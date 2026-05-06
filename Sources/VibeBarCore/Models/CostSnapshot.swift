import Foundation

/// Aggregated token + cost data for a single tool over multiple windows.
///
/// Codable so we can persist the full snapshot to disk (`CostSnapshotCache`)
/// — that way the popover shows real numbers instantly on app launch, before
/// the next background scan completes.
public struct CostSnapshot: Sendable, Equatable, Codable {
    public let tool: ToolType

    public let todayCostUSD: Double
    public let last7DaysCostUSD: Double
    public let last30DaysCostUSD: Double
    public let allTimeCostUSD: Double

    public let todayTokens: Int
    public let last7DaysTokens: Int
    public let last30DaysTokens: Int
    public let allTimeTokens: Int

    /// Per-day series since `dayHistoryStart`, ordered ascending.
    public let dailyHistory: [DailyCostPoint]
    /// Per-hour series for the current local day, ordered ascending. This is
    /// derived from live JSONL events so the Today chart can show hourly shape
    /// instead of rendering one whole-day bar.
    public let todayHourlyHistory: [HourlyCostPoint]
    /// 7×24 cells: weekday (1-7, Sunday=1) × hour (0-23) → token total.
    public let heatmap: UsageHeatmap
    /// Top models in the all-time window.
    public let modelBreakdowns: [ModelBreakdown]
    /// Top models in the last 7 days. Used by the headline Top Model tile.
    public let last7DaysModelBreakdowns: [ModelBreakdown]
    /// Per-day top-model breakdown — computed live when the user scans local
    /// JSONL. Used for chart tooltips ("On Mar 5 you used Sonnet for $2.34").
    /// Not persisted to disk: when CostHistoryStore preserves a day from a
    /// rotated session, the model split is lost — but the totals are kept.
    public let dailyModelBreakdown: [Date: [ModelBreakdown]]
    public let jsonlFilesFound: Int
    public let updatedAt: Date

    public struct ModelBreakdown: Sendable, Equatable, Identifiable, Codable {
        public let modelName: String
        public let costUSD: Double
        public let totalTokens: Int
        public var id: String { modelName }

        public init(modelName: String, costUSD: Double, totalTokens: Int) {
            self.modelName = modelName
            self.costUSD = costUSD
            self.totalTokens = totalTokens
        }
    }

    public init(
        tool: ToolType,
        todayCostUSD: Double,
        last7DaysCostUSD: Double,
        last30DaysCostUSD: Double,
        allTimeCostUSD: Double,
        todayTokens: Int,
        last7DaysTokens: Int,
        last30DaysTokens: Int,
        allTimeTokens: Int,
        dailyHistory: [DailyCostPoint],
        todayHourlyHistory: [HourlyCostPoint] = [],
        heatmap: UsageHeatmap,
        modelBreakdowns: [ModelBreakdown],
        last7DaysModelBreakdowns: [ModelBreakdown] = [],
        dailyModelBreakdown: [Date: [ModelBreakdown]] = [:],
        jsonlFilesFound: Int,
        updatedAt: Date
    ) {
        self.tool = tool
        self.todayCostUSD = todayCostUSD
        self.last7DaysCostUSD = last7DaysCostUSD
        self.last30DaysCostUSD = last30DaysCostUSD
        self.allTimeCostUSD = allTimeCostUSD
        self.todayTokens = todayTokens
        self.last7DaysTokens = last7DaysTokens
        self.last30DaysTokens = last30DaysTokens
        self.allTimeTokens = allTimeTokens
        self.dailyHistory = dailyHistory
        self.todayHourlyHistory = todayHourlyHistory
        self.heatmap = heatmap
        self.modelBreakdowns = modelBreakdowns
        self.last7DaysModelBreakdowns = last7DaysModelBreakdowns
        self.dailyModelBreakdown = dailyModelBreakdown
        self.jsonlFilesFound = jsonlFilesFound
        self.updatedAt = updatedAt
    }

    public static func empty(tool: ToolType, now: Date = Date()) -> CostSnapshot {
        CostSnapshot(
            tool: tool,
            todayCostUSD: 0, last7DaysCostUSD: 0, last30DaysCostUSD: 0, allTimeCostUSD: 0,
            todayTokens: 0, last7DaysTokens: 0, last30DaysTokens: 0, allTimeTokens: 0,
            dailyHistory: [], todayHourlyHistory: [], heatmap: .empty(tool: tool),
            modelBreakdowns: [], last7DaysModelBreakdowns: [], dailyModelBreakdown: [:], jsonlFilesFound: 0, updatedAt: now
        )
    }

    /// Return a view-safe snapshot whose calendar-window totals are evaluated
    /// against `now`, not against the day when the snapshot was originally
    /// scanned and cached.
    public func rebasedForCurrentDay(now: Date = Date(), calendar: Calendar = .current) -> CostSnapshot {
        let today = calendar.startOfDay(for: now)
        let weekCutoff = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let monthCutoff = calendar.date(byAdding: .day, value: -29, to: today) ?? today

        var todayCost = 0.0, todayTokenCount = 0
        var weekCost = 0.0, weekTokenCount = 0
        var monthCost = 0.0, monthTokenCount = 0
        var allCost = 0.0, allTokenCount = 0

        for point in dailyHistory {
            let day = calendar.startOfDay(for: point.date)
            guard day <= today else { continue }
            allCost += point.costUSD
            allTokenCount += point.totalTokens
            if calendar.isDate(day, inSameDayAs: now) {
                todayCost += point.costUSD
                todayTokenCount += point.totalTokens
            }
            if day >= weekCutoff {
                weekCost += point.costUSD
                weekTokenCount += point.totalTokens
            }
            if day >= monthCutoff {
                monthCost += point.costUSD
                monthTokenCount += point.totalTokens
            }
        }

        let hasDailyHistory = !dailyHistory.isEmpty
        let hourlyToday = todayHourlyHistory.filter {
            calendar.isDate($0.date, inSameDayAs: now)
        }

        return CostSnapshot(
            tool: tool,
            todayCostUSD: hasDailyHistory ? todayCost : (calendar.isDate(updatedAt, inSameDayAs: now) ? todayCostUSD : 0),
            last7DaysCostUSD: hasDailyHistory ? weekCost : last7DaysCostUSD,
            last30DaysCostUSD: hasDailyHistory ? monthCost : last30DaysCostUSD,
            allTimeCostUSD: hasDailyHistory ? allCost : allTimeCostUSD,
            todayTokens: hasDailyHistory ? todayTokenCount : (calendar.isDate(updatedAt, inSameDayAs: now) ? todayTokens : 0),
            last7DaysTokens: hasDailyHistory ? weekTokenCount : last7DaysTokens,
            last30DaysTokens: hasDailyHistory ? monthTokenCount : last30DaysTokens,
            allTimeTokens: hasDailyHistory ? allTokenCount : allTimeTokens,
            dailyHistory: dailyHistory,
            todayHourlyHistory: hourlyToday,
            heatmap: heatmap,
            modelBreakdowns: modelBreakdowns,
            last7DaysModelBreakdowns: last7DaysModelBreakdowns,
            dailyModelBreakdown: dailyModelBreakdown,
            jsonlFilesFound: jsonlFilesFound,
            updatedAt: updatedAt
        )
    }

    /// Top 3 models for a given day — used by the cost history chart tooltip.
    /// Returns empty when the day predates the live scan (only cost/token
    /// totals were preserved from CostHistoryStore).
    public func topModels(for day: Date, limit: Int = 3) -> [ModelBreakdown] {
        let key = Calendar.current.startOfDay(for: day)
        return Array((dailyModelBreakdown[key] ?? []).prefix(limit))
    }

    // MARK: - Codable
    //
    // The default synthesis can't encode `[Date: [ModelBreakdown]]` as JSON
    // because dictionary keys must be String. We re-key the per-day model
    // breakdown by ISO-8601 date string before encoding and decode the same
    // way. Everything else round-trips with the default behavior.

    private enum CodingKeys: String, CodingKey {
        case tool, todayCostUSD, last7DaysCostUSD, last30DaysCostUSD, allTimeCostUSD
        case todayTokens, last7DaysTokens, last30DaysTokens, allTimeTokens
        case dailyHistory, todayHourlyHistory, heatmap, modelBreakdowns, last7DaysModelBreakdowns, dailyModelBreakdown
        case jsonlFilesFound, updatedAt
    }

    private static let dateKeyFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.tool = try c.decode(ToolType.self, forKey: .tool)
        self.todayCostUSD = try c.decode(Double.self, forKey: .todayCostUSD)
        self.last7DaysCostUSD = try c.decode(Double.self, forKey: .last7DaysCostUSD)
        self.last30DaysCostUSD = try c.decode(Double.self, forKey: .last30DaysCostUSD)
        self.allTimeCostUSD = try c.decode(Double.self, forKey: .allTimeCostUSD)
        self.todayTokens = try c.decode(Int.self, forKey: .todayTokens)
        self.last7DaysTokens = try c.decode(Int.self, forKey: .last7DaysTokens)
        self.last30DaysTokens = try c.decode(Int.self, forKey: .last30DaysTokens)
        self.allTimeTokens = try c.decode(Int.self, forKey: .allTimeTokens)
        self.dailyHistory = try c.decode([DailyCostPoint].self, forKey: .dailyHistory)
        self.todayHourlyHistory = try c.decodeIfPresent([HourlyCostPoint].self, forKey: .todayHourlyHistory) ?? []
        self.heatmap = try c.decode(UsageHeatmap.self, forKey: .heatmap)
        self.modelBreakdowns = try c.decode([ModelBreakdown].self, forKey: .modelBreakdowns)
        self.last7DaysModelBreakdowns = try c.decodeIfPresent(
            [ModelBreakdown].self,
            forKey: .last7DaysModelBreakdowns
        ) ?? self.modelBreakdowns
        self.jsonlFilesFound = try c.decode(Int.self, forKey: .jsonlFilesFound)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)

        let stringKeyed = try c.decodeIfPresent([String: [ModelBreakdown]].self, forKey: .dailyModelBreakdown) ?? [:]
        var rebuilt: [Date: [ModelBreakdown]] = [:]
        for (raw, value) in stringKeyed {
            if let date = Self.dateKeyFormatter.date(from: raw) {
                rebuilt[date] = value
            }
        }
        self.dailyModelBreakdown = rebuilt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tool, forKey: .tool)
        try c.encode(todayCostUSD, forKey: .todayCostUSD)
        try c.encode(last7DaysCostUSD, forKey: .last7DaysCostUSD)
        try c.encode(last30DaysCostUSD, forKey: .last30DaysCostUSD)
        try c.encode(allTimeCostUSD, forKey: .allTimeCostUSD)
        try c.encode(todayTokens, forKey: .todayTokens)
        try c.encode(last7DaysTokens, forKey: .last7DaysTokens)
        try c.encode(last30DaysTokens, forKey: .last30DaysTokens)
        try c.encode(allTimeTokens, forKey: .allTimeTokens)
        try c.encode(dailyHistory, forKey: .dailyHistory)
        try c.encode(todayHourlyHistory, forKey: .todayHourlyHistory)
        try c.encode(heatmap, forKey: .heatmap)
        try c.encode(modelBreakdowns, forKey: .modelBreakdowns)
        try c.encode(last7DaysModelBreakdowns, forKey: .last7DaysModelBreakdowns)
        try c.encode(jsonlFilesFound, forKey: .jsonlFilesFound)
        try c.encode(updatedAt, forKey: .updatedAt)

        let stringKeyed = Dictionary(
            uniqueKeysWithValues: dailyModelBreakdown.map { (Self.dateKeyFormatter.string(from: $0.key), $0.value) }
        )
        try c.encode(stringKeyed, forKey: .dailyModelBreakdown)
    }
}

public enum CostTimeframe: String, CaseIterable, Identifiable, Sendable {
    case today
    case week
    case month
    case all

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .today: return "Today"
        case .week:  return "7 days"
        case .month: return "30 days"
        case .all:   return "All"
        }
    }

    public var shortLabel: String {
        switch self {
        case .today: return "Today"
        case .week:  return "7d"
        case .month: return "30d"
        case .all:   return "All"
        }
    }

    public func cost(in snapshot: CostSnapshot) -> Double {
        switch self {
        case .today: return snapshot.todayCostUSD
        case .week:  return snapshot.last7DaysCostUSD
        case .month: return snapshot.last30DaysCostUSD
        case .all:   return snapshot.allTimeCostUSD
        }
    }

    public func tokens(in snapshot: CostSnapshot) -> Int {
        switch self {
        case .today: return snapshot.todayTokens
        case .week:  return snapshot.last7DaysTokens
        case .month: return snapshot.last30DaysTokens
        case .all:   return snapshot.allTimeTokens
        }
    }
}
