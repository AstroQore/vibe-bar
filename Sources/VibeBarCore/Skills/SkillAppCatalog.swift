import Foundation

/// Where every agent CLI keeps its skills, relative to the real user home.
///
/// This is the one table the whole Skills feature reads. Adding an app means
/// adding a `SkillAppTarget` case and a row here — nothing else in the sync
/// engine is app-aware.
///
/// AntiGravity has its own customization root under `~/.gemini/config/`, but
/// also discovers the Gemini CLI's `~/.gemini/skills`. The table still keeps
/// the roots separate because a direct AntiGravity projection and a Gemini
/// compatibility projection are different provenance; effective-state logic
/// reports the latter as coupled. Missing roots are created lazily, one
/// component at a time.
public enum SkillAppCatalog {
    /// Single source of truth every app dir is projected from.
    public static let ssotRelativePath = ".agents/skills"
    /// Provenance file written by the third-party skill installer. Vibe Bar
    /// reads it during import and never writes it.
    public static let lockFileRelativePath = ".agents/.skill-lock.json"

    public static func relativePath(for app: SkillAppTarget) -> String {
        switch app {
        case .claude: return ".claude/skills"
        case .codex: return ".codex/skills"
        case .gemini: return ".gemini/skills"
        case .grok: return ".grok/skills"
        case .hermes: return ".hermes/skills"
        case .opencode: return ".config/opencode/skills"
        case .antigravity: return ".gemini/config/skills"
        case .cursor: return ".cursor/skills"
        }
    }

    public static func ssotDirectory(homeDirectory: String = RealHomeDirectory.path) -> URL {
        url(homeDirectory: homeDirectory, relativePath: ssotRelativePath)
    }

    public static func lockFileURL(homeDirectory: String = RealHomeDirectory.path) -> URL {
        url(homeDirectory: homeDirectory, relativePath: lockFileRelativePath)
    }

    public static func skillsDirectory(
        for app: SkillAppTarget,
        homeDirectory: String = RealHomeDirectory.path
    ) -> URL {
        url(homeDirectory: homeDirectory, relativePath: relativePath(for: app))
    }

    /// The SSOT plus every app skills dir. The sync engine hard-asserts that
    /// each path it mutates sits under one of these, so a malformed skill name
    /// can never reach into the rest of the home directory.
    public static func allowedWriteRoots(homeDirectory: String = RealHomeDirectory.path) -> [URL] {
        [ssotDirectory(homeDirectory: homeDirectory)]
            + SkillAppTarget.allCases.map { skillsDirectory(for: $0, homeDirectory: homeDirectory) }
    }

    /// Lexical containment check on standardized paths. Deliberately does not
    /// resolve symlinks: the caller has already lstat-ed the entry, and
    /// resolving here would let a symlinked app dir vouch for a path outside
    /// the allowed roots.
    public static func isWriteAllowed(
        _ url: URL,
        homeDirectory: String = RealHomeDirectory.path
    ) -> Bool {
        let candidate = url.standardizedFileURL.path
        return allowedWriteRoots(homeDirectory: homeDirectory).contains { root in
            let rootPath = root.standardizedFileURL.path
            return candidate == rootPath || candidate.hasPrefix(rootPath + "/")
        }
    }

    public static func isPath(_ url: URL, under root: URL) -> Bool {
        let candidate = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidate == rootPath || candidate.hasPrefix(rootPath + "/")
    }

    private static func url(homeDirectory: String, relativePath: String) -> URL {
        relativePath
            .split(separator: "/")
            .reduce(URL(fileURLWithPath: homeDirectory, isDirectory: true)) { partial, component in
                partial.appendingPathComponent(String(component), isDirectory: true)
            }
    }
}
