import Charts
import SwiftUI
import VibeBarCore

/// The four token components a request is billed on.
///
/// Their hues are deliberately *not* provider accents: a stacked band here
/// means "cache read", not "Claude", and reusing the brand palette would make
/// the two readings fight. Four widely separated semantic-ish hues instead,
/// kept in one table so the legend, the bands, and the tooltip agree.
enum UsageTokenSeries: String, CaseIterable, Identifiable, Hashable {
    case freshInput
    case output
    case cacheCreation
    case cacheRead

    var id: String { rawValue }

    var title: String {
        switch self {
        case .freshInput:    "Input"
        case .output:        "Output"
        case .cacheCreation: "Cache write"
        case .cacheRead:     "Cache read"
        }
    }

    var color: Color {
        switch self {
        case .freshInput:    Color(red: 0.33, green: 0.55, blue: 0.95)  // blue
        case .output:        Color(red: 0.20, green: 0.72, blue: 0.58)  // green
        case .cacheCreation: Color(red: 0.96, green: 0.66, blue: 0.22)  // amber
        case .cacheRead:     Color(red: 0.62, green: 0.45, blue: 0.93)  // violet
        }
    }

    var gradient: LinearGradient {
        LinearGradient(
            colors: [color.opacity(0.72), color.opacity(0.20)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    func value(in point: UsageTrendPoint) -> Int64 {
        switch self {
        case .freshInput:    point.freshInput
        case .output:        point.output
        case .cacheCreation: point.cacheCreation
        case .cacheRead:     point.cacheRead
        }
    }
}

private enum UsageChartMetric: String, CaseIterable, Identifiable {
    case tokens
    case cost

    var id: String { rawValue }
    var title: String { self == .tokens ? "Tokens" : "Cost" }
    var systemImage: String { self == .tokens ? "sum" : "dollarsign" }
}

/// Tokens or cost over the selected range in one deliberate chart surface.
/// The metric switch mirrors the established cost-history interaction instead
/// of stacking two unrelated plots and asking the user to read both at once.
///
/// The range is drawn whole: no brush strip, no pan/zoom. `ChartTimeWindow`
/// and `ChartBrushNavigator` earn their keep on the cost history card, whose
/// domain is "everything Vibe Bar ever recorded"; here the domain *is* the
/// filter, and the filter bar is already the navigation.
struct UsageTrendChartView: View {
    let density: Theme.Density
    let series: UsageTrendSeries

    @State private var metric: UsageChartMetric = .tokens
    @State private var hiddenSeries: Set<UsageTokenSeries> = []
    @State private var hoveredDate: Date?

    /// Floor for the leading axis-label column on both panes. Without a shared
    /// floor the token pane ("3.40M") and the cost pane ("$12") inset their
    /// plots differently and the two x axes stop lining up.
    private static let axisLabelWidth: CGFloat = 46
    private static let tooltipWidth: CGFloat = 186

    private var visibleSeries: [UsageTokenSeries] {
        UsageTokenSeries.allCases.filter { !hiddenSeries.contains($0) }
    }

    private var hasData: Bool {
        series.points.contains { $0.totalTokens > 0 || $0.costMicros != 0 }
    }

    private var domain: ClosedRange<Date> {
        guard let first = series.points.first?.bucketStart,
              let last = series.points.last?.bucketStart
        else {
            let now = Date()
            return now.addingTimeInterval(-3_600)...now
        }
        return first...max(last, first.addingTimeInterval(1))
    }

    private var hoveredPoint: UsageTrendPoint? {
        guard let hoveredDate else { return nil }
        return series.points.first { $0.bucketStart == hoveredDate }
    }

    var body: some View {
        CardShell(density: density, spacing: density.cardSpacing) {
            header
            if hasData {
                if metric == .tokens { tokenPane } else { costPane }
            } else {
                emptyState
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("USAGE OVER TIME")
                    .font(.system(size: max(8, density.subtitleFontSize - 2), weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.4)
                Text(series.bucket == .hour ? "Hourly buckets" : "Local calendar days")
                    .font(.system(size: max(9, density.resetCountdownFontSize - 1)))
                    .foregroundStyle(.secondary)
            }
            metricSelector
            Spacer(minLength: 8)
            if metric == .tokens { legend }
        }
    }

    private var metricSelector: some View {
        HStack(spacing: 2) {
            ForEach(UsageChartMetric.allCases) { value in
                let selected = metric == value
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { metric = value }
                } label: {
                    Label(value.title, systemImage: value.systemImage)
                        .font(.system(size: max(9, density.segmentedFontSize - 1), weight: .semibold))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 9)
                        .frame(minHeight: 24)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(selected ? Color.accentColor.opacity(0.38) : Color.clear, lineWidth: 0.7)
                )
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.6)
        )
    }

    private var legend: some View {
        HStack(spacing: 6) {
            ForEach(UsageTokenSeries.allCases) { kind in
                let visible = !hiddenSeries.contains(kind)
                Button {
                    toggle(kind)
                } label: {
                    HStack(spacing: 4) {
                        Capsule()
                            .fill(kind.color)
                            .frame(width: 10, height: 4)
                        Text(kind.title)
                            .font(.system(size: max(8, density.segmentedFontSize - 2), weight: .semibold))
                    }
                    .padding(.horizontal, 7)
                    .frame(minHeight: 20)
                }
                .buttonStyle(.plain)
                .background(
                    Capsule().fill(kind.color.opacity(visible ? 0.14 : 0.04))
                )
                .opacity(visible ? 1 : 0.42)
                .saturation(visible ? 1 : 0.15)
                .help(visible ? "Hide \(kind.title)" : "Show \(kind.title)")
                .accessibilityAddTraits(visible ? [.isSelected] : [])
            }
        }
    }

    private func toggle(_ kind: UsageTokenSeries) {
        if hiddenSeries.contains(kind) {
            hiddenSeries.remove(kind)
        } else if hiddenSeries.count < UsageTokenSeries.allCases.count - 1 {
            // Never let the last band go: an empty token pane reads as "no
            // data" rather than as "you turned everything off".
            hiddenSeries.insert(kind)
        }
    }

    // MARK: - Panes

    private var tokenPane: some View {
        Chart {
            ForEach(visibleSeries) { kind in
                ForEach(series.points, id: \.bucketStart) { point in
                    AreaMark(
                        x: .value("Time", point.bucketStart),
                        y: .value("Tokens", kind.value(in: point)),
                        series: .value("Series", kind.title),
                        stacking: .standard
                    )
                    .foregroundStyle(kind.gradient)
                }
            }
            if let hoveredDate {
                RuleMark(x: .value("Time", hoveredDate))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: domain)
        .chartPlotStyle { $0.clipped() }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text(UsageFormatting.compactTokens(Int64(raw)))
                            .font(.system(size: 9, design: .rounded).monospacedDigit())
                            .frame(minWidth: Self.axisLabelWidth, alignment: .trailing)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.10))
            }
        }
        .chartOverlay { proxy in
            hoverSurface(proxy: proxy) { geometry in
                if let point = hoveredPoint {
                    tooltip(point)
                        .offset(x: tooltipOffset(point.bucketStart, proxy: proxy, geometry: geometry))
                }
            }
        }
        .frame(height: density.overviewCostChartHeight)
    }

    private var costPane: some View {
        Chart {
            ForEach(series.points, id: \.bucketStart) { point in
                AreaMark(
                    x: .value("Time", point.bucketStart),
                    y: .value("Cost", costUSD(point))
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.20), Color.accentColor.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value("Time", point.bucketStart),
                    y: .value("Cost", costUSD(point))
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
            if let hoveredDate {
                RuleMark(x: .value("Time", hoveredDate))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: domain)
        .chartPlotStyle { $0.clipped() }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text(UsageFormatting.formatMicroUSD(Int64(raw * 1_000_000)))
                            .font(.system(size: 9, design: .rounded).monospacedDigit())
                            .frame(minWidth: Self.axisLabelWidth, alignment: .trailing)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.10))
                AxisValueLabel(format: axisFormat)
                    .font(.system(size: 9))
            }
        }
        .chartOverlay { proxy in
            hoverSurface(proxy: proxy) { geometry in
                if let point = hoveredPoint {
                    costPill(point)
                        .offset(x: costPillOffset(point.bucketStart, proxy: proxy, geometry: geometry))
                }
            }
        }
        .frame(height: density.overviewCostChartHeight)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No usage recorded in this range")
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: density.overviewCostChartHeight)
    }

    // MARK: - Hover

    /// One hover surface, mounted on both panes. Whichever pane the cursor is
    /// over writes the same `hoveredDate`, so the rule and the readouts move
    /// together instead of each pane tracking its own cursor.
    private func hoverSurface(
        proxy: ChartProxy,
        @ViewBuilder overlay: @escaping (GeometryProxy) -> some View
    ) -> some View {
        GeometryReader { geometry in
            let plotMinX = proxy.plotFrame.map { geometry[$0].minX } ?? 0
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            if let date: Date = proxy.value(
                                atX: location.x - plotMinX, as: Date.self
                            ) {
                                hoveredDate = nearestBucket(to: date)
                            }
                        case .ended:
                            hoveredDate = nil
                        }
                    }
                overlay(geometry)
                    .allowsHitTesting(false)
            }
        }
    }

    private func nearestBucket(to date: Date) -> Date? {
        series.points
            .min { lhs, rhs in
                abs(lhs.bucketStart.timeIntervalSince(date))
                    < abs(rhs.bucketStart.timeIntervalSince(date))
            }?
            .bucketStart
    }

    private func tooltip(_ point: UsageTrendPoint) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(tooltipDate(point.bucketStart))
                    .font(.system(size: 10, weight: .semibold))
                Spacer(minLength: 4)
                Text(UsageFormatting.formatMicroUSD(point.costMicros))
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
            }
            Divider().opacity(0.3)
            ForEach(UsageTokenSeries.allCases) { kind in
                HStack(spacing: 6) {
                    Capsule()
                        .fill(kind.color)
                        .frame(width: 8, height: 4)
                    Text(kind.title)
                        .font(.system(size: 9))
                        .foregroundStyle(hiddenSeries.contains(kind) ? .tertiary : .secondary)
                    Spacer(minLength: 4)
                    Text(UsageFormatting.compactTokens(kind.value(in: point)))
                        .font(.system(size: 9, design: .rounded).monospacedDigit())
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(width: Self.tooltipWidth)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
        .padding(.top, 4)
    }

    private func costPill(_ point: UsageTrendPoint) -> some View {
        Text(UsageFormatting.formatMicroUSD(point.costMicros))
            .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
            .padding(.horizontal, 9)
            .frame(minHeight: 20)
            .glassEffect(.regular, in: .capsule)
            .padding(.top, 4)
    }

    private func tooltipOffset(
        _ date: Date,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> CGFloat {
        offset(date, proxy: proxy, geometry: geometry, width: Self.tooltipWidth)
    }

    private func costPillOffset(
        _ date: Date,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> CGFloat {
        offset(date, proxy: proxy, geometry: geometry, width: 70)
    }

    private func offset(
        _ date: Date,
        proxy: ChartProxy,
        geometry: GeometryProxy,
        width: CGFloat
    ) -> CGFloat {
        let plotMinX = proxy.plotFrame.map { geometry[$0].minX } ?? 0
        let x = (proxy.position(forX: date) ?? 0) + plotMinX
        return min(max(0, x - width / 2), max(0, geometry.size.width - width))
    }

    // MARK: - Formatting

    private func costUSD(_ point: UsageTrendPoint) -> Double {
        Double(point.costMicros) / 1_000_000
    }

    private var axisFormat: Date.FormatStyle {
        series.bucket == .hour
            ? .dateTime.hour()
            : .dateTime.month(.abbreviated).day()
    }

    private func tooltipDate(_ date: Date) -> String {
        let formatter = series.bucket == .hour ? Self.hourFormatter : Self.dayFormatter
        return formatter.string(from: date)
    }

    private static let hourFormatter = localizedFormatter("MMMd HH:mm")
    private static let dayFormatter = localizedFormatter("EEEMMMd")

    private static func localizedFormatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}
