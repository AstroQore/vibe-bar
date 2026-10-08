import Foundation
import SQLite3

/// What Codex's own thread table says about one thread.
public struct CodexThreadState: Hashable, Sendable {
    public var tokensUsed: Int
    public var model: String?
    public var reasoningEffort: String?
    public var gitBranch: String?
    public var threadSource: String?
}

/// Read-only lookups in `~/.codex/state_5.sqlite` — Codex's thread table,
/// which keeps a token total (`threads.tokens_used`) even for rollouts whose
/// `token_count` records are missing.
///
/// Codex owns that database and holds it open. This opens it
/// `SQLITE_OPEN_READONLY` per lookup with a short busy timeout and gives up
/// on any error: a busy or absent database means "no fallback", never a
/// stall and never a write.
public struct CodexThreadStateReader: Sendable {
    public static let busyTimeoutMs: Int32 = 100

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public init(homeDirectory: String = RealHomeDirectory.path) {
        url = URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("state_5.sqlite")
    }

    public func thread(id: String) -> CodexThreadState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let handle
        else {
            if handle != nil { sqlite3_close_v2(handle) }
            return nil
        }
        defer { sqlite3_close_v2(handle) }
        sqlite3_busy_timeout(handle, Self.busyTimeoutMs)
        // Older state databases predate the model / effort / source columns.
        let queries = [
            "SELECT tokens_used, model, reasoning_effort, git_branch, thread_source FROM threads WHERE id = ?1",
            "SELECT tokens_used, NULL, NULL, git_branch, NULL FROM threads WHERE id = ?1"
        ]
        for sql in queries {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                if statement != nil { sqlite3_finalize(statement) }
                continue
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            func text(_ index: Int32) -> String? {
                guard let raw = sqlite3_column_text(statement, index) else { return nil }
                let value = String(cString: raw)
                return value.isEmpty ? nil : value
            }
            return CodexThreadState(
                tokensUsed: Int(sqlite3_column_int64(statement, 0)),
                model: text(1),
                reasoningEffort: text(2),
                gitBranch: text(3),
                threadSource: text(4)
            )
        }
        return nil
    }
}
