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

    private let cellSpacing: CGFloat = 2
    private let weekdayLabels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    @State private var measuredGridWidth: CGFloat = 0
    @EnvironmentObject var environment: AppEnvironment

    var body: some View {
        // Compute these ONCE per body. `thresholds` does a sort on the year's
        // non-zero days, and `cell(...)` is invoked ~365 times — without
        // hoisting, we'd re-sort the entire history per cell on every redraw.
        let columns = makeColumns()
        let metrics = gridMetrics(columnCount: columns.count, measuredWidth: measuredGridWidth)
        let cachedThresholds = thresholds
        let cachedMonthMarkers = monthLabelPositions(columns: columns)

        VStack(alignment: .leading, spacing: density.cardSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(toolName) — Past Year")
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                Spacer()
                if let total = totalLabel {
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
                Text("Less")
                    .font(.system(size: density.resetCountdownFontSize))
                    .foregroundStyle(.tertiary)
                ForEach(0..<5, id: \.self) { step in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(color(forLevel: step))
                        .frame(width: metrics.cellSize, height: metrics.cellSize)
                }
                Text("More")
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
        12 + cellSpacing + 7 * metrics.cellSize + 6 * cellSpacing
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
                            .font(.system(size: 8, design: .rounded))
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
                                    .font(.system(size: 8, design: .rounded))
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text(" ")
                                    .font(.system(size: 8))
                            }
                        }
                        .frame(width: metrics.labelWidth, height: metrics.cellSize)
                    }
                }
                HStack(alignment: .top, spacing: metrics.cellSpacing) {
                    ForEach(columns.indices, id: \.self) { columnIndex in
                        VStack(spacing: metrics.cellSpacing) {
                            ForEach(0..<7, id: \.self) { weekday in
                                cell(at: weekday, columnEntry: columns[columnIndex], metrics: metrics, thresholds: thresholds)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(at weekday: Int, columnEntry: WeekColumn, metrics: YearlyGridMetrics, thresholds: (p25: Double, p50: Double, p75: Double)) -> some View {
        let entry = columnEntry.days[weekday]
        let value = entry?.costUSD ?? 0
        let level = Self.level(for: value, thresholds: thresholds)
        RoundedRectangle(cornerRadius: metrics.cellCornerRadius, style: .continuous)
            .fill(color(forLevel: level))
            .frame(width: metrics.cellSize, height: metrics.cellSize)
            .help(tooltip(for: entry))
    }

    private func gridMetrics(columnCount: Int, measuredWidth: CGFloat) -> YearlyGridMetrics {
        let labelWidth: CGFloat = 28
        let labelGap: CGFloat = 4
        let fallbackWidth: CGFloat = 560
        let availableWidth = measuredWidth > 1 ? measuredWidth : fallbackWidth
        let interCellSpacing = CGFloat(max(0, columnCount - 1)) * cellSpacing
        let usableWidth = max(0, availableWidth - labelWidth - labelGap - interCellSpacing)
        let rawSide = usableWidth / CGFloat(max(1, columnCount))
        let cellSize = min(max(rawSide, 5), 13)
        return YearlyGridMetrics(
            labelWidth: labelWidth,
            labelGap: labelGap,
            cellSize: cellSize,
            cellSpacing: cellSpacing,
            columnCount: columnCount
        )
    }

    private func tooltip(for entry: DailyCostPoint?) -> String {
        guard let entry else { return "" }
        let date = entry.date
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let cost: String = entry.costUSD < 0.01 ? "$0.00"
            : entry.costUSD < 100 ? String(format: "$%.2f", entry.costUSD)
            : String(format: "$%.0f", entry.costUSD)
        return "\(formatter.string(from: date)) · \(cost)"
    }

    /// Build week columns for the past 365 days, anchored to the most recent
    /// Sunday so the grid always ends with the current week aligned right.
    private struct WeekColumn {
        let weekStart: Date
        let days: [DailyCostPoint?]   // exactly 7, indexed by weekday
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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM"
        for (idx, column) in columns.enumerated() {
            let month = calendar.component(.month, from: column.weekStart)
            if month != lastMonth {
                markers.append(MonthMarker(column: idx, label: formatter.string(from: column.weekStart)))
                lastMonth = month
            }
        }
        return markers
    }

    private var totalLabel: String? {
        let total = history.reduce(0) { $0 + $1.costUSD }
        guard total > 0 else { return nil }
        if total < 100 { return String(format: "$%.2f total", total) }
        return String(format: "$%.0f total", total)
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

    /// Discrete level 0…4. 0 = no usage, 1…4 increase in saturation.
    /// Picking levels by quartile means the grid always feels populated even
    /// for users with little history (no faint pale-blue washout).
    private static func level(for value: Double, thresholds t: (p25: Double, p50: Double, p75: Double)) -> Int {
        guard value > 0 else { return 0 }
        if t.p75 == 0 { return 1 }                 // only one active day
        if value > t.p75 { return 4 }
        if value > t.p50 { return 3 }
        if value > t.p25 { return 2 }
        return 1
    }

    private func color(forLevel level: Int) -> Color {
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
