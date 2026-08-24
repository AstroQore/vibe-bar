import Foundation

/// Normalizes harness-reported working directories into stable project ids.
///
/// Agent worktrees live below the owning repository (`<repo>/.codex/worktrees`
/// and peers). Counting the raw cwd would split one project into a new slice
/// for every branch, so those paths collapse to the repository root. Other
/// directories stay exact: two unrelated folders with the same last component
/// must not be merged merely because their display names match.
public enum UsageProjectIdentity {
    private static let worktreeMarkers = [
        "/.agents/worktrees/",
        "/.codex/worktrees/",
        "/.claude/worktrees/",
        "/.cursor/worktrees/",
        "/.grok/worktrees/",
    ]

    public static func normalizedPath(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else { return nil }
        let path = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
        for marker in worktreeMarkers {
            guard let range = path.range(of: marker) else { continue }
            let root = String(path[..<range.lowerBound])
            return root.isEmpty ? nil : root
        }
        return path
    }

    public static func displayName(for path: String) -> String {
        let name = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
        return name.isEmpty ? path : name
    }
}
