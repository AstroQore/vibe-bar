import SwiftUI
import VibeBarCore

/// GitHub-style 365-day contribution heatmap. Columns are calendar weeks
/// (Sunday-anchored), rows are weekdays, cells colored by daily cost.
///
/// Designed to be a "shape of the year" overview — the user sees vacation
/// gaps, busy crunch weeks, and seasonal patterns at a glance. Not interactive
/// beyond per-cell tooltips; for chart-style hovering, see `CostHistoryView`.
struct YearlyContributionHeatmapView: View {
    let history: [DailyCostPoint]
    let density: Theme.Density
    let toolName: String

    private var cellSpacing: CGFloat {
        switch density.profile {
        case .compact: 1.5
        case .regular: 2
        case .spacious: 2.5
        }
    }
    private var weekdayLabels: [String] { AppLocale.shortWeekdaySymbols }
    @State private var measuredGridWidth: CGFloat = 0
    @EnvironmentObject var environment: AppEnvironment

    /// The 365-day walk, the month markers, the quartile thresholds and the
    /// header total rebuilt only when the history (or the day) changes — not
    /// on every redraw of the card. A reference box on purpose: filling it
    /// during `body` must not dirty view state.
    private final class GridCache {
        var historyStamp: GridStamp?
        var columns: [WeekColumn] = []
        var markers: [MonthMarker] = []
        var thresholds: (p25: Double, p50: Double, p75: Double) = (0, 0, 0)
        /// The *number*, not the sentence. "{amount} total" is a rendering of
        /// this and is derived at draw time, so a language change needs no
        /// cache entry of its own.
        var total: Double?
    }

    private struct GridStamp: Equatable {
        let history: [DailyCostPoint]
        let today: Date
        /// The walk groups by `Calendar.current`; a calendar or zone change
        /// mid-flight must invalidate even when today's start looks equal.
        let calendarIdentity: String
        /// The month markers are localized month *names*, so the language is
        /// part of what makes this cache entry valid — for exactly the same
        /// reason the calendar identity is.
        let language: LanguageStamp
    }

    @State private var gridCache = GridCache()

    private typealias CachedGrid = (
        columns: [WeekColumn],
        markers: [MonthMarker],
        thresholds: (p25: Double, p50: Double, p75: Double),
        total: Double?
    )

    private func cachedGrid() -> CachedGrid {
        let stamp = GridStamp(
            history: history,
            today: Calendar.current.startOfDay(for: Date()),
            calendarIdentity: "\(Calendar.current.identifier)|\(TimeZone.current.identifier)",
            language: .current
        )
        if gridCache.historyStamp == stamp {
            return (gridCache.columns, gridCache.markers, gridCache.thresholds, gridCache.total)
        }
        let columns = makeColumns()
        let markers = monthLabelPositions(columns: columns)
        let levels = thresholds
        let total = totalSpend
        gridCache.historyStamp = stamp
        gridCache.columns = columns
        gridCache.markers = markers
        gridCache.thresholds = levels
        gridCache.total = total
        return (columns, markers, levels, total)
    }

    var body: some View {
        // Everything derived from the year of history — the week walk, the
        // month markers, the quartile sort behind `thresholds`, and the
        // header total — is memoized on the history generation, so a redraw
        // of the card (hover, resize, refresh tick) costs a stamp compare.
        let (columns, cachedMonthMarkers, cachedThresholds, cachedTotal) = cachedGrid()
        let metrics = gridMetrics(columnCount: columns.count, measuredWidth: measuredGridWidth)

        VStack(alignment: .leading, spacing: density.cardSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.Usage.yearHeatmapTitle(provider: toolName))
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                Spacer()
                if let total = totalLabel(cachedTotal) {
                    Text(total)
                        .font(.system(size: density.subtitleFontSize))
                        .foregroundStyle(.secondary)
                }
                SectionRefreshButton(isRefreshing: false) {
                    environment.refreshCostUsage()
                }
                .padding(.leading, 4)
            }
            GeometryReader { proxy in
                let liveMetrics = gridMetrics(columnCount: columns.count, measuredWidth: proxy.size.width)
                grid(columns: columns, metrics: liveMetrics, thresholds: cachedThresholds, monthMarkers: cachedMonthMarkers)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .preference(key: YearlyGridWidthPreferenceKey.self, value: proxy.size.width)
            }
            .frame(height: gridHeight(for: metrics))
            .onPreferenceChange(YearlyGridWidthPreferenceKey.self) { width in
                if abs(width - measuredGridWidth) > 0.5 {
                    measuredGridWidth = width
                }
            }
            HStack(spacing: 6) {
                Text(L10n.Usage.yearHeatmapLess)
                    .font(.system(size: density.resetCountdownFontSize))
                    .foregroundStyle(.tertiary)
                ForEach(0..<5, id: \.self) { step in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(yearlyLevelColor(step))
                        .frame(width: metrics.cellSize, height: metrics.cellSize)
                }
                Text(L10n.Usage.yearHeatmapMore)
                    .font(.system(size: density.resetCountdownFontSize))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(density.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .fill(.background.tertiary.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .stroke(.separator.opacity(0.4), lineWidth: 0.5)
        )
    }

    private func gridHeight(for metrics: YearlyGridMetrics) -> CGFloat {
        // Month label row + the VStack spacing under it + the cell block.
        12 + cellSpacing + metrics.cellsHeight
    }

    private func grid(
        columns: [WeekColumn],
        metrics: YearlyGridMetrics,
        thresholds: (p25: Double, p50: Double, p75: Double),
        monthMarkers: [MonthMarker]
    ) -> some View {
        return VStack(alignment: .leading, spacing: cellSpacing) {
            // Month label row, aligned to the column where each month's first
            // visible day falls.
            HStack(alignment: .center, spacing: 0) {
                Text("")
                    .frame(width: metrics.labelWidth, alignment: .trailing)
                    .padding(.trailing, metrics.labelGap)
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: metrics.gridWidth, height: 12)
                    ForEach(monthMarkers, id: \.column) { marker in
                        Text(marker.label)
                            .font(.system(size: max(7, density.resetCountdownFontSize - 2), design: .rounded))
                            .foregroundStyle(.tertiary)
                            .offset(x: CGFloat(marker.column) * (metrics.cellSize + metrics.cellSpacing))
                    }
                }
            }
            // 7 weekday rows × N week columns
            HStack(alignment: .top, spacing: metrics.labelGap) {
                VStack(alignment: .trailing, spacing: cellSpacing) {
                    // Show every other weekday label for compactness
                    ForEach(0..<7, id: \.self) { weekday in
                        Group {
                            if weekday % 2 == 1 {
                                Text(weekdayLabels[weekday])
                                    .font(.system(size: max(7, density.resetCountdownFontSize - 2), design: .rounded))
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text(" ")
                                    .font(.system(size: max(7, density.resetCountdownFontSize - 2)))
                            }
                        }
                        .frame(width: metrics.labelWidth, height: metrics.cellSize)
                    }
                }
                YearlyHeatmapCanvas(
                    columns: columns,
                    metrics: metrics,
                    thresholds: thresholds,
                    accessibilityLabel: L10n.Usage.yearHeatmapA11y(
                        provider: toolName, count: columns.count
                    )
                )
            }
        }
    }

    private func gridMetrics(columnCount: Int, measuredWidth: CGFloat) -> YearlyGridMetrics {
        let labelWidth: CGFloat = 28
        let labelGap: CGFloat = 4
        let fallbackWidth = density.detailRightColumnMinimum
        let availableWidth = measuredWidth > 1 ? measuredWidth : fallbackWidth
        let interCellSpacing = CGFloat(max(0, columnCount - 1)) * cellSpacing
        let usableWidth = max(0, availableWidth - labelWidth - labelGap - interCellSpacing)
        let rawSide = usableWidth / CGFloat(max(1, columnCount))
        let cellBounds: ClosedRange<CGFloat>
        switch density.profile {
        case .compact: cellBounds = 4...11
        case .regular: cellBounds = 5...13
        case .spacious: cellBounds = 6...15
        }
        let cellSize = min(max(rawSide, cellBounds.lowerBound), cellBounds.upperBound)
        return YearlyGridMetrics(
            labelWidth: labelWidth,
            labelGap: labelGap,
            cellSize: cellSize,
            cellSpacing: cellSpacing,
            columnCount: columnCount
        )
    }

    // Built per language rather than once per process: a formatter
    // parked in a `static let` keeps the language it was created in.
    private static var monthLabelFormatter: DateFormatter {
        AppLocale.dateFormatter(template: "MMM")
    }

    private func makeColumns() -> [WeekColumn] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // Sunday-anchored week start (calendar.firstWeekday = 1 by default, Sun)
        let cutoff = calendar.date(byAdding: .day, value: -364, to: today) ?? today
        let firstWeekday = calendar.weekday(for: cutoff)
        let firstWeekStart = calendar.date(byAdding: .day, value: -(firstWeekday - 1), to: cutoff) ?? cutoff

        var historyByDay: [Date: DailyCostPoint] = [:]
        for point in history {
            historyByDay[calendar.startOfDay(for: point.date)] = point
        }

        var columns: [WeekColumn] = []
        var weekStart = firstWeekStart
        while weekStart <= today {
            var days: [DailyCostPoint?] = []
            for offset in 0..<7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: weekStart) else {
                    days.append(nil); continue
                }
                if day < cutoff || day > today {
                    days.append(nil)
                } else {
                    days.append(historyByDay[day])
                }
            }
            columns.append(WeekColumn(weekStart: weekStart, days: days))
            guard let next = calendar.date(byAdding: .day, value: 7, to: weekStart) else { break }
            weekStart = next
        }
        return columns
    }

    /// Pick column indexes where the month label changes — rendered as a
    /// header row above the grid.
    private struct MonthMarker {
        let column: Int
        let label: String
    }

    private func monthLabelPositions(columns: [WeekColumn]) -> [MonthMarker] {
        let calendar = Calendar.current
        var markers: [MonthMarker] = []
        var lastMonth: Int = -1
        for (idx, column) in columns.enumerated() {
            let month = calendar.component(.month, from: column.weekStart)
            if month != lastMonth {
                markers.append(MonthMarker(
                    column: idx,
                    label: Self.monthLabelFormatter.string(from: column.weekStart)
                ))
                lastMonth = month
            }
        }
        return markers
    }

    /// The figure behind the header caption. Data, so it is what the grid
    /// cache holds.
    private var totalSpend: Double? {
        let total = history.reduce(0) { $0 + $1.costUSD }
        return total > 0 ? total : nil
    }

    /// The caption itself, derived from the cached figure at draw time — the
    /// sentence is a rendering of the number, not another thing to cache.
    private func totalLabel(_ total: Double?) -> String? {
        guard let total else { return nil }
        let amount = total < 100
            ? String(format: "$%.2f", total)
            : String(format: "$%.0f", total)
        return L10n.Usage.yearHeatmapTotal(amount: amount)
    }

    /// Per-tool quartile thresholds computed from the history's non-zero days.
    /// Mirroring GitHub: split active days into 4 levels using the 25/50/75
    /// percentile of the user's own data, so light-usage tools and heavy-usage
    /// tools both light up the grid the same amount.
    private var thresholds: (p25: Double, p50: Double, p75: Double) {
        let nonZero = history.map(\.costUSD).filter { $0 > 0 }.sorted()
        guard !nonZero.isEmpty else { return (0, 0, 0) }
        return (
            p25: percentile(nonZero, 0.25),
            p50: percentile(nonZero, 0.50),
            p75: percentile(nonZero, 0.75)
        )
    }

    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = max(0, min(sorted.count - 1, Int(Double(sorted.count - 1) * p)))
        return sorted[idx]
    }
}

/// One week of the yearly grid: exactly 7 slots, indexed by weekday. At file
/// scope so the canvas that draws it can read it too.
private struct WeekColumn {
    let weekStart: Date
    let days: [DailyCostPoint?]   // exactly 7, indexed by weekday
}

/// The ~365 cells drawn as one `Canvas` instead of one `RoundedRectangle` per
/// cell with a `.help()` each. Three of these cards are alive while the
/// popover is open, so the view-per-cell shape cost roughly 1 100 view nodes
/// and as many tooltip nodes just to sit idle. Hit-testing the hover point
/// against the same geometry the canvas draws with reproduces the per-cell
/// tooltip from a single string, and keeping the hover state in this leaf
/// means a mouse move redraws the grid, not the whole card.
private struct YearlyHeatmapCanvas: View {
    let columns: [WeekColumn]
    let metrics: YearlyGridMetrics
    let thresholds: (p25: Double, p50: Double, p75: Double)
    let accessibilityLabel: String

    @State private var hoveredTooltip: String?

    var body: some View {
        Canvas { context, _ in
            let step = metrics.cellSize + metrics.cellSpacing
            for (columnIndex, column) in columns.enumerated() {
                let x = CGFloat(columnIndex) * step
                for weekday in 0..<7 {
                    let value = column.days[weekday]?.costUSD ?? 0
                    let rect = CGRect(
                        x: x,
                        y: CGFloat(weekday) * step,
                        width: metrics.cellSize,
                        height: metrics.cellSize
                    )
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: metrics.cellCornerRadius, style: .continuous),
                        with: .color(yearlyLevelColor(yearlyLevel(for: value, thresholds: thresholds)))
                    )
                }
            }
        }
        .frame(width: metrics.gridWidth, height: metrics.cellsHeight)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                let text = tooltip(at: location)
                if text != hoveredTooltip { hoveredTooltip = text }
            case .ended:
                if hoveredTooltip != nil { hoveredTooltip = nil }
            }
        }
        .help(hoveredTooltip ?? "")
        // The individual cell views are gone, so the grid speaks for itself.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func tooltip(at point: CGPoint) -> String? {
        guard let column = heatmapCellIndex(
            for: point.x,
            side: metrics.cellSize,
            spacing: metrics.cellSpacing,
            count: columns.count
        ), let weekday = heatmapCellIndex(
            for: point.y,
            side: metrics.cellSize,
            spacing: metrics.cellSpacing,
            count: 7
        ), let entry = columns[column].days[weekday] else { return nil }
        return yearlyCellTooltip(for: entry)
    }
}

// Memoized on purpose: the tooltip formatter used to be rebuilt per cell —
// ~365 times per body pass — and a fresh `DateFormatter` per call is
// milliseconds of pure allocation on every redraw of the card. `AppLocale`
// keeps that property while keying the cache on the app's language, so a
// language change rebuilds it instead of leaving an English month name in
// a Chinese tooltip. Its formatters use `.autoupdatingCurrent` for the time
// zone, so a system change is still followed.
private var yearlyTooltipFormatter: DateFormatter {
    AppLocale.dateFormatter(template: "MMMdyyyy")
}

private func yearlyCellTooltip(for entry: DailyCostPoint) -> String {
    let cost: String = entry.costUSD < 0.01 ? "$0.00"
        : entry.costUSD < 100 ? String(format: "$%.2f", entry.costUSD)
        : String(format: "$%.0f", entry.costUSD)
    return L10n.Usage.yearHeatmapTooltip(
        date: yearlyTooltipFormatter.string(from: entry.date), amount: cost
    )
}

/// Discrete level 0…4. 0 = no usage, 1…4 increase in saturation.
/// Picking levels by quartile means the grid always feels populated even
/// for users with little history (no faint pale-blue washout).
private func yearlyLevel(for value: Double, thresholds t: (p25: Double, p50: Double, p75: Double)) -> Int {
    guard value > 0 else { return 0 }
    if t.p75 == 0 { return 1 }                 // only one active day
    if value > t.p75 { return 4 }
    if value > t.p50 { return 3 }
    if value > t.p25 { return 2 }
    return 1
}

private func yearlyLevelColor(_ level: Int) -> Color {
    // GitHub-style palette in cool→warm. Saturation/opacity steps are
    // chosen so each level is visibly distinct on both light and dark
    // backgrounds.
    switch level {
    case 0: return Color.primary.opacity(0.06)
    case 1: return Color(red: 0.42, green: 0.60, blue: 0.97).opacity(0.55)
    case 2: return Color(red: 0.42, green: 0.60, blue: 0.97).opacity(0.85)
    case 3: return Color(red: 0.97, green: 0.65, blue: 0.30).opacity(0.85)
    default: return Color(red: 0.97, green: 0.45, blue: 0.18)
    }
}

private struct YearlyGridMetrics {
    let labelWidth: CGFloat
    let labelGap: CGFloat
    let cellSize: CGFloat
    let cellSpacing: CGFloat
    let columnCount: Int

    var gridWidth: CGFloat {
        CGFloat(columnCount) * cellSize + CGFloat(max(0, columnCount - 1)) * cellSpacing
    }

    /// Height of the 7-row cell block — what the per-column `VStack`s used to
    /// measure to on their own.
    var cellsHeight: CGFloat {
        7 * cellSize + 6 * cellSpacing
    }

    var cellCornerRadius: CGFloat {
        min(2, max(1.2, cellSize * 0.18))
    }
}

private struct YearlyGridWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension Calendar {
    /// 1 = Sunday … 7 = Saturday — same as `component(.weekday, from:)` but
    /// with a more telling name at the call site.
    func weekday(for date: Date) -> Int {
        component(.weekday, from: date)
    }
}
