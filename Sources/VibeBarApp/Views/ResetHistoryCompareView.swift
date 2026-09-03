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
                    out.append(
                        retiredLane(
                            accountId: account.id,
                            bucketId: key.bucketId,
                            tool: (tools?.contains(sampleTool) ?? true) ? sampleTool : tool,
                            accountLabel: accountLabel,
                            samples: samples,
                            registry: registry
                        )
                    )
                }
            }
        }
        out.append(
            contentsOf: signedOutAccountLanes(
                environment: environment,
                settings: settings,
                tools: tools,
                history: history,
                recordedByAccount: recordedByAccount,
                registry: registry
            )
        )
        return out
    }

    /// Lanes for accounts `AccountStore` no longer lists.
    ///
    /// Signing out of a provider, or switching to a different account, removes
    /// the identity while `QuotaService` goes on hydrating its retained
    /// samples — and the Workbench's reset calendar goes on reading them
    /// straight out of `historyByAccountBucket`. Discovering only from the
    /// detected accounts therefore made the same completed cycles visible on
    /// one surface and absent from the comparison next to it.
    ///
    /// The identity is reconstructed from the samples, which carry the tool;
    /// the account id is a privacy-preserving hash and never becomes copy, so
    /// former accounts are labelled positionally instead.
    @MainActor
    private static func signedOutAccountLanes(
        environment: AppEnvironment,
        settings: AppSettings,
        tools: [ToolType]?,
        history: [SubscriptionHistoryKey: [SubscriptionWindowSample]],
        recordedByAccount: [String: [SubscriptionHistoryKey]],
        registry: QuotaFieldRegistry
    ) -> [ResetHistoryLaneInput] {
        // Detected across every provider, not just the in-scope ones: an
        // account that is live under a filtered-out tool has not been signed
        // out of, and must not reappear here as a ghost.
        let detected = Set(
            ToolType.dedicatedCardProviders.flatMap { tool in
                environment.accountStore.accounts(for: tool).map(\.id)
            }
        )
        var keysByTool: [ToolType: [String: [SubscriptionHistoryKey]]] = [:]
        for (accountId, keys) in recordedByAccount where !detected.contains(accountId) {
            for key in keys {
                guard let first = history[key]?.first else { continue }
                keysByTool[first.tool, default: [:]][accountId, default: []].append(key)
            }
        }
        guard !keysByTool.isEmpty else { return [] }

        var out: [ResetHistoryLaneInput] = []
        // Canonical provider order again, so these lanes carry the same
        // company precedence as the live ones.
        for tool in ToolType.dedicatedCardProviders {
            if let tools {
                guard tools.contains(tool) else { continue }
            } else {
                guard settings.isCoreProviderVisible(tool) else { continue }
            }
            guard let accounts = keysByTool[tool] else { continue }
            let accountIds = accounts.keys.sorted()
            for (position, accountId) in accountIds.enumerated() {
                // Numbered only when a provider has more than one former
                // identity, so the ordinary case reads plainly.
                let label = accountIds.count > 1
                    ? "Signed-out account \(position + 1)"
                    : "Signed-out account"
                for key in (accounts[accountId] ?? []).sorted(by: { $0.bucketId < $1.bucketId }) {
                    guard let samples = history[key], !samples.isEmpty else { continue }
                    out.append(
                        retiredLane(
                            accountId: accountId,
                            bucketId: key.bucketId,
                            tool: tool,
                            accountLabel: label,
                            samples: samples,
                            registry: registry
                        )
                    )
                }
            }
        }
        return out
    }

    /// One lane no live bucket backs any more — a withdrawn bucket, or one
    /// belonging to an account that has been signed out of.
    ///
    /// `isRetired` rather than merely leaving the live fields nil: the last
    /// sample of a bucket nothing observes again never closes, and without the
    /// flag it would render as a dashed current cycle forever.
    private static func retiredLane(
        accountId: String,
        bucketId: String,
        tool: ToolType,
        accountLabel: String?,
        samples: [SubscriptionWindowSample],
        registry: QuotaFieldRegistry
    ) -> ResetHistoryLaneInput {
        ResetHistoryLaneInput(
            accountId: accountId,
            tool: tool,
            bucketId: bucketId,
            company: tool.vendorName,
            subProvider: tool.quotaSubProviderName(bucketID: bucketId),
            groupTitle: nil,
            bucketTitle: retiredBucketTitle(tool: tool, bucketId: bucketId, registry: registry),
            accountLabel: accountLabel,
            liveWindowSeconds: nil,
            currentUsedPercent: nil,
            currentResetAt: nil,
            isRetired: true,
            samples: samples
        )
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
        let hour: Double
    }

    private var key: Key?
    private var value: ResetHistoryComparison?

    func comparison(
        inputs: [ResetHistoryLaneInput],
        window: ResetHistoryComparison.Window,
        now: Date = Date()
    ) -> ResetHistoryComparison {
        // The clock decides only whether a cycle has closed since the last
        // build, so it is quantized to the hour. This module starts no timer
        // of its own: the next quota refresh redraws it.
        let hour = (now.timeIntervalSinceReferenceDate / 3_600).rounded(.down) * 3_600
        let candidate = Key(inputs: inputs, window: window, hour: hour)
        if let key, key == candidate, let value { return value }
        let built = ResetHistoryComparison.build(
            inputs: inputs,
            window: window,
            now: Date(timeIntervalSinceReferenceDate: hour)
        )
        key = candidate
        value = built
        return built
    }
}

// MARK: - Card

/// Every weekly-and-longer quota's reset history as one table: how much of
/// each refill expired unused, row by row, cycle by cycle.
///
/// Two decisions carry the design.
///
/// **Columns are cycle ordinals, not dates.** Quotas refill on their own
/// schedules, so a shared calendar axis put every row's bars in different
/// places and made two rows impossible to read against each other. Here the
/// newest completed cycle of every quota sits in the same column, the one
/// before it in the column to its left; a row with less history is
/// right-aligned into the grid and starts further right.
///
/// **The bar is what was left, not what was spent.** The question is "am I
/// wasting quota", so a tall bar is a cycle that expired mostly unused and an
/// empty slot is one that was spent to the last percent. The faint track keeps
/// the empty slot visible.
///
/// Rows are grouped by company and ordered company → SubProvider → group /
/// bucket, the same hierarchy the popover reads in (`AGENTS.md` § 7.1). There
/// is no sort control: a table whose rows move around is not a table.
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

    @State private var window: ResetHistoryComparison.Window = .eight
    @State private var cache = ResetHistoryComparisonCache()

    var body: some View {
        let comparison = cache.comparison(
            inputs: ResetHistoryLanes.inputs(environment: environment, tools: tools),
            window: window
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
            Text("cycles")
                .font(.system(size: max(8, density.subtitleFontSize - 2.5)))
                .foregroundStyle(.quaternary)
            windowPicker
        }
    }

    /// How many cycles back the table reaches. The same hand-drawn segment
    /// pill the cost card's metric switch uses, so the two read as one control
    /// family.
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

/// Row metrics plus the column grid, resolved once and shared by the drawing
/// surface and the hit test — so the tooltip can never describe a bar the
/// cursor is not actually over.
struct ResetHistoryCompareLayout: Equatable {
    /// Height of the bar track. Fixed per density, never per row: the bar
    /// encodes a percentage, so a taller row must not mean a taller bar.
    let trackHeight: CGFloat
    let rowHeight: CGFloat
    let labelWidth: CGFloat
    /// Band above each track holding the early-refill dots.
    let markerBand: CGFloat = 5
    /// Gap under each track.
    let rowGap: CGFloat = 6
    let labelGap: CGFloat = 10
    let axisHeight: CGFloat = 13
    let titleFontSize: CGFloat
    let captionFontSize: CGFloat
    let titleLineHeight: CGFloat
    /// Label lines every row reserves, so the grid stays even whether or not
    /// a particular name needs the second one.
    let titleLineLimit = 2
    let now: Date
    let columns: ResetHistoryComparison.ColumnPlan
    /// Height of a company heading.
    let headingHeight: CGFloat
    /// What the surface draws, top to bottom.
    let rows: [Row]
    /// Y of each row in `rows`.
    let rowTops: [CGFloat]
    /// Y of each lane, indexed by its position in `comparison.lanes`. The
    /// headings push these down, which is the whole reason the geometry is
    /// resolved once and shared instead of derived from an index twice.
    let laneTops: [CGFloat]
    let rowsHeight: CGFloat

    enum Row: Equatable {
        case heading(String)
        case lane(Int)
    }

    init(density: Theme.Density, comparison: ResetHistoryComparison) {
        // Wide enough that "AntiGravity · Claude & GPT Models · Weekly" reads
        // in full — the first version clipped every row at about twenty
        // characters, which is the complaint this layout exists to answer.
        switch density.profile {
        case .compact:
            trackHeight = 26
            labelWidth = 176
        case .regular:
            trackHeight = 30
            labelWidth = 202
        case .spacious:
            trackHeight = 36
            labelWidth = 232
        }
        titleFontSize = max(9, density.subtitleFontSize - 0.5)
        captionFontSize = max(8, density.subtitleFontSize - 2)
        titleLineHeight = titleFontSize + 3
        now = comparison.now
        columns = comparison.columns

        // Two label lines plus the caption, or the bar track, whichever is
        // taller. Uniform per density: this is a table, and a table's rows
        // line up.
        let labelBlock = CGFloat(titleLineLimit) * titleLineHeight + captionFontSize + 4
        let rowHeight = max(trackHeight, labelBlock) + markerBand + rowGap
        self.rowHeight = rowHeight
        headingHeight = max(16, titleFontSize + 8)

        var rows: [Row] = []
        var rowTops: [CGFloat] = []
        var laneTops: [CGFloat] = []
        var y: CGFloat = 0
        var currentCompany: String?
        for (index, lane) in comparison.lanes.enumerated() {
            // One heading per company. The rows arrive grouped, so a change of
            // company is the start of a band.
            if lane.company != currentCompany {
                currentCompany = lane.company
                rows.append(.heading(lane.company))
                rowTops.append(y)
                y += headingHeight
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

    var totalHeight: CGFloat { rowsHeight + axisHeight }
    var chartX: CGFloat { labelWidth + labelGap }

    func chartWidth(in size: CGSize) -> CGFloat { max(20, size.width - chartX) }
    func laneTop(_ index: Int) -> CGFloat {
        index >= 0 && index < laneTops.count ? laneTops[index] : 0
    }
    func trackTop(_ index: Int) -> CGFloat { laneTop(index) + markerBand }
    func trackBottom(_ index: Int) -> CGFloat { trackTop(index) + trackHeight }

    /// The lane under a pointer, or `nil` over a heading, a gap, or the axis.
    func laneIndex(atY y: CGFloat) -> Int? {
        for (index, top) in laneTops.enumerated() where y >= top && y < top + rowHeight {
            return index
        }
        return nil
    }

    func columnWidth(in size: CGSize) -> CGFloat {
        guard columns.totalColumnCount > 0 else { return 0 }
        return chartWidth(in: size) / CGFloat(columns.totalColumnCount)
    }

    /// One bar's rectangle. Identical x for the same column on every row —
    /// that identity is the alignment the table is built on.
    func barRect(column: Int, laneIndex: Int, in size: CGSize) -> CGRect? {
        guard column >= 0, column < columns.totalColumnCount else { return nil }
        let width = columnWidth(in: size)
        guard width > 0 else { return nil }
        // A point of air on each side, but never at the cost of a bar the eye
        // can find.
        let inset = min(1.5, width / 6)
        let top = trackTop(laneIndex)
        return CGRect(
            x: chartX + CGFloat(column) * width + inset,
            y: top,
            width: max(2, width - inset * 2),
            height: trackHeight
        )
    }
}

// MARK: - Small multiples

/// Every lane as a row of the same column grid.
///
/// The bars are a single `Canvas` (`AGENTS.md` § 11: dense status history is
/// one drawing surface, not hundreds of views) held behind `.equatable()`, so
/// moving the pointer across the table re-renders the hover highlight and one
/// tooltip — never the several hundred bars underneath them.
struct ResetHistoryCompareView: View {
    let comparison: ResetHistoryComparison
    let density: Theme.Density

    @State private var hover: Hover?

    private struct Hover: Equatable {
        let laneIndex: Int
        let cycleID: String
        let column: Int
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
                    if let hover,
                       let rect = layout.barRect(
                           column: hover.column,
                           laneIndex: hover.laneIndex,
                           in: proxy.size
                       ) {
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
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

    /// The same marks the bars use, never a stand-in shape for them.
    private var legend: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: 6, height: 9)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.secondary)
                        .frame(width: 6, height: 6)
                }
                Text("bar height = remaining at reset")
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 0.8, dash: [2, 1.5]))
                    .frame(width: 6, height: 9)
                Text("now")
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
        // `>= chartX` matters: a pointer over the label column would otherwise
        // truncate to column 0 and light up a bar it is nowhere near.
        guard let index = layout.laneIndex(atY: location.y),
              index < comparison.lanes.count,
              location.x >= layout.chartX,
              layout.columnWidth(in: size) > 0
        else { return nil }
        let column = Int((location.x - layout.chartX) / layout.columnWidth(in: size))
        guard column >= 0, column < comparison.columns.totalColumnCount else { return nil }
        let lane = comparison.lanes[index]
        if column == comparison.columns.currentColumn, let current = lane.currentCycle {
            return Hover(laneIndex: index, cycleID: current.id, column: column, point: location)
        }
        let offset = column - comparison.columns.column(
            ofCycleAt: 0,
            inLaneWithCycleCount: lane.cycles.count
        )
        guard offset >= 0, offset < lane.cycles.count else { return nil }
        return Hover(
            laneIndex: index,
            cycleID: lane.cycles[offset].id,
            column: column,
            point: location
        )
    }

    private func cycle(for hover: Hover) -> ResetHistoryComparison.Cycle? {
        guard hover.laneIndex < comparison.lanes.count else { return nil }
        let lane = comparison.lanes[hover.laneIndex]
        if let match = lane.cycles.first(where: { $0.id == hover.cycleID }) { return match }
        return lane.currentCycle?.id == hover.cycleID ? lane.currentCycle : nil
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
                // The full quota-axis name, company included: the row label
                // drops the company because the heading carries it, and a
                // tooltip has no heading above it.
                Text(lane.label)
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
            Text(dateRange(cycle))
                .font(.system(size: 9, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
            Text(
                cycle.isCompleted
                    ? "\(Int(cycle.wastedPercent.rounded()))% left at reset · \(Int(cycle.usedPercent.rounded()))% used"
                    : "Current cycle · \(Int(cycle.wastedPercent.rounded()))% left now · \(Int(cycle.usedPercent.rounded()))% used so far"
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

    private static let tooltipWidth: CGFloat = 244

    private func tooltipOffset(_ hover: Hover, in size: CGSize) -> CGSize {
        let x = min(max(0, hover.point.x - Self.tooltipWidth / 2), max(0, size.width - Self.tooltipWidth))
        // Above the hovered row when there is room for it, below otherwise.
        let above = hover.point.y > 82
        return CGSize(width: x, height: above ? hover.point.y - 80 : hover.point.y + 14)
    }

    private func dateRange(_ cycle: ResetHistoryComparison.Cycle) -> String {
        let start = ResetHistoryCompareFormatters.tooltip.string(from: cycle.start)
        let end = ResetHistoryCompareFormatters.tooltip.string(from: cycle.end)
        return cycle.isCompleted ? "\(start) → \(end) reset" : "\(start) → \(end) reset due"
    }
}

// MARK: - The drawing surface

/// The bars, the labels, the company headings and the column axis — one
/// `Canvas`, no per-cell views and no `.help()` per bar.
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
                    drawHeading(&context, company: company, top: top, isFirst: top == 0, size: size)
                case let .lane(index):
                    let lane = comparison.lanes[index]
                    drawLabels(&context, lane: lane, index: index)
                    drawLane(&context, lane: lane, index: index, size: size)
                }
            }
            drawAxis(&context, size: size)
        }
    }

    /// Column separators behind every row, and the live column marked off from
    /// the completed ones.
    private func drawGrid(_ context: inout GraphicsContext, size: CGSize) {
        let width = layout.columnWidth(in: size)
        guard width > 0 else { return }
        for column in 1..<max(1, comparison.columns.totalColumnCount) {
            let isCurrentBoundary = column == comparison.columns.currentColumn
            context.fill(
                Path(CGRect(x: layout.chartX + CGFloat(column) * width, y: 0, width: 0.5, height: layout.rowsHeight)),
                with: .color(Color.primary.opacity(isCurrentBoundary ? 0.22 : 0.06))
            )
        }
    }

    /// One L1 company band: a rule across the full width and the company's
    /// name over it. The rows below it drop the company from their own labels,
    /// so this is where it lives.
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

    /// The row's name over its waste summary.
    ///
    /// The name wraps on its own separators rather than truncating: every row
    /// reserves two lines, and the caption follows whatever the name actually
    /// used, so a one-line row has no hole under it.
    private func drawLabels(
        _ context: inout GraphicsContext,
        lane: ResetHistoryComparison.Lane,
        index: Int
    ) {
        let maxWidth = layout.labelWidth - layout.labelGap
        var y = layout.laneTop(index) + layout.markerBand - 2
        let lines = wrapped(
            context,
            lane.labelWithoutCompany,
            font: .system(size: layout.titleFontSize, weight: .semibold),
            color: Color.primary.opacity(0.88),
            maxWidth: maxWidth,
            lineLimit: layout.titleLineLimit
        )
        for line in lines {
            context.draw(line, at: CGPoint(x: 0, y: y), anchor: .topLeading)
            y += layout.titleLineHeight
        }
        context.draw(
            truncated(
                context,
                lane.wasteSummary,
                font: .system(size: layout.captionFontSize, design: .rounded),
                color: Color.primary.opacity(0.5),
                maxWidth: maxWidth
            ),
            at: CGPoint(x: 0, y: y + 1),
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
        let accent = Theme.providerAccent(for: lane.tool)
        for (offset, cycle) in lane.cycles.enumerated() {
            let column = comparison.columns.column(
                ofCycleAt: offset,
                inLaneWithCycleCount: lane.cycles.count
            )
            drawBar(&context, cycle: cycle, column: column, laneIndex: index, accent: accent, size: size)
        }
        if let current = lane.currentCycle, let column = comparison.columns.currentColumn {
            drawBar(&context, cycle: current, column: column, laneIndex: index, accent: accent, size: size)
        }
    }

    private func drawBar(
        _ context: inout GraphicsContext,
        cycle: ResetHistoryComparison.Cycle,
        column: Int,
        laneIndex: Int,
        accent: Color,
        size: CGSize
    ) {
        guard let rect = layout.barRect(column: column, laneIndex: laneIndex, in: size) else { return }
        let radius = min(2.5, rect.width / 2)
        // The track is the whole quota; the fill is the part of it that was
        // still there when the window refilled. A cycle spent to the last
        // percent draws no fill at all, and the track is what keeps that
        // visible as a deliberate empty slot rather than a missing bar.
        context.fill(
            Path(roundedRect: rect, cornerRadius: radius, style: .continuous),
            with: .color(Theme.barTrack.opacity(0.62))
        )
        let fillHeight = cycle.wastedPercent > 0
            ? max(1, rect.height * cycle.wastedPercent / 100)
            : 0
        if fillHeight > 0 {
            let fillRect = CGRect(
                x: rect.minX,
                y: rect.maxY - fillHeight,
                width: rect.width,
                height: fillHeight
            )
            context.fill(
                Path(roundedRect: fillRect, cornerRadius: min(radius, fillHeight / 2), style: .continuous),
                with: .color(accent.opacity(cycle.isCompleted ? 0.86 : 0.5))
            )
        }
        if !cycle.isCompleted {
            context.stroke(
                Path(roundedRect: rect, cornerRadius: radius, style: .continuous),
                with: .color(accent.opacity(0.9)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 2])
            )
        }
        // Above the bar rather than inside it: a cycle that expired untouched
        // fills its track to the top, where a marker would be the same colour
        // as the fill under it.
        if cycle.refilledEarly {
            let dot = CGRect(x: rect.midX - 1.5, y: layout.laneTop(laneIndex) + 1, width: 3, height: 3)
            context.fill(Path(ellipseIn: dot), with: .color(accent.opacity(0.8)))
        }
    }

    /// How many cycles back each column is, and `now` for the live one.
    /// Deliberately not dates: the columns are ordinals, and each cycle's own
    /// dates are in its tooltip.
    private func drawAxis(_ context: inout GraphicsContext, size: CGSize) {
        let y = layout.rowsHeight + 1
        let width = layout.columnWidth(in: size)
        guard width > 0 else { return }
        let total = comparison.columns.totalColumnCount
        // Label the ends and the live column, plus interior ordinals only
        // while they still have room to be read.
        let stride = max(1, Int((28 / max(width, 1)).rounded(.up)))
        for column in 0..<total {
            let isCurrent = column == comparison.columns.currentColumn
            let isEdge = column == 0 || column == comparison.columns.completedColumnCount - 1
            guard isCurrent || isEdge || column % stride == 0,
                  let label = comparison.columns.axisLabel(forColumn: column)
            else { continue }
            let text = context.resolve(
                Text(label)
                    .font(.system(size: max(7, layout.captionFontSize - 1), design: .rounded))
                    .foregroundStyle(Color.primary.opacity(isCurrent ? 0.55 : 0.35))
            )
            let measured = text.measure(in: CGSize(width: 80, height: 20)).width
            let centre = layout.chartX + (CGFloat(column) + 0.5) * width
            let clamped = min(
                max(centre - measured / 2, layout.chartX),
                layout.chartX + layout.chartWidth(in: size) - measured
            )
            context.draw(text, at: CGPoint(x: clamped, y: y), anchor: .topLeading)
        }
    }

    /// A name broken across at most `lineLimit` lines on its own " · "
    /// separators, so "AntiGravity · Claude & GPT Models · Weekly" wraps where
    /// a reader would break it instead of being cut at twenty characters.
    /// The last line still truncates if even that will not fit.
    private func wrapped(
        _ context: GraphicsContext,
        _ string: String,
        font: Font,
        color: Color,
        maxWidth: CGFloat,
        lineLimit: Int
    ) -> [GraphicsContext.ResolvedText] {
        let probe = CGSize(width: 10_000, height: 40)
        func resolve(_ candidate: String) -> GraphicsContext.ResolvedText {
            context.resolve(Text(candidate).font(font).foregroundStyle(color))
        }
        let full = resolve(string)
        guard maxWidth > 0, full.measure(in: probe).width > maxWidth, lineLimit > 1 else {
            return [truncated(context, string, font: font, color: color, maxWidth: maxWidth)]
        }
        let separator = " · "
        let parts = string.components(separatedBy: separator)
        guard parts.count > 1 else {
            return [truncated(context, string, font: font, color: color, maxWidth: maxWidth)]
        }
        var lines: [String] = []
        var current = ""
        for part in parts {
            let candidate = current.isEmpty ? part : current + separator + part
            if current.isEmpty || resolve(candidate).measure(in: probe).width <= maxWidth {
                current = candidate
                continue
            }
            lines.append(current)
            current = part
        }
        if !current.isEmpty { lines.append(current) }
        if lines.count > lineLimit {
            // Everything that did not fit joins the last allowed line, which
            // then truncates — better a trailing ellipsis than a dropped
            // bucket name.
            let tail = lines[(lineLimit - 1)...].joined(separator: separator)
            lines = Array(lines.prefix(lineLimit - 1)) + [tail]
        }
        return lines.map { truncated(context, $0, font: font, color: color, maxWidth: maxWidth) }
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
    static let tooltip: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter
    }()
}
