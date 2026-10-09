import Foundation

/// The coarse kind of work a tool call does, for the Usage page's weekly
/// stacks. Tool names stay exactly as the harness wrote them (`exec`,
/// `Bash`, `js`, `mcp__github__list_prs`); only the grouping is ours.
public enum UsageToolCategory: String, CaseIterable, Sendable, Hashable, Codable {
    case shell
    case read
    case edit
    case web
    case agent
    case mcp
    case other

    public init(toolName raw: String) {
        let name = raw.lowercased()
        if name.hasPrefix("mcp__") || name.hasPrefix("mcp.") || name.contains("__mcp") {
            self = .mcp
            return
        }
        if Self.shellNames.contains(name) { self = .shell; return }
        if Self.readNames.contains(name) { self = .read; return }
        if Self.editNames.contains(name) { self = .edit; return }
        if Self.webNames.contains(name) { self = .web; return }
        if Self.agentNames.contains(name) || name.hasPrefix("collab.") { self = .agent; return }
        // A Codex MCP call the structure parser spells `server.tool`.
        if name.contains("."), !name.hasPrefix(".") { self = .mcp; return }
        self = .other
    }

    private static let shellNames: Set<String> = [
        "bash", "bashoutput", "killshell", "killbash", "exec", "exec_command", "shell", "shell_command",
        "local_shell", "write_stdin", "js", "unified_exec", "container.exec", "run_terminal_cmd",
        "run_command", "powershell", "terminal",
    ]
    private static let readNames: Set<String> = [
        "read", "glob", "grep", "ls", "view_image", "read_file", "list_dir", "list_directory",
        "file_search", "codebase_search", "grep_search", "find", "search_files", "notebookread",
        "lsp", "tool_search",
    ]
    private static let editNames: Set<String> = [
        "edit", "multiedit", "write", "notebookedit", "apply_patch", "file_change", "edit_file",
        "write_file", "str_replace", "create_file", "delete_file", "search_replace",
    ]
    private static let webNames: Set<String> = [
        "websearch", "webfetch", "web_search", "web_fetch", "image_generation", "fetch", "browser",
    ]
    private static let agentNames: Set<String> = [
        "task", "agent", "subagent", "spawn_agent", "send_input", "wait", "close_agent",
        "resume_agent", "todowrite", "update_plan", "exitplanmode", "skill", "askuserquestion",
        "request_user_input", "request_user_input_async", "sleep",
    ]
}

/// Context windows for the health cards, by model family.
///
/// Codex reports its own (`model_context_window` on every `token_count`), and
/// `SessionActivityScanner` keeps that; this table answers for everything
/// else. Matched by prefix on the lower-cased raw id, longest prefix first,
/// and `nil` for a family it does not list — a missing window is shown as
/// unknown, never guessed from the vendor.
public enum UsageModelContextWindow {
    public static func tokens(for rawModel: String) -> Int? {
        let model = rawModel.lowercased()
        if model.contains("[1m]") || model.hasSuffix("-1m") || model.contains("-1m-") { return 1_000_000 }
        for (prefix, window) in table where model.hasPrefix(prefix) {
            return window
        }
        return nil
    }

    /// Longest prefixes first so `gpt-5.1-codex-mini` is not read as `gpt-5`.
    private static let table: [(String, Int)] = [
        ("claude-sonnet-4-5", 200_000),
        ("claude-sonnet-4", 200_000),
        ("claude-opus-4", 200_000),
        ("claude-haiku-4", 200_000),
        ("claude-3", 200_000),
        ("claude-", 200_000),
        ("gpt-5", 400_000),
        ("gpt-4.1", 1_047_576),
        ("gpt-4o", 128_000),
        ("o3", 200_000),
        ("o4", 200_000),
        ("codex-", 400_000),
        ("grok-code", 256_000),
        ("grok-4", 256_000),
        ("grok-3", 131_072),
        ("gemini-3", 1_048_576),
        ("gemini-2.5", 1_048_576),
        ("devstral", 256_000),
        ("mistral", 128_000),
    ].sorted { $0.0.count > $1.0.count }
}
