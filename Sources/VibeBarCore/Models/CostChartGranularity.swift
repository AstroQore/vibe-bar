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
    case month

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hour: L10n.Cost.Granularity.hour
        case .day: L10n.Cost.Granularity.day
        case .week: L10n.Cost.Granularity.week
        case .month: L10n.Cost.Granularity.month
        }
    }

    /// Approximate bucket width, for laying out bar marks before the data is
    /// grouped. Calendar months vary, so the monthly value is the 30-day
    /// nominal one — anything that needs exact edges asks the calendar.
    public var approximateBucketSeconds: TimeInterval {
        switch self {
        case .hour: 3_600
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        }
    }

    private static let dayInterval: TimeInterval = 86_400

    /// What "Auto" resolves to for a visible span.
    ///
    /// The ladder is chosen by how many bars a mode would leave on screen, not
    /// by how many it *could* draw:
    ///
    /// - **≤ 5 days → hour.** Fewer than about six daily bars is a sparse
    ///   chart: three or four slabs floating in a wide plot. The same span
    ///   carries 24–120 hourly points, which is where a cost chart actually
    ///   shows the shape of a working day.
    /// - **≤ 110 days → day.** The everyday range; 110 daily bars is about as
    ///   dense as this card can draw before bars stop being comparable.
    /// - **≤ 240 days → week.** Roughly 16 to 34 weekly bars.
    /// - **beyond → month.** Eight months is already 34+ weeks; past that the
    ///   domain is a shape, not a series of individual weeks. A ten-month
    ///   "All" domain lands here.
    public static func resolve(autoFor visibleSpan: TimeInterval) -> CostChartGranularity {
        let days = max(0, visibleSpan) / dayInterval
        if days <= 5 { return .hour }
        if days <= 110 { return .day }
        if days <= 240 { return .week }
        return .month
    }

    /// Granularities the user may pick at this visible span, coarsest-last.
    ///
    /// Hourly disappears once the span could not be drawn without hundreds of
    /// bars; weekly only appears once there are enough weeks to compare, and
    /// monthly once there are at least two full months. Daily is always offered
    /// so the control never collapses to nothing.
    ///
    /// The hour unlock stays wider than the Auto threshold on purpose: Auto
    /// stops reaching for hours at five days, but a user who wants to compare a
    /// full week hour-by-hour can still ask for it.
    ///
    /// Weekly waits for four whole weeks rather than three: at three weeks the
    /// chart draws three or four slabs, which reads as a bar chart of nothing.
    public static func allowed(for visibleSpan: TimeInterval) -> [CostChartGranularity] {
        let days = max(0, visibleSpan) / dayInterval
        var options: [CostChartGranularity] = []
        if days <= 7 { options.append(.hour) }
        options.append(.day)
        if days >= 28 { options.append(.week) }
        if days >= 60 { options.append(.month) }
        return options
    }

    public static func isAllowed(
        _ granularity: CostChartGranularity,
        for visibleSpan: TimeInterval
    ) -> Bool {
        allowed(for: visibleSpan).contains(granularity)
    }

    /// The fewest bars a bucket width has to be able to draw before it stops
    /// being a series and becomes a couple of slabs.
    public static let minimumManualBuckets = 4

    /// Whether `granularity` still fills the visible span with enough bars to
    /// read as a shape.
    public static func drawsEnoughBuckets(
        _ granularity: CostChartGranularity,
        for visibleSpan: TimeInterval,
        minimum: Int = minimumManualBuckets
    ) -> Bool {
        guard minimum > 0 else { return true }
        let buckets = max(0, visibleSpan) / granularity.approximateBucketSeconds
        return buckets >= Double(minimum)
    }

    /// Whether a granularity the user picked by hand should survive a pan or a
    /// zoom: it has to still be offered at this span *and* still draw enough
    /// bars to be worth holding on to.
    ///
    /// `.day` is exempt from the bar floor. It is the one option the control
    /// always offers, and Auto resolves to it across the same middle spans, so
    /// dropping the user's pick there would trade a label for nothing.
    public static func survivesManualSelection(
        _ granularity: CostChartGranularity,
        for visibleSpan: TimeInterval
    ) -> Bool {
        guard isAllowed(granularity, for: visibleSpan) else { return false }
        guard granularity != .day else { return true }
        return drawsEnoughBuckets(granularity, for: visibleSpan)
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

/// One calendar month of cost history.
public struct MonthlyCostPoint: Sendable, Equatable, Identifiable {
    public let monthStart: Date
    public let costUSD: Double
    public let totalTokens: Int

    public var id: Date { monthStart }

    public init(monthStart: Date, costUSD: Double, totalTokens: Int) {
        self.monthStart = monthStart
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

    /// Sum daily points into calendar months, oldest first.
    ///
    /// Same contract as `weekly`: partial months at either end are real bars,
    /// not something to hide, and a December day lands in December rather than
    /// leaking into the next year's first bucket.
    public static func monthly(
        _ days: [DailyCostPoint],
        calendar: Calendar = .current
    ) -> [MonthlyCostPoint] {
        var totals: [Date: (cost: Double, tokens: Int)] = [:]
        for day in days {
            guard let start = monthStart(of: day.date, calendar: calendar) else { continue }
            var value = totals[start] ?? (0, 0)
            value.cost += day.costUSD
            value.tokens += day.totalTokens
            totals[start] = value
        }
        return totals
            .map { MonthlyCostPoint(monthStart: $0.key, costUSD: $0.value.cost, totalTokens: $0.value.tokens) }
            .sorted { $0.monthStart < $1.monthStart }
    }

    /// Midnight on the first day of the calendar month containing `date`.
    ///
    /// Taken from the calendar's own month interval rather than by subtracting
    /// days, so month lengths, leap years and the December→January rollover are
    /// the calendar's problem rather than this function's.
    public static func monthStart(of date: Date, calendar: Calendar = .current) -> Date? {
        calendar.dateInterval(of: .month, for: date)?.start
    }
}
