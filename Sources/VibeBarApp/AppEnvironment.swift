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

    private let claudeWebLoginController = ClaudeWebLoginController()
    private let settingsWindowController = SettingsWindowController()
    private var cancellables: Set<AnyCancellable> = []
    private var routineBudgetInFlightAccountIds: Set<String> = []
    private var lastRoutineBudgetAttemptByAccount: [String: Date] = [:]

    init() {
        let settings = SettingsStore()
        let accounts = AccountStore(claudeUsageMode: settings.claudeUsageMode)
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
                    && $0.claudeUsageMode == $1.claudeUsageMode
            }
            .sink { [weak self] settings in
                self?.accountStore.reload(claudeUsageMode: settings.claudeUsageMode)
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
        accountStore.reload(claudeUsageMode: settingsStore.claudeUsageMode)
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
        accountStore.reload(claudeUsageMode: settingsStore.claudeUsageMode)
        let account = account(for: tool)
        Task { @MainActor in
            if let account {
                _ = await quotaService.refresh(account)
            }
            await costService.refreshAll()
        }
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

    @discardableResult
    func deleteClaudeWebCookies() -> Bool {
        do {
            ClaudeWebLoginController.clearPersistentClaudeWebsiteData()
            try ClaudeWebCookieStore.deleteCookieHeader()
            hasClaudeWebCookies = false
            for account in accountStore.accounts(for: .claude) {
                quotaService.clear(accountId: account.id)
            }
            accountStore.reload(claudeUsageMode: settingsStore.claudeUsageMode)
            scheduler.triggerRefresh()
            return true
        } catch {
            SafeLog.warn("Deleting Claude web cookies failed: \(SafeLog.sanitize(error.localizedDescription))")
            hasClaudeWebCookies = ClaudeWebCookieStore.hasCookieHeader()
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
