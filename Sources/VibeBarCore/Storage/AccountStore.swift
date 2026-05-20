import Foundation
import Combine

/// Holds the provider identities auto-detected from local CLI credentials.
/// VibeBar only reads official CLI credentials already present on this Mac.
///
/// Primary providers (Codex, Claude) are detected on demand — if no
/// credential is found, no account is registered, and the popover shows
/// a "logged out" placeholder for that tool.
///
/// Misc provider instances follow the opposite rule: every visible or
/// hidden instance always has a stable account id of the form
/// `"misc-<instanceID>"`, even when no credential is configured. The
/// resulting card shows a "Set up" call-to-action; once a credential
/// lands the same id is reused so cached snapshots survive.
@MainActor
public final class AccountStore: ObservableObject {
    @Published public private(set) var accounts: [AccountIdentity] = []

    public init(
        codexUsageMode: CodexUsageMode = .auto,
        claudeUsageMode: ClaudeUsageMode = .auto,
        geminiUsageMode: GeminiUsageMode = .auto,
        antigravityUsageMode: AntigravityUsageMode = .auto,
        miscProviderInstances: [MiscProviderInstance] = AppSettings.defaultMiscProviderInstances
    ) {
        reload(
            codexUsageMode: codexUsageMode,
            claudeUsageMode: claudeUsageMode,
            geminiUsageMode: geminiUsageMode,
            antigravityUsageMode: antigravityUsageMode,
            miscProviderInstances: miscProviderInstances
        )
    }

    /// Re-scan CLI keychain/files for auto-detected provider identities.
    public func reload(
        codexUsageMode: CodexUsageMode = .auto,
        claudeUsageMode: ClaudeUsageMode = .auto,
        geminiUsageMode: GeminiUsageMode = .auto,
        antigravityUsageMode: AntigravityUsageMode = .auto,
        miscProviderInstances: [MiscProviderInstance] = AppSettings.defaultMiscProviderInstances
    ) {
        var detected: [AccountIdentity] = []

        if let codex = autoDetectCodex(mode: codexUsageMode) {
            detected.append(codex)
        }
        if let claude = autoDetectClaude(mode: claudeUsageMode) {
            detected.append(claude)
        }
        if let gemini = autoDetectGemini(mode: geminiUsageMode) {
            detected.append(gemini)
        }
        if let antigravity = autoDetectAntigravity(mode: antigravityUsageMode) {
            detected.append(antigravity)
        }

        // Misc provider instances always present, regardless of credentials.
        for instance in miscProviderInstances {
            detected.append(miscPlaceholder(for: instance))
        }

        self.accounts = detected
    }

    public func accounts(for tool: ToolType) -> [AccountIdentity] {
        accounts.filter { $0.tool == tool }
    }

    public func account(forMiscProviderInstanceID instanceID: String) -> AccountIdentity? {
        accounts.first { $0.id == Self.miscAccountId(forInstanceID: instanceID) }
    }

    nonisolated public static func miscAccountId(for tool: ToolType) -> String {
        precondition(tool.isMisc, "miscAccountId requested for primary tool: \(tool)")
        return miscAccountId(forInstanceID: tool.rawValue)
    }

    nonisolated public static func miscAccountId(forInstanceID instanceID: String) -> String {
        "misc-\(instanceID)"
    }

    nonisolated public static func miscInstanceID(fromAccountID accountID: String, fallbackTool: ToolType) -> String {
        let prefix = "misc-"
        guard accountID.hasPrefix(prefix), accountID.count > prefix.count else {
            return fallbackTool.rawValue
        }
        return String(accountID.dropFirst(prefix.count))
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

    /// Gemini in `.auto` mode runs both sources in parallel and merges
    /// their buckets — so the account is registered if *either* source
    /// has credentials. The `source` field reflects the dominant route
    /// (OAuth wins when present because it carries email + plan info).
    /// `.oauthOnly` / `.webOnly` register the account only when that
    /// one source is configured.
    private func autoDetectGemini(mode: GeminiUsageMode) -> AccountIdentity? {
        let enabled = GeminiSourcePlanner.enabledSources(mode: mode)
        let homeDir = RealHomeDirectory.path
        let geminiOAuthPath = URL(fileURLWithPath: homeDir)
            .appendingPathComponent(".gemini/oauth_creds.json").path
        let hasOAuth = enabled.contains(.oauthCLI) && FileManager.default.fileExists(atPath: geminiOAuthPath)
        let hasWeb = enabled.contains(.webCookie) && GeminiWebCookieStore.hasCookieHeader()
        guard hasOAuth || hasWeb else { return nil }

        // Dominant source: OAuth (richer metadata) > Web. The
        // `source` field is mostly informational on the card — the
        // adapter still decides which paths to actually fetch.
        let primarySource: CredentialSource = hasOAuth ? .oauthCLI : .webCookie
        let id: String
        let alias: String
        switch mode {
        case .auto:
            id = hasOAuth && hasWeb ? "dual-gemini" : (hasOAuth ? "oauth-gemini" : "web-gemini")
            alias = hasOAuth && hasWeb ? "Gemini CLI + Web" : (hasOAuth ? "Gemini CLI" : "Gemini Web")
        case .oauthOnly:
            id = "oauth-gemini"
            alias = "Gemini CLI"
        case .webOnly:
            id = "web-gemini"
            alias = "Gemini Web"
        }
        return AccountIdentity(
            id: id,
            tool: .gemini,
            alias: alias,
            source: primarySource,
            allowsWebFallback: mode == .auto && hasWeb && !hasOAuth ? false : (mode != .oauthOnly && hasWeb),
            allowsCLIFallback: false,
            allowsOAuthFallback: mode != .webOnly && hasOAuth,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    /// Antigravity always registers a placeholder identity so its
    /// dedicated card shows up even when the desktop app isn't running
    /// or no cookies have been imported yet. The adapter's `fetch`
    /// surfaces the real "open Antigravity" / "import cookies" error
    /// once the user opens the popover.
    private func autoDetectAntigravity(mode: AntigravityUsageMode) -> AccountIdentity? {
        let order = AntigravitySourcePlanner.resolve(mode: mode)
        let primarySource: CredentialSource = order.first ?? .localProbe
        let id: String
        let alias: String
        switch primarySource {
        case .webCookie:
            id = "web-antigravity"
            alias = "Antigravity Web"
        default:
            id = "local-antigravity"
            alias = "Antigravity"
        }
        return AccountIdentity(
            id: id,
            tool: .antigravity,
            alias: alias,
            source: primarySource,
            allowsWebFallback: order.contains(.webCookie),
            allowsCLIFallback: false,
            allowsOAuthFallback: false,
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
    private func miscPlaceholder(for instance: MiscProviderInstance) -> AccountIdentity {
        AccountIdentity(
            id: AccountStore.miscAccountId(forInstanceID: instance.id),
            tool: instance.tool,
            alias: instance.displayName ?? instance.tool.menuTitle,
            source: .notConfigured,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}
