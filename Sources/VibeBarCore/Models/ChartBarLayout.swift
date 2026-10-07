import Foundation

/// Bar sizing and axis-label spacing for time-bucketed bar charts.
///
/// A bar's width is a share of its *slot* — the plot width divided by how
/// many buckets the visible window spans — so the same rule fills a 7-bar
/// week and a 168-bar week alike, and follows the brush as it zooms. Pure
/// arithmetic so a chart resolves it once per (data, window, width) change
/// rather than per render, and so the policy is testable without a view.
public enum ChartBarLayout {
    /// Widest a bar may get. Past this a sparse chart stops reading as bars
    /// and starts reading as a wall of colour.
    public static let defaultMaximumWidth: Double = 44
    /// Thinner than this and a bar disappears into the background.
    public static let minimumWidth: Double = 1
    /// Narrowest gap left between neighbours, so dense bars stay separate.
    public static let minimumGap: Double = 1

    /// Share of the slot a bar fills once slots are roomy.
    static let sparseFill: Double = 0.7
    /// Share of the slot a bar fills once slots are tight: a dense chart
    /// wants columns that nearly touch, not hairlines with gaps between.
    static let denseFill: Double = 0.85
    /// Slot widths between which the fill eases from dense to sparse.
    static let denseSlotWidth: Double = 12
    static let sparseSlotWidth: Double = 36

    /// The horizontal room one bucket gets: plot width over the number of
    /// buckets the visible span holds. Counting from the span rather than
    /// the number of data points keeps the pitch right when buckets are
    /// missing or the window cuts a bucket in half.
    public static func slotWidth(plotWidth: Double, slotCount: Double) -> Double {
        guard plotWidth > 0, slotCount.isFinite else { return 0 }
        return plotWidth / max(1, slotCount)
    }

    /// The share of the slot a bar fills, eased between `denseFill` and
    /// `sparseFill` so the width never jumps as a window is resized.
    static func fill(forSlotWidth slot: Double) -> Double {
        if slot <= denseSlotWidth { return denseFill }
        if slot >= sparseSlotWidth { return sparseFill }
        let progress = (slot - denseSlotWidth) / (sparseSlotWidth - denseSlotWidth)
        return denseFill + (sparseFill - denseFill) * progress
    }

    /// Width for each bar in a plot `plotWidth` points wide whose visible
    /// window spans `slotCount` buckets.
    public static func barWidth(
        plotWidth: Double,
        slotCount: Double,
        maximumWidth: Double = defaultMaximumWidth
    ) -> Double {
        let slot = slotWidth(plotWidth: plotWidth, slotCount: slotCount)
        guard slot > 0 else { return minimumWidth }
        let gap = max(minimumGap, slot * (1 - fill(forSlotWidth: slot)))
        return min(max(minimumWidth, maximumWidth), max(minimumWidth, slot - gap))
    }

    /// How many buckets apart axis labels sit so neighbours are at least
    /// `minimumLabelSpacing` points apart. Picks the first of `steps`
    /// (calendar-friendly strides such as 6 hours or 7 days) that clears the
    /// spacing; past the last step, the smallest multiple of it that does.
    public static func labelStride(
        slotWidth: Double,
        minimumLabelSpacing: Double,
        steps: [Int]
    ) -> Int {
        guard slotWidth > 0, minimumLabelSpacing > 0 else { return 1 }
        let needed = Int((minimumLabelSpacing / slotWidth).rounded(.up))
        guard needed > 1 else { return 1 }
        let ordered = steps.filter { $0 > 0 }.sorted()
        if let step = ordered.first(where: { $0 >= needed }) { return step }
        guard let largest = ordered.last else { return needed }
        return Int((Double(needed) / Double(largest)).rounded(.up)) * largest
    }
}

extension UsageTrendBucket {
    /// Calendar-friendly label strides, in buckets: hours land on quarter
    /// and half days, days on weeks, weeks on months and quarters.
    public var axisLabelSteps: [Int] {
        switch self {
        case .hour: [1, 2, 3, 6, 12, 24, 48, 168]
        case .sixHours: [1, 2, 4, 8, 12, 28]
        case .day: [1, 2, 3, 7, 14, 28]
        case .week: [1, 2, 4, 13, 26, 52]
        }
    }

    /// Points to leave between axis-label centres. A six-hour label carries
    /// the date as well as the hour, so it needs more room.
    public var minimumAxisLabelSpacing: Double {
        switch self {
        case .sixHours: 96
        case .hour, .day, .week: 60
        }
    }
}
