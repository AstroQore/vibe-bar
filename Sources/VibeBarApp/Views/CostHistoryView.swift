import SwiftUI
import Charts
import VibeBarCore

/// Cost history chart with selectable timeframe (Today / 7d / 30d / All).
/// Bars taller than the average get a warmer color; a dashed RuleMark shows
/// the daily average so anomalies are obvious at a glance.
///
/// Hovering / clicking a bar reveals that day's top models and totals — fed
/// from `CostSnapshot.dailyModelBreakdown`.
struct CostHistoryView: View {
    let tool: ToolType
    let snapshot: CostSnapshot?
    let density: Theme.Density
    /// Plot area height. Overview uses a taller value to roughly match the
    /// height of the left-column quota cards; provider detail tabs pass the
    /// default.
    var chartHeight: CGFloat = 130
    @State private var timeframe: CostTimeframe = .month
    @State private var hoveredDay: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: density.cardSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cost history")
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                Spacer()
                CostTimeframeSelector(selection: $timeframe, density: density)
                    .frame(width: 220)
            }
            chart
            HStack(spacing: 16) {
                metric(label: "Total", value: formatCost(filteredTotal))
                metric(label: "Avg/day", value: formatCost(average))
                metric(label: "Peak", value: formatCost(peak))
                Spacer()
                Text(timeframeNote)
                    .font(.system(size: density.resetCountdownFontSize))
                    .foregroundStyle(.tertiary)
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

    @ViewBuilder
    private var chart: some View {
        let points = filteredDays
        if points.isEmpty {
            VStack {
                Text("Building history…")
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.tertiary)
                Text("Cost samples accumulate as you use Codex/Claude CLI.")
                    .font(.system(size: density.resetCountdownFontSize))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else {
            Chart {
                ForEach(points) { day in
                    BarMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value("Cost", day.costUSD)
                    )
                    .foregroundStyle(barColor(for: day))
                    .cornerRadius(2)
                    .opacity(opacity(for: day))
                }
                if average > 0 {
                    RuleMark(y: .value("Avg", average))
                        .foregroundStyle(Color.accentColor.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                        .annotation(position: .top, alignment: .trailing, spacing: 3) {
                            Text("avg \(formatCost(average))")
                                .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(.primary.opacity(0.82))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.92))
                                )
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(.separator.opacity(0.35), lineWidth: 0.5)
                                )
                                .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
                        }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                    AxisValueLabel {
                        if let raw = value.as(Double.self) {
                            Text(formatAxisCost(raw))
                                .font(.system(size: 9, design: .rounded).monospacedDigit())
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: stride.calendarComponent, count: stride.count)) { value in
                    AxisValueLabel(format: stride.format)
                        .font(.system(size: 9))
                }
            }
            .chartOverlay { proxy in
                hoverOverlay(proxy: proxy, points: points)
            }
            .frame(height: chartHeight)
            // Tooltip is an overlay on top of the chart bars — no padding
            // reservation. It auto-clamps horizontally inside `tooltipX(...)`
            // and floats above the bar at the top of the chart area.
        }
    }

    /// Track the cursor X position and resolve it to the closest day so we can
    /// surface a tooltip with model breakdown.
    private func hoverOverlay(proxy: ChartProxy, points: [DailyCostPoint]) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            // proxy.plotFrame is the modern API but optional; fall back to 0
                            // when it isn't ready yet (first frame of layout).
                            let plotMinX = proxy.plotFrame.map { geo[$0].minX } ?? 0
                            if let date: Date = proxy.value(atX: location.x - plotMinX, as: Date.self) {
                                hoveredDay = nearestDay(to: date, in: points)
                            }
                        case .ended:
                            hoveredDay = nil
                        }
                    }
                if let day = hoveredDay,
                   let point = points.first(where: { Calendar.current.isDate($0.date, inSameDayAs: day) }) {
                    tooltipView(for: point)
                        .offset(x: tooltipX(for: point.date, proxy: proxy, geo: geo, in: points))
                }
            }
        }
    }

    @ViewBuilder
    private func tooltipView(for point: DailyCostPoint) -> some View {
        let models = snapshot?.topModels(for: point.date) ?? []
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(formatTooltipDate(point.date))
                    .font(.system(size: 10, weight: .semibold))
                Spacer(minLength: 8)
                Text(formatCost(point.costUSD))
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
            }
            Text(formatTokens(point.totalTokens))
                .font(.system(size: 9, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
            if !models.isEmpty {
                Divider().opacity(0.3)
                ForEach(models) { model in
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.modelName)
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(formatCost(model.costUSD))
                            .font(.system(size: 9, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.85))
        )
        .foregroundStyle(.white)
        .frame(width: tooltipWidth)
        .allowsHitTesting(false)
    }

    private let tooltipWidth: CGFloat = 180

    private func tooltipX(for date: Date, proxy: ChartProxy, geo: GeometryProxy, in points: [DailyCostPoint]) -> CGFloat {
        guard let xValue = proxy.position(forX: date) else { return 0 }
        let plotMinX = proxy.plotFrame.map { geo[$0].minX } ?? 0
        let centerX = plotMinX + xValue
        // Keep the tooltip on-screen even at the chart edges.
        let halfWidth = tooltipWidth / 2
        let clamped = min(max(centerX - halfWidth, 0), max(0, geo.size.width - tooltipWidth))
        return clamped
    }

    private func nearestDay(to date: Date, in points: [DailyCostPoint]) -> Date? {
        guard !points.isEmpty else { return nil }
        return points.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })?.date
    }

    private struct StrideSpec {
        let calendarComponent: Calendar.Component
        let count: Int
        let format: Date.FormatStyle
    }

    private var stride: StrideSpec {
        switch timeframe {
        case .today: return .init(calendarComponent: .hour, count: 4, format: .dateTime.hour())
        case .week:  return .init(calendarComponent: .day, count: 1, format: .dateTime.day().month(.abbreviated))
        case .month: return .init(calendarComponent: .day, count: 5, format: .dateTime.day().month(.abbreviated))
        case .all:   return .init(calendarComponent: .month, count: 1, format: .dateTime.month(.abbreviated).year(.twoDigits))
        }
    }

    private var filteredDays: [DailyCostPoint] {
        guard let history = snapshot?.dailyHistory else { return [] }
        let cutoff: Date?
        switch timeframe {
        case .today: cutoff = Calendar.current.startOfDay(for: Date())
        case .week:  cutoff = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date()))
        case .month: cutoff = Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: Date()))
        case .all:   cutoff = nil
        }
        guard let cutoff else { return history }
        return history.filter { $0.date >= cutoff }
    }

    private var filteredTotal: Double { filteredDays.reduce(0) { $0 + $1.costUSD } }
    private var average: Double {
        guard !filteredDays.isEmpty else { return 0 }
        return filteredTotal / Double(filteredDays.count)
    }
    private var peak: Double { filteredDays.map(\.costUSD).max() ?? 0 }

    private var timeframeNote: String {
        switch timeframe {
        case .today: return "1 day"
        case .week:  return "7 days"
        case .month: return "30 days"
        case .all:   return filteredDays.count == 0 ? "" : "\(filteredDays.count) days"
        }
    }

    @ViewBuilder
    private func metric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label.uppercased())
                .font(.system(size: max(8, density.subtitleFontSize - 2), weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.4)
            Text(value)
                .font(.system(size: density.bucketTitleFontSize, weight: .semibold, design: .rounded).monospacedDigit())
        }
    }

    private func formatCost(_ value: Double) -> String {
        if value < 0.01 { return "$0.00" }
        if value < 100 { return String(format: "$%.2f", value) }
        return String(format: "$%.0f", value)
    }
    private func formatAxisCost(_ value: Double) -> String {
        if value < 1 { return String(format: "$%.2f", value) }
        return String(format: "$%.0f", value)
    }
    private func formatTokens(_ tokens: Int) -> String {
        if tokens < 1_000 { return "\(tokens) tok" }
        if tokens < 1_000_000 { return String(format: "%.1fk tok", Double(tokens) / 1_000) }
        return String(format: "%.2fM tok", Double(tokens) / 1_000_000)
    }
    private func formatTooltipDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private func barColor(for day: DailyCostPoint) -> Color {
        if average > 0, day.costUSD > average * 1.5 {
            return Color(red: 0.97, green: 0.55, blue: 0.20)
        }
        return Color(red: 0.42, green: 0.60, blue: 0.97)
    }

    private func opacity(for day: DailyCostPoint) -> Double {
        guard let hovered = hoveredDay else { return 1.0 }
        return Calendar.current.isDate(day.date, inSameDayAs: hovered) ? 1.0 : 0.55
    }
}

private struct CostTimeframeSelector: View {
    @Binding var selection: CostTimeframe
    let density: Theme.Density

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CostTimeframe.allCases) { timeframe in
                Button {
                    selection = timeframe
                } label: {
                    Text(timeframe.shortLabel)
                        .font(.system(size: density.segmentedFontSize, weight: .semibold, design: .rounded))
                        .foregroundStyle(selection == timeframe ? .primary : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .background {
                    if selection == timeframe {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                            )
                    }
                }
                .accessibilityLabel(timeframe.label)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
    }
}
