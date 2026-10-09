import Foundation
import SQLite3

extension VibeBarLocalStore {
    /// `~/.vibebar/session_activity.sqlite3`: `SessionActivityScanner`
    /// results, keyed by session file and valid for one fingerprint.
    public static var sessionActivityURL: URL {
        baseDirectory.appendingPathComponent("session_activity.sqlite3")
    }
}

/// Persistent cache of `SessionActivityTally` per session file, plus the
/// budgeted background fill that keeps it current.
///
/// Derived data in the same sense as `session_structure.sqlite3`: a row is
/// valid only for the `(mtime_ns, size)` it was scanned at and for the
/// current `SessionActivityScanner.version`; anything else is a miss. If the
/// file cannot be opened the store degrades to "always miss" and the fill
/// keeps its results in memory for the life of the process.
public actor SessionActivityStore {
    public struct FillBudget: Sendable, Hashable {
        public var maxFiles: Int
        public var maxBytes: Int64
        /// Files above this are never scanned in the background.
        public var maxFileBytes: Int64

        public init(maxFiles: Int = 64, maxBytes: Int64 = 384 * 1024 * 1024, maxFileBytes: Int64 = 1_024 * 1024 * 1024) {
            self.maxFiles = maxFiles
            self.maxBytes = maxBytes
            self.maxFileBytes = maxFileBytes
        }
    }

    public struct FillReport: Sendable, Hashable {
        public var scanned = 0
        public var upToDate = 0
        public var skippedLarge = 0
        public var deferred = 0
        public var missing = 0
        public var bytesScanned: Int64 = 0

        public init() {}
    }

    public struct Entry: Sendable, Hashable {
        public var fingerprint: SessionFileFingerprint
        public var tally: SessionActivityTally
    }

    static let schemaVersion: Int32 = 1

    public let url: URL?
    private let calendar: Calendar
    private var database: TimelineSQLite?
    private var didOpen = false
    /// Everything read or scanned this launch.
    private var memory: [String: Entry] = [:]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// `url == nil` keeps everything in memory (tests, or a store that
    /// would not open).
    public init(url: URL? = VibeBarLocalStore.sessionActivityURL, calendar: Calendar = UsageDashboardCalendar.local) {
        self.url = url
        self.calendar = calendar
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder
    }

    deinit {
        database?.close()
    }

    // MARK: Reads

    /// Fresh tallies for `summaries`, keyed by source path. A session whose
    /// file moved since its scan is absent.
    public func tallies(for summaries: [SessionSummary]) -> [String: SessionActivityTally] {
        var out: [String: SessionActivityTally] = [:]
        var wanted: [String: SessionFileFingerprint] = [:]
        for summary in summaries where SessionActivityScanner.supports(summary.provider) {
            guard let fingerprint = SessionFileFingerprint.of(path: summary.sourcePath) else { continue }
            if let cached = memory[summary.sourcePath], cached.fingerprint == fingerprint {
                out[summary.sourcePath] = cached.tally
            } else {
                wanted[summary.sourcePath] = fingerprint
            }
        }
        guard !wanted.isEmpty else { return out }
        for (path, entry) in readRows(paths: Array(wanted.keys)) where entry.fingerprint == wanted[path] {
            memory[path] = entry
            out[path] = entry.tally
        }
        return out
    }

    // MARK: Fill

    /// Scan the sessions in `summaries` whose tally is missing or stale,
    /// most recently active first, within `budget`.
    public func fill(_ summaries: [SessionSummary], budget: FillBudget = FillBudget()) async -> FillReport {
        var report = FillReport()
        let ordered = summaries
            .filter { SessionActivityScanner.supports($0.provider) }
            .sorted { ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast) }
        let known = tallies(for: ordered)
        for summary in ordered {
            if Task.isCancelled { break }
            if known[summary.sourcePath] != nil {
                report.upToDate += 1
                continue
            }
            guard let fingerprint = SessionFileFingerprint.of(path: summary.sourcePath) else {
                report.missing += 1
                continue
            }
            if fingerprint.size > budget.maxFileBytes {
                report.skippedLarge += 1
                continue
            }
            if report.scanned >= budget.maxFiles || report.bytesScanned >= budget.maxBytes {
                report.deferred += 1
                continue
            }
            let url = URL(fileURLWithPath: summary.sourcePath)
            let provider = summary.provider
            let calendar = self.calendar
            let tally = await Task.detached(priority: .utility) {
                SessionActivityScanner.scan(
                    fileURL: url, provider: provider, calendar: calendar, isCancelled: { Task.isCancelled }
                )
            }.value
            guard let tally else {
                report.missing += 1
                continue
            }
            report.scanned += 1
            report.bytesScanned += fingerprint.size
            let entry = Entry(fingerprint: fingerprint, tally: tally)
            memory[summary.sourcePath] = entry
            write(path: summary.sourcePath, entry: entry)
        }
        return report
    }

    /// Whether a session will never be scanned in the background.
    public static func isTooLarge(_ summary: SessionSummary, budget: FillBudget = FillBudget()) -> Bool {
        summary.sizeBytes > budget.maxFileBytes
    }

    // MARK: SQLite

    private func openIfNeeded() -> TimelineSQLite? {
        if didOpen { return database }
        didOpen = true
        guard let url else { return nil }
        if url == VibeBarLocalStore.sessionActivityURL {
            try? VibeBarLocalStore.ensureBaseDirectory()
        }
        guard let opened = TimelineSQLite(url: url) else { return nil }
        guard opened.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;") else {
            opened.close()
            return nil
        }
        if opened.userVersion != Self.schemaVersion {
            _ = opened.exec("DROP TABLE IF EXISTS session_activity")
        }
        guard opened.exec("""
            CREATE TABLE IF NOT EXISTS session_activity (
                source_path TEXT PRIMARY KEY,
                mtime_ns INTEGER NOT NULL,
                size INTEGER NOT NULL,
                scanner_version INTEGER NOT NULL,
                tally_json TEXT NOT NULL,
                scanned_at REAL NOT NULL
            );
            """)
        else {
            opened.close()
            return nil
        }
        opened.userVersion = Self.schemaVersion
        _ = opened.exec("DELETE FROM session_activity WHERE scanner_version != \(SessionActivityScanner.version)")
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        database = opened
        return opened
    }

    private func readRows(paths: [String]) -> [String: Entry] {
        guard let database = openIfNeeded() else { return [:] }
        var out: [String: Entry] = [:]
        var start = 0
        while start < paths.count {
            let chunk = paths[start..<min(paths.count, start + 400)]
            start += chunk.count
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            guard let statement = database.prepare("""
                SELECT source_path, mtime_ns, size, tally_json FROM session_activity
                WHERE scanner_version = ? AND source_path IN (\(marks))
                """)
            else { continue }
            sqlite3_bind_int64(statement, 1, Int64(SessionActivityScanner.version))
            for (offset, path) in chunk.enumerated() {
                database.bindText(statement, Int32(offset + 2), path)
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let path = database.columnText(statement, 0),
                      let json = database.columnText(statement, 3),
                      let tally = try? decoder.decode(SessionActivityTally.self, from: Data(json.utf8))
                else { continue }
                out[path] = Entry(
                    fingerprint: SessionFileFingerprint(
                        mtimeNs: sqlite3_column_int64(statement, 1),
                        size: sqlite3_column_int64(statement, 2)
                    ),
                    tally: tally
                )
            }
            sqlite3_finalize(statement)
        }
        return out
    }

    private func write(path: String, entry: Entry) {
        guard let database = openIfNeeded(),
              let data = try? encoder.encode(entry.tally),
              let json = String(data: data, encoding: .utf8),
              let statement = database.prepare("""
                INSERT INTO session_activity (source_path, mtime_ns, size, scanner_version, tally_json, scanned_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                ON CONFLICT(source_path) DO UPDATE SET
                    mtime_ns = excluded.mtime_ns, size = excluded.size,
                    scanner_version = excluded.scanner_version, tally_json = excluded.tally_json,
                    scanned_at = excluded.scanned_at
                """)
        else { return }
        defer { sqlite3_finalize(statement) }
        database.bindText(statement, 1, path)
        sqlite3_bind_int64(statement, 2, entry.fingerprint.mtimeNs)
        sqlite3_bind_int64(statement, 3, entry.fingerprint.size)
        sqlite3_bind_int64(statement, 4, Int64(SessionActivityScanner.version))
        database.bindText(statement, 5, json)
        database.bindDouble(statement, 6, Date().timeIntervalSince1970)
        _ = sqlite3_step(statement)
    }
}
