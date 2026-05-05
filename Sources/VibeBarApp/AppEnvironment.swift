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
        })

        self.settingsStore = settings
        self.accountStore = accounts
        self.quotaService = service
        self.serviceStatus = ServiceStatusController()
        self.costService = CostUsageService(mockProvider: { [weak settings] in
            settings?.mockEnabled ?? false
        })
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
            }
        )
        self.scheduler = scheduler

        // Re-schedule when interval changes; refresh when user toggles mock.
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
                Task { @MainActor in
                    await self?.costService.refreshAll()
                }
            }
            .store(in: &cancellables)

        scheduler.start()
        serviceStatus.start()

        // Kick off an initial cost scan in the background. Cost data updates
        // slowly compared to live quota, so we re-scan only on user-triggered
        // refresh or app relaunch.
        Task { @MainActor in
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
        scheduler.triggerRefresh()
        serviceStatus.refreshAll()
        Task { @MainActor in
            await costService.refreshAll()
        }
    }

    func refreshAll() {
        reloadProviderCredentialsAndRefresh()
    }

    func refresh(_ tool: ToolType) {
        hasClaudeWebCookies = ClaudeWebCookieStore.hasCookieHeader()
        accountStore.reload(claudeUsageMode: settingsStore.claudeUsageMode)
        guard let account = account(for: tool) else { return }
        Task { @MainActor in
            _ = await quotaService.refresh(account)
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

    private func scheduleClaudeRoutineBudgetPatchIfNeeded(for quota: AccountQuota) {
        guard quota.tool == .claude, !settingsStore.mockEnabled else { return }
        guard let routine = quota.bucket(id: "daily_routines") else { return }
        guard !routine.shortLabel.contains("/") else { return }
        guard !routineBudgetInFlightAccountIds.contains(quota.accountId) else { return }
        let now = Date()
        if let last = lastRoutineBudgetAttemptByAccount[quota.accountId],
           now.timeIntervalSince(last) < 120 {
            return
        }
        routineBudgetInFlightAccountIds.insert(quota.accountId)
        lastRoutineBudgetAttemptByAccount[quota.accountId] = now

        Task { @MainActor [weak self, accountId = quota.accountId] in
            guard let self else { return }
            defer { self.routineBudgetInFlightAccountIds.remove(accountId) }
            guard let result = await ClaudeRoutineBudgetWebViewFetcher.fetch() else { return }
            self.quotaService.replaceBucket(self.routinesBucket(from: result), for: accountId)
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
