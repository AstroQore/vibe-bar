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

    public init(claudeUsageMode: ClaudeUsageMode = .cliThenWeb) {
        reload(claudeUsageMode: claudeUsageMode)
    }

    /// Re-scan CLI keychain/files for auto-detected provider identities.
    public func reload(claudeUsageMode: ClaudeUsageMode = .cliThenWeb) {
        var detected: [AccountIdentity] = []

        if let codex = autoDetectCodex() {
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

    private func autoDetectCodex() -> AccountIdentity? {
        guard let cred = try? CodexCredentialReader.loadFromCLI() else { return nil }
        let id = cred.accountId ?? "cli-codex"
        return AccountIdentity(
            id: id,
            tool: .codex,
            email: cred.email,
            alias: "Codex CLI",
            plan: cred.plan,
            accountId: cred.accountId,
            source: .cliDetected,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    private func autoDetectClaude(mode: ClaudeUsageMode) -> AccountIdentity? {
        switch mode {
        case .cliThenWeb:
            if let credential = try? ClaudeCredentialReader.loadFromCLI() {
                return AccountIdentity(
                    id: "cli-claude",
                    tool: .claude,
                    alias: "Claude Code",
                    plan: ProviderPlanDisplay.claudeDisplayName(rateLimitTier: credential.rateLimitTier),
                    source: .cliDetected,
                    allowsWebFallback: true,
                    createdAt: Date(),
                    updatedAt: Date()
                )
            }
            return webClaudeAccount()
        case .webThenCli:
            if let web = webClaudeAccount(allowsCLIFallback: true) {
                return web
            }
            guard let credential = try? ClaudeCredentialReader.loadFromCLI() else { return nil }
            return AccountIdentity(
                id: "cli-claude",
                tool: .claude,
                alias: "Claude Code",
                plan: ProviderPlanDisplay.claudeDisplayName(rateLimitTier: credential.rateLimitTier),
                source: .cliDetected,
                createdAt: Date(),
                updatedAt: Date()
            )
        case .cliOnly:
            guard let credential = try? ClaudeCredentialReader.loadFromCLI() else { return nil }
            return AccountIdentity(
                id: "cli-claude",
                tool: .claude,
                alias: "Claude Code",
                plan: ProviderPlanDisplay.claudeDisplayName(rateLimitTier: credential.rateLimitTier),
                source: .cliDetected,
                createdAt: Date(),
                updatedAt: Date()
            )
        case .webOnly:
            return webClaudeAccount()
        }
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
