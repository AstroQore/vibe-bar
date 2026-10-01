import Charts
import SwiftUI
import VibeBarCore

private enum UsageChartMetric: String, CaseIterable, Identifiable {
    case tokens
    case cost

    var id: String { rawValue }
    var title: String { self == .tokens ? L10n.Usage.Tokens.title : L10n.Cost.title }
    var systemImage: String { self == .tokens ? "sum" : "dollarsign" }
}

private enum UsageTokenComponent: String, CaseIterable, Identifiable {
    case input
    case output
    case cacheWrite
    case cacheRead

    var id: String { rawValue }

    /// The same four names the hero card's legend uses: one page, one
    /// vocabulary for one number.
    var title: String {
        switch self {
        case .input: L10n.Usage.Tokens.input
        case .output: L10n.Usage.Tokens.output
        case .cacheWrite: L10n.Usage.Tokens.cacheWrite
        case .cacheRead: L10n.Usage.Tokens.cacheRead
        }
    }

    var color: Color {
        switch self {
        case .input: .blue
        case .output: .green
        case .cacheWrite: .orange
        case .cacheRead: .purple
        }
    }

    func value(in point: UsageTrendPoint) -> Int64 {
        switch self {
        case .input: point.freshInput
        case .output: point.output
        case .cacheWrite: point.cacheCreation
        case .cacheRead: point.cacheRead
        }
    }
}

/// Tokens or cost over the selected range, grouped by provider. This mirrors
/// the Overview chart's compact navigation vocabulary while keeping the
/// Usage filter as the single source for every card and table on the page.
struct UsageTrendChartView: View {
    let density: Theme.Density
    @ObservedObject var model: UsageStatsViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var metric: UsageChartMetric = .tokens
    @State private var hiddenTools: Set<ToolType> = []
    @State private var hoveredDate: Date?
    @State private var chartWindow: ChartTimeWindow?
    /// The plot area's width, rounded to whole points. Bars and axis labels
    /// are sized against it; the plot's width never depends on either, so
    /// measuring it cannot feed back into another layout pass.
    @State private var plotWidth: CGFloat = 0

    /// Floor for the leading axis-label column on both panes. Without a shared
    /// floor the token pane ("3.40M") and the cost pane ("$12") inset their
    /// plots differently and the two x axes stop lining up.
    private static let axisLabelWidth: CGFloat = 46
    private static let tooltipWidth: CGFloat = 186
    private static let mainMarkBudget = 1_200
    private static let navigatorMarkBudget = 480
    /// Stand-in until the plot reports its real width on first layout.
    private static let fallbackPlotWidth: CGFloat = 600

    private struct DomainKey: Equatable {
        let bucket: UsageTrendBucket
        let start: Date?
        let end: Date?
        let providers: [ToolType]
    }

    /// Everything the panes derive from the series at the current window,
    /// built once per (data, window, legend, metric) change.
    ///
    /// These used to be computed properties, which meant every body pass —
    /// including the one per pointer move that a hover update triggers —
    /// re-filtered and re-downsampled the whole series and resolved hover
    /// readings by linear scan. At 30 d × hourly that is ~720 aggregate
    /// buckets plus one series per provider, per frame. The plan is memoized
    /// on the exact inputs (array equality hits the COW identity fast path),
    /// so a hover or tooltip pass costs dictionary lookups and one binary
    /// search instead.
    private struct RenderPlan {
        var aggregateRendered: [UsageTrendPoint] = []
        var aggregateByStart: [Date: UsageTrendPoint] = [:]
        /// Visible buckets, ascending — the hover snap works on these.
        var visibleAnchors: [BucketAnchor] = []
        /// Where each visible bucket is drawn: the middle of its calendar
        /// span, so a bar covers the bucket it stands for instead of being
        /// centred on the boundary with the previous one.
        var centerByStart: [Date: Date] = [:]
        var startByCenter: [Date: Date] = [:]
        /// Axis tick positions (bucket centres), thinned to fit the labels.
        var axisTicks: [Date] = []
        var barWidth: CGFloat = ChartBarLayout.minimumWidth
        var providerRenderedByTool: [ToolType: [UsageTrendPoint]] = [:]
        var providerByStart: [ToolType: [Date: UsageTrendPoint]] = [:]
        var navigatorByTool: [ToolType: [UsageTrendPoint]] = [:]
        var navigationMaximum: Double = 0
        var visibleTokensTotal: Int64 = 0
        var visibleCostTotal: Int64 = 0
    }

    private struct BucketAnchor {
        let start: Date
        let center: Date
    }

    private struct PlanKey: Equatable {
        let series: UsageTrendSeries
        let visibleDomain: ClosedRange<Date>
        let hiddenTools: Set<ToolType>
        let metric: UsageChartMetric
        let plotWidth: CGFloat
    }

    /// Reference box so a memo hit/update during `body` never dirties view
    /// state; correctness comes from the key, not from invalidation timing.
    private final class PlanCache {
        var key: PlanKey?
        var plan: RenderPlan?
    }

    @State private var planCache = PlanCache()

    private var plan: RenderPlan {
        let key = PlanKey(
            series: series,
            visibleDomain: visibleDomain,
            hiddenTools: hiddenTools,
            metric: metric,
            plotWidth: plotWidth > 0 ? plotWidth : Self.fallbackPlotWidth
        )
        if let cached = planCache.plan, planCache.key == key {
            // Adopt the newest key: a reload can return identical points in
            // fresh storage, and re-keying keeps later compares on the O(1)
            // identity fast path instead of walking every element per pass.
            planCache.key = key
            return cached
        }
        let built = Self.buildPlan(key: key)
        planCache.key = key
        planCache.plan = built
        return built
    }

    private static func buildPlan(key: PlanKey) -> RenderPlan {
        let series = key.series
        let visibleDomain = key.visibleDomain
        var plan = RenderPlan()

        // A bucket is visible when any of it is: the window can cut a bar in
        // half, and dropping the half that still shows leaves a hole at the
        // edge. The nominal length is close enough for this test; centres
        // below use the real calendar span.
        let bucket = series.bucket
        let nominal = bucket.nominalSeconds
        let isVisible: (UsageTrendPoint) -> Bool = { point in
            point.bucketStart < visibleDomain.upperBound
                && point.bucketStart.addingTimeInterval(nominal) > visibleDomain.lowerBound
        }
        var visiblePoints: [UsageTrendPoint] = []
        var visibleIndices: [Int] = []
        for (index, point) in series.points.enumerated() where isVisible(point) {
            visiblePoints.append(point)
            visibleIndices.append(index)
        }
        plan.visibleAnchors = visiblePoints.map { point in
            let start = point.bucketStart
            let end = bucketEnd(after: start, bucket: bucket)
            return BucketAnchor(start: start, center: start.addingTimeInterval(end.timeIntervalSince(start) / 2))
        }
        for anchor in plan.visibleAnchors {
            plan.centerByStart[anchor.start] = anchor.center
            plan.startByCenter[anchor.center] = anchor.start
        }

        // Bars and labels share one pitch: the plot width over the number of
        // buckets the visible span holds, so zooming the brush widens both.
        let span = visibleDomain.upperBound.timeIntervalSince(visibleDomain.lowerBound)
        let slotCount = span / nominal
        let plotWidth = Double(key.plotWidth)
        plan.barWidth = CGFloat(ChartBarLayout.barWidth(plotWidth: plotWidth, slotCount: slotCount))
        let stride = ChartBarLayout.labelStride(
            slotWidth: ChartBarLayout.slotWidth(plotWidth: plotWidth, slotCount: slotCount),
            minimumLabelSpacing: bucket.minimumAxisLabelSpacing,
            steps: bucket.axisLabelSteps
        )
        // Strides count from the series start, not the window's, so a tick
        // stays on its bucket while the brush pans instead of hopping along.
        plan.axisTicks = zip(visibleIndices, plan.visibleAnchors)
            .filter { index, _ in index % stride == 0 }
            .map { $0.1.center }

        plan.aggregateRendered = UsageTrendSeriesDownsampling.points(
            visiblePoints,
            limit: max(2, mainMarkBudget / UsageTokenComponent.allCases.count)
        )
        plan.aggregateByStart = Dictionary(
            series.points.map { ($0.bucketStart, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let visibleProviders = series.providerSeries.filter { !key.hiddenTools.contains($0.tool) }
        let perProvider = max(2, mainMarkBudget / max(1, visibleProviders.count))
        for provider in visibleProviders {
            let points = provider.points.filter(isVisible)
            plan.providerRenderedByTool[provider.tool] =
                UsageTrendSeriesDownsampling.points(points, limit: perProvider)
            plan.providerByStart[provider.tool] = Dictionary(
                provider.points.map { ($0.bucketStart, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }

        let navigatorProviders = key.metric == .tokens ? series.providerSeries : visibleProviders
        let perNavigator = max(2, navigatorMarkBudget / max(1, visibleProviders.count))
        for provider in navigatorProviders {
            plan.navigatorByTool[provider.tool] =
                UsageTrendSeriesDownsampling.points(provider.points, limit: perNavigator)
        }
        plan.navigationMaximum = key.metric == .tokens
            ? series.points.map { Double($0.totalTokens) }.max() ?? 0
            : visibleProviders.flatMap(\.points).map { Double($0.costMicros) }.max() ?? 0

        let accessibilityPoints = key.metric == .tokens
            ? visiblePoints
            : visibleProviders.flatMap(\.points).filter(isVisible)
        plan.visibleTokensTotal = accessibilityPoints.reduce(Int64(0)) { $0 + $1.totalTokens }
        plan.visibleCostTotal = accessibilityPoints.reduce(Int64(0)) { $0 + $1.costMicros }
        return plan
    }

    private var series: UsageTrendSeries { model.trend }

    private var visibleProviders: [UsageProviderTrendSeries] {
        series.providerSeries.filter { !hiddenTools.contains($0.tool) }
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
        return first...max(bucketEnd(after: last), first.addingTimeInterval(1))
    }

    private var visibleDomain: ClosedRange<Date> {
        resolvedChartWindow.visibleRange
    }

    private var domainKey: DomainKey {
        DomainKey(
            bucket: series.bucket,
            start: series.points.first?.bucketStart,
            end: series.points.last?.bucketStart,
            providers: series.providerSeries.map(\.tool)
        )
    }

    private var resolvedChartWindow: ChartTimeWindow {
        chartWindow ?? ChartTimeWindow(
            domainStart: domain.lowerBound,
            domainEnd: domain.upperBound,
            minimumSpan: minimumChartSpan,
            visibleStart: domain.lowerBound,
            visibleEnd: domain.upperBound
        )
    }

    private var chartWindowBinding: Binding<ChartTimeWindow> {
        Binding(
            get: { resolvedChartWindow },
            set: { chartWindow = $0 }
        )
    }

    private var hoveredPoint: UsageTrendPoint? {
        guard let hoveredDate else { return nil }
        return plan.aggregateByStart[hoveredDate]
    }

    var body: some View {
        CardShell(density: density, spacing: density.cardSpacing) {
            header
            if hasData {
                if metric == .tokens { tokenPane } else { costPane }
                ChartBrushNavigator(
                    window: chartWindowBinding,
                    accent: .accentColor,
                    height: density.chartBrushHeight,
                    accessibilityDescription: L10n.Usage.Trend.navigatorLabel
                ) { geometry in
                    miniProviderPaths(in: geometry)
                }
                chartScopeRow
            } else {
                emptyState
            }
        }
        // The automatic granularity is chosen for this width: a wide card
        // earns finer buckets. The card's width is used rather than the
        // plot's because it does not move with the y-axis labels, which a
        // bucket change can widen — that would let the choice flip-flop.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width.rounded()
        } action: { width in
            model.trendChartWidth = width
        }
        .onChange(of: domainKey) { _, newValue in
            chartWindow = nil
            hoveredDate = nil
            let available = Set(newValue.providers)
            hiddenTools.formIntersection(available)
            if !available.isEmpty, hiddenTools.count == available.count {
                hiddenTools.removeAll()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.Usage.Trend.title)
                        .font(.system(size: max(8, density.subtitleFontSize - 2), weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.4)
                    Text(bucketSubtitle)
                        .font(.system(size: max(9, density.resetCountdownFontSize - 1)))
                        .foregroundStyle(.secondary)
                }
                metricSelector
                granularitySelector
                Spacer(minLength: 8)
                windowNavigator
            }
            if metric == .tokens {
                ScrollView(.horizontal) {
                    tokenLegend
                }
                .scrollIndicators(.never)
            } else if !series.providerSeries.isEmpty {
                ScrollView(.horizontal) {
                    providerLegend
                }
                .scrollIndicators(.never)
            }
        }
    }

    private var bucketSubtitle: String {
        switch series.bucket {
        case .hour: L10n.Usage.Trend.bucketHour
        case .sixHours: L10n.Usage.Trend.bucketSixHours
        case .day: L10n.Usage.Trend.bucketDay
        case .week: L10n.Usage.Trend.bucketWeek
        }
    }

    private var metricSelector: some View {
        HStack(spacing: 2) {
            ForEach(UsageChartMetric.allCases) { value in
                let selected = metric == value
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { metric = value }
                } label: {
                    Label(value.title, systemImage: value.systemImage)
                        .font(.system(size: max(9, density.segmentedFontSize - 1), weight: .semibold))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 9)
                        .frame(minHeight: 24)
                }
                .buttonStyle(.vibeBar)
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

    private var granularitySelector: some View {
        Menu {
            Picker(L10n.Usage.Trend.granularity, selection: $model.trendGranularity) {
                ForEach(Self.granularityOptions, id: \.self) { value in
                    Text(granularityTitle(value)).tag(value)
                        .disabled(!model.isTrendGranularityAvailable(value))
                }
            }
        } label: {
            Label(granularityTitle(model.trendGranularity), systemImage: "chart.bar.xaxis")
                .font(.system(size: max(10, density.segmentedFontSize - 1), weight: .semibold))
                .frame(minHeight: 22)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel(L10n.Usage.Trend.granularityLabel)
    }

    private var windowNavigator: some View {
        ControlGroup {
            Button { model.navigateWindow(by: -1) } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.canNavigateBackward)
            .help(L10n.Usage.Trend.previousWindow)
            Button { model.navigateWindow(by: 1) } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!model.canNavigateForward)
            .help(L10n.Usage.Trend.nextWindow)
            Button { model.resetWindow() } label: {
                Label(L10n.Usage.Trend.now, systemImage: "arrow.clockwise")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!model.canNavigateForward)
            .help(L10n.Usage.Trend.nowHelp)
        }
        .font(.system(size: 10, weight: .semibold))
        .controlSize(.small)
    }

    private var providerLegend: some View {
        HStack(spacing: 6) {
            ForEach(series.providerSeries) { provider in
                let visible = !hiddenTools.contains(provider.tool)
                let color = Theme.providerAccent(for: provider.tool)
                Button {
                    toggle(provider.tool)
                } label: {
                    HStack(spacing: 4) {
                        Capsule()
                            .fill(color)
                            .frame(width: 10, height: 4)
                        Text(provider.tool.menuTitle)
                            .font(.system(size: max(8, density.segmentedFontSize - 2), weight: .semibold))
                    }
                    .padding(.horizontal, 7)
                    .frame(minHeight: 20)
                }
                .buttonStyle(.vibeBar)
                .background(
                    Capsule().fill(color.opacity(visible ? 0.14 : 0.04))
                )
                .opacity(visible ? 1 : 0.68)
                .saturation(visible ? 1 : 0.45)
                .help(visible
                    ? L10n.Usage.Trend.hideProvider(provider: provider.tool.displayName)
                    : L10n.Usage.Trend.showProvider(provider: provider.tool.displayName))
                .accessibilityAddTraits(visible ? [.isSelected] : [])
            }
        }
    }

    private var tokenLegend: some View {
        HStack(spacing: 10) {
            ForEach(UsageTokenComponent.allCases) { component in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(component.color)
                        .frame(width: 7, height: 7)
                    Text(component.title)
                        .font(.system(size: max(8, density.segmentedFontSize - 2), weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func toggle(_ tool: ToolType) {
        if hiddenTools.contains(tool) {
            hiddenTools.remove(tool)
        } else if hiddenTools.count < series.providerSeries.count - 1 {
            // Never let the last provider go: an empty chart reads as missing
            // data rather than as "you turned every series off".
            hiddenTools.insert(tool)
        }
    }

    // MARK: - Panes

    private var tokenPane: some View {
        // Resolved once per pass: the marks below look up hundreds of
        // centres, and each `plan` access re-checks the memo key.
        let plan = self.plan
        let bucket = series.bucket
        return Chart {
            ForEach(plan.aggregateRendered, id: \.bucketStart) { point in
                let center = Self.center(of: point.bucketStart, in: plan, bucket: bucket)
                ForEach(UsageTokenComponent.allCases) { component in
                    BarMark(
                        x: .value("Time", center),
                        y: .value("Tokens", component.value(in: point)),
                        width: .fixed(plan.barWidth),
                        stacking: .standard
                    )
                    .foregroundStyle(component.color.gradient)
                    .cornerRadius(3)
                }
            }
            if let hoveredDate {
                RuleMark(x: .value("Time", center(of: hoveredDate)))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: visibleDomain)
        .chartPlotStyle { plot in
            plot
                .clipped()
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width.rounded()
                } action: { width in
                    plotWidth = width
                }
        }
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
        .chartXAxis { bucketAxis }
        .chartOverlay { proxy in
            hoverSurface(proxy: proxy) { geometry in
                if let point = hoveredPoint {
                    tooltip(point)
                        .offset(x: tooltipOffset(point.bucketStart, proxy: proxy, geometry: geometry))
                }
            }
        }
        .frame(height: density.overviewCostChartHeight)
        .accessibilityLabel(L10n.Usage.Trend.tokensChartLabel)
        .accessibilityValue(chartAccessibilityValue)
    }

    /// Ticks sit on bar centres and are labelled with the bucket they
    /// stand for (its start), thinned so neighbouring labels never collide.
    private var bucketAxis: some AxisContent {
        let startByCenter = plan.startByCenter
        let format = axisFormat
        return AxisMarks(values: plan.axisTicks) { value in
            AxisGridLine().foregroundStyle(.secondary.opacity(0.10))
            AxisTick(length: 3).foregroundStyle(.secondary.opacity(0.35))
            AxisValueLabel(centered: false) {
                if let center = value.as(Date.self) {
                    Text((startByCenter[center] ?? center).formatted(format))
                        .font(.system(size: 9))
                }
            }
        }
    }

    /// Where a bucket is drawn. Visible buckets come from the plan; anything
    /// else (a hover racing a window change) falls back to the nominal middle.
    private func center(of start: Date) -> Date {
        Self.center(of: start, in: plan, bucket: series.bucket)
    }

    private static func center(of start: Date, in plan: RenderPlan, bucket: UsageTrendBucket) -> Date {
        plan.centerByStart[start] ?? start.addingTimeInterval(bucket.nominalSeconds / 2)
    }

    private var costPane: some View {
        let plan = self.plan
        let bucket = series.bucket
        return Chart {
            ForEach(visibleProviders) { provider in
                let color = Theme.providerAccent(for: provider.tool)
                ForEach(plan.providerRenderedByTool[provider.tool] ?? [], id: \.bucketStart) { point in
                    let center = Self.center(of: point.bucketStart, in: plan, bucket: bucket)
                    AreaMark(
                        x: .value("Time", center),
                        y: .value("Cost", costUSD(point)),
                        series: .value("Provider", provider.tool.rawValue)
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(areaGradient(color))
                    LineMark(
                        x: .value("Time", center),
                        y: .value("Cost", costUSD(point)),
                        series: .value("Provider", provider.tool.rawValue)
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                }
                if let hoveredDate, let point = providerPoint(for: provider, at: hoveredDate) {
                    PointMark(
                        x: .value("Time", center(of: point.bucketStart)),
                        y: .value("Cost", costUSD(point))
                    )
                    .foregroundStyle(color)
                    .symbolSize(34)
                }
            }
            if let hoveredDate {
                RuleMark(x: .value("Time", center(of: hoveredDate)))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: visibleDomain)
        .chartPlotStyle { plot in
            plot
                .clipped()
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width.rounded()
                } action: { width in
                    plotWidth = width
                }
        }
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
        .chartXAxis { bucketAxis }
        .chartOverlay { proxy in
            hoverSurface(proxy: proxy) { geometry in
                if let point = hoveredPoint {
                    costPill(point)
                        .offset(x: costPillOffset(point.bucketStart, proxy: proxy, geometry: geometry))
                }
            }
        }
        .frame(height: density.overviewCostChartHeight)
        .accessibilityLabel(L10n.Usage.Trend.costChartLabel)
        .accessibilityValue(chartAccessibilityValue)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L10n.Usage.Trend.empty)
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
        // Runs once per pointer move; the starts are ascending, so binary
        // search instead of a scan over every visible bucket.
        ChartSampleSearch.nearest(
            in: plan.visibleAnchors,
            to: date,
            tolerance: .greatestFiniteMagnitude,
            time: \.center
        )?.start
    }

    private func tooltip(_ point: UsageTrendPoint) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(tooltipDate(point.bucketStart))
                    .font(.system(size: 10, weight: .semibold))
                Spacer(minLength: 4)
                Text(UsageFormatting.formatMicroUSD(
                    metric == .tokens ? point.costMicros : visibleCostMicros(at: point.bucketStart)
                ))
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
            }
            Divider().opacity(0.3)
            if metric == .tokens {
                ForEach(UsageTokenComponent.allCases) { component in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(component.color)
                            .frame(width: 7, height: 7)
                        Text(component.title)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(UsageFormatting.compactTokens(component.value(in: point)))
                            .font(.system(size: 9, design: .rounded).monospacedDigit())
                    }
                }
            } else {
                ForEach(visibleProviders) { provider in
                    let providerPoint = providerPoint(for: provider, at: point.bucketStart)
                    HStack(spacing: 6) {
                        Capsule()
                            .fill(Theme.providerAccent(for: provider.tool))
                            .frame(width: 8, height: 4)
                        Text(provider.tool.menuTitle)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(UsageFormatting.formatMicroUSD(providerPoint?.costMicros ?? 0))
                            .font(.system(size: 9, design: .rounded).monospacedDigit())
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(width: Self.tooltipWidth)
        .workbenchOverlaySurface(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.top, 4)
    }

    private func costPill(_ point: UsageTrendPoint) -> some View {
        Text(UsageFormatting.formatMicroUSD(visibleCostMicros(at: point.bucketStart)))
            .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
            .padding(.horizontal, 9)
            .frame(minHeight: 20)
            .workbenchOverlaySurface(in: Capsule())
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
        let x = (proxy.position(forX: center(of: date)) ?? 0) + plotMinX
        return min(max(0, x - width / 2), max(0, geometry.size.width - width))
    }

    // MARK: - Formatting

    private func costUSD(_ point: UsageTrendPoint) -> Double {
        Double(point.costMicros) / 1_000_000
    }

    private func providerPoint(
        for provider: UsageProviderTrendSeries,
        at date: Date
    ) -> UsageTrendPoint? {
        plan.providerByStart[provider.tool]?[date]
    }

    private func visibleCostMicros(at date: Date) -> Int64 {
        visibleProviders.reduce(Int64(0)) { total, provider in
            total + (providerPoint(for: provider, at: date)?.costMicros ?? 0)
        }
    }

    private func navigatorPoints(for provider: UsageProviderTrendSeries) -> [UsageTrendPoint] {
        plan.navigatorByTool[provider.tool] ?? []
    }

    private func areaGradient(_ color: Color) -> LinearGradient {
        LinearGradient(
            colors: [color.opacity(0.26), color.opacity(0.025)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var minimumChartSpan: TimeInterval {
        switch series.bucket {
        case .hour: 2 * 3_600
        case .sixHours: 2 * 6 * 3_600
        case .day: 2 * 86_400
        case .week: 2 * 7 * 86_400
        }
    }

    private func bucketEnd(after start: Date) -> Date {
        Self.bucketEnd(after: start, bucket: series.bucket)
    }

    private static func bucketEnd(after start: Date, bucket: UsageTrendBucket) -> Date {
        let calendar = Calendar.current
        switch bucket {
        case .hour:
            return calendar.date(byAdding: .hour, value: 1, to: start)
                ?? start.addingTimeInterval(3_600)
        case .sixHours:
            return calendar.date(byAdding: .hour, value: 6, to: start)
                ?? start.addingTimeInterval(6 * 3_600)
        case .day:
            return calendar.date(byAdding: .day, value: 1, to: start)
                ?? start.addingTimeInterval(86_400)
        case .week:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: start)
                ?? start.addingTimeInterval(7 * 86_400)
        }
    }

    private func miniProviderPaths(in geometry: ChartBrushGeometry) -> some View {
        let maximum = navigationMaximum
        return ZStack {
            ForEach(navigatorProviders) { provider in
                Path { path in
                    var hasPoint = false
                    for point in navigatorPoints(for: provider) {
                        let value = metric == .tokens
                            ? Double(point.totalTokens)
                            : Double(point.costMicros)
                        let position = CGPoint(
                            x: geometry.x(for: point.bucketStart),
                            y: geometry.y(forFraction: maximum > 0 ? value / maximum : 0)
                        )
                        if hasPoint { path.addLine(to: position) } else { path.move(to: position) }
                        hasPoint = true
                    }
                }
                .stroke(
                    Theme.providerAccent(for: provider.tool).opacity(0.78),
                    style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
                )
            }
        }
    }

    private var navigationMaximum: Double {
        plan.navigationMaximum
    }

    private var navigatorProviders: [UsageProviderTrendSeries] {
        metric == .tokens ? series.providerSeries : visibleProviders
    }

    private var chartScopeRow: some View {
        HStack(spacing: 8) {
            Text(L10n.Usage.Trend.scopeHint)
                .font(.system(size: max(9, density.resetCountdownFontSize - 1)))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if !resolvedChartWindow.coversDomain {
                Button(L10n.Usage.Trend.fit) {
                    chartWindow = nil
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .semibold))
                .help(L10n.Usage.Trend.fitHelp)
            }
        }
    }

    private var chartAccessibilityValue: String {
        L10n.Usage.Trend.accessibilitySummary(
            count: visibleProviders.count,
            tokens: UsageFormatting.compactTokens(plan.visibleTokensTotal),
            cost: UsageFormatting.formatMicroUSD(plan.visibleCostTotal)
        )
    }

    /// Automatic first, then every explicit bucket.
    private static let granularityOptions: [UsageTrendBucket?] =
        [nil] + UsageTrendBucket.allCases.map { $0 }

    private func granularityTitle(_ value: UsageTrendBucket?) -> String {
        switch value {
        case .none: L10n.Common.auto
        case .hour: L10n.Usage.Trend.granularityHourly
        case .sixHours: L10n.Usage.Trend.granularitySixHourly
        case .day: L10n.Usage.Trend.granularityDaily
        case .week: L10n.Usage.Trend.granularityWeekly
        }
    }

    /// The app's language, not the process locale. A bare `.dateTime` style
    /// asks `Locale.current`, so a Chinese build on an English Mac drew "Aug
    /// 17" along the axis of an otherwise translated page.
    private var axisFormat: Date.FormatStyle {
        switch series.bucket {
        case .hour: .dateTime.hour().locale(AppLocale.current)
        case .sixHours: .dateTime.month(.abbreviated).day().hour().locale(AppLocale.current)
        case .day: .dateTime.month(.abbreviated).day().locale(AppLocale.current)
        case .week: .dateTime.month(.abbreviated).day().locale(AppLocale.current)
        }
    }

    private func tooltipDate(_ date: Date) -> String {
        let formatter = series.bucket == .hour || series.bucket == .sixHours ? Self.hourFormatter : Self.dayFormatter
        return formatter.string(from: date)
    }

    private static var hourFormatter: DateFormatter {
        AppLocale.dateFormatter(template: "MMMdHHmm")
    }
    private static var dayFormatter: DateFormatter {
        AppLocale.dateFormatter(template: "EEEMMMd")
    }

}
