import Foundation
import Combine

/// Holds the provider identities auto-detected from local CLI credentials.
/// VibeBar only reads official CLI credentials already present on this Mac.
///
/// Primary providers (Codex, Claude) are detected on demand — if no
/// credential is found, no account is registered, and the popover shows
/// a "logged out" placeholder for that tool.
///
/// Misc providers (`ToolType.miscProviders`) follow the opposite rule:
/// every misc provider always has a stable account id of the form
/// `"misc-<rawValue>"`, even when no credential is configured. The
/// resulting card shows a "Set up" call-to-action; once a credential
/// lands the same id is reused so cached snapshots survive.
@MainActor
public final class AccountStore: ObservableObject {
    @Published public private(set) var accounts: [AccountIdentity] = []

    public init(
        codexUsageMode: CodexUsageMode = .auto,
        claudeUsageMode: ClaudeUsageMode = .auto
    ) {
        reload(codexUsageMode: codexUsageMode, claudeUsageMode: claudeUsageMode)
    }

    /// Re-scan CLI keychain/files for auto-detected provider identities.
    public func reload(
        codexUsageMode: CodexUsageMode = .auto,
        claudeUsageMode: ClaudeUsageMode = .auto
    ) {
        var detected: [AccountIdentity] = []

        if let codex = autoDetectCodex(mode: codexUsageMode) {
            detected.append(codex)
        }
        if let claude = autoDetectClaude(mode: claudeUsageMode) {
            detected.append(claude)
        }

        // Misc providers always present, regardless of credentials.
        for tool in ToolType.miscProviders {
            detected.append(miscPlaceholder(for: tool))
        }

        self.accounts = detected
    }

    public func accounts(for tool: ToolType) -> [AccountIdentity] {
        accounts.filter { $0.tool == tool }
    }

    public static func miscAccountId(for tool: ToolType) -> String {
        precondition(tool.isMisc, "miscAccountId requested for primary tool: \(tool)")
        return "misc-\(tool.rawValue)"
    }

    // MARK: - CLI auto detection

    private func autoDetectCodex(mode: CodexUsageMode) -> AccountIdentity? {
        let order = CodexSourcePlanner.resolve(mode: mode)
        let lookupOrder = order + (CodexSourcePlanner.allowsWebFallback(mode: mode) ? [.webCookie] : [])
        var selected: (source: CredentialSource, credential: CodexCredential?)?
        for source in lookupOrder {
            switch source {
            case .oauthCLI:
                if let credential = try? CodexCredentialReader.loadFromOAuth() {
                    selected = (source, credential)
                }
            case .cliDetected:
                if let credential = try? CodexCredentialReader.loadFromCLI() {
                    selected = (source, credential)
                }
            case .webCookie:
                if OpenAIWebCookieStore.hasCookieHeader() {
                    selected = (source, nil)
                }
            case .apiToken, .browserCookie, .manualCookie, .localProbe, .notConfigured:
                break
            }
            if selected != nil { break }
        }
        guard let selected else { return nil }
        let cred = selected.credential
        let remaining = remainingSources(after: selected.source, in: order)
        let id = cred?.accountId ?? (selected.source == .oauthCLI ? "oauth-codex" : selected.source == .webCookie ? "web-codex" : "cli-codex")
        return AccountIdentity(
            id: id,
            tool: .codex,
            email: cred?.email,
            alias: selected.source == .oauthCLI ? "Codex OAuth" : selected.source == .webCookie ? "OpenAI Web" : "Codex CLI",
            plan: cred?.plan,
            accountId: cred?.accountId,
            source: selected.source,
            allowsWebFallback: selected.source == .webCookie
                ? false
                : CodexSourcePlanner.allowsWebFallback(mode: mode) && OpenAIWebCookieStore.hasCookieHeader(),
            allowsCLIFallback: remaining.contains(.cliDetected),
            allowsOAuthFallback: remaining.contains(.oauthCLI),
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    private func autoDetectClaude(mode: ClaudeUsageMode) -> AccountIdentity? {
        let order = ClaudeSourcePlanner.resolve(mode: mode)
        var selected: (source: CredentialSource, credential: ClaudeCredential?)?
        for source in order {
            switch source {
            case .oauthCLI:
                if let credential = try? ClaudeCredentialReader.loadFromOAuth() {
                    selected = (source, credential)
                }
            case .cliDetected:
                if let credential = try? ClaudeCredentialReader.loadFromCLI() {
                    selected = (source, credential)
                }
            case .webCookie:
                if ClaudeWebCookieStore.hasCookieHeader() {
                    selected = (source, nil)
                }
            case .apiToken, .browserCookie, .manualCookie, .localProbe, .notConfigured:
                break
            }
            if selected != nil { break }
        }
        guard let selected else { return nil }
        let credential = selected.credential
        let id: String
        let alias: String
        switch selected.source {
        case .oauthCLI:
            id = "oauth-claude"
            alias = "Claude OAuth"
        case .cliDetected:
            id = "cli-claude"
            alias = "Claude Code"
        case .webCookie:
            id = "web-claude"
            alias = "Claude Web"
        case .apiToken, .browserCookie, .manualCookie, .localProbe, .notConfigured:
            id = "claude"
            alias = "Claude"
        }
        let remaining = remainingSources(after: selected.source, in: order)
        return AccountIdentity(
            id: id,
            tool: .claude,
            alias: alias,
            plan: ProviderPlanDisplay.claudeDisplayName(rateLimitTier: credential?.rateLimitTier),
            source: selected.source,
            allowsWebFallback: remaining.contains(.webCookie),
            allowsCLIFallback: remaining.contains(.cliDetected),
            allowsOAuthFallback: remaining.contains(.oauthCLI),
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    private func remainingSources(after source: CredentialSource, in order: [CredentialSource]) -> [CredentialSource] {
        guard let index = order.firstIndex(of: source) else { return [] }
        let next = order.index(after: index)
        guard next < order.endIndex else { return [] }
        return Array(order[next...])
    }

    private func webClaudeAccount(allowsCLIFallback: Bool = false) -> AccountIdentity? {
        guard ClaudeWebCookieStore.hasCookieHeader() else { return nil }
        return AccountIdentity(
            id: "web-claude",
            tool: .claude,
            alias: "Claude Web",
            source: .webCookie,
            allowsCLIFallback: allowsCLIFallback,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    /// Stable placeholder for misc providers regardless of credential
    /// presence. The `source` defaults to `.notConfigured`; once an
    /// adapter actually fetches successfully, `QuotaService` updates
    /// the snapshot's metadata — the placeholder identity is mainly a
    /// hook for the UI to render a card and route to Settings.
    private func miscPlaceholder(for tool: ToolType) -> AccountIdentity {
        AccountIdentity(
            id: AccountStore.miscAccountId(for: tool),
            tool: tool,
            alias: tool.menuTitle,
            source: .notConfigured,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}
