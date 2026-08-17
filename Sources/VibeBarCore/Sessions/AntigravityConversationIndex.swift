import Foundation
import SQLite3

/// AntiGravity-schema queries over a conversation database.
///
/// The generic "read another app's live SQLite file" plumbing lives in
/// `LiveSQLiteReader`; only the two AntiGravity tables are described here.
enum AntigravityLiveSQLite {
    /// One `steps` row, reduced to the three columns a transcript needs.
    struct Step {
        let idx: Int
        let type: Int
        let payload: Data?
    }

    static func steps(at url: URL) -> [Step]? {
        LiveSQLiteReader.read(at: url) { database in
            let statement = try LiveSQLiteReader.prepare(
                database,
                "SELECT idx, step_type, step_payload FROM steps ORDER BY idx"
            )
            defer { sqlite3_finalize(statement) }
            var out: [Step] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW, out.count < LiveSQLiteReader.maxRows {
                out.append(Step(
                    idx: Int(sqlite3_column_int64(statement, 0)),
                    type: Int(sqlite3_column_int64(statement, 1)),
                    payload: LiveSQLiteReader.blob(statement, 2)
                ))
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE || out.count >= LiveSQLiteReader.maxRows else {
                throw LiveSQLiteReader.ReadError.statement
            }
            return out
        }
    }

    /// `gen_metadata` decoded into model turns, keyed by row index.
    ///
    /// `AntigravitySessionReader.readGenMetadata` opens with `immutable=1`
    /// (correct for the cost scanner's IDE-only sweep, wrong for a live CLI
    /// database), so only its blob decoder is reused here.
    static func turns(at url: URL) -> [(idx: Int, turn: AntigravitySessionReader.Turn)]? {
        LiveSQLiteReader.read(at: url) { database in
            let statement = try LiveSQLiteReader.prepare(
                database,
                "SELECT idx, data FROM gen_metadata ORDER BY idx"
            )
            defer { sqlite3_finalize(statement) }
            var out: [(idx: Int, turn: AntigravitySessionReader.Turn)] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW, out.count < LiveSQLiteReader.maxRows {
                if let data = LiveSQLiteReader.blob(statement, 1),
                   let turn = AntigravitySessionReader.decodeTurn(blob: data) {
                    out.append((Int(sqlite3_column_int64(statement, 0)), turn))
                }
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE || out.count >= LiveSQLiteReader.maxRows else {
                throw LiveSQLiteReader.ReadError.statement
            }
            return out
        }
    }
}

/// Best-effort titles and working directories for AntiGravity
/// conversations, which live outside the conversation databases.
///
/// Two side stores, both optional and both allowed to be wrong:
///
/// 1. `<surface>/conversation_summaries.db` — a `conversation_summaries`
///    table with a title, a preview, and `workspace_uris`. On real
///    machines this store drifts badly: its `conversation_id` values can
///    match *none* of the databases actually on disk. Zero joins is a
///    normal outcome, never an error.
/// 2. `<surface>/history.jsonl` — the CLI's own prompt history, one
///    `{display, timestamp, workspace, conversationId}` object per
///    submitted prompt. Lines without a `conversationId` cannot be
///    attributed and are skipped.
///
/// Both are read once per surface directory and cached, because a sweep
/// describes hundreds of conversations against the same two files.
public final class AntigravityConversationIndex: @unchecked Sendable {
    public struct Record: Hashable, Sendable {
        public let title: String?
        public let projectDir: String?
        public let lastModified: Date?
    }

    private let lock = NSLock()
    private var surfaces: [String: [String: Record]] = [:]

    public init() {}

    /// Hydration record for one conversation id. `surface` is the
    /// directory that *contains* `conversations/`, e.g. `~/.gemini/antigravity-cli`.
    func record(for conversationID: String, surface: URL) -> Record? {
        records(surface: surface)[conversationID.lowercased()]
    }

    func records(surface: URL) -> [String: Record] {
        let key = surface.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        if let cached = surfaces[key] { return cached }
        let loaded = Self.load(surface: surface)
        surfaces[key] = loaded
        return loaded
    }

    /// Drop every cached surface so a later lookup re-reads both stores.
    public func invalidate() {
        lock.lock()
        surfaces = [:]
        lock.unlock()
    }

    // MARK: - Loading

    static let summariesFileName = "conversation_summaries.db"
    static let historyFileName = "history.jsonl"

    static let cliSurfaceName = "antigravity-cli"

    static func load(surface: URL) -> [String: Record] {
        let history = historyRecords(at: surface.appendingPathComponent(historyFileName))
        var summaries = summaryRecords(at: surface.appendingPathComponent(summariesFileName))

        // The CLI's summaries store is shared across surfaces: its rows
        // name the owning surface in `app_data_dir`, and on real machines
        // it is the only store that knows anything about the IDE's
        // conversations. Consulted second, so a surface's own store —
        // if it ever grows one — always wins.
        let shared = surface.deletingLastPathComponent()
            .appendingPathComponent(cliSurfaceName, isDirectory: true)
            .appendingPathComponent(summariesFileName)
        if surface.lastPathComponent != cliSurfaceName {
            for (id, record) in summaryRecords(at: shared) where summaries[id] == nil {
                summaries[id] = record
            }
        }

        var merged = history
        for (id, summary) in summaries {
            let existing = merged[id]
            merged[id] = Record(
                // A hydrated title is the CLI's own label for the thread and
                // outranks the first prompt; a working directory recorded at
                // prompt time outranks a summary row that may predate a move.
                title: summary.title ?? existing?.title,
                projectDir: existing?.projectDir ?? summary.projectDir,
                lastModified: summary.lastModified ?? existing?.lastModified
            )
        }
        return merged
    }

    static func historyRecords(at url: URL) -> [String: Record] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        var out: [String: Record] = [:]
        _ = CostUsageScanner.forEachJSONLLine(in: url) { lineData in
            guard let object = SessionParsing.json(lineData),
                  let id = SessionParsing.string(object["conversationId"])?.lowercased()
            else { return }
            let display = SessionParsing.string(object["display"])
            let workspace = SessionParsing.string(object["workspace"])
            let timestamp = SessionParsing.date(object["timestamp"])
            guard display != nil || workspace != nil else { return }
            let existing = out[id]
            // First prompt wins for the title; the newest line wins for the
            // timestamp, and any known workspace fills the gap.
            out[id] = Record(
                title: existing?.title ?? display,
                projectDir: existing?.projectDir ?? workspace,
                lastModified: timestamp ?? existing?.lastModified
            )
        }
        return out
    }

    static func summaryRecords(at url: URL) -> [String: Record] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let rows: [String: Record]? = LiveSQLiteReader.read(at: url) { database in
            let statement = try LiveSQLiteReader.prepare(
                database,
                """
                SELECT conversation_id, title, preview, workspace_uris, last_modified_time
                  FROM conversation_summaries
                """
            )
            defer { sqlite3_finalize(statement) }
            var out: [String: Record] = [:]
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW, out.count < LiveSQLiteReader.maxRows {
                defer { result = sqlite3_step(statement) }
                guard let id = SessionParsing.string(LiveSQLiteReader.text(statement, 0))
                else { continue }
                // `title` is empty on every build seen so far; `preview`
                // is where the generated label actually lands, often as a
                // markdown heading.
                let title = strippingHeadingMarkers(SessionParsing.firstString(
                    LiveSQLiteReader.text(statement, 1),
                    LiveSQLiteReader.text(statement, 2)
                ))
                out[id.lowercased()] = Record(
                    title: title,
                    projectDir: firstWorkspace(LiveSQLiteReader.text(statement, 3)),
                    lastModified: timestamp(LiveSQLiteReader.text(statement, 4))
                )
            }
            guard result == SQLITE_DONE || out.count >= LiveSQLiteReader.maxRows else {
                throw LiveSQLiteReader.ReadError.statement
            }
            return out
        }
        return rows ?? [:]
    }

    static func strippingHeadingMarkers(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return SessionParsing.string(
            raw.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// `workspace_uris` is a JSON array of `file://` URIs on the builds
    /// that populate it at all, and an empty string on the ones that do
    /// not. A bare path is accepted too, because the column is untyped.
    static func firstWorkspace(_ raw: String?) -> String? {
        guard let raw = SessionParsing.string(raw) else { return nil }
        var candidate: String?
        if let data = raw.data(using: .utf8),
           let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
            candidate = array.compactMap { SessionParsing.string($0) }.first
        }
        let value = candidate ?? raw
        guard !value.hasPrefix("[") else { return nil }
        guard value.hasPrefix("file://") else { return SessionParsing.string(value) }
        let path = String(value.dropFirst("file://".count))
        return SessionParsing.string(path.removingPercentEncoding ?? path)
    }

    /// `last_modified_time` is written as `2026-07-16 08:18:19.171238+00:00`
    /// — ISO-8601 with a space where the `T` belongs.
    static func timestamp(_ raw: String?) -> Date? {
        guard let raw = SessionParsing.string(raw) else { return nil }
        if let date = SessionParsing.date(raw) { return date }
        guard let space = raw.firstIndex(of: " ") else { return nil }
        var normalized = raw
        normalized.replaceSubrange(space...space, with: "T")
        guard let date = SessionParsing.date(normalized) else { return nil }
        // The zero value AntiGravity writes for "never" (year 1) is not a
        // date any UI should show.
        return date.timeIntervalSince1970 > 0 ? date : nil
    }
}
