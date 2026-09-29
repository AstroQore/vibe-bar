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
        // Display only: Muse's own folder is never a write root.
        case .muse: return ".config/muse/skills"
        case .mistralVibe: return ".vibe/skills"
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

    /// The SSOT plus every app skills dir Vibe Bar may project into. The sync
    /// engine hard-asserts that each path it mutates sits under one of these,
    /// so a malformed skill name can never reach into the rest of the home
    /// directory.
    public static func allowedWriteRoots(homeDirectory: String = RealHomeDirectory.path) -> [URL] {
        [ssotDirectory(homeDirectory: homeDirectory)]
            + SkillAppTarget.allCases
                .filter(\.supportsProjection)
                .map { skillsDirectory(for: $0, homeDirectory: homeDirectory) }
    }

    /// Home-relative folders where a harness keeps the skills it ships with.
    ///
    /// Each row is an on-disk convention the harness itself documents or
    /// marks, never a guess:
    /// - Codex installs its bundled skills under `~/.codex/skills/.system`
    ///   and drops a `.codex-system-skills.marker` beside them.
    /// - Grok Build's skills guide says bundled skills are cached under
    ///   `~/.grok/bundled/skills/` and never written into `~/.grok/skills/`.
    /// - Cursor syncs its own skills into `~/.cursor/skills-cursor` and lists
    ///   them in `.cursor-managed-skills-manifest.json` there.
    ///
    /// These folders belong to the harness's updater. Vibe Bar reads them to
    /// show every copy of a skill and never writes into them — see
    /// `isWriteAllowed`, which refuses them even where one sits inside an
    /// app skills root (Codex's `.system`).
    public static func builtInRelativePaths(for app: SkillAppTarget) -> [String] {
        switch app {
        case .codex: return [".codex/skills/.system"]
        case .grok: return [".grok/bundled/skills"]
        case .cursor: return [".cursor/skills-cursor"]
        case .claude, .gemini, .hermes, .opencode, .antigravity, .muse, .mistralVibe: return []
        }
    }

    public static func builtInSkillRoots(
        for app: SkillAppTarget,
        homeDirectory: String = RealHomeDirectory.path
    ) -> [URL] {
        builtInRelativePaths(for: app).map { url(homeDirectory: homeDirectory, relativePath: $0) }
    }

    /// Lexical containment check on standardized paths. Deliberately does not
    /// resolve symlinks: the caller has already lstat-ed the entry, and
    /// resolving here would let a symlinked app dir vouch for a path outside
    /// the allowed roots.
    ///
    /// A harness's built-in folder is refused even when it sits inside an
    /// allowed root: `~/.codex/skills/.system` is under `~/.codex/skills`,
    /// and its contents are Codex's to replace on update, not ours.
    public static func isWriteAllowed(
        _ url: URL,
        homeDirectory: String = RealHomeDirectory.path
    ) -> Bool {
        let candidate = url.standardizedFileURL.path
        let insideBuiltIn = SkillAppTarget.allCases.contains { app in
            builtInSkillRoots(for: app, homeDirectory: homeDirectory).contains { root in
                let rootPath = root.standardizedFileURL.path
                return candidate == rootPath || candidate.hasPrefix(rootPath + "/")
            }
        }
        guard !insideBuiltIn else { return false }
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
