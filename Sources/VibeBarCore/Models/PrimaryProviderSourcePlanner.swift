import Foundation

public enum CodexUsageMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case oauthThenCLI
    case cliThenOAuth
    case oauthOnly
    case cliOnly

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto: return L10n.Common.auto
        case .oauthThenCLI: return L10n.Settings.UsageMode.Codex.oauthThenCli
        case .cliThenOAuth: return L10n.Settings.UsageMode.Codex.cliThenOauth
        case .oauthOnly: return L10n.Settings.UsageMode.oauthOnly
        case .cliOnly: return L10n.Settings.UsageMode.Codex.cliOnly
        }
    }

    public var detail: String {
        switch self {
        case .auto:
            return L10n.Settings.UsageMode.Codex.autoDetail
        case .oauthThenCLI:
            return L10n.Settings.UsageMode.Codex.oauthFirstDetail
        case .cliThenOAuth:
            return L10n.Settings.UsageMode.Codex.autoDetail
        case .oauthOnly:
            return L10n.Settings.UsageMode.Codex.oauthOnlyDetail
        case .cliOnly:
            return L10n.Settings.UsageMode.Codex.cliOnlyDetail
        }
    }
}

public enum CodexSourcePlanner {
    public static func resolve(mode: CodexUsageMode) -> [CredentialSource] {
        switch mode {
        case .auto, .cliThenOAuth:
            return [.cliDetected, .oauthCLI]
        case .oauthThenCLI:
            return [.oauthCLI, .cliDetected]
        case .oauthOnly:
            return [.oauthCLI]
        case .cliOnly:
            return [.cliDetected]
        }
    }

    public static func allowsWebFallback(mode: CodexUsageMode) -> Bool {
        switch mode {
        case .auto, .oauthThenCLI, .cliThenOAuth:
            return true
        case .oauthOnly, .cliOnly:
            return false
        }
    }
}

public enum ClaudeSourcePlanner {
    public static func resolve(mode: ClaudeUsageMode) -> [CredentialSource] {
        switch mode {
        case .auto:
            return [.webCookie, .oauthCLI, .cliDetected]
        case .oauthThenCliThenWeb:
            return [.oauthCLI, .cliDetected, .webCookie]
        case .cliThenWeb:
            return [.cliDetected, .webCookie, .oauthCLI]
        case .webThenCli:
            return [.webCookie, .cliDetected, .oauthCLI]
        case .oauthOnly:
            return [.oauthCLI]
        case .cliOnly:
            return [.cliDetected]
        case .webOnly:
            return [.webCookie]
        }
    }
}

/// Gemini live quota comes only from the Web usage surface. The local
/// CLI still feeds historical cost/usage scans, but it is not a quota
/// source.
public enum GeminiSourcePlanner {
    public static func enabledSources(mode _: GeminiUsageMode) -> [CredentialSource] {
        [.webCookie]
    }

    public static func runsOAuth(mode _: GeminiUsageMode) -> Bool {
        false
    }

    public static func runsWeb(mode _: GeminiUsageMode) -> Bool {
        true
    }
}

public enum AntigravitySourcePlanner {
    /// Compile-time flag controlling whether the web-cookie path is
    /// exposed. Flip to `true` only after the Antigravity Cloud endpoint
    /// spike succeeds (see plan §9). Until then, `webOnly` collapses to
    /// `[.localProbe]` and the Settings UI hides the Antigravity cookie
    /// controls. Centralised here so the follow-up patch is a one-line
    /// flip instead of a multi-file churn.
    public static let antigravityWebSourceAvailable = false

    public static func resolve(mode: AntigravityUsageMode) -> [CredentialSource] {
        switch mode {
        case .auto, .localThenWeb:
            return antigravityWebSourceAvailable ? [.localProbe, .webCookie] : [.localProbe]
        case .webThenLocal:
            return antigravityWebSourceAvailable ? [.webCookie, .localProbe] : [.localProbe]
        case .localOnly:
            return [.localProbe]
        case .webOnly:
            return antigravityWebSourceAvailable ? [.webCookie] : [.localProbe]
        }
    }
}
