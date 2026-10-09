import Foundation
import SQLite3

/// A file's identity for cache purposes: modification time to the
/// nanosecond plus size. Either moving invalidates a cached parse.
public struct SessionFileFingerprint: Hashable, Sendable, Codable {
    public var mtimeNs: Int64
    public var size: Int64

    public init(mtimeNs: Int64, size: Int64) {
        self.mtimeNs = mtimeNs
        self.size = size
    }

    /// `stat(2)` of a regular file; nil when it is missing or not a file.
    public static func of(path: String) -> SessionFileFingerprint? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let nanos = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return SessionFileFingerprint(mtimeNs: nanos, size: Int64(info.st_size))
    }
}

/// One cached parse: stats, the per-turn outline and the Claude sidechain
/// rollups (counts, usage, models), no message bodies.
public struct SessionStructureRecord: Hashable, Sendable, Codable {
    public var sourcePath: String
    public var fingerprint: SessionFileFingerprint
    public var provider: SessionProvider
    public var sessionID: String?
    public var kind: SessionStructureKind
    public var parentID: String?
    public var relation: SessionStructureRelation?
    public var stats: SessionStats
    public var outline: [SessionTurnOutline]
    public var sidechains: [SessionStructure.SidechainRollup]
    public var parsedAt: Date
    public var parserVersion: Int

    public init(
        structure: SessionStructure,
        fingerprint: SessionFileFingerprint,
        parsedAt: Date = Date(),
        parserVersion: Int = SessionStructure.parserVersion
    ) {
        sourcePath = structure.sourcePath
        self.fingerprint = fingerprint
        provider = structure.provider
        sessionID = structure.sessionID
        kind = structure.stats.kind
        parentID = structure.stats.parentID
        relation = structure.stats.relation
        stats = structure.stats
        outline = structure.outline
        sidechains = structure.sidechains
        self.parsedAt = parsedAt
        self.parserVersion = parserVersion
    }

    /// The outline-detail structure this record stands for.
    public var structure: SessionStructure {
        SessionStructure(
            provider: provider,
            sessionID: sessionID,
            sourcePath: sourcePath,
            detail: .outline,
            turns: outline.map(\.turn),
            stats: stats,
            sidechains: sidechains
        )
    }
}

/// `~/.vibebar/session_structure.sqlite3`: the host-side sidecar that keeps
/// each session file's structure outline and stats between launches.
///
/// It is derived data in the same sense as `session_index.sqlite3`, but a
/// separate file on purpose: the kit's index schema is a cross-language
/// contract this app does not extend. Rows are keyed by `source_path` and
/// valid only for the `(mtime_ns, size)` they were parsed at and for the
/// current `SessionStructure.parserVersion`; a stale row is a miss, and rows
/// from another parser version are purged on open.
///
/// An actor over one WAL connection. If the database cannot be opened (or
/// is corrupt and cannot be recreated) the store degrades to "always miss":
/// nothing throws and nothing crashes, the caller just parses again.
public actor SessionStructureStore {
    /// Table layout version (`PRAGMA user_version`). A different value
    /// drops and recreates the table.
    ///
    /// v2: `sidechains_json`.
    static let schemaVersion: Int32 = 2

    public let url: URL
    private let parserVersion: Int
    private var database: TimelineSQLite?
    private var didOpen = false
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL = VibeBarLocalStore.sessionStructureURL, parserVersion: Int = SessionStructure.parserVersion) {
        self.url = url
        self.parserVersion = parserVersion
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    deinit {
        database?.close()
    }

    /// Whether the database opened. Opening happens on first use.
    public var isAvailable: Bool { openIfNeeded() != nil }

    // MARK: Reads

    /// The cached record for `path`, only if it was parsed at exactly
    /// `fingerprint` by the current parser.
    public func record(forPath path: String, fingerprint: SessionFileFingerprint) -> SessionStructureRecord? {
        guard let record = record(forPath: path),
              record.fingerprint == fingerprint,
              record.parserVersion == parserVersion
        else { return nil }
        return record
    }

    /// The cached record for `path` regardless of freshness.
    public func record(forPath path: String) -> SessionStructureRecord? {
        guard let database = openIfNeeded(),
              let statement = database.prepare("""
                SELECT source_path, mtime_ns, size, provider, session_id, kind, parent_id, relation,
                       stats_json, outline_json, parsed_at, parser_version, sidechains_json
                FROM session_structure WHERE source_path = ?1
                """)
        else { return nil }
        defer { sqlite3_finalize(statement) }
        database.bindText(statement, 1, path)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return decodeRow(statement, database: database)
    }

    /// Records whose `parent_id` is `parentID` (forks, subagents, reviews).
    public func records(withParentID parentID: String) -> [SessionStructureRecord] {
        guard let database = openIfNeeded(),
              let statement = database.prepare("""
                SELECT source_path, mtime_ns, size, provider, session_id, kind, parent_id, relation,
                       stats_json, outline_json, parsed_at, parser_version, sidechains_json
                FROM session_structure WHERE parent_id = ?1 AND parser_version = ?2
                ORDER BY source_path
                """)
        else { return [] }
        defer { sqlite3_finalize(statement) }
        database.bindText(statement, 1, parentID)
        sqlite3_bind_int64(statement, 2, Int64(parserVersion))
        var rows: [SessionStructureRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let record = decodeRow(statement, database: database) { rows.append(record) }
        }
        return rows
    }

    /// What the Sessions list shows for each fresh row — its stats and its
    /// first prompt preview — in one prepared statement for the whole
    /// batch, reading only each outline entry's preview, origin and status
    /// rather than decoding the outline. The preview is picked by the rule a
    /// fresh parse uses (`SessionStructureListing.firstPromptPreview`), over
    /// the whole outline. Rows parsed at another fingerprint or by another
    /// parser are left out.
    public func listings(
        for entries: [(path: String, fingerprint: SessionFileFingerprint)]
    ) -> [String: SessionStructureListing] {
        guard !entries.isEmpty,
              let database = openIfNeeded(),
              let statement = database.prepare("""
                SELECT mtime_ns, size, parser_version, stats_json,
                       (SELECT json_group_array(json_array(
                                   json_extract(entry.value, '$.promptPreview'),
                                   json_extract(entry.value, '$.origin'),
                                   json_extract(entry.value, '$.status')))
                        FROM (SELECT value FROM json_each(outline_json) ORDER BY key) AS entry)
                FROM session_structure WHERE source_path = ?1
                """)
        else { return [:] }
        defer { sqlite3_finalize(statement) }
        var out: [String: SessionStructureListing] = [:]
        for entry in entries {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            database.bindText(statement, 1, entry.path)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  sqlite3_column_int64(statement, 0) == entry.fingerprint.mtimeNs,
                  sqlite3_column_int64(statement, 1) == entry.fingerprint.size,
                  Int(sqlite3_column_int64(statement, 2)) == parserVersion,
                  let statsJSON = database.columnText(statement, 3),
                  let stats = try? decoder.decode(SessionStats.self, from: Data(statsJSON.utf8))
            else { continue }
            let entries = database.columnText(statement, 4)
                .flatMap { try? decoder.decode([[String?]].self, from: Data($0.utf8)) } ?? []
            let candidates = entries.lazy.map { fields in
                SessionStructureListing.PromptCandidate(
                    preview: fields.first ?? nil,
                    origin: fields.count > 1 ? fields[1].flatMap(SessionStructure.PromptOrigin.init(rawValue:)) : nil,
                    status: fields.count > 2 ? fields[2].flatMap(SessionStructure.TurnStatus.init(rawValue:)) : nil
                )
            }
            out[entry.path] = SessionStructureListing(
                stats: stats,
                firstPromptPreview: SessionStructureListing.firstPromptPreview(in: candidates)
            )
        }
        return out
    }

    /// Rows per provider, originator and thread kind, for the kinds that are
    /// not a conversation of their own. Claude subagent transcripts are left
    /// out: the session index never lists them, so they are not part of any
    /// count the page shows next to these.
    public func threadKindCounts() -> [SessionThreadKindCount] {
        let kinds = SessionThreadTree.nestedKinds.union(SessionThreadTree.filteredKinds)
            .subtracting([.guardian])
            .map { "'\($0.rawValue)'" }
            .sorted()
            .joined(separator: ",")
        guard let database = openIfNeeded(),
              let statement = database.prepare("""
                SELECT provider, json_extract(stats_json, '$.originator'), kind, COUNT(*)
                FROM session_structure
                WHERE parser_version = ?1 AND kind IN (\(kinds))
                  AND source_path NOT LIKE '%/subagents/agent-%'
                GROUP BY 1, 2, 3
                """)
        else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(parserVersion))
        var out: [SessionThreadKindCount] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let providerRaw = database.columnText(statement, 0),
                  let provider = SessionProvider(rawValue: providerRaw),
                  let kindRaw = database.columnText(statement, 2),
                  let kind = SessionStructureKind(rawValue: kindRaw)
            else { continue }
            out.append(SessionThreadKindCount(
                provider: provider,
                originator: database.columnText(statement, 1),
                kind: kind,
                count: Int(sqlite3_column_int64(statement, 3))
            ))
        }
        return out
    }

    /// Source paths of the rows that are a thread of another session
    /// (subagent, fork, agent-created), with their kind. Claude subagent
    /// transcripts are left out, as in `threadKindCounts()`.
    public func threadPaths() -> [String: SessionStructureKind] {
        let kinds = SessionThreadTree.nestedKinds.subtracting([.guardian])
            .map { "'\($0.rawValue)'" }
            .sorted()
            .joined(separator: ",")
        guard let database = openIfNeeded(),
              let statement = database.prepare("""
                SELECT source_path, kind FROM session_structure
                WHERE parser_version = ?1 AND kind IN (\(kinds))
                  AND source_path NOT LIKE '%/subagents/agent-%'
                """)
        else { return [:] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(parserVersion))
        var out: [String: SessionStructureKind] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = database.columnText(statement, 0),
                  let raw = database.columnText(statement, 1),
                  let kind = SessionStructureKind(rawValue: raw)
            else { continue }
            out[path] = kind
        }
        return out
    }

    public func count() -> Int {
        guard let database = openIfNeeded(),
              let statement = database.prepare("SELECT COUNT(*) FROM session_structure")
        else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: Writes

    public func upsert(_ record: SessionStructureRecord) {
        guard let database = openIfNeeded(),
              let stats = try? encoder.encode(record.stats),
              let outline = try? encoder.encode(record.outline),
              let sidechains = try? encoder.encode(record.sidechains),
              let statsJSON = String(data: stats, encoding: .utf8),
              let outlineJSON = String(data: outline, encoding: .utf8),
              let sidechainsJSON = String(data: sidechains, encoding: .utf8),
              let statement = database.prepare("""
                INSERT INTO session_structure (
                    source_path, mtime_ns, size, provider, session_id, kind, parent_id, relation,
                    stats_json, outline_json, parsed_at, parser_version, sidechains_json
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
                ON CONFLICT(source_path) DO UPDATE SET
                    mtime_ns = excluded.mtime_ns, size = excluded.size, provider = excluded.provider,
                    session_id = excluded.session_id, kind = excluded.kind, parent_id = excluded.parent_id,
                    relation = excluded.relation, stats_json = excluded.stats_json,
                    outline_json = excluded.outline_json, parsed_at = excluded.parsed_at,
                    parser_version = excluded.parser_version, sidechains_json = excluded.sidechains_json
                """)
        else { return }
        defer { sqlite3_finalize(statement) }
        database.bindText(statement, 1, record.sourcePath)
        sqlite3_bind_int64(statement, 2, record.fingerprint.mtimeNs)
        sqlite3_bind_int64(statement, 3, record.fingerprint.size)
        database.bindText(statement, 4, record.provider.rawValue)
        bindOptionalText(statement, 5, record.sessionID, database: database)
        database.bindText(statement, 6, record.kind.rawValue)
        bindOptionalText(statement, 7, record.parentID, database: database)
        bindOptionalText(statement, 8, record.relation?.rawValue, database: database)
        database.bindText(statement, 9, statsJSON)
        database.bindText(statement, 10, outlineJSON)
        database.bindDouble(statement, 11, record.parsedAt.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 12, Int64(record.parserVersion))
        database.bindText(statement, 13, sidechainsJSON)
        _ = sqlite3_step(statement)
    }

    public func remove(paths: [String]) {
        guard let database = openIfNeeded(), !paths.isEmpty,
              let statement = database.prepare("DELETE FROM session_structure WHERE source_path = ?1")
        else { return }
        defer { sqlite3_finalize(statement) }
        database.exec("BEGIN")
        for path in paths {
            sqlite3_reset(statement)
            database.bindText(statement, 1, path)
            _ = sqlite3_step(statement)
        }
        database.exec("COMMIT")
    }

    /// Drop rows whose source path is not in `known` (deleted sessions).
    public func prune(keeping known: Set<String>) {
        guard let database = openIfNeeded(),
              let statement = database.prepare("SELECT source_path FROM session_structure")
        else { return }
        var stale: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let path = database.columnText(statement, 0), !known.contains(path) { stale.append(path) }
        }
        sqlite3_finalize(statement)
        remove(paths: stale)
    }

    // MARK: Opening

    private func openIfNeeded() -> TimelineSQLite? {
        if didOpen { return database }
        didOpen = true
        if url == VibeBarLocalStore.sessionStructureURL {
            try? VibeBarLocalStore.ensureBaseDirectory()
        }
        let first = Self.open(url: url, parserVersion: parserVersion)
        if let opened = first.database {
            database = opened
            return opened
        }
        // Derived data: a plain file that SQLite says is not a database (or
        // is corrupt) is replaced rather than worked around. A busy or
        // locked database — another Vibe Bar build may hold it — and
        // anything that is not a plain file are left alone.
        guard first.isCorrupt, Self.isRegularFile(url.path) else { return nil }
        for suffix in ["", "-wal", "-shm"] where Self.isRegularFile(url.path + suffix) {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        database = Self.open(url: url, parserVersion: parserVersion).database
        return database
    }

    private static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    private static func open(url: URL, parserVersion: Int) -> (database: TimelineSQLite?, isCorrupt: Bool) {
        guard let database = TimelineSQLite(url: url) else { return (nil, false) }
        func fail() -> (database: TimelineSQLite?, isCorrupt: Bool) {
            let code = sqlite3_errcode(database.handle) & 0xFF
            database.close()
            return (nil, code == SQLITE_NOTADB || code == SQLITE_CORRUPT)
        }
        guard database.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;") else { return fail() }
        if database.userVersion != schemaVersion {
            guard database.exec("DROP TABLE IF EXISTS session_structure") else { return fail() }
        }
        let schema = """
            CREATE TABLE IF NOT EXISTS session_structure (
                source_path TEXT PRIMARY KEY,
                mtime_ns INTEGER NOT NULL,
                size INTEGER NOT NULL,
                provider TEXT NOT NULL,
                session_id TEXT,
                kind TEXT NOT NULL,
                parent_id TEXT,
                relation TEXT,
                stats_json TEXT NOT NULL,
                outline_json TEXT NOT NULL,
                parsed_at REAL NOT NULL,
                parser_version INTEGER NOT NULL,
                sidechains_json TEXT NOT NULL DEFAULT '[]'
            );
            CREATE INDEX IF NOT EXISTS session_structure_parent ON session_structure(parent_id);
            CREATE INDEX IF NOT EXISTS session_structure_session ON session_structure(provider, session_id);
            """
        guard database.exec(schema) else { return fail() }
        database.userVersion = schemaVersion
        // A parser upgrade invalidates every row at once.
        _ = database.exec("DELETE FROM session_structure WHERE parser_version != \(parserVersion)")
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return (database, false)
    }

    // MARK: Rows

    private func decodeRow(_ statement: OpaquePointer, database: TimelineSQLite) -> SessionStructureRecord? {
        guard let path = database.columnText(statement, 0),
              let providerRaw = database.columnText(statement, 3),
              let provider = SessionProvider(rawValue: providerRaw),
              let statsJSON = database.columnText(statement, 8),
              let outlineJSON = database.columnText(statement, 9),
              let stats = try? decoder.decode(SessionStats.self, from: Data(statsJSON.utf8)),
              let outline = try? decoder.decode([SessionTurnOutline].self, from: Data(outlineJSON.utf8))
        else { return nil }
        let fingerprint = SessionFileFingerprint(
            mtimeNs: sqlite3_column_int64(statement, 1),
            size: sqlite3_column_int64(statement, 2)
        )
        let structure = SessionStructure(
            provider: provider,
            sessionID: database.columnText(statement, 4),
            sourcePath: path,
            detail: .outline,
            stats: stats
        )
        var record = SessionStructureRecord(
            structure: structure,
            fingerprint: fingerprint,
            parsedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
            parserVersion: Int(sqlite3_column_int64(statement, 11))
        )
        record.outline = outline
        if let sidechainsJSON = database.columnText(statement, 12),
           let sidechains = try? decoder.decode([SessionStructure.SidechainRollup].self, from: Data(sidechainsJSON.utf8)) {
            record.sidechains = sidechains
        }
        return record
    }

    private func bindOptionalText(_ statement: OpaquePointer, _ index: Int32, _ value: String?, database: TimelineSQLite) {
        if let value {
            database.bindText(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }
}

// MARK: - Bulk stats (read-only)

/// One row of `SessionStructureStore.statsRows(forPaths:)`: what a dashboard
/// needs from a cached parse, without decoding its outline.
public struct SessionStructureStatsRow: Hashable, Sendable {
    public var sourcePath: String
    public var fingerprint: SessionFileFingerprint
    public var parserVersion: Int
    public var stats: SessionStats

    public init(sourcePath: String, fingerprint: SessionFileFingerprint, parserVersion: Int, stats: SessionStats) {
        self.sourcePath = sourcePath
        self.fingerprint = fingerprint
        self.parserVersion = parserVersion
        self.stats = stats
    }
}

extension SessionStructureStore {
    /// Stats for each of `paths` that has a row from the current parser —
    /// fresh or not; the caller compares `fingerprint` with the file. Reads
    /// `stats_json` only, so a few thousand sessions cost one statement per
    /// 400 paths and no outline decode.
    public func statsRows(forPaths paths: [String]) -> [String: SessionStructureStatsRow] {
        guard !paths.isEmpty, let database = openIfNeeded() else { return [:] }
        var out: [String: SessionStructureStatsRow] = [:]
        let unique = Array(Set(paths))
        var start = 0
        while start < unique.count {
            let chunk = unique[start..<min(unique.count, start + 400)]
            start += chunk.count
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            guard let statement = database.prepare("""
                SELECT source_path, mtime_ns, size, parser_version, stats_json
                FROM session_structure WHERE parser_version = ? AND source_path IN (\(marks))
                """)
            else { continue }
            sqlite3_bind_int64(statement, 1, Int64(parserVersion))
            for (offset, path) in chunk.enumerated() {
                database.bindText(statement, Int32(offset + 2), path)
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let path = database.columnText(statement, 0),
                      let json = database.columnText(statement, 4),
                      let stats = try? decoder.decode(SessionStats.self, from: Data(json.utf8))
                else { continue }
                out[path] = SessionStructureStatsRow(
                    sourcePath: path,
                    fingerprint: SessionFileFingerprint(
                        mtimeNs: sqlite3_column_int64(statement, 1),
                        size: sqlite3_column_int64(statement, 2)
                    ),
                    parserVersion: Int(sqlite3_column_int64(statement, 3)),
                    stats: stats
                )
            }
            sqlite3_finalize(statement)
        }
        return out
    }
}
