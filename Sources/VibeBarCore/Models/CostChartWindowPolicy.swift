import Foundation

/// Date math the navigable cost chart shares between drawing, totalling and
/// preset highlighting.
///
/// Kept out of the view because all three have to agree: a preset that lands
/// one hour off a day boundary makes the footer count a bar the user cannot
/// see, and makes the pill that produced the range stop lighting up.
public enum CostChartWindowPolicy {
    private static let dayInterval: TimeInterval = 86_400

    /// Does a bucket starting at `start` and `width` seconds wide occupy any
    /// visible time inside `range`?
    ///
    /// Both edges are exclusive. A bucket that *ends* exactly where the window
    /// begins — or begins exactly where it ends — covers zero visible seconds,
    /// and counting it puts a 31st daily bar into a midnight-aligned 30-day
    /// total. A bucket that genuinely straddles an edge is still included, and
    /// deliberately kept whole by the caller.
    public static func bucketOverlaps(
        start: Date,
        width: TimeInterval,
        range: ClosedRange<Date>
    ) -> Bool {
        start < range.upperBound
            && start.addingTimeInterval(max(0, width)) > range.lowerBound
    }

    /// Span of the `days` calendar days ending at the end of `now`'s day — the
    /// span the Today / 7d / 30d presets jump to.
    ///
    /// Subtracting fixed 86 400-second multiples drifts by an hour across a
    /// DST change, which is enough to slide the visible range off the day
    /// boundary the bars sit on. The presets anchor at the domain's newest
    /// edge, which `CostHistoryView` sets to the end of today, so a span
    /// measured back from the same instant lands exactly on a midnight.
    public static func anchoredSpan(
        days: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TimeInterval {
        let count = max(1, days)
        let today = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: today),
              let start = calendar.date(byAdding: .day, value: -count, to: end)
        else { return TimeInterval(count) * dayInterval }
        return end.timeIntervalSince(start)
    }

    /// Calendar bounds of the Yesterday preset — the one preset not anchored
    /// at the newest edge.
    public static func yesterdayBounds(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -1, to: today)
            ?? today.addingTimeInterval(-dayInterval)
        return (start, today)
    }

    /// Whole-day stretch the hourly cost lane retains, from the oldest and
    /// newest hourly buckets on hand.
    ///
    /// The scanner keeps per-hour buckets for yesterday and today only. Inside
    /// a retained day an hour with no bucket means nothing was spent, not that
    /// evidence is missing — so coverage is reported as whole days rather than
    /// as the extent of the points themselves. Otherwise Today would read as
    /// "not covered" for every hour after the last one that saw usage.
    public static func hourlyCoverage(
        firstHour: Date?,
        lastHour: Date?,
        calendar: Calendar = .current
    ) -> ClosedRange<Date>? {
        guard let firstHour, let lastHour, lastHour >= firstHour else { return nil }
        let start = calendar.startOfDay(for: firstHour)
        let lastDay = calendar.startOfDay(for: lastHour)
        guard let end = calendar.date(byAdding: .day, value: 1, to: lastDay),
              end > start
        else { return nil }
        return start...end
    }

    /// Does `coverage` span the whole of `range`?
    ///
    /// Hour granularity needs hourly evidence everywhere it draws. A window
    /// that merely *overlaps* the retained days would draw and total only its
    /// covered part, with the uncovered days silently reading as zero.
    public static func covers(_ coverage: ClosedRange<Date>?, range: ClosedRange<Date>) -> Bool {
        guard let coverage else { return false }
        return coverage.lowerBound <= range.lowerBound
            && coverage.upperBound >= range.upperBound
    }
}
