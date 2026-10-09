import Charts
import SwiftUI
import VibeBarCore

/// What the trend card plots.
enum UsageTrendMetric: String, CaseIterable, Identifiable {
    case tokens
    case output
    /// Request-level ledger rows — model calls, not transcript messages: a
    /// turn can make several requests (and retries), so this is named for
    /// what it counts.
    case requests
    case sessions
    case cost
    case active

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tokens: L10n.Usage.Tokens.title
        case .output: L10n.Workbench.Usage.Trend.Metric.output
        case .requests: L10n.Usage.Breakdown.requests
        case .sessions: L10n.Workbench.Page.Sessions.title
        case .cost: L10n.Cost.title
        case .active: L10n.Workbench.Usage.Trend.Metric.active
        }
    }

    var tint: Color {
        switch self {
        case .tokens: WorkbenchPorcelain.accent
        case .output: .green
        case .requests: .teal
        case .sessions: Color(red: 20 / 255, green: 169 / 255, blue: 124 / 255)
        case .cost: .orange
        case .active: .purple
        }
    }

    /// Tokens and cost can be split by harness; the rest are counts of
    /// things a harness split would double count (a session, an hour).
    var canSplitByHarness: Bool { self == .tokens || self == .cost }

    func format(_ value: Double) -> String {
        switch self {
        case .tokens, .output: UsageDashboardFormat.tokens(Int64(value.rounded()))
        case .cost: UsageFormatting.compactUSD(Int64(value.rounded()))
        case .requests, .sessions, .active: AppLocale.number(Int(value.rounded()))
        }
    }
}

/// How the bars are split: input under output, or one band per harness.
enum UsageTrendSplit: String, CaseIterable, Identifiable {
    case flow
    case harness

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flow: L10n.Workbench.Usage.Trend.splitFlow
        case .harness: L10n.Usage.Table.Column.harness
        }
    }
}

/// One bar's stacked parts, precomputed once per (series, metric, split).
struct UsageTrendSegment: Equatable, Identifiable {
    let start: Date
    let key: String
    let label: String
    let value: Double
    let tint: Color
    var id: String { "\(start.timeIntervalSince1970)|\(key)" }
}

/// Everything the card draws, derived once per data or control change and
/// never in `body`: the segments, the hover readings and the subtitle.
struct UsageTrendPlan: Equatable {
    var segments: [UsageTrendSegment] = []
    /// Bar starts, ascending — the hover overlay's binary search runs on these.
    var starts: [Date] = []
    /// Per bar, the parts in stacking order (for the tooltip).
    var parts: [[UsageTrendSegment]] = []
    var legend: [UsageTrendSegment] = []
    var subtitle: String?
    var isEmpty = true

    static let harnessLimit = 6

    init() {}

    init(trend: UsageDashboardSnapshot.Trend, metric: UsageTrendMetric, split: UsageTrendSplit) {
        let points = trend.points
        starts = points.map(\.start)
        let bySplit = split == .harness && metric.canSplitByHarness
        // The heaviest harnesses over the whole range keep their own band;
        // the rest fold into one, so a bar never stacks more than seven.
        var keep: [Harness] = []
        if bySplit {
            var totals: [Harness: Int64] = [:]
            for point in points {
                for value in point.byHarness {
                    totals[value.harness, default: 0] += metric == .cost ? value.costMicros : value.tokens
                }
            }
            keep = totals.filter { $0.value > 0 }
                .sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }
                .prefix(Self.harnessLimit).map(\.key)
        }
        var shadeByHarness: [Harness: Double] = [:]
        var seenPerCompany: [ToolType: Int] = [:]
        for harness in keep {
            let index = seenPerCompany[harness.company, default: 0]
            seenPerCompany[harness.company] = index + 1
            shadeByHarness[harness] = max(0.35, 0.9 - Double(index) * 0.3)
        }
        for point in points {
            var bar: [UsageTrendSegment] = []
            if bySplit {
                var other: Double = 0
                for value in point.byHarness {
                    let amount = Double(metric == .cost ? value.costMicros : value.tokens)
                    if let shade = shadeByHarness[value.harness] {
                        bar.append(UsageTrendSegment(
                            start: point.start, key: value.harness.rawValue, label: value.harness.displayName,
                            value: amount, tint: value.harness.usageTint.opacity(shade)
                        ))
                    } else {
                        other += amount
                    }
                }
                bar.sort { lhs, rhs in
                    (keep.firstIndex { $0.rawValue == lhs.key } ?? 0) < (keep.firstIndex { $0.rawValue == rhs.key } ?? 0)
                }
                if other > 0 {
                    bar.append(UsageTrendSegment(
                        start: point.start, key: "other", label: L10n.Usage.Mix.other, value: other, tint: .gray.opacity(0.55)
                    ))
                }
            } else {
                switch metric {
                case .tokens:
                    bar = [
                        UsageTrendSegment(start: point.start, key: "in", label: L10n.Workbench.Usage.Tokens.prompt,
                                          value: Double(point.promptTokens), tint: UsageTrendMetric.tokens.tint.opacity(0.85)),
                        UsageTrendSegment(start: point.start, key: "out", label: L10n.Usage.Tokens.output,
                                          value: Double(point.outputTokens), tint: UsageTrendMetric.output.tint.opacity(0.85)),
                    ]
                case .output:
                    bar = [UsageTrendSegment(start: point.start, key: "out", label: metric.title, value: Double(point.outputTokens), tint: metric.tint.opacity(0.85))]
                case .requests:
                    bar = [UsageTrendSegment(start: point.start, key: "n", label: metric.title, value: Double(point.requests), tint: metric.tint.opacity(0.85))]
                case .sessions:
                    bar = [UsageTrendSegment(start: point.start, key: "n", label: metric.title, value: Double(point.sessions), tint: metric.tint.opacity(0.85))]
                case .cost:
                    bar = [UsageTrendSegment(start: point.start, key: "n", label: metric.title, value: Double(point.costMicros), tint: metric.tint.opacity(0.85))]
                case .active:
                    bar = [UsageTrendSegment(start: point.start, key: "n", label: metric.title, value: Double(point.activeHours), tint: metric.tint.opacity(0.85))]
                }
            }
            parts.append(bar)
            segments.append(contentsOf: bar.filter { $0.value > 0 })
        }
        isEmpty = segments.isEmpty
        var seen: Set<String> = []
        legend = parts.flatMap { $0 }.filter { seen.insert($0.key).inserted }
        if bySplit {
            legend.sort { lhs, rhs in
                (keep.firstIndex { $0.rawValue == lhs.key } ?? Int.max) < (keep.firstIndex { $0.rawValue == rhs.key } ?? Int.max)
            }
        }
        switch metric {
        case .tokens: subtitle = UsageDashboardFormat.tokens(points.reduce(0) { $0 + $1.totalTokens })
        case .output: subtitle = UsageDashboardFormat.tokens(points.reduce(0) { $0 + $1.outputTokens })
        case .requests: subtitle = L10n.Usage.requestCount(count: AppLocale.number(points.reduce(0) { $0 + $1.requests }))
        // Sessions span days: a sum of daily counts would count one many times.
        case .sessions: subtitle = nil
        case .cost: subtitle = UsageFormatting.compactUSD(points.reduce(0) { $0 + $1.costMicros })
        case .active: subtitle = L10n.Workbench.Usage.Count.activeHours(count: points.reduce(0) { $0 + $1.activeHours })
        }
    }
}

/// The trend card: one metric at a time, hourly for Today, daily up to 120
/// days and weekly past that — the buckets `UsageEventLedger.trend` draws.
///
/// The marks live in `UsageTrendBars`, an `Equatable` view rebuilt only when
/// the plan changes; the crosshair and tooltip live in `UsageTrendHover`
/// under `.chartOverlay`, which owns the hover state — so a pointer move
/// re-renders the overlay and not one bar (the `QuotaHistoryChartView`
/// pattern; AGENTS.md § 7). The plan is derived in `onChange`, not in `body`.
struct UsageTrendChartView: View, Equatable {
    let density: Theme.Density
    let trend: UsageDashboardSnapshot.Trend

    @State private var metric: UsageTrendMetric = .tokens
    @State private var split: UsageTrendSplit = .flow
    @State private var plan = UsageTrendPlan()

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.density == rhs.density && lhs.trend == rhs.trend
    }

    private var title: String {
        switch trend.bucket {
        case .week: L10n.Workbench.Usage.Trend.titleWeekly
        case .day, .hour: L10n.Workbench.Usage.Trend.titleDaily
        }
    }

    var body: some View {
        CardShell(density: density, spacing: 12) {
            UsageCardHeader(density: density, title: title, subtitle: plan.subtitle) {
                HStack(spacing: 8) {
                    if metric.canSplitByHarness {
                        UsagePillPicker(
                            options: UsageTrendSplit.allCases,
                            title: \.title,
                            selection: $split,
                            accessibilityLabel: L10n.Usage.Table.Column.harness
                        )
                    }
                    UsagePillPicker(
                        options: UsageTrendMetric.allCases,
                        title: \.title,
                        selection: $metric,
                        accessibilityLabel: L10n.Workbench.Usage.Trend.a11y
                    )
                }
            }
            if plan.isEmpty {
                UsageEmptyMessage(density: density, text: L10n.Workbench.Usage.Trend.empty, systemImage: "chart.bar")
                    .frame(height: 190)
            } else {
                UsageTrendBars(plan: plan, metric: metric, bucket: trend.bucket)
                    .equatable()
                    .frame(height: 190)
                if plan.legend.count > 1 {
                    legend
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { rebuild() }
        .onChange(of: trend) { _, _ in rebuild() }
        .onChange(of: metric) { _, _ in rebuild() }
        .onChange(of: split) { _, _ in rebuild() }
    }

    private func rebuild() {
        plan = UsageTrendPlan(trend: trend, metric: metric, split: split)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(plan.legend) { item in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(item.tint)
                        .frame(width: 8, height: 8)
                    Text(item.label)
                }
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }
}

/// The plotted bars. ≤ 120 bars × ≤ 7 parts = ≤ 840 marks.
struct UsageTrendBars: View, Equatable {
    let plan: UsageTrendPlan
    let metric: UsageTrendMetric
    let bucket: UsageDashboardSnapshot.Trend.Bucket

    private var unit: Calendar.Component {
        switch bucket {
        case .hour: .hour
        case .day: .day
        case .week: .weekOfYear
        }
    }

    var body: some View {
        Chart(plan.segments) { segment in
            BarMark(
                x: .value("Period", segment.start, unit: unit),
                y: .value("Value", segment.value)
            )
            .foregroundStyle(segment.tint)
            .cornerRadius(2)
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text(metric.format(raw))
                            .font(.system(size: 9, design: .rounded).monospacedDigit())
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.08))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(bucket == .hour ? AppLocale.string(date, template: "HHmm") : UsageDashboardFormat.day(date))
                            .font(.system(size: 9))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            UsageTrendHover(proxy: proxy, plan: plan, metric: metric, bucket: bucket)
        }
        .accessibilityLabel(L10n.Workbench.Usage.Trend.a11y)
    }
}

/// Crosshair and tooltip. Its own view with its own state, so hovering
/// re-renders this and nothing above it; a pointer move costs one binary
/// search.
private struct UsageTrendHover: View {
    let proxy: ChartProxy
    let plan: UsageTrendPlan
    let metric: UsageTrendMetric
    let bucket: UsageDashboardSnapshot.Trend.Bucket

    @State private var hoveredIndex: Int?

    private var halfBucket: TimeInterval {
        switch bucket {
        case .hour: 1_800
        case .day: 43_200
        case .week: 302_400
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let plot = proxy.plotFrame.map { geometry[$0] }
            let plotMinX = plot?.minX ?? 0
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoveredIndex = proxy.value(atX: location.x - plotMinX, as: Date.self).flatMap(index(at:))
                        case .ended:
                            hoveredIndex = nil
                        }
                    }
                if let hoveredIndex, plan.starts.indices.contains(hoveredIndex), let plot {
                    let start = plan.starts[hoveredIndex]
                    let x = proxy.position(forX: start.addingTimeInterval(halfBucket)) ?? 0
                    Rectangle()
                        .fill(Color.primary.opacity(0.18))
                        .frame(width: 1, height: plot.height)
                        .offset(x: plotMinX + min(max(0, x), plot.width), y: plot.minY)
                        .allowsHitTesting(false)
                    tooltip(start: start, parts: plan.parts[hoveredIndex])
                        .offset(x: min(max(0, plotMinX + x - 80), max(0, geometry.size.width - 190)), y: plot.minY + 4)
                }
            }
        }
    }

    private func index(at date: Date) -> Int? {
        let starts = plan.starts
        guard !starts.isEmpty else { return nil }
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= date { low = mid } else { high = mid - 1 }
        }
        return starts[low] <= date ? low : nil
    }

    private func tooltip(start: Date, parts: [UsageTrendSegment]) -> some View {
        UsageTooltip {
            Text(heading(start)).fontWeight(.semibold)
            ForEach(parts) { part in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(part.tint)
                        .frame(width: 7, height: 7)
                    Text(part.label).foregroundStyle(.secondary)
                    Spacer(minLength: 10)
                    Text(metric.format(part.value)).fontWeight(.semibold)
                }
            }
        }
    }

    private func heading(_ start: Date) -> String {
        switch bucket {
        case .hour: AppLocale.string(start, template: "EEEMMMdHHmm")
        case .day: AppLocale.string(start, template: "EEEMMMd")
        case .week: L10n.Cost.History.weekOf(date: UsageDashboardFormat.day(start))
        }
    }
}
