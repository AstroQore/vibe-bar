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
        case .auto: return "Auto"
        case .oauthThenCLI: return "OAuth, then CLI"
        case .cliThenOAuth: return "CLI, then OAuth"
        case .oauthOnly: return "OAuth only"
        case .cliOnly: return "CLI only"
        }
    }

    public var detail: String {
        switch self {
        case .auto:
            return "Use local Codex CLI credentials first; fall back to Codex OAuth and saved OpenAI web cookies."
        case .oauthThenCLI:
            return "Use Codex OAuth first; fall back to local Codex CLI credentials and saved OpenAI web cookies."
        case .cliThenOAuth:
            return "Use local Codex CLI credentials first; fall back to Codex OAuth and saved OpenAI web cookies."
        case .oauthOnly:
            return "Use only Codex OAuth credentials from auth.json."
        case .cliOnly:
            return "Use only local Codex CLI credentials."
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
