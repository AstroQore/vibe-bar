import Foundation
import Combine

/// The settings one account reload reads. A value rather than a reference to
/// the settings store, so the probe can carry it off the main actor.
public struct AccountReloadRequest: Sendable, Equatable {
    public var chatGPTChatEnabled: Bool
    public var codexUsageMode: CodexUsageMode
    public var claudeUsageMode: ClaudeUsageMode
    public var geminiUsageMode: GeminiUsageMode
    public var antigravityUsageMode: AntigravityUsageMode
    public var miscProviderInstances: [MiscProviderInstance]

    public init(
        chatGPTChatEnabled: Bool = false,
        codexUsageMode: CodexUsageMode = .auto,
        claudeUsageMode: ClaudeUsageMode = .auto,
        geminiUsageMode: GeminiUsageMode = .webOnly,
        antigravityUsageMode: AntigravityUsageMode = .auto,
        miscProviderInstances: [MiscProviderInstance] = AppSettings.defaultMiscProviderInstances
    ) {
        self.chatGPTChatEnabled = chatGPTChatEnabled
        self.codexUsageMode = codexUsageMode
        self.claudeUsageMode = claudeUsageMode
        self.geminiUsageMode = geminiUsageMode
        self.antigravityUsageMode = antigravityUsageMode
        self.miscProviderInstances = miscProviderInstances
    }

    public init(settings: AppSettings) {
        self.init(
            chatGPTChatEnabled: settings.chatGPTChat.enabled,
            codexUsageMode: settings.codexUsageMode,
            claudeUsageMode: settings.claudeUsageMode,
            geminiUsageMode: settings.geminiUsageMode,
            antigravityUsageMode: settings.antigravityUsageMode,
            miscProviderInstances: settings.miscProviderInstances
        )
    }
}

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
///
/// Detection reads the Keychain, CLI credential files and Cursor's SQLite
/// store, any of which can block for tens of milliseconds (Cursor's database
/// for up to its 250 ms busy timeout). `reload` therefore runs the probe in
/// `AccountDetector` on a background executor and comes back to the main
/// actor only to publish — once, and only when an account actually changed.
@MainActor
public final class AccountStore: ObservableObject {
    /// One full credential probe. Runs off the main actor.
    public typealias Detector = @Sendable (AccountReloadRequest) -> [AccountIdentity]

    @Published public private(set) var accounts: [AccountIdentity] = []

    private let detector: Detector
    /// Bumped by every `reload` call; only the probe carrying the newest
    /// generation may publish.
    private var requestedGeneration: UInt64 = 0
    /// The generation whose result is live in `accounts`.
    private var appliedGeneration: UInt64 = 0
    private var inFlightProbe: Task<[AccountIdentity], Never>?
    private var latestReload: Task<Void, Never>?

    /// Probes synchronously, once. This runs before the app has any UI, and
    /// `QuotaService` needs the account ids at construction to seed its cached
    /// snapshots; every later reload goes through `reload(_:)`.
    public convenience init(request: AccountReloadRequest = AccountReloadRequest()) {
        self.init(accounts: AccountDetector.detect(request), detector: { AccountDetector.detect($0) })
    }

    /// Tests inject a detector; nothing is probed until `reload(_:)`.
    init(accounts: [AccountIdentity], detector: @escaping Detector) {
        self.detector = detector
        self.accounts = accounts
    }

    /// Re-scan CLI keychain/files for auto-detected provider identities.
    ///
    /// The probe runs off the main actor; the result is published in one
    /// assignment, and not at all when it describes the accounts already live.
    /// The newest call wins: a probe a later call superseded is cancelled and
    /// its result discarded, whichever order the two finish in, so an older
    /// reading can never overwrite a newer one.
    ///
    /// The returned task finishes once a result at least as new as this call
    /// is live, so a caller that awaits it and then reads `accounts` sees the
    /// world as of its own request — never the reading it was meant to replace.
    @discardableResult
    public func reload(_ request: AccountReloadRequest) -> Task<Void, Never> {
        requestedGeneration &+= 1
        let generation = requestedGeneration
        inFlightProbe?.cancel()
        let detector = self.detector
        let probe = Task.detached(priority: .userInitiated) { detector(request) }
        inFlightProbe = probe
        let reload = Task { @MainActor [weak self] in
            let detected = await probe.value
            await self?.settle(detected, generation: generation)
        }
        latestReload = reload
        return reload
    }

    private func settle(_ detected: [AccountIdentity], generation: UInt64) async {
        if generation == requestedGeneration {
            inFlightProbe = nil
            appliedGeneration = generation
            publishIfChanged(detected)
            return
        }
        // Superseded. Each newer reload either publishes or, if it was itself
        // superseded, waits for the next one; the chain ends at the newest.
        while appliedGeneration < generation, let latest = latestReload {
            await latest.value
        }
    }

    private func publishIfChanged(_ detected: [AccountIdentity]) {
        let next = Self.reconciled(detected, with: accounts)
        guard next != accounts else { return }
        accounts = next
    }

    /// Detection stamps every identity with the time of the probe, so a probe
    /// that found exactly what is live still differs in `createdAt` /
    /// `updatedAt`. Keep the live value for every account whose content did
    /// not change; an unchanged probe then compares equal and publishes
    /// nothing, and a changed one replaces only what changed.
    nonisolated static func reconciled(
        _ detected: [AccountIdentity],
        with current: [AccountIdentity]
    ) -> [AccountIdentity] {
        guard !current.isEmpty else { return detected }
        let currentByID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return detected.map { account in
            guard let live = currentByID[account.id], live.hasSameContent(as: account) else {
                return account
            }
            return live
        }
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

    /// Builds the stable placeholder identities for misc-provider instances
    /// without probing any primary-provider credentials or the Keychain.
    nonisolated static func miscAccounts(
        for instances: [MiscProviderInstance],
        now: Date = Date()
    ) -> [AccountIdentity] {
        instances.map { instance in
            AccountIdentity(
                id: miscAccountId(forInstanceID: instance.id),
                tool: instance.tool,
                alias: instance.displayName ?? instance.tool.menuTitle,
                source: .notConfigured,
                createdAt: now,
                updatedAt: now
            )
        }
    }
}

/// The credential probes behind `AccountStore`. Every function here reads the
/// Keychain, a CLI credential file, or Cursor's SQLite store, so callers run
/// it on a background executor; nothing in it touches main-actor state.
///
/// Thread safety of what it calls: `SecItemCopyMatching` is safe from any
/// thread, `VibeBarCredentialVault` serializes its own reads behind a lock,
/// and `CursorAppAuthStore` opens, uses and closes its own read-only SQLite
/// connection inside one call, so no connection is ever shared across threads.
enum AccountDetector {
    static func detect(_ request: AccountReloadRequest) -> [AccountIdentity] {
        var detected: [AccountIdentity] = []

        // A demo home has no credentials to probe; it declares its accounts.
        // Misc instances still come from settings below, as in production.
        if DemoMode.isEnabled {
            detected.append(contentsOf: DemoAccountsStore.load())
            detected.append(contentsOf: AccountStore.miscAccounts(for: request.miscProviderInstances))
            return detected
        }

        // One Keychain read and decode of the vault for the whole pass: Muse,
        // Mistral Vibe, Devin and Cursor each look up their cookie slots in it,
        // and the cookie stores below read it too. Dropping the cache first
        // means a credential changed since the last pass is still seen.
        VibeBarCredentialVault.invalidateCache()

        // Chat reads the Codex OAuth login or a chatgpt.com web session;
        // with neither on this Mac the account could only ever say "needs
        // login", so it waits for one rather than nagging the OpenAI card.
        if request.chatGPTChatEnabled, hasChatGPTChatCredential() {
            detected.append(AccountIdentity(id: "web-chatgpt-chat", tool: .chatgptChat, alias: "ChatGPT Chat", source: .webCookie))
        }
        if let codex = autoDetectCodex(mode: request.codexUsageMode) {
            detected.append(codex)
        }
        if let claude = autoDetectClaude(mode: request.claudeUsageMode) {
            detected.append(claude)
        }
        // A newer reload superseded this one; its result will be discarded,
        // so skip the remaining probes rather than finish them for nothing.
        if Task.isCancelled { return detected }
        detected.append(contentsOf: autoDetectGemini(mode: request.geminiUsageMode))
        if let antigravity = autoDetectAntigravity(mode: request.antigravityUsageMode) {
            detected.append(antigravity)
        }
        if let grok = autoDetectGrok() {
            detected.append(grok)
        }
        if let muse = autoDetectMuse() {
            detected.append(muse)
        }
        detected.append(autoDetectMuseAgent())
        if let devin = autoDetectDevin() {
            detected.append(devin)
        }
        if let mistralVibe = autoDetectMistralVibe() {
            detected.append(mistralVibe)
        }
        if Task.isCancelled { return detected }
        // Cursor is a linked Grok-family surface. Keep its stable account
        // present even while signed out so the xAI Settings cookie controls can
        // establish a session without first creating a legacy Misc instance.
        detected.append(CursorSessionResolver.accountIdentity())

        // Misc provider instances always present, regardless of credentials.
        detected.append(contentsOf: AccountStore.miscAccounts(for: request.miscProviderInstances))

        return detected
    }

    // MARK: - CLI auto detection

    static func hasChatGPTChatCredential() -> Bool {
        (try? CodexCredentialReader.loadFromOAuth()) != nil
            || (try? CodexCredentialReader.loadFromCLI()) != nil
            || OpenAIWebCookieStore.cachedCookieHeader() != nil
    }

    private static func autoDetectCodex(mode: CodexUsageMode) -> AccountIdentity? {
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

    private static func autoDetectClaude(mode: ClaudeUsageMode) -> AccountIdentity? {
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

    /// Gemini live quota is Web-only. Historical Gemini CLI telemetry
    /// remains part of cost scanning, but `~/.gemini/oauth_creds.json`
    /// is no longer registered as a quota account.
    private static func autoDetectGemini(mode: GeminiUsageMode) -> [AccountIdentity] {
        let enabled = GeminiSourcePlanner.enabledSources(mode: mode)
        let hasWeb = enabled.contains(.webCookie) && GeminiWebCookieStore.hasCookieHeader()

        var out: [AccountIdentity] = []
        if hasWeb {
            out.append(AccountIdentity(
                id: "web-gemini",
                tool: .gemini,
                alias: "Gemini Web",
                source: .webCookie,
                allowsWebFallback: false,
                allowsCLIFallback: false,
                allowsOAuthFallback: false,
                createdAt: Date(),
                updatedAt: Date()
            ))
        }
        return out
    }

    /// Antigravity always registers a placeholder identity so its
    /// dedicated card shows up even when the desktop app isn't running
    /// or no cookies have been imported yet. The adapter's `fetch`
    /// surfaces the real "open Antigravity" / "import cookies" error
    /// once the user opens the popover.
    private static func autoDetectAntigravity(mode: AntigravityUsageMode) -> AccountIdentity? {
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

    /// Grok registers when EITHER `~/.grok/auth.json` is present
    /// (preferred — carries email + plan label) OR a signed-in
    /// grok.com browser session has been imported into the Keychain.
    /// The dominant source determines the account id / alias; the
    /// adapter still falls back internally if its preferred source
    /// trips at fetch time.
    private static func autoDetectGrok() -> AccountIdentity? {
        let hasAuthJson = GrokCredentialsStore.hasCredentials()
        let hasCookies = GrokWebCookieStore.hasCookieHeader()
        guard hasAuthJson || hasCookies else { return nil }

        if hasAuthJson {
            // Best-effort identity enrichment: surface the account's
            // email and SuperGrok plan badge when auth.json parses
            // cleanly. If parsing fails we still register the account
            // so the adapter can run and report a fetch error.
            let credentials = try? GrokCredentialsStore.load()
            return AccountIdentity(
                id: "oauth-grok",
                tool: .grok,
                email: credentials?.email,
                alias: "Grok",
                plan: credentials?.planLabel,
                source: .oauthCLI,
                allowsWebFallback: hasCookies,
                allowsCLIFallback: false,
                allowsOAuthFallback: true,
                createdAt: Date(),
                updatedAt: Date()
            )
        }

        // Cookie-only session. The web payload doesn't carry email or
        // plan tier, so the card shows just "Grok Web" until/unless
        // the user also runs `grok login`.
        return AccountIdentity(
            id: "web-grok",
            tool: .grok,
            alias: "Grok Web",
            source: .webCookie,
            allowsWebFallback: true,
            allowsCLIFallback: false,
            allowsOAuthFallback: false,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    /// Muse Code registers once `muse login` has left
    /// `~/.config/muse/auth.json` behind. The file carries the account's
    /// email without the token, so detection never touches the Keychain —
    /// the adapter reads the secret, and reports when macOS has not yet
    /// allowed it to.
    private static func autoDetectMuse() -> AccountIdentity? {
        guard let authFile = MuseCredentialReader.readAuthFile() else { return nil }
        return AccountIdentity(
            id: "oauth-muse",
            tool: .muse,
            email: authFile.email,
            alias: ToolType.muse.productName,
            source: .oauthCLI,
            allowsOAuthFallback: true,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    /// Muse's account is always present, like Mistral Vibe's: its quota needs
    /// a muse.ai session imported through the shared cookie controls, and
    /// those find the account to refresh by its cookie-instance id. Until a
    /// session is saved it stays `.notConfigured`, which keeps it off the
    /// Overview and out of the browser (`MuseAgentQuotaAdapter` does not go
    /// looking for a session nobody imported).
    private static func autoDetectMuseAgent() -> AccountIdentity {
        let hasCookie = MiscCookieSlotStore.hasAnySlot(for: .museAgent)
        return AccountIdentity(
            id: AccountStore.miscAccountId(forInstanceID: ToolType.museAgent.rawValue),
            tool: .museAgent,
            alias: ToolType.museAgent.productName,
            source: hasCookie ? .browserCookie : .notConfigured,
            allowsWebFallback: hasCookie,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    /// Devin registers once its CLI has cached a plan status on this Mac.
    /// Always present, like Mistral Vibe's: the web session is imported
    /// through the shared controls in Settings, which need an account to
    /// refresh. The source says which route can answer today.
    private static func autoDetectDevin() -> AccountIdentity? {
        let hasCache = DevinUserStatusCache.exists()
        let hasSession = MiscCookieSlotStore.hasAnySlot(for: .devin)
        return AccountIdentity(
            id: "local-devin",
            tool: .devin,
            alias: ToolType.devin.productName,
            source: hasSession ? .browserCookie : (hasCache ? .cliDetected : .notConfigured),
            allowsCLIFallback: hasCache,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    /// Mistral Vibe's account is always present, like Cursor's: its quota
    /// needs a console session imported through the shared cookie controls,
    /// and those find the account to refresh by its cookie-instance id.
    private static func autoDetectMistralVibe() -> AccountIdentity? {
        let hasCookie = MiscCookieSlotStore.hasAnySlot(for: .mistralVibe)
        return AccountIdentity(
            id: AccountStore.miscAccountId(forInstanceID: ToolType.mistralVibe.rawValue),
            tool: .mistralVibe,
            alias: ToolType.mistralVibe.productName,
            source: hasCookie ? .browserCookie : .notConfigured,
            allowsWebFallback: hasCookie,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    private static func remainingSources(after source: CredentialSource, in order: [CredentialSource]) -> [CredentialSource] {
        guard let index = order.firstIndex(of: source) else { return [] }
        let next = order.index(after: index)
        guard next < order.endIndex else { return [] }
        return Array(order[next...])
    }

    private static func webClaudeAccount(allowsCLIFallback: Bool = false) -> AccountIdentity? {
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
