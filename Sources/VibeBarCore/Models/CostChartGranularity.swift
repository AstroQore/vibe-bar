import Foundation

/// How a navigable cost chart buckets its points.
///
/// Distinct from the popover's timeframe control: this granularity follows the
/// *visible* span of a pannable chart, so zooming into three days of a
/// year-long domain switches to hourly bars without the user changing mode.
public enum CostChartGranularity: String, CaseIterable, Sendable, Identifiable {
    case hour
    case day
    case week

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hour: "Hour"
        case .day: "Day"
        case .week: "Week"
        }
    }

    /// Approximate bucket width, for laying out bar marks before the data is
    /// grouped.
    public var approximateBucketSeconds: TimeInterval {
        switch self {
        case .hour: 3_600
        case .day: 86_400
        case .week: 7 * 86_400
        }
    }

    private static let dayInterval: TimeInterval = 86_400

    /// What "Auto" resolves to for a visible span.
    ///
    /// Thresholds are picked so each mode lands at a readable bar count: about
    /// 62 hourly bars at the top of the hour range, about 110 daily bars at the
    /// top of the day range, weeks beyond that.
    public static func resolve(autoFor visibleSpan: TimeInterval) -> CostChartGranularity {
        let days = max(0, visibleSpan) / dayInterval
        if days <= 2.6 { return .hour }
        if days <= 110 { return .day }
        return .week
    }

    /// Granularities the user may pick at this visible span, coarsest-last.
    ///
    /// Hourly disappears once the span could not be drawn without hundreds of
    /// bars; weekly only appears once there are enough weeks to compare. Daily
    /// is always offered so the control never collapses to nothing.
    public static func allowed(for visibleSpan: TimeInterval) -> [CostChartGranularity] {
        let days = max(0, visibleSpan) / dayInterval
        var options: [CostChartGranularity] = []
        if days <= 7 { options.append(.hour) }
        options.append(.day)
        if days >= 21 { options.append(.week) }
        return options
    }

    public static func isAllowed(
        _ granularity: CostChartGranularity,
        for visibleSpan: TimeInterval
    ) -> Bool {
        allowed(for: visibleSpan).contains(granularity)
    }
}

/// One Monday-anchored week of cost history.
public struct WeeklyCostPoint: Sendable, Equatable, Identifiable {
    public let weekStart: Date
    public let costUSD: Double
    public let totalTokens: Int

    public var id: Date { weekStart }

    public init(weekStart: Date, costUSD: Double, totalTokens: Int) {
        self.weekStart = weekStart
        self.costUSD = costUSD
        self.totalTokens = totalTokens
    }
}

/// Regrouping helpers for the cost chart.
public enum CostChartAggregation {
    /// Sum daily points into Monday-start weeks, oldest first.
    ///
    /// Partial weeks at either end are kept as-is — a week with two days of
    /// data is a real, if short, bar rather than something to hide.
    public static func weekly(
        _ days: [DailyCostPoint],
        calendar: Calendar = .current
    ) -> [WeeklyCostPoint] {
        var totals: [Date: (cost: Double, tokens: Int)] = [:]
        for day in days {
            guard let weekStart = mondayStart(of: day.date, calendar: calendar) else { continue }
            var value = totals[weekStart] ?? (0, 0)
            value.cost += day.costUSD
            value.tokens += day.totalTokens
            totals[weekStart] = value
        }
        return totals
            .map { WeeklyCostPoint(weekStart: $0.key, costUSD: $0.value.cost, totalTokens: $0.value.tokens) }
            .sorted { $0.weekStart < $1.weekStart }
    }

    /// Midnight on the Monday of the week containing `date`.
    ///
    /// Derived from the weekday component rather than `Calendar.firstWeekday`,
    /// so the bucket boundary stays on Monday regardless of the user's locale
    /// (US locales default to a Sunday-start week).
    public static func mondayStart(of date: Date, calendar: Calendar = .current) -> Date? {
        let startOfDay = calendar.startOfDay(for: date)
        // Gregorian weekday numbering: 1 = Sunday … 7 = Saturday, so Monday is
        // 2 and `(weekday + 5) % 7` is the day count back to it.
        let offset = (calendar.component(.weekday, from: startOfDay) + 5) % 7
        return calendar.date(byAdding: .day, value: -offset, to: startOfDay)
    }
}
