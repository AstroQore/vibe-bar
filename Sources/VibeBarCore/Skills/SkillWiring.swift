import Foundation

/// One harness's complete view of one skill, spelled out for the UI.
///
/// `SkillActivationState` compresses three mechanisms — shared-root
/// discovery, the per-app projection, and the harness's native switch — into
/// one word, which is right for a badge and wrong for the question "what did
/// Vibe Bar actually do on my disk". This struct keeps the layers separate
/// and names the paths, so the Skills page can show its work instead of
/// asking to be trusted.
public struct SkillHarnessWiring: Hashable, Sendable {
    public let app: SkillAppTarget
    public let state: SkillActivationState
    /// The harness scans `~/.agents/skills` itself, so the skill is visible
    /// there with no per-app entry at all.
    public let discoversSharedRoot: Bool
    /// The per-app entry Vibe Bar manages, when one exists.
    public let projection: SkillMaterialization?
    /// Home-relative location that entry occupies (or would occupy).
    public let projectionPath: String
    /// Home-relative SSOT directory every projection points back to.
    public let sourcePath: String
    /// Home-relative file holding the harness's per-skill switch, `nil` when
    /// the harness has none.
    public let nativeConfigPath: String?
    /// The key inside that file, in the harness's own vocabulary.
    public let nativeConfigKey: String?
    /// AntiGravity only: visible because it also reads the Gemini CLI's
    /// skills directory, which holds a Gemini projection of this skill.
    public let viaGeminiCompatibility: Bool
}

extension Skill {
    /// Everything the UI needs to explain how `app` currently sees this
    /// skill. Pure derivation — nothing here touches the filesystem.
    public func wiring(for app: SkillAppTarget) -> SkillHarnessWiring {
        SkillHarnessWiring(
            app: app,
            state: activationState(for: app),
            discoversSharedRoot: app.discoversSharedSkillRoot,
            projection: apps[app],
            projectionPath: "~/\(SkillAppCatalog.relativePath(for: app))/\(directory)",
            sourcePath: "~/\(SkillAppCatalog.ssotRelativePath)/\(directory)",
            nativeConfigPath: app.nativeConfigRelativePath.map { "~/\($0)" },
            nativeConfigKey: app.nativeConfigKeyDescription,
            viaGeminiCompatibility: app == .antigravity && apps[app] == nil && isProjected(for: .gemini)
        )
    }
}
