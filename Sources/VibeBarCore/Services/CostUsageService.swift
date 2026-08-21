import Foundation
import Combine

/// Owns per-tool CostSnapshot + ProviderExtras. Fresh JSONL scans max-merge
/// with persisted history so log rotation cannot erase usage; authoritative
/// Cursor dashboard snapshots replace their retained history so corrections
/// stay consistent with the request ledger.
@MainActor
public final class CostUsageService: ObservableObject {
    @Published public private(set) var snapshots: [ToolType: CostSnapshot] = [:] {
        didSet { aggregations.setSource(snapshots) }
    }
    @Published public private(set) var extrasByTool: [ToolType: ProviderExtras] = [:]
    @Published public private(set) var isRefreshing: Bool = false
    @Published public private(set) var lastRefreshedAt: Date?
    /// Set by callers (e.g. AppEnvironment) to surface Claude extras parsed
    /// from the OAuth response. Updated each time QuotaService refreshes.
    public func setLiveExtras(_ extras: ProviderExtras?, for tool: ToolType) {
        guard !costDataSettingsProvider().privacyModeEnabled else {
            extrasByTool.removeValue(forKey: tool)
            return
        }
        if let extras { extrasByTool[tool] = extras }
        else { extrasByTool.removeValue(forKey: tool) }
    }

    /// Hard per-provider scan budget — a backstop against a stalled scan
    /// wedging the whole pass, NOT a performance cap. It must clear the
    /// slowest *legitimate* scan, which is a one-time full re-parse of a
    /// large local history after a scan-cache schema bump: a multi-GB
    /// `~/.codex/sessions` tree can take a few minutes cold (warm scans
    /// are sub-second). 30s clipped that, so codex silently never updated
    /// while every smaller provider did. Genuine subprocess hangs (the
    /// AntiGravity `lsof`/RPC probe) are bounded separately by
    /// `ProcessRunner`, so this can be generous without risking a freeze.
    private static let perToolScanTimeoutSeconds: Double = 300

    /// Number of days of request-level rows the usage ledger keeps before
    /// folding a day into its daily rollups. Everything the usage UI shows
    /// per request lives inside this window; older history stays available
    /// as totals.
    private static let ledgerDetailDays = 30

    private let homeDirectory: String
    private let mockProvider: () -> Bool
    private let costDataSettingsProvider: () -> CostDataSettings
    /// Optional per-request event ledger. When present it receives every
    /// event behind each scan, so a usage UI can query request-level
    /// history without re-walking the JSONL. Nil keeps the scan pipeline
    /// byte-identical to the pre-ledger behaviour.
    private let usageLedger: UsageEventLedger?
    /// Keep authoritative local and selected-remote sources separate. Only the
    /// merged dictionary is published, so remote facts are never written into
    /// the local scan cache/history and cannot be counted again after relaunch.
    private var localSnapshots: [ToolType: CostSnapshot] = [:]
    /// Account-wide provider APIs that are authoritative but not local files.
    /// Cursor's last-known dashboard snapshot is persisted for launch
    /// hydration, but remains in this lane so it can never be combined with
    /// itself as if it were a newly scanned local session.
    private var directRemoteSnapshots: [ToolType: CostSnapshot] = [:]
    private var remoteSnapshots: [ToolType: CostSnapshot] = [:]
    /// Every value the UI derives from `snapshots` — rebased per-tool
    /// snapshots, combined platform snapshots, the Overview rollups — is a pure
    /// function of the snapshots and the local day, and the popover asks for
    /// them dozens of times per render pass. The cache keeps that work at once
    /// per refresh instead of once per read; it is dropped automatically by the
    /// `snapshots` observer above and on day rollover.
    private let aggregations = CostAggregationCache()

    public init(
        homeDirectory: String = RealHomeDirectory.path,
        mockProvider: @escaping () -> Bool = { false },
        costDataSettingsProvider: @escaping () -> CostDataSettings = { .default },
        usageLedger: UsageEventLedger? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.mockProvider = mockProvider
        self.costDataSettingsProvider = costDataSettingsProvider
        self.usageLedger = usageLedger
        // Surface the most recent persisted snapshot per tool immediately so
        // the popover doesn't render an empty Cost panel while the first
        // background scan is still running. The fresh scan replaces this when
        // it completes (typically within a second on modern hardware).
        Task { @MainActor in
            let costData = self.costDataSettingsProvider()
            guard !costData.privacyModeEnabled else {
                await self.eraseLocalCostData()
                return
            }
            let cached = await CostSnapshotCache.shared.loadAll(retentionDays: costData.retentionDays, now: Date())
            // One assignment, not one per tool: every write to a `@Published`
            // dictionary is its own publish, and the popover re-renders on each.
            let hydrated = Self.partitionPersistedSnapshots(
                cached,
                local: self.localSnapshots,
                directRemote: self.directRemoteSnapshots
            )
            if hydrated.addedAny {
                self.localSnapshots = hydrated.local
                self.directRemoteSnapshots = hydrated.directRemote
                self.publishMergedSnapshots()
            }
            if !cached.isEmpty {
                self.lastRefreshedAt = cached.values.map(\.updatedAt).max()
            }
        }
    }

    public func snapshot(for tool: ToolType) -> CostSnapshot? {
        aggregations.snapshot(for: tool)
    }

    /// Cost for several tools the product presents as one platform (Gemini Web
    /// + AntiGravity as "Gemini").
    public func combinedSnapshot(of tools: [ToolType], labelledAs label: ToolType) -> CostSnapshot {
        aggregations.combinedSnapshot(of: tools, labelledAs: label)
    }

    /// Cross-provider rollups for the Overview's "all providers" cards.
    public func rollup(
        individualTools: [ToolType],
        groups: [CostSnapshotGroup] = [],
        labelledAs label: ToolType
    ) -> CostRollup {
        aggregations.rollup(individualTools: individualTools, groups: groups, labelledAs: label)
    }

    /// Headline cost and token totals over a set of providers.
    public func totals(of tools: [ToolType]) -> CostTotals {
        aggregations.totals(of: tools)
    }

    /// Whether any of these providers has found session logs. Deliberately
    /// reads the raw file count instead of a rebased or combined snapshot:
    /// `jsonlFilesFound` survives both untouched, and this is asked on every
    /// render pass to decide whether the cost cards exist at all.
    public func hasJSONLFiles(in tools: [ToolType]) -> Bool {
        aggregations.hasJSONLFiles(in: tools)
    }

    public func extras(for tool: ToolType) -> ProviderExtras? {
        extrasByTool[tool]
    }

    /// Replace the selected Probe contribution. The caller supplies snapshots
    /// built from the Core's decrypted ledger; this service keeps them in
    /// memory only and combines them with local CLI snapshots for every
    /// Overview/provider surface through the existing aggregation cache.
    public func setRemoteSnapshots(_ snapshots: [ToolType: CostSnapshot]) {
        remoteSnapshots = snapshots
        publishMergedSnapshots()
    }

    public func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let now = Date()
        let costData = costDataSettingsProvider()
        guard !costData.privacyModeEnabled else {
            await eraseLocalCostData()
            return
        }
        // A demo home carries its cost snapshots and ledger ready-made, and
        // has no session logs worth scanning; a rescan would replace the
        // snapshot it shipped with by an empty one.
        guard !DemoMode.isEnabled else { return }
        let retentionDays = costData.retentionDays
        if mockProvider() {
            var results: [ToolType: CostSnapshot] = [:]
            for tool in ToolType.allCases where tool.supportsTokenCost {
                if let snap = MockDataProvider.sampleCostSnapshot(for: tool, now: now) {
                    results[tool] = snap
                }
            }
            var mockExtras: [ToolType: ProviderExtras] = [:]
            for tool in ToolType.allCases {
                if let e = MockDataProvider.sampleExtras(for: tool, now: now) {
                    mockExtras[tool] = e
                }
            }
            localSnapshots = results
            publishMergedSnapshots()
            extrasByTool = mockExtras
            lastRefreshedAt = now
            return
        }

        // Adopt any pricing table PricingRefresher has written since the
        // last pass. Swapping here — at the pass boundary, before any scan
        // starts — keeps every scan below on one consistent table while
        // letting new model rates land without an app relaunch.
        PricingResolver.reloadIfChanged(homeDirectory: homeDirectory)

        // The Workbench reads persisted request costs from UsageEventLedger,
        // while the outer ranking is rebuilt directly from each fresh scan.
        // Reprice previously unpriced ledger rows whenever the effective
        // catalog (including local overrides) changes so both surfaces can
        // adopt newly covered models without losing rotated history.
        _ = try? await usageLedger?.prepareForPricingRevision(PricingResolver.activeRevision)

        var results: [ToolType: CostSnapshot] = [:]
        var directRemoteResults = directRemoteSnapshots
        var ledgerDidIngest = false
        let home = homeDirectory
        // Privacy mode is already handled above (it erases and returns), so
        // reaching here means the ledger is allowed to record.
        let sink = usageLedger
        for tool in ToolType.allCases where tool.supportsTokenCost {
            if tool == .cursor {
                let outcome = await AsyncTimeout.run(seconds: Self.perToolScanTimeoutSeconds) {
                    await CursorCostUsageFetcher.fetch(
                        homeDirectory: home,
                        now: now,
                        retentionDays: retentionDays,
                        eventSink: sink
                    )
                }
                guard !costDataSettingsProvider().privacyModeEnabled else {
                    await eraseLocalCostData()
                    return
                }
                switch outcome {
                case .completed(.success(let snapshot)):
                    let merged = await CostHistoryStore.shared.replaceAndAugment(
                        snapshot,
                        retentionDays: retentionDays
                    )
                    directRemoteResults[.cursor] = merged
                    await CostSnapshotCache.shared.save(
                        merged,
                        retentionDays: retentionDays
                    )
                    // Cursor dashboard events now feed the same request ledger
                    // as local scanners, so Workbench and the outer Grok cost
                    // surface share one set of token/cost facts.
                    ledgerDidIngest = true
                case .completed(.unavailable):
                    directRemoteResults.removeValue(forKey: .cursor)
                    // Match the in-memory decision on the next launch: once
                    // every Cursor session is gone, an old hydrated dashboard
                    // snapshot must not reappear from cursor.json.
                    await CostSnapshotCache.shared.remove(tool: .cursor)
                case .completed(.failed), .timedOut:
                    // A transient dashboard failure keeps the last in-memory
                    // success, just as a timed-out local scan keeps its prior
                    // snapshot. Logging happens inside the fetcher.
                    break
                }
                continue
            }
            // Scan on a detached utility task so JSONL parsing doesn't block
            // the main actor. CostUsageService itself is `@MainActor`; without
            // this hop, `nonisolated async` callees still run inline on the
            // calling actor and can stutter the menu bar UI for hundreds of
            // milliseconds when the user has accumulated many session files.
            //
            // Bound each scan: a single stalled provider (historically the
            // AntiGravity language-server probe wedged on `lsof`) must never
            // hang the loop. A wedge there used to leave `isRefreshing` stuck
            // forever, freezing cost/usage for ALL providers. On timeout we
            // keep the tool's last-known snapshot and move on, so the loop
            // always completes and the refresh self-heals next pass.
            let outcome = await AsyncTimeout.run(seconds: Self.perToolScanTimeoutSeconds) {
                await CostUsageScanner.scan(
                    tool: tool,
                    homeDirectory: home,
                    now: now,
                    retentionDays: retentionDays,
                    eventSink: sink
                )
            }
            let scanned: CostSnapshot?
            switch outcome {
            case .completed(let snapshot):
                scanned = snapshot
            case .timedOut:
                if let previous = localSnapshots[tool] { results[tool] = previous }
                continue
            }
            if let scanned {
                guard !costDataSettingsProvider().privacyModeEnabled else {
                    await eraseLocalCostData()
                    return
                }
                let merged = await CostHistoryStore.shared.mergeAndAugment(scanned, retentionDays: retentionDays)
                results[tool] = merged
                // Persist the post-merge snapshot so a future launch can show
                // these numbers without waiting for a fresh scan.
                await CostSnapshotCache.shared.save(merged, retentionDays: retentionDays)
                ledgerDidIngest = true
            }
        }
        localSnapshots = results
        directRemoteSnapshots = directRemoteResults
        publishMergedSnapshots()
        // Fold everything ingested this pass down to daily rollups past the
        // detail window and apply retention — once, at the end.
        //
        // This used to run inside the loop, per tool. `rollupAndPrune` opens a
        // BEGIN IMMEDIATE transaction and aggregates the whole detail table,
        // and it holds the ledger actor while it does: with ~20 scannable
        // tools, a single refresh took that write lock twenty times, and every
        // Workbench query issued during the pass queued behind whichever one
        // was running. One call folds exactly the same rows.
        if ledgerDidIngest {
            try? await usageLedger?.rollupAndPrune(
                now: now,
                detailDays: Self.ledgerDetailDays,
                retentionDays: retentionDays
            )
        }
        // Extras (credits / overage) display was removed from the UI — see the
        // user-feedback round that turned them off because the loaders weren't
        // reliable. Parsing infrastructure for Claude.providerExtras is kept
        // so it's easy to re-enable later, but we no longer fetch live OpenAI
        // credits from chatgpt.com.
        lastRefreshedAt = now
    }

    public func costHistory(for tool: ToolType, timeframe: CostTimeframe) async -> CostHistory {
        let costData = costDataSettingsProvider()
        guard !costData.privacyModeEnabled else {
            return CostHistory(tool: tool, days: [], updatedAt: Date())
        }
        if mockProvider() {
            return MockDataProvider.sampleCostHistory(for: tool, timeframe: timeframe)
        }
        let dayCount: Int?
        switch timeframe {
        case .today: dayCount = 1
        case .yesterday: dayCount = 2
        case .week:  dayCount = 7
        case .month: dayCount = 30
        case .all:   dayCount = nil
        }
        let history = await CostHistoryStore.shared.history(
            for: tool,
            days: dayCount,
            retentionDays: costData.retentionDays
        )
        guard timeframe == .yesterday else { return history }
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date())) ?? Date()
        return CostHistory(
            tool: history.tool,
            days: history.days.filter { calendar.isDate($0.date, inSameDayAs: yesterday) },
            updatedAt: history.updatedAt
        )
    }

    public func applyCostDataSettings() async {
        let costData = costDataSettingsProvider()
        guard !costData.privacyModeEnabled else {
            await eraseLocalCostData()
            return
        }
        await CostHistoryStore.shared.prune(retentionDays: costData.retentionDays)
        try? await usageLedger?.rollupAndPrune(
            now: Date(),
            detailDays: Self.ledgerDetailDays,
            retentionDays: costData.retentionDays
        )
        let cached = await CostSnapshotCache.shared.loadAll(retentionDays: costData.retentionDays, now: Date())
        let hydrated = Self.partitionPersistedSnapshots(cached)
        localSnapshots = hydrated.local
        directRemoteSnapshots = hydrated.directRemote
        publishMergedSnapshots()
        lastRefreshedAt = cached.values.map(\.updatedAt).max()
    }

    public func eraseLocalCostData() async {
        await CostHistoryStore.shared.eraseAll()
        await CostSnapshotCache.shared.eraseAll()
        CostUsageScanCache.eraseAll(homeDirectory: homeDirectory)
        try? await usageLedger?.eraseAll()
        localSnapshots = [:]
        directRemoteSnapshots = [:]
        publishMergedSnapshots()
        extrasByTool = [:]
        lastRefreshedAt = nil
    }

    private func publishMergedSnapshots(now: Date = Date()) {
        guard !costDataSettingsProvider().privacyModeEnabled else {
            snapshots = [:]
            return
        }
        // Mock mode is a self-contained preview and must never leak real Probe
        // totals into screenshots or tests.
        guard !mockProvider() else {
            snapshots = localSnapshots
            return
        }
        var merged = localSnapshots
        // Both remote lanes fold in the same way; the direct-remote lane goes
        // first, and a tool present in both is combined once per lane.
        for (tool, remote) in Array(directRemoteSnapshots) + Array(remoteSnapshots) {
            merged[tool] = merged[tool].map {
                CostSnapshotAggregator.combinedSnapshot(
                    tool: tool,
                    snapshots: [$0, remote],
                    now: now
                )
            } ?? remote
        }
        snapshots = merged
    }

    struct PersistedPartition {
        var local: [ToolType: CostSnapshot]
        var directRemote: [ToolType: CostSnapshot]
        /// At least one cached snapshot filled a lane slot that was empty.
        /// Cheaper for the caller than comparing two dictionaries of
        /// snapshots to find out whether anything moved.
        var addedAny = false
    }

    /// Persisted Cursor data came from an account-wide dashboard rather than
    /// a local session scan. Keep it in the direct-remote lane when hydrating
    /// so a failed first refresh after launch retains the last-known snapshot
    /// and a later successful refresh replaces it instead of adding it twice.
    static func partitionPersistedSnapshots(
        _ cached: [ToolType: CostSnapshot],
        local: [ToolType: CostSnapshot] = [:],
        directRemote: [ToolType: CostSnapshot] = [:]
    ) -> PersistedPartition {
        var partition = PersistedPartition(local: local, directRemote: directRemote)
        for (tool, snapshot) in cached {
            let lane: WritableKeyPath<PersistedPartition, [ToolType: CostSnapshot]> =
                tool == .cursor ? \.directRemote : \.local
            guard partition[keyPath: lane][tool] == nil else { continue }
            partition[keyPath: lane][tool] = snapshot
            partition.addedAny = true
        }
        return partition
    }
}
