import Foundation
import Combine
import VibeBarCore

@MainActor
final class AppEnvironment: ObservableObject {
    let accountStore: AccountStore
    let settingsStore: SettingsStore
    let quotaService: QuotaService
    let scheduler: QuotaRefreshScheduler
    let serviceStatus: ServiceStatusController
    let costService: CostUsageService

    @Published private(set) var hasClaudeWebCookies: Bool
    @Published private(set) var hasOpenAIWebCookies: Bool
    @Published private(set) var isImportingOpenAIBrowserCookies = false
    @Published private(set) var isImportingClaudeBrowserCookies = false
    @Published private(set) var openAIBrowserCookieImportStatus: String?
    @Published private(set) var claudeBrowserCookieImportStatus: String?
    @Published private(set) var routeHealth: [PrimaryProviderRoute: PrimaryProviderRouteHealth]

    private let openAIWebLoginController = OpenAIWebLoginController()
    private let claudeWebLoginController = ClaudeWebLoginController()
    private let miscWebLoginRegistry = MiscWebLoginRegistry()
    private let settingsWindowController = SettingsWindowController()
    private var cancellables: Set<AnyCancellable> = []
    private var routineBudgetInFlightAccountIds: Set<String> = []
    private var lastRoutineBudgetAttemptByAccount: [String: Date] = [:]
    private var persistentClaudeCookieImportInFlight = false
    private var browserClaudeCookieImportInFlight = false
    private var persistentOpenAICookieImportInFlight = false
    private var browserOpenAICookieImportInFlight = false

    init() {
        let settings = SettingsStore()
        let accounts = AccountStore(
            codexUsageMode: settings.codexUsageMode,
            claudeUsageMode: settings.claudeUsageMode
        )
        let service = QuotaService.makeDefault(mockProvider: { [weak settings] in
            settings?.mockEnabled ?? false
        }, initialAccountIds: accounts.accounts.map(\.id))

        self.settingsStore = settings
        self.accountStore = accounts
        self.quotaService = service
        self.serviceStatus = ServiceStatusController()
        let costService = CostUsageService(mockProvider: { [weak settings] in
            settings?.mockEnabled ?? false
        }, costDataSettingsProvider: { [weak settings] in
            settings?.settings.costData ?? .default
        })
        self.costService = costService
        self.hasClaudeWebCookies = ClaudeWebCookieStore.hasCookieHeader()
        self.hasOpenAIWebCookies = OpenAIWebCookieStore.hasCookieHeader()
        self.routeHealth = PrimaryProviderRouteHealthChecker.checkAll()

        let scheduler = QuotaRefreshScheduler(
            service: service,
            accountsProvider: { [weak accounts, weak settings] in
                guard let accounts, let settings else { return [] }
                if settings.mockEnabled {
                    return MockDataProvider.sampleAccounts()
                }
                return ToolType.allCases.compactMap { accounts.accounts(for: $0).first }
            },
            intervalProvider: { [weak settings] in
                settings?.refreshIntervalSeconds ?? AppSettings.default.refreshIntervalSeconds
            },
            onRefreshTriggered: {
                Task { @MainActor in
                    await costService.refreshAll()
                }
            }
        )
        self.scheduler = scheduler

        // Re-schedule + reload accounts when interval / mock / usage mode
        // changes. Quota refresh is cheap (in-memory + a couple of HTTPS
        // calls) so we always trigger it.
        settings.$settings
            .dropFirst()
            .removeDuplicates {
                $0.refreshIntervalSeconds == $1.refreshIntervalSeconds
                    && $0.mockEnabled == $1.mockEnabled
                    && $0.codexUsageMode == $1.codexUsageMode
                    && $0.claudeUsageMode == $1.claudeUsageMode
            }
            .sink { [weak self] settings in
                self?.accountStore.reload(
                    codexUsageMode: settings.codexUsageMode,
                    claudeUsageMode: settings.claudeUsageMode
                )
                self?.recheckPrimaryRouteHealth()
                self?.scheduler.reschedule()
                self?.scheduler.triggerRefresh()
            }
            .store(in: &cancellables)

        // Cost re-scan is the expensive path (full filesystem walk + JSONL
        // parse). Only run it when the *data source* actually changes —
        // mock mode or claude usage mode. The refresh-interval slider has no
        // effect on what cost data we'd read, so a flurry of slider edits
        // shouldn't kick off back-to-back full scans. Debounce smooths
        // multi-step settings transitions too.
        settings.$settings
            .dropFirst()
            .removeDuplicates {
                $0.mockEnabled == $1.mockEnabled
                    && $0.claudeUsageMode == $1.claudeUsageMode
                    && $0.codexUsageMode == $1.codexUsageMode
            }
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.costService.refreshAll()
                }
            }
            .store(in: &cancellables)

        settings.$settings
            .dropFirst()
            .map(\.costData)
            .removeDuplicates()
            .sink { [weak self] costData in
                Task { @MainActor in
                    await self?.costService.applyCostDataSettings()
                    if !costData.privacyModeEnabled {
                        await self?.costService.refreshAll()
                    }
                }
            }
            .store(in: &cancellables)

        scheduler.start()
        serviceStatus.start()

        // Kick off an initial cost scan in the background. Cost data updates
        // slowly compared to live quota, so we re-scan only on app relaunch,
        // data-source settings changes, or the explicit Cost Data rescan button.
        Task { @MainActor in
            await costService.applyCostDataSettings()
            await costService.refreshAll()
        }
        importPersistentClaudeCookiesAndRefreshIfNeeded()
        importClaudeBrowserCookiesAndRefreshIfNeeded()
        importPersistentOpenAICookiesAndRefreshIfNeeded()
        importOpenAIBrowserCookiesAndRefreshIfNeeded()

        // Push Claude/Codex extras parsed by adapters into CostUsageService.
        service.$lastSuccessByAccount
            .receive(on: RunLoop.main)
            .sink { [weak self] map in
                guard let self else { return }
                for (_, quota) in map {
                    if let extras = quota.providerExtras {
                        self.costService.setLiveExtras(extras, for: quota.tool)
                    }
                    self.scheduleClaudeRoutineBudgetPatchIfNeeded(for: quota)
                }
            }
            .store(in: &cancellables)
    }

    func account(for tool: ToolType) -> AccountIdentity? {
        if settingsStore.mockEnabled {
            return MockDataProvider.sampleAccounts().first { $0.tool == tool }
        }
        return accountStore.accounts(for: tool).first
    }

    func quota(for tool: ToolType) -> AccountQuota? {
        guard let account = account(for: tool) else { return nil }
        return quotaService.cachedQuota(for: account.id)
    }

    func reloadProviderCredentialsAndRefresh() {
        hasClaudeWebCookies = ClaudeWebCookieStore.hasCookieHeader()
        hasOpenAIWebCookies = OpenAIWebCookieStore.hasCookieHeader()
        recheckPrimaryRouteHealth()
        importPersistentOpenAICookiesAndRefreshIfNeeded()
        importOpenAIBrowserCookiesAndRefreshIfNeeded()
        importPersistentClaudeCookiesAndRefreshIfNeeded()
        importClaudeBrowserCookiesAndRefreshIfNeeded()
        accountStore.reload(
            codexUsageMode: settingsStore.settings.codexUsageMode,
            claudeUsageMode: settingsStore.claudeUsageMode
        )
        // Cookies may have changed (login / re-login) — drop any stale
        // 1h failure cooldowns so the routine WebView probe gets a fresh
        // chance on the very next quota refresh.
        lastRoutineBudgetAttemptByAccount.removeAll()
        scheduler.triggerRefresh()
        serviceStatus.refreshAll()
    }

    func refreshAll() {
        reloadProviderCredentialsAndRefresh()
    }

    func refreshCostUsage() {
        Task { @MainActor in
            await costService.refreshAll()
        }
    }

    func clearCostData() {
        Task { @MainActor in
            await costService.eraseLocalCostData()
        }
    }

    func refresh(_ tool: ToolType) {
        hasClaudeWebCookies = ClaudeWebCookieStore.hasCookieHeader()
        hasOpenAIWebCookies = OpenAIWebCookieStore.hasCookieHeader()
        recheckPrimaryRouteHealth(provider: tool)
        accountStore.reload(
            codexUsageMode: settingsStore.settings.codexUsageMode,
            claudeUsageMode: settingsStore.claudeUsageMode
        )
        let account = account(for: tool)
        Task { @MainActor in
            if let account {
                _ = await quotaService.refresh(account)
            }
        }
    }

    func recheckPrimaryRouteHealth(provider: ToolType? = nil) {
        let routes = provider.map(PrimaryProviderRoute.routes(for:)) ?? PrimaryProviderRoute.allCases
        var next = routeHealth
        let now = Date()
        for route in routes {
            next[route] = PrimaryProviderRouteHealthChecker.check(route, now: now)
        }
        routeHealth = next
    }

    func showSettingsWindow() {
        settingsWindowController.show(environment: self)
    }

    func openClaudeWebLogin() {
        claudeWebLoginController.open { [weak self] in
            self?.hasClaudeWebCookies = ClaudeWebCookieStore.hasCookieHeader()
            self?.reloadProviderCredentialsAndRefresh()
        }
    }

    func openOpenAIWebLogin() {
        openAIWebLoginController.open { [weak self] in
            self?.hasOpenAIWebCookies = OpenAIWebCookieStore.hasCookieHeader()
            self?.reloadProviderCredentialsAndRefresh()
        }
    }

    /// Open the in-app WebView login flow for a misc provider whose
    /// cookies can't be auto-imported from the user's main browser
    /// (typically because of Chrome v11/app-bound cookie encryption,
    /// which SweetCookieKit doesn't read). After save, kicks a one-shot
    /// quota refresh so the misc card flips out of "Set up" state.
    func openMiscWebLogin(for tool: ToolType) {
        guard let account = account(for: tool) else { return }
        miscWebLoginRegistry.openLogin(for: tool) { [weak self] in
            guard let self else { return }
            Task { _ = await self.quotaService.refresh(account) }
        }
    }

    func importOpenAIBrowserCookies() {
        importOpenAIBrowserCookiesAndRefreshIfNeeded(
            allowKeychainPrompt: true,
            userInitiated: true
        )
    }

    func importClaudeBrowserCookies() {
        importClaudeBrowserCookiesAndRefreshIfNeeded(
            allowKeychainPrompt: true,
            userInitiated: true
        )
    }

    private func importPersistentClaudeCookiesAndRefreshIfNeeded() {
        guard !persistentClaudeCookieImportInFlight else { return }
        persistentClaudeCookieImportInFlight = true
        let hadCookies = hasClaudeWebCookies
        ClaudeWebLoginController.importPersistentClaudeCookiesIfAvailable { [weak self] didImport in
            guard let self else { return }
            self.persistentClaudeCookieImportInFlight = false
            self.hasClaudeWebCookies = ClaudeWebCookieStore.hasCookieHeader()
            self.recheckPrimaryRouteHealth(provider: .claude)
            guard didImport, !hadCookies else { return }
            self.accountStore.reload(
                codexUsageMode: self.settingsStore.settings.codexUsageMode,
                claudeUsageMode: self.settingsStore.claudeUsageMode
            )
            self.lastRoutineBudgetAttemptByAccount.removeAll()
            self.scheduler.triggerRefresh()
        }
    }

    private func importClaudeBrowserCookiesAndRefreshIfNeeded(
        allowKeychainPrompt: Bool = false,
        userInitiated: Bool = false
    ) {
        if !allowKeychainPrompt, ClaudeWebCookieStore.hasCookieHeader() {
            return
        }
        guard !browserClaudeCookieImportInFlight else { return }
        browserClaudeCookieImportInFlight = true
        if userInitiated {
            isImportingClaudeBrowserCookies = true
            claudeBrowserCookieImportStatus = "Importing from browser..."
        }

        let importTask = Task.detached(priority: userInitiated ? .userInitiated : .utility) {
            try? ClaudeBrowserCookieImporter.importAndStoreFromBrowsers(
                allowKeychainPrompt: allowKeychainPrompt
            )
        }
        Task { @MainActor [weak self] in
            let result = await importTask.value
            guard let self else { return }
            self.browserClaudeCookieImportInFlight = false
            if userInitiated {
                self.isImportingClaudeBrowserCookies = false
            }
            self.hasClaudeWebCookies = ClaudeWebCookieStore.hasCookieHeader()
            self.recheckPrimaryRouteHealth(provider: .claude)
            guard let result else {
                if userInitiated {
                    self.claudeBrowserCookieImportStatus = "No Claude sessionKey found in readable browser cookies."
                }
                return
            }
            if userInitiated {
                self.claudeBrowserCookieImportStatus = "Imported from \(result.sourceLabel)."
            }
            self.accountStore.reload(
                codexUsageMode: self.settingsStore.settings.codexUsageMode,
                claudeUsageMode: self.settingsStore.claudeUsageMode
            )
            self.lastRoutineBudgetAttemptByAccount.removeAll()
            self.scheduler.triggerRefresh()
        }
    }

    private func importPersistentOpenAICookiesAndRefreshIfNeeded() {
        guard !persistentOpenAICookieImportInFlight else { return }
        persistentOpenAICookieImportInFlight = true
        let hadCookies = hasOpenAIWebCookies
        OpenAIWebLoginController.importPersistentOpenAICookiesIfAvailable { [weak self] didImport in
            guard let self else { return }
            self.persistentOpenAICookieImportInFlight = false
            self.hasOpenAIWebCookies = OpenAIWebCookieStore.hasCookieHeader()
            self.recheckPrimaryRouteHealth(provider: .codex)
            guard didImport, !hadCookies else { return }
            self.accountStore.reload(
                codexUsageMode: self.settingsStore.settings.codexUsageMode,
                claudeUsageMode: self.settingsStore.claudeUsageMode
            )
            self.scheduler.triggerRefresh()
        }
    }

    private func importOpenAIBrowserCookiesAndRefreshIfNeeded(
        allowKeychainPrompt: Bool = false,
        userInitiated: Bool = false
    ) {
        if !allowKeychainPrompt, OpenAIWebCookieStore.hasCookieHeader() {
            return
        }
        guard !browserOpenAICookieImportInFlight else { return }
        browserOpenAICookieImportInFlight = true
        if userInitiated {
            isImportingOpenAIBrowserCookies = true
            openAIBrowserCookieImportStatus = "Importing from browser..."
        }

        let importTask = Task.detached(priority: userInitiated ? .userInitiated : .utility) {
            try? OpenAIBrowserCookieImporter.importAndStoreFromBrowsers(
                allowKeychainPrompt: allowKeychainPrompt
            )
        }
        Task { @MainActor [weak self] in
            let result = await importTask.value
            guard let self else { return }
            self.browserOpenAICookieImportInFlight = false
            if userInitiated {
                self.isImportingOpenAIBrowserCookies = false
            }
            self.hasOpenAIWebCookies = OpenAIWebCookieStore.hasCookieHeader()
            self.recheckPrimaryRouteHealth(provider: .codex)
            guard let result else {
                if userInitiated {
                    self.openAIBrowserCookieImportStatus = "No ChatGPT session cookies found in readable browser cookies."
                }
                return
            }
            if userInitiated {
                self.openAIBrowserCookieImportStatus = "Imported from \(result.sourceLabel)."
            }
            self.accountStore.reload(
                codexUsageMode: self.settingsStore.settings.codexUsageMode,
                claudeUsageMode: self.settingsStore.claudeUsageMode
            )
            self.scheduler.triggerRefresh()
        }
    }

    @discardableResult
    func deleteClaudeWebCookies() -> Bool {
        do {
            ClaudeWebLoginController.clearPersistentClaudeWebsiteData()
            try ClaudeWebCookieStore.deleteCookieHeader()
            claudeBrowserCookieImportStatus = nil
            hasClaudeWebCookies = false
            recheckPrimaryRouteHealth(provider: .claude)
            for account in accountStore.accounts(for: .claude) {
                quotaService.clear(accountId: account.id)
            }
            accountStore.reload(
                codexUsageMode: settingsStore.settings.codexUsageMode,
                claudeUsageMode: settingsStore.claudeUsageMode
            )
            scheduler.triggerRefresh()
            return true
        } catch {
            SafeLog.warn("Deleting Claude web cookies failed: \(SafeLog.sanitize(error.localizedDescription))")
            hasClaudeWebCookies = ClaudeWebCookieStore.hasCookieHeader()
            return false
        }
    }

    @discardableResult
    func deleteOpenAIWebCookies() -> Bool {
        do {
            OpenAIWebLoginController.clearPersistentOpenAIWebsiteData()
            try OpenAIWebCookieStore.deleteCookieHeader()
            openAIBrowserCookieImportStatus = nil
            hasOpenAIWebCookies = false
            recheckPrimaryRouteHealth(provider: .codex)
            for account in accountStore.accounts(for: .codex) {
                quotaService.clear(accountId: account.id)
            }
            accountStore.reload(
                codexUsageMode: settingsStore.settings.codexUsageMode,
                claudeUsageMode: settingsStore.claudeUsageMode
            )
            scheduler.triggerRefresh()
            return true
        } catch {
            SafeLog.warn("Deleting OpenAI web cookies failed: \(SafeLog.sanitize(error.localizedDescription))")
            hasOpenAIWebCookies = OpenAIWebCookieStore.hasCookieHeader()
            return false
        }
    }

    /// Fallback Claude run-budget probe spins up a hidden WKWebView to scrape
    /// `claude.ai/v1/code/routines/run-budget`. Loading a real browser engine
    /// is expensive (~50–200 ms CPU plus memory) and the probe usually fails
    /// in a predictable way (no cookies, or the endpoint is gated). After a
    /// failure we hold off for an hour so we don't re-spin the WebView on
    /// every 10-minute quota refresh; on success the bucket gets a "used /
    /// limit" `shortLabel` containing "/", so this scheduler short-circuits
    /// at the next refresh anyway.
    private static let routineBudgetFailureCooldown: TimeInterval = 3600

    private func scheduleClaudeRoutineBudgetPatchIfNeeded(for quota: AccountQuota) {
        guard quota.tool == .claude, !settingsStore.mockEnabled else { return }
        guard let routine = quota.bucket(id: "daily_routines") else { return }
        guard !routine.shortLabel.contains("/") else { return }
        guard !routineBudgetInFlightAccountIds.contains(quota.accountId) else { return }
        // No cookies → the WebView would just load the login page and the
        // parser would never see a budget JSON. Spinning it up costs CPU
        // for no chance of success.
        guard !ClaudeWebCookieStore.candidateCookieHeaders().isEmpty else { return }
        let now = Date()
        if let last = lastRoutineBudgetAttemptByAccount[quota.accountId],
           now.timeIntervalSince(last) < Self.routineBudgetFailureCooldown {
            return
        }
        routineBudgetInFlightAccountIds.insert(quota.accountId)
        lastRoutineBudgetAttemptByAccount[quota.accountId] = now

        Task { @MainActor [weak self, accountId = quota.accountId] in
            guard let self else { return }
            defer { self.routineBudgetInFlightAccountIds.remove(accountId) }
            guard let result = await ClaudeRoutineBudgetWebViewFetcher.fetch() else { return }
            self.quotaService.replaceBucket(self.routinesBucket(from: result), for: accountId)
            // Success: clear the cooldown so a future cookie rotation can
            // reach the WebView immediately if the bucket regresses.
            self.lastRoutineBudgetAttemptByAccount.removeValue(forKey: accountId)
        }
    }

    private func routinesBucket(from result: ClaudeRoutinesFetcher.Result) -> QuotaBucket {
        QuotaBucket(
            id: "daily_routines",
            title: "Today · \(result.used) / \(result.limit)",
            shortLabel: "\(result.used)/\(result.limit)",
            usedPercent: result.usedPercent,
            resetAt: nextRoutineResetDate(),
            rawWindowSeconds: 86_400,
            groupTitle: "Daily Routines"
        )
    }

    private func nextRoutineResetDate(now: Date = Date()) -> Date? {
        Calendar.current.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        )
    }
}
