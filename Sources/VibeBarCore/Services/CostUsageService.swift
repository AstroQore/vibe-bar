import Foundation
import Combine

/// Owns per-tool CostSnapshot + ProviderExtras. Merges fresh JSONL scans with
/// the persisted CostHistoryStore using max() per retained (tool, day), so
/// recent data survives CLI log rotation without keeping an unlimited profile.
@MainActor
public final class CostUsageService: ObservableObject {
    @Published public private(set) var snapshots: [ToolType: CostSnapshot] = [:]
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

    private let homeDirectory: String
    private let mockProvider: () -> Bool
    private let costDataSettingsProvider: () -> CostDataSettings

    public init(
        homeDirectory: String = RealHomeDirectory.path,
        mockProvider: @escaping () -> Bool = { false },
        costDataSettingsProvider: @escaping () -> CostDataSettings = { .default }
    ) {
        self.homeDirectory = homeDirectory
        self.mockProvider = mockProvider
        self.costDataSettingsProvider = costDataSettingsProvider
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
            for (tool, snap) in cached where self.snapshots[tool] == nil {
                self.snapshots[tool] = snap
            }
            if !cached.isEmpty {
                self.lastRefreshedAt = cached.values.map(\.updatedAt).max()
            }
        }
    }

    public func snapshot(for tool: ToolType) -> CostSnapshot? {
        snapshots[tool]?.rebasedForCurrentDay()
    }

    public func extras(for tool: ToolType) -> ProviderExtras? {
        extrasByTool[tool]
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
            snapshots = results
            extrasByTool = mockExtras
            lastRefreshedAt = now
            return
        }

        var results: [ToolType: CostSnapshot] = [:]
        let home = homeDirectory
        for tool in ToolType.allCases where tool.supportsTokenCost {
            // Scan on a detached utility task so JSONL parsing doesn't block
            // the main actor. CostUsageService itself is `@MainActor`; without
            // this hop, `nonisolated async` callees still run inline on the
            // calling actor and can stutter the menu bar UI for hundreds of
            // milliseconds when the user has accumulated many session files.
            let scanned: CostSnapshot? = await Task.detached(priority: .utility) {
                await CostUsageScanner.scan(
                    tool: tool,
                    homeDirectory: home,
                    now: now,
                    retentionDays: retentionDays
                )
            }.value
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
            }
        }
        snapshots = results
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
        case .week:  dayCount = 7
        case .month: dayCount = 30
        case .all:   dayCount = nil
        }
        return await CostHistoryStore.shared.history(
            for: tool,
            days: dayCount,
            retentionDays: costData.retentionDays
        )
    }

    public func applyCostDataSettings() async {
        let costData = costDataSettingsProvider()
        guard !costData.privacyModeEnabled else {
            await eraseLocalCostData()
            return
        }
        await CostHistoryStore.shared.prune(retentionDays: costData.retentionDays)
        let cached = await CostSnapshotCache.shared.loadAll(retentionDays: costData.retentionDays, now: Date())
        snapshots = cached
        lastRefreshedAt = cached.values.map(\.updatedAt).max()
    }

    public func eraseLocalCostData() async {
        await CostHistoryStore.shared.eraseAll()
        await CostSnapshotCache.shared.eraseAll()
        CostUsageScanCache.eraseAll(homeDirectory: homeDirectory)
        snapshots = [:]
        extrasByTool = [:]
        lastRefreshedAt = nil
    }
}
