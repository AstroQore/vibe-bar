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
    let remoteProbeService: RemoteProbeService
    let updateController: AppUpdateController
    /// Per-page card arrangement, shared by the popover and the Settings
    /// layout editor. Loads `~/.vibebar/layout.json` once at startup.
    let pageLayout: PageLayoutModel
    /// Per-request usage ledger, opened once. `nil` when the SQLite file
    /// cannot be opened — every reader treats that as "no history", so a
    /// broken ledger costs the usage page, not the app.
    let usageLedger: UsageEventLedger?
    /// Local MCP server. Built here so its lifetime matches the app's; the
    /// socket itself exists only while `AppSettings.mcpServer.enabled` is on.
    private(set) var mcp: MCPController!
    /// One skills actor for the whole process, shared by the Workbench's
    /// Skills page and the MCP `skills.install` tool. Two instances would mean
    /// two writers doing read-modify-write on `~/.vibebar/skills.json`, so an
    /// agent installing a skill while the page is open could drop a record.
    /// Free to hold: the registry file is read lazily on first access.
    let skillsService = SkillsService()

    @Published private(set) var hasClaudeWebCookies: Bool
    @Published private(set) var hasOpenAIWebCookies: Bool
    @Published private(set) var hasGeminiWebCookies: Bool
    @Published private(set) var hasGrokWebCookies: Bool
    @Published private(set) var isImportingOpenAIBrowserCookies = false
    @Published private(set) var isImportingClaudeBrowserCookies = false
    @Published private(set) var isImportingGeminiBrowserCookies = false
    @Published private(set) var isImportingGrokBrowserCookies = false
    @Published private(set) var openAIBrowserCookieImportStatus: String?
    @Published private(set) var claudeBrowserCookieImportStatus: String?
    @Published private(set) var geminiBrowserCookieImportStatus: String?
    @Published private(set) var grokBrowserCookieImportStatus: String?
    @Published private(set) var routeHealth: [PrimaryProviderRoute: PrimaryProviderRouteHealth]
    @Published private(set) var pricingRefreshStatus = MultiSourcePricingRefresher.loadStatus()
    @Published private(set) var isRefreshingPricing = false
    @Published private(set) var menuBarWatchdog: MenuBarBlockWatchdog?

    private let openAIWebLoginController = OpenAIWebLoginController()
    private let claudeWebLoginController = ClaudeWebLoginController()
    private let miscWebLoginRegistry = MiscWebLoginRegistry()
    private let workbenchWindowController = WorkbenchWindowController()
    private var workbenchServicesStorage: WorkbenchServices?
    private var cancellables: Set<AnyCancellable> = []
    private var routineBudgetInFlightAccountIds: Set<String> = []
    private var lastRoutineBudgetAttemptByAccount: [String: Date] = [:]
    private var persistentClaudeCookieImportInFlight = false
    private var browserClaudeCookieImportInFlight = false
    private var persistentOpenAICookieImportInFlight = false
    private var browserOpenAICookieImportInFlight = false
    private var browserGeminiCookieImportInFlight = false
    private var browserGrokCookieImportInFlight = false
    private var pricingRefreshTask: Task<Void, Never>?
    private var webCookiePresenceProbedAt: Date?
    private var webCookiePresenceGeneration: UInt64 = 0
    private var routeHealthProbeGeneration: UInt64 = 0
    private var routeHealthWriteGeneration: [PrimaryProviderRoute: UInt64] = [:]
    private var remoteCostAggregationGeneration: UInt64 = 0
    private var menuBarReregisterHandler: (() -> Void)?
    /// Long enough to fold the probes of one refresh burst — the Gemini card
    /// refreshes two providers back to back — and short enough that a cookie
    /// change made outside Vibe Bar still shows up on the next manual refresh.
    private static let webCookiePresenceTTL: TimeInterval = 5

    init() {
        let settings = SettingsStore()
        let isDemo = DemoMode.isEnabled
        self.updateController = AppUpdateController(
            updateChannel: settings.settings.updateChannel,
            // Sparkle would otherwise read its own defaults and may decide a
            // daily check is due the moment the updater starts.
            isEnabled: !isDemo
        )
        let accounts = AccountStore(
            codexUsageMode: settings.codexUsageMode,
            claudeUsageMode: settings.claudeUsageMode,
            geminiUsageMode: settings.geminiUsageMode,
            antigravityUsageMode: settings.antigravityUsageMode,
            miscProviderInstances: settings.settings.miscProviderInstances
        )
        let service = QuotaService.makeDefault(
            mockProvider: { [weak settings] in
                settings?.mockEnabled ?? false
            },
            retentionProvider: { [weak settings] in
                settings?.settings.costData.retentionDays ?? CostDataSettings.defaultRetentionDays
            },
            initialAccountIds: accounts.accounts.map(\.id),
            geminiWebFallback: { account, cookieHeader in
                try await GeminiWebQuotaCalibrator.shared.fetch(
                    account: account,
                    cookieHeader: cookieHeader
                )
            }
        )

        self.settingsStore = settings
        self.accountStore = accounts
        self.quotaService = service
        self.pageLayout = PageLayoutModel(settingsStore: settings)
        self.serviceStatus = ServiceStatusController()
        let ledger: UsageEventLedger?
        do {
            ledger = try UsageEventLedger()
        } catch {
            SafeLog.warn("Opening the usage ledger failed: \(SafeLog.sanitize(error.localizedDescription))")
            ledger = nil
        }
        self.usageLedger = ledger
        let costService = CostUsageService(mockProvider: { [weak settings] in
            settings?.mockEnabled ?? false
        }, costDataSettingsProvider: { [weak settings] in
            settings?.settings.costData ?? .default
        }, usageLedger: ledger)
        self.costService = costService
        self.remoteProbeService = RemoteProbeService()

        // Give the quota refresh path the same activity inputs the popover
        // passes when it renders a forecast (see
        // `SubscriptionUtilizationView.paceForecast(for:)`), so the projection
        // recorded into the forecast timeline is the projection the user saw.
        // Cached published state only — this runs after every successful quota
        // refresh and must never trigger a cost scan.
        service.activityContextProvider = { [weak costService] tool in
            guard let snapshot = costService?.snapshot(for: tool) else { return .empty }
            return QuotaActivityContext(
                heatmap: snapshot.heatmap,
                dailyActivity: snapshot.dailyHistory
            )
        }
        // What the discovered-field registry must not forget: every field a
        // mini window selects, every field the user has named, and every
        // *group* the user has named — shared or per-window. Anything else
        // that vanishes from a provider's response was never the user's and
        // drops on the next refresh.
        service.registryKeepProvider = { [weak settingsStore] in
            guard let mini = settingsStore?.settings.miniWindow else { return QuotaFieldKeepSet() }
            var fieldIds = Set(mini.customLabels.keys)
            var groupKeys = Set(mini.groupLabels.keys)
            for window in mini.windows {
                fieldIds.formUnion(window.fieldIds)
                fieldIds.formUnion(window.customLabels.keys)
                groupKeys.formUnion(window.groupLabels.keys)
            }
            return QuotaFieldKeepSet(fieldIds: fieldIds, groupKeys: groupKeys)
        }

        if isDemo {
            // No Keychain in demo mode. A web-sourced demo account stands in
            // for "cookies are present", which is all these flags gate.
            func declaresWebAccount(_ tool: ToolType) -> Bool {
                accounts.accounts(for: tool).contains { $0.source == .webCookie }
            }
            self.hasClaudeWebCookies = declaresWebAccount(.claude)
            self.hasOpenAIWebCookies = declaresWebAccount(.codex)
            self.hasGeminiWebCookies = declaresWebAccount(.gemini)
            self.hasGrokWebCookies = declaresWebAccount(.grok)
        } else {
            self.hasClaudeWebCookies = ClaudeWebCookieStore.hasCookieHeader()
            self.hasOpenAIWebCookies = OpenAIWebCookieStore.hasCookieHeader()
            self.hasGeminiWebCookies = GeminiWebCookieStore.hasCookieHeader()
            self.hasGrokWebCookies = GrokWebCookieStore.hasCookieHeader()
        }
        // Filled in by the async probe at the end of `init`. Checking all
        // twelve routes synchronously here meant launch blocked on a dozen
        // Keychain round trips plus a `/bin/ps` spawn before the menu bar item
        // even appeared; the surfaces that read this treat a missing route as
        // "not checked yet", which for the first few milliseconds is the truth.
        self.routeHealth = [:]

        let scheduler = QuotaRefreshScheduler(
            service: service,
            accountsProvider: { [weak accounts, weak settings] in
                guard let accounts, let settings else { return [] }
                if settings.mockEnabled {
                    return MockDataProvider.sampleAccounts()
                }
                var visibleAccounts: [AccountIdentity] = []
                for tool in ToolType.dedicatedCardProviders {
                    if let account = accounts.accounts(for: tool).first {
                        visibleAccounts.append(account)
                    }
                }
                for instance in settings.settings.visibleMiscProviderInstances {
                    if let account = accounts.account(forMiscProviderInstanceID: instance.id) {
                        visibleAccounts.append(account)
                    }
                }
                return visibleAccounts
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
                    && $0.geminiUsageMode == $1.geminiUsageMode
                    && $0.antigravityUsageMode == $1.antigravityUsageMode
                    && $0.miscProviderInstances == $1.miscProviderInstances
            }
            .sink { [weak self] settings in
                // Adapters resolve usage modes and misc-provider plans from
                // settings.json on disk; make sure the edit is there before
                // the refresh this sink triggers reads it. `@Published` emits
                // during willSet, so flush the emitted value, not the store's.
                self?.settingsStore.flush(settings)
                self?.accountStore.reload(
                    codexUsageMode: settings.codexUsageMode,
                    claudeUsageMode: settings.claudeUsageMode,
                    geminiUsageMode: settings.geminiUsageMode,
                    antigravityUsageMode: settings.antigravityUsageMode,
                    miscProviderInstances: settings.miscProviderInstances
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
                    && $0.geminiUsageMode == $1.geminiUsageMode
                    && $0.antigravityUsageMode == $1.antigravityUsageMode
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

        settings.$settings
            .dropFirst()
            .map(\.updateChannel)
            .removeDuplicates()
            .sink { [weak self] channel in
                self?.updateController.setUpdateChannel(channel)
            }
            .store(in: &cancellables)

        settings.$settings
            .dropFirst()
            .map(\.pricingRefreshIntervalSeconds)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.schedulePricingRefreshLoop()
            }
            .store(in: &cancellables)

        settings.$settings
            .dropFirst()
            .map(\.modelPricingOverrides)
            .removeDuplicates()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] overrides in
                guard let self else { return }
                let result = MultiSourcePricingRefresher.rebuildFromCaches(
                    overrides: overrides
                )
                self.pricingRefreshStatus = result.status
                if result.changed {
                    _ = PricingResolver.reloadIfChanged()
                    Task { @MainActor [weak self] in
                        await self?.costService.refreshAll()
                    }
                }
            }
            .store(in: &cancellables)

        // Remote facts become visible to cost surfaces only after the user
        // selects their machine IDs. Rebuild after either a successful Relay
        // import or a selection change; generation fencing prevents a slower
        // old selection from publishing after a newer click.
        remoteProbeService.$machines
            .combineLatest(
                settings.$settings
                    .map(\.remoteCostIncludedMachineIDs)
                    .removeDuplicates()
            )
            .sink { [weak self] _, machineIDs in
                self?.scheduleRemoteCostAggregation(machineIDs: machineIDs)
            }
            .store(in: &cancellables)

        // Last, and after every service it reads from is live: an agent that
        // connects the instant the socket appears must not race a half-built
        // environment. Demo mode keeps the server: its socket lives inside
        // the demo home and answers from the demo store, and the Settings
        // pane that documents it is one of the screenshots.
        let mcp = MCPController(environment: self)
        self.mcp = mcp
        mcp.start(settingsStore: settings)

        // Demo mode stops here. Everything below either leaves the demo home
        // (provider, status, pricing and Relay refreshes; Keychain and browser
        // cookie imports) or would overwrite the snapshot the home shipped
        // with (the cost rescan). See `DemoMode`.
        guard !isDemo else { return }

        scheduler.start()
        serviceStatus.start()
        remoteProbeService.start()

        // Kick off an initial cost scan in the background. Cost data updates
        // slowly compared to live quota, so we re-scan only on app relaunch,
        // data-source settings changes, or the explicit Cost Data rescan button.
        Task { @MainActor in
            await costService.applyCostDataSettings()
            await costService.refreshAll()
        }

        // Refresh every source immediately and then at the interval selected
        // in Settings. Each source has its own last-known-good cache, so one
        // broken upstream does not erase the other catalogs.
        schedulePricingRefreshLoop()
        recheckPrimaryRouteHealth()
        importPersistentClaudeCookiesAndRefreshIfNeeded()
        importClaudeBrowserCookiesAndRefreshIfNeeded()
        importPersistentOpenAICookiesAndRefreshIfNeeded()
        importOpenAIBrowserCookiesAndRefreshIfNeeded()
        importGeminiBrowserCookiesAndRefreshIfNeeded()
        importGrokBrowserCookiesAndRefreshIfNeeded()

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

    deinit {
        pricingRefreshTask?.cancel()
    }

    func refreshPricingNow() {
        guard !DemoMode.isEnabled else { return }
        Task { @MainActor [weak self] in
            await self?.refreshPricing()
        }
    }

    private func schedulePricingRefreshLoop() {
        pricingRefreshTask?.cancel()
        pricingRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshPricing()
                let seconds = max(
                    self.settingsStore.settings.pricingRefreshIntervalSeconds,
                    15 * 60
                )
                do {
                    try await Task.sleep(for: .seconds(seconds))
                } catch {
                    return
                }
            }
        }
    }

    private func refreshPricing() async {
        guard !isRefreshingPricing else { return }
        isRefreshingPricing = true
        defer { isRefreshingPricing = false }

        let result = await MultiSourcePricingRefresher.refreshAll(
            overrides: settingsStore.settings.modelPricingOverrides
        )
        pricingRefreshStatus = result.status
        if result.changed {
            _ = PricingResolver.reloadIfChanged()
            await costService.refreshAll()
        }
    }

    private func scheduleRemoteCostAggregation(machineIDs: Set<String>) {
        remoteCostAggregationGeneration &+= 1
        let generation = remoteCostAggregationGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshots = await remoteProbeService.costSnapshots(
                includingMachineIDs: machineIDs
            )
            guard generation == remoteCostAggregationGeneration else { return }
            costService.setRemoteSnapshots(snapshots)
        }
    }

    func account(for tool: ToolType) -> AccountIdentity? {
        if settingsStore.mockEnabled {
            return MockDataProvider.sampleAccounts().first { $0.tool == tool }
        }
        return accountStore.accounts(for: tool).first
    }

    func account(for instance: MiscProviderInstance) -> AccountIdentity? {
        if settingsStore.mockEnabled {
            return MockDataProvider.sampleAccounts().first { $0.tool == instance.tool }
        }
        return accountStore.account(forMiscProviderInstanceID: instance.id)
    }

    func quota(for tool: ToolType) -> AccountQuota? {
        guard let account = account(for: tool) else { return nil }
        return quotaService.cachedQuota(for: account.id)
    }

    func quota(for instance: MiscProviderInstance) -> AccountQuota? {
        guard let account = account(for: instance) else { return nil }
        return quotaService.cachedQuota(for: account.id)
    }

    func reloadProviderCredentialsAndRefresh() {
        // The Refresh button reaches here too. Demo mode has nothing to
        // reload — no cookies, no credentials, no routes — and the importers
        // below read browser stores outside the demo home.
        guard !DemoMode.isEnabled else { return }
        // Forced: this is the path a login, a sign-out, or an explicit "reload
        // credentials" takes, so a cached presence reading would be exactly the
        // wrong answer.
        refreshWebCookiePresence(force: true)
        recheckPrimaryRouteHealth()
        importPersistentOpenAICookiesAndRefreshIfNeeded()
        importOpenAIBrowserCookiesAndRefreshIfNeeded()
        importPersistentClaudeCookiesAndRefreshIfNeeded()
        importClaudeBrowserCookiesAndRefreshIfNeeded()
        importGeminiBrowserCookiesAndRefreshIfNeeded()
        importGrokBrowserCookiesAndRefreshIfNeeded()
        accountStore.reload(
            codexUsageMode: settingsStore.settings.codexUsageMode,
            claudeUsageMode: settingsStore.claudeUsageMode,
            geminiUsageMode: settingsStore.geminiUsageMode,
            antigravityUsageMode: settingsStore.antigravityUsageMode,
            miscProviderInstances: settingsStore.settings.miscProviderInstances
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
        Task { @MainActor [weak self] in
            await self?.remoteProbeService.refresh()
        }
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
        refreshWebCookiePresence()
        recheckPrimaryRouteHealth(provider: tool)
        accountStore.reload(
            codexUsageMode: settingsStore.settings.codexUsageMode,
            claudeUsageMode: settingsStore.claudeUsageMode,
            geminiUsageMode: settingsStore.geminiUsageMode,
            antigravityUsageMode: settingsStore.antigravityUsageMode,
            miscProviderInstances: settingsStore.settings.miscProviderInstances
        )
        let account = account(for: tool)
        Task { @MainActor in
            if let account {
                _ = await quotaService.refresh(account)
            }
        }
    }

    func refresh(_ instance: MiscProviderInstance) {
        guard let account = account(for: instance) else { return }
        Task { @MainActor in
            _ = await quotaService.refresh(account)
        }
    }

    /// Re-probe the credential routes behind one provider, or all of them.
    ///
    /// Runs off the main actor: every route reads a credential file, a Keychain
    /// item, or — for AntiGravity — spawns `/bin/ps` and blocks on it, and this
    /// is reached from every refresh, including the one a popover open triggers.
    /// The results land back in one published assignment.
    func recheckPrimaryRouteHealth(provider: ToolType? = nil) {
        let routes = provider.map(PrimaryProviderRoute.routes(for:)) ?? PrimaryProviderRoute.allCases
        // Probes overlap: a slow all-route sweep can still be reading files
        // when a credential change fires a short provider-specific probe. The
        // newer probe describes the newer world, so each route remembers the
        // generation that last wrote it and an older sweep cannot roll it back.
        routeHealthProbeGeneration &+= 1
        let generation = routeHealthProbeGeneration
        Task { @MainActor [weak self] in
            let checked = await PrimaryProviderRouteHealthChecker.checkOffActor(routes, now: Date())
            guard let self else { return }
            var merged = self.routeHealth
            for (route, health) in checked {
                if let written = self.routeHealthWriteGeneration[route], written > generation { continue }
                merged[route] = health
                self.routeHealthWriteGeneration[route] = generation
            }
            self.routeHealth = merged
        }
    }

    /// Whether each provider has a saved web session cookie.
    ///
    /// Four Keychain round trips, and `SecureCookieHeaderStore` only caches
    /// *found* items — a provider the user has never signed into re-queries the
    /// Keychain every single time. That used to happen on the main actor once
    /// per refresh and once per *provider* refresh, so opening the Gemini card
    /// alone paid for eight of them. Probed off the actor, and reused inside one
    /// refresh burst so the Gemini pair does not probe twice.
    private func refreshWebCookiePresence(force: Bool = false) {
        let now = Date()
        if !force,
           let probedAt = webCookiePresenceProbedAt,
           now.timeIntervalSince(probedAt) < Self.webCookiePresenceTTL {
            return
        }
        webCookiePresenceProbedAt = now
        // The snapshot is all-or-nothing, so only the newest probe may publish:
        // a login or cookie deletion forces a fresh probe, and a still-running
        // older one finishing after it must not put the pre-login state back.
        webCookiePresenceGeneration &+= 1
        let generation = webCookiePresenceGeneration
        Task { @MainActor [weak self] in
            let presence = await Task.detached(priority: .userInitiated) {
                WebCookiePresence(
                    claude: ClaudeWebCookieStore.hasCookieHeader(),
                    openAI: OpenAIWebCookieStore.hasCookieHeader(),
                    gemini: GeminiWebCookieStore.hasCookieHeader(),
                    grok: GrokWebCookieStore.hasCookieHeader()
                )
            }.value
            guard let self, generation == self.webCookiePresenceGeneration else { return }
            self.hasClaudeWebCookies = presence.claude
            self.hasOpenAIWebCookies = presence.openAI
            self.hasGeminiWebCookies = presence.gemini
            self.hasGrokWebCookies = presence.grok
        }
    }

    private struct WebCookiePresence: Sendable {
        let claude: Bool
        let openAI: Bool
        let gemini: Bool
        let grok: Bool
    }

    func showSettingsWindow() {
        showWorkbench(page: .settings)
    }

    func registerMenuBarHealth(
        watchdog: MenuBarBlockWatchdog,
        reregister: @escaping () -> Void
    ) {
        menuBarWatchdog = watchdog
        menuBarReregisterHandler = reregister
    }

    func repairMenuBarAllowList() async -> MenuBarAllowListRepair.Outcome {
        let outcome = await MenuBarAllowListRepair.apply()
        guard outcome.succeeded else { return outcome }
        // A clean allow-list can still leave this process holding the stale
        // NSStatusItem that the script tells shell users to recreate by
        // relaunching. The in-app path can do that narrower re-registration
        // for both successful outcomes without stopping MCP or the app.
        menuBarReregisterHandler?()
        for _ in 0..<6 {
            try? await Task.sleep(for: .milliseconds(500))
            menuBarWatchdog?.checkNow()
            if menuBarWatchdog?.report.state == .healthy { return outcome }
        }
        return MenuBarAllowListRepair.Outcome(
            status: .failed,
            message: outcome.changed
                ? "The allow-list was repaired, but the status item has not become visible yet."
                : "The allow-list is clean, but the status item is still not visible."
        )
    }

    func showWorkbench(page: WorkbenchPage? = nil) {
        workbenchWindowController.show(environment: self, page: page)
    }

    func showSettings(_ destination: SettingsDestination) {
        workbenchWindowController.show(environment: self, page: .settings, settingsDestination: destination)
    }

    /// Built on the first Workbench open and kept for the process lifetime, so
    /// reopening the window lands on the state the user left rather than on a
    /// fresh set of queries.
    var workbenchServices: WorkbenchServices {
        if let workbenchServicesStorage { return workbenchServicesStorage }
        let services = WorkbenchServices(
            usageLedger: usageLedger,
            costService: costService,
            settingsStore: settingsStore,
            skillsService: skillsService
        )
        workbenchServicesStorage = services
        return services
    }

    /// Front an already-open Workbench without creating one. Used by the Dock
    /// reopen path, which must not resurrect a window the user just closed.
    @discardableResult
    func frontWorkbenchIfOpen() -> Bool {
        workbenchWindowController.frontExistingWindow()
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
        openMiscWebLogin(for: tool, instanceID: tool.rawValue)
    }

    func openMiscWebLogin(for tool: ToolType, instanceID: String) {
        guard let account = accountStore.account(forMiscProviderInstanceID: instanceID) else { return }
        miscWebLoginRegistry.openLogin(for: tool, instanceID: instanceID) { [weak self] in
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

    func importGeminiBrowserCookies() {
        importGeminiBrowserCookiesAndRefreshIfNeeded(
            allowKeychainPrompt: true,
            userInitiated: true
        )
    }

    func importGrokBrowserCookies() {
        importGrokBrowserCookiesAndRefreshIfNeeded(
            allowKeychainPrompt: true,
            userInitiated: true
        )
    }

    private func importGrokBrowserCookiesAndRefreshIfNeeded(
        allowKeychainPrompt: Bool = false,
        userInitiated: Bool = false
    ) {
        if !allowKeychainPrompt, GrokWebCookieStore.hasCookieHeader() {
            return
        }
        guard !browserGrokCookieImportInFlight else { return }
        browserGrokCookieImportInFlight = true
        if userInitiated {
            isImportingGrokBrowserCookies = true
            grokBrowserCookieImportStatus = "Importing from browser..."
        }

        let importTask = Task.detached(priority: userInitiated ? .userInitiated : .utility) {
            try? GrokBrowserCookieImporter.importAndStoreFromBrowsers(
                allowKeychainPrompt: allowKeychainPrompt
            )
        }
        Task { @MainActor [weak self] in
            let result = await importTask.value
            guard let self else { return }
            self.browserGrokCookieImportInFlight = false
            if userInitiated {
                self.isImportingGrokBrowserCookies = false
            }
            self.hasGrokWebCookies = GrokWebCookieStore.hasCookieHeader()
            self.recheckPrimaryRouteHealth(provider: .grok)
            guard let result else {
                if userInitiated {
                    self.grokBrowserCookieImportStatus = "No Grok cookies found in readable browser stores."
                }
                return
            }
            if userInitiated {
                self.grokBrowserCookieImportStatus = "Imported from \(result.sourceLabel)."
            }
            self.accountStore.reload(
                codexUsageMode: self.settingsStore.settings.codexUsageMode,
                claudeUsageMode: self.settingsStore.claudeUsageMode,
                geminiUsageMode: self.settingsStore.geminiUsageMode,
                antigravityUsageMode: self.settingsStore.antigravityUsageMode,
                miscProviderInstances: self.settingsStore.settings.miscProviderInstances
            )
            self.scheduler.triggerRefresh()
        }
    }

    private func importGeminiBrowserCookiesAndRefreshIfNeeded(
        allowKeychainPrompt: Bool = false,
        userInitiated: Bool = false
    ) {
        if !allowKeychainPrompt, GeminiWebCookieStore.hasCookieHeader() {
            return
        }
        guard !browserGeminiCookieImportInFlight else { return }
        browserGeminiCookieImportInFlight = true
        if userInitiated {
            isImportingGeminiBrowserCookies = true
            geminiBrowserCookieImportStatus = "Importing from browser..."
        }

        let importTask = Task.detached(priority: userInitiated ? .userInitiated : .utility) {
            try? GeminiBrowserCookieImporter.importAndStoreFromBrowsers(
                allowKeychainPrompt: allowKeychainPrompt
            )
        }
        Task { @MainActor [weak self] in
            let result = await importTask.value
            guard let self else { return }
            self.browserGeminiCookieImportInFlight = false
            if userInitiated {
                self.isImportingGeminiBrowserCookies = false
            }
            self.hasGeminiWebCookies = GeminiWebCookieStore.hasCookieHeader()
            self.recheckPrimaryRouteHealth(provider: .gemini)
            guard let result else {
                if userInitiated {
                    self.geminiBrowserCookieImportStatus = "No Gemini cookies found in readable browser stores."
                }
                return
            }
            if userInitiated {
                self.geminiBrowserCookieImportStatus = "Imported from \(result.sourceLabel)."
            }
            self.accountStore.reload(
                codexUsageMode: self.settingsStore.settings.codexUsageMode,
                claudeUsageMode: self.settingsStore.claudeUsageMode,
                geminiUsageMode: self.settingsStore.geminiUsageMode,
                antigravityUsageMode: self.settingsStore.antigravityUsageMode,
                miscProviderInstances: self.settingsStore.settings.miscProviderInstances
            )
            self.scheduler.triggerRefresh()
        }
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
                claudeUsageMode: self.settingsStore.claudeUsageMode,
                geminiUsageMode: self.settingsStore.geminiUsageMode,
                antigravityUsageMode: self.settingsStore.antigravityUsageMode,
                miscProviderInstances: self.settingsStore.settings.miscProviderInstances
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
                claudeUsageMode: self.settingsStore.claudeUsageMode,
                geminiUsageMode: self.settingsStore.geminiUsageMode,
                antigravityUsageMode: self.settingsStore.antigravityUsageMode,
                miscProviderInstances: self.settingsStore.settings.miscProviderInstances
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
                claudeUsageMode: self.settingsStore.claudeUsageMode,
                geminiUsageMode: self.settingsStore.geminiUsageMode,
                antigravityUsageMode: self.settingsStore.antigravityUsageMode,
                miscProviderInstances: self.settingsStore.settings.miscProviderInstances
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
                claudeUsageMode: self.settingsStore.claudeUsageMode,
                geminiUsageMode: self.settingsStore.geminiUsageMode,
                antigravityUsageMode: self.settingsStore.antigravityUsageMode,
                miscProviderInstances: self.settingsStore.settings.miscProviderInstances
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
                claudeUsageMode: settingsStore.claudeUsageMode,
                geminiUsageMode: settingsStore.geminiUsageMode,
                antigravityUsageMode: settingsStore.antigravityUsageMode,
                miscProviderInstances: settingsStore.settings.miscProviderInstances
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
                claudeUsageMode: settingsStore.claudeUsageMode,
                geminiUsageMode: settingsStore.geminiUsageMode,
                antigravityUsageMode: settingsStore.antigravityUsageMode,
                miscProviderInstances: settingsStore.settings.miscProviderInstances
            )
            scheduler.triggerRefresh()
            return true
        } catch {
            SafeLog.warn("Deleting OpenAI web cookies failed: \(SafeLog.sanitize(error.localizedDescription))")
            hasOpenAIWebCookies = OpenAIWebCookieStore.hasCookieHeader()
            return false
        }
    }

    @discardableResult
    func deleteGeminiWebCookies() -> Bool {
        do {
            try GeminiWebCookieStore.deleteCookieHeader()
            geminiBrowserCookieImportStatus = nil
            hasGeminiWebCookies = false
            recheckPrimaryRouteHealth(provider: .gemini)
            for account in accountStore.accounts(for: .gemini) {
                quotaService.clear(accountId: account.id)
            }
            accountStore.reload(
                codexUsageMode: settingsStore.settings.codexUsageMode,
                claudeUsageMode: settingsStore.claudeUsageMode,
                geminiUsageMode: settingsStore.geminiUsageMode,
                antigravityUsageMode: settingsStore.antigravityUsageMode,
                miscProviderInstances: settingsStore.settings.miscProviderInstances
            )
            scheduler.triggerRefresh()
            return true
        } catch {
            SafeLog.warn("Deleting Gemini web cookies failed: \(SafeLog.sanitize(error.localizedDescription))")
            hasGeminiWebCookies = GeminiWebCookieStore.hasCookieHeader()
            return false
        }
    }

    @discardableResult
    func deleteGrokWebCookies() -> Bool {
        do {
            try GrokWebCookieStore.deleteCookieHeader()
            grokBrowserCookieImportStatus = nil
            hasGrokWebCookies = false
            recheckPrimaryRouteHealth(provider: .grok)
            for account in accountStore.accounts(for: .grok) {
                quotaService.clear(accountId: account.id)
            }
            accountStore.reload(
                codexUsageMode: settingsStore.settings.codexUsageMode,
                claudeUsageMode: settingsStore.claudeUsageMode,
                geminiUsageMode: settingsStore.geminiUsageMode,
                antigravityUsageMode: settingsStore.antigravityUsageMode,
                miscProviderInstances: settingsStore.settings.miscProviderInstances
            )
            scheduler.triggerRefresh()
            return true
        } catch {
            SafeLog.warn("Deleting Grok web cookies failed: \(SafeLog.sanitize(error.localizedDescription))")
            hasGrokWebCookies = GrokWebCookieStore.hasCookieHeader()
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

    /// How long the probe waits when the popover is on screen.
    ///
    /// Every Claude refresh reaches this, and opening the popover triggers a
    /// refresh — so the WebView used to boot in the same run-loop turns the
    /// popover was laying itself out in, on the main actor, next to the
    /// rendering. Waiting lets the refresh settle first. Deliberately a delay
    /// rather than "skip while visible": the routines bucket only gets its
    /// "used / limit" label from this probe, and a user who leaves the popover
    /// open would otherwise never see it.
    private static let routineBudgetVisiblePopoverDelay: TimeInterval = 2

    /// Set by `StatusItemController` when the popover is shown or dismissed.
    /// Deliberately not `@Published`: nothing renders from it, and publishing it
    /// would invalidate every view observing this object at the exact moment the
    /// popover is trying to appear.
    private(set) var isPopoverVisible = false

    func setPopoverVisible(_ isVisible: Bool) {
        isPopoverVisible = isVisible
    }

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

        let deferBy = isPopoverVisible ? Self.routineBudgetVisiblePopoverDelay : 0
        Task { @MainActor [weak self, accountId = quota.accountId] in
            guard let self else { return }
            defer { self.routineBudgetInFlightAccountIds.remove(accountId) }
            if deferBy > 0 {
                try? await Task.sleep(for: .seconds(deferBy))
            }
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
