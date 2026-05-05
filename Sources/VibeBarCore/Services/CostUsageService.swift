import Foundation
import Combine

/// Owns per-tool CostSnapshot + ProviderExtras. Merges fresh JSONL scans with
/// the persisted CostHistoryStore using max() per (tool, day), so old data
/// rotated off disk by Codex/Claude is preserved across runs.
@MainActor
public final class CostUsageService: ObservableObject {
    @Published public private(set) var snapshots: [ToolType: CostSnapshot] = [:]
    @Published public private(set) var extrasByTool: [ToolType: ProviderExtras] = [:]
    @Published public private(set) var isRefreshing: Bool = false
    @Published public private(set) var lastRefreshedAt: Date?
    /// Set by callers (e.g. AppEnvironment) to surface Claude extras parsed
    /// from the OAuth response. Updated each time QuotaService refreshes.
    public func setLiveExtras(_ extras: ProviderExtras?, for tool: ToolType) {
        if let extras { extrasByTool[tool] = extras }
        else { extrasByTool.removeValue(forKey: tool) }
    }

    private let homeDirectory: String
    private let mockProvider: () -> Bool

    public init(
        homeDirectory: String = NSHomeDirectory(),
        mockProvider: @escaping () -> Bool = { false }
    ) {
        self.homeDirectory = homeDirectory
        self.mockProvider = mockProvider
        // Surface the most recent persisted snapshot per tool immediately so
        // the popover doesn't render an empty Cost panel while the first
        // background scan is still running. The fresh scan replaces this when
        // it completes (typically within a second on modern hardware).
        Task { @MainActor in
            let cached = await CostSnapshotCache.shared.loadAll()
            for (tool, snap) in cached where self.snapshots[tool] == nil {
                self.snapshots[tool] = snap
            }
            if !cached.isEmpty {
                self.lastRefreshedAt = cached.values.map(\.updatedAt).max()
            }
        }
    }

    public func snapshot(for tool: ToolType) -> CostSnapshot? {
        snapshots[tool]
    }

    public func extras(for tool: ToolType) -> ProviderExtras? {
        extrasByTool[tool]
    }

    public func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let now = Date()
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
            if let scanned = await CostUsageScanner.scan(tool: tool, homeDirectory: home, now: now) {
                let merged = await CostHistoryStore.shared.mergeAndAugment(scanned)
                results[tool] = merged
                // Persist the post-merge snapshot so a future launch can show
                // these numbers without waiting for a fresh scan.
                await CostSnapshotCache.shared.save(merged)
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
        return await CostHistoryStore.shared.history(for: tool, days: dayCount)
    }
}
