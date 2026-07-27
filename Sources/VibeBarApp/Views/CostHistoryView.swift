import SwiftUI
import Charts
import VibeBarCore

/// How the chart picks its bucket width: follow the visible span, or stay on
/// what the user asked for.
private enum CostGranularityMode: Equatable {
    case auto
    case manual(CostChartGranularity)
}

/// One entry in the granularity segmented control.
private struct CostGranularityOption: Identifiable, Equatable {
    let mode: CostGranularityMode
    let label: String
    /// `nil` for Auto, which is selectable at every span.
    let granularity: CostChartGranularity?

    var id: String {
        switch mode {
        case .auto: "auto"
        case .manual(let granularity): granularity.rawValue
        }
    }

    func isEnabled(allowed: [CostChartGranularity]) -> Bool {
        guard let granularity else { return true }
        return allowed.contains(granularity)
    }

    static let all: [CostGranularityOption] = [
        CostGranularityOption(mode: .auto, label: "Auto", granularity: nil),
        CostGranularityOption(
            mode: .manual(.hour),
            label: CostChartGranularity.hour.displayName,
            granularity: .hour
        ),
        CostGranularityOption(
            mode: .manual(.day),
            label: CostChartGranularity.day.displayName,
            granularity: .day
        ),
        CostGranularityOption(
            mode: .manual(.week),
            label: CostChartGranularity.week.displayName,
            granularity: .week
        ),
        CostGranularityOption(
            mode: .manual(.month),
            label: CostChartGranularity.month.displayName,
            granularity: .month
        )
    ]
}

/// A bucket already summed by Core, before its model roll-up is attached.
private struct CostBucketTotal {
    let start: Date
    let costUSD: Double
    let totalTokens: Int
}

private struct CostChartPoint: Identifiable, Equatable {
    let date: Date
    let costUSD: Double
    let totalTokens: Int
    let models: [CostSnapshot.ModelBreakdown]
    var id: Date { date }
}

/// What the chart resolved to, and whether it had to walk back from hourly.
private struct CostResolvedGranularity: Equatable {
    let granularity: CostChartGranularity
    /// Hourly was asked for (by Auto or by the user) but the visible range has
    /// no hourly evidence, so the chart is drawing days instead.
    let hourlyFallback: Bool
}

/// Everything about the underlying data that can move the navigable domain.
/// Rebuilding the window is keyed on this so a pan or a zoom never re-anchors
/// the view the user just scrolled to.
private struct CostDomainSignature: Equatable {
    var firstDay: Date?
    var lastDay: Date?
    var dayCount: Int
    var hourlyEnd: Date?
}

/// Cost history over a freely navigable time range.
///
/// The card shares its interaction model with `QuotaHistoryChartView`: the full
/// recorded extent is the domain, the user sees a sub-range, and drag-pan,
/// pinch-zoom, the brush strip and the range pills all funnel through one
/// `ChartTimeWindow`. Bucket width follows the visible span by default — zoom
/// into two days of a year-long domain and the bars become hours without the
/// user changing mode.
///
/// Model detail keeps its original two-step shape: hover for the compact
/// tooltip, click for the inline inspector. `ColumnMasonryLayout` keeps the
/// current column assignments stable while the expanded card changes height, so
/// inspecting a bar does not shuffle the Overview.
struct CostHistoryView: View {
    let tool: ToolType
    let snapshot: CostSnapshot?
    let density: Theme.Density
    var chartHeight: CGFloat = 130
    var titleOverride: String? = nil

    @State private var window: ChartTimeWindow?
    @State private var granularityMode: CostGranularityMode = .auto
    @State private var hoveredDate: Date?
    @State private var inspectedPoint: CostChartPoint?
    @State private var panBase: ChartTimeWindow?
    @State private var magnifyBase: ChartTimeWindow?

    @EnvironmentObject var environment: AppEnvironment

    private static let dayInterval: TimeInterval = 86_400
    /// Zoom floor. Half a day still shows twelve hourly bars; anything tighter
    /// is more scrolling than signal for a cost chart.
    private static let minimumSpan: TimeInterval = 12 * 3_600
    /// Opening span, and what a double-tap returns to.
    private static let resetSpan: TimeInterval = 30 * 86_400
    /// Marks inside the visible window. Only reachable by manually holding a
    /// fine granularity across a very wide window — beyond this the bars are
    /// thinner than a pixel and only cost frames.
    private static let visibleMarkLimit = 520
    private static let miniMarkLimit = 180

    var body: some View {
        let window = self.window

        VStack(alignment: .leading, spacing: density.cardSpacing) {
            header(window: window)

            if let window, window.domainSpan > 0 {
                navigableContent(window: window)
            } else {
                emptyNote
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
        .onChange(of: domainSignature, initial: true) { _, _ in
            rebuildWindow()
        }
        .onChange(of: window?.visibleSpan) { _, span in
            demoteDisallowedGranularity(span: span)
        }
        .onChange(of: granularityKey) { _, _ in
            clearSelection()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(window: ChartTimeWindow?) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(titleOverride ?? "Cost History")
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                Spacer(minLength: 8)
                SectionRefreshButton(isRefreshing: false) {
                    environment.refreshCostUsage()
                }
            }
            if let window {
                // Five presets plus five bucket widths do not fit on one line in
                // a compact popover. Prefer the single row, then stack.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        presetBar(window: window)
                        granularityControl(window: window)
                    }
                    VStack(alignment: .trailing, spacing: 3) {
                        presetBar(window: window)
                        granularityControl(window: window)
                    }
                }
            }
        }
    }

    private func presetBar(window: ChartTimeWindow) -> some View {
        CostRangePresetBar(
            active: activePreset(window: window),
            density: density,
            action: applyPreset
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    private var emptyNote: some View {
        VStack(spacing: 4) {
            Text("Building history…")
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.tertiary)
            Text("Cost samples appear after the next local scan.")
                .font(.system(size: density.resetCountdownFontSize))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Chart

    @ViewBuilder
    private func navigableContent(window: ChartTimeWindow) -> some View {
        let binding = windowBinding(fallback: window)
        let resolved = resolve(window: window)
        let points = visiblePoints(window: window, granularity: resolved.granularity)
        let rendered = ChartSeriesThinning.strided(points, limit: Self.visibleMarkLimit)
        let total = points.reduce(0) { $0 + $1.costUSD }
        let average = points.isEmpty ? 0 : total / Double(points.count)
        let peakPoint = points.max { $0.costUSD < $1.costUSD }
        let peak = peakPoint?.costUSD ?? 0

        VStack(alignment: .leading, spacing: 6) {
            chart(
                points: rendered,
                average: average,
                granularity: resolved.granularity,
                window: binding
            )

            ChartBrushNavigator(
                window: binding,
                accent: .accentColor,
                height: density.chartBrushHeight,
                accessibilityDescription: "Cost history range navigator"
            ) { geometry in
                miniBars(in: geometry)
            }
        }

        if inspectedPoint != nil {
            inlineModelInspector(granularity: resolved.granularity)
        }

        footer(
            total: total,
            average: average,
            peak: peak,
            peakDate: peak > 0 ? peakPoint?.date : nil,
            resolved: resolved,
            window: window
        )
    }

    @ViewBuilder
    private func chart(
        points: [CostChartPoint],
        average: Double,
        granularity: CostChartGranularity,
        window: Binding<ChartTimeWindow>
    ) -> some View {
        Chart {
            if granularity == .hour {
                ForEach(points) { point in
                    AreaMark(
                        x: .value("Hour", point.date, unit: .hour),
                        y: .value("Cost", point.costUSD)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    LineMark(
                        x: .value("Hour", point.date, unit: .hour),
                        y: .value("Cost", point.costUSD)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .opacity(pointOpacity(point))
                    if point.costUSD > 0 {
                        PointMark(
                            x: .value("Hour", point.date, unit: .hour),
                            y: .value("Cost", point.costUSD)
                        )
                        .symbolSize(24)
                        .foregroundStyle(point.costUSD > average * 1.5 ? Color.orange : Color.accentColor)
                    }
                }
            } else {
                ForEach(points) { point in
                    BarMark(
                        x: .value(
                            "Period",
                            point.date,
                            unit: barUnit(granularity),
                            calendar: Self.barCalendar
                        ),
                        y: .value("Cost", point.costUSD)
                    )
                    .foregroundStyle(point.costUSD > average * 1.5 ? Color.orange : Color.accentColor)
                    .cornerRadius(2)
                    .opacity(pointOpacity(point))
                }
            }
            if average > 0 {
                RuleMark(y: .value("Avg", average))
                    .foregroundStyle(Color.accentColor.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            }
        }
        .chartXScale(domain: window.wrappedValue.visibleRange)
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
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisValueLabel(
                    format: axisFormat(granularity, span: window.wrappedValue.visibleSpan)
                )
                .font(.system(size: 9))
            }
        }
        .chartOverlay { proxy in
            interactionOverlay(proxy: proxy, points: points, window: window)
        }
        .frame(height: chartHeight)
        .overlay {
            if points.isEmpty {
                Text("No cost recorded in this range.")
                    .font(.system(size: density.resetCountdownFontSize))
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Thin daily bars for the brush strip. Always daily regardless of the main
    /// chart's granularity: the strip's job is to show where the activity is
    /// across the whole domain, not to mirror the current zoom.
    private func miniBars(in geometry: ChartBrushGeometry) -> some View {
        let days = ChartSeriesThinning.strided(
            snapshot?.dailyHistory ?? [],
            limit: Self.miniMarkLimit
        )
        let peak = days.map(\.costUSD).max() ?? 0
        let width = max(1, min(3, geometry.size.width / CGFloat(max(days.count, 1)) - 0.5))
        return Path { path in
            guard peak > 0 else { return }
            let baseline = geometry.y(forFraction: 0)
            for day in days {
                // Centre the bar on the day it represents, not on its midnight.
                let x = geometry.x(for: day.date.addingTimeInterval(Self.dayInterval / 2))
                let top = geometry.y(forFraction: day.costUSD / peak)
                path.addRect(
                    CGRect(x: x - width / 2, y: top, width: width, height: max(1, baseline - top))
                )
            }
        }
        .fill(Color.accentColor.opacity(0.55))
    }

    // MARK: - Hover + gestures

    private func interactionOverlay(
        proxy: ChartProxy,
        points: [CostChartPoint],
        window: Binding<ChartTimeWindow>
    ) -> some View {
        GeometryReader { geometry in
            let plot = proxy.plotFrame.map { geometry[$0] }
            let plotMinX = plot?.minX ?? 0
            let plotWidth = plot?.width ?? geometry.size.width
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            // The overlay also covers the leading axis strip; a
                            // reading from there would snap the tooltip to a
                            // bucket the cursor is not over.
                            if let date: Date = proxy.value(atX: location.x - plotMinX, as: Date.self) {
                                hoveredDate = nearestPoint(to: date, in: points)?.date
                            }
                        case .ended:
                            hoveredDate = nil
                        }
                    }
                    .gesture(panGesture(window: window, plotWidth: plotWidth))
                    .simultaneousGesture(
                        magnifyGesture(window: window, proxy: proxy, plotMinX: plotMinX)
                    )
                    .onTapGesture(count: 2) {
                        window.wrappedValue = window.wrappedValue.jumped(toSpan: Self.resetSpan)
                        clearSelection()
                    }
                    .onTapGesture {
                        guard let hovered = hoveredPoint(in: points) else { return }
                        inspectedPoint = inspectedPoint?.date == hovered.date ? nil : hovered
                    }

                if let hovered = hoveredPoint(in: points), inspectedPoint == nil {
                    compactTooltip(hovered)
                        .offset(x: tooltipX(for: hovered.date, proxy: proxy, geometry: geometry))
                }
            }
        }
    }

    private func panGesture(window: Binding<ChartTimeWindow>, plotWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard plotWidth > 0 else { return }
                let base = panBase ?? window.wrappedValue
                if panBase == nil { panBase = base }
                let secondsPerPoint = base.visibleSpan / TimeInterval(plotWidth)
                window.wrappedValue = base.panned(
                    by: -TimeInterval(value.translation.width) * secondsPerPoint
                )
            }
            .onEnded { _ in panBase = nil }
    }

    private func magnifyGesture(
        window: Binding<ChartTimeWindow>,
        proxy: ChartProxy,
        plotMinX: CGFloat
    ) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                let base = magnifyBase ?? window.wrappedValue
                if magnifyBase == nil { magnifyBase = base }
                let anchor = proxy.value(atX: value.startLocation.x - plotMinX, as: Date.self)
                    ?? base.visibleMidpoint
                window.wrappedValue = base.zoomed(scale: value.magnification, around: anchor)
            }
            .onEnded { _ in magnifyBase = nil }
    }

    private func compactTooltip(_ point: CostChartPoint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(tooltipDate(point.date, granularity: currentGranularity))
                    .font(.system(size: 10, weight: .semibold))
                Spacer(minLength: 8)
                Text(formatCost(point.costUSD))
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
            }
            Text(formatTokens(point.totalTokens))
                .font(.system(size: 9, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
            ForEach(point.models.prefix(3)) { model in
                modelRow(model)
            }
            if point.models.count > 3 {
                Text("+\(point.models.count - 3) more · click to inspect")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.87)))
        .foregroundStyle(.white)
        .frame(width: 190)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func inlineModelInspector(granularity: CostChartGranularity) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
                .opacity(0.35)

            if let point = inspectedPoint {
                HStack(spacing: 8) {
                    Text("Models · \(tooltipDate(point.date, granularity: granularity))")
                        .font(.system(size: 10, weight: .semibold))
                    Spacer(minLength: 8)
                    Button {
                        inspectedPoint = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear model selection")
                }

                if point.models.isEmpty {
                    Text("Model detail is unavailable for this historical period.")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 16, alignment: .leading),
                            GridItem(.flexible(), spacing: 0, alignment: .leading)
                        ],
                        alignment: .leading,
                        spacing: 4
                    ) {
                        ForEach(point.models) { model in
                            inspectedModelRow(model)
                        }
                    }
                }
            }
        }
    }

    private func inspectedModelRow(_ model: CostSnapshot.ModelBreakdown) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(model.modelName)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(formatCost(model.costUSD))
                .font(.system(size: 9, design: .rounded).monospacedDigit())
            Text(formatTokens(model.totalTokens))
                .font(.system(size: 8, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func modelRow(_ model: CostSnapshot.ModelBreakdown) -> some View {
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

    // MARK: - Footer

    @ViewBuilder
    private func footer(
        total: Double,
        average: Double,
        peak: Double,
        peakDate: Date?,
        resolved: CostResolvedGranularity,
        window: ChartTimeWindow
    ) -> some View {
        HStack(spacing: 16) {
            metric(label: "Total", value: formatCost(total))
            metric(
                label: "Avg/\(resolved.granularity.displayName.lowercased())",
                value: formatCost(average)
            )
            metric(
                label: "Peak",
                value: formatCost(peak),
                detail: peakDate.map { peakDetail($0, granularity: resolved.granularity) }
            )
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(visibleExtentNote(window: window))
                    .font(.system(size: density.resetCountdownFontSize))
                    .foregroundStyle(.tertiary)
                if resolved.hourlyFallback {
                    Text("hourly n/a · showing daily")
                        .font(.system(size: max(8, density.resetCountdownFontSize - 1)))
                        .foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    @ViewBuilder
    private func metric(label: String, value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label.uppercased())
                .font(.system(size: max(8, density.subtitleFontSize - 2), weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.4)
            Text(value)
                .font(.system(size: density.bucketTitleFontSize, weight: .semibold, design: .rounded).monospacedDigit())
            if let detail {
                Text(detail)
                    .font(.system(size: max(8, density.resetCountdownFontSize - 2)))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    // MARK: - Window

    private func windowBinding(fallback: ChartTimeWindow) -> Binding<ChartTimeWindow> {
        Binding<ChartTimeWindow>(
            get: { self.window ?? fallback },
            set: { self.window = $0 }
        )
    }

    private var domainSignature: CostDomainSignature {
        CostDomainSignature(
            firstDay: snapshot?.dailyHistory.first?.date,
            lastDay: snapshot?.dailyHistory.last?.date,
            dayCount: snapshot?.dailyHistory.count ?? 0,
            hourlyEnd: snapshot?.todayHourlyHistory.last?.date
        )
    }

    /// The full navigable extent: first recorded day through the end of today.
    ///
    /// The newest edge is the end of the current day rather than this instant so
    /// today's bar is drawn whole and the Today / Yesterday presets land exactly
    /// on calendar-day boundaries — the same frame the old fixed-timeframe chart
    /// used. Floored at 24h so a first-run domain is still navigable.
    private func domainRange() -> ClosedRange<Date>? {
        guard let snapshot else { return nil }
        let calendar = Calendar.current
        var low = snapshot.dailyHistory.first?.date
        if let firstHour = snapshot.yesterdayHourlyHistory.first?.date
            ?? snapshot.todayHourlyHistory.first?.date {
            low = low.map { min($0, firstHour) } ?? firstHour
        }
        guard let low else { return nil }
        let start = calendar.startOfDay(for: low)
        let today = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: today)
            ?? today.addingTimeInterval(Self.dayInterval)
        if end.timeIntervalSince(start) < Self.dayInterval {
            return end.addingTimeInterval(-Self.dayInterval)...end
        }
        return start...end
    }

    /// Re-anchor the window after a scan. Runs on data changes only — pans and
    /// zooms reuse the window they produced.
    private func rebuildWindow() {
        guard let domain = domainRange(), domain.upperBound > domain.lowerBound else {
            window = nil
            return
        }
        if let existing = window {
            if existing.domainStart == domain.lowerBound,
               existing.domainEnd == domain.upperBound {
                return
            }
            // Domain grew (a scan landed) — keep the user where they were,
            // unless they were pinned to the newest edge, which should follow.
            let followsEnd = existing.isAtDomainEnd
            var next = ChartTimeWindow(
                domainStart: domain.lowerBound,
                domainEnd: domain.upperBound,
                minimumSpan: Self.minimumSpan,
                visibleStart: existing.visibleStart,
                visibleEnd: existing.visibleEnd
            )
            if followsEnd { next.jump(toSpan: existing.visibleSpan) }
            window = next
            return
        }
        window = ChartTimeWindow(
            domainStart: domain.lowerBound,
            domainEnd: domain.upperBound,
            minimumSpan: Self.minimumSpan,
            visibleSpan: Self.resetSpan
        )
    }

    // MARK: - Range presets

    private func applyPreset(_ preset: CostTimeframe) {
        guard var current = window else { return }
        switch preset {
        case .today:
            current.jump(toSpan: Self.dayInterval)
        case .yesterday:
            // The one preset that is not anchored at the newest edge.
            let (start, end) = Self.yesterdayBounds()
            current = ChartTimeWindow(
                domainStart: current.domainStart,
                domainEnd: current.domainEnd,
                minimumSpan: current.minimumSpan,
                visibleStart: start,
                visibleEnd: end
            )
        case .week:
            current.jump(toSpan: 7 * Self.dayInterval)
        case .month:
            current.jump(toSpan: 30 * Self.dayInterval)
        case .all:
            current.jump(toSpan: current.domainSpan)
        }
        window = current
        clearSelection()
    }

    /// Which pill (if any) describes the current window. Free navigation
    /// routinely lands between presets, and none being lit is the honest
    /// answer — not a reason to snap the window to the nearest one.
    private func activePreset(window: ChartTimeWindow) -> CostTimeframe? {
        if window.coversDomain { return .all }
        let span = window.visibleSpan
        let tolerance = Self.dayInterval * 0.03
        let (yesterdayStart, _) = Self.yesterdayBounds()
        if abs(span - Self.dayInterval) <= tolerance,
           abs(window.visibleStart.timeIntervalSince(yesterdayStart)) <= tolerance {
            return .yesterday
        }
        guard window.isAtDomainEnd else { return nil }
        let anchored: [(CostTimeframe, TimeInterval)] = [
            (.today, Self.dayInterval),
            (.week, 7 * Self.dayInterval),
            (.month, 30 * Self.dayInterval)
        ]
        return anchored.first { abs(span - $0.1) <= $0.1 * 0.03 }?.0
    }

    private static func yesterdayBounds() -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -1, to: today)
            ?? today.addingTimeInterval(-dayInterval)
        return (start, today)
    }

    // MARK: - Granularity

    @ViewBuilder
    private func granularityControl(window: ChartTimeWindow) -> some View {
        let allowed = CostChartGranularity.allowed(for: window.visibleSpan)
        HStack(spacing: 1) {
            ForEach(CostGranularityOption.all) { option in
                let enabled = option.isEnabled(allowed: allowed)
                Button {
                    granularityMode = option.mode
                } label: {
                    granularityOptionLabel(
                        option,
                        selected: granularityMode == option.mode,
                        enabled: enabled
                    )
                }
                .buttonStyle(.plain)
                .focusable(false)
                .disabled(!enabled)
                .help(
                    enabled
                        ? "Group cost history by \(option.label.lowercased())"
                        : "\(option.label) needs a different zoom level"
                )
                .accessibilityLabel("Group cost history by \(option.label.lowercased())")
            }
        }
        .padding(2)
        .frame(width: CGFloat(CostGranularityOption.all.count) * 32)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
    }

    private func granularityOptionLabel(
        _ option: CostGranularityOption,
        selected: Bool,
        enabled: Bool
    ) -> some View {
        Text(option.label)
            .font(.system(size: max(9, density.segmentedFontSize - 1), weight: .semibold, design: .rounded))
            .foregroundStyle(enabled ? (selected ? Color.primary : Color.secondary) : Color.secondary.opacity(0.4))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity, minHeight: 22)
            .contentShape(Rectangle())
            .background {
                if selected, enabled {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.12))
                }
            }
    }

    /// A manual pick that stops making sense after a pan or a zoom returns to
    /// Auto rather than silently drawing something the span cannot carry.
    private func demoteDisallowedGranularity(span: TimeInterval?) {
        guard case .manual(let choice) = granularityMode, let span else { return }
        if !CostChartGranularity.isAllowed(choice, for: span) {
            granularityMode = .auto
        }
    }

    private func resolve(window: ChartTimeWindow) -> CostResolvedGranularity {
        let span = window.visibleSpan
        let requested: CostChartGranularity
        switch granularityMode {
        case .auto:
            requested = CostChartGranularity.resolve(autoFor: span)
        case .manual(let choice):
            // A pinch can invalidate the pick mid-gesture. Draw what the span
            // can carry straight away; `demoteDisallowedGranularity` moves the
            // selection back to Auto once the change settles.
            requested = CostChartGranularity.isAllowed(choice, for: span)
                ? choice
                : CostChartGranularity.resolve(autoFor: span)
        }
        guard requested == .hour, !hasHourlyCoverage(in: window.visibleRange) else {
            return CostResolvedGranularity(granularity: requested, hourlyFallback: false)
        }
        return CostResolvedGranularity(granularity: .day, hourlyFallback: true)
    }

    private var currentGranularity: CostChartGranularity {
        guard let window else { return .day }
        return resolve(window: window).granularity
    }

    private var granularityKey: String {
        currentGranularity.rawValue
    }

    /// Hourly detail only exists for yesterday and today — the scanner keeps
    /// per-hour buckets for those two days and nothing older. Any overlap with
    /// that stretch is enough to draw hours; a window entirely outside it falls
    /// back to daily bars.
    private var hourlyCoverage: ClosedRange<Date>? {
        guard let snapshot else { return nil }
        let first = snapshot.yesterdayHourlyHistory.first?.date
            ?? snapshot.todayHourlyHistory.first?.date
        let last = snapshot.todayHourlyHistory.last?.date
            ?? snapshot.yesterdayHourlyHistory.last?.date
        guard let first, let last, last >= first else { return nil }
        return first...last.addingTimeInterval(3_600)
    }

    private func hasHourlyCoverage(in range: ClosedRange<Date>) -> Bool {
        guard let coverage = hourlyCoverage else { return false }
        return coverage.lowerBound <= range.upperBound && coverage.upperBound >= range.lowerBound
    }

    // MARK: - Data shaping

    /// Buckets that touch the visible range, oldest first. A bucket straddling
    /// an edge is kept whole: it is a real bar the user can see, and cutting its
    /// total to the visible slice would make the footer disagree with the chart.
    private func visiblePoints(
        window: ChartTimeWindow,
        granularity: CostChartGranularity
    ) -> [CostChartPoint] {
        guard let snapshot else { return [] }
        let range = window.visibleRange
        switch granularity {
        case .hour:
            let hours = snapshot.yesterdayHourlyHistory + snapshot.todayHourlyHistory
            return clip(hours, date: \.date, bucket: clipBucket(.hour), to: range).map { point in
                CostChartPoint(
                    date: point.date,
                    costUSD: point.costUSD,
                    totalTokens: point.totalTokens,
                    models: snapshot.topModels(forHour: point.date, limit: .max)
                )
            }
        case .day:
            return clip(snapshot.dailyHistory, date: \.date, bucket: clipBucket(.day), to: range)
                .map { point in
                    CostChartPoint(
                        date: point.date,
                        costUSD: point.costUSD,
                        totalTokens: point.totalTokens,
                        models: snapshot.topModels(for: point.date, limit: .max)
                    )
                }
        case .week:
            let calendar = Calendar.current
            let weeks = CostChartAggregation.weekly(snapshot.dailyHistory, calendar: calendar)
                .map { CostBucketTotal(start: $0.weekStart, costUSD: $0.costUSD, totalTokens: $0.totalTokens) }
            return groupedPoints(
                snapshot: snapshot,
                buckets: weeks,
                bucket: clipBucket(.week),
                range: range
            ) { CostChartAggregation.mondayStart(of: $0, calendar: calendar) }
        case .month:
            let calendar = Calendar.current
            let months = CostChartAggregation.monthly(snapshot.dailyHistory, calendar: calendar)
                .map { CostBucketTotal(start: $0.monthStart, costUSD: $0.costUSD, totalTokens: $0.totalTokens) }
            return groupedPoints(
                snapshot: snapshot,
                buckets: months,
                bucket: clipBucket(.month),
                range: range
            ) { CostChartAggregation.monthStart(of: $0, calendar: calendar) }
        }
    }

    /// Attach a model roll-up to buckets Core already summed.
    ///
    /// Cost and tokens come straight from `CostChartAggregation`; only the model
    /// split has to be recomputed here, because the snapshot stores it per day.
    private func groupedPoints(
        snapshot: CostSnapshot,
        buckets: [CostBucketTotal],
        bucket: TimeInterval,
        range: ClosedRange<Date>,
        bucketStart: (Date) -> Date?
    ) -> [CostChartPoint] {
        let visible = clip(buckets, date: \.start, bucket: bucket, to: range)
        guard !visible.isEmpty else { return [] }

        // Only the visible buckets need a roll-up; folding the whole history
        // every render would be work nobody sees.
        let wanted = Set(visible.map(\.start))
        var models: [Date: [String: (cost: Double, tokens: Int)]] = [:]
        for day in snapshot.dailyHistory {
            guard let start = bucketStart(day.date), wanted.contains(start) else { continue }
            var bucketModels = models[start] ?? [:]
            for model in snapshot.topModels(for: day.date, limit: .max) {
                let current = bucketModels[model.modelName] ?? (0, 0)
                bucketModels[model.modelName] = (
                    current.cost + model.costUSD,
                    current.tokens + model.totalTokens
                )
            }
            models[start] = bucketModels
        }

        return visible.map { total in
            CostChartPoint(
                date: total.start,
                costUSD: total.costUSD,
                totalTokens: total.totalTokens,
                models: (models[total.start] ?? [:])
                    .map {
                        CostSnapshot.ModelBreakdown(
                            modelName: $0.key,
                            costUSD: $0.value.cost,
                            totalTokens: $0.value.tokens
                        )
                    }
                    .sorted { $0.costUSD > $1.costUSD }
            )
        }
    }

    /// Bucket width used to decide whether a bar touches the visible range.
    /// Over-inclusive for months on purpose: the longest calendar month keeps a
    /// 31-day bar at the edge from disappearing a day early.
    private func clipBucket(_ granularity: CostChartGranularity) -> TimeInterval {
        switch granularity {
        case .hour: 3_600
        case .day: Self.dayInterval
        case .week: 7 * Self.dayInterval
        case .month: 31 * Self.dayInterval
        }
    }

    private func clip<Element>(
        _ points: [Element],
        date: KeyPath<Element, Date>,
        bucket: TimeInterval,
        to range: ClosedRange<Date>
    ) -> [Element] {
        points.filter { element in
            let start = element[keyPath: date]
            return start <= range.upperBound && start.addingTimeInterval(bucket) >= range.lowerBound
        }
    }

    // MARK: - Presentation helpers

    /// Monday-first so a `.weekOfYear` bar covers exactly the week
    /// `CostChartAggregation.weekly` summed. Left as the current calendar
    /// otherwise: `firstWeekday` does not touch hour or day bins, and a
    /// US-default Sunday-first calendar would draw every weekly bar one day to
    /// the left of the data it represents.
    private static let barCalendar: Calendar = {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }()

    private func barUnit(_ granularity: CostChartGranularity) -> Calendar.Component {
        switch granularity {
        case .hour: .hour
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    /// Day-and-month reads best at every span a cost chart is normally used at.
    /// Past about a year the five automatic labels start repeating month names
    /// from different years, so the day gives way to the year.
    private func axisFormat(
        _ granularity: CostChartGranularity,
        span: TimeInterval
    ) -> Date.FormatStyle {
        switch granularity {
        case .hour: .dateTime.hour()
        case .day, .week:
            span > Self.multiYearSpan
                ? .dateTime.month(.abbreviated).year(.twoDigits)
                : .dateTime.day().month(.abbreviated)
        // Monthly bars only appear on spans where the day of the month is
        // noise, so the label goes straight to month-and-year.
        case .month: .dateTime.month(.abbreviated).year(.twoDigits)
        }
    }

    private func hoveredPoint(in points: [CostChartPoint]) -> CostChartPoint? {
        hoveredDate.flatMap { date in points.first { $0.date == date } }
    }

    private func nearestPoint(to date: Date, in points: [CostChartPoint]) -> CostChartPoint? {
        points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    private func pointOpacity(_ point: CostChartPoint) -> Double {
        guard let selected = inspectedPoint?.date ?? hoveredDate else { return 1 }
        return point.date == selected ? 1 : 0.55
    }

    private func tooltipX(for date: Date, proxy: ChartProxy, geometry: GeometryProxy) -> CGFloat {
        guard let x = proxy.position(forX: date) else { return 0 }
        let plotMinX = proxy.plotFrame.map { geometry[$0].minX } ?? 0
        return min(max(plotMinX + x - 95, 0), max(0, geometry.size.width - 190))
    }

    private func clearSelection() {
        hoveredDate = nil
        inspectedPoint = nil
    }

    private func visibleExtentNote(window: ChartTimeWindow) -> String {
        let span = Self.spanLabel(window.visibleSpan)
        let formatter = window.visibleSpan > Self.multiYearSpan
            ? Self.extentYearFormatter
            : Self.extentFormatter
        let start = formatter.string(from: window.visibleStart)
        let end = formatter.string(from: window.visibleEnd)
        return "\(span) · \(start) – \(end)"
    }

    /// Past this the day-of-month stops disambiguating anything.
    private static let multiYearSpan: TimeInterval = 400 * dayInterval

    private static func spanLabel(_ seconds: TimeInterval) -> String {
        if seconds < 90 * 60 { return "\(max(1, Int((seconds / 60).rounded())))m" }
        if seconds < 48 * 3_600 { return "\(Int((seconds / 3_600).rounded()))h" }
        return "\(Int((seconds / 86_400).rounded()))d"
    }

    private func formatCost(_ value: Double) -> String {
        if value < 0.01 { return "$0.00" }
        if value < 100 { return String(format: "$%.2f", value) }
        return String(format: "$%.0f", value)
    }

    private func formatAxisCost(_ value: Double) -> String {
        value < 1 ? String(format: "$%.2f", value) : String(format: "$%.0f", value)
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens < 1_000 { return "\(tokens) tok" }
        if tokens < 1_000_000 { return String(format: "%.1fk tok", Double(tokens) / 1_000) }
        if tokens < 1_000_000_000 { return String(format: "%.2fM tok", Double(tokens) / 1_000_000) }
        return String(format: "%.2fB tok", Double(tokens) / 1_000_000_000)
    }

    private func tooltipDate(_ date: Date, granularity: CostChartGranularity) -> String {
        switch granularity {
        case .hour: Self.hourFormatter.string(from: date)
        case .day: Self.dayFormatter.string(from: date)
        case .week: "Week of \(Self.dayFormatter.string(from: date))"
        case .month: Self.monthFormatter.string(from: date)
        }
    }

    /// When the peak bucket happened, in the narrowest form that still says
    /// which bucket it was.
    private func peakDetail(_ date: Date, granularity: CostChartGranularity) -> String {
        switch granularity {
        case .hour: Self.peakHourFormatter.string(from: date)
        case .day: Self.extentFormatter.string(from: date)
        case .week: "wk \(Self.extentFormatter.string(from: date))"
        case .month: Self.monthFormatter.string(from: date)
        }
    }

    private static let hourFormatter = posixFormatter("MMM d · HH:00")
    private static let peakHourFormatter = posixFormatter("MMM d HH:00")
    private static let dayFormatter = posixFormatter("MMM d, yyyy")
    private static let monthFormatter = posixFormatter("MMM yyyy")
    private static let extentFormatter = posixFormatter("MMM d")
    private static let extentYearFormatter = posixFormatter("MMM yyyy")

    private static func posixFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}

/// The original timeframe pills, repurposed as window presets. Selection is
/// derived from the window rather than owned here: free navigation can leave
/// every pill unlit, which a `Binding<CostTimeframe>` could not express.
private struct CostRangePresetBar: View {
    let active: CostTimeframe?
    let density: Theme.Density
    let action: (CostTimeframe) -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(CostTimeframe.allCases) { preset in
                Button {
                    action(preset)
                } label: {
                    Text(preset.shortLabel)
                        .font(.system(size: max(9, density.segmentedFontSize - 1), weight: .semibold, design: .rounded))
                        .foregroundStyle(active == preset ? .primary : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .background {
                    if active == preset {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.12))
                    }
                }
                .accessibilityLabel(preset.label)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
    }
}
