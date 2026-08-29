import Foundation
import SQLite3

/// Persists quota observations used by reset history and pace forecasting.
///
/// Scope mirrors `SubscriptionHistoryStore` where it makes sense:
///
/// - Every quota for the five core providers is recorded, including Codex
///   Spark, Claude Fable, and every Gemini Web / AntiGravity lane.
/// - Slot size and retention follow the quota window so short rolling limits
///   stay detailed without making weekly/monthly history unnecessarily large.
///
/// Storage is SQLite (`~/.vibebar/fill_timeline.sqlite3`, mode 0600, WAL).
/// The original whole-file JSON design assumed the timeline would stay small;
/// real retention grew it to tens of thousands of points, and atomically
/// rewriting megabytes every save throttle put the app hundreds of KB/s over
/// the OS disk-write budget. WAL upserts make each refresh cost a few KB —
/// only the observed slots — no matter how large the history gets. A legacy
/// `fill_timeline.json` is imported once and removed.
public actor UsageFillTimelineStore {
    public static let shared = UsageFillTimelineStore(
        fileURL: UsageFillTimelineStore.defaultFileURL(),
        legacyJSONURL: VibeBarLocalStore.fillTimelineURL
    )

    private struct LegacyStorage: Codable {
        var schemaVersion: Int
        var points: [FillTimelinePoint]
    }

    private let fileURL: URL
    private let legacyJSONURL: URL?
    private var database: TimelineSQLite?
    private var openAttempted = false
    private var sidecarPermissionsSet = false

    private static let databaseSchemaVersion: Int32 = 1
    /// Highest legacy JSON schema this build can import.
    private static let legacyJSONSchemaVersion = 2
    /// Defensive cap on the legacy import: a JSON file past this size is
    /// corrupt, not legitimate history.
    private static let maxLegacyFileBytes = 24 * 1024 * 1024
    private static let supportedTools: Set<ToolType> = [.codex, .claude, .gemini, .antigravity, .grok, .cursor]

    public init(fileURL: URL = UsageFillTimelineStore.defaultFileURL(), legacyJSONURL: URL? = nil) {
        self.fileURL = fileURL
        self.legacyJSONURL = legacyJSONURL
    }

    public static func defaultFileURL() -> URL {
        try? VibeBarLocalStore.ensureBaseDirectory()
        return VibeBarLocalStore.fillTimelineDatabaseURL
    }

    // MARK: - Public API

    public func observe(
        _ quota: AccountQuota,
        now: Date = Date(),
        retentionDays: Int = CostDataSettings.defaultRetentionDays
    ) {
        guard Self.supportedTools.contains(quota.tool) else { return }
        guard let db = ensureDatabase() else { return }

        let upsert = db.prepare("""
            INSERT INTO fill_points(
                account_id, tool, bucket_id, slot_start, used_percent,
                sampled_at, reset_at, raw_window_seconds
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(account_id, bucket_id, slot_start) DO UPDATE SET
                tool = excluded.tool,
                used_percent = excluded.used_percent,
                sampled_at = excluded.sampled_at,
                reset_at = excluded.reset_at,
                raw_window_seconds = excluded.raw_window_seconds
            """)
        guard let upsert else { return }
        defer { sqlite3_finalize(upsert) }

        var dirty = false
        db.exec("BEGIN IMMEDIATE")
        for bucket in quota.buckets {
            guard bucket.usedPercent.isFinite else { continue }
            let percent = min(100, max(0, bucket.usedPercent))
            let slotStart = Self.slotStart(for: now, windowSeconds: bucket.rawWindowSeconds)
            sqlite3_reset(upsert)
            db.bindText(upsert, 1, quota.accountId)
            db.bindText(upsert, 2, quota.tool.rawValue)
            db.bindText(upsert, 3, bucket.id)
            db.bindDouble(upsert, 4, slotStart.timeIntervalSince1970)
            db.bindDouble(upsert, 5, percent)
            db.bindDouble(upsert, 6, now.timeIntervalSince1970)
            db.bindOptionalDouble(upsert, 7, bucket.resetAt?.timeIntervalSince1970)
            db.bindOptionalInt(upsert, 8, bucket.rawWindowSeconds)
            if sqlite3_step(upsert) == SQLITE_DONE { dirty = true }
        }
        if dirty {
            prune(db, retentionDays: retentionDays, now: now)
        }
        db.exec("COMMIT")
        setSidecarPermissionsIfNeeded()
    }

    /// Points for one account+bucket, oldest first.
    public func points(accountId: String, bucketId: String) -> [FillTimelinePoint] {
        guard let db = ensureDatabase(),
              let statement = db.prepare("""
                  SELECT account_id, tool, bucket_id, slot_start, used_percent,
                         sampled_at, reset_at, raw_window_seconds
                    FROM fill_points
                   WHERE account_id = ? AND bucket_id = ?
                   ORDER BY slot_start
                  """)
        else { return [] }
        defer { sqlite3_finalize(statement) }
        db.bindText(statement, 1, accountId)
        db.bindText(statement, 2, bucketId)
        return readPoints(db, statement)
    }

    /// Points for several buckets of one account, oldest first per bucket.
    ///
    /// One actor hop for the whole account instead of one per bucket: the
    /// caller republishes the result into `@Published` state, and an `await`
    /// between buckets meant every bucket landed in its own main-actor tick —
    /// which is a full popover re-render each, thirty-odd of them per refresh.
    /// Buckets with no recorded points are absent from the result.
    public func points(accountId: String, bucketIds: [String]) -> [String: [FillTimelinePoint]] {
        let wanted = Set(bucketIds)
        guard !wanted.isEmpty, let db = ensureDatabase(),
              let statement = db.prepare("""
                  SELECT account_id, tool, bucket_id, slot_start, used_percent,
                         sampled_at, reset_at, raw_window_seconds
                    FROM fill_points
                   WHERE account_id = ?
                   ORDER BY slot_start
                  """)
        else { return [:] }
        defer { sqlite3_finalize(statement) }
        db.bindText(statement, 1, accountId)
        var grouped: [String: [FillTimelinePoint]] = [:]
        for point in readPoints(db, statement) where wanted.contains(point.bucketId) {
            grouped[point.bucketId, default: []].append(point)
        }
        return grouped
    }

    public func allPoints() -> [FillTimelinePoint] {
        guard let db = ensureDatabase(),
              let statement = db.prepare("""
                  SELECT account_id, tool, bucket_id, slot_start, used_percent,
                         sampled_at, reset_at, raw_window_seconds
                    FROM fill_points
                   ORDER BY slot_start
                  """)
        else { return [] }
        defer { sqlite3_finalize(statement) }
        return readPoints(db, statement)
    }

    public func eraseAll() {
        database?.close()
        database = nil
        openAttempted = false
        sidecarPermissionsSet = false
        removeDatabaseFiles()
        if let legacyJSONURL {
            try? FileManager.default.removeItem(at: legacyJSONURL)
        }
    }

    /// Writes are committed per observation now; this folds the WAL back into
    /// the main file so tests (and privacy-conscious users) see one file.
    public func flushPendingWrites() async {
        database?.exec("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    // MARK: - Private

    static func hourSlotStart(for date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 3_600) * 3_600)
    }

    static func slotStart(for date: Date, windowSeconds: Int?) -> Date {
        UsageTimelineSlotPolicy.slotStart(for: date, windowSeconds: windowSeconds)
    }

    private func ensureDatabase() -> TimelineSQLite? {
        if let database { return database }
        guard !openAttempted else { return nil }
        openAttempted = true

        var db = TimelineSQLite(url: fileURL)
        if db == nil || !Self.initializeSchema(db!) {
            // A corrupt database loads empty and still accepts new points —
            // same contract the JSON store had for a corrupt file.
            db?.close()
            removeDatabaseFiles()
            db = TimelineSQLite(url: fileURL)
            guard let retried = db, Self.initializeSchema(retried) else {
                db?.close()
                return nil
            }
        }
        guard let opened = db else { return nil }

        if opened.userVersion > Self.databaseSchemaVersion {
            // A future build owns this file. Start over rather than guessing
            // at its schema — mirrors the JSON store's reset-on-future-schema.
            opened.close()
            removeDatabaseFiles()
            guard let fresh = TimelineSQLite(url: fileURL), Self.initializeSchema(fresh) else {
                return nil
            }
            fresh.userVersion = Self.databaseSchemaVersion
            database = fresh
        } else {
            opened.userVersion = Self.databaseSchemaVersion
            database = opened
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
        importLegacyJSONIfPresent()
        return database
    }

    private static func initializeSchema(_ db: TimelineSQLite) -> Bool {
        db.exec("""
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS fill_points (
                account_id TEXT NOT NULL,
                tool TEXT NOT NULL,
                bucket_id TEXT NOT NULL,
                slot_start REAL NOT NULL,
                used_percent REAL NOT NULL,
                sampled_at REAL NOT NULL,
                reset_at REAL,
                raw_window_seconds INTEGER,
                PRIMARY KEY(account_id, bucket_id, slot_start)
            );
            """)
    }

    private func importLegacyJSONIfPresent() {
        guard let legacyJSONURL, let database,
              FileManager.default.fileExists(atPath: legacyJSONURL.path)
        else { return }
        defer {
            // One shot either way: a file that failed to decode is corrupt or
            // from a future build, and leaving it would only re-run this on
            // every launch. The new database is the source of truth now.
            try? FileManager.default.removeItem(at: legacyJSONURL)
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: legacyJSONURL.path),
           let size = (attrs[.size] as? NSNumber)?.intValue,
           size > Self.maxLegacyFileBytes {
            return
        }
        guard let data = try? Data(contentsOf: legacyJSONURL),
              let legacy = try? JSONDecoder().decode(LegacyStorage.self, from: data),
              legacy.schemaVersion <= Self.legacyJSONSchemaVersion
        else { return }
        let upsert = database.prepare("""
            INSERT OR REPLACE INTO fill_points(
                account_id, tool, bucket_id, slot_start, used_percent,
                sampled_at, reset_at, raw_window_seconds
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            """)
        guard let upsert else { return }
        defer { sqlite3_finalize(upsert) }
        database.exec("BEGIN IMMEDIATE")
        for point in legacy.points {
            sqlite3_reset(upsert)
            database.bindText(upsert, 1, point.accountId)
            database.bindText(upsert, 2, point.tool.rawValue)
            database.bindText(upsert, 3, point.bucketId)
            database.bindDouble(upsert, 4, point.slotStart.timeIntervalSince1970)
            database.bindDouble(upsert, 5, point.usedPercent)
            database.bindDouble(upsert, 6, point.sampledAt.timeIntervalSince1970)
            database.bindOptionalDouble(upsert, 7, point.resetAt?.timeIntervalSince1970)
            database.bindOptionalInt(upsert, 8, point.rawWindowSeconds)
            sqlite3_step(upsert)
        }
        database.exec("COMMIT")
        setSidecarPermissionsIfNeeded()
    }

    private func readPoints(_ db: TimelineSQLite, _ statement: OpaquePointer) -> [FillTimelinePoint] {
        var points: [FillTimelinePoint] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let accountId = db.columnText(statement, 0),
                  let toolRaw = db.columnText(statement, 1),
                  let tool = ToolType(rawValue: toolRaw),
                  let bucketId = db.columnText(statement, 2)
            else { continue }
            points.append(FillTimelinePoint(
                accountId: accountId,
                tool: tool,
                bucketId: bucketId,
                slotStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                usedPercent: sqlite3_column_double(statement, 4),
                sampledAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                resetAt: db.columnOptionalDouble(statement, 6).map(Date.init(timeIntervalSince1970:)),
                rawWindowSeconds: db.columnOptionalInt(statement, 7)
            ))
        }
        return points
    }

    /// Window-aware retention, evaluated in SQL. The horizon depends only on
    /// which of the four slot classes a point's window falls into, so four
    /// cutoffs bound the whole table — see `UsageTimelineSlotPolicy`.
    private func prune(_ db: TimelineSQLite, retentionDays: Int, now: Date) {
        let statement = db.prepare("""
            DELETE FROM fill_points WHERE slot_start <
                CASE
                    WHEN raw_window_seconds IS NOT NULL AND raw_window_seconds <= 21600 THEN ?
                    WHEN raw_window_seconds IS NOT NULL AND raw_window_seconds <= 691200 THEN ?
                    WHEN raw_window_seconds IS NOT NULL AND raw_window_seconds <= 3888000 THEN ?
                    ELSE ?
                END
            """)
        guard let statement else { return }
        defer { sqlite3_finalize(statement) }
        for (index, representative) in [21_600, 691_200, 3_888_000, nil as Int?].enumerated() {
            let horizon = UsageTimelineSlotPolicy.retentionHorizonDays(
                windowSeconds: representative,
                retentionDays: retentionDays
            )
            db.bindDouble(
                statement,
                Int32(index + 1),
                now.addingTimeInterval(-TimeInterval(horizon) * 86_400).timeIntervalSince1970
            )
        }
        sqlite3_step(statement)
    }

    private func removeDatabaseFiles() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: fileURL.path + suffix)
        }
    }

    private func setSidecarPermissionsIfNeeded() {
        guard !sidecarPermissionsSet else { return }
        var allPresentSet = true
        for suffix in ["-wal", "-shm"] {
            let path = fileURL.path + suffix
            guard FileManager.default.fileExists(atPath: path) else {
                allPresentSet = false
                continue
            }
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: path
            )
        }
        sidecarPermissionsSet = allPresentSet
    }
}
