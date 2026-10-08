import Foundation
import SQLite3

/// Auto Review rows, answered by parent instead of loaded wholesale.
///
/// The kit can only hand these out as `summaries(provider:providerVariantPrefix:)`
/// — whole rows, oldest first, at most 2 000 by default and 10 000 at all. The
/// Sessions page used to load that list on every index change and group it in
/// memory, which on a Mac with 3 300 review rollouts meant the newest 1 300
/// were never seen: no badge on their session, missing from its transcript,
/// and not subtracted from the Codex chip. Raising the limit would only have
/// moved the cliff and kept the whole list in memory.
///
/// So the two questions the page actually asks are asked of SQLite directly:
///
/// - `overview()` — how many reviews each session has, and how many rows
///   the list's exclusion hides per harness. One grouped scan of the Codex
///   rows; the result is one `[id: count]` entry per *parent* — about a
///   hundred bytes each, where the old path held a full summary (title,
///   prompt, paths: a kilobyte or more) per *review*, and still stopped at
///   2 000 of them.
/// - `reviews(forParents:limit:)` — the reviews of the sessions in hand,
///   when a transcript is opened or a deletion is planned.
///
/// The index is the kit's file, and its schema is a published contract
/// (`contracts/storage/session-index-v5.sql`); this reads the `sessions`
/// table on its own **read-only** connection, under the same licence
/// `SessionIndexCompactor` and `SessionIndexReparse` already use to maintain
/// it. An actor, so every query runs off the main actor, and one connection,
/// opened on first use and never used to write.
public actor SessionReviewIndex {
    public enum Failure: Error, Equatable {
        /// The database does not exist yet, or would not open read-only.
        case unavailable
        /// A statement failed — a schema this code does not know, most likely.
        case statement
    }

    /// Everything the session list derives from the review rows.
    public struct Overview: Sendable, Equatable {
        /// Reviews per parent session id.
        public var countsByParent: [String: Int]
        /// Rows the list's Auto Review exclusion removes, per harness — what
        /// to subtract from `SessionIndexStore.harnessCounts()` so a chip
        /// counts the rows its filter can actually show.
        public var hiddenRowsByHarness: [Harness: Int]

        public init(
            countsByParent: [String: Int] = [:],
            hiddenRowsByHarness: [Harness: Int] = [:]
        ) {
            self.countsByParent = countsByParent
            self.hiddenRowsByHarness = hiddenRowsByHarness
        }

        public static let empty = Overview()

        public var totalHiddenRows: Int { hiddenRowsByHarness.values.reduce(0, +) }
    }

    private let databaseURL: URL
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(databaseURL: URL = VibeBarLocalStore.sessionIndexURL) {
        self.databaseURL = databaseURL
    }

    deinit {
        if let database { sqlite3_close_v2(database) }
    }

    // MARK: - Queries

    public func overview() throws -> Overview {
        var overview = Overview()
        let prefix = SessionVisibleRows.hiddenVariantPrefix
        let parentStart = Int64(prefix.utf8.count + 1)
        // The parent is the variant's suffix. A row that names itself is the
        // pre-0.142 shape `CodexReviewLinkRepair` rewrites; it belongs to no
        // listed row, so it is not counted as anybody's review.
        try query(
            """
            SELECT substr(provider_variant, ?1) AS parent, COUNT(*)
              FROM sessions
             WHERE provider = ?2
               AND provider_variant LIKE ?3 ESCAPE '\\'
               AND substr(provider_variant, ?1) <> session_id
             GROUP BY parent
            """,
            [.integer(parentStart), .text(SessionProvider.codex.rawValue), .text(Self.likePrefix(prefix))]
        ) { statement in
            guard let parent = Self.text(statement, 0), !parent.isEmpty else { return }
            overview.countsByParent[parent] = Int(sqlite3_column_int64(statement, 1))
        }
        // The same predicate `summaryPage(excludingProviderVariantPrefix:)`
        // applies, on the same rows `harnessCounts()` counts — every provider,
        // harness not null — so the subtraction is exact.
        try query(
            """
            SELECT harness, COUNT(*)
              FROM sessions
             WHERE harness IS NOT NULL
               AND provider_variant LIKE ?1 ESCAPE '\\'
             GROUP BY harness
            """,
            [.text(Self.likePrefix(prefix))]
        ) { statement in
            guard let raw = Self.text(statement, 0), let harness = Harness(rawValue: raw) else { return }
            overview.hiddenRowsByHarness[harness] = Int(sqlite3_column_int64(statement, 1))
        }
        return overview
    }

    /// The Auto Reviews of `parents`, oldest first, at most `limit` of them.
    ///
    /// The ids travel as one JSON array bound to a single parameter, so the
    /// statement does not grow with the selection and no id is ever
    /// interpolated into SQL.
    public func reviews(forParents parents: [String], limit: Int) throws -> [SessionSummary] {
        let wanted = Array(Set(parents.filter { !$0.isEmpty }))
        guard !wanted.isEmpty else { return [] }
        let ids = try JSONSerialization.data(withJSONObject: wanted)
        let prefix = SessionVisibleRows.hiddenVariantPrefix
        var out: [SessionSummary] = []
        try query(
            """
            SELECT provider, session_id, provider_variant, title, summary, project_dir,
                   created_at, last_active_at, source_path, size_bytes, message_count,
                   harness, model
              FROM sessions
             WHERE provider = ?1
               AND provider_variant LIKE ?2 ESCAPE '\\'
               AND substr(provider_variant, ?3) IN (SELECT value FROM json_each(?4))
               AND substr(provider_variant, ?3) <> session_id
             ORDER BY COALESCE(created_at, last_active_at) ASC, id ASC
             LIMIT ?5
            """,
            [
                .text(SessionProvider.codex.rawValue),
                .text(Self.likePrefix(prefix)),
                .integer(Int64(prefix.utf8.count + 1)),
                .text(String(decoding: ids, as: UTF8.self)),
                .integer(Int64(max(1, limit)))
            ]
        ) { statement in
            if let summary = Self.summary(statement) { out.append(summary) }
        }
        return out
    }

    /// How many Auto Reviews one session has, without reading them.
    public func reviewCount(forParent parent: String) throws -> Int {
        guard !parent.isEmpty else { return 0 }
        var count = 0
        try query(
            """
            SELECT COUNT(*) FROM sessions
             WHERE provider = ?1 AND provider_variant = ?2 AND session_id <> ?3
            """,
            [
                .text(SessionProvider.codex.rawValue),
                .text(SessionVisibleRows.hiddenVariantPrefix + parent),
                .text(parent)
            ]
        ) { count = Int(sqlite3_column_int64($0, 0)) }
        return count
    }

    // MARK: - SQLite plumbing

    private enum Binding {
        case text(String)
        case integer(Int64)
    }

    /// Opened on first use rather than at init: the index may not exist yet
    /// when the app starts, and a read-only open never creates it.
    private func connection() throws -> OpaquePointer {
        if let database { return database }
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { throw Failure.unavailable }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle
        else {
            if handle != nil { sqlite3_close_v2(handle) }
            throw Failure.unavailable
        }
        sqlite3_busy_timeout(handle, 2_000)
        database = handle
        return handle
    }

    private func query(
        _ sql: String,
        _ bindings: [Binding],
        row: (OpaquePointer) -> Void
    ) throws {
        let database = try connection()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            if statement != nil { sqlite3_finalize(statement) }
            throw Failure.statement
        }
        defer { sqlite3_finalize(statement) }
        for (index, binding) in bindings.enumerated() {
            switch binding {
            case let .text(value):
                sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
            case let .integer(value):
                sqlite3_bind_int64(statement, Int32(index + 1), value)
            }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row(statement)
            case SQLITE_DONE: return
            default: throw Failure.statement
            }
        }
    }

    /// `prefix%`, with `LIKE`'s wildcards in the prefix escaped against `\`
    /// — the same escaping the kit applies to the exclusion it is mirroring.
    static func likePrefix(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
            + "%"
    }

    private static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: raw)
    }

    private static func date(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, index)))
    }

    /// Column order of the `SELECT` in `reviews(forParents:limit:)`, which is
    /// the kit's own `sessionColumns` order.
    private static func summary(_ statement: OpaquePointer) -> SessionSummary? {
        guard let rawProvider = text(statement, 0),
              let provider = SessionProvider(rawValue: rawProvider),
              let sessionID = text(statement, 1),
              let sourcePath = text(statement, 8)
        else { return nil }
        return SessionSummary(
            provider: provider,
            sessionID: sessionID,
            providerVariant: text(statement, 2),
            harness: text(statement, 11).flatMap(Harness.init(rawValue:)),
            model: text(statement, 12),
            title: text(statement, 3),
            summary: text(statement, 4),
            projectDir: text(statement, 5),
            createdAt: date(statement, 6),
            lastActiveAt: date(statement, 7),
            sourcePath: sourcePath,
            sizeBytes: sqlite3_column_int64(statement, 9),
            messageCount: Int(sqlite3_column_int64(statement, 10))
        )
    }
}
