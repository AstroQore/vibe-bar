import Foundation
import SQLite3

public enum SessionIndexError: Error, Sendable {
    /// The SQLite file could not be opened or migrated.
    case open
    /// A statement failed to prepare, bind, or step.
    case statement
}

/// One search result: the session that matched, plus where in it.
public struct SessionSearchHit: Hashable, Sendable {
    public let summary: SessionSummary
    /// FTS5 snippet with `<b>` markers around the match, or nil when the
    /// hit came from the session's own metadata rather than its body.
    public let snippet: String?
    /// Position of the matching message inside the transcript, so a UI
    /// can open the transcript scrolled to it.
    public let matchedSeq: Int?

    public init(summary: SessionSummary, snippet: String?, matchedSeq: Int?) {
        self.summary = summary
        self.snippet = snippet
        self.matchedSeq = matchedSeq
    }
}

/// Persistent index over every discovered session.
///
/// Three tables and a virtual one:
///
/// - `sessions` — one row per discovered session, keyed by
///   `(provider, session_id, source_path)` because the same id can
///   legitimately appear under two roots;
/// - `session_files` — the incremental-scan cursor: a hashed path, the
///   fingerprint last indexed at, and the session it produced;
/// - `session_messages` — per-message excerpts, only written when body
///   indexing is enabled;
/// - `session_fts` — an external-content FTS5 table over those excerpts,
///   kept in sync by triggers.
///
/// The tokenizer is `trigram`, not the default unicode61: it is the only
/// built-in tokenizer that matches *inside* words, which is what makes
/// substring search work for CJK text (no word spacing) and for
/// identifiers alike. Its cost is that queries shorter than three
/// characters cannot be answered at all — `search` falls back to `LIKE`
/// for those.
///
/// Everything here is reconstructible from the CLIs' own session logs, so
/// a schema-version mismatch drops and rebuilds instead of migrating.
public actor SessionIndexStore {
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Bumping this drops and rebuilds every table on the next open.
    ///
    /// v2 added `sessions.harness` and `sessions.model`. There is no ALTER
    /// path on purpose: every row is reconstructible from the CLIs' own
    /// logs, and a rebuild is what fills the new columns anyway.
    static let schemaVersion = 2

    public init(url: URL = VibeBarLocalStore.sessionIndexURL) throws {
        if url == VibeBarLocalStore.sessionIndexURL {
            try VibeBarLocalStore.ensureBaseDirectory()
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle
        else {
            if handle != nil { sqlite3_close_v2(handle) }
            throw SessionIndexError.open
        }
        sqlite3_busy_timeout(handle, 5_000)
        do {
            try Self.initialize(handle)
            database = handle
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close_v2(database) }
    }

    // MARK: - Schema

    private static func initialize(_ database: OpaquePointer) throws {
        let preamble = """
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            PRAGMA foreign_keys=ON;
            """
        guard sqlite3_exec(database, preamble, nil, nil, nil) == SQLITE_OK else {
            throw SessionIndexError.open
        }
        if storedSchemaVersion(database) != schemaVersion {
            guard sqlite3_exec(database, dropSQL, nil, nil, nil) == SQLITE_OK else {
                throw SessionIndexError.open
            }
        }
        guard sqlite3_exec(database, schemaSQL, nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(database, "PRAGMA user_version = \(schemaVersion)", nil, nil, nil) == SQLITE_OK
        else {
            throw SessionIndexError.open
        }
    }

    private static func storedSchemaVersion(_ database: OpaquePointer) -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Triggers first, then the virtual table, then the content tables —
    /// dropping an external-content FTS5 table after its content table is
    /// gone still works, but the order keeps the intent readable.
    private static let dropSQL = """
        DROP TRIGGER IF EXISTS session_messages_ai;
        DROP TRIGGER IF EXISTS session_messages_ad;
        DROP TABLE IF EXISTS session_fts;
        DROP TABLE IF EXISTS session_messages;
        DROP TABLE IF EXISTS session_files;
        DROP TABLE IF EXISTS sessions;
        DROP TABLE IF EXISTS session_index_meta;
        """

    private static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS session_index_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sessions (
            id INTEGER PRIMARY KEY,
            provider TEXT NOT NULL,
            session_id TEXT NOT NULL,
            provider_variant TEXT,
            harness TEXT,
            model TEXT,
            title TEXT,
            summary TEXT,
            project_dir TEXT,
            created_at INTEGER,
            last_active_at INTEGER,
            source_path TEXT NOT NULL,
            size_bytes INTEGER NOT NULL DEFAULT 0,
            message_count INTEGER NOT NULL DEFAULT -1,
            UNIQUE(provider, session_id, source_path)
        );
        CREATE INDEX IF NOT EXISTS sessions_last_active_idx
            ON sessions(last_active_at DESC);
        CREATE INDEX IF NOT EXISTS sessions_effective_active_idx
            ON sessions(COALESCE(last_active_at, created_at) DESC, id DESC);
        CREATE INDEX IF NOT EXISTS sessions_provider_effective_active_idx
            ON sessions(provider, COALESCE(last_active_at, created_at) DESC, id DESC);
        CREATE INDEX IF NOT EXISTS sessions_provider_project_idx
            ON sessions(provider, project_dir);
        CREATE INDEX IF NOT EXISTS sessions_harness_effective_active_idx
            ON sessions(harness, COALESCE(last_active_at, created_at) DESC, id DESC);
        CREATE TABLE IF NOT EXISTS session_files (
            path_hash TEXT PRIMARY KEY,
            path TEXT NOT NULL,
            provider TEXT NOT NULL,
            mtime_ns INTEGER NOT NULL,
            size INTEGER NOT NULL,
            session_row INTEGER REFERENCES sessions(id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS session_messages (
            id INTEGER PRIMARY KEY,
            session_row INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            seq INTEGER NOT NULL,
            role TEXT NOT NULL,
            excerpt TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS session_messages_row_idx
            ON session_messages(session_row, seq);
        CREATE VIRTUAL TABLE IF NOT EXISTS session_fts USING fts5(
            excerpt,
            content='session_messages',
            content_rowid='id',
            tokenize='trigram'
        );
        CREATE TRIGGER IF NOT EXISTS session_messages_ai
        AFTER INSERT ON session_messages BEGIN
            INSERT INTO session_fts(rowid, excerpt) VALUES (new.id, new.excerpt);
        END;
        CREATE TRIGGER IF NOT EXISTS session_messages_ad
        AFTER DELETE ON session_messages BEGIN
            INSERT INTO session_fts(session_fts, rowid, excerpt)
                VALUES('delete', old.id, old.excerpt);
        END;
        """

    // MARK: - Writes

    /// Insert or refresh one session, returning its row id.
    ///
    /// The harness column is never left null: a summary that arrived without
    /// one is stored under `provider.defaultHarness`, so the harness filter
    /// below is total and no row can hide from every chip.
    @discardableResult
    public func upsertSession(_ summary: SessionSummary) throws -> Int64 {
        try run(
            """
            INSERT INTO sessions(
                   provider, session_id, provider_variant, harness, model,
                   title, summary, project_dir,
                   created_at, last_active_at, source_path, size_bytes, message_count
               ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(provider, session_id, source_path) DO UPDATE SET
                   provider_variant = excluded.provider_variant,
                   harness = excluded.harness,
                   model = excluded.model,
                   title = excluded.title,
                   summary = excluded.summary,
                   project_dir = excluded.project_dir,
                   created_at = excluded.created_at,
                   last_active_at = excluded.last_active_at,
                   size_bytes = excluded.size_bytes,
                   message_count = excluded.message_count
            """,
            [
                .text(summary.provider.rawValue),
                .text(summary.sessionID),
                summary.providerVariant.map(Binding.text) ?? .null,
                .text(summary.effectiveHarness.rawValue),
                summary.model.map(Binding.text) ?? .null,
                summary.title.map(Binding.text) ?? .null,
                summary.summary.map(Binding.text) ?? .null,
                summary.projectDir.map(Binding.text) ?? .null,
                summary.createdAt.map { .integer(Self.epoch($0)) } ?? .null,
                summary.lastActiveAt.map { .integer(Self.epoch($0)) } ?? .null,
                .text(summary.sourcePath),
                .integer(summary.sizeBytes),
                .integer(Int64(summary.messageCount))
            ]
        )
        guard let row = try scalarInt(
            """
            SELECT id FROM sessions
             WHERE provider = ? AND session_id = ? AND source_path = ?
            """,
            [.text(summary.provider.rawValue), .text(summary.sessionID), .text(summary.sourcePath)]
        ) else { throw SessionIndexError.statement }
        return row
    }

    public struct MessageExcerpt: Hashable, Sendable {
        public let seq: Int
        public let role: SessionRole
        public let excerpt: String

        public init(seq: Int, role: SessionRole, excerpt: String) {
            self.seq = seq
            self.role = role
            self.excerpt = excerpt
        }
    }

    /// Replace every indexed excerpt for one session. The delete trigger
    /// clears the old FTS rows, so this is also how a shrinking
    /// transcript stops matching its removed text.
    public func replaceMessages(sessionRow: Int64, excerpts: [MessageExcerpt]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try run("DELETE FROM session_messages WHERE session_row = ?", [.integer(sessionRow)])
            if !excerpts.isEmpty {
                let statement = try prepare(
                    "INSERT INTO session_messages(session_row, seq, role, excerpt) VALUES(?, ?, ?, ?)"
                )
                defer { sqlite3_finalize(statement) }
                for excerpt in excerpts {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    bindAll([
                        .integer(sessionRow),
                        .integer(Int64(excerpt.seq)),
                        .text(excerpt.role.rawValue),
                        .text(excerpt.excerpt)
                    ], to: statement)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw SessionIndexError.statement
                    }
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Fingerprint of a file as of its last successful index pass.
    public struct FileCursor: Hashable, Sendable {
        public let mtimeNanos: Int64
        public let size: Int64
        public let sessionRow: Int64?

        public init(mtimeNanos: Int64, size: Int64, sessionRow: Int64?) {
            self.mtimeNanos = mtimeNanos
            self.size = size
            self.sessionRow = sessionRow
        }
    }

    public func fileCursor(pathHash: String) throws -> FileCursor? {
        let statement = try prepare(
            "SELECT mtime_ns, size, session_row FROM session_files WHERE path_hash = ?"
        )
        defer { sqlite3_finalize(statement) }
        bindAll([.text(pathHash)], to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw SessionIndexError.statement }
        return FileCursor(
            mtimeNanos: sqlite3_column_int64(statement, 0),
            size: sqlite3_column_int64(statement, 1),
            sessionRow: sqlite3_column_type(statement, 2) == SQLITE_NULL
                ? nil : sqlite3_column_int64(statement, 2)
        )
    }

    public func saveFileCursor(
        pathHash: String,
        path: String,
        provider: SessionProvider,
        mtimeNanos: Int64,
        size: Int64,
        sessionRow: Int64?
    ) throws {
        try run(
            """
            INSERT INTO session_files(path_hash, path, provider, mtime_ns, size, session_row)
               VALUES(?, ?, ?, ?, ?, ?)
               ON CONFLICT(path_hash) DO UPDATE SET
                   path = excluded.path,
                   provider = excluded.provider,
                   mtime_ns = excluded.mtime_ns,
                   size = excluded.size,
                   session_row = excluded.session_row
            """,
            [
                .text(pathHash), .text(path), .text(provider.rawValue),
                .integer(mtimeNanos), .integer(size),
                sessionRow.map(Binding.integer) ?? .null
            ]
        )
    }

    /// Forget the sessions that came from these paths, and the cursors
    /// pointing at them.
    public func removeSessions(sourcePathIn paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            for path in paths {
                try run("DELETE FROM sessions WHERE source_path = ?", [.text(path)])
                try run("DELETE FROM session_files WHERE path = ?", [.text(path)])
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Drop every file whose hash is no longer on disk, together with the
    /// session it produced. Returns how many files were pruned.
    @discardableResult
    public func pruneMissing(existingPathHashes: Set<String>) throws -> Int {
        var stale: [(hash: String, row: Int64?)] = []
        let statement = try prepare("SELECT path_hash, session_row FROM session_files")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let hash = columnText(statement, 0) else { continue }
            guard !existingPathHashes.contains(hash) else { continue }
            stale.append((
                hash,
                sqlite3_column_type(statement, 1) == SQLITE_NULL
                    ? nil : sqlite3_column_int64(statement, 1)
            ))
        }
        guard !stale.isEmpty else { return 0 }

        try execute("BEGIN IMMEDIATE")
        do {
            for entry in stale {
                if let row = entry.row {
                    // Cascades through session_messages (and its FTS
                    // trigger) and through session_files.
                    try run("DELETE FROM sessions WHERE id = ?", [.integer(row)])
                }
                try run("DELETE FROM session_files WHERE path_hash = ?", [.text(entry.hash)])
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        return stale.count
    }

    /// Drop every indexed excerpt, keeping the session rows. This is what
    /// switching body indexing off means: metadata search still works,
    /// nothing of the transcripts is left on disk.
    public func dropBodyIndex() throws {
        try run("DELETE FROM session_messages", [])
    }

    /// Forget every scan cursor, so the next refresh re-reads all files.
    /// Session rows survive — they are re-upserted in place, which keeps
    /// row ids (and any UI selection keyed on them) stable.
    public func resetFileCursors() throws {
        try run("DELETE FROM session_files", [])
    }

    private static let bodyIndexingKey = "body_indexing"

    /// Whether the last completed refresh indexed message bodies. `nil`
    /// before the first refresh. Turning the setting back on has to
    /// re-read files whose fingerprint never moved, and this is how that
    /// transition is noticed.
    public func bodyIndexingMode() throws -> Bool? {
        let statement = try prepare("SELECT value FROM session_index_meta WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        bindAll([.text(Self.bodyIndexingKey)], to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw SessionIndexError.statement }
        return columnText(statement, 0) == "1"
    }

    public func setBodyIndexingMode(_ enabled: Bool) throws {
        try run(
            """
            INSERT INTO session_index_meta(key, value) VALUES(?, ?)
               ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            [.text(Self.bodyIndexingKey), .text(enabled ? "1" : "0")]
        )
    }

    /// Wipe every row. The schema stays, so the next refresh rebuilds the
    /// index without reopening the database.
    public func eraseAll() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM session_messages")
            try execute("DELETE FROM session_files")
            try execute("DELETE FROM sessions")
            try execute("DELETE FROM session_index_meta")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Reads

    /// Fixed order, and new columns go on the end: the search queries select
    /// `s.id` and the match columns straight after this list, and address
    /// them by index.
    private static let sessionColumns = """
        s.provider, s.session_id, s.provider_variant, s.title, s.summary, s.project_dir,
        s.created_at, s.last_active_at, s.source_path, s.size_bytes, s.message_count,
        s.harness, s.model
        """
    /// Column index of `s.id` in a `SELECT sessionColumns, s.id, …`.
    private static let rowIDColumn: Int32 = 13

    /// Every indexed session, most recently active first.
    public func allSummaries() throws -> [SessionSummary] {
        let statement = try prepare(
            """
            SELECT \(Self.sessionColumns) FROM sessions s
             ORDER BY s.last_active_at IS NULL, s.last_active_at DESC, s.id DESC
            """
        )
        defer { sqlite3_finalize(statement) }
        var out: [SessionSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let summary = self.summary(statement, offset: 0) { out.append(summary) }
        }
        return out
    }

    /// One filtered, ordered page. This is the product read path; the unbounded
    /// `allSummaries()` remains for tests and maintenance tools.
    public func summaryPage(
        providers: [SessionProvider]? = nil,
        harnesses: [Harness]? = nil,
        since: Date? = nil,
        order: SessionSummaryOrder = .recentFirst,
        offset: Int = 0,
        limit: Int = 250
    ) throws -> SessionSummaryPage {
        if let providers, providers.isEmpty {
            return SessionSummaryPage(summaries: [], totalCount: 0, offset: 0, limit: max(1, limit))
        }
        if let harnesses, harnesses.isEmpty {
            return SessionSummaryPage(summaries: [], totalCount: 0, offset: 0, limit: max(1, limit))
        }
        let safeOffset = max(0, offset)
        let safeLimit = min(max(1, limit), 500)
        var clauses: [String] = []
        var bindings: [Binding] = []
        if let providers {
            clauses.append("s.provider IN (\(Array(repeating: "?", count: providers.count).joined(separator: ", ")))")
            bindings.append(contentsOf: providers.map { .text($0.rawValue) })
        }
        if let harnesses {
            clauses.append("s.harness IN (\(Array(repeating: "?", count: harnesses.count).joined(separator: ", ")))")
            bindings.append(contentsOf: harnesses.map { .text($0.rawValue) })
        }
        if let since {
            clauses.append("COALESCE(s.last_active_at, s.created_at) >= ?")
            bindings.append(.integer(Int64(since.timeIntervalSince1970.rounded(.down))))
        }
        let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let orderSQL: String
        switch order {
        case .recentFirst:
            orderSQL = "COALESCE(s.last_active_at, s.created_at) DESC, s.id DESC"
        case .oldestFirst:
            orderSQL = "COALESCE(s.last_active_at, s.created_at) ASC, s.id ASC"
        case .byProject:
            orderSQL = "s.project_dir IS NULL, s.project_dir COLLATE NOCASE ASC, "
                + "COALESCE(s.last_active_at, s.created_at) DESC, s.id DESC"
        }

        let total = Int(try scalarInt(
            "SELECT COUNT(*) FROM sessions s\(whereSQL)",
            bindings
        ) ?? 0)
        let statement = try prepare(
            """
            SELECT \(Self.sessionColumns) FROM sessions s\(whereSQL)
             ORDER BY \(orderSQL) LIMIT ? OFFSET ?
            """
        )
        defer { sqlite3_finalize(statement) }
        bindAll(bindings + [.integer(Int64(safeLimit)), .integer(Int64(safeOffset))], to: statement)
        var out: [SessionSummary] = []
        out.reserveCapacity(min(safeLimit, total))
        while sqlite3_step(statement) == SQLITE_ROW {
            if let summary = self.summary(statement, offset: 0) { out.append(summary) }
        }
        return SessionSummaryPage(
            summaries: out,
            totalCount: total,
            offset: safeOffset,
            limit: safeLimit
        )
    }

    public func providerCounts() throws -> [SessionProvider: Int] {
        let statement = try prepare("SELECT provider, COUNT(*) FROM sessions GROUP BY provider")
        defer { sqlite3_finalize(statement) }
        var counts: [SessionProvider: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = columnText(statement, 0), let provider = SessionProvider(rawValue: raw) else {
                continue
            }
            counts[provider] = Int(sqlite3_column_int64(statement, 1))
        }
        return counts
    }

    /// Row count per harness — what the Sessions page's company chips and
    /// source menu label themselves with. Rows written before the harness
    /// column existed cannot occur (the schema bump rebuilds), so a row that
    /// somehow has no harness is skipped rather than invented.
    public func harnessCounts() throws -> [Harness: Int] {
        let statement = try prepare(
            "SELECT harness, COUNT(*) FROM sessions WHERE harness IS NOT NULL GROUP BY harness"
        )
        defer { sqlite3_finalize(statement) }
        var counts: [Harness: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = columnText(statement, 0), let harness = Harness(rawValue: raw) else {
                continue
            }
            counts[harness] = Int(sqlite3_column_int64(statement, 1))
        }
        return counts
    }

    public func sessionCount() throws -> Int {
        Int(try scalarInt("SELECT COUNT(*) FROM sessions", []) ?? 0)
    }

    public func messageCount() throws -> Int {
        Int(try scalarInt("SELECT COUNT(*) FROM session_messages", []) ?? 0)
    }

    /// Substring search over indexed message bodies *and* session
    /// metadata, best match first, at most one hit per session.
    public func search(
        text: String,
        providers: [SessionProvider]? = nil,
        harnesses: [Harness]? = nil,
        limit: Int = 50
    ) throws -> [SessionSearchHit] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        if let providers, providers.isEmpty { return [] }
        if let harnesses, harnesses.isEmpty { return [] }
        let cap = min(max(1, limit), 500)
        let scope = Scope(providers: providers, harnesses: harnesses)

        var hits: [SessionSearchHit] = []
        var seen: Set<Int64> = []
        for row in try bodyMatches(needle, scope: scope, limit: cap) {
            guard seen.insert(row.rowID).inserted else { continue }
            hits.append(row.hit)
            if hits.count >= cap { return hits }
        }
        for row in try metadataMatches(needle, scope: scope, limit: cap) {
            guard seen.insert(row.rowID).inserted else { continue }
            hits.append(row.hit)
            if hits.count >= cap { return hits }
        }
        return hits
    }

    /// The trigram tokenizer indexes three-character sequences, so a
    /// one- or two-character query has nothing to match against. Those
    /// fall back to a bounded `LIKE` scan, which is slow in principle and
    /// fine in practice at this table's size.
    static let minimumTrigramLength = 3
    private static let likeScanLimit = 200

    /// What a search is narrowed to. Both dimensions are optional and are
    /// ANDed, which is what lets a company chip (harnesses) and an explicit
    /// provider list live in the same query.
    private struct Scope {
        let providers: [SessionProvider]?
        let harnesses: [Harness]?
    }

    private func bodyMatches(
        _ needle: String,
        scope: Scope,
        limit: Int
    ) throws -> [(rowID: Int64, hit: SessionSearchHit)] {
        let filter = scopeFilter(scope)
        let sql: String
        var bindings: [Binding]
        if needle.count >= Self.minimumTrigramLength {
            sql = """
                SELECT \(Self.sessionColumns), s.id, m.seq,
                       snippet(session_fts, 0, '<b>', '</b>', '…', 12)
                  FROM session_fts
                  JOIN session_messages m ON m.id = session_fts.rowid
                  JOIN sessions s ON s.id = m.session_row
                 WHERE session_fts MATCH ?\(filter.sql)
                 ORDER BY rank LIMIT ?
                """
            bindings = [.text(Self.ftsQuery(needle))] + filter.bindings + [.integer(Int64(limit))]
        } else {
            sql = """
                SELECT \(Self.sessionColumns), s.id, m.seq, m.excerpt
                  FROM session_messages m
                  JOIN sessions s ON s.id = m.session_row
                 WHERE m.excerpt LIKE ? ESCAPE '\\'\(filter.sql)
                 ORDER BY m.id LIMIT ?
                """
            bindings = [.text("%" + Self.likePattern(needle) + "%")]
                + filter.bindings
                + [.integer(Int64(min(limit, Self.likeScanLimit)))]
        }

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bindAll(bindings, to: statement)

        var out: [(rowID: Int64, hit: SessionSearchHit)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let summary = summary(statement, offset: 0) else { continue }
            out.append((
                sqlite3_column_int64(statement, Self.rowIDColumn),
                SessionSearchHit(
                    summary: summary,
                    snippet: columnText(statement, Self.rowIDColumn + 2),
                    matchedSeq: Int(sqlite3_column_int64(statement, Self.rowIDColumn + 1))
                )
            ))
        }
        return out
    }

    private func metadataMatches(
        _ needle: String,
        scope: Scope,
        limit: Int
    ) throws -> [(rowID: Int64, hit: SessionSearchHit)] {
        let filter = scopeFilter(scope)
        let statement = try prepare(
            """
            SELECT \(Self.sessionColumns), s.id FROM sessions s
             WHERE (s.title LIKE ? ESCAPE '\\'
                 OR s.summary LIKE ? ESCAPE '\\'
                 OR s.project_dir LIKE ? ESCAPE '\\')\(filter.sql)
             ORDER BY s.last_active_at IS NULL, s.last_active_at DESC, s.id DESC
             LIMIT ?
            """
        )
        defer { sqlite3_finalize(statement) }
        let pattern = "%" + Self.likePattern(needle) + "%"
        bindAll(
            [.text(pattern), .text(pattern), .text(pattern)]
                + filter.bindings
                + [.integer(Int64(limit))],
            to: statement
        )

        var out: [(rowID: Int64, hit: SessionSearchHit)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let summary = summary(statement, offset: 0) else { continue }
            out.append((
                sqlite3_column_int64(statement, Self.rowIDColumn),
                SessionSearchHit(summary: summary, snippet: nil, matchedSeq: nil)
            ))
        }
        return out
    }

    private func scopeFilter(_ scope: Scope) -> (sql: String, bindings: [Binding]) {
        var sql = ""
        var bindings: [Binding] = []
        if let providers = scope.providers, !providers.isEmpty {
            let marks = Array(repeating: "?", count: providers.count).joined(separator: ", ")
            sql += " AND s.provider IN (\(marks))"
            bindings.append(contentsOf: providers.map { .text($0.rawValue) })
        }
        if let harnesses = scope.harnesses, !harnesses.isEmpty {
            let marks = Array(repeating: "?", count: harnesses.count).joined(separator: ", ")
            sql += " AND s.harness IN (\(marks))"
            bindings.append(contentsOf: harnesses.map { .text($0.rawValue) })
        }
        return (sql, bindings)
    }

    /// FTS5 `MATCH` takes a query language, not a literal: bare `AND`,
    /// `*`, `:`, `-` and friends are operators. Wrapping the whole needle
    /// in double quotes turns it into one phrase, and doubling any
    /// embedded quote keeps that wrapper from being closed early — so no
    /// user input can reach the parser as syntax.
    static func ftsQuery(_ raw: String) -> String {
        "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// `LIKE` wildcards escaped against a literal `\` escape character.
    static func likePattern(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - Row decoding

    private func summary(_ statement: OpaquePointer, offset: Int32) -> SessionSummary? {
        guard let rawProvider = columnText(statement, offset),
              let provider = SessionProvider(rawValue: rawProvider),
              let sessionID = columnText(statement, offset + 1),
              let sourcePath = columnText(statement, offset + 8)
        else { return nil }
        return SessionSummary(
            provider: provider,
            sessionID: sessionID,
            providerVariant: columnText(statement, offset + 2),
            harness: columnText(statement, offset + 11).flatMap(Harness.init(rawValue:)),
            model: columnText(statement, offset + 12),
            title: columnText(statement, offset + 3),
            summary: columnText(statement, offset + 4),
            projectDir: columnText(statement, offset + 5),
            createdAt: date(statement, offset + 6),
            lastActiveAt: date(statement, offset + 7),
            sourcePath: sourcePath,
            sizeBytes: sqlite3_column_int64(statement, offset + 9),
            messageCount: Int(sqlite3_column_int64(statement, offset + 10))
        )
    }

    private func date(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, index)))
    }

    private static func epoch(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded())
    }

    // MARK: - SQLite plumbing

    private enum Binding {
        case text(String)
        case integer(Int64)
        case null
    }

    private func execute(_ sql: String) throws {
        guard let database, sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SessionIndexError.statement
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard let database,
              sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            if statement != nil { sqlite3_finalize(statement) }
            throw SessionIndexError.statement
        }
        return statement
    }

    private func run(_ sql: String, _ bindings: [Binding]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bindAll(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SessionIndexError.statement
        }
    }

    private func scalarInt(_ sql: String, _ bindings: [Binding]) throws -> Int64? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bindAll(bindings, to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw SessionIndexError.statement }
        return sqlite3_column_int64(statement, 0)
    }

    private func bindAll(_ bindings: [Binding], to statement: OpaquePointer) {
        for (index, value) in bindings.enumerated() {
            switch value {
            case let .text(text):
                sqlite3_bind_text(statement, Int32(index + 1), text, -1, transient)
            case let .integer(integer):
                sqlite3_bind_int64(statement, Int32(index + 1), integer)
            case .null:
                sqlite3_bind_null(statement, Int32(index + 1))
            }
        }
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: raw)
    }
}
