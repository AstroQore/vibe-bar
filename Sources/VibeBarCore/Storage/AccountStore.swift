import Foundation
import Combine

/// Holds the provider identities auto-detected from local CLI credentials.
/// VibeBar only reads official CLI credentials already present on this Mac.
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

        self.accounts = detected
    }

    public func accounts(for tool: ToolType) -> [AccountIdentity] {
        accounts.filter { $0.tool == tool }
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
}
