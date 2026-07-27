import SwiftUI
import Charts
import VibeBarCore

/// One headed group of independently resettable quotas.
///
/// Claude splits its weekly allowance across model scopes ("Fable", "Opus", …)
/// and Codex splits its by limit name; each of those is a group, and the
/// ungrouped remainder (Claude's 5 Hours + Weekly) is a group too — the one
/// Subscription Utilization prints no heading for.
struct QuotaBucketGroup: Identifiable, Equatable {
    let id: String
    let title: String?
    let buckets: [QuotaBucket]
}

/// Single source of truth for how a provider page splits an account's quotas
/// into headed groups.
///
/// `SubscriptionUtilizationView` prints the heading above the first row of each
/// group; the quota-history cards draw one chart per group. Both have to agree
/// on where a group starts and what it is called, so both read this.
enum QuotaBucketGrouping {
    /// The heading a bucket belongs under, or `nil` for the ungrouped rows the
    /// utilization card prints without a heading.
    ///
    /// `pageTool` is the provider page being rendered and `itemTool` the tool
    /// the bucket actually came from — they differ only for linked products
    /// (AntiGravity on the Gemini page).
    static func title(pageTool: ToolType, itemTool: ToolType, bucket: QuotaBucket) -> String? {
        if let title = bucket.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        if pageTool == .gemini, itemTool == .gemini {
            return "Gemini Chat"
        }
        return nil
    }

    /// Stable identity for the run of rows a heading covers.
    ///
    /// Account- and tool-scoped because one card can stack two products'
    /// quotas (Gemini Web + AntiGravity), and `nil`-safe because the ungrouped
    /// run (Claude's 5 Hours + Weekly — "all models") is a group for charting
    /// purposes even though the utilization card prints no heading above it.
    static func key(accountId: String?, itemTool: ToolType, title: String?) -> String {
        "\(accountId ?? "")|\(itemTool.rawValue)|\(title ?? "")"
    }
}

/// One drawable point of the forecast's uncertainty band.
private struct QuotaBandPoint: Identifiable {
    let id: String
    let seriesKey: String
    let time: Date
    let low: Double
    let high: Double
}

/// Everything one bucket contributes to the plot, already clipped and thinned.
private struct QuotaBucketLines: Identifiable {
    let id: String
    let color: Color
    let forecastColor: Color
    let actual: [QuotaChartLinePoint]
    let actualBridges: [QuotaChartLinePoint]
    let forecast: [QuotaChartLinePoint]
    let forecastBridges: [QuotaChartLinePoint]
}

/// What the hover crosshair resolved to on one bucket's lines.
private struct QuotaHoverBucketReading: Identifiable {
    let id: String
    let title: String
    let color: Color
    let actual: Double?
    let pace: Double?
    let forecast: Double?

    var isEmpty: Bool { actual == nil && pace == nil && forecast == nil }
}

/// What the hover crosshair resolved to at one instant, across the group.
private struct QuotaHoverReading {
    let time: Date
    let buckets: [QuotaHoverBucketReading]

    var isEmpty: Bool { buckets.allSatisfy(\.isEmpty) }
}

/// Everything that decides the shape of the chart. Rebuilding is keyed on this
/// rather than on the raw arrays: a quota refresh appends one point, and only
/// then is it worth re-segmenting the series.
private struct QuotaSeriesSignature: Equatable {
    struct Entry: Equatable {
        var bucketId: String
        var fillCount: Int
        var fillStart: Date?
        var fillEnd: Date?
        var forecastCount: Int
        var forecastEnd: Date?
    }

    var entries: [Entry]
}

/// Quota history over time for one group of quotas: what was left, what an even
/// burn would have left, and what the forecast said would be left at reset —
/// each drawn only where it was actually observed.
///
/// The card follows its group the way "Reset history" follows its bucket: one
/// chart per heading, no picker. Buckets that reset on different schedules but
/// belong to the same scope (Claude's 5 Hours and Weekly, say) overlay in one
/// plot and are told apart by hue, because the question "how is this scope
/// doing" is one question.
///
/// The lines answer different questions and are deliberately not merged:
/// `actual` is evidence, `pace` is the wall-clock reference, and `forecast` is
/// the projection *as recorded at the time*, never recomputed with hindsight.
/// Between quota windows there is simply no line, which is why the builder
/// hands back segments instead of flat arrays.
///
/// Navigation is the approved thumbnail + gesture hybrid: a brush strip covers
/// the whole domain, while drag-pan and pinch-zoom work directly on the plot.
///
/// `Equatable` on purpose. The chart is rendered inside Subscription
/// Utilization, whose call sites wrap it in `TimelineView(.periodic(by: 30))`
/// so the pace rows can re-read the wall clock. Every tick re-proposes this
/// view; without `.equatable()` each tick would re-segment, re-clip and
/// re-thin thousands of marks and could land in the middle of a pan. The
/// comparison covers exactly the inputs that change what is drawn — the
/// `@State`/`@EnvironmentObject` storage is deliberately excluded, because
/// those invalidate the view through their own dependency, not through the
/// parent's diff.
///
/// The other half of that contract: **this view must never read the current
/// time**. There is no `now` parameter and no `Date()` anywhere in it — every
/// "current" reading in the legend comes from the newest recorded sample, so a
/// tick genuinely has nothing new to say.
struct QuotaHistoryChartView: View, Equatable {
    let tool: ToolType
    let accountId: String
    let group: QuotaBucketGroup
    let density: Theme.Density
    /// Set when a page shows more than one of these charts for *different
    /// products* and "Quota history" alone would not say whose.
    var titleOverride: String? = nil
    /// Print the group's name under the title. Set when the chart is shown
    /// away from its group's heading and needs to name itself.
    var showsGroupTitle: Bool = false
    /// Drawn inside the utilization card, directly under the group's rows —
    /// so no card chrome of its own, and a quiet caption-sized title, exactly
    /// like the "Reset history" strip it sits beside.
    var isEmbedded: Bool = false

    @EnvironmentObject var quotaService: QuotaService

    static func == (lhs: QuotaHistoryChartView, rhs: QuotaHistoryChartView) -> Bool {
        lhs.tool == rhs.tool
            && lhs.accountId == rhs.accountId
            && lhs.group == rhs.group
            && lhs.density == rhs.density
            && lhs.titleOverride == rhs.titleOverride
            && lhs.showsGroupTitle == rhs.showsGroupTitle
            && lhs.isEmbedded == rhs.isEmbedded
    }

    @State private var forecastByBucket: [String: [ForecastTimelinePoint]] = [:]
    @State private var seriesByBucket: [String: QuotaHistorySeries] = [:]
    @State private var lookupByBucket: [String: BucketLookup] = [:]
    @State private var miniSegments: [[QuotaHistorySample]] = []
    @State private var window: ChartTimeWindow?
    @State private var windowKey: String?
    @State private var initialSpan: TimeInterval = 24 * 3_600
    @State private var hoverDate: Date?
    @State private var panBase: ChartTimeWindow?
    @State private var magnifyBase: ChartTimeWindow?

    /// Hue per bucket inside one group, reused from the accents the rest of the
    /// app already spends: the healthy-quota green, the forecast blue, the
    /// "watch" amber, AntiGravity's violet, Claude's coral. First bucket green
    /// keeps a single-quota chart looking exactly like it did before groups.
    private static let bucketPalette: [Color] = [
        Color(red: 0.18, green: 0.74, blue: 0.55),
        Color(red: 0.20, green: 0.56, blue: 0.88),
        Color(red: 0.97, green: 0.62, blue: 0.20),
        Color(red: 0.55, green: 0.40, blue: 0.92),
        Color(red: 0.93, green: 0.40, blue: 0.40)
    ]
    private static let paceColor = Color.secondary

    /// Marks per line inside the visible window. Beyond this the strokes stop
    /// gaining detail and start costing frames on a zoomed-out weekly domain —
    /// so the budget is shared out across however many buckets overlay, and
    /// then again across the segments each bucket is drawn in.
    private static let visibleMarkBudget = 520
    private static let minimumMarkBudget = 140
    private static let miniMarkLimit = 160
    /// Past this many reset lines the plot reads as a picket fence rather than
    /// as a set of boundaries, so a zoomed-out five-hour quota drops them.
    private static let visibleResetLimit = 24

    var body: some View {
        let buckets = bucketsWithHistory
        let drawable = buckets.first.flatMap { first in
            window.flatMap { $0.domainSpan > 0 ? (first, $0) : nil }
        }

        Group {
            if isEmbedded {
                // Nothing to draw yet: stay silent rather than repeating a
                // "history builds up" note under every quota scope in the card.
                // The Reset history strip on the row above already says it.
                if let drawable {
                    VStack(alignment: .leading, spacing: 5) {
                        embeddedHeader
                        chartBody(buckets: buckets, primary: drawable.0, window: drawable.1)
                    }
                    .padding(.top, 5)
                }
            } else {
                VStack(alignment: .leading, spacing: density.cardSpacing) {
                    cardHeader
                    if let drawable {
                        chartBody(buckets: buckets, primary: drawable.0, window: drawable.1)
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
            }
        }
        .task(id: forecastLoadKey) {
            await loadForecastPoints()
        }
        .onChange(of: seriesSignature, initial: true) { _, _ in
            rebuild()
        }
    }

    // MARK: - Header

    /// Embedded title, styled like the "Reset history" caption directly above
    /// it — the chart is a continuation of the group's rows, not a new card
    /// competing with the section heading.
    private var embeddedHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Quota history")
                .font(.system(size: max(9, density.subtitleFontSize - 2), weight: .medium))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            rangePills
        }
    }

    private var cardHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(titleOverride ?? "Quota history")
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                if showsGroupTitle, let groupTitle = group.title {
                    // Same treatment as the group heading in Subscription
                    // Utilization, so the two surfaces read as one section.
                    Text(groupTitle)
                        .font(.system(size: max(9, density.subtitleFontSize - 1), weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .tracking(0.4)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            rangePills
        }
    }

    private var emptyNote: some View {
        Text("Quota history builds up as refreshes come in.")
            .font(.system(size: density.subtitleFontSize))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
    }

    // MARK: - Chart

    @ViewBuilder
    private func chartBody(
        buckets: [QuotaBucket],
        primary: QuotaBucket,
        window: ChartTimeWindow
    ) -> some View {
        let binding = Binding<ChartTimeWindow>(
            get: { self.window ?? window },
            set: { self.window = $0 }
        )
        let visible = window.visibleRange
        let isSingle = buckets.count == 1
        // One budget per bucket, shared out across however many segments that
        // bucket happens to be drawn in.
        let budget = max(Self.minimumMarkBudget, Self.visibleMarkBudget / max(1, buckets.count))
        let lines = bucketLines(buckets: buckets, range: visible, budget: budget)
        let primarySeries = seriesByBucket[primary.id] ?? .empty
        // Only a single-bucket chart can afford the wall-clock reference and
        // the uncertainty band: two of them overlaid is mud, and the pace
        // reading moves into the hover tooltip instead.
        let pacePoints = isSingle
            ? linePoints(primarySeries.pace, kind: "pace", range: visible, budget: budget)
            : []
        let paceBridges = isSingle
            ? bridgePoints(
                primarySeries.pace,
                time: { $0.time },
                value: { $0.remainingPercent },
                kind: "pace",
                range: visible
            )
            : []
        let bandPoints = isSingle
            ? forecastBandPoints(primarySeries.forecast, range: visible, budget: budget)
            : []
        let resets = resetMarks(primarySeries: primarySeries, range: visible)

        VStack(alignment: .leading, spacing: 6) {
            legend(buckets: buckets)

            Chart {
                ForEach(bandPoints) { point in
                    AreaMark(
                        x: .value("Time", point.time),
                        yStart: .value("Low", point.low),
                        yEnd: .value("High", point.high),
                        series: .value("Band", point.seriesKey)
                    )
                    .foregroundStyle(forecastTint(Self.bucketPalette[0]).opacity(0.08))
                }
                ForEach(resets, id: \.self) { reset in
                    RuleMark(x: .value("Reset", reset))
                        .foregroundStyle(Color.primary.opacity(0.16))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                ForEach(paceBridges) { point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("Left", point.value),
                        series: .value("Line", point.seriesKey)
                    )
                    .foregroundStyle(Self.paceColor.opacity(QuotaChartMarks.bridgeOpacity))
                    .lineStyle(QuotaChartMarks.bridgeStroke)
                }
                ForEach(pacePoints) { point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("Left", point.value),
                        series: .value("Line", point.seriesKey)
                    )
                    .foregroundStyle(Self.paceColor.opacity(0.85))
                    .lineStyle(StrokeStyle(lineWidth: 1.6, dash: [5, 4]))
                }
                ForEach(lines) { line in
                    ForEach(line.forecastBridges) { point in
                        LineMark(
                            x: .value("Time", point.time),
                            y: .value("Left", point.value),
                            series: .value("Line", point.seriesKey)
                        )
                        .foregroundStyle(line.forecastColor.opacity(QuotaChartMarks.bridgeOpacity))
                        .lineStyle(QuotaChartMarks.bridgeStroke)
                    }
                }
                ForEach(lines) { line in
                    ForEach(line.forecast) { point in
                        LineMark(
                            x: .value("Time", point.time),
                            y: .value("Left", point.value),
                            series: .value("Line", point.seriesKey)
                        )
                        .foregroundStyle(line.forecastColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: [2, 3.4]))
                    }
                }
                ForEach(lines) { line in
                    ForEach(line.actualBridges) { point in
                        LineMark(
                            x: .value("Time", point.time),
                            y: .value("Left", point.value),
                            series: .value("Line", point.seriesKey)
                        )
                        .foregroundStyle(line.color.opacity(QuotaChartMarks.bridgeOpacity))
                        .lineStyle(QuotaChartMarks.bridgeStroke)
                    }
                }
                ForEach(lines) { line in
                    ForEach(line.actual) { point in
                        LineMark(
                            x: .value("Time", point.time),
                            y: .value("Left", point.value),
                            series: .value("Line", point.seriesKey)
                        )
                        .foregroundStyle(line.color)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .chartXScale(domain: visible)
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                    AxisValueLabel {
                        if let raw = value.as(Double.self) {
                            Text("\(Int(raw))%")
                                .font(.system(size: 9, design: .rounded).monospacedDigit())
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.10))
                    AxisValueLabel()
                        .font(.system(size: 9))
                }
            }
            .chartOverlay { proxy in
                interactionOverlay(
                    proxy: proxy,
                    buckets: buckets,
                    primary: primary,
                    window: binding
                )
            }
            .frame(height: density.quotaHistoryChartHeight)

            ChartBrushNavigator(
                window: binding,
                accent: Self.bucketPalette[0],
                height: density.chartBrushHeight,
                accessibilityDescription: "Quota history range navigator"
            ) { geometry in
                miniPath(in: geometry)
            }

            Text(scopeNote(buckets: buckets, window: window))
                .font(.system(size: max(8, density.resetCountdownFontSize - 1)))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    private func miniPath(in geometry: ChartBrushGeometry) -> some View {
        ZStack {
            // Connectors first so the observed line always sits on top of them.
            miniBridgePath(in: geometry)
                .stroke(
                    Self.bucketPalette[0].opacity(0.28),
                    style: StrokeStyle(lineWidth: 0.7, lineCap: .round)
                )
            Path { path in
                for segment in miniSegments {
                    guard let first = segment.first else { continue }
                    path.move(to: miniPoint(first, in: geometry))
                    for sample in segment.dropFirst() {
                        path.addLine(to: miniPoint(sample, in: geometry))
                    }
                }
            }
            .stroke(
                Self.bucketPalette[0].opacity(0.75),
                style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
            )
        }
    }

    /// Straight hops across the holes in the brush mini. Thin and faint rather
    /// than dashed — at this scale a dash pattern is just noise.
    private func miniBridgePath(in geometry: ChartBrushGeometry) -> Path {
        Path { path in
            guard miniSegments.count > 1 else { return }
            for index in 0..<(miniSegments.count - 1) {
                guard let tail = miniSegments[index].last,
                      let head = miniSegments[index + 1].first
                else { continue }
                path.move(to: miniPoint(tail, in: geometry))
                path.addLine(to: miniPoint(head, in: geometry))
            }
        }
    }

    private func miniPoint(_ sample: QuotaHistorySample, in geometry: ChartBrushGeometry) -> CGPoint {
        CGPoint(
            x: geometry.x(for: sample.time),
            y: geometry.y(forFraction: sample.remainingPercent / 100)
        )
    }

    /// Reset lines for the plot. In a multi-bucket chart only the
    /// shortest-window quota's boundaries are drawn — its sawtooth is the one a
    /// reader is trying to line up, and stacking a second schedule on top of it
    /// just stripes the plot.
    private func resetMarks(
        primarySeries: QuotaHistorySeries,
        range: ClosedRange<Date>
    ) -> [Date] {
        let visible = primarySeries.resetBoundaries.filter { range.contains($0) }
        return visible.count > Self.visibleResetLimit ? [] : visible
    }

    // MARK: - Legend

    private enum LegendStroke {
        case solid
        case dashed
        case dotted
    }

    /// One legend column: a stroke swatch, what it is, where it stands now, and
    /// an optional second reading underneath.
    private struct LegendBlock: Identifiable {
        let id: String
        let stroke: LegendStroke
        let color: Color
        let label: String
        let value: String
        let detail: String?
    }

    /// Legend + current readings.
    ///
    /// Laid out as metric columns rather than a run of inline chips so the
    /// swatch row, the percentage row, and the at-reset row each sit on one
    /// shared baseline no matter how long a bucket's name is — the same fix the
    /// cost card's footer uses. The detail row is laid out for every column
    /// (blank when a bucket has no projection) so one forecast cannot push its
    /// own column up out of line.
    @ViewBuilder
    private func legend(buckets: [QuotaBucket]) -> some View {
        let blocks = legendBlocks(buckets: buckets)
        let showsDetail = blocks.contains { $0.detail != nil }
        let hint = forecastHint(blocks: blocks)
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                legendRow(blocks, spacing: 14, showsDetail: showsDetail)
                Spacer(minLength: 14)
                hint
            }
            HStack(alignment: .top, spacing: 8) {
                legendRow(blocks, spacing: 8, showsDetail: showsDetail)
                Spacer(minLength: 8)
                hint
            }
            VStack(alignment: .leading, spacing: 2) {
                legendRow(blocks, spacing: 8, showsDetail: showsDetail)
                hint.frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(blocks) { block in
                    legendBlock(block, showsDetail: showsDetail)
                }
                hint.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func legendRow(
        _ blocks: [LegendBlock],
        spacing: CGFloat,
        showsDetail: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(blocks) { block in
                legendBlock(block, showsDetail: showsDetail)
            }
        }
    }

    private func legendBlocks(buckets: [QuotaBucket]) -> [LegendBlock] {
        var blocks: [LegendBlock] = buckets.enumerated().map { index, bucket in
            LegendBlock(
                id: "bucket-\(bucket.id)",
                stroke: .solid,
                color: color(at: index),
                label: bucket.title,
                value: currentRemainingLabel(bucket: bucket),
                detail: currentForecastLabel(bucket: bucket).map { "\($0) at reset" }
            )
        }
        // The wall-clock reference only gets a line (and therefore a legend
        // entry) when it is the sole thing sharing the plot with one quota.
        if buckets.count == 1, let pace = currentPaceLabel(bucket: buckets[0]) {
            blocks.append(
                LegendBlock(
                    id: "pace",
                    stroke: .dashed,
                    color: Self.paceColor,
                    label: "Time-only pace",
                    value: pace,
                    detail: nil
                )
            )
        }
        return blocks
    }

    @ViewBuilder
    private func forecastHint(blocks: [LegendBlock]) -> some View {
        if blocks.contains(where: { $0.detail != nil }) {
            HStack(spacing: 4) {
                legendSwatch(stroke: .dotted, color: .secondary)
                Text("forecast")
                    .font(.system(size: max(8, density.resetCountdownFontSize - 1)))
                    .foregroundStyle(.tertiary)
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func legendBlock(_ block: LegendBlock, showsDetail: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                legendSwatch(stroke: block.stroke, color: block.color)
                Text(block.label.uppercased())
                    .font(.system(size: max(8, density.subtitleFontSize - 2), weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.4)
            }
            Text(block.value)
                .font(
                    .system(
                        size: density.bucketTitleFontSize,
                        weight: .semibold,
                        design: .rounded
                    ).monospacedDigit()
                )
                .foregroundStyle(block.color)
            if showsDetail {
                Text(block.detail ?? " ")
                    .font(.system(size: max(8, density.resetCountdownFontSize - 2)))
                    .foregroundStyle(.tertiary)
                    .opacity(block.detail == nil ? 0 : 1)
                    .accessibilityHidden(block.detail == nil)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func legendSwatch(stroke: LegendStroke, color: Color) -> some View {
        let dash: [CGFloat]
        switch stroke {
        case .solid: dash = []
        case .dashed: dash = [4, 3]
        case .dotted: dash = [1.6, 2.6]
        }
        return Path { path in
            path.move(to: CGPoint(x: 0, y: 1))
            path.addLine(to: CGPoint(x: 14, y: 1))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dash))
        .frame(width: 14, height: 2)
    }

    // MARK: - Hover + gestures

    private func interactionOverlay(
        proxy: ChartProxy,
        buckets: [QuotaBucket],
        primary: QuotaBucket,
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
                            // The overlay also covers the leading axis strip;
                            // a reading from there would park the crosshair
                            // outside the plot.
                            let value = proxy.value(atX: location.x - plotMinX, as: Date.self)
                            hoverDate = value.flatMap {
                                window.wrappedValue.visibleRange.contains($0) ? $0 : nil
                            }
                        case .ended:
                            hoverDate = nil
                        }
                    }
                    .gesture(panGesture(window: window, plotWidth: plotWidth))
                    .simultaneousGesture(
                        magnifyGesture(window: window, proxy: proxy, plotMinX: plotMinX)
                    )
                    .onTapGesture(count: 2) {
                        window.wrappedValue = window.wrappedValue.jumped(toSpan: initialSpan)
                        hoverDate = nil
                    }

                if let hoverDate,
                   let reading = hoverReading(at: hoverDate, buckets: buckets, primary: primary),
                   let x = proxy.position(forX: reading.time),
                   let plot {
                    Rectangle()
                        .fill(Color.primary.opacity(0.22))
                        .frame(width: 1, height: plot.height)
                        .offset(x: plotMinX + x, y: plot.minY)
                        .allowsHitTesting(false)
                    tooltip(reading, showsBucketTitles: buckets.count > 1)
                        .offset(x: tooltipX(plotMinX: plotMinX, x: x, width: geometry.size.width))
                        .allowsHitTesting(false)
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

    private func tooltipX(plotMinX: CGFloat, x: CGFloat, width: CGFloat) -> CGFloat {
        let tooltipWidth = Self.tooltipWidth
        return min(max(plotMinX + x - tooltipWidth / 2, 0), max(0, width - tooltipWidth))
    }

    private static let tooltipWidth: CGFloat = 178

    private func tooltip(_ reading: QuotaHoverReading, showsBucketTitles: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Self.tooltipFormatter.string(from: reading.time))
                .font(.system(size: 10, weight: .semibold))
            ForEach(reading.buckets) { bucket in
                if showsBucketTitles {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(bucket.color)
                            .frame(width: 5, height: 5)
                        Text(bucket.title)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 1)
                }
                if bucket.isEmpty {
                    Text("No active window")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    if let actual = bucket.actual {
                        tooltipRow("Quota left", percent(actual), color: bucket.color)
                    }
                    if let pace = bucket.pace {
                        tooltipRow("Pace", percent(pace), color: .white.opacity(0.8))
                    }
                    if let forecast = bucket.forecast {
                        tooltipRow("At reset", percent(forecast), color: bucket.color.opacity(0.75))
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.87)))
        .foregroundStyle(.white)
        .frame(width: Self.tooltipWidth, alignment: .leading)
    }

    private func tooltipRow(_ label: String, _ value: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.75))
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
        }
    }

    /// Nearest reading on each line, per bucket, or nothing at all for a bucket
    /// whose coverage does not reach the cursor — a gap is information, not a
    /// rounding error, so it is never bridged to the closest sample on either
    /// side. The time label follows the shortest-window quota, which is the one
    /// sampled most densely.
    ///
    /// Binary search rather than a scan: this runs on every pointer move, and a
    /// densely sampled lane under unlimited retention is tens of thousands of
    /// samples per bucket.
    private func hoverReading(
        at date: Date,
        buckets: [QuotaBucket],
        primary: QuotaBucket
    ) -> QuotaHoverReading? {
        guard let window else { return nil }
        let slot = UsageTimelineSlotPolicy.slotSeconds(windowSeconds: primary.rawWindowSeconds)
        let tolerance = max(slot * 2, window.visibleSpan / 80)
        var readings: [QuotaHoverBucketReading] = []
        var anchor: Date?
        for (index, bucket) in buckets.enumerated() {
            let lookup = lookupByBucket[bucket.id] ?? BucketLookup()
            let actual = ChartSampleSearch.nearest(
                in: lookup.actual, to: date, tolerance: tolerance, time: { $0.time }
            )
            let pace = ChartSampleSearch.nearest(
                in: lookup.pace, to: date, tolerance: tolerance, time: { $0.time }
            )
            let forecast = ChartSampleSearch.nearest(
                in: lookup.forecast, to: date, tolerance: tolerance, time: { $0.time }
            )
            if bucket.id == primary.id {
                anchor = actual?.time ?? forecast?.time
            }
            readings.append(
                QuotaHoverBucketReading(
                    id: bucket.id,
                    title: bucket.title,
                    color: color(at: index),
                    actual: actual?.remainingPercent,
                    pace: pace?.remainingPercent,
                    forecast: forecast?.remainingPercent
                )
            )
        }
        return QuotaHoverReading(time: anchor ?? date, buckets: readings)
    }

    /// Flattened, ascending copies of one bucket's lines.
    ///
    /// The segments are contiguous runs of an already time-sorted array, so
    /// concatenating them keeps the order a binary search needs. Built once per
    /// data change rather than walked per pointer move.
    private struct BucketLookup {
        var actual: [QuotaHistorySample] = []
        var pace: [QuotaHistorySample] = []
        var forecast: [QuotaHistoryForecastSample] = []
    }

    // MARK: - Range pills

    /// Preset spans, shared with the Overview chart so both surfaces offer the
    /// same navigation vocabulary. Rendered only once a window exists.
    @ViewBuilder
    private var rangePills: some View {
        if window != nil {
            ChartRangePills(
                window: Binding(
                    get: { self.window ?? ChartTimeWindow(
                        domainStart: .distantPast,
                        domainEnd: .distantPast,
                        minimumSpan: 0,
                        visibleSpan: 0
                    ) },
                    set: { self.window = $0 }
                ),
                fontSize: max(9, density.segmentedFontSize - 2),
                onSelect: { hoverDate = nil }
            )
        }
    }

    // MARK: - Data selection

    /// A single observation draws nothing — a line needs two points — so a
    /// bucket only joins the plot once it can actually be drawn. Shortest
    /// window first: that quota anchors the reset lines, the brush mini, and
    /// the zoom floor.
    private var bucketsWithHistory: [QuotaBucket] {
        group.buckets
            .filter { fillPoints(bucketId: $0.id).count > 1 }
            .sorted {
                let left = $0.rawWindowSeconds ?? Int.max
                let right = $1.rawWindowSeconds ?? Int.max
                return left == right ? $0.id < $1.id : left < right
            }
    }

    private func color(at index: Int) -> Color {
        Self.bucketPalette[index % Self.bucketPalette.count]
    }

    /// Forecast strokes share their bucket's hue, lifted toward white on dark
    /// backgrounds the same way `ForecastQuotaBar` lifts its forecast marker —
    /// a 1.8pt dotted line loses more contrast than a solid one.
    ///
    /// Resolved by the *appearance* rather than by reading
    /// `@Environment(\.colorScheme)`: an environment read is a dependency this
    /// view would otherwise carry into its `Equatable` contract, and a dynamic
    /// `NSColor` re-resolves itself at draw time for free. Cached because the
    /// palette is fixed and building one per mark would not be.
    private func forecastTint(_ base: Color) -> Color {
        Self.forecastTints[base] ?? base
    }

    private static let forecastTints: [Color: Color] = Dictionary(
        uniqueKeysWithValues: bucketPalette.map { base in
            let lifted = NSColor(base.mix(with: .white, by: 0.16))
            let plain = NSColor(base)
            return (
                base,
                Color(
                    nsColor: NSColor(name: nil) { appearance in
                        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                            ? lifted
                            : plain
                    }
                )
            )
        }
    )

    private func fillPoints(bucketId: String) -> [FillTimelinePoint] {
        let key = SubscriptionHistoryKey(accountId: accountId, bucketId: bucketId)
        return quotaService.observationsByAccountBucket[key] ?? []
    }

    /// Account, group, and the shape of every bucket's observed fill lane.
    ///
    /// The forecast snapshots live in an actor-backed store this view cannot
    /// observe, so keying only on account and bucket would freeze the forecast
    /// lines at whatever was on disk when the page opened. Every refresh that
    /// records a projection also appends a fill point to
    /// `QuotaService.observationsByAccountBucket`, which *is* `@Published` —
    /// so each lane's count and newest timestamp are the cheapest honest signal
    /// that there is a new projection to read.
    private var forecastLoadKey: String {
        let parts = bucketsWithHistory.map { bucket -> String in
            let fills = fillPoints(bucketId: bucket.id)
            let newest = fills.last?.sampledAt.timeIntervalSince1970 ?? 0
            return "\(bucket.id):\(fills.count):\(newest)"
        }
        return "\(accountId)|\(group.id)|\(parts.joined(separator: ","))"
    }

    private func loadForecastPoints() async {
        var result: [String: [ForecastTimelinePoint]] = [:]
        for bucket in bucketsWithHistory {
            result[bucket.id] = await UsageForecastTimelineStore.shared.points(
                accountId: accountId,
                bucketId: bucket.id
            )
        }
        forecastByBucket = result
    }

    private var seriesSignature: QuotaSeriesSignature {
        // Both arrays arrive time-sorted (QuotaService sorts observations,
        // the forecast store sorts by slot), so the bounds are O(1).
        QuotaSeriesSignature(
            entries: bucketsWithHistory.map { bucket in
                let fills = fillPoints(bucketId: bucket.id)
                let forecasts = forecastByBucket[bucket.id] ?? []
                return QuotaSeriesSignature.Entry(
                    bucketId: bucket.id,
                    fillCount: fills.count,
                    fillStart: fills.first?.sampledAt,
                    fillEnd: fills.last?.sampledAt,
                    forecastCount: forecasts.count,
                    forecastEnd: forecasts.last?.sampledAt
                )
            }
        )
    }

    /// Re-segment every bucket's series and re-anchor the visible window. Runs
    /// on data changes only — pans and zooms reuse the series already built.
    private func rebuild() {
        let buckets = bucketsWithHistory
        guard let primary = buckets.first, let domain = domainRange(buckets: buckets) else {
            seriesByBucket = [:]
            lookupByBucket = [:]
            miniSegments = []
            window = nil
            windowKey = nil
            return
        }

        var built: [String: QuotaHistorySeries] = [:]
        for bucket in buckets {
            built[bucket.id] = QuotaHistorySeriesBuilder.build(
                fillPoints: fillPoints(bucketId: bucket.id),
                forecastPoints: forecastByBucket[bucket.id] ?? [],
                range: domain
            )
        }
        seriesByBucket = built
        lookupByBucket = built.mapValues {
            BucketLookup(
                actual: $0.actual.flatMap { $0 },
                pace: $0.pace.flatMap { $0 },
                forecast: $0.forecast.flatMap { $0 }
            )
        }
        miniSegments = ChartMarkBudget.thinned(
            built[primary.id]?.actual ?? [],
            budget: Self.miniMarkLimit
        )

        let minimumSpan = minimumSpan(for: primary)
        initialSpan = initialSpan(for: primary)

        // A different set of quotas gets a fresh window: buckets are sampled at
        // the same instants, so their domains can match to the second while the
        // sensible zoom floor and opening span are completely different.
        let key = buckets.map(\.id).joined(separator: ",")
        let sameQuotas = windowKey == key
        windowKey = key

        if sameQuotas,
           let existing = window,
           existing.domainStart == domain.lowerBound,
           existing.domainEnd == domain.upperBound {
            return
        }
        if sameQuotas, let existing = window {
            // Domain grew (a refresh landed) — keep the user where they were,
            // unless they were pinned to the newest edge, which should follow.
            let followsEnd = existing.isAtDomainEnd
            var next = ChartTimeWindow(
                domainStart: domain.lowerBound,
                domainEnd: domain.upperBound,
                minimumSpan: minimumSpan,
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
            minimumSpan: minimumSpan,
            visibleSpan: initialSpan
        )
    }

    /// Full extent of the stored evidence across the group, floored at six
    /// hours so a freshly-installed app does not open on a two-sample domain
    /// that no gesture can navigate. One shared domain, because the overlaid
    /// lines have to be readable against the same x axis.
    private func domainRange(buckets: [QuotaBucket]) -> ClosedRange<Date>? {
        var low: Date?
        var high: Date?
        for bucket in buckets {
            let fills = fillPoints(bucketId: bucket.id)
            let forecasts = forecastByBucket[bucket.id] ?? []
            for candidate in [fills.first?.sampledAt, forecasts.first?.sampledAt] {
                guard let candidate else { continue }
                low = low.map { min($0, candidate) } ?? candidate
            }
            for candidate in [fills.last?.sampledAt, forecasts.last?.sampledAt] {
                guard let candidate else { continue }
                high = high.map { max($0, candidate) } ?? candidate
            }
        }
        guard let low, let high, high >= low else { return nil }
        let floorSpan: TimeInterval = 6 * 3_600
        if high.timeIntervalSince(low) < floorSpan {
            return high.addingTimeInterval(-floorSpan)...high
        }
        return low...high
    }

    /// Zoom floor. A five-hour quota is legible at one hour; a weekly one has
    /// hourly slots at best, so half a day is as deep as its evidence goes.
    /// Taken from the shortest window in the group — it is the one that still
    /// has something to say at the deepest zoom.
    private func minimumSpan(for bucket: QuotaBucket) -> TimeInterval {
        guard let windowSeconds = bucket.rawWindowSeconds, windowSeconds > 0 else {
            return 6 * 3_600
        }
        return min(max(TimeInterval(windowSeconds) / 5, 3_600), 12 * 3_600)
    }

    private func initialSpan(for bucket: QuotaBucket) -> TimeInterval {
        guard let windowSeconds = bucket.rawWindowSeconds, windowSeconds > 0 else {
            return 7 * 86_400
        }
        return windowSeconds <= 6 * 3_600 ? 24 * 3_600 : 7 * 86_400
    }

    // MARK: - Mark shaping

    private func bucketLines(
        buckets: [QuotaBucket],
        range: ClosedRange<Date>,
        budget: Int
    ) -> [QuotaBucketLines] {
        buckets.enumerated().map { index, bucket in
            let series = seriesByBucket[bucket.id] ?? .empty
            let hue = color(at: index)
            return QuotaBucketLines(
                id: bucket.id,
                color: hue,
                forecastColor: forecastTint(hue),
                actual: linePoints(
                    series.actual,
                    kind: "actual-\(index)",
                    range: range,
                    budget: budget
                ),
                actualBridges: bridgePoints(
                    series.actual,
                    time: { $0.time },
                    value: { $0.remainingPercent },
                    kind: "actual-\(index)",
                    range: range
                ),
                forecast: forecastLinePoints(
                    series.forecast,
                    kind: "forecast-\(index)",
                    range: range,
                    budget: budget
                ),
                forecastBridges: bridgePoints(
                    series.forecast,
                    time: { $0.time },
                    value: { $0.remainingPercent },
                    kind: "forecast-\(index)",
                    range: range
                )
            )
        }
    }

    private func bridgePoints<Element>(
        _ segments: [[Element]],
        time: (Element) -> Date,
        value: (Element) -> Double,
        kind: String,
        range: ClosedRange<Date>
    ) -> [QuotaChartLinePoint] {
        QuotaChartMarks.bridges(segments, kind: kind, range: range, time: time, value: value)
    }

    private func linePoints(
        _ segments: [[QuotaHistorySample]],
        kind: String,
        range: ClosedRange<Date>,
        budget: Int
    ) -> [QuotaChartLinePoint] {
        QuotaChartMarks.points(
            segments,
            kind: kind,
            range: range,
            budget: budget,
            time: { $0.time },
            value: { $0.remainingPercent }
        )
    }

    private func forecastLinePoints(
        _ segments: [[QuotaHistoryForecastSample]],
        kind: String,
        range: ClosedRange<Date>,
        budget: Int
    ) -> [QuotaChartLinePoint] {
        QuotaChartMarks.points(
            segments,
            kind: kind,
            range: range,
            budget: budget,
            time: { $0.time },
            value: { $0.remainingPercent }
        )
    }

    private func forecastBandPoints(
        _ segments: [[QuotaHistoryForecastSample]],
        range: ClosedRange<Date>,
        budget: Int
    ) -> [QuotaBandPoint] {
        var visible: [(index: Int, samples: [QuotaHistoryForecastSample])] = []
        for (index, segment) in segments.enumerated() {
            let clipped = QuotaChartMarks.clip(segment, time: { $0.time }, to: range)
            guard clipped.count > 1 else { continue }
            visible.append((index, clipped))
        }
        let allowance = ChartMarkBudget.allocate(
            segmentCounts: visible.map { $0.samples.count },
            budget: budget
        )
        var result: [QuotaBandPoint] = []
        for (slot, entry) in visible.enumerated() {
            let thinned = ChartSeriesThinning.strided(entry.samples, limit: allowance[slot])
            let key = "band-\(entry.index)"
            for (offset, sample) in thinned.enumerated() {
                result.append(
                    QuotaBandPoint(
                        id: "\(key)-\(offset)",
                        seriesKey: key,
                        time: sample.time,
                        low: min(sample.lowerRemainingPercent, sample.upperRemainingPercent),
                        high: max(sample.lowerRemainingPercent, sample.upperRemainingPercent)
                    )
                )
            }
        }
        return result
    }

    // MARK: - Current values

    private func currentRemainingLabel(bucket: QuotaBucket) -> String {
        percent(max(0, 100 - bucket.usedPercent))
    }

    /// The newest *recorded* pace reading rather than one computed against the
    /// wall clock.
    ///
    /// Two reasons, and the second is the load-bearing one. It matches the end
    /// of the pace line the reader is looking at instead of a value a few
    /// minutes ahead of it — and it keeps this view free of `Date()`, which is
    /// what lets `.equatable()` skip the 30-second `TimelineView` tick the
    /// utilization card ticks on. The live wall-clock pace is already on the
    /// row directly above.
    private func currentPaceLabel(bucket: QuotaBucket) -> String? {
        guard let last = (seriesByBucket[bucket.id] ?? .empty).pace.last?.last else { return nil }
        return percent(last.remainingPercent)
    }

    /// The newest *recorded* projection rather than a freshly computed one:
    /// `QuotaService.activityContextProvider` feeds the refresh path the same
    /// activity inputs the popover renders with, so this matches the
    /// utilization card while costing nothing at render time — and it is the
    /// value the forecast line actually ends on.
    ///
    /// Omitted when the newest projection is older than the newest observation
    /// by more than a couple of slots: a forecast that stopped being recordable
    /// last week is history, not a current reading.
    private func currentForecastLabel(bucket: QuotaBucket) -> String? {
        let series = seriesByBucket[bucket.id] ?? .empty
        guard let last = series.forecast.last?.last else { return nil }
        if let newestActual = series.actual.last?.last?.time {
            let slot = UsageTimelineSlotPolicy.slotSeconds(windowSeconds: bucket.rawWindowSeconds)
            guard newestActual.timeIntervalSince(last.time) <= slot * 3 else { return nil }
        }
        return percent(last.remainingPercent)
    }

    private func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private func scopeNote(buckets: [QuotaBucket], window: ChartTimeWindow) -> String {
        let span = Self.spanLabel(window.visibleSpan)
        let total = Self.spanLabel(window.domainSpan)
        let shown = buckets.prefix(3).map(\.title).joined(separator: " + ")
        let names = buckets.count > 3 ? "\(shown) +\(buckets.count - 3)" : shown
        let scope = group.title.map { "\($0) · \(names)" } ?? names
        return "\(scope) · showing \(span) of \(total) recorded"
    }

    private static func spanLabel(_ seconds: TimeInterval) -> String {
        if seconds < 90 * 60 { return "\(max(1, Int((seconds / 60).rounded())))m" }
        if seconds < 48 * 3_600 { return "\(Int((seconds / 3_600).rounded()))h" }
        return "\(Int((seconds / 86_400).rounded()))d"
    }

    private static let tooltipFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d · HH:mm"
        return formatter
    }()
}
