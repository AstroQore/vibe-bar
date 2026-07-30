import Foundation

/// The cross-provider rollups the Overview's "all providers" cards draw.
///
/// Bundled into one value because they share every input: recomputing them
/// individually meant re-rebasing and re-bucketing the same snapshots once per
/// card per render pass.
public struct CostRollup: Sendable, Equatable {
    /// Everything that went into the rollup: each individual provider that has
    /// a snapshot at all, plus one combined snapshot per group that carries
    /// data. This is the list the "does the Overview have cost cards" question
    /// is answered from.
    public let snapshots: [CostSnapshot]
    /// One combined snapshot per requested group, in the order the groups were
    /// passed — Gemini Web + AntiGravity rolled up as the single "Gemini"
    /// platform. Kept separately because the per-group card needs its own
    /// group's total, not the all-providers sum.
    public let groupSnapshots: [CostSnapshot]
    public let dailyHistory: [DailyCostPoint]
    public let heatmap: UsageHeatmap
    public let modelBreakdowns: [CostSnapshot.ModelBreakdown]
    public let combinedSnapshot: CostSnapshot

    public init(
        snapshots: [CostSnapshot],
        groupSnapshots: [CostSnapshot],
        dailyHistory: [DailyCostPoint],
        heatmap: UsageHeatmap,
        modelBreakdowns: [CostSnapshot.ModelBreakdown],
        combinedSnapshot: CostSnapshot
    ) {
        self.snapshots = snapshots
        self.groupSnapshots = groupSnapshots
        self.dailyHistory = dailyHistory
        self.heatmap = heatmap
        self.modelBreakdowns = modelBreakdowns
        self.combinedSnapshot = combinedSnapshot
    }

    /// Whether any provider in the rollup has found session logs. The Overview
    /// gates its cost and analytics cards on this.
    public var hasCostData: Bool {
        snapshots.contains { $0.jsonlFilesFound > 0 }
    }
}

/// Several tools the product presents as one platform, and the tool the
/// combined snapshot is labelled with — Gemini Web + AntiGravity combined and
/// labelled `.antigravity`, which is what the "Gemini" cost card renders.
public struct CostSnapshotGroup: Hashable, Sendable {
    public let label: ToolType
    public let tools: [ToolType]

    public init(label: ToolType, tools: [ToolType]) {
        self.label = label
        self.tools = tools
    }
}

/// Cost and token totals across a set of providers, for the Overview's
/// headline grid.
public struct CostTotals: Sendable, Equatable {
    public let allTimeCostUSD: Double
    public let todayCostUSD: Double
    public let yesterdayCostUSD: Double
    public let last7DaysCostUSD: Double
    public let last30DaysCostUSD: Double
    public let allTimeTokens: Int
    public let todayTokens: Int
    public let yesterdayTokens: Int
    public let last7DaysTokens: Int
    public let last30DaysTokens: Int
    /// Cost and token peaks are independent: the most expensive day is not
    /// necessarily the day with the highest token volume.
    public let peakDayCostUSD: Double
    public let peakDayTokens: Int

    public static let empty = CostTotals(
        allTimeCostUSD: 0,
        todayCostUSD: 0,
        yesterdayCostUSD: 0,
        last7DaysCostUSD: 0,
        last30DaysCostUSD: 0,
        allTimeTokens: 0,
        todayTokens: 0,
        yesterdayTokens: 0,
        last7DaysTokens: 0,
        last30DaysTokens: 0,
        peakDayCostUSD: 0,
        peakDayTokens: 0
    )

    public init(
        allTimeCostUSD: Double,
        todayCostUSD: Double,
        yesterdayCostUSD: Double,
        last7DaysCostUSD: Double,
        last30DaysCostUSD: Double,
        allTimeTokens: Int,
        todayTokens: Int,
        yesterdayTokens: Int,
        last7DaysTokens: Int,
        last30DaysTokens: Int,
        peakDayCostUSD: Double,
        peakDayTokens: Int
    ) {
        self.allTimeCostUSD = allTimeCostUSD
        self.todayCostUSD = todayCostUSD
        self.yesterdayCostUSD = yesterdayCostUSD
        self.last7DaysCostUSD = last7DaysCostUSD
        self.last30DaysCostUSD = last30DaysCostUSD
        self.allTimeTokens = allTimeTokens
        self.todayTokens = todayTokens
        self.yesterdayTokens = yesterdayTokens
        self.last7DaysTokens = last7DaysTokens
        self.last30DaysTokens = last30DaysTokens
        self.peakDayCostUSD = peakDayCostUSD
        self.peakDayTokens = peakDayTokens
    }
}

/// Memoizes everything the cost UI derives from the raw per-tool snapshots.
///
/// Three separate costs used to be paid on every single popover render pass,
/// including the ones triggered by an unrelated quota publish:
///
/// - `CostSnapshot.rebasedForCurrentDay()` walks a provider's whole daily
///   history with a `Calendar` round trip per point, and roughly ten call
///   sites ask for it — several of them from inside a SwiftUI `body`.
/// - `CostSnapshotAggregator.combinedSnapshot` re-rebases every provider and
///   then re-buckets ~720 hourly keys.
/// - The Overview asked for both of those four times per `body`, because the
///   module catalog, the rollup context, and the Gemini card each recomputed
///   them independently.
///
/// Every one of those is a pure function of (raw snapshots, local day), so the
/// results live here until `setSource` replaces the snapshots or the day rolls
/// over. Day rollover is detected against a cached midnight-to-midnight range
/// so the common path is a `Date` range check rather than a calendar round
/// trip.
///
/// Not thread-safe by design: it is owned by the `@MainActor`
/// `CostUsageService` and only ever touched from there.
public final class CostAggregationCache {
    private struct RollupKey: Hashable {
        let individualTools: [ToolType]
        let groups: [CostSnapshotGroup]
        let label: ToolType
    }

    private struct CombinedKey: Hashable {
        let tools: [ToolType]
        let label: ToolType
    }

    private var calendar: Calendar
    private var timeZoneObserver: NSObjectProtocol?

    private var source: [ToolType: CostSnapshot] = [:]
    private var rebasedByTool: [ToolType: CostSnapshot] = [:]
    private var combinedByKey: [CombinedKey: CostSnapshot] = [:]
    private var rollupByKey: [RollupKey: CostRollup] = [:]
    private var totalsByTools: [[ToolType]: CostTotals] = [:]
    /// The local day every memo above was computed for, as a half-open range.
    private var dayRange: Range<Date>?

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
        // `Calendar.current` freezes the time zone it was read under, and this
        // cache lives as long as the menu bar does. Without this, a system
        // zone change (travel, DST rule updates) would keep "today" cut at the
        // old midnight until relaunch, because `refreshDay`'s fast path never
        // consults the zone again. Main queue on purpose: the cache is owned
        // by the `@MainActor` service and is not thread-safe.
        timeZoneObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.adoptCalendar(.current)
        }
    }

    deinit {
        if let timeZoneObserver {
            NotificationCenter.default.removeObserver(timeZoneObserver)
        }
    }

    /// Switch to a calendar (and thus time zone) and drop every derived value —
    /// the memos were all cut at the old midnight. Internal so a test can hand
    /// in a fixed-zone calendar; production only ever passes `.current`, which
    /// also overwrites an injected calendar the moment the system zone really
    /// changes, matching what the default initializer would have captured.
    func adoptCalendar(_ calendar: Calendar) {
        self.calendar = calendar
        dayRange = nil
        invalidateDerived()
    }

    /// Replace the raw snapshots and drop every derived value.
    public func setSource(_ snapshots: [ToolType: CostSnapshot]) {
        source = snapshots
        invalidateDerived()
    }

    /// Test hook: replace the raw snapshots *without* announcing the change, so
    /// a test can prove an answer came out of the memo instead of being
    /// recomputed.
    func setSourceWithoutInvalidatingForTesting(_ snapshots: [ToolType: CostSnapshot]) {
        source = snapshots
    }

    /// Raw file count for one tool, without rebasing or combining anything.
    ///
    /// `jsonlFilesFound` survives both rebasing and combining untouched, so
    /// "does this provider have cost data" never needs either — and the module
    /// catalog asks that question on every render pass.
    public func jsonlFilesFound(for tool: ToolType) -> Int {
        source[tool]?.jsonlFilesFound ?? 0
    }

    public func hasJSONLFiles(in tools: [ToolType]) -> Bool {
        tools.contains { jsonlFilesFound(for: $0) > 0 }
    }

    /// The view-safe snapshot for one tool: window totals evaluated against
    /// today rather than against the day the snapshot was scanned.
    public func snapshot(for tool: ToolType, now: Date = Date()) -> CostSnapshot? {
        refreshDay(now: now)
        guard let raw = source[tool] else { return nil }
        if let cached = rebasedByTool[tool] { return cached }
        let rebased = raw.rebasedForCurrentDay(now: now, calendar: calendar)
        rebasedByTool[tool] = rebased
        return rebased
    }

    /// One snapshot for several tools that the product presents as a single
    /// platform.
    public func combinedSnapshot(
        of tools: [ToolType],
        labelledAs label: ToolType,
        now: Date = Date()
    ) -> CostSnapshot {
        refreshDay(now: now)
        let key = CombinedKey(tools: tools, label: label)
        if let cached = combinedByKey[key] { return cached }
        let parts = tools.compactMap { source[$0] }
        let combined = CostSnapshotAggregator.combinedSnapshot(
            tool: label,
            snapshots: parts,
            now: now,
            calendar: calendar
        )
        combinedByKey[key] = combined
        return combined
    }

    /// The Overview's rollup: `individualTools` contribute their own snapshot,
    /// each entry of `groups` is combined into one snapshot first, and the
    /// whole set is then aggregated.
    ///
    /// A group only joins the aggregate when it actually has data — an empty
    /// Gemini + AntiGravity pair would otherwise contribute a zero-filled
    /// snapshot and make `hasCostData` true for a provider with no logs.
    ///
    /// Group snapshots go through `combinedSnapshot`, so the group total here
    /// and the same platform's own card share one cache entry rather than
    /// combining the pair twice.
    public func rollup(
        individualTools: [ToolType],
        groups: [CostSnapshotGroup] = [],
        labelledAs label: ToolType,
        now: Date = Date()
    ) -> CostRollup {
        refreshDay(now: now)
        let key = RollupKey(individualTools: individualTools, groups: groups, label: label)
        if let cached = rollupByKey[key] { return cached }

        let groupSnapshots = groups.map {
            combinedSnapshot(of: $0.tools, labelledAs: $0.label, now: now)
        }
        var snapshots = individualTools.compactMap { snapshot(for: $0, now: now) }
        snapshots.append(contentsOf: groupSnapshots.filter { $0.jsonlFilesFound > 0 })

        let rollup = CostRollup(
            snapshots: snapshots,
            groupSnapshots: groupSnapshots,
            dailyHistory: CostSnapshotAggregator.combinedDailyHistory(snapshots, calendar: calendar),
            heatmap: CostSnapshotAggregator.combinedHeatmap(snapshots),
            modelBreakdowns: CostSnapshotAggregator.combinedModelBreakdowns(snapshots),
            combinedSnapshot: CostSnapshotAggregator.combinedSnapshot(
                tool: label,
                snapshots: snapshots,
                now: now,
                calendar: calendar
            )
        )
        rollupByKey[key] = rollup
        return rollup
    }

    /// Headline cost and token totals over a set of providers.
    public func totals(of tools: [ToolType], now: Date = Date()) -> CostTotals {
        refreshDay(now: now)
        if let cached = totalsByTools[tools] { return cached }
        let snapshots = tools.compactMap { snapshot(for: $0, now: now) }
        let dailyHistory = CostSnapshotAggregator.combinedDailyHistory(snapshots, calendar: calendar)
        let yesterday = calendar.date(
            byAdding: .day,
            value: -1,
            to: calendar.startOfDay(for: now)
        ) ?? now
        let yesterdayPoints = snapshots.compactMap { snapshot in
            snapshot.dailyHistory.first { calendar.isDate($0.date, inSameDayAs: yesterday) }
        }
        let totals = CostTotals(
            allTimeCostUSD: snapshots.reduce(0) { $0 + $1.allTimeCostUSD },
            todayCostUSD: snapshots.reduce(0) { $0 + $1.todayCostUSD },
            yesterdayCostUSD: yesterdayPoints.reduce(0) { $0 + $1.costUSD },
            last7DaysCostUSD: snapshots.reduce(0) { $0 + $1.last7DaysCostUSD },
            last30DaysCostUSD: snapshots.reduce(0) { $0 + $1.last30DaysCostUSD },
            allTimeTokens: snapshots.reduce(0) { $0 + $1.allTimeTokens },
            todayTokens: snapshots.reduce(0) { $0 + $1.todayTokens },
            yesterdayTokens: yesterdayPoints.reduce(0) { $0 + $1.totalTokens },
            last7DaysTokens: snapshots.reduce(0) { $0 + $1.last7DaysTokens },
            last30DaysTokens: snapshots.reduce(0) { $0 + $1.last30DaysTokens },
            peakDayCostUSD: CostSnapshotAggregator.peakDailyCost(in: dailyHistory),
            peakDayTokens: CostSnapshotAggregator.peakDailyTokens(in: dailyHistory)
        )
        totalsByTools[tools] = totals
        return totals
    }

    // MARK: - Private

    private func refreshDay(now: Date) {
        if let dayRange, dayRange.contains(now) { return }
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        // A clock that jumps backwards (manual change, NTP correction) lands
        // outside the cached range too, which is exactly the right response:
        // every window total is relative to "today".
        dayRange = start..<max(end, start.addingTimeInterval(1))
        invalidateDerived()
    }

    private func invalidateDerived() {
        rebasedByTool.removeAll(keepingCapacity: true)
        combinedByKey.removeAll(keepingCapacity: true)
        rollupByKey.removeAll(keepingCapacity: true)
        totalsByTools.removeAll(keepingCapacity: true)
    }
}
