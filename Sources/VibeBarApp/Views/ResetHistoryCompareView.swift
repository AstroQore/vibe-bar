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
                    ? L10n.Quota.resetHistoryRetiredAccountNumbered(number: position + 1)
                    : L10n.Quota.resetHistoryRetiredAccount
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
        let axis: ResetHistoryAxis
        let window: ResetHistoryComparison.Window
        let hour: Double
    }

    private var key: Key?
    private var value: ResetHistoryComparison?

    func comparison(
        inputs: [ResetHistoryLaneInput],
        axis: ResetHistoryAxis,
        window: ResetHistoryComparison.Window,
        now: Date = Date()
    ) -> ResetHistoryComparison {
        // The clock decides only whether a cycle has closed since the last
        // build, so it is quantized to the hour. This module starts no timer
        // of its own: the next quota refresh redraws it.
        let hour = (now.timeIntervalSinceReferenceDate / 3_600).rounded(.down) * 3_600
        let candidate = Key(inputs: inputs, axis: axis, window: window, hour: hour)
        if let key, key == candidate, let value { return value }
        let built = ResetHistoryComparison.build(
            inputs: inputs,
            axis: axis,
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
/// **Two axes, and the reader picks.** On `Cycles` the columns are ordinals:
/// the newest completed cycle of every quota sits in the same column, the one
/// before it in the column to its left, and a row with less history is
/// right-aligned into the grid. Quotas refill on unrelated schedules, so that
/// is the only layout in which two rows can be read against each other. On
/// `Time` each cycle sits where it actually happened, which is the only layout
/// that shows two quotas running dry in the same week — or a lane that stopped
/// refilling in March. The choice persists in `AppSettings`, one setting for
/// every surface that draws the module.
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

    /// The window the user picked, if they picked one. `nil` means "still on
    /// the default", which is derived from how much room the card actually got
    /// rather than hard-coded — a card half the popover wide and one filling
    /// the Workbench are the same module with very different space.
    ///
    /// Session state, as before: an explicit choice sticks until the popover
    /// closes, and only the *initial* value became width-derived.
    @State private var chosenWindow: ResetHistoryComparison.Window?
    /// The card's content width, updated only when it actually changes —
    /// `onGeometryChange` fires on a new value, not on every layout pass.
    ///
    /// Measured rather than derived from `density.popoverWidth`: this card
    /// sits in an Overview column, a provider page's wide column and a full
    /// Workbench page, and only one of those is a function of the popover.
    @State private var cardWidth: CGFloat = 0
    @State private var cache = ResetHistoryComparisonCache()

    private var window: ResetHistoryComparison.Window {
        chosenWindow ?? ResetHistoryComparison.defaultWindow(
            chartWidth: Double(max(0, cardWidth - ResetHistoryCompareLayout.chartX(for: density)))
        )
    }

    /// Persisted, not `@State`: switching the Overview's copy switches the
    /// provider pages' and the Workbench's too, which is what a reader who
    /// changed their mind about the layout means.
    private var axis: ResetHistoryAxis { settingsStore.settings.resetHistoryCompareAxis }

    private func setAxis(_ next: ResetHistoryAxis) {
        guard settingsStore.settings.resetHistoryCompareAxis != next else { return }
        settingsStore.settings.resetHistoryCompareAxis = next
    }

    var body: some View {
        let comparison = cache.comparison(
            inputs: ResetHistoryLanes.inputs(environment: environment, tools: tools),
            axis: axis,
            window: window
        )
        CardShell(density: density, spacing: 8) {
            header
            summary(comparison)
                // Inside the shell, so this is the card's *content* width —
                // the shell's own width would include its padding and make
                // every plot look wider than it is.
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    cardWidth = width
                }
            if comparison.isEmpty {
                Text(L10n.Quota.resetHistoryCompareEmpty)
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
            } else {
                ResetHistoryCompareView(comparison: comparison, density: density)
            }
        }
    }

    private var title: String { titleOverride ?? L10n.Quota.resetHistoryCompareTitle }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 6)
            axisPicker
            windowPicker
        }
    }

    /// Cycles or Time. Words rather than glyphs: the difference between an
    /// ordinal grid and a calendar is not something an icon carries, and this
    /// control changes what the whole chart measures.
    private var axisPicker: some View {
        HStack(spacing: 1) {
            ForEach(ResetHistoryAxis.allCases, id: \.self) { option in
                Button {
                    setAxis(option)
                } label: {
                    Text(option.title)
                        .font(.system(size: max(8.5, density.segmentedFontSize - 1.5), weight: .semibold))
                        .foregroundStyle(axis == option ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 17)
                        .contentShape(Rectangle())
                        .background {
                            if axis == option {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.primary.opacity(0.12))
                            }
                        }
                }
                .buttonStyle(.vibeBar(cornerRadius: 5))
                .help(option.help)
                .accessibilityLabel(option.help)
                .accessibilityAddTraits(axis == option ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
    }

    /// How far back the comparison reaches, in whichever unit the axis counts.
    /// The same hand-drawn segment pill the cost card's metric switch uses, so
    /// the two read as one control family.
    private var windowPicker: some View {
        HStack(spacing: 1) {
            ForEach(ResetHistoryComparison.Window.allCases, id: \.self) { option in
                Button {
                    chosenWindow = option
                } label: {
                    Text(option.shortTitle(for: axis))
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
                .help(L10n.Quota.resetHistoryCompareWindow(window: option.spokenTitle(for: axis)))
                .accessibilityLabel(
                    L10n.Quota.resetHistoryCompareWindow(window: option.spokenTitle(for: axis))
                )
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
    /// Label lines every row reserves. Exactly two, always: the SubProvider
    /// on the first and the group/bucket on the second. A fixed count is what
    /// keeps the caption under it on one line across the whole table — the
    /// wrapped version moved it up or down per row.
    let labelLineCount = 2
    let now: Date
    /// Which grid the bars sit on. Everything above this line — heading
    /// heights, label block, track height, row rhythm — is identical for both,
    /// so flipping the axis moves bars without reflowing a single label.
    let grid: ResetHistoryComparison.Grid
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
        case .compact: trackHeight = 26
        case .regular: trackHeight = 30
        case .spacious: trackHeight = 36
        }
        labelWidth = Self.labelWidth(for: density)
        titleFontSize = max(9, density.subtitleFontSize - 0.5)
        captionFontSize = max(8, density.subtitleFontSize - 2)
        titleLineHeight = titleFontSize + 3
        now = comparison.now
        grid = comparison.grid

        // Two label lines plus the caption, or the bar track, whichever is
        // taller. Uniform per density: this is a table, and a table's rows
        // line up.
        let labelBlock = CGFloat(labelLineCount) * titleLineHeight + captionFontSize + 4
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

    /// Width of the label column, resolved from density alone — the card asks
    /// for it before there is a comparison to build a layout from.
    static func labelWidth(for density: Theme.Density) -> CGFloat {
        switch density.profile {
        case .compact: 176
        case .regular: 202
        case .spacious: 232
        }
    }

    /// Where the plot starts, for a card that has not been laid out yet.
    static func chartX(for density: Theme.Density) -> CGFloat {
        labelWidth(for: density) + CGFloat(10)
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

    /// The cycle axis's column plan; an empty one on the time axis.
    var columns: ResetHistoryComparison.ColumnPlan {
        guard case let .cycles(plan) = grid else {
            return ResetHistoryComparison.ColumnPlan(completedColumnCount: 0, hasCurrentColumn: false)
        }
        return plan
    }

    var span: ResetHistoryComparison.TimeSpan? {
        guard case let .time(span) = grid else { return nil }
        return span
    }

    func columnWidth(in size: CGSize) -> CGFloat {
        guard columns.totalColumnCount > 0 else { return 0 }
        return chartWidth(in: size) / CGFloat(columns.totalColumnCount)
    }

    // MARK: Time axis

    func x(for date: Date, in size: CGSize) -> CGFloat {
        guard let span else { return chartX }
        return chartX + chartWidth(in: size) * CGFloat(span.fraction(of: date))
    }

    /// A cycle's rectangle on the time axis, clamped to the plot. `nil` when
    /// the cycle falls entirely outside the visible span.
    func timeBarRect(
        _ cycle: ResetHistoryComparison.Cycle,
        laneIndex: Int,
        in size: CGSize
    ) -> CGRect? {
        guard span != nil else { return nil }
        let left = x(for: cycle.start, in: size)
        let right = x(for: cycle.end, in: size)
        let minX = chartX
        let maxX = chartX + chartWidth(in: size)
        guard right > minX, left < maxX else { return nil }
        let clampedLeft = max(minX, left)
        let clampedRight = min(maxX, right)
        // One point of air between neighbours, and never thinner than a bar
        // the eye can find.
        return CGRect(
            x: clampedLeft,
            y: trackTop(laneIndex),
            width: max(2, clampedRight - clampedLeft - 1),
            height: trackHeight
        )
    }

    /// Bars a lane may draw on the time axis before they stop being separable.
    /// Three points is already narrower than the eye can split.
    func timeDrawBudget(in size: CGSize) -> Int { max(4, Int(chartWidth(in: size) / 3)) }

    // MARK: Cycle axis

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
        /// Cycle axis only; `nil` on the time axis, where the bar's rectangle
        /// comes from the cycle's own dates instead of a column index.
        let column: Int?
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
                Text(L10n.Quota.resetHistoryLegendBarHeight)
            }
            // What the x position means, which is the one thing the axis
            // toggle changes about how to read the chart.
            Text(
                comparison.axis == .cycle
                    ? L10n.Quota.resetHistoryLegendPerCycle
                    : L10n.Quota.resetHistoryLegendByDate
            )
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 0.8, dash: [2, 1.5]))
                    .frame(width: 6, height: 9)
                Text(L10n.Quota.resetHistoryAxisNow)
            }
            HStack(spacing: 3) {
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 3, height: 3)
                Text(L10n.Quota.resetHistoryLegendRefilledEarly)
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
        // `>= chartX` matters on both axes: a pointer over the label column
        // would otherwise resolve to the leftmost bar it is nowhere near.
        guard let index = layout.laneIndex(atY: location.y),
              index < comparison.lanes.count,
              location.x >= layout.chartX
        else { return nil }
        let lane = comparison.lanes[index]
        switch comparison.grid {
        case let .cycles(plan):
            guard layout.columnWidth(in: size) > 0 else { return nil }
            let column = Int((location.x - layout.chartX) / layout.columnWidth(in: size))
            guard column >= 0, column < plan.totalColumnCount else { return nil }
            if column == plan.currentColumn, let current = lane.currentCycle {
                return Hover(laneIndex: index, cycleID: current.id, column: column, point: location)
            }
            let offset = column - plan.column(ofCycleAt: 0, inLaneWithCycleCount: lane.cycles.count)
            guard offset >= 0, offset < lane.cycles.count else { return nil }
            return Hover(
                laneIndex: index,
                cycleID: lane.cycles[offset].id,
                column: column,
                point: location
            )
        case .time:
            // The same thinned set the canvas drew, so the tooltip can never
            // describe a bar that is not on screen.
            var candidates = ResetHistoryComparison.downsampled(
                lane.cycles,
                limit: layout.timeDrawBudget(in: size)
            )
            if let current = lane.currentCycle { candidates.append(current) }
            // Reverse order matches the draw order: the current cycle is
            // painted last and is therefore the one on top.
            for cycle in candidates.reversed() {
                guard let rect = layout.timeBarRect(cycle, laneIndex: index, in: size) else { continue }
                if location.x >= rect.minX - 1, location.x <= rect.maxX + 1 {
                    return Hover(laneIndex: index, cycleID: cycle.id, column: nil, point: location)
                }
            }
            return nil
        }
    }

    /// The hovered bar's rectangle, resolved the way its axis resolves bars.
    private func hoveredRect(
        _ hover: Hover,
        in size: CGSize,
        layout: ResetHistoryCompareLayout
    ) -> CGRect? {
        if let column = hover.column {
            return layout.barRect(column: column, laneIndex: hover.laneIndex, in: size)
        }
        guard let cycle = cycle(for: hover) else { return nil }
        return layout.timeBarRect(cycle, laneIndex: hover.laneIndex, in: size)
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
                    ? L10n.Quota.resetHistoryTooltipCompleted(
                        left: Int(cycle.wastedPercent.rounded()),
                        used: Int(cycle.usedPercent.rounded())
                    )
                    : L10n.Quota.resetHistoryTooltipCurrent(
                        left: Int(cycle.wastedPercent.rounded()),
                        used: Int(cycle.usedPercent.rounded())
                    )
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
        return cycle.isCompleted
            ? L10n.Quota.resetHistoryTooltipRange(start: start, end: end)
            : L10n.Quota.resetHistoryTooltipRangeDue(start: start, end: end)
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
        lhs.layout == rhs.layout
            && lhs.comparison == rhs.comparison
            // `Lane.label` is a computed property — correctly, so it is never
            // a stored localized string — which means `comparison ==` is
            // blind to the language while `drawLabels` is not.
            && lhs.language == rhs.language
    }

    private let language = LanguageStamp.current

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
    /// the completed ones — or, on the time axis, the date rules and a *now*
    /// hairline.
    private func drawGrid(_ context: inout GraphicsContext, size: CGSize) {
        guard case let .cycles(plan) = comparison.grid else {
            drawTimeGrid(&context, size: size)
            return
        }
        let width = layout.columnWidth(in: size)
        guard width > 0 else { return }
        for column in 1..<max(1, plan.totalColumnCount) {
            let isCurrentBoundary = column == plan.currentColumn
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

    /// The row's name as two levels, over its waste summary.
    ///
    /// Line one is the SubProvider and line two is the quota inside it; they
    /// are never joined and line one never wraps. The single wrapped string
    /// this replaces broke wherever the column ran out — "ChatGPT Agentic ·
    /// Weekly" on one row, "AntiGravity" over "Claude and GPT Models · Weekly"
    /// on the next — so no two rows agreed on where the level boundary was.
    /// Line two truncates rather than wrapping, because a third line would
    /// push the caption out of the row every row it happened on.
    ///
    /// Weight and colour carry the hierarchy, not size: both lines are set at
    /// `titleFontSize` so the reserved block height is exactly two lines
    /// whatever the labels say.
    private func drawLabels(
        _ context: inout GraphicsContext,
        lane: ResetHistoryComparison.Lane,
        index: Int
    ) {
        let maxWidth = layout.labelWidth - layout.labelGap
        var y = layout.laneTop(index) + layout.markerBand - 2
        context.draw(
            truncated(
                context,
                lane.subProvider,
                font: .system(size: layout.titleFontSize, weight: .semibold),
                color: Color.primary.opacity(0.88),
                maxWidth: maxWidth
            ),
            at: CGPoint(x: 0, y: y),
            anchor: .topLeading
        )
        y += layout.titleLineHeight
        // Empty only for a lane whose bucket nothing could name; the line is
        // still reserved so the caption below stays put.
        if !lane.bucketLine.isEmpty {
            context.draw(
                truncated(
                    context,
                    lane.bucketLine,
                    font: .system(size: layout.titleFontSize),
                    color: Color.primary.opacity(0.58),
                    maxWidth: maxWidth
                ),
                at: CGPoint(x: 0, y: y),
                anchor: .topLeading
            )
        }
        y += layout.titleLineHeight
        context.draw(
            truncated(
                context,
                lane.wasteSummary,
                font: .system(size: layout.captionFontSize, design: .rounded),
                color: Color.primary.opacity(0.45),
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
        switch comparison.grid {
        case let .cycles(plan):
            for (offset, cycle) in lane.cycles.enumerated() {
                let column = plan.column(ofCycleAt: offset, inLaneWithCycleCount: lane.cycles.count)
                guard let rect = layout.barRect(column: column, laneIndex: index, in: size) else { continue }
                drawBar(&context, cycle: cycle, in: rect, laneIndex: index, accent: accent)
            }
            if let current = lane.currentCycle, let column = plan.currentColumn,
               let rect = layout.barRect(column: column, laneIndex: index, in: size) {
                drawBar(&context, cycle: current, in: rect, laneIndex: index, accent: accent)
            }
        case .time:
            // Thinned before drawing: the time axis has no column ceiling, so
            // a year of weeklies on a short row is a bar every two pixels.
            // Endpoints and the wasteful cycles are what survive the cut.
            for cycle in ResetHistoryComparison.downsampled(
                lane.cycles,
                limit: layout.timeDrawBudget(in: size)
            ) {
                guard let rect = layout.timeBarRect(cycle, laneIndex: index, in: size) else { continue }
                drawBar(&context, cycle: cycle, in: rect, laneIndex: index, accent: accent)
            }
            if let current = lane.currentCycle,
               let rect = layout.timeBarRect(current, laneIndex: index, in: size) {
                drawBar(&context, cycle: current, in: rect, laneIndex: index, accent: accent)
            }
        }
    }

    /// Date rules across the plot and the *now* hairline — the same idiom the
    /// refill-horizon lane uses.
    private func drawTimeGrid(_ context: inout GraphicsContext, size: CGSize) {
        guard let span = layout.span else { return }
        for tick in Self.timeTicks(span) {
            context.fill(
                Path(CGRect(x: layout.x(for: tick, in: size), y: 0, width: 0.5, height: layout.rowsHeight)),
                with: .color(Color.primary.opacity(0.07))
            )
        }
        let nowX = layout.x(for: min(span.end, layout.now), in: size)
        if nowX >= layout.chartX, nowX <= layout.chartX + layout.chartWidth(in: size) {
            context.fill(
                Path(CGRect(x: nowX - 0.5, y: 0, width: 1, height: layout.rowsHeight)),
                with: .color(Color.primary.opacity(0.28))
            )
        }
    }

    /// Six evenly spaced dates across the visible span.
    static func timeTicks(_ span: ResetHistoryComparison.TimeSpan) -> [Date] {
        let count = 5
        return (0...count).map { index in
            span.start.addingTimeInterval(span.duration * Double(index) / Double(count))
        }
    }

    private func drawBar(
        _ context: inout GraphicsContext,
        cycle: ResetHistoryComparison.Cycle,
        in rect: CGRect,
        laneIndex: Int,
        accent: Color
    ) {
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

    /// The axis caption row: how many cycles back each column is on the cycle
    /// axis (dates live in the tooltips there, because the columns are
    /// ordinals), and real dates on the time axis.
    private func drawAxis(_ context: inout GraphicsContext, size: CGSize) {
        let y = layout.rowsHeight + 1
        drawTruncationNote(&context, y: y)
        guard case let .cycles(plan) = comparison.grid else {
            drawTimeAxis(&context, size: size, y: y)
            return
        }
        let width = layout.columnWidth(in: size)
        guard width > 0 else { return }
        let total = plan.totalColumnCount
        // Label the ends and the live column, plus interior ordinals only
        // while they still have room to be read.
        let stride = max(1, Int((28 / max(width, 1)).rounded(.up)))
        for column in 0..<total {
            let isCurrent = column == plan.currentColumn
            let isEdge = column == 0 || column == plan.completedColumnCount - 1
            guard isCurrent || isEdge || column % stride == 0,
                  let label = plan.axisLabel(forColumn: column)
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

    /// Dates under the time axis, kept inside the plot at both ends.
    private func drawTimeAxis(_ context: inout GraphicsContext, size: CGSize, y: CGFloat) {
        guard let span = layout.span else { return }
        let chartWidth = layout.chartWidth(in: size)
        for tick in Self.timeTicks(span) {
            let tickX = layout.x(for: tick, in: size)
            guard tickX >= layout.chartX - 1, tickX <= layout.chartX + chartWidth else { continue }
            let text = context.resolve(
                Text(ResetHistoryCompareFormatters.axis.string(from: tick))
                    .font(.system(size: max(7, layout.captionFontSize - 1), design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.4))
            )
            let measured = text.measure(in: CGSize(width: 80, height: 20)).width
            let clamped = min(
                max(tickX - measured / 2, layout.chartX),
                layout.chartX + chartWidth - measured
            )
            context.draw(text, at: CGPoint(x: clamped, y: y), anchor: .topLeading)
        }
    }

    /// The label column is free on the axis row, which is where the caveat
    /// belongs: the grid is capped, the numbers above it are not.
    private func drawTruncationNote(_ context: inout GraphicsContext, y: CGFloat) {
        if let note = comparison.truncationNote {
            context.draw(
                truncated(
                    context,
                    note,
                    font: .system(size: max(7, layout.captionFontSize - 1), design: .rounded),
                    color: Color.primary.opacity(0.4),
                    maxWidth: layout.labelWidth - layout.labelGap
                ),
                at: CGPoint(x: 0, y: y),
                anchor: .topLeading
            )
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
    // Built per language rather than once per process: a formatter
    // parked in a `static let` keeps the language it was created in.
    static var axis: DateFormatter {
        AppLocale.dateFormatter(template: "MMMd")
    }

    // Built per language rather than once per process: a formatter
    // parked in a `static let` keeps the language it was created in.
    static var tooltip: DateFormatter {
        AppLocale.dateFormatter(template: "MMMdHHmm")
    }
}
