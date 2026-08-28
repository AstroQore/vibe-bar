import Foundation

/// Activity inputs used when a quota refresh records its pace forecast.
///
/// The heatmap and daily token history live in the cost layer, which Core's
/// quota path has no handle on. The App injects them through
/// `QuotaService.activityContextProvider` so the *recorded* forecast matches
/// the one the popover renders live; with nothing injected the forecast falls
/// back to a time-only activity profile, which is still a valid — just less
/// personalised — projection.
public struct QuotaActivityContext: Sendable {
    public let heatmap: UsageHeatmap?
    public let dailyActivity: [DailyCostPoint]

    public static let empty = QuotaActivityContext()

    public init(heatmap: UsageHeatmap? = nil, dailyActivity: [DailyCostPoint] = []) {
        self.heatmap = heatmap
        self.dailyActivity = dailyActivity
    }
}

/// QuotaService routes a request to the right adapter, tracks last-success
/// quota per account so callers can fall back to cached data on transient
/// failures, and supports a global mock-mode override.
@MainActor
public final class QuotaService: ObservableObject {
    public static let credentialFallbackMaxAge: TimeInterval = 30 * 60
    nonisolated public static let defaultRefreshTimeoutSeconds: Double = 60
    @Published public private(set) var lastSuccessByAccount: [String: AccountQuota] = [:]
    @Published public private(set) var lastErrorByAccount: [String: QuotaError] = [:]
    /// When the *data* currently on screen was fetched. Only a success writes
    /// here — a failed refresh used to bump it too, which made every card
    /// claim it had just updated while it was still drawing hours-old buckets.
    @Published public private(set) var lastUpdatedByAccount: [String: Date] = [:]
    /// When a refresh last ran for this account, successful or not. Paired
    /// with `lastUpdatedByAccount` this separates "we keep trying" from "the
    /// numbers are current".
    @Published public private(set) var lastAttemptedByAccount: [String: Date] = [:]
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
    /// Catalog-external quota buckets seen on this Mac, loaded from and
    /// persisted to `VibeBarLocalStore.quotaFieldRegistryURL`. The mini-window
    /// field picker and layouts merge this with the static catalog, which is
    /// how a bucket the provider shipped after this build (GPT-reserve, say)
    /// becomes selectable without a release.
    @Published public private(set) var fieldRegistry: QuotaFieldRegistry = .empty

    /// Supplies the cost-side activity inputs for the forecast recorded after
    /// each refresh. Optional: Core works without it, the App sets it once at
    /// wiring time.
    public var activityContextProvider: ((ToolType) -> QuotaActivityContext)?
    /// What the registry must keep even when the provider stops returning
    /// the buckets — selections, named fields, and named groups. Wired by
    /// the App from settings; nil keeps everything (prune disabled).
    public var registryKeepProvider: (() -> QuotaFieldKeepSet)?

    private let adapters: [ToolType: any QuotaAdapter]
    private let mockProvider: () -> Bool
    private let retentionProvider: () -> Int
    private let refreshTimeoutSeconds: Double
    /// A timed-out adapter may ignore cancellation and keep running. Do not
    /// start another fetch for that account until the abandoned operation
    /// actually returns; otherwise each scheduler tick can leak another task
    /// or provider subprocess.
    private var timedOutAccountIds: Set<String> = []

    public init(
        adapters: [ToolType: any QuotaAdapter],
        mockProvider: @escaping () -> Bool,
        retentionProvider: @escaping () -> Int = { CostDataSettings.defaultRetentionDays },
        initialAccountIds: [String] = [],
        refreshTimeoutSeconds: Double = QuotaService.defaultRefreshTimeoutSeconds
    ) {
        self.adapters = adapters
        self.mockProvider = mockProvider
        self.retentionProvider = retentionProvider
        self.refreshTimeoutSeconds = max(0.01, refreshTimeoutSeconds)
        let cached = QuotaCacheStore.loadAll(accountIds: initialAccountIds)
        self.lastSuccessByAccount = cached
        self.lastUpdatedByAccount = cached.mapValues(\.queriedAt)
        // A cache entry is by definition the last thing that succeeded, so at
        // launch the two timestamps agree; they diverge on the first failure.
        self.lastAttemptedByAccount = cached.mapValues(\.queriedAt)

        // Load the discovered-field registry, then fold the cached quotas in
        // so a bucket the catalog doesn't know is selectable before the first
        // live refresh of this launch.
        var registry = (try? VibeBarLocalStore.readJSON(
            QuotaFieldRegistry.self,
            from: VibeBarLocalStore.quotaFieldRegistryURL
        )) ?? .empty
        var registryChanged = false
        for quota in cached.values where ToolType.dedicatedCardProviders.contains(quota.tool) {
            registryChanged = registry.record(tool: quota.tool, buckets: quota.buckets, now: quota.queriedAt) || registryChanged
        }
        self.fieldRegistry = registry
        if registryChanged {
            try? VibeBarLocalStore.writeJSON(registry, to: VibeBarLocalStore.quotaFieldRegistryURL)
        }

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
        initialAccountIds: [String] = [],
        geminiWebFallback: (@Sendable (AccountIdentity, String) async throws -> AccountQuota)? = nil
    ) -> QuotaService {
        QuotaService(
            adapters: [
                .codex: CodexQuotaAdapter(),
                .claude: ClaudeQuotaAdapter(),
                .zai: ZaiQuotaAdapter(),
                .copilot: CopilotQuotaAdapter(),
                .gemini: GeminiQuotaAdapter(webFallback: geminiWebFallback),
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
        if timedOutAccountIds.contains(account.id) {
            return cachedOrEmpty(for: account, error: .network("timeout"))
        }
        inFlightAccountIds.insert(account.id)
        defer { inFlightAccountIds.remove(account.id) }

        if mockProvider() {
            let quota = MockDataProvider.sampleQuota(for: account)
            store(success: quota)
            return quota
        }

        // Demo mode never reaches a provider: the cache the demo home shipped
        // with is the answer, and a missing cache stays visibly empty.
        if DemoMode.isEnabled {
            return lastSuccessByAccount[account.id]
                ?? AccountQuota(accountId: account.id, tool: account.tool, buckets: [], queriedAt: Date(), error: nil)
        }

        guard let adapter = adapters[account.tool] else {
            let err = QuotaError.notImplemented
            store(error: err, for: account)
            return cachedOrEmpty(for: account, error: err)
        }

        let completion = QuotaFetchCompletion()
        let outcome = await AsyncTimeout.run(seconds: refreshTimeoutSeconds) {
            defer { completion.finish() }
            do {
                let quota = try await adapter.fetch(for: account)
                if let error = quota.error {
                    return QuotaAdapterFetchResult.failure(error)
                }
                return QuotaAdapterFetchResult.success(quota)
            } catch let qe as QuotaError {
                return QuotaAdapterFetchResult.failure(qe)
            } catch {
                return QuotaAdapterFetchResult.failure(mapURLError(error))
            }
        }
        switch outcome {
        case let .completed(.success(quota)):
            store(success: quota)
            return quota
        case let .completed(.failure(qe)):
            SafeLog.net("\(account.tool.rawValue) refresh failed: \(qe.userFacingMessage)")
            store(error: qe, for: account)
            return cachedOrEmpty(for: account, error: qe)
        case .timedOut:
            let qe = QuotaError.network("timeout")
            SafeLog.net("\(account.tool.rawValue) refresh timed out")
            store(error: qe, for: account)
            timedOutAccountIds.insert(account.id)
            Task { @MainActor [weak self] in
                await completion.wait()
                self?.timedOutAccountIds.remove(account.id)
            }
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
        if cached.buckets.contains(where: { bucket in
            bucket.resetAt.map { $0 <= now } ?? false
        }) {
            return true
        }
        return now.timeIntervalSince(cached.queriedAt) >= max(0, maxAge)
    }

    public func clear(accountId: String) {
        lastSuccessByAccount.removeValue(forKey: accountId)
        lastErrorByAccount.removeValue(forKey: accountId)
        lastUpdatedByAccount.removeValue(forKey: accountId)
        lastAttemptedByAccount.removeValue(forKey: accountId)
        // Through the writer so a coalesced write for this account cannot land
        // after the delete and resurrect the file.
        Task { await QuotaCacheWriter.shared.delete(accountId: accountId) }
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
        now: Date = Date(),
        allowsPostResetGrace: Bool = false
    ) -> QuotaPaceForecast? {
        let key = SubscriptionHistoryKey(accountId: accountId, bucketId: bucket.id)
        let observations = observationsByAccountBucket[key] ?? []
        let cycles = historyByAccountBucket[key] ?? []
        // Render paths ask for this once per bucket per body pass — every
        // quota-group row, mini-window cell, and the status item — and the
        // blend walks every stored observation per completed cycle. Between
        // data changes the inputs are byte-identical (each `TimelineView`
        // hands every re-render of a tick the same date), so the memo turns
        // the repeat asks into a handful of COW identity comparisons. Keyed
        // on the *exact* inputs, never a quantized clock: a hit is provably
        // the same pure-function call, so behavior cannot drift.
        if let memos = paceForecastMemo[key] {
            for memo in memos where memo.matches(
                bucket: bucket,
                observations: observations,
                cycles: cycles,
                heatmap: activityHeatmap,
                dailyActivity: dailyActivity,
                now: now,
                allowsPostResetGrace: allowsPostResetGrace
            ) {
                return memo.result
            }
        }
        let result = QuotaPaceForecast.compute(
            bucket: bucket,
            observations: observations,
            cycles: cycles,
            activityHeatmap: activityHeatmap,
            dailyActivity: dailyActivity,
            now: now,
            allowsPostResetGrace: allowsPostResetGrace
        )
        var memos = paceForecastMemo[key] ?? []
        // A refresh replaces the observation/cycle arrays wholesale, so a
        // memo from the previous data generation can never match again —
        // but it would keep retaining those arrays (thousands of points per
        // bucket) for as long as it sat in the list. Keep only memos of the
        // current generation; the differently-phased `now` values are what
        // the multi-entry list is for.
        memos.removeAll { memo in
            !memo.matchesData(
                bucket: bucket,
                observations: observations,
                cycles: cycles,
                heatmap: activityHeatmap,
                dailyActivity: dailyActivity
            )
        }
        memos.append(PaceForecastMemo(
            bucket: bucket,
            observations: observations,
            cycles: cycles,
            heatmap: activityHeatmap,
            dailyActivity: dailyActivity,
            now: now,
            allowsPostResetGrace: allowsPostResetGrace,
            result: result
        ))
        // Several surfaces (popover, mini windows, status item) tick on
        // their own 30 s phases, so keep a few entries per bucket rather
        // than one; the arrays inside are references to storage the service
        // already retains, so the memo itself is a few dozen words.
        if memos.count > Self.paceForecastMemoLimit {
            memos.removeFirst(memos.count - Self.paceForecastMemoLimit)
        }
        paceForecastMemo[key] = memos
        return result
    }

    private struct PaceForecastMemo {
        let bucket: QuotaBucket
        let observations: [FillTimelinePoint]
        let cycles: [SubscriptionWindowSample]
        let heatmap: UsageHeatmap?
        let dailyActivity: [DailyCostPoint]
        let now: Date
        let allowsPostResetGrace: Bool
        let result: QuotaPaceForecast?

        func matches(
            bucket: QuotaBucket,
            observations: [FillTimelinePoint],
            cycles: [SubscriptionWindowSample],
            heatmap: UsageHeatmap?,
            dailyActivity: [DailyCostPoint],
            now: Date,
            allowsPostResetGrace: Bool
        ) -> Bool {
            self.now == now
                && self.allowsPostResetGrace == allowsPostResetGrace
                && matchesData(
                    bucket: bucket,
                    observations: observations,
                    cycles: cycles,
                    heatmap: heatmap,
                    dailyActivity: dailyActivity
                )
        }

        /// The time-independent half of `matches` — one data generation.
        func matchesData(
            bucket: QuotaBucket,
            observations: [FillTimelinePoint],
            cycles: [SubscriptionWindowSample],
            heatmap: UsageHeatmap?,
            dailyActivity: [DailyCostPoint]
        ) -> Bool {
            self.bucket == bucket
                && self.observations == observations
                && self.cycles == cycles
                && self.heatmap == heatmap
                && self.dailyActivity == dailyActivity
        }
    }

    private static let paceForecastMemoLimit = 4
    private var paceForecastMemo: [SubscriptionHistoryKey: [PaceForecastMemo]] = [:]

    /// The picker's explicit "forget": drop one discovered field from the
    /// registry and persist. The caller removes its own references
    /// (selections, labels) — this only owns the registry file.
    public func forgetDiscoveredField(id: String) {
        var registry = fieldRegistry
        guard registry.forget(id: id) else { return }
        fieldRegistry = registry
        try? VibeBarLocalStore.writeJSON(registry, to: VibeBarLocalStore.quotaFieldRegistryURL)
    }

    // MARK: - Private

    private func store(success: AccountQuota, now: Date = Date()) {
        lastSuccessByAccount[success.accountId] = success
        lastErrorByAccount.removeValue(forKey: success.accountId)
        lastUpdatedByAccount[success.accountId] = success.queriedAt
        lastAttemptedByAccount[success.accountId] = now

        // Mock-mode buckets must not be remembered as real discoveries.
        if !mockProvider(), ToolType.dedicatedCardProviders.contains(success.tool) {
            var registry = fieldRegistry
            var changed = registry.record(tool: success.tool, buckets: success.buckets, now: now)
            if let keep = registryKeepProvider?() {
                changed = registry.prune(
                    tool: success.tool,
                    liveBucketIds: Set(success.buckets.map(\.id)),
                    keeping: keep
                ) || changed
            }
            if changed {
                fieldRegistry = registry
                try? VibeBarLocalStore.writeJSON(registry, to: VibeBarLocalStore.quotaFieldRegistryURL)
            }
        }

        // Store both the point observations used by the personal forecast and
        // the inferred completed cycles used by reset history. Both paths
        // retain every bucket, including model-scoped limits.
        let retention = retentionProvider()
        let quota = success
        Task { [weak self] in
            // Every step below is deliberately actor work rather than main-actor
            // work: the cache write is an encode plus an atomic file write, and
            // the two stores parse and prune their whole file.
            await QuotaCacheWriter.shared.save(quota)
            await UsageFillTimelineStore.shared.observe(quota, retentionDays: retention)
            await SubscriptionHistoryStore.shared.observe(quota, retentionDays: retention)
            await self?.refreshObservations(for: quota)
            await self?.refreshSubscriptionHistory(for: quota)
            // Runs last so the forecast sees the observation this very refresh
            // just recorded. Refresh-time only — the history chart must never
            // pay for a forecast at render time.
            await self?.recordForecastObservations(for: quota, retentionDays: retention)
        }
    }

    /// Snapshot the pace forecast for every bucket that has one, so the history
    /// chart can later draw what was predicted instead of re-deriving it with
    /// hindsight. Buckets without enough information to forecast are skipped
    /// rather than recorded as zero.
    private func recordForecastObservations(
        for quota: AccountQuota,
        retentionDays: Int,
        now: Date = Date()
    ) async {
        let context = activityContextProvider?(quota.tool) ?? .empty
        let inputs = quota.buckets.map { bucket in
            let key = SubscriptionHistoryKey(accountId: quota.accountId, bucketId: bucket.id)
            return ForecastInput(
                bucket: bucket,
                observations: observationsByAccountBucket[key] ?? [],
                cycles: historyByAccountBucket[key] ?? []
            )
        }
        // Snapshot the inputs here, blend them there: the forecast is pure value
        // math, but it is a full blend per bucket over every stored observation,
        // and a thirty-bucket account paid for all of it on the main actor while
        // the popover was trying to draw.
        let observations = await Task.detached(priority: .utility) {
            Self.forecastObservations(inputs: inputs, context: context, now: now)
        }.value
        guard !observations.isEmpty else { return }
        await UsageForecastTimelineStore.shared.observe(
            observations,
            accountId: quota.accountId,
            tool: quota.tool,
            now: now,
            retentionDays: retentionDays
        )
    }

    /// One bucket's forecast inputs, snapshotted from main-actor state so the
    /// blend itself can run off it.
    private struct ForecastInput: Sendable {
        let bucket: QuotaBucket
        let observations: [FillTimelinePoint]
        let cycles: [SubscriptionWindowSample]
    }

    private nonisolated static func forecastObservations(
        inputs: [ForecastInput],
        context: QuotaActivityContext,
        now: Date
    ) -> [BucketForecastObservation] {
        inputs.compactMap { input in
            guard let forecast = QuotaPaceForecast.compute(
                bucket: input.bucket,
                observations: input.observations,
                cycles: input.cycles,
                activityHeatmap: context.heatmap,
                dailyActivity: context.dailyActivity,
                now: now
            ) else { return nil }
            return BucketForecastObservation(bucket: input.bucket, forecast: forecast)
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

    /// Republish every bucket's observation lane for one account.
    ///
    /// Gathering across the single `await` and applying the result in one
    /// assignment is load-bearing, not tidiness: this dictionary is
    /// `@Published`, and the previous shape — one store round trip and one
    /// assignment per bucket — put every bucket in its own main-actor tick.
    /// A Claude account with thirty buckets therefore re-rendered the whole
    /// popover thirty times per refresh, and the all-providers history card
    /// re-segmented every lane on each of them.
    private func refreshObservations(for quota: AccountQuota) async {
        let bucketIds = quota.buckets.map(\.id)
        guard !bucketIds.isEmpty else { return }
        let grouped = await UsageFillTimelineStore.shared.points(
            accountId: quota.accountId,
            bucketIds: bucketIds
        )
        var updated = observationsByAccountBucket
        for bucketId in bucketIds {
            let key = SubscriptionHistoryKey(accountId: quota.accountId, bucketId: bucketId)
            updated[key] = grouped[bucketId] ?? []
        }
        observationsByAccountBucket = updated
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
        // Same one-publish rule as `refreshObservations`.
        var merged = historyByAccountBucket
        for (key, samples) in updates {
            merged[key] = samples
        }
        historyByAccountBucket = merged
    }

    private func store(error: QuotaError, for account: AccountIdentity, now: Date = Date()) {
        // A failed refresh is an attempt, never an update: `lastUpdated` must
        // keep pointing at the snapshot the UI is actually drawing, otherwise
        // the freshness label ages from the failure instead of from the data.
        lastAttemptedByAccount[account.id] = now
        if error.isCredentialState,
           let cached = lastSuccessByAccount[account.id],
           !cached.buckets.isEmpty,
           now.timeIntervalSince(cached.queriedAt) < Self.credentialFallbackMaxAge {
            lastErrorByAccount.removeValue(forKey: account.id)
            return
        }
        lastErrorByAccount[account.id] = error
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

private enum QuotaAdapterFetchResult: Sendable {
    case success(AccountQuota)
    case failure(QuotaError)
}

private final class QuotaFetchCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                if finished { return true }
                waiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func finish() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !finished else { return [] }
            finished = true
            let pending = waiters
            waiters = []
            return pending
        }
        for waiter in pending { waiter.resume() }
    }
}
