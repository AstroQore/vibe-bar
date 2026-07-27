import SwiftUI
import Charts
import VibeBarCore

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

/// What the hover crosshair resolved to at one instant.
private struct QuotaHoverReading {
    let time: Date
    let actual: Double?
    let pace: Double?
    let forecast: Double?

    var isEmpty: Bool { actual == nil && pace == nil && forecast == nil }
}

/// Everything that decides the shape of the chart. Rebuilding is keyed on this
/// rather than on the raw arrays: a quota refresh appends one point, and only
/// then is it worth re-segmenting the series.
private struct QuotaSeriesSignature: Equatable {
    var bucketId: String
    var fillCount: Int
    var fillStart: Date?
    var fillEnd: Date?
    var forecastCount: Int
    var forecastEnd: Date?
}

/// Quota history over time: what was left, what an even burn would have left,
/// and what the forecast said would be left at reset — each drawn only where it
/// was actually observed.
///
/// The three lines answer three different questions and are deliberately not
/// merged: `actual` is evidence, `pace` is the wall-clock reference, and
/// `forecast` is the projection *as recorded at the time*, never recomputed
/// with hindsight. Between quota windows there is simply no line, which is why
/// the builder hands back segments instead of flat arrays.
///
/// Navigation is the approved thumbnail + gesture hybrid: a brush strip covers
/// the whole domain, while drag-pan and pinch-zoom work directly on the plot.
struct QuotaHistoryChartView: View {
    let tool: ToolType
    let accountId: String
    let buckets: [QuotaBucket]
    let density: Theme.Density

    @EnvironmentObject var quotaService: QuotaService

    @State private var selectedBucketId: String?
    @State private var forecastPoints: [ForecastTimelinePoint] = []
    @State private var series: QuotaHistorySeries = .empty
    @State private var miniSegments: [[QuotaHistorySample]] = []
    @State private var window: ChartTimeWindow?
    @State private var windowBucketId: String?
    @State private var initialSpan: TimeInterval = 24 * 3_600
    @State private var hoverDate: Date?
    @State private var panBase: ChartTimeWindow?
    @State private var magnifyBase: ChartTimeWindow?

    /// Same green as a healthy remaining-quota bar, so "quota left" reads the
    /// same on the chart as it does on the bar above it.
    private static let actualColor = Color(red: 0.18, green: 0.74, blue: 0.55)
    private static let forecastColor = Color(red: 0.20, green: 0.56, blue: 0.88)
    private static let paceColor = Color.secondary

    /// Marks per line inside the visible window. Beyond this the strokes stop
    /// gaining detail and start costing frames on a zoomed-out weekly domain.
    private static let visibleMarkLimit = 520
    private static let miniMarkLimit = 160

    var body: some View {
        let historyBuckets = bucketsWithHistory
        let bucket = activeBucket(in: historyBuckets)

        VStack(alignment: .leading, spacing: density.cardSpacing) {
            header(historyBuckets: historyBuckets)

            if let bucket, let window, window.domainSpan > 0 {
                chartBody(bucket: bucket, window: window)
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
            await loadForecastPoints(bucketId: bucket?.id)
        }
        .onChange(of: seriesSignature(for: bucket), initial: true) { _, signature in
            rebuild(signature: signature, bucket: bucket)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(historyBuckets: [QuotaBucket]) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Quota history")
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                Spacer(minLength: 8)
                if window != nil, !rangeOptions.isEmpty {
                    pillGroup(rangeOptions) { option in
                        applyRange(option)
                    }
                }
            }
            if historyBuckets.count > 1 {
                bucketPills(bucketOptions(historyBuckets))
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
    private func chartBody(bucket: QuotaBucket, window: ChartTimeWindow) -> some View {
        let binding = Binding<ChartTimeWindow>(
            get: { self.window ?? window },
            set: { self.window = $0 }
        )
        let visible = window.visibleRange
        let actualPoints = linePoints(series.actual, kind: "actual", range: visible)
        let pacePoints = linePoints(series.pace, kind: "pace", range: visible)
        let forecastLine = forecastLinePoints(range: visible)
        let bandPoints = forecastBandPoints(range: visible)
        let resets = series.resetBoundaries.filter { visible.contains($0) }

        VStack(alignment: .leading, spacing: 6) {
            legend(bucket: bucket)

            Chart {
                ForEach(bandPoints) { point in
                    AreaMark(
                        x: .value("Time", point.time),
                        yStart: .value("Low", point.low),
                        yEnd: .value("High", point.high),
                        series: .value("Band", point.seriesKey)
                    )
                    .foregroundStyle(Self.forecastColor.opacity(0.08))
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
                ForEach(forecastLine) { point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("Left", point.value),
                        series: .value("Line", point.seriesKey)
                    )
                    .foregroundStyle(Self.forecastColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: [2, 3.4]))
                }
                ForEach(actualPoints) { point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("Left", point.value),
                        series: .value("Line", point.seriesKey)
                    )
                    .foregroundStyle(Self.actualColor)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
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
                interactionOverlay(proxy: proxy, bucket: bucket, window: binding)
            }
            .frame(height: density.quotaHistoryChartHeight)

            ChartBrushNavigator(
                window: binding,
                accent: Self.actualColor,
                height: density.chartBrushHeight,
                accessibilityDescription: "Quota history range navigator"
            ) { geometry in
                miniPath(in: geometry)
            }

            Text(scopeNote(bucket: bucket, window: window))
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
            Self.actualColor.opacity(0.75),
            style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
        )
    }

    // MARK: - Legend

    private enum LegendStroke {
        case solid
        case dashed
        case dotted
    }

    @ViewBuilder
    private func legend(bucket: QuotaBucket) -> some View {
        let items: [(LegendStroke, Color, String, String?)] = [
            (.solid, Self.actualColor, "Quota left", currentRemainingLabel(bucket: bucket)),
            (.dashed, Self.paceColor, "Time-only pace", currentPaceLabel(bucket: bucket)),
            (.dotted, Self.forecastColor, "Forecast at reset", currentForecastLabel(bucket: bucket))
        ]
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    legendItem(stroke: item.0, color: item.1, label: item.2, value: item.3)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    legendItem(stroke: item.0, color: item.1, label: item.2, value: item.3)
                }
            }
        }
    }

    private func legendItem(
        stroke: LegendStroke,
        color: Color,
        label: String,
        value: String?
    ) -> some View {
        HStack(spacing: 4) {
            legendSwatch(stroke: stroke, color: color)
            Text(label)
                .font(.system(size: max(9, density.subtitleFontSize - 1)))
                .foregroundStyle(.secondary)
            if let value {
                Text(value)
                    .font(
                        .system(
                            size: max(9, density.subtitleFontSize - 1),
                            weight: .semibold,
                            design: .rounded
                        ).monospacedDigit()
                    )
                    .foregroundStyle(color)
            }
        }
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
        bucket: QuotaBucket,
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
                   let reading = hoverReading(at: hoverDate, bucket: bucket),
                   let x = proxy.position(forX: reading.time),
                   let plot {
                    Rectangle()
                        .fill(Color.primary.opacity(0.22))
                        .frame(width: 1, height: plot.height)
                        .offset(x: plotMinX + x, y: plot.minY)
                        .allowsHitTesting(false)
                    tooltip(reading)
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
        let tooltipWidth: CGFloat = 168
        return min(max(plotMinX + x - tooltipWidth / 2, 0), max(0, width - tooltipWidth))
    }

    private func tooltip(_ reading: QuotaHoverReading) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Self.tooltipFormatter.string(from: reading.time))
                .font(.system(size: 10, weight: .semibold))
            if reading.isEmpty {
                Text("No active window")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                if let actual = reading.actual {
                    tooltipRow("Quota left", percent(actual), color: Self.actualColor)
                }
                if let pace = reading.pace {
                    tooltipRow("Pace", percent(pace), color: .white.opacity(0.8))
                }
                if let forecast = reading.forecast {
                    tooltipRow("At reset", percent(forecast), color: Self.forecastColor)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.87)))
        .foregroundStyle(.white)
        .frame(width: 168, alignment: .leading)
    }

    private func tooltipRow(_ label: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.75))
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
        }
    }

    /// Nearest reading on each line, or nothing at all when the cursor sits in
    /// a stretch with no coverage — a gap is information, not a rounding error,
    /// so it is never bridged to the closest sample on either side.
    private func hoverReading(at date: Date, bucket: QuotaBucket) -> QuotaHoverReading? {
        guard let window else { return nil }
        let slot = UsageTimelineSlotPolicy.slotSeconds(windowSeconds: bucket.rawWindowSeconds)
        let tolerance = max(slot * 2, window.visibleSpan / 80)
        let actual = nearestSample(in: series.actual, to: date, tolerance: tolerance)
        let pace = nearestSample(in: series.pace, to: date, tolerance: tolerance)
        let forecast = nearestForecast(to: date, tolerance: tolerance)
        return QuotaHoverReading(
            time: actual?.time ?? forecast?.time ?? date,
            actual: actual?.remainingPercent,
            pace: pace?.remainingPercent,
            forecast: forecast?.remainingPercent
        )
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
        to date: Date,
        tolerance: TimeInterval
    ) -> QuotaHistoryForecastSample? {
        var best: QuotaHistoryForecastSample?
        var bestDistance = tolerance
        for segment in series.forecast {
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

    private func bucketOptions(_ historyBuckets: [QuotaBucket]) -> [PillOption] {
        let active = activeBucket(in: historyBuckets)?.id
        return historyBuckets.map { bucket in
            PillOption(
                id: bucket.id,
                label: bucketLabel(bucket),
                span: nil,
                isSelected: bucket.id == active
            )
        }
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

    /// Claude can expose seven independently resettable quotas, which is more
    /// pills than the narrow quota column fits on one line. Prefer one row,
    /// then let `ViewThatFits` fall back to two or three — chunking keeps every
    /// label fully legible instead of scaling them into illegibility.
    @ViewBuilder
    private func bucketPills(_ options: [PillOption]) -> some View {
        let select: (PillOption) -> Void = { option in
            guard option.id != selectedBucketId else { return }
            selectedBucketId = option.id
            // The forecast snapshots belong to the bucket that was showing;
            // drop them so the reload cannot flash another quota's projection
            // over the new line.
            forecastPoints = []
            hoverDate = nil
        }
        ViewThatFits(in: .horizontal) {
            pillRows(options, rows: 1, action: select)
            pillRows(options, rows: 2, action: select)
            pillRows(options, rows: 3, action: select)
        }
    }

    private func pillRows(
        _ options: [PillOption],
        rows: Int,
        action: @escaping (PillOption) -> Void
    ) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            ForEach(Array(chunked(options, rows: rows).enumerated()), id: \.offset) { _, chunk in
                pillGroup(chunk, action: action)
            }
        }
    }

    private func chunked(_ options: [PillOption], rows: Int) -> [[PillOption]] {
        guard rows > 1, options.count > rows else { return [options] }
        let perRow = Int(ceil(Double(options.count) / Double(rows)))
        return stride(from: 0, to: options.count, by: perRow).map {
            Array(options[$0..<min($0 + perRow, options.count)])
        }
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
    /// bucket only becomes selectable once it can actually be plotted.
    private var bucketsWithHistory: [QuotaBucket] {
        buckets
            .filter { fillPoints(bucketId: $0.id).count > 1 }
            .sorted {
                let left = $0.rawWindowSeconds ?? Int.max
                let right = $1.rawWindowSeconds ?? Int.max
                return left == right ? $0.id < $1.id : left < right
            }
    }

    private func activeBucket(in historyBuckets: [QuotaBucket]) -> QuotaBucket? {
        if let selectedBucketId,
           let match = historyBuckets.first(where: { $0.id == selectedBucketId }) {
            return match
        }
        return historyBuckets.first
    }

    private func fillPoints(bucketId: String) -> [FillTimelinePoint] {
        let key = SubscriptionHistoryKey(accountId: accountId, bucketId: bucketId)
        return quotaService.observationsByAccountBucket[key] ?? []
    }

    private var forecastLoadKey: String {
        "\(accountId)|\(activeBucket(in: bucketsWithHistory)?.id ?? "")"
    }

    private func loadForecastPoints(bucketId: String?) async {
        guard let bucketId else {
            forecastPoints = []
            return
        }
        let points = await UsageForecastTimelineStore.shared.points(
            accountId: accountId,
            bucketId: bucketId
        )
        forecastPoints = points
    }

    private func seriesSignature(for bucket: QuotaBucket?) -> QuotaSeriesSignature {
        guard let bucket else {
            return QuotaSeriesSignature(
                bucketId: "",
                fillCount: 0,
                fillStart: nil,
                fillEnd: nil,
                forecastCount: 0,
                forecastEnd: nil
            )
        }
        // Both arrays arrive time-sorted (QuotaService sorts observations,
        // the forecast store sorts by slot), so the bounds are O(1).
        let fills = fillPoints(bucketId: bucket.id)
        return QuotaSeriesSignature(
            bucketId: bucket.id,
            fillCount: fills.count,
            fillStart: fills.first?.sampledAt,
            fillEnd: fills.last?.sampledAt,
            forecastCount: forecastPoints.count,
            forecastEnd: forecastPoints.last?.sampledAt
        )
    }

    /// Re-segment the series and re-anchor the visible window. Runs on data
    /// changes only — pans and zooms reuse the series already built.
    private func rebuild(signature: QuotaSeriesSignature, bucket: QuotaBucket?) {
        guard let bucket, signature.fillCount > 0 else {
            series = .empty
            miniSegments = []
            window = nil
            windowBucketId = nil
            return
        }
        let fills = fillPoints(bucketId: bucket.id)
        guard let domain = domainRange(fills: fills) else {
            series = .empty
            miniSegments = []
            window = nil
            windowBucketId = nil
            return
        }

        series = QuotaHistorySeriesBuilder.build(
            fillPoints: fills,
            forecastPoints: forecastPoints,
            range: domain
        )
        miniSegments = series.actual.map {
            ChartSeriesThinning.strided($0, limit: Self.miniMarkLimit)
        }

        let minimumSpan = minimumSpan(for: bucket)
        initialSpan = initialSpan(for: bucket)

        // A different quota gets a fresh window: the two buckets are sampled at
        // the same instants, so their domains can match to the second while the
        // sensible zoom floor and opening span are completely different.
        let sameBucket = windowBucketId == bucket.id
        windowBucketId = bucket.id

        if sameBucket,
           let existing = window,
           existing.domainStart == domain.lowerBound,
           existing.domainEnd == domain.upperBound {
            return
        }
        if sameBucket, let existing = window {
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

    /// Full extent of the stored evidence, floored at six hours so a
    /// freshly-installed app does not open on a two-sample domain that no
    /// gesture can navigate.
    private func domainRange(fills: [FillTimelinePoint]) -> ClosedRange<Date>? {
        var low = fills.first?.sampledAt
        var high = fills.last?.sampledAt
        if let first = forecastPoints.first?.sampledAt {
            low = low.map { min($0, first) } ?? first
        }
        if let last = forecastPoints.last?.sampledAt {
            high = high.map { max($0, last) } ?? last
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

    private func linePoints(
        _ segments: [[QuotaHistorySample]],
        kind: String,
        range: ClosedRange<Date>
    ) -> [QuotaLinePoint] {
        var result: [QuotaLinePoint] = []
        for (index, segment) in segments.enumerated() {
            let clipped = clip(segment, time: { $0.time }, to: range)
            guard clipped.count > 0 else { continue }
            let thinned = ChartSeriesThinning.strided(clipped, limit: Self.visibleMarkLimit)
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

    private func forecastLinePoints(range: ClosedRange<Date>) -> [QuotaLinePoint] {
        var result: [QuotaLinePoint] = []
        for (index, segment) in series.forecast.enumerated() {
            let clipped = clip(segment, time: { $0.time }, to: range)
            guard clipped.count > 0 else { continue }
            let thinned = ChartSeriesThinning.strided(clipped, limit: Self.visibleMarkLimit)
            let key = "forecast-\(index)"
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

    private func forecastBandPoints(range: ClosedRange<Date>) -> [QuotaBandPoint] {
        var result: [QuotaBandPoint] = []
        for (index, segment) in series.forecast.enumerated() {
            let clipped = clip(segment, time: { $0.time }, to: range)
            guard clipped.count > 1 else { continue }
            let thinned = ChartSeriesThinning.strided(clipped, limit: Self.visibleMarkLimit)
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

    /// Pill label. Claude titles six different weekly quotas "Weekly" and only
    /// the group name tells them apart, so the group wins when it exists —
    /// matching the section headings in Subscription Utilization.
    private func bucketLabel(_ bucket: QuotaBucket) -> String {
        if let group = bucket.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !group.isEmpty {
            return group
        }
        return bucket.title
    }

    private func scopeNote(bucket: QuotaBucket, window: ChartTimeWindow) -> String {
        let span = Self.spanLabel(window.visibleSpan)
        let total = Self.spanLabel(window.domainSpan)
        let scope = bucket.groupTitle?.isEmpty == false
            ? "\(bucketLabel(bucket)) · \(bucket.title)"
            : bucket.title
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
