import Foundation

/// QuotaService routes a request to the right adapter, tracks last-success
/// quota per account so callers can fall back to cached data on transient
/// failures, and supports a global mock-mode override.
@MainActor
public final class QuotaService: ObservableObject {
    public static let credentialFallbackMaxAge: TimeInterval = 30 * 60
    @Published public private(set) var lastSuccessByAccount: [String: AccountQuota] = [:]
    @Published public private(set) var lastErrorByAccount: [String: QuotaError] = [:]
    @Published public private(set) var lastUpdatedByAccount: [String: Date] = [:]
    @Published public private(set) var inFlightAccountIds: Set<String> = []
    /// Per-(accountId, bucketId) subscription fill history loaded from
    /// `SubscriptionHistoryStore`. Hydrated asynchronously on init and
    /// kept in sync as each `refresh` succeeds; views read this
    /// dictionary directly via the `@Published` projection.
    @Published public private(set) var historyByAccountBucket: [SubscriptionHistoryKey: [SubscriptionWindowSample]] = [:]
    /// Adaptive point samples for every independently resettable quota. These
    /// power personal pace forecasts; completed-cycle summaries remain in
    /// `historyByAccountBucket` for Fill History and reset outcomes.
    @Published public private(set) var observationsByAccountBucket: [SubscriptionHistoryKey: [FillTimelinePoint]] = [:]

    private let adapters: [ToolType: any QuotaAdapter]
    private let mockProvider: () -> Bool
    private let retentionProvider: () -> Int

    public init(
        adapters: [ToolType: any QuotaAdapter],
        mockProvider: @escaping () -> Bool,
        retentionProvider: @escaping () -> Int = { CostDataSettings.defaultRetentionDays },
        initialAccountIds: [String] = []
    ) {
        self.adapters = adapters
        self.mockProvider = mockProvider
        self.retentionProvider = retentionProvider
        let cached = QuotaCacheStore.loadAll(accountIds: initialAccountIds)
        self.lastSuccessByAccount = cached
        self.lastUpdatedByAccount = cached.mapValues(\.queriedAt)

        // Hydrate the subscription history dictionary from disk. The
        // store is an actor, so this has to be deferred — the popover
        // and mini window won't render samples until this Task resolves,
        // but neither is open at launch so the brief flicker is invisible.
        Task { @MainActor [weak self] in
            // Salvage only genuine refill jumps from the retired hourly
            // timeline before hydrating the cycle-based history UI.
            let points = await UsageFillTimelineStore.shared.allPoints()
            self?.applyInitialObservations(points)
            await SubscriptionHistoryStore.shared.importLegacyTimeline(
                points,
                retentionDays: retentionProvider()
            )
            let samples = await SubscriptionHistoryStore.shared.allSamples()
            self?.applyInitialSubscriptionHistory(samples)
        }
    }

    public static func makeDefault(
        mockProvider: @escaping () -> Bool,
        retentionProvider: @escaping () -> Int = { CostDataSettings.defaultRetentionDays },
        initialAccountIds: [String] = []
    ) -> QuotaService {
        QuotaService(
            adapters: [
                .codex: CodexQuotaAdapter(),
                .claude: ClaudeQuotaAdapter(),
                .zai: ZaiQuotaAdapter(),
                .copilot: CopilotQuotaAdapter(),
                .gemini: GeminiQuotaAdapter(),
                .alibaba: AlibabaQuotaAdapter(),
                .alibabaTokenPlan: AlibabaTokenPlanQuotaAdapter(),
                .minimax: MiniMaxQuotaAdapter(),
                .kimi: KimiQuotaAdapter(),
                .cursor: CursorQuotaAdapter(),
                .antigravity: AntigravityQuotaAdapter(),
                .grok: GrokQuotaAdapter(),
                .mimo: MimoQuotaAdapter(),
                .iflytek: IFlyTekQuotaAdapter(),
                .tencentHunyuan: TencentHunyuanQuotaAdapter(),
                .tencentTokenPlan: TencentTokenPlanQuotaAdapter(),
                .volcengine: VolcengineQuotaAdapter(),
                .volcengineAgentPlan: VolcengineAgentPlanQuotaAdapter(),
                .baiduQianfan: BaiduQianfanQuotaAdapter(),
                .openCodeGo: OpenCodeGoQuotaAdapter(),
                .kilo: KiloQuotaAdapter(),
                .kiro: KiroQuotaAdapter(),
                .ollama: OllamaQuotaAdapter(),
                .openRouter: OpenRouterQuotaAdapter(),
                .warp: WarpQuotaAdapter()
            ],
            mockProvider: mockProvider,
            retentionProvider: retentionProvider,
            initialAccountIds: initialAccountIds
        )
    }

    /// Fetch quota for the given account. Stores the result (or error) and
    /// returns the new AccountQuota — which may be a cached previous success
    /// if the live call failed and we have prior data.
    @discardableResult
    public func refresh(_ account: AccountIdentity) async -> AccountQuota {
        if inFlightAccountIds.contains(account.id) {
            return lastSuccessByAccount[account.id]
                ?? AccountQuota(accountId: account.id, tool: account.tool, buckets: [], queriedAt: Date(), error: nil)
        }
        inFlightAccountIds.insert(account.id)
        defer { inFlightAccountIds.remove(account.id) }

        if mockProvider() {
            let quota = MockDataProvider.sampleQuota(for: account)
            store(success: quota)
            return quota
        }

        guard let adapter = adapters[account.tool] else {
            let err = QuotaError.notImplemented
            store(error: err, for: account)
            return cachedOrEmpty(for: account, error: err)
        }

        do {
            let quota = try await adapter.fetch(for: account)
            store(success: quota)
            return quota
        } catch let qe as QuotaError {
            SafeLog.net("\(account.tool.rawValue) refresh failed: \(qe.userFacingMessage)")
            store(error: qe, for: account)
            return cachedOrEmpty(for: account, error: qe)
        } catch {
            let qe = mapURLError(error)
            SafeLog.net("\(account.tool.rawValue) refresh exception: \(qe.userFacingMessage)")
            store(error: qe, for: account)
            return cachedOrEmpty(for: account, error: qe)
        }
    }

    public func cachedQuota(for accountId: String) -> AccountQuota? {
        lastSuccessByAccount[accountId]
    }

    /// Opening a provider page should refresh both missing and stale cache.
    /// Previously any cache entry — even one from months ago — suppressed the
    /// page refresh indefinitely.
    public func needsRefresh(
        accountId: String,
        now: Date = Date(),
        maxAge: TimeInterval
    ) -> Bool {
        guard let cached = lastSuccessByAccount[accountId] else { return true }
        return now.timeIntervalSince(cached.queriedAt) >= max(0, maxAge)
    }

    public func clear(accountId: String) {
        lastSuccessByAccount.removeValue(forKey: accountId)
        lastErrorByAccount.removeValue(forKey: accountId)
        lastUpdatedByAccount.removeValue(forKey: accountId)
        try? QuotaCacheStore.delete(accountId: accountId)
    }

    public func replaceBucket(_ bucket: QuotaBucket, for accountId: String) {
        guard var quota = lastSuccessByAccount[accountId] else { return }
        quota.buckets.removeAll { $0.id == bucket.id }
        quota.buckets.append(bucket)
        quota.queriedAt = Date()
        store(success: quota)
    }

    public func paceForecast(
        accountId: String,
        bucket: QuotaBucket,
        activityHeatmap: UsageHeatmap? = nil,
        dailyActivity: [DailyCostPoint] = [],
        now: Date = Date()
    ) -> QuotaPaceForecast? {
        let key = SubscriptionHistoryKey(accountId: accountId, bucketId: bucket.id)
        return QuotaPaceForecast.compute(
            bucket: bucket,
            observations: observationsByAccountBucket[key] ?? [],
            cycles: historyByAccountBucket[key] ?? [],
            activityHeatmap: activityHeatmap,
            dailyActivity: dailyActivity,
            now: now
        )
    }

    // MARK: - Private

    private func store(success: AccountQuota) {
        lastSuccessByAccount[success.accountId] = success
        lastErrorByAccount.removeValue(forKey: success.accountId)
        lastUpdatedByAccount[success.accountId] = success.queriedAt
        do {
            try QuotaCacheStore.save(success)
        } catch {
            SafeLog.warn("Saving quota cache failed: \(SafeLog.sanitize(error.localizedDescription))")
        }

        // Store both the point observations used by the personal forecast and
        // the inferred completed cycles used by reset history. Both paths
        // retain every bucket, including model-scoped limits.
        let retention = retentionProvider()
        let quota = success
        Task { [weak self] in
            await UsageFillTimelineStore.shared.observe(quota, retentionDays: retention)
            await SubscriptionHistoryStore.shared.observe(quota, retentionDays: retention)
            await self?.refreshObservations(for: quota)
            await self?.refreshSubscriptionHistory(for: quota)
        }
    }

    private func applyInitialObservations(_ points: [FillTimelinePoint]) {
        var grouped: [SubscriptionHistoryKey: [FillTimelinePoint]] = [:]
        for point in points {
            let key = SubscriptionHistoryKey(accountId: point.accountId, bucketId: point.bucketId)
            grouped[key, default: []].append(point)
        }
        observationsByAccountBucket = grouped.mapValues { $0.sorted { $0.sampledAt < $1.sampledAt } }
    }

    private func refreshObservations(for quota: AccountQuota) async {
        for bucket in quota.buckets {
            let key = SubscriptionHistoryKey(accountId: quota.accountId, bucketId: bucket.id)
            let points = await UsageFillTimelineStore.shared.points(
                accountId: quota.accountId,
                bucketId: bucket.id
            )
            observationsByAccountBucket[key] = points
        }
    }

    private func applyInitialSubscriptionHistory(_ samples: [SubscriptionWindowSample]) {
        var grouped: [SubscriptionHistoryKey: [SubscriptionWindowSample]] = [:]
        for sample in samples {
            let key = SubscriptionHistoryKey(accountId: sample.accountId, bucketId: sample.bucketId)
            grouped[key, default: []].append(sample)
        }
        for key in grouped.keys {
            grouped[key]?.sort { $0.windowEnd > $1.windowEnd }
        }
        historyByAccountBucket = grouped
    }

    private func refreshSubscriptionHistory(for quota: AccountQuota) async {
        var updates: [SubscriptionHistoryKey: [SubscriptionWindowSample]] = [:]
        for bucket in quota.buckets {
            let samples = await SubscriptionHistoryStore.shared.samples(
                accountId: quota.accountId,
                bucketId: bucket.id
            )
            let key = SubscriptionHistoryKey(accountId: quota.accountId, bucketId: bucket.id)
            updates[key] = samples
        }
        for (key, samples) in updates {
            historyByAccountBucket[key] = samples
        }
    }

    private func store(error: QuotaError, for account: AccountIdentity) {
        if error.isCredentialState,
           let cached = lastSuccessByAccount[account.id],
           !cached.buckets.isEmpty,
           Date().timeIntervalSince(cached.queriedAt) < Self.credentialFallbackMaxAge {
            lastErrorByAccount.removeValue(forKey: account.id)
            return
        }
        lastErrorByAccount[account.id] = error
        lastUpdatedByAccount[account.id] = Date()
    }

    private func cachedOrEmpty(for account: AccountIdentity, error: QuotaError) -> AccountQuota {
        if var cached = lastSuccessByAccount[account.id] {
            if error.isCredentialState,
               !cached.buckets.isEmpty,
               Date().timeIntervalSince(cached.queriedAt) < Self.credentialFallbackMaxAge {
                cached.error = nil
                return cached
            }
            cached.error = error
            return cached
        }
        return AccountQuota(
            accountId: account.id,
            tool: account.tool,
            buckets: [],
            plan: account.plan,
            email: account.email,
            queriedAt: Date(),
            error: error
        )
    }
}
