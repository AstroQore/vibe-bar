import Foundation
import SQLite3

/// Persists the pace forecast that was actually shown for each quota bucket.
///
/// Scope mirrors `UsageFillTimelineStore`:
///
/// - Same five core providers, same adaptive slot policy, last sample in a slot
///   wins, same window-aware retention horizon.
/// - Written only when a quota refresh succeeds. Nothing here runs at render
///   time — the live forecast the UI draws is still computed on demand.
///
/// The chart pairs these points with the fill timeline: the fill line is what
/// happened, this is what was predicted at the time. Recomputing an old
/// forecast from today's history would quietly launder hindsight into the
/// projection line, which is exactly what the feature is meant to expose.
///
/// Storage is SQLite (`~/.vibebar/forecast_timeline.sqlite3`, mode 0600, WAL)
/// for the same reason as the fill timeline: whole-file JSON rewrites of a
/// multi-megabyte history every save throttle blew the OS disk-write budget,
/// while WAL upserts cost a few KB per refresh. A legacy
/// `forecast_timeline.json` is imported once and removed.
public actor UsageForecastTimelineStore {
    public static let shared = UsageForecastTimelineStore(
        fileURL: UsageForecastTimelineStore.defaultFileURL(),
        legacyJSONURL: VibeBarLocalStore.forecastTimelineURL
    )

    private struct LegacyStorage: Codable {
        var schemaVersion: Int
        var points: [ForecastTimelinePoint]
    }

    private let fileURL: URL
    private let legacyJSONURL: URL?
    private var database: TimelineSQLite?
    private var openAttempted = false
    private var sidecarPermissionsSet = false
    /// When retention was last enforced. The prune is a full-table
    /// `DELETE ... WHERE slot_start < CASE …` — not sargable, so SQLite scans
    /// every row — and it used to run on every dirty observation, i.e. once
    /// per quota refresh per account. Retention horizons are measured in
    /// days; once an hour discards exactly the same rows.
    private var lastPrunedAt: Date?
    private static let pruneInterval: TimeInterval = 60 * 60

    private static let databaseSchemaVersion: Int32 = 1
    /// Highest legacy JSON schema this build can import.
    private static let legacyJSONSchemaVersion = 1
    /// Defensive cap on the legacy import: a JSON file past this size is
    /// corrupt, not legitimate history.
    private static let maxLegacyFileBytes = 24 * 1024 * 1024
    private static let supportedTools: Set<ToolType> = [.codex, .claude, .gemini, .antigravity, .grok, .cursor]

    public init(fileURL: URL = UsageForecastTimelineStore.defaultFileURL(), legacyJSONURL: URL? = nil) {
        self.fileURL = fileURL
        self.legacyJSONURL = legacyJSONURL
    }

    public static func defaultFileURL() -> URL {
        try? VibeBarLocalStore.ensureBaseDirectory()
        return VibeBarLocalStore.forecastTimelineDatabaseURL
    }

    // MARK: - Public API

    /// Record one refresh worth of forecasts. Buckets without a forecast are
    /// simply omitted by the caller — a missing projection is not stored as a
    /// zero.
    public func observe(
        _ forecasts: [BucketForecastObservation],
        accountId: String,
        tool: ToolType,
        now: Date = Date(),
        retentionDays: Int = CostDataSettings.defaultRetentionDays
    ) {
        guard Self.supportedTools.contains(tool), !forecasts.isEmpty else { return }
        guard let db = ensureDatabase() else { return }

        let upsert = db.prepare("""
            INSERT INTO forecast_points(
                account_id, tool, bucket_id, slot_start, sampled_at,
                projected_used_percent, projected_lower_percent, projected_upper_percent,
                reset_at, raw_window_seconds
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(account_id, bucket_id, slot_start) DO UPDATE SET
                tool = excluded.tool,
                sampled_at = excluded.sampled_at,
                projected_used_percent = excluded.projected_used_percent,
                projected_lower_percent = excluded.projected_lower_percent,
                projected_upper_percent = excluded.projected_upper_percent,
                reset_at = excluded.reset_at,
                raw_window_seconds = excluded.raw_window_seconds
            """)
        guard let upsert else { return }
        defer { sqlite3_finalize(upsert) }

        var dirty = false
        db.exec("BEGIN IMMEDIATE")
        for forecast in forecasts {
            guard forecast.projectedUsedPercent.isFinite,
                  forecast.projectedUsedLowerPercent.isFinite,
                  forecast.projectedUsedUpperPercent.isFinite
            else { continue }
            let slotStart = UsageTimelineSlotPolicy.slotStart(
                for: now,
                windowSeconds: forecast.rawWindowSeconds
            )
            sqlite3_reset(upsert)
            db.bindText(upsert, 1, accountId)
            db.bindText(upsert, 2, tool.rawValue)
            db.bindText(upsert, 3, forecast.bucketId)
            db.bindDouble(upsert, 4, slotStart.timeIntervalSince1970)
            db.bindDouble(upsert, 5, now.timeIntervalSince1970)
            db.bindDouble(upsert, 6, forecast.projectedUsedPercent)
            db.bindDouble(upsert, 7, forecast.projectedUsedLowerPercent)
            db.bindDouble(upsert, 8, forecast.projectedUsedUpperPercent)
            db.bindOptionalDouble(upsert, 9, forecast.resetAt?.timeIntervalSince1970)
            db.bindOptionalInt(upsert, 10, forecast.rawWindowSeconds)
            if sqlite3_step(upsert) == SQLITE_DONE { dirty = true }
        }
        if dirty, shouldPrune(now: now) {
            prune(db, retentionDays: retentionDays, now: now)
            lastPrunedAt = now
        }
        db.exec("COMMIT")
        setSidecarPermissionsIfNeeded()
    }

    /// Points for one account+bucket, oldest first.
    public func points(accountId: String, bucketId: String) -> [ForecastTimelinePoint] {
        guard let db = ensureDatabase(),
              let statement = db.prepare("""
                  SELECT account_id, tool, bucket_id, slot_start, sampled_at,
                         projected_used_percent, projected_lower_percent,
                         projected_upper_percent, reset_at, raw_window_seconds
                    FROM forecast_points
                   WHERE account_id = ? AND bucket_id = ?
                   ORDER BY slot_start
                  """)
        else { return [] }
        defer { sqlite3_finalize(statement) }
        db.bindText(statement, 1, accountId)
        db.bindText(statement, 2, bucketId)
        return readPoints(db, statement)
    }

    public func allPoints() -> [ForecastTimelinePoint] {
        guard let db = ensureDatabase(),
              let statement = db.prepare("""
                  SELECT account_id, tool, bucket_id, slot_start, sampled_at,
                         projected_used_percent, projected_lower_percent,
                         projected_upper_percent, reset_at, raw_window_seconds
                    FROM forecast_points
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
        lastPrunedAt = nil
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
            CREATE TABLE IF NOT EXISTS forecast_points (
                account_id TEXT NOT NULL,
                tool TEXT NOT NULL,
                bucket_id TEXT NOT NULL,
                slot_start REAL NOT NULL,
                sampled_at REAL NOT NULL,
                projected_used_percent REAL NOT NULL,
                projected_lower_percent REAL NOT NULL,
                projected_upper_percent REAL NOT NULL,
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
            INSERT OR REPLACE INTO forecast_points(
                account_id, tool, bucket_id, slot_start, sampled_at,
                projected_used_percent, projected_lower_percent, projected_upper_percent,
                reset_at, raw_window_seconds
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            database.bindDouble(upsert, 5, point.sampledAt.timeIntervalSince1970)
            database.bindDouble(upsert, 6, point.projectedUsedPercent)
            database.bindDouble(upsert, 7, point.projectedUsedLowerPercent)
            database.bindDouble(upsert, 8, point.projectedUsedUpperPercent)
            database.bindOptionalDouble(upsert, 9, point.resetAt?.timeIntervalSince1970)
            database.bindOptionalInt(upsert, 10, point.rawWindowSeconds)
            sqlite3_step(upsert)
        }
        database.exec("COMMIT")
        setSidecarPermissionsIfNeeded()
    }

    private func readPoints(_ db: TimelineSQLite, _ statement: OpaquePointer) -> [ForecastTimelinePoint] {
        var points: [ForecastTimelinePoint] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let accountId = db.columnText(statement, 0),
                  let toolRaw = db.columnText(statement, 1),
                  let tool = ToolType(rawValue: toolRaw),
                  let bucketId = db.columnText(statement, 2)
            else { continue }
            points.append(ForecastTimelinePoint(
                accountId: accountId,
                tool: tool,
                bucketId: bucketId,
                slotStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                sampledAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                projectedUsedPercent: sqlite3_column_double(statement, 5),
                projectedUsedLowerPercent: sqlite3_column_double(statement, 6),
                projectedUsedUpperPercent: sqlite3_column_double(statement, 7),
                resetAt: db.columnOptionalDouble(statement, 8).map(Date.init(timeIntervalSince1970:)),
                rawWindowSeconds: db.columnOptionalInt(statement, 9)
            ))
        }
        return points
    }

    /// Window-aware retention, evaluated in SQL. The horizon depends only on
    /// which of the four slot classes a point's window falls into, so four
    /// cutoffs bound the whole table — see `UsageTimelineSlotPolicy`.
    private func shouldPrune(now: Date) -> Bool {
        guard let lastPrunedAt else { return true }
        // A clock that jumped backwards must not park the prune indefinitely.
        guard now >= lastPrunedAt else { return true }
        return now.timeIntervalSince(lastPrunedAt) >= Self.pruneInterval
    }

    private func prune(_ db: TimelineSQLite, retentionDays: Int, now: Date) {
        let statement = db.prepare("""
            DELETE FROM forecast_points WHERE slot_start <
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
