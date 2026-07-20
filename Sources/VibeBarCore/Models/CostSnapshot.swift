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

    /// Request count per window. Each event the CostAggregator sees
    /// (one JSONL line ≈ one assistant turn ≈ one provider request)
    /// increments these. Powers the RPM (Requests Per Minute) tile
    /// in the Overview cost row.
    public let todayRequests: Int
    public let last7DaysRequests: Int
    public let last30DaysRequests: Int
    public let allTimeRequests: Int

    /// Per-day series since `dayHistoryStart`, ordered ascending.
    public let dailyHistory: [DailyCostPoint]
    /// Per-hour series for the current local day, ordered ascending. This is
    /// derived from live JSONL events so the Today chart can show hourly shape
    /// instead of rendering one whole-day bar.
    public let todayHourlyHistory: [HourlyCostPoint]
    /// Per-hour series for the previous local day. Kept separately so the
    /// Yesterday range can retain the same line-chart detail as Today.
    public let yesterdayHourlyHistory: [HourlyCostPoint]
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
    /// Per-hour model breakdown for Today and Yesterday. This powers the
    /// hourly hover detail without inflating the long-term history file.
    public let hourlyModelBreakdown: [Date: [ModelBreakdown]]
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
        todayRequests: Int = 0,
        last7DaysRequests: Int = 0,
        last30DaysRequests: Int = 0,
        allTimeRequests: Int = 0,
        dailyHistory: [DailyCostPoint],
        todayHourlyHistory: [HourlyCostPoint] = [],
        yesterdayHourlyHistory: [HourlyCostPoint] = [],
        heatmap: UsageHeatmap,
        modelBreakdowns: [ModelBreakdown],
        last7DaysModelBreakdowns: [ModelBreakdown] = [],
        dailyModelBreakdown: [Date: [ModelBreakdown]] = [:],
        hourlyModelBreakdown: [Date: [ModelBreakdown]] = [:],
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
        self.todayRequests = todayRequests
        self.last7DaysRequests = last7DaysRequests
        self.last30DaysRequests = last30DaysRequests
        self.allTimeRequests = allTimeRequests
        self.dailyHistory = dailyHistory
        self.todayHourlyHistory = todayHourlyHistory
        self.yesterdayHourlyHistory = yesterdayHourlyHistory
        self.heatmap = heatmap
        self.modelBreakdowns = modelBreakdowns
        self.last7DaysModelBreakdowns = last7DaysModelBreakdowns
        self.dailyModelBreakdown = dailyModelBreakdown
        self.hourlyModelBreakdown = hourlyModelBreakdown
        self.jsonlFilesFound = jsonlFilesFound
        self.updatedAt = updatedAt
    }

    public static func empty(tool: ToolType, now: Date = Date()) -> CostSnapshot {
        CostSnapshot(
            tool: tool,
            todayCostUSD: 0, last7DaysCostUSD: 0, last30DaysCostUSD: 0, allTimeCostUSD: 0,
            todayTokens: 0, last7DaysTokens: 0, last30DaysTokens: 0, allTimeTokens: 0,
            todayRequests: 0, last7DaysRequests: 0, last30DaysRequests: 0, allTimeRequests: 0,
            dailyHistory: [], todayHourlyHistory: [], yesterdayHourlyHistory: [], heatmap: .empty(tool: tool),
            modelBreakdowns: [], last7DaysModelBreakdowns: [], dailyModelBreakdown: [:], hourlyModelBreakdown: [:], jsonlFilesFound: 0, updatedAt: now
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
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let hourlyYesterday = yesterdayHourlyHistory.filter {
            calendar.isDate($0.date, inSameDayAs: yesterday)
        }

        // Request counts have no daily history — they pass through
        // verbatim except for the today bucket, which we zero out
        // when the cached snapshot's `updatedAt` is from a previous
        // day (otherwise yesterday's TPM/RPM bleed into "today").
        let todayIsFresh = calendar.isDate(updatedAt, inSameDayAs: now)
        return CostSnapshot(
            tool: tool,
            todayCostUSD: hasDailyHistory ? todayCost : (todayIsFresh ? todayCostUSD : 0),
            last7DaysCostUSD: hasDailyHistory ? weekCost : last7DaysCostUSD,
            last30DaysCostUSD: hasDailyHistory ? monthCost : last30DaysCostUSD,
            allTimeCostUSD: hasDailyHistory ? allCost : allTimeCostUSD,
            todayTokens: hasDailyHistory ? todayTokenCount : (todayIsFresh ? todayTokens : 0),
            last7DaysTokens: hasDailyHistory ? weekTokenCount : last7DaysTokens,
            last30DaysTokens: hasDailyHistory ? monthTokenCount : last30DaysTokens,
            allTimeTokens: hasDailyHistory ? allTokenCount : allTimeTokens,
            todayRequests: todayIsFresh ? todayRequests : 0,
            last7DaysRequests: last7DaysRequests,
            last30DaysRequests: last30DaysRequests,
            allTimeRequests: allTimeRequests,
            dailyHistory: dailyHistory,
            todayHourlyHistory: hourlyToday,
            yesterdayHourlyHistory: hourlyYesterday,
            heatmap: heatmap,
            modelBreakdowns: modelBreakdowns,
            last7DaysModelBreakdowns: last7DaysModelBreakdowns,
            dailyModelBreakdown: dailyModelBreakdown,
            hourlyModelBreakdown: hourlyModelBreakdown,
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

    public func topModels(forHour hour: Date, limit: Int = 3, calendar: Calendar = .current) -> [ModelBreakdown] {
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: hour)
        guard let key = calendar.date(from: components) else { return [] }
        return Array((hourlyModelBreakdown[key] ?? []).prefix(limit))
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
        case todayRequests, last7DaysRequests, last30DaysRequests, allTimeRequests
        case dailyHistory, todayHourlyHistory, yesterdayHourlyHistory, heatmap, modelBreakdowns, last7DaysModelBreakdowns
        case dailyModelBreakdown, hourlyModelBreakdown
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
        // Request counts are new — cached snapshots from older builds
        // omit them; default to 0 so the TPM/RPM tiles render as 0
        // until the next scan lands.
        self.todayRequests = try c.decodeIfPresent(Int.self, forKey: .todayRequests) ?? 0
        self.last7DaysRequests = try c.decodeIfPresent(Int.self, forKey: .last7DaysRequests) ?? 0
        self.last30DaysRequests = try c.decodeIfPresent(Int.self, forKey: .last30DaysRequests) ?? 0
        self.allTimeRequests = try c.decodeIfPresent(Int.self, forKey: .allTimeRequests) ?? 0
        self.dailyHistory = try c.decode([DailyCostPoint].self, forKey: .dailyHistory)
        self.todayHourlyHistory = try c.decodeIfPresent([HourlyCostPoint].self, forKey: .todayHourlyHistory) ?? []
        self.yesterdayHourlyHistory = try c.decodeIfPresent([HourlyCostPoint].self, forKey: .yesterdayHourlyHistory) ?? []
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

        let hourlyStringKeyed = try c.decodeIfPresent([String: [ModelBreakdown]].self, forKey: .hourlyModelBreakdown) ?? [:]
        var hourlyRebuilt: [Date: [ModelBreakdown]] = [:]
        for (raw, value) in hourlyStringKeyed {
            if let date = Self.dateKeyFormatter.date(from: raw) {
                hourlyRebuilt[date] = value
            }
        }
        self.hourlyModelBreakdown = hourlyRebuilt
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
        try c.encode(todayRequests, forKey: .todayRequests)
        try c.encode(last7DaysRequests, forKey: .last7DaysRequests)
        try c.encode(last30DaysRequests, forKey: .last30DaysRequests)
        try c.encode(allTimeRequests, forKey: .allTimeRequests)
        try c.encode(dailyHistory, forKey: .dailyHistory)
        try c.encode(todayHourlyHistory, forKey: .todayHourlyHistory)
        try c.encode(yesterdayHourlyHistory, forKey: .yesterdayHourlyHistory)
        try c.encode(heatmap, forKey: .heatmap)
        try c.encode(modelBreakdowns, forKey: .modelBreakdowns)
        try c.encode(last7DaysModelBreakdowns, forKey: .last7DaysModelBreakdowns)
        try c.encode(jsonlFilesFound, forKey: .jsonlFilesFound)
        try c.encode(updatedAt, forKey: .updatedAt)

        let stringKeyed = Dictionary(
            uniqueKeysWithValues: dailyModelBreakdown.map { (Self.dateKeyFormatter.string(from: $0.key), $0.value) }
        )
        try c.encode(stringKeyed, forKey: .dailyModelBreakdown)
        let hourlyStringKeyed = Dictionary(
            uniqueKeysWithValues: hourlyModelBreakdown.map { (Self.dateKeyFormatter.string(from: $0.key), $0.value) }
        )
        try c.encode(hourlyStringKeyed, forKey: .hourlyModelBreakdown)
    }
}

/// Combine multiple `CostSnapshot`s into the aggregate inputs the Overview's
/// "all providers" cards need (Model Ranking, Past Year heatmap, When You Use
/// heatmap, Hourly Burn Rate). Lives in Core so the math is testable and the
/// view layer just plumbs values through.
///
/// Notes
/// - Daily history is summed by start-of-day in the supplied calendar so a
///   Codex day and a Claude day at the same wall-clock date land in the same
///   bucket.
/// - The 7×24 heatmap is summed cell-by-cell. The returned heatmap's `tool`
///   field is irrelevant for the combined view; callers should pass an
///   explicit title to `UsageActivityView` instead of relying on it.
/// - Models from different providers don't normally collide, but if they do
///   we sum costs/tokens under the shared name. The output is sorted by cost
///   desc to match the existing single-provider rendering.
public enum CostSnapshotAggregator {
    public static func combinedDailyHistory(
        _ snapshots: [CostSnapshot],
        calendar: Calendar = .current
    ) -> [DailyCostPoint] {
        var totals: [Date: (cost: Double, tokens: Int)] = [:]
        for snapshot in snapshots {
            for point in snapshot.dailyHistory {
                let day = calendar.startOfDay(for: point.date)
                let current = totals[day] ?? (0, 0)
                totals[day] = (current.cost + point.costUSD, current.tokens + point.totalTokens)
            }
        }
        return totals
            .map { DailyCostPoint(date: $0.key, costUSD: $0.value.cost, totalTokens: $0.value.tokens) }
            .sorted { $0.date < $1.date }
    }

    public static func combinedHourlyHistory(
        _ snapshots: [CostSnapshot],
        calendar: Calendar = .current
    ) -> [HourlyCostPoint] {
        var totals: [Date: (cost: Double, tokens: Int)] = [:]
        for snapshot in snapshots {
            for point in snapshot.todayHourlyHistory {
                let components = calendar.dateComponents([.year, .month, .day, .hour], from: point.date)
                guard let hour = calendar.date(from: components) else { continue }
                let current = totals[hour] ?? (0, 0)
                totals[hour] = (current.cost + point.costUSD, current.tokens + point.totalTokens)
            }
        }
        return totals
            .map { HourlyCostPoint(date: $0.key, costUSD: $0.value.cost, totalTokens: $0.value.tokens) }
            .sorted { $0.date < $1.date }
    }

    public static func combinedYesterdayHourlyHistory(
        _ snapshots: [CostSnapshot],
        calendar: Calendar = .current
    ) -> [HourlyCostPoint] {
        combineHourlyPoints(snapshots.flatMap(\.yesterdayHourlyHistory), calendar: calendar)
    }

    public static func combinedHourlyModelBreakdown(
        _ snapshots: [CostSnapshot],
        calendar: Calendar = .current
    ) -> [Date: [CostSnapshot.ModelBreakdown]] {
        var totals: [Date: [String: (cost: Double, tokens: Int)]] = [:]
        for snapshot in snapshots {
            for (rawHour, breakdowns) in snapshot.hourlyModelBreakdown {
                let components = calendar.dateComponents([.year, .month, .day, .hour], from: rawHour)
                guard let hour = calendar.date(from: components) else { continue }
                var hourTotals = totals[hour] ?? [:]
                for breakdown in breakdowns {
                    let current = hourTotals[breakdown.modelName] ?? (0, 0)
                    hourTotals[breakdown.modelName] = (
                        current.cost + breakdown.costUSD,
                        current.tokens + breakdown.totalTokens
                    )
                }
                totals[hour] = hourTotals
            }
        }
        return totals.mapValues { models in
            models.map {
                CostSnapshot.ModelBreakdown(modelName: $0.key, costUSD: $0.value.cost, totalTokens: $0.value.tokens)
            }.sorted { $0.costUSD > $1.costUSD }
        }
    }

    public static func combinedHeatmap(
        _ snapshots: [CostSnapshot],
        tool: ToolType? = nil
    ) -> UsageHeatmap {
        let zeroes = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        guard !snapshots.isEmpty else {
            return UsageHeatmap(tool: tool ?? .codex, cells: zeroes, totalTokens: 0)
        }
        var combined = zeroes
        var total = 0
        for snapshot in snapshots {
            let cells = snapshot.heatmap.cells
            for weekday in 0..<7 where weekday < cells.count {
                let row = cells[weekday]
                for hour in 0..<24 where hour < row.count {
                    combined[weekday][hour] += row[hour]
                }
            }
            total += snapshot.heatmap.totalTokens
        }
        return UsageHeatmap(tool: tool ?? snapshots.first?.tool ?? .codex, cells: combined, totalTokens: total)
    }

    public static func combinedModelBreakdowns(
        _ snapshots: [CostSnapshot]
    ) -> [CostSnapshot.ModelBreakdown] {
        combineBreakdowns(snapshots.flatMap(\.modelBreakdowns))
    }

    public static func combinedLast7DaysModelBreakdowns(
        _ snapshots: [CostSnapshot]
    ) -> [CostSnapshot.ModelBreakdown] {
        combineBreakdowns(snapshots.flatMap(\.last7DaysModelBreakdowns))
    }

    public static func combinedDailyModelBreakdown(
        _ snapshots: [CostSnapshot],
        calendar: Calendar = .current
    ) -> [Date: [CostSnapshot.ModelBreakdown]] {
        var totals: [Date: [String: (cost: Double, tokens: Int)]] = [:]
        for snapshot in snapshots {
            for (day, breakdowns) in snapshot.dailyModelBreakdown {
                let key = calendar.startOfDay(for: day)
                var dayTotals = totals[key] ?? [:]
                for breakdown in breakdowns {
                    let current = dayTotals[breakdown.modelName] ?? (0, 0)
                    dayTotals[breakdown.modelName] = (
                        current.cost + breakdown.costUSD,
                        current.tokens + breakdown.totalTokens
                    )
                }
                totals[key] = dayTotals
            }
        }
        return totals.mapValues { models in
            models
                .map { CostSnapshot.ModelBreakdown(modelName: $0.key, costUSD: $0.value.cost, totalTokens: $0.value.tokens) }
                .sorted { $0.costUSD > $1.costUSD }
        }
    }

    public static func combinedSnapshot(
        tool: ToolType,
        snapshots: [CostSnapshot],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> CostSnapshot {
        guard !snapshots.isEmpty else {
            return .empty(tool: tool, now: now)
        }

        let rebased = snapshots.map { $0.rebasedForCurrentDay(now: now, calendar: calendar) }
        return CostSnapshot(
            tool: tool,
            todayCostUSD: rebased.reduce(0) { $0 + $1.todayCostUSD },
            last7DaysCostUSD: rebased.reduce(0) { $0 + $1.last7DaysCostUSD },
            last30DaysCostUSD: rebased.reduce(0) { $0 + $1.last30DaysCostUSD },
            allTimeCostUSD: rebased.reduce(0) { $0 + $1.allTimeCostUSD },
            todayTokens: rebased.reduce(0) { $0 + $1.todayTokens },
            last7DaysTokens: rebased.reduce(0) { $0 + $1.last7DaysTokens },
            last30DaysTokens: rebased.reduce(0) { $0 + $1.last30DaysTokens },
            allTimeTokens: rebased.reduce(0) { $0 + $1.allTimeTokens },
            todayRequests: rebased.reduce(0) { $0 + $1.todayRequests },
            last7DaysRequests: rebased.reduce(0) { $0 + $1.last7DaysRequests },
            last30DaysRequests: rebased.reduce(0) { $0 + $1.last30DaysRequests },
            allTimeRequests: rebased.reduce(0) { $0 + $1.allTimeRequests },
            dailyHistory: combinedDailyHistory(rebased, calendar: calendar),
            todayHourlyHistory: combinedHourlyHistory(rebased, calendar: calendar),
            yesterdayHourlyHistory: combinedYesterdayHourlyHistory(rebased, calendar: calendar),
            heatmap: combinedHeatmap(rebased, tool: tool),
            modelBreakdowns: combinedModelBreakdowns(rebased),
            last7DaysModelBreakdowns: combinedLast7DaysModelBreakdowns(rebased),
            dailyModelBreakdown: combinedDailyModelBreakdown(rebased, calendar: calendar),
            hourlyModelBreakdown: combinedHourlyModelBreakdown(rebased, calendar: calendar),
            jsonlFilesFound: rebased.reduce(0) { $0 + $1.jsonlFilesFound },
            updatedAt: rebased.map(\.updatedAt).max() ?? now
        )
    }

    private static func combineBreakdowns(
        _ breakdowns: [CostSnapshot.ModelBreakdown]
    ) -> [CostSnapshot.ModelBreakdown] {
        var totals: [String: (cost: Double, tokens: Int)] = [:]
        for breakdown in breakdowns {
            let current = totals[breakdown.modelName] ?? (0, 0)
            totals[breakdown.modelName] = (
                current.cost + breakdown.costUSD,
                current.tokens + breakdown.totalTokens
            )
        }
        return totals
            .map { CostSnapshot.ModelBreakdown(modelName: $0.key, costUSD: $0.value.cost, totalTokens: $0.value.tokens) }
            .sorted { $0.costUSD > $1.costUSD }
    }

    private static func combineHourlyPoints(
        _ points: [HourlyCostPoint],
        calendar: Calendar
    ) -> [HourlyCostPoint] {
        var totals: [Date: (cost: Double, tokens: Int)] = [:]
        for point in points {
            let components = calendar.dateComponents([.year, .month, .day, .hour], from: point.date)
            guard let hour = calendar.date(from: components) else { continue }
            let current = totals[hour] ?? (0, 0)
            totals[hour] = (current.cost + point.costUSD, current.tokens + point.totalTokens)
        }
        return totals.map {
            HourlyCostPoint(date: $0.key, costUSD: $0.value.cost, totalTokens: $0.value.tokens)
        }.sorted { $0.date < $1.date }
    }
}

public enum CostTimeframe: String, CaseIterable, Identifiable, Sendable {
    case today
    case yesterday
    case week
    case month
    case all

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .week:  return "7 days"
        case .month: return "30 days"
        case .all:   return "All"
        }
    }

    public var shortLabel: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .week:  return "7d"
        case .month: return "30d"
        case .all:   return "All"
        }
    }

    public func cost(in snapshot: CostSnapshot) -> Double {
        switch self {
        case .today: return snapshot.todayCostUSD
        case .yesterday:
            return snapshot.dailyHistory.first {
                Calendar.current.isDate($0.date, inSameDayAs: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
            }?.costUSD ?? 0
        case .week:  return snapshot.last7DaysCostUSD
        case .month: return snapshot.last30DaysCostUSD
        case .all:   return snapshot.allTimeCostUSD
        }
    }

    public func tokens(in snapshot: CostSnapshot) -> Int {
        switch self {
        case .today: return snapshot.todayTokens
        case .yesterday:
            return snapshot.dailyHistory.first {
                Calendar.current.isDate($0.date, inSameDayAs: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
            }?.totalTokens ?? 0
        case .week:  return snapshot.last7DaysTokens
        case .month: return snapshot.last30DaysTokens
        case .all:   return snapshot.allTimeTokens
        }
    }
}
