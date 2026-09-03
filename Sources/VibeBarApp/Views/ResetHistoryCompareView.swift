import SwiftUI
import VibeBarCore

// MARK: - Lane discovery

/// Turns the live quotas plus the recorded cycle history into the pure inputs
/// `ResetHistoryComparison` aggregates.
///
/// Reads only what is already in memory — the cached quotas and the published
/// history dictionary. No I/O, no fetch, no forecast: this runs inside a
/// render pass.
enum ResetHistoryLanes {
    /// - Parameter tools: restricts the module to one provider family (a
    ///   provider detail page passes `googleAIPair` / `grokFamily` so the
    ///   Google AI page keeps showing AntiGravity next to Gemini Web). `nil`
    ///   means every dedicated provider the user has left visible.
    @MainActor
    static func inputs(
        environment: AppEnvironment,
        tools: [ToolType]? = nil
    ) -> [ResetHistoryLaneInput] {
        let settings = environment.settingsStore.settings
        let history = environment.quotaService.historyByAccountBucket
        let registry = environment.quotaService.fieldRegistry
        // Every bucket the history remembers, grouped once. Walking the whole
        // dictionary per account would be O(accounts x lanes) for an answer
        // that does not change between accounts.
        var recordedByAccount: [String: [SubscriptionHistoryKey]] = [:]
        for key in history.keys {
            recordedByAccount[key.accountId, default: []].append(key)
        }
        var out: [ResetHistoryLaneInput] = []
        // Canonical provider order, so the `.company` grouping is the app's
        // own order rather than an alphabetical reshuffle.
        for tool in ToolType.dedicatedCardProviders {
            if let tools {
                guard tools.contains(tool) else { continue }
            } else {
                guard settings.isCoreProviderVisible(tool) else { continue }
            }
            // Every account, not the first: multi-account providers refill
            // per account, and each account is its own lane.
            let accounts = environment.accountStore.accounts(for: tool)
            for account in accounts {
                // Not `guard let`: an account with no cached quota can still
                // have recorded cycles, and dropping it here is exactly how a
                // renamed bucket used to vanish.
                let quota = environment.quotaService.cachedQuota(for: account.id)
                let accountLabel = accounts.count > 1 ? account.displayLabel : nil
                var liveBucketIds: Set<String> = []
                for bucket in quota?.buckets ?? [] {
                    liveBucketIds.insert(bucket.id)
                    let key = SubscriptionHistoryKey(accountId: account.id, bucketId: bucket.id)
                    let subProvider = tool.quotaSubProviderName(bucketID: bucket.id)
                    let trimmed = bucket.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                    // A group titled after its own SubProvider is the primary
                    // lane (Grok Bot), not a model group.
                    let group = (trimmed?.isEmpty ?? true)
                        || trimmed?.caseInsensitiveCompare(subProvider) == .orderedSame
                        ? nil : trimmed
                    out.append(
                        ResetHistoryLaneInput(
                            accountId: account.id,
                            tool: tool,
                            bucketId: bucket.id,
                            company: tool.vendorName,
                            subProvider: subProvider,
                            groupTitle: group,
                            bucketTitle: bucket.title,
                            accountLabel: accountLabel,
                            liveWindowSeconds: bucket.rawWindowSeconds,
                            currentUsedPercent: bucket.usedPercent,
                            currentResetAt: bucket.resetAt,
                            // COW: this is a retain, not a copy, which is what
                            // makes the cache's equality check cheap.
                            samples: history[key] ?? []
                        )
                    )
                }
                // Buckets the provider has stopped returning. Their cycles are
                // still in the history, and a weekly model limit that was
                // renamed away is precisely the one whose waste record the
                // user would otherwise never see again. No current cycle:
                // there is no live bucket to read one from.
                for key in (recordedByAccount[account.id] ?? []).sorted(by: { $0.bucketId < $1.bucketId }) {
                    guard !liveBucketIds.contains(key.bucketId),
                          let samples = history[key], !samples.isEmpty
                    else { continue }
                    // Identity comes from the samples themselves: the account
                    // pins the tool, but a sample records its own, which is
                    // what names a bucket whose adapter serves two
                    // SubProviders. A tool outside this page's scope falls
                    // back to the account's rather than leaking onto it.
                    let sampleTool = samples[0].tool
                    let laneTool = (tools?.contains(sampleTool) ?? true) ? sampleTool : tool
                    out.append(
                        ResetHistoryLaneInput(
                            accountId: account.id,
                            tool: laneTool,
                            bucketId: key.bucketId,
                            company: laneTool.vendorName,
                            subProvider: laneTool.quotaSubProviderName(bucketID: key.bucketId),
                            groupTitle: nil,
                            bucketTitle: retiredBucketTitle(
                                tool: laneTool,
                                bucketId: key.bucketId,
                                registry: registry
                            ),
                            accountLabel: accountLabel,
                            liveWindowSeconds: nil,
                            currentUsedPercent: nil,
                            currentResetAt: nil,
                            samples: samples
                        )
                    )
                }
            }
        }
        return out
    }

    /// What to call a bucket no live quota carries any more.
    ///
    /// The mini-window catalog already names buckets — the static table for
    /// the ones this build ships with, `QuotaFieldRegistry` for the ones an
    /// adapter discovered at runtime, which it keeps precisely so a bucket
    /// survives the provider dropping it. Its titles are already in the
    /// "group / window" form the lane label wants ("Fable / Weekly"), so the
    /// group slot stays empty. Only when neither knows the bucket does this
    /// fall back to the id, spaced out rather than left as a raw token.
    static func retiredBucketTitle(
        tool: ToolType,
        bucketId: String,
        registry: QuotaFieldRegistry
    ) -> String {
        let fieldId = MenuBarFieldCatalog.fieldId(tool: tool, bucketId: bucketId)
        if let known = MenuBarFieldCatalog.field(id: fieldId, registry: registry) {
            return known.title
        }
        return bucketId
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

// MARK: - Memo

/// One built comparison, kept until its inputs change.
///
/// The aggregation walks every recorded cycle on the Mac, which is not work a
/// `body` may do per render (`AGENTS.md` § 7). Equality on the inputs is what
/// makes the memo cheap: `[SubscriptionWindowSample]` short-circuits on
/// identical storage, so an unchanged history costs one pointer compare per
/// lane.
@MainActor
final class ResetHistoryComparisonCache {
    private struct Key: Equatable {
        let inputs: [ResetHistoryLaneInput]
        let window: ResetHistoryComparison.Window
        let ordering: ResetHistoryComparison.Ordering
        let hour: Double
    }

    private var key: Key?
    private var value: ResetHistoryComparison?

    func comparison(
        inputs: [ResetHistoryLaneInput],
        window: ResetHistoryComparison.Window,
        ordering: ResetHistoryComparison.Ordering,
        now: Date = Date()
    ) -> ResetHistoryComparison {
        // The visible span is anchored to now, so the clock is an input — but
        // quantized to the hour. A weeks-wide axis does not move within one,
        // and this module starts no timer of its own: the next quota refresh
        // redraws it.
        let hour = (now.timeIntervalSinceReferenceDate / 3_600).rounded(.down) * 3_600
        let candidate = Key(inputs: inputs, window: window, ordering: ordering, hour: hour)
        if let key, key == candidate, let value { return value }
        let built = ResetHistoryComparison.build(
            inputs: inputs,
            window: window,
            ordering: ordering,
            now: Date(timeIntervalSinceReferenceDate: hour)
        )
        key = candidate
        value = built
        return built
    }
}

// MARK: - Card

/// Every weekly-and-longer quota's reset history, side by side on one time
/// axis: where quota is being thrown away, and where it is being spent.
///
/// Same bar semantics as `FillTimelineChart`, which shows one lane inside its
/// own quota card — height is the peak used percent, the muted remainder above
/// it is what expired unused, a dashed outline is the cycle still running, and
/// a dot over a bar means the window refilled before it said it would. The two
/// surfaces are one system; changing a colour or a marker here means changing
/// it there.
///
/// Five-hour lanes are excluded by `ResetHistoryComparison` itself — see the
/// note there for why, and why the cut is made on the window length rather
/// than on a bucket name.
struct ResetHistoryCompareCard: View {
    let density: Theme.Density
    /// Provider family this instance is scoped to. `nil` on the Overview and
    /// in the Workbench, which compare everything.
    var tools: [ToolType]?
    var titleOverride: String?

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore
    /// Observed: the module's whole content is this service's published
    /// history plus its cached quotas.
    @EnvironmentObject private var quotaService: QuotaService

    @State private var window: ResetHistoryComparison.Window = .eightWeeks
    @State private var groupByCompany = false
    @State private var cache = ResetHistoryComparisonCache()

    var body: some View {
        let comparison = cache.comparison(
            inputs: ResetHistoryLanes.inputs(environment: environment, tools: tools),
            window: window,
            ordering: groupByCompany ? .company : .waste
        )
        CardShell(density: density, spacing: 8) {
            header
            summary(comparison)
            if comparison.isEmpty {
                Text("Nothing to compare yet — weekly and longer quotas appear here once a provider reports one.")
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
            } else {
                ResetHistoryCompareView(comparison: comparison, density: density)
            }
        }
    }

    private var title: String { titleOverride ?? "Reset History Compare" }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 6)
            groupToggle
            windowPicker
        }
    }

    /// Compact 4w / 8w / 12w / All. The same hand-drawn segment pill the cost
    /// card's metric switch uses, so the two read as one control family.
    private var windowPicker: some View {
        HStack(spacing: 1) {
            ForEach(ResetHistoryComparison.Window.allCases, id: \.self) { option in
                Button {
                    window = option
                } label: {
                    Text(option.shortTitle)
                        .font(.system(size: max(8.5, density.segmentedFontSize - 1.5), weight: .semibold, design: .rounded))
                        .foregroundStyle(window == option ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .frame(minHeight: 17)
                        .contentShape(Rectangle())
                        .background {
                            if window == option {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.primary.opacity(0.12))
                            }
                        }
                }
                .buttonStyle(.vibeBar(cornerRadius: 5))
                .help("Compare the \(option.spokenTitle)")
                .accessibilityLabel("Compare the \(option.spokenTitle)")
                // The fill is the only sighted cue for which span is showing;
                // VoiceOver needs the selection stated outright.
                .accessibilityAddTraits(window == option ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
    }

    private var groupToggle: some View {
        Button {
            groupByCompany.toggle()
        } label: {
            Image(systemName: groupByCompany ? "rectangle.3.group.fill" : "arrow.down.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(groupByCompany ? Color.primary : Color.secondary)
                .frame(width: 19, height: 17)
                .contentShape(Rectangle())
                .background {
                    if groupByCompany {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.12))
                    }
                }
        }
        .buttonStyle(.vibeBar(cornerRadius: 5))
        .help(
            groupByCompany
                ? "Grouped by company — switch back to most wasted first"
                : "Sorted by most wasted — group by company instead"
        )
        .accessibilityLabel("Group quotas by company")
        .accessibilityAddTraits(groupByCompany ? [.isSelected] : [])
        .padding(.trailing, 2)
    }

    /// The header's arithmetic and the one plain sentence under it.
    private func summary(_ comparison: ResetHistoryComparison) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(comparison.totals.headline)
                .font(.system(size: density.subtitleFontSize, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
            Text(comparison.verdict)
                .font(.system(size: max(9, density.subtitleFontSize - 0.5)))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Geometry

/// Row metrics plus the time→x mapping, resolved once and shared by the
/// drawing surface and the hit test — so the tooltip can never describe a bar
/// the cursor is not actually over.
struct ResetHistoryCompareLayout: Equatable {
    let rowHeight: CGFloat
    let labelWidth: CGFloat
    /// Band above each track holding the early-refill dots.
    let markerBand: CGFloat = 5
    /// Gap under each track.
    let rowGap: CGFloat = 6
    let labelGap: CGFloat = 8
    let axisHeight: CGFloat = 13
    let titleFontSize: CGFloat
    let captionFontSize: CGFloat
    let rangeStart: Date
    let rangeEnd: Date
    let now: Date
    /// Height of a company heading. Zero unless the rows are grouped, so the
    /// ungrouped layout is byte-for-byte the one it always was.
    let headingHeight: CGFloat
    /// What the surface draws, top to bottom.
    let rows: [Row]
    /// Y of each row in `rows`.
    let rowTops: [CGFloat]
    /// Y of each lane, indexed by its position in `comparison.lanes`. The
    /// headings push these down, which is the whole reason the geometry is
    /// resolved once and shared instead of derived from an index twice.
    let laneTops: [CGFloat]

    enum Row: Equatable {
        case heading(String)
        case lane(Int)
    }

    init(density: Theme.Density, comparison: ResetHistoryComparison) {
        // Two text lines and a bar per row. Deliberately tight: a dozen
        // weekly-and-longer quotas have to fit on one screen, which is the
        // whole point of the module.
        switch density.profile {
        case .compact:
            rowHeight = 38
            labelWidth = 142
        case .regular:
            rowHeight = 44
            labelWidth = 164
        case .spacious:
            rowHeight = 52
            labelWidth = 190
        }
        titleFontSize = max(9, density.subtitleFontSize - 0.5)
        captionFontSize = max(8, density.subtitleFontSize - 2)
        rangeStart = comparison.rangeStart
        rangeEnd = comparison.rangeEnd
        now = comparison.now

        let grouped = comparison.ordering == .company
        let heading = grouped ? max(16, titleFontSize + 8) : 0
        headingHeight = heading
        var rows: [Row] = []
        var rowTops: [CGFloat] = []
        var laneTops: [CGFloat] = []
        var y: CGFloat = 0
        var currentCompany: String?
        for (index, lane) in comparison.lanes.enumerated() {
            if grouped, lane.company != currentCompany {
                currentCompany = lane.company
                rows.append(.heading(lane.company))
                rowTops.append(y)
                y += heading
            }
            rows.append(.lane(index))
            rowTops.append(y)
            laneTops.append(y)
            y += rowHeight
        }
        self.rows = rows
        self.rowTops = rowTops
        self.laneTops = laneTops
        rowsHeight = y
    }

    /// Total height of the rows, headings included.
    let rowsHeight: CGFloat

    var totalHeight: CGFloat { rowsHeight + axisHeight }
    var chartX: CGFloat { labelWidth + labelGap }

    func chartWidth(in size: CGSize) -> CGFloat { max(20, size.width - chartX) }
    func laneTop(_ index: Int) -> CGFloat {
        index >= 0 && index < laneTops.count ? laneTops[index] : 0
    }
    func trackTop(_ index: Int) -> CGFloat { laneTop(index) + markerBand }
    func trackBottom(_ index: Int) -> CGFloat { laneTop(index) + rowHeight - rowGap }

    /// The lane under a pointer, or `nil` over a heading, a gap, or the axis.
    /// Never `y / rowHeight`: with headings in the stack that arithmetic is
    /// off by one row per company.
    func laneIndex(atY y: CGFloat) -> Int? {
        for (index, top) in laneTops.enumerated() where y >= top && y < top + rowHeight {
            return index
        }
        return nil
    }

    /// Bars per lane the row has room for. Three points is already narrower
    /// than a bar the eye can separate.
    func drawBudget(in size: CGSize) -> Int { max(4, Int(chartWidth(in: size) / 3)) }

    func x(for date: Date, in size: CGSize) -> CGFloat {
        let span = max(1, rangeEnd.timeIntervalSince(rangeStart))
        let fraction = date.timeIntervalSince(rangeStart) / span
        return chartX + chartWidth(in: size) * CGFloat(fraction)
    }

    /// One bar's rectangle, clamped to the visible axis. `nil` when the cycle
    /// falls entirely outside it.
    func barRect(
        _ cycle: ResetHistoryComparison.Cycle,
        laneIndex: Int,
        in size: CGSize
    ) -> CGRect? {
        let left = x(for: cycle.start, in: size)
        let right = x(for: cycle.end, in: size)
        let minX = chartX
        let maxX = chartX + chartWidth(in: size)
        guard right > minX, left < maxX else { return nil }
        let clampedLeft = max(minX, left)
        let clampedRight = min(maxX, right)
        // One point of air between neighbours, and never thinner than a bar
        // the eye can find.
        let width = max(2, clampedRight - clampedLeft - 1)
        let top = trackTop(laneIndex)
        return CGRect(x: clampedLeft, y: top, width: width, height: trackBottom(laneIndex) - top)
    }

    /// Six evenly spaced dates across the visible span.
    var ticks: [Date] {
        let span = rangeEnd.timeIntervalSince(rangeStart)
        guard span > 0 else { return [] }
        let count = 5
        return (0...count).map { index in
            rangeStart.addingTimeInterval(span * Double(index) / Double(count))
        }
    }
}

// MARK: - Small multiples

/// Every lane on one shared time axis.
///
/// The bars are a single `Canvas` (`AGENTS.md` § 11: dense status history is
/// one drawing surface, not hundreds of views) held behind `.equatable()`, so
/// moving the pointer across fifteen lanes re-renders the hover highlight and
/// one tooltip — never the several hundred bars underneath them.
struct ResetHistoryCompareView: View {
    let comparison: ResetHistoryComparison
    let density: Theme.Density

    @State private var hover: Hover?

    private struct Hover: Equatable {
        let laneIndex: Int
        let cycleID: String
        let point: CGPoint
    }

    var body: some View {
        let layout = ResetHistoryCompareLayout(density: density, comparison: comparison)
        VStack(alignment: .leading, spacing: 5) {
            legend
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    ResetHistoryLanesCanvas(comparison: comparison, layout: layout)
                        .equatable()
                    if let hover, let rect = hoveredRect(hover, in: proxy.size, layout: layout) {
                        RoundedRectangle(cornerRadius: min(2.5, rect.width / 2) + 1, style: .continuous)
                            .stroke(Color.primary.opacity(0.5), lineWidth: 1)
                            .frame(width: rect.width + 2, height: rect.height + 2)
                            .offset(x: rect.minX - 1, y: rect.minY - 1)
                            .allowsHitTesting(false)
                    }
                    if let hover, let cycle = cycle(for: hover) {
                        tooltip(lane: comparison.lanes[hover.laneIndex], cycle: cycle)
                            .offset(tooltipOffset(hover, in: proxy.size))
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        let next = hit(location, in: proxy.size, layout: layout)
                        if next != hover { hover = next }
                    case .ended:
                        hover = nil
                    }
                }
            }
            .frame(height: layout.totalHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(comparison.accessibilitySummary)
        }
    }

    // MARK: Legend

    /// One composite swatch rather than three abstractions of it: the reader
    /// is being told how to read a bar, and the swatch *is* a bar.
    private var legend: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 6, height: 9)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.secondary)
                        .frame(width: 6, height: 5)
                }
                Text("bar height = used, grey remainder = wasted")
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 0.8, dash: [2, 1.5]))
                    .frame(width: 6, height: 9)
                Text("current")
            }
            HStack(spacing: 3) {
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 3, height: 3)
                Text("refilled early")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: max(7.5, density.subtitleFontSize - 3), design: .rounded))
        .foregroundStyle(.tertiary)
    }

    // MARK: Hover

    private func hit(
        _ location: CGPoint,
        in size: CGSize,
        layout: ResetHistoryCompareLayout
    ) -> Hover? {
        guard let index = layout.laneIndex(atY: location.y),
              index < comparison.lanes.count
        else { return nil }
        let lane = comparison.lanes[index]
        var candidates = ResetHistoryComparison.downsampled(
            lane.cycles,
            limit: layout.drawBudget(in: size)
        )
        if let current = lane.currentCycle { candidates.append(current) }
        // Reverse order matches the draw order: the current cycle is painted
        // last and is therefore the one on top.
        for cycle in candidates.reversed() {
            guard let rect = layout.barRect(cycle, laneIndex: index, in: size) else { continue }
            if location.x >= rect.minX - 1, location.x <= rect.maxX + 1 {
                return Hover(laneIndex: index, cycleID: cycle.id, point: location)
            }
        }
        return nil
    }

    private func cycle(for hover: Hover) -> ResetHistoryComparison.Cycle? {
        guard hover.laneIndex < comparison.lanes.count else { return nil }
        let lane = comparison.lanes[hover.laneIndex]
        if let match = lane.cycles.first(where: { $0.id == hover.cycleID }) { return match }
        return lane.currentCycle?.id == hover.cycleID ? lane.currentCycle : nil
    }

    private func hoveredRect(
        _ hover: Hover,
        in size: CGSize,
        layout: ResetHistoryCompareLayout
    ) -> CGRect? {
        guard let cycle = cycle(for: hover) else { return nil }
        return layout.barRect(cycle, laneIndex: hover.laneIndex, in: size)
    }

    private func tooltip(
        lane: ResetHistoryComparison.Lane,
        cycle: ResetHistoryComparison.Cycle
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(Theme.providerAccent(for: lane.tool))
                    .frame(width: 5, height: 5)
                Text(lane.label)
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(dateRange(cycle))
                .font(.system(size: 9, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
            Text(
                cycle.isCompleted
                    ? "\(Int(cycle.usedPercent.rounded()))% used · \(Int(cycle.wastedPercent.rounded()))% wasted"
                    : "Current cycle · \(Int(cycle.usedPercent.rounded()))% used so far · \(Int(cycle.wastedPercent.rounded()))% left"
            )
            .font(.system(size: 9, design: .rounded).monospacedDigit())
            .foregroundStyle(.primary.opacity(0.85))
            if !cycle.resetDescription.isEmpty {
                Text(cycle.resetDescription)
                    .font(.system(size: 8.5, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: Self.tooltipWidth, alignment: .leading)
        // Opaque, not shadowed or glassy: the flat language's way of saying
        // "this is on top" (docs/DESIGN.md § 2).
        .workbenchOverlaySurface(in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private static let tooltipWidth: CGFloat = 236

    private func tooltipOffset(_ hover: Hover, in size: CGSize) -> CGSize {
        let x = min(max(0, hover.point.x - Self.tooltipWidth / 2), max(0, size.width - Self.tooltipWidth))
        // Above the hovered row when there is room for it, below otherwise.
        let above = hover.point.y > 76
        return CGSize(width: x, height: above ? hover.point.y - 74 : hover.point.y + 14)
    }

    private func dateRange(_ cycle: ResetHistoryComparison.Cycle) -> String {
        let start = ResetHistoryCompareFormatters.tooltip.string(from: cycle.start)
        let end = ResetHistoryCompareFormatters.tooltip.string(from: cycle.end)
        return cycle.isCompleted ? "\(start) → \(end) reset" : "\(start) → \(end) reset due"
    }
}

// MARK: - The drawing surface

/// The bars, the labels, the grid and the axis — one `Canvas`, no per-cell
/// views and no `.help()` per bar.
///
/// `Equatable` so hover, which changes several times a second, cannot drag the
/// whole surface through a redraw with it. The value is the comparison plus
/// the geometry; nothing else here reads state.
private struct ResetHistoryLanesCanvas: View, Equatable {
    let comparison: ResetHistoryComparison
    let layout: ResetHistoryCompareLayout

    static func == (lhs: ResetHistoryLanesCanvas, rhs: ResetHistoryLanesCanvas) -> Bool {
        lhs.layout == rhs.layout && lhs.comparison == rhs.comparison
    }

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            drawGrid(&context, size: size)
            for (row, top) in zip(layout.rows, layout.rowTops) {
                switch row {
                case let .heading(company):
                    drawHeading(
                        &context,
                        company: company,
                        top: top,
                        isFirst: top == 0,
                        size: size
                    )
                case let .lane(index):
                    let lane = comparison.lanes[index]
                    drawLabels(&context, lane: lane, index: index)
                    drawLane(&context, lane: lane, index: index, size: size)
                }
            }
            drawAxis(&context, size: size)
        }
    }

    /// Week gridlines behind every row, plus the *now* hairline — the same
    /// "the leading hairline is now" idiom the refill-horizon lane uses.
    private func drawGrid(_ context: inout GraphicsContext, size: CGSize) {
        for tick in layout.ticks {
            let tickX = layout.x(for: tick, in: size)
            context.fill(
                Path(CGRect(x: tickX, y: 0, width: 0.5, height: layout.rowsHeight)),
                with: .color(Color.primary.opacity(0.07))
            )
        }
        let nowX = layout.x(for: min(layout.rangeEnd, layout.now), in: size)
        if nowX >= layout.chartX, nowX <= layout.chartX + layout.chartWidth(in: size) {
            context.fill(
                Path(CGRect(x: nowX - 0.5, y: 0, width: 1, height: layout.rowsHeight)),
                with: .color(Color.primary.opacity(0.28))
            )
        }
    }

    /// One L1 company band: a rule across the full width and the company's
    /// name over it. Without this the grouped ordering strips the company off
    /// every row and puts it nowhere — "Gemini Web" and "AntiGravity" sitting
    /// under no Google AI at all.
    private func drawHeading(
        _ context: inout GraphicsContext,
        company: String,
        top: CGFloat,
        isFirst: Bool,
        size: CGSize
    ) {
        if !isFirst {
            context.fill(
                Path(CGRect(x: 0, y: top + 1, width: size.width, height: 0.5)),
                with: .color(Color.primary.opacity(0.12))
            )
        }
        context.draw(
            truncated(
                context,
                company.uppercased(),
                font: .system(size: max(8, layout.captionFontSize), weight: .bold),
                color: Color.primary.opacity(0.55),
                maxWidth: max(20, size.width),
                tracking: 0.5
            ),
            at: CGPoint(x: 0, y: top + layout.headingHeight - 4),
            anchor: .bottomLeading
        )
    }

    private func drawLabels(
        _ context: inout GraphicsContext,
        lane: ResetHistoryComparison.Lane,
        index: Int
    ) {
        let maxWidth = layout.labelWidth - layout.labelGap
        let top = layout.laneTop(index) + layout.markerBand - 2
        // Grouped by company, the heading carries the company; sorted by
        // waste, each row has to name itself in full.
        let title = comparison.ordering == .company ? lane.labelWithoutCompany : lane.label
        context.draw(
            truncated(
                context,
                title,
                font: .system(size: layout.titleFontSize, weight: .semibold),
                color: Color.primary.opacity(0.88),
                maxWidth: maxWidth
            ),
            at: CGPoint(x: 0, y: top),
            anchor: .topLeading
        )
        context.draw(
            truncated(
                context,
                lane.wasteSummary,
                font: .system(size: layout.captionFontSize, design: .rounded),
                color: Color.primary.opacity(0.5),
                maxWidth: maxWidth
            ),
            at: CGPoint(x: 0, y: top + layout.titleFontSize + 4),
            anchor: .topLeading
        )
    }

    private func drawLane(
        _ context: inout GraphicsContext,
        lane: ResetHistoryComparison.Lane,
        index: Int,
        size: CGSize
    ) {
        let baseline = layout.trackBottom(index)
        let chartWidth = layout.chartWidth(in: size)
        context.fill(
            Path(CGRect(x: layout.chartX, y: baseline - 0.5, width: chartWidth, height: 0.5)),
            with: .color(Color.primary.opacity(0.10))
        )
        guard !lane.cycles.isEmpty || lane.currentCycle != nil else {
            context.draw(
                truncated(
                    context,
                    lane.emptyStateText,
                    font: .system(size: layout.captionFontSize),
                    color: Color.primary.opacity(0.35),
                    maxWidth: chartWidth - 8
                ),
                at: CGPoint(x: layout.chartX + 4, y: (layout.trackTop(index) + baseline) / 2),
                anchor: .leading
            )
            return
        }
        // Downsample before drawing: a lane can hold more cycles than the row
        // has pixels, and the wasteful ones are exactly the ones that must
        // survive the cut.
        let accent = Theme.providerAccent(for: lane.tool)
        for cycle in ResetHistoryComparison.downsampled(lane.cycles, limit: layout.drawBudget(in: size)) {
            drawBar(&context, cycle: cycle, laneIndex: index, accent: accent, size: size)
        }
        if let current = lane.currentCycle {
            drawBar(&context, cycle: current, laneIndex: index, accent: accent, size: size)
        }
    }

    private func drawBar(
        _ context: inout GraphicsContext,
        cycle: ResetHistoryComparison.Cycle,
        laneIndex: Int,
        accent: Color,
        size: CGSize
    ) {
        guard let rect = layout.barRect(cycle, laneIndex: laneIndex, in: size) else { return }
        let radius = min(2.5, rect.width / 2)
        // The track is the wasted remainder; the fill is what was spent. The
        // same two-part bar `FillTimelineChart` draws for a single lane.
        context.fill(
            Path(roundedRect: rect, cornerRadius: radius, style: .continuous),
            with: .color(Theme.barTrack.opacity(0.62))
        )
        let fillHeight = cycle.usedPercent > 0 ? max(1, rect.height * cycle.usedPercent / 100) : 0
        if fillHeight > 0 {
            let fillRect = CGRect(
                x: rect.minX,
                y: rect.maxY - fillHeight,
                width: rect.width,
                height: fillHeight
            )
            context.fill(
                Path(roundedRect: fillRect, cornerRadius: min(radius, fillHeight / 2), style: .continuous),
                with: .color(accent.opacity(0.86))
            )
        }
        if !cycle.isCompleted {
            context.stroke(
                Path(roundedRect: rect, cornerRadius: radius, style: .continuous),
                with: .color(accent.opacity(0.9)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 2])
            )
        }
        // Above the bar rather than inside it: a cycle that spent everything
        // fills its track to the top, where a marker would be the same colour
        // as the fill under it.
        if cycle.refilledEarly {
            let dot = CGRect(x: rect.midX - 1.5, y: layout.laneTop(laneIndex) + 1, width: 3, height: 3)
            context.fill(Path(ellipseIn: dot), with: .color(accent.opacity(0.8)))
        }
    }

    private func drawAxis(_ context: inout GraphicsContext, size: CGSize) {
        let y = layout.rowsHeight + 1
        let chartWidth = layout.chartWidth(in: size)
        for tick in layout.ticks {
            let tickX = layout.x(for: tick, in: size)
            guard tickX >= layout.chartX - 1, tickX <= layout.chartX + chartWidth else { continue }
            let text = context.resolve(
                Text(ResetHistoryCompareFormatters.axis.string(from: tick))
                    .font(.system(size: max(7, layout.captionFontSize - 1), design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.4))
            )
            let width = text.measure(in: CGSize(width: 80, height: 20)).width
            // Keep the first and last labels inside the plot instead of
            // letting them hang off either end.
            let clamped = min(
                max(tickX - width / 2, layout.chartX),
                layout.chartX + chartWidth - width
            )
            context.draw(text, at: CGPoint(x: clamped, y: y), anchor: .topLeading)
        }
    }

    /// Single-line text that fits `maxWidth`, with an ellipsis when it does
    /// not. `Canvas` has no truncation of its own, and a wrapped-then-clipped
    /// label reads as a bug. Costs one resolve for a label that already fits,
    /// which is most of them.
    private func truncated(
        _ context: GraphicsContext,
        _ string: String,
        font: Font,
        color: Color,
        maxWidth: CGFloat,
        tracking: CGFloat = 0
    ) -> GraphicsContext.ResolvedText {
        let probe = CGSize(width: 10_000, height: 40)
        func resolve(_ candidate: String) -> GraphicsContext.ResolvedText {
            context.resolve(
                Text(candidate).font(font).tracking(tracking).foregroundStyle(color)
            )
        }
        let full = resolve(string)
        guard maxWidth > 0, full.measure(in: probe).width > maxWidth else { return full }
        let characters = Array(string)
        var low = 0
        var high = characters.count
        var best = ""
        while low <= high {
            let mid = (low + high) / 2
            let candidate = String(characters.prefix(mid)) + "…"
            if resolve(candidate).measure(in: probe).width <= maxWidth {
                best = candidate
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return resolve(best.isEmpty ? "…" : best)
    }
}

private enum ResetHistoryCompareFormatters {
    static let axis: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    static let tooltip: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter
    }()
}
