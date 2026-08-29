import Foundation
import SQLite3

/// Keeps `~/.vibebar/session_index.sqlite3` at the size its content
/// deserves.
///
/// Three things made the index grow to 2.5 GB on a busy machine, and each
/// gets its own pass here:
///
/// 1. **Over-long excerpts.** The kit indexes up to 2 000 characters per
///    message and 512 KiB per session; three quarters of that text was
///    tool output. The *trim* pass re-asserts
///    `SessionIndexExcerptPolicy` over rows already in the database —
///    delete + re-insert, never `UPDATE`, because the FTS5 external-content
///    table is synced by insert/delete triggers only.
/// 2. **Stale FTS doclists.** Every append to a live session re-indexes it
///    as delete-all + insert-all, and FTS5 keeps the superseded postings
///    until segments merge. Nothing ever asked for a merge, so a third of
///    the index was dead weight. The *merge* pass runs FTS5's documented
///    incremental merge — one bounded transaction per step — until the
///    index is a single segment.
/// 3. **No reclamation.** The database predates `auto_vacuum`, so freed
///    pages could never return to the filesystem. The first pass converts
///    it with `auto_vacuum=INCREMENTAL` + one `VACUUM`; every later pass
///    just runs bounded `incremental_vacuum` steps.
///
/// The index is derived data and this class only ever *removes* content
/// the policy says is over budget, so a half-finished pass is harmless:
/// the victim query is idempotent and the next pass continues where this
/// one stopped. All work happens on a utility-QoS serial queue — never on
/// the caller's executor — and every step is bounded so the kit's own
/// writers only ever wait on a short transaction.
public final class SessionIndexCompactor: @unchecked Sendable {
    public struct Outcome: Sendable, Equatable {
        public var sessionsTrimmed = 0
        public var messagesDropped = 0
        public var messagesTrimmed = 0
        public var mergeSteps = 0
        public var ranFullVacuum = false
        public var bytesBefore: Int64 = 0
        public var bytesAfter: Int64 = 0
        /// `false` when the time budget ran out or a step hit a busy
        /// database; the stamp is not written, so the next trigger retries.
        public var completed = false
    }

    /// One compactor for the production database. Both trigger sites (app
    /// launch and the Sessions page's refresh completion) share it, and the
    /// serial queue underneath makes overlapping triggers wait, not race.
    public static let standard = SessionIndexCompactor()

    private let databaseURL: URL
    private let stampURL: URL
    private let scratchDirectoryURL: URL
    private let policy: SessionIndexExcerptPolicy
    private let queue: DispatchQueue

    /// Floor between two completed passes. A policy-version change ignores it.
    private let interval: TimeInterval
    /// Wall-clock budget for one pass. The one-time migration of a
    /// years-grown database fits (measured ≈ 6 minutes for 2.5 GB); a
    /// steady-state pass uses seconds of it.
    private let timeBudget: TimeInterval

    /// The kit schema this class knows how to trim
    /// (`SessionIndexStore.schemaVersion`). Any other version means the kit
    /// has rebuilt or is about to rebuild the tables, and the only safe
    /// move is to do nothing.
    private static let supportedKitSchemaVersion: Int32 = 5

    public init(
        databaseURL: URL = VibeBarLocalStore.sessionIndexURL,
        stampURL: URL = VibeBarLocalStore.sessionIndexMaintenanceStampURL,
        scratchDirectoryURL: URL = VibeBarLocalStore.sessionIndexScratchDirectoryURL,
        policy: SessionIndexExcerptPolicy = .standard,
        interval: TimeInterval = 24 * 60 * 60,
        timeBudget: TimeInterval = 10 * 60
    ) {
        self.databaseURL = databaseURL
        self.stampURL = stampURL
        self.scratchDirectoryURL = scratchDirectoryURL
        self.policy = policy
        self.interval = interval
        self.timeBudget = timeBudget
        self.queue = DispatchQueue(label: "vibebar.session-index-compactor", qos: .utility)
    }

    /// Runs a pass when the stamp says one is due; returns `nil` otherwise
    /// (also when the database does not exist yet). Safe to call from
    /// several places — calls serialize on the compactor's queue.
    public func compactIfDue(now: Date = Date()) async -> Outcome? {
        await onQueue { [self] in
            guard isDue(now: now) else { return nil }
            return performCompact(now: now)
        }
    }

    /// Runs a pass unconditionally (except for a missing database).
    public func compact(now: Date = Date()) async -> Outcome? {
        await onQueue { [self] in performCompact(now: now) }
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    // MARK: - Stamp

    private struct Stamp: Codable {
        var lastCompletedAt: Date
        var policyVersion: Int
    }

    private func isDue(now: Date) -> Bool {
        guard let data = try? Data(contentsOf: stampURL),
              let stamp = try? JSONDecoder().decode(Stamp.self, from: data)
        else { return true }
        if stamp.policyVersion != SessionIndexExcerptPolicy.version { return true }
        return now.timeIntervalSince(stamp.lastCompletedAt) >= interval
    }

    private func writeStamp(now: Date) {
        let stamp = Stamp(lastCompletedAt: now, policyVersion: SessionIndexExcerptPolicy.version)
        guard let data = try? JSONEncoder().encode(stamp) else { return }
        try? FileManager.default.createDirectory(
            at: stampURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? data.write(to: stampURL, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: stampURL.path
        )
    }

    // MARK: - The pass

    private func performCompact(now: Date) -> Outcome? {
        sweepScratch(now: now)
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        guard let db = Connection(url: databaseURL) else { return nil }
        defer { db.close() }

        var outcome = Outcome()
        outcome.bytesBefore = db.int("PRAGMA page_count") * db.int("PRAGMA page_size")
        let deadline = Date().addingTimeInterval(timeBudget)

        guard db.int("PRAGMA user_version") == Int64(Self.supportedKitSchemaVersion),
              db.hasTable("session_messages"), db.hasTable("session_fts")
        else {
            // Unknown schema: the kit owns it now. Leave the rows alone and
            // do not stamp, so a pass runs once a supported schema is back.
            return nil
        }

        let trimmedFully = trimPass(db, outcome: &outcome, deadline: deadline)
        let mergedFully = trimmedFully && mergePass(db, outcome: &outcome, deadline: deadline)
        let reclaimedFully = mergedFully && reclaimPass(db, outcome: &outcome, deadline: deadline)
        db.exec("PRAGMA wal_checkpoint(TRUNCATE)")

        outcome.bytesAfter = db.int("PRAGMA page_count") * db.int("PRAGMA page_size")
        outcome.completed = reclaimedFully
        if outcome.completed {
            writeStamp(now: now)
        }
        SafeLog.info(
            "Session index maintenance: trimmed \(outcome.sessionsTrimmed) sessions "
                + "(-\(outcome.messagesDropped) rows, \(outcome.messagesTrimmed) shortened), "
                + "\(outcome.mergeSteps) merge steps, "
                + "\(outcome.ranFullVacuum ? "full" : "incremental") vacuum, "
                + "\(outcome.bytesBefore / 1_048_576) MB -> \(outcome.bytesAfter / 1_048_576) MB"
                + (outcome.completed ? "." : " (will resume).")
        )
        return outcome
    }

    // MARK: - Trim

    /// Sessions per transaction. Small enough that the kit's own writers
    /// (5-second busy timeout) never wait long, large enough to amortize
    /// the commit.
    private static let trimBatchSessions = 32

    private func trimPass(_ db: Connection, outcome: inout Outcome, deadline: Date) -> Bool {
        // Over-selection is fine (a compliant session is read and left
        // alone); under-selection is not, so the predicates mirror the trim
        // exactly: characters per role (+1 for the truncation ellipsis),
        // UTF-8 bytes per session.
        let victims = db.column(
            """
            SELECT session_row FROM session_messages
             GROUP BY session_row
             HAVING SUM(LENGTH(CAST(excerpt AS BLOB))) > ?1
                 OR MAX(CASE WHEN role IN ('tool','system') THEN LENGTH(excerpt) ELSE 0 END) > ?2
                 OR MAX(CASE WHEN role NOT IN ('tool','system') THEN LENGTH(excerpt) ELSE 0 END) > ?3
            """,
            binds: [
                Int64(policy.sessionExcerptBytes),
                Int64(policy.toolExcerptCharacters + 1),
                Int64(policy.proseExcerptCharacters + 1)
            ]
        )
        guard !victims.isEmpty else { return true }

        for batch in stride(from: 0, to: victims.count, by: Self.trimBatchSessions) {
            guard Date() < deadline else { return false }
            let slice = victims[batch..<min(batch + Self.trimBatchSessions, victims.count)]
            guard db.exec("BEGIN IMMEDIATE") else { return false }
            var ok = true
            for sessionRow in slice where ok {
                ok = trim(sessionRow: sessionRow, in: db, outcome: &outcome)
            }
            guard ok, db.exec("COMMIT") else {
                db.exec("ROLLBACK")
                return false
            }
        }
        return true
    }

    private struct MessageRow {
        let id: Int64
        let sessionRow: Int64
        let seq: Int64
        let role: String
        let excerpt: String
    }

    private func trim(sessionRow: Int64, in db: Connection, outcome: inout Outcome) -> Bool {
        // Re-read inside the transaction: the kit may have re-indexed this
        // session (new row ids) between the victim query and now.
        var rows: [MessageRow] = []
        let read = db.query(
            "SELECT id, session_row, seq, role, excerpt FROM session_messages WHERE session_row = ?1 ORDER BY seq, id",
            binds: [sessionRow]
        ) { statement in
            rows.append(MessageRow(
                id: sqlite3_column_int64(statement, 0),
                sessionRow: sqlite3_column_int64(statement, 1),
                seq: sqlite3_column_int64(statement, 2),
                role: sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "",
                excerpt: sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? ""
            ))
        }
        guard read else { return false }

        var budget = policy.sessionExcerptBytes
        var dropFrom: Int? = nil
        var trims: [(row: MessageRow, text: String)] = []
        for (index, row) in rows.enumerated() {
            let role = SessionRole(rawValue: row.role) ?? .system
            let cap = policy.excerptCharacters(for: role)
            // `+ 1` for the ellipsis `truncate` appends: a row the kit (or a
            // previous pass) already truncated to exactly cap+1 characters
            // is compliant and must not be rewritten every day.
            let needsTrim = row.excerpt.count > cap + 1
            let text = needsTrim ? SessionParsing.truncate(row.excerpt, limit: cap) : row.excerpt
            let cost = text.utf8.count
            if cost > budget {
                dropFrom = index
                break
            }
            budget -= cost
            if needsTrim { trims.append((row, text)) }
        }

        let dropped = dropFrom.map { Array(rows[$0...]) } ?? []
        guard !dropped.isEmpty || !trims.isEmpty else { return true }

        for row in dropped {
            guard db.run("DELETE FROM session_messages WHERE id = ?1", binds: [row.id]) else { return false }
        }
        for (row, text) in trims {
            // Delete + insert so the FTS triggers fire; an UPDATE would
            // silently desynchronize the external-content index.
            guard db.run("DELETE FROM session_messages WHERE id = ?1", binds: [row.id]),
                  db.run(
                    "INSERT INTO session_messages(id, session_row, seq, role, excerpt) VALUES(?1, ?2, ?3, ?4, ?5)",
                    binds: [row.id, row.sessionRow, row.seq, row.role, text]
                  )
            else { return false }
        }
        outcome.sessionsTrimmed += 1
        outcome.messagesDropped += dropped.count
        outcome.messagesTrimmed += trims.count
        return true
    }

    // MARK: - Merge

    /// FTS5's incremental optimize: a negative argument schedules a merge
    /// of *all* segments, then each positive call does about that many
    /// pages of work in its own transaction. Done when a step changes
    /// fewer than two rows.
    private func mergePass(_ db: Connection, outcome: inout Outcome, deadline: Date) -> Bool {
        guard db.exec("INSERT INTO session_fts(session_fts, rank) VALUES('merge', -500)") else {
            return false
        }
        while outcome.mergeSteps < 100_000 {
            guard Date() < deadline else { return false }
            let before = db.totalChanges
            guard db.exec("INSERT INTO session_fts(session_fts, rank) VALUES('merge', 500)") else {
                return false
            }
            outcome.mergeSteps += 1
            if db.totalChanges - before < 2 { return true }
        }
        return true
    }

    // MARK: - Reclaim

    private func reclaimPass(_ db: Connection, outcome: inout Outcome, deadline: Date) -> Bool {
        let pageSize = db.int("PRAGMA page_size")
        if db.int("PRAGMA auto_vacuum") != 2 {
            // One-time conversion. VACUUM rewrites the file, so demand the
            // live bytes plus margin in free space, and accept that a busy
            // writer can bounce it — the stamp stays unwritten and the next
            // pass tries again.
            let liveBytes = (db.int("PRAGMA page_count") - db.int("PRAGMA freelist_count")) * pageSize
            guard freeDiskBytes() > liveBytes + 512 * 1_048_576 else { return false }
            guard db.exec("PRAGMA auto_vacuum = INCREMENTAL"), db.exec("VACUUM") else {
                return false
            }
            outcome.ranFullVacuum = true
            return true
        }
        // 8 192 pages ≈ 32 MB returned per bounded step.
        while db.int("PRAGMA freelist_count") > 1_024 {
            guard Date() < deadline else { return false }
            guard db.exec("PRAGMA incremental_vacuum(8192)") else { return false }
        }
        return true
    }

    private func freeDiskBytes() -> Int64 {
        let values = try? databaseURL.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: - Scratch sweep

    /// Head copies are deleted by their creator; anything still here is a
    /// crash leftover once it is a day old.
    private func sweepScratch(now: Date) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: scratchDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > 24 * 60 * 60 {
                try? fileManager.removeItem(at: entry)
            }
        }
    }
}

// MARK: - SQLite plumbing

/// Minimal wrapper over one read-write connection. Not shared with
/// `TimelineSQLite` because this one must *not* create a missing database:
/// no index means nothing to maintain.
private final class Connection {
    private let handle: OpaquePointer
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(url: URL) {
        var opened: OpaquePointer?
        guard sqlite3_open_v2(
            url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK, let opened else {
            if opened != nil { sqlite3_close_v2(opened) }
            return nil
        }
        sqlite3_busy_timeout(opened, 5_000)
        sqlite3_exec(opened, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(opened, "PRAGMA synchronous=NORMAL", nil, nil, nil)
        handle = opened
    }

    func close() {
        sqlite3_close_v2(handle)
    }

    var totalChanges: Int64 {
        sqlite3_total_changes64(handle)
    }

    @discardableResult
    func exec(_ sql: String) -> Bool {
        sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
    }

    func hasTable(_ name: String) -> Bool {
        int("SELECT COUNT(*) FROM sqlite_schema WHERE name = '\(name)'") > 0
    }

    /// First column of the first row, or 0.
    func int(_ sql: String) -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return 0
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    /// First column of every row.
    func column(_ sql: String, binds: [Int64]) -> [Int64] {
        var out: [Int64] = []
        _ = query(sql, binds: binds) { out.append(sqlite3_column_int64($0, 0)) }
        return out
    }

    func query(_ sql: String, binds: [Int64], row: (OpaquePointer) -> Void) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in binds.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), value)
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row(statement)
            case SQLITE_DONE: return true
            default: return false
            }
        }
    }

    /// Mixed-type binds for the trim writes.
    @discardableResult
    func run(_ sql: String, binds: [Any]) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in binds.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let number as Int64: sqlite3_bind_int64(statement, position, number)
            case let text as String: sqlite3_bind_text(statement, position, text, -1, transient)
            default: sqlite3_bind_null(statement, position)
            }
        }
        return sqlite3_step(statement) == SQLITE_DONE
    }
}
