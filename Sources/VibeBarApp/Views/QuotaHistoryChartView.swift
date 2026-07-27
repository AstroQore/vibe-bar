import SwiftUI
import Charts
import VibeBarCore

/// One headed group of independently resettable quotas.
///
/// Claude splits its weekly allowance across model scopes ("Fable", "Opus", …)
/// and Codex splits its by limit name; each of those is a group, and the
/// ungrouped remainder (Claude's 5 Hours + Weekly) is a group too — the one
/// Subscription Utilization prints no heading for.
struct QuotaBucketGroup: Identifiable {
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

    /// Split `buckets` into runs that share a heading, preserving the
    /// provider's own bucket order.
    ///
    /// Contiguous by design: the utilization card decides "this row starts a
    /// group" by comparing with the row above it, so a title that reappeared
    /// after an interruption would print twice there. Grouping the same way
    /// keeps one chart per printed heading rather than per distinct string.
    static func groups(
        pageTool: ToolType,
        itemTool: ToolType,
        buckets: [QuotaBucket]
    ) -> [QuotaBucketGroup] {
        var result: [QuotaBucketGroup] = []
        for bucket in buckets {
            let title = title(pageTool: pageTool, itemTool: itemTool, bucket: bucket)
            if let last = result.last, last.title == title {
                result[result.count - 1] = QuotaBucketGroup(
                    id: last.id,
                    title: last.title,
                    buckets: last.buckets + [bucket]
                )
            } else {
                result.append(
                    QuotaBucketGroup(
                        id: "\(itemTool.rawValue)|\(result.count)|\(title ?? "")",
                        title: title,
                        buckets: [bucket]
                    )
                )
            }
        }
        return result
    }

    /// Groups worth giving a history card.
    ///
    /// A line needs two points, so a group nobody has observed twice yet would
    /// render an empty card — and on a fresh install *every* group would. Keep
    /// the ones with something to draw; when none of them has anything, keep
    /// exactly one so the "history builds up as refreshes come in" note is
    /// still said once instead of once per quota scope.
    static func chartable(
        _ groups: [QuotaBucketGroup],
        accountId: String,
        observations: [SubscriptionHistoryKey: [FillTimelinePoint]]
    ) -> [QuotaBucketGroup] {
        let drawable = groups.filter { group in
            group.buckets.contains { bucket in
                let key = SubscriptionHistoryKey(accountId: accountId, bucketId: bucket.id)
                return (observations[key]?.count ?? 0) > 1
            }
        }
        if !drawable.isEmpty { return drawable }
        return groups.isEmpty ? [] : [groups[0]]
    }
}

/// One drawable point on a quota history line. Segment membership travels with
/// the point as `seriesKey` so Swift Charts never joins two sides of a reset
/// (or of a stretch where Vibe Bar was not running) into one stroke.
private struct QuotaLinePoint: Identifiable {
    let id: String
    let seriesKey: String
    let time: Date
    let value: Double
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
    let actual: [QuotaLinePoint]
    let forecast: [QuotaLinePoint]
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
struct QuotaHistoryChartView: View {
    let tool: ToolType
    let accountId: String
    let group: QuotaBucketGroup
    let density: Theme.Density
    /// Set when a page shows more than one of these cards for *different
    /// products* and "Quota history" alone would not say whose.
    var titleOverride: String? = nil
    /// Print the group's name under the title. Set when the account has more
    /// than one group, mirroring the headings in Subscription Utilization.
    var showsGroupTitle: Bool = false

    @EnvironmentObject var quotaService: QuotaService
    @Environment(\.colorScheme) private var colorScheme

    @State private var forecastByBucket: [String: [ForecastTimelinePoint]] = [:]
    @State private var seriesByBucket: [String: QuotaHistorySeries] = [:]
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
    /// so the budget is shared out across however many buckets overlay.
    private static let visibleMarkLimit = 520
    private static let minimumMarkLimit = 140
    private static let miniMarkLimit = 160
    /// Past this many reset lines the plot reads as a picket fence rather than
    /// as a set of boundaries, so a zoomed-out five-hour quota drops them.
    private static let visibleResetLimit = 24

    var body: some View {
        let buckets = bucketsWithHistory

        VStack(alignment: .leading, spacing: density.cardSpacing) {
            header

            if let first = buckets.first, let window, window.domainSpan > 0 {
                chartBody(buckets: buckets, primary: first, window: window)
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
        .task(id: forecastLoadKey) {
            await loadForecastPoints()
        }
        .onChange(of: seriesSignature, initial: true) { _, _ in
            rebuild()
        }
    }

    // MARK: - Header

    private var header: some View {
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
            if window != nil, !rangeOptions.isEmpty {
                pillGroup(rangeOptions) { option in
                    applyRange(option)
                }
            }
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
        let limit = max(Self.minimumMarkLimit, Self.visibleMarkLimit / max(1, buckets.count))
        let lines = bucketLines(buckets: buckets, range: visible, limit: limit)
        let primarySeries = seriesByBucket[primary.id] ?? .empty
        // Only a single-bucket chart can afford the wall-clock reference and
        // the uncertainty band: two of them overlaid is mud, and the pace
        // reading moves into the hover tooltip instead.
        let pacePoints = isSingle
            ? linePoints(primarySeries.pace, kind: "pace", range: visible, limit: limit)
            : []
        let bandPoints = isSingle
            ? forecastBandPoints(primarySeries.forecast, range: visible, limit: limit)
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
        Path { path in
            for segment in miniSegments {
                guard let first = segment.first else { continue }
                path.move(
                    to: CGPoint(
                        x: geometry.x(for: first.time),
                        y: geometry.y(forFraction: first.remainingPercent / 100)
                    )
                )
                for sample in segment.dropFirst() {
                    path.addLine(
                        to: CGPoint(
                            x: geometry.x(for: sample.time),
                            y: geometry.y(forFraction: sample.remainingPercent / 100)
                        )
                    )
                }
            }
        }
        .stroke(
            Self.bucketPalette[0].opacity(0.75),
            style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
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
            let series = seriesByBucket[bucket.id] ?? .empty
            let actual = nearestSample(in: series.actual, to: date, tolerance: tolerance)
            let pace = nearestSample(in: series.pace, to: date, tolerance: tolerance)
            let forecast = nearestForecast(in: series.forecast, to: date, tolerance: tolerance)
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

    private func nearestSample(
        in segments: [[QuotaHistorySample]],
        to date: Date,
        tolerance: TimeInterval
    ) -> QuotaHistorySample? {
        var best: QuotaHistorySample?
        var bestDistance = tolerance
        for segment in segments {
            for sample in segment {
                let distance = abs(sample.time.timeIntervalSince(date))
                if distance <= bestDistance {
                    best = sample
                    bestDistance = distance
                }
            }
        }
        return best
    }

    private func nearestForecast(
        in segments: [[QuotaHistoryForecastSample]],
        to date: Date,
        tolerance: TimeInterval
    ) -> QuotaHistoryForecastSample? {
        var best: QuotaHistoryForecastSample?
        var bestDistance = tolerance
        for segment in segments {
            for sample in segment {
                let distance = abs(sample.time.timeIntervalSince(date))
                if distance <= bestDistance {
                    best = sample
                    bestDistance = distance
                }
            }
        }
        return best
    }

    // MARK: - Range pills

    private struct PillOption: Identifiable, Equatable {
        let id: String
        let label: String
        let span: TimeInterval?
        let isSelected: Bool
    }

    private static let rangeSpans: [(String, TimeInterval)] = [
        ("6h", 6 * 3_600),
        ("24h", 24 * 3_600),
        ("3d", 3 * 86_400),
        ("7d", 7 * 86_400)
    ]

    private var rangeOptions: [PillOption] {
        guard let window, window.domainSpan > 0 else { return [] }
        var options = Self.rangeSpans
            .filter { $0.1 < window.domainSpan }
            .map { label, span in
                PillOption(
                    id: label,
                    label: label,
                    span: span,
                    isSelected: !window.coversDomain
                        && window.isAtDomainEnd
                        && abs(window.visibleSpan - span) <= span * 0.03
                )
            }
        options.append(
            PillOption(id: "all", label: "All", span: nil, isSelected: window.coversDomain)
        )
        return options
    }

    private func applyRange(_ option: PillOption) {
        guard var current = window else { return }
        if let span = option.span {
            current.jump(toSpan: span)
        } else {
            current.jump(toSpan: current.domainSpan)
        }
        window = current
        hoverDate = nil
    }

    private func pillGroup(
        _ options: [PillOption],
        action: @escaping (PillOption) -> Void
    ) -> some View {
        HStack(spacing: 1) {
            ForEach(options) { option in
                Button {
                    action(option)
                } label: {
                    Text(option.label)
                        .font(
                            .system(
                                size: max(9, density.segmentedFontSize - 2),
                                weight: .semibold,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(option.isSelected ? .primary : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .background {
                    if option.isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.12))
                    }
                }
                .accessibilityLabel(option.label)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
        .fixedSize(horizontal: true, vertical: false)
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
    private func forecastTint(_ base: Color) -> Color {
        colorScheme == .dark ? base.mix(with: .white, by: 0.16) : base
    }

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
        miniSegments = (built[primary.id]?.actual ?? []).map {
            ChartSeriesThinning.strided($0, limit: Self.miniMarkLimit)
        }

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
        limit: Int
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
                    limit: limit
                ),
                forecast: forecastLinePoints(
                    series.forecast,
                    kind: "forecast-\(index)",
                    range: range,
                    limit: limit
                )
            )
        }
    }

    private func linePoints(
        _ segments: [[QuotaHistorySample]],
        kind: String,
        range: ClosedRange<Date>,
        limit: Int
    ) -> [QuotaLinePoint] {
        var result: [QuotaLinePoint] = []
        for (index, segment) in segments.enumerated() {
            let clipped = clip(segment, time: { $0.time }, to: range)
            guard clipped.count > 0 else { continue }
            let thinned = ChartSeriesThinning.strided(clipped, limit: limit)
            let key = "\(kind)-\(index)"
            for (offset, sample) in thinned.enumerated() {
                result.append(
                    QuotaLinePoint(
                        id: "\(key)-\(offset)",
                        seriesKey: key,
                        time: sample.time,
                        value: sample.remainingPercent
                    )
                )
            }
        }
        return result
    }

    private func forecastLinePoints(
        _ segments: [[QuotaHistoryForecastSample]],
        kind: String,
        range: ClosedRange<Date>,
        limit: Int
    ) -> [QuotaLinePoint] {
        var result: [QuotaLinePoint] = []
        for (index, segment) in segments.enumerated() {
            let clipped = clip(segment, time: { $0.time }, to: range)
            guard clipped.count > 0 else { continue }
            let thinned = ChartSeriesThinning.strided(clipped, limit: limit)
            let key = "\(kind)-\(index)"
            for (offset, sample) in thinned.enumerated() {
                result.append(
                    QuotaLinePoint(
                        id: "\(key)-\(offset)",
                        seriesKey: key,
                        time: sample.time,
                        value: sample.remainingPercent
                    )
                )
            }
        }
        return result
    }

    private func forecastBandPoints(
        _ segments: [[QuotaHistoryForecastSample]],
        range: ClosedRange<Date>,
        limit: Int
    ) -> [QuotaBandPoint] {
        var result: [QuotaBandPoint] = []
        for (index, segment) in segments.enumerated() {
            let clipped = clip(segment, time: { $0.time }, to: range)
            guard clipped.count > 1 else { continue }
            let thinned = ChartSeriesThinning.strided(clipped, limit: limit)
            let key = "band-\(index)"
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

    /// Keep one sample beyond each edge so a line entering the window starts at
    /// the frame border instead of at its first visible observation.
    private func clip<Element>(
        _ segment: [Element],
        time: (Element) -> Date,
        to range: ClosedRange<Date>
    ) -> [Element] {
        guard !segment.isEmpty else { return [] }
        var first: Int?
        var last: Int?
        for (index, element) in segment.enumerated() {
            let stamp = time(element)
            if stamp >= range.lowerBound, stamp <= range.upperBound {
                if first == nil { first = index }
                last = index
            }
        }
        guard let first, let last else { return [] }
        let lower = max(0, first - 1)
        let upper = min(segment.count - 1, last + 1)
        return Array(segment[lower...upper])
    }

    // MARK: - Current values

    private func currentRemainingLabel(bucket: QuotaBucket) -> String {
        percent(max(0, 100 - bucket.usedPercent))
    }

    private func currentPaceLabel(bucket: QuotaBucket) -> String? {
        guard let pace = UsagePace.compute(bucket: bucket, now: Date()) else { return nil }
        return percent(max(0, 100 - pace.expectedUsedPercent))
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
