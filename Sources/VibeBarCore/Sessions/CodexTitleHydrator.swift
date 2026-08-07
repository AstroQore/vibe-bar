import Foundation
import SQLite3

/// Resolves Codex thread titles, which live outside the rollout files.
///
/// Two sources, merged in this order (later wins):
///
/// 1. `~/.codex/session_index.jsonl` — one `{id, thread_name}` object
///    per thread, cheap to read and present on older installs.
/// 2. Codex's own state database. The `threads` table lives at
///    `~/.codex/sqlite/state_<N>.sqlite`, with `~/.codex/state_<N>.sqlite`
///    as the legacy location. Columns used: `id`, `title`, `cwd`.
///
/// Hydration is best-effort. A missing index, a locked database, or a
/// schema that has moved on again all degrade to "no titles" — never to
/// a thrown error, because a session list without titles is still a
/// usable session list.
public final class CodexTitleHydrator: @unchecked Sendable {
    public struct Thread: Hashable, Sendable {
        public let id: String
        public let title: String?
        public let cwd: String?
    }

    private let homeDirectory: String
    private let lock = NSLock()
    private var cache: [String: Thread]?

    public init(homeDirectory: String = RealHomeDirectory.path) {
        self.homeDirectory = homeDirectory
    }

    /// Thread record for a session id, loading both sources on first
    /// use and caching the merge.
    public func thread(for sessionID: String) -> Thread? {
        threads()[sessionID.lowercased()]
    }

    public func threads() -> [String: Thread] {
        lock.lock()
        defer { lock.unlock() }
        if let cache { return cache }
        let loaded = Self.load(homeDirectory: homeDirectory)
        cache = loaded
        return loaded
    }

    /// Drop the cached merge so a later call re-reads both sources.
    public func invalidate() {
        lock.lock()
        cache = nil
        lock.unlock()
    }

    /// Apply hydrated titles (and cwd, where the rollout header had
    /// none) to a batch of summaries.
    public func hydrate(_ summaries: [SessionSummary]) -> [SessionSummary] {
        let map = threads()
        guard !map.isEmpty else { return summaries }
        return summaries.map { summary in
            guard let thread = map[summary.sessionID.lowercased()] else { return summary }
            let title = SessionParsing.display(thread.title, limit: SessionParsing.titleLimit) ?? summary.title
            return summary.withTitle(title, projectDir: summary.projectDir ?? thread.cwd)
        }
    }

    // MARK: - Loading

    static func load(homeDirectory: String) -> [String: Thread] {
        var merged = sessionIndexThreads(homeDirectory: homeDirectory)
        guard let database = stateDatabaseURL(homeDirectory: homeDirectory) else { return merged }
        for thread in stateThreads(at: database) {
            let key = thread.id.lowercased()
            merged[key] = Thread(
                id: thread.id,
                title: thread.title ?? merged[key]?.title,
                cwd: thread.cwd ?? merged[key]?.cwd
            )
        }
        return merged
    }

    static func sessionIndexThreads(homeDirectory: String) -> [String: Thread] {
        let url = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".codex/session_index.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        var out: [String: Thread] = [:]
        _ = CostUsageScanner.forEachJSONLLine(in: url) { lineData in
            guard let obj = SessionParsing.json(lineData),
                  let id = SessionParsing.string(obj["id"])
            else { return }
            let name = SessionParsing.firstString(obj["thread_name"], obj["title"])
            guard name != nil else { return }
            out[id.lowercased()] = Thread(id: id, title: name, cwd: SessionParsing.string(obj["cwd"]))
        }
        return out
    }

    /// Highest-numbered `state_<N>.sqlite`. Codex moved the state store
    /// into a `sqlite/` subdirectory, so that location wins outright
    /// when it holds any candidate; the flat legacy path is only
    /// consulted when it does not.
    static func stateDatabaseURL(homeDirectory: String) -> URL? {
        let codex = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".codex")
        let preferred = highestVersionedState(in: codex.appendingPathComponent("sqlite"))
        return preferred ?? highestVersionedState(in: codex)
    }

    private static func highestVersionedState(in directory: URL) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        var best: (version: Int, url: URL)?
        for name in names {
            guard let version = stateFileVersion(name) else { continue }
            if best == nil || version > best!.version {
                best = (version, directory.appendingPathComponent(name))
            }
        }
        return best?.url
    }

    static func stateFileVersion(_ name: String) -> Int? {
        guard name.hasPrefix("state_"), name.hasSuffix(".sqlite") else { return nil }
        let start = name.index(name.startIndex, offsetBy: "state_".count)
        let end = name.index(name.endIndex, offsetBy: -".sqlite".count)
        guard start < end else { return nil }
        return Int(name[start..<end])
    }

    static func stateThreads(at file: URL) -> [Thread] {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(file.path, &db, flags, nil) == SQLITE_OK, let db else {
            if db != nil { sqlite3_close_v2(db) }
            return []
        }
        defer { sqlite3_close_v2(db) }
        // Codex writes to this database while the CLI runs; a short
        // busy timeout keeps a concurrent write from turning into an
        // empty title list.
        sqlite3_busy_timeout(db, 250)

        var statement: OpaquePointer?
        let sql = "SELECT id, title, cwd FROM threads WHERE title <> ''"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            if statement != nil { sqlite3_finalize(statement) }
            return []
        }
        defer { sqlite3_finalize(statement) }

        var out: [Thread] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: idText)
            guard !id.isEmpty else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let cwd = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            out.append(Thread(
                id: id,
                title: SessionParsing.string(title),
                cwd: SessionParsing.string(cwd)
            ))
        }
        return out
    }
}
