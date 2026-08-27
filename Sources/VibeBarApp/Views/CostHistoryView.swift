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

    /// Auto is selectable at every span. A manual width is offered only when
    /// picking it would actually stick — the same rule that demotes a pick
    /// after a pan or a zoom, so the control never lights up an option the
    /// chart would immediately hand back.
    func isEnabled(for visibleSpan: TimeInterval) -> Bool {
        guard let granularity else { return true }
        return CostChartGranularity.survivesManualSelection(granularity, for: visibleSpan)
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

/// Range presets the navigable cost chart offers.
///
/// Deliberately not `CostTimeframe`, which still carries a Yesterday case for
/// the summary tiles. The chart dropped its Yesterday pill: free navigation
/// reaches yesterday with one drag, and the pill's label was the widest in the
/// busiest row of the card — it pushed the bucket-width control off the edge in
/// a narrow Overview column for a range the user can already reach.
private enum CostRangePreset: String, CaseIterable, Identifiable {
    case today
    case week
    case month
    case all

    var id: String { rawValue }

    /// Calendar days back from the end of today, or `nil` for the whole domain.
    var days: Int? {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        case .all: nil
        }
    }

    var shortLabel: String {
        switch self {
        case .today: "Today"
        case .week: "7d"
        case .month: "30d"
        case .all: "All"
        }
    }

    var label: String {
        switch self {
        case .today: "Today"
        case .week: "7 days"
        case .month: "30 days"
        case .all: "All"
        }
    }
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
    /// Opening span, and what a double-tap returns to. Calendar-derived like
    /// the presets: the domain ends at the end of today, so 30 calendar days
    /// back from it is a midnight and the chart opens on exactly 30 whole bars.
    private static var resetSpan: TimeInterval {
        CostChartWindowPolicy.anchoredSpan(days: 30)
    }
    /// Marks inside the visible window. Only reachable by manually holding a
    /// fine granularity across a very wide window — beyond this the bars are
    /// thinner than a pixel and only cost frames.
    private static let visibleMarkLimit = 520
    private static let miniMarkLimit = 180

    var body: some View {
        // Derived, not just read: `rebuildWindow()` only runs once the card is
        // on screen, and until it does `self.window` is nil. Measuring the card
        // in that state reports the height of the "Building history…" note —
        // roughly a third of the real card — and any ancestor that sizes from
        // that first pass (the Overview waterfall proposes each card the height
        // it measured) would lay the card out too short. Seeding the window
        // here makes the first measurement the real one.
        let window = self.window ?? initialWindow()

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
                // Four presets plus five bucket widths do not fit on one line
                // in a compact popover, and the two groups are the widest thing
                // in the card. Offer the same pair at three widths and let
                // `ViewThatFits` pick.
                //
                // The last candidate is the one that matters: `ViewThatFits`
                // falls back to it when *nothing* fits, so it has to be the one
                // that compresses. The first two hold their natural width —
                // pills that shrink when they don't need to look broken — while
                // the last drops `fixedSize` and lets the labels take their
                // `minimumScaleFactor`. Before this, the narrowest candidate
                // was still rigid, so an Overview column narrower than the two
                // groups drew "Week Month" straight past the card edge.
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
                    VStack(alignment: .trailing, spacing: 3) {
                        presetBar(window: window, compressible: true)
                        granularityControl(window: window, compressible: true)
                    }
                }
            }
        }
    }

    private func presetBar(window: ChartTimeWindow, compressible: Bool = false) -> some View {
        CostRangePresetBar(
            active: activePreset(window: window),
            density: density,
            action: applyPreset
        )
        // `fixedSize(horizontal: false)` is a no-op, so the compressible
        // candidate simply doesn't pin the width.
        .fixedSize(horizontal: !compressible, vertical: false)
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
        // The bar width has to be resolved against the real plot width: Swift
        // Charts sizes a calendar-unit bar to the whole unit, so a five-day
        // window would otherwise draw five ~90pt slabs.
        GeometryReader { geometry in
            chartBody(
                points: points,
                average: average,
                granularity: granularity,
                window: window,
                barWidth: barWidth(
                    points: points,
                    granularity: granularity,
                    window: window.wrappedValue,
                    // The GeometryReader measures the whole chart, gutter
                    // included; the bars only ever get what is left of it.
                    plotWidth: geometry.size.width - Self.yAxisGutterWidth
                )
            )
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

    @ViewBuilder
    private func chartBody(
        points: [CostChartPoint],
        average: Double,
        granularity: CostChartGranularity,
        window: Binding<ChartTimeWindow>,
        barWidth: MarkDimension
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
                        y: .value("Cost", point.costUSD),
                        width: barWidth
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
        // Marks are laid out against the scale, not against the plot rect, so a
        // bucket that straddles the visible range's leading edge draws half its
        // body to the left of the plot — straight across the "$0.00" label
        // column. `visiblePoints` keeps those straddling buckets whole on
        // purpose (cutting them would make the footer disagree with the chart),
        // so the bar has to be clipped rather than dropped.
        .chartPlotStyle { plotArea in
            plotArea.clipped()
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text(formatAxisCost(raw))
                            .font(.system(size: 9, design: .rounded).monospacedDigit())
                            // Swift Charts insets the plot by whatever the
                            // widest label reports, so a floor here is a floor
                            // on the gutter. Without it the column is as narrow
                            // as "$10" at some zoom levels and as wide as
                            // "$0.00" at others, and the plot edge — and with
                            // it the first bar — slides sideways as the user
                            // pans. `minWidth` rather than `width` so a
                            // four-figure total still gets the room it needs.
                            .frame(minWidth: Self.yAxisLabelWidth, alignment: .trailing)
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
    }

    /// Floor for the leading y-axis label column. "$0.00" at 9pt monospaced
    /// digits is about 24pt; the extra keeps the gutter stable when the axis
    /// switches between "$0.00" and "$10".
    private static let yAxisLabelWidth: CGFloat = 30
    /// What the label column costs the plot: the label itself plus the gap
    /// Swift Charts leaves between it and the plot edge. Subtracted before
    /// bar widths are derived, so the pitch is measured against the width the
    /// bars actually get rather than the width of the whole card.
    private static let yAxisGutterWidth: CGFloat = yAxisLabelWidth + 6

    /// Widest a single bar is allowed to get. Past this a bar stops reading as
    /// a measurement and starts reading as a block of colour — a five-day
    /// window is the common case, and its unit-wide bars are ~90pt.
    private static let maximumBarWidth: CGFloat = 26
    /// Gap kept between neighbouring bars once they are narrow enough that the
    /// cap no longer applies.
    private static let barGap: CGFloat = 2
    /// Thinner than this and a bar disappears into the background.
    private static let minimumBarWidth: CGFloat = 1

    /// How wide to draw each bar, given how many of them share the plot.
    ///
    /// `.automatic` would hand every bar its whole calendar unit, so the width
    /// has to be resolved here: take the per-bucket slice of the plot, leave a
    /// hairline gap, and clamp it to something a reader can still compare.
    /// Swift Charts keeps a fixed-width bar centred on the same anchor the
    /// automatic one used — the middle of its bucket — so narrowing a bar does
    /// not slide it off the day it represents.
    private func barWidth(
        points: [CostChartPoint],
        granularity: CostChartGranularity,
        window: ChartTimeWindow,
        plotWidth: CGFloat
    ) -> MarkDimension {
        guard plotWidth > 0, !points.isEmpty else { return .automatic }
        let span = window.visibleSpan
        guard span > 0 else { return .automatic }
        // Bucket count from the span rather than `points.count`: a range with
        // gaps in the data still has to draw the bars at their true pitch.
        let buckets = max(
            Double(points.count),
            span / granularity.approximateBucketSeconds
        )
        let pitch = CGFloat(Double(plotWidth) / max(1, buckets))
        let width = min(Self.maximumBarWidth, pitch - Self.barGap)
        return .fixed(max(Self.minimumBarWidth, width))
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
            Text(UsageModelNaming.canonicalDisplayName(model.modelName))
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.modelName)
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
            Text(UsageModelNaming.canonicalDisplayName(model.modelName))
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.modelName)
            Spacer(minLength: 8)
            Text(formatCost(model.costUSD))
                .font(.system(size: 9, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    /// TOTAL / AVG / PEAK plus the visible-extent note.
    ///
    /// The overview column is narrow enough that the four blocks cannot always
    /// share one line, and an `HStack` given less width than it asked for lets
    /// its children draw past the card rather than shrinking them. Offer the
    /// same content at three widths instead and let `ViewThatFits` pick: roomy
    /// row, tight row, then the note wrapped onto its own line. Every candidate
    /// reports a finite ideal width — the spacer keeps a real `minLength` — so
    /// the choice is made on what actually fits.
    @ViewBuilder
    private func footer(
        total: Double,
        average: Double,
        peak: Double,
        peakDate: Date?,
        resolved: CostResolvedGranularity,
        window: ChartTimeWindow
    ) -> some View {
        let note = extentNote(resolved: resolved, window: window)
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Self.footerRowSpacing) {
                metricsRow(
                    spacing: Self.footerRowSpacing,
                    total: total,
                    average: average,
                    peak: peak,
                    peakDate: peakDate,
                    resolved: resolved
                )
                Spacer(minLength: Self.footerRowSpacing)
                note
            }
            HStack(alignment: .top, spacing: Self.footerTightSpacing) {
                metricsRow(
                    spacing: Self.footerTightSpacing,
                    total: total,
                    average: average,
                    peak: peak,
                    peakDate: peakDate,
                    resolved: resolved
                )
                Spacer(minLength: Self.footerTightSpacing)
                note
            }
            VStack(alignment: .leading, spacing: 2) {
                metricsRow(
                    spacing: Self.footerTightSpacing,
                    total: total,
                    average: average,
                    peak: peak,
                    peakDate: peakDate,
                    resolved: resolved
                )
                note
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Gap between the metric blocks when the card has room for it.
    private static let footerRowSpacing: CGFloat = 16
    /// The same gap once the card is narrow enough that 16pt would push the
    /// extent note off the card.
    private static let footerTightSpacing: CGFloat = 8

    private func metricsRow(
        spacing: CGFloat,
        total: Double,
        average: Double,
        peak: Double,
        peakDate: Date?,
        resolved: CostResolvedGranularity
    ) -> some View {
        HStack(alignment: .top, spacing: spacing) {
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
        }
    }

    @ViewBuilder
    private func extentNote(
        resolved: CostResolvedGranularity,
        window: ChartTimeWindow
    ) -> some View {
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
        .fixedSize(horizontal: true, vertical: false)
    }

    /// One metric block. The three of them line up on two shared baselines —
    /// the label row and the value row — because the sub-label row is always
    /// laid out, blank when a metric has nothing to say there. Peak's date
    /// therefore hangs below the shared value baseline instead of pushing its
    /// own column up.
    @ViewBuilder
    private func metric(label: String, value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label.uppercased())
                .font(.system(size: max(8, density.subtitleFontSize - 2), weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.4)
            Text(value)
                .font(.system(size: density.bucketTitleFontSize, weight: .semibold, design: .rounded).monospacedDigit())
            Text(detail ?? " ")
                .font(.system(size: max(8, density.resetCountdownFontSize - 2)))
                .foregroundStyle(.tertiary)
                .opacity(detail == nil ? 0 : 1)
                .accessibilityHidden(detail == nil)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
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
            hourlyEnd: hourlyPoints.last?.date
        )
    }

    /// The full navigable extent: first recorded day through the end of today.
    ///
    /// The newest edge is the end of the current day rather than this instant so
    /// today's bar is drawn whole and every preset lands exactly on a
    /// calendar-day boundary — the same frame the old fixed-timeframe chart
    /// used. Floored at 24h so a first-run domain is still navigable.
    private func domainRange() -> ClosedRange<Date>? {
        guard let snapshot else { return nil }
        let calendar = Calendar.current
        var low = snapshot.dailyHistory.first?.date
        // The oldest hourly *bucket*, not the retention start: an empty
        // retained window is not history, and treating it as domain would open
        // a first-run chart on two weeks of nothing.
        if let firstHour = hourlyPoints.first?.date {
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

    /// The window a card opens on, derived purely from the data. Used both to
    /// seed `window` and to render the very first layout pass, before
    /// `rebuildWindow()` has had a chance to run.
    private func initialWindow() -> ChartTimeWindow? {
        guard let domain = domainRange(), domain.upperBound > domain.lowerBound else {
            return nil
        }
        return ChartTimeWindow(
            domainStart: domain.lowerBound,
            domainEnd: domain.upperBound,
            minimumSpan: Self.minimumSpan,
            visibleSpan: Self.resetSpan
        )
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
        window = initialWindow()
    }

    // MARK: - Range presets

    /// Presets are calendar spans, not multiples of 86 400 seconds: the domain
    /// ends at the end of today, so a span measured back from there with
    /// `Calendar` lands on a midnight even across a 23- or 25-hour DST day.
    ///
    /// Every preset is anchored at the domain's newest edge, which is what let
    /// the Yesterday pill go: it was the only one that wasn't.
    private func applyPreset(_ preset: CostRangePreset) {
        guard var current = window else { return }
        if let days = preset.days {
            current.jump(toSpan: CostChartWindowPolicy.anchoredSpan(days: days))
        } else {
            current.jump(toSpan: current.domainSpan)
        }
        window = current
        clearSelection()
    }

    /// Which pill (if any) describes the current window. Free navigation
    /// routinely lands between presets, and none being lit is the honest
    /// answer — not a reason to snap the window to the nearest one.
    ///
    /// Matched against the same calendar spans `applyPreset` produces, so a DST
    /// day's extra (or missing) hour cannot push a freshly applied preset out
    /// of its own tolerance.
    private func activePreset(window: ChartTimeWindow) -> CostRangePreset? {
        if window.coversDomain { return .all }
        guard window.isAtDomainEnd else { return nil }
        let span = window.visibleSpan
        return CostRangePreset.allCases.first { preset in
            guard let days = preset.days else { return false }
            let anchored = CostChartWindowPolicy.anchoredSpan(days: days)
            return abs(span - anchored) <= anchored * 0.03
        }
    }

    // MARK: - Granularity

    @ViewBuilder
    private func granularityControl(window: ChartTimeWindow, compressible: Bool = false) -> some View {
        let span = window.visibleSpan
        HStack(spacing: 1) {
            ForEach(CostGranularityOption.all) { option in
                let enabled = option.isEnabled(for: span)
                Button {
                    granularityMode = option.mode
                } label: {
                    granularityOptionLabel(
                        option,
                        selected: granularityMode == option.mode,
                        enabled: enabled
                    )
                }
                .buttonStyle(.vibeBar)
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
        // Fixed width keeps the five options evenly pitched; the compressible
        // candidate caps instead of pins, so a narrow card shrinks the segments
        // (the labels already carry `minimumScaleFactor`) rather than letting
        // the last two draw past the card.
        .frame(
            minWidth: compressible ? nil : Self.granularityControlWidth,
            maxWidth: Self.granularityControlWidth
        )
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
    }

    private static let granularityControlWidth = CGFloat(CostGranularityOption.all.count) * 32

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
    ///
    /// "Stops making sense" is two things: the option is no longer offered at
    /// this span, or it is still offered but would draw fewer bars than
    /// `CostChartGranularity.minimumManualBuckets` — a handful of slabs the
    /// user cannot read a trend from.
    private func demoteDisallowedGranularity(span: TimeInterval?) {
        guard case .manual(let choice) = granularityMode, let span else { return }
        if !CostChartGranularity.survivesManualSelection(choice, for: span) {
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
            requested = CostChartGranularity.survivesManualSelection(choice, for: span)
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

    /// Every per-hour bucket the snapshot carries, oldest first.
    ///
    /// `recentHourlyHistory` is a superset of the two day-scoped lanes, so it
    /// is used alone when present. Snapshots cached before the window widened
    /// have only the two days, and concatenating those is the fallback — never
    /// both, or every bucket for yesterday and today would be counted twice.
    private var hourlyPoints: [HourlyCostPoint] {
        guard let snapshot else { return [] }
        if !snapshot.recentHourlyHistory.isEmpty { return snapshot.recentHourlyHistory }
        return snapshot.yesterdayHourlyHistory + snapshot.todayHourlyHistory
    }

    /// The stretch the chart has hourly evidence for, as whole days.
    ///
    /// The lower bound comes from the snapshot's declared retention start when
    /// it has one: a day inside the retained window with no buckets was
    /// scanned and found idle, which is coverage, whereas the oldest *bucket*
    /// would leave an idle Monday looking like missing evidence and drop the
    /// chart back to daily bars. Older snapshots don't declare a start, so
    /// there the oldest bucket is all the proof there is.
    private var hourlyCoverage: ClosedRange<Date>? {
        guard let snapshot else { return nil }
        let points = hourlyPoints
        return CostChartWindowPolicy.hourlyCoverage(
            firstHour: snapshot.hourlyCoverageStart ?? points.first?.date,
            lastHour: points.last?.date
        )
    }

    /// Hours are drawn only when hourly evidence covers the *whole* visible
    /// range. Merely overlapping it would draw — and total — the covered days
    /// alone, leaving the rest to read as zero with nothing on screen saying
    /// so; the daily fallback plus the footer note is the honest answer.
    private func hasHourlyCoverage(in range: ClosedRange<Date>) -> Bool {
        CostChartWindowPolicy.covers(hourlyCoverage, range: range)
    }

    // MARK: - Data shaping

    /// Buckets that occupy visible time, oldest first. A bucket straddling an
    /// edge is kept whole: it is a real bar the user can see, and cutting its
    /// total to the visible slice would make the footer disagree with the
    /// chart. A bucket merely *touching* an edge is not visible at all and is
    /// left out — see `CostChartWindowPolicy.bucketOverlaps`.
    private func visiblePoints(
        window: ChartTimeWindow,
        granularity: CostChartGranularity
    ) -> [CostChartPoint] {
        guard let snapshot else { return [] }
        let range = window.visibleRange
        switch granularity {
        case .hour:
            return clip(hourlyPoints, date: \.date, bucket: clipBucket(.hour), to: range).map { point in
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
                // Canonical key: the snapshot can carry two raw ids that
                // display as the same model (a learned AntiGravity label and
                // its router alias), and two identical-looking rows in one
                // tooltip is a bug, not a breakdown.
                let key = UsageModelNaming.canonicalDisplayName(model.modelName)
                let current = bucketModels[key] ?? (0, 0)
                bucketModels[key] = (
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
            CostChartWindowPolicy.bucketOverlaps(
                start: element[keyPath: date],
                width: bucket,
                range: range
            )
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
/// every pill unlit, which a `Binding<CostRangePreset>` could not express.
private struct CostRangePresetBar: View {
    let active: CostRangePreset?
    let density: Theme.Density
    let action: (CostRangePreset) -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(CostRangePreset.allCases) { preset in
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
                .buttonStyle(.vibeBar)
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
