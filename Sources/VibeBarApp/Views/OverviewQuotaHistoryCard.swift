import SwiftUI
import Charts
import VibeBarCore

/// One curve in the all-providers quota history chart: the observed
/// remaining-percent line of a single `(tool, account, bucket)`.
///
/// Everything the chart needs to draw and name the curve is resolved once, when
/// the series are rebuilt, rather than per frame — including the colour, which
/// costs an `NSColor` round trip to make appearance-aware.
struct OverviewQuotaCurve: Identifiable, Equatable {
    /// `"<tool>|<accountId>|<bucketId>"`. Also the key persisted in
    /// `AppSettings.overviewQuotaHistoryHiddenCurveIds`, so it has to stay
    /// stable across launches — no indices, no display strings.
    let id: String
    let tool: ToolType
    let accountId: String
    let bucketId: String
    let toolTitle: String
    let bucketTitle: String
    /// Masked account hint, set only when a tool has more than one account with
    /// history and the bucket titles alone would be ambiguous.
    let accountQualifier: String?
    /// The quota's window length, carried so the hover can size its tolerance
    /// to *this* curve's sampling rhythm. This card mixes five-hour lanes
    /// (five-minute slots) with weekly ones (hourly slots) by design, and one
    /// shared tolerance reads the sparse ones as blank. See
    /// `ChartHoverTolerance`.
    let windowSeconds: Int?
    let color: Color
    let dash: [CGFloat]

    var label: String {
        let base = "\(toolTitle) · \(bucketTitle)"
        guard let accountQualifier else { return base }
        return "\(base) · \(accountQualifier)"
    }

    static func id(tool: ToolType, accountId: String, bucketId: String) -> String {
        "\(tool.rawValue)|\(accountId)|\(bucketId)"
    }
}

/// What the crosshair resolved to on one curve.
private struct OverviewHoverReading: Identifiable {
    let id: String
    let label: String
    let color: Color
    let value: Double
}

/// Rebuild trigger. Keyed on the shape of every recorded lane rather than on
/// the arrays themselves: a refresh appends one point per bucket, and only then
/// is it worth re-segmenting every provider's history.
private struct OverviewSeriesSignature: Equatable {
    struct Entry: Equatable {
        var curveId: String
        var title: String
        var count: Int
        var first: Date?
        var last: Date?
    }

    var entries: [Entry]
}

/// What building one lane produced, plus everything that decides whether the
/// result is still valid.
private struct OverviewLaneBuild {
    var signature: OverviewSeriesSignature.Entry
    /// The palette slot and the account qualifier depend on the *set* of lanes
    /// rather than on this lane alone — a second Claude account appearing
    /// renames every Claude curve — so both belong to the validity check.
    var variantIndex: Int
    var qualifier: String?
    var curve: OverviewQuotaCurve
    var segments: [[QuotaHistorySample]]
    var flat: [QuotaHistorySample]
    /// The thinned copy the brush strip draws. Cached with the lane because it
    /// depends only on the segments, never on the visible window.
    var mini: [[QuotaHistorySample]]
}

/// Every recorded quota, from every provider and account, on one time axis.
///
/// The per-provider cards answer "how am I doing on this one quota"; this one
/// answers the question they cannot — "which of my quotas is the one that is
/// actually going to run out". That only works if the curves share an axis, so
/// this card draws observed remaining-percent only: pace lines, forecasts and
/// uncertainty bands are meaningful against a single quota and are mud against
/// a dozen.
///
/// A pull-down picks which curves are drawn, and the choice persists — see
/// `AppSettings.overviewQuotaHistoryHiddenCurveIds`.
///
/// Split in two. This half discovers the lanes, which means reading three
/// environment objects; `OverviewQuotaChartBody` draws them and is `.equatable()`
/// over plain values, so a `QuotaService` or `SettingsStore` publish that
/// changes nothing the chart shows stops at that boundary instead of re-running
/// the mark pipeline for every curve. The crosshair sits one level lower again,
/// in `OverviewQuotaHoverOverlay`, so a pointer move invalidates neither.
///
/// Like `QuotaHistoryChartView`, neither half reads a wall clock, so both are
/// safe under any re-proposal from above.
struct OverviewQuotaHistoryCard: View {
    let density: Theme.Density

    @EnvironmentObject var accountStore: AccountStore
    @EnvironmentObject var quotaService: QuotaService
    @EnvironmentObject var settingsStore: SettingsStore

    @State private var curves: [OverviewQuotaCurve] = []
    /// Last build output per curve, so a refresh that appends one point to one
    /// provider's lane re-segments that lane instead of all thirty.
    @State private var laneCache: [String: OverviewLaneBuild] = [:]
    @State private var segmentsByCurve: [String: [[QuotaHistorySample]]] = [:]
    /// Each curve's samples flattened into one ascending array — the segments
    /// are already time-sorted and contiguous, so concatenating them keeps the
    /// order a binary search needs. Built with the series so a pointer move
    /// costs a search rather than a scan.
    @State private var flatByCurve: [String: [QuotaHistorySample]] = [:]
    /// Each curve thinned for the brush strip. This used to be recomputed
    /// inside the strip's `Path` builder, which put a full re-thin of every
    /// curve on the main thread once per navigator frame — every frame of a pan
    /// included. It depends on the segments alone and never on the window, so
    /// it belongs with the rest of the per-data-change work.
    @State private var miniByCurve: [String: [[QuotaHistorySample]]] = [:]
    @State private var window: ChartTimeWindow?
    @State private var windowKey: String?
    @State private var initialSpan: TimeInterval = OverviewQuotaHistoryCard.preferredInitialSpan
    /// Bumped once per `rebuild()`. It stands in for the three sample
    /// dictionaries above in `OverviewQuotaChartBody`'s `==`: they are the
    /// expensive half of that view's input, nothing but `rebuild()` writes them,
    /// and comparing a counter is both cheaper and exactly as correct as walking
    /// thirty lanes of samples.
    @State private var seriesRevision = 0
    /// Bumped when the picker or a range pill has to drop the crosshair. The
    /// hover state itself lives in `OverviewQuotaHoverOverlay` so that a pointer
    /// move cannot invalidate *this* view — which reads three environment
    /// objects and, before the split, re-ran the whole mark pipeline whenever
    /// any of them published.
    @State private var hoverResetToken = 0

    private static let miniMarkLimit = 120

    var body: some View {
        VStack(alignment: .leading, spacing: density.cardSpacing) {
            header
            if let window, window.domainSpan > 0, !visibleCurves.isEmpty {
                // Everything below this line is a plain value and the drawing
                // view is `.equatable()`. That barrier is the point: this card
                // has to read `AccountStore`, `QuotaService` and `SettingsStore`
                // to discover its lanes, an environment object invalidates its
                // readers directly, and a refresh publishes repeatedly — so
                // without it every unrelated publish re-ran clip → budget →
                // thin → build for every curve.
                OverviewQuotaChartBody(
                    density: density,
                    curves: visibleCurves,
                    segmentsByCurve: segmentsByCurve,
                    flatByCurve: flatByCurve,
                    miniByCurve: miniByCurve,
                    revision: seriesRevision,
                    window: window,
                    initialSpan: initialSpan,
                    resetToken: hoverResetToken,
                    setWindow: { self.window = $0 }
                )
                .equatable()
            } else if curves.isEmpty {
                note("Quota history builds up as refreshes come in.")
            } else {
                note("Every curve is hidden — pick one from the menu above.")
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
        .onChange(of: seriesSignature, initial: true) { _, _ in
            rebuild()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Quota history")
                .font(.system(size: density.titleFontSize, weight: .semibold))
            Text("All providers")
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            if !curves.isEmpty {
                curvePicker
            }
            if window != nil {
                ChartRangePills(
                    window: rangeBinding,
                    fontSize: max(9, density.segmentedFontSize - 2),
                    // The crosshair lives in the overlay now, so a pill asks for
                    // it to be dropped instead of clearing it directly.
                    onSelect: { hoverResetToken &+= 1 }
                )
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: density.subtitleFontSize))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
    }

    // MARK: - Curve picker

    private var curvePicker: some View {
        Menu {
            Button("Show all curves") { setHidden([]) }
            if visibleCurves.count > 1 {
                Button("Show only the busiest") { showOnlyBusiest() }
            }
            Divider()
            ForEach(curvesByTool, id: \.0) { tool, toolCurves in
                Section(displayTitle(for: tool)) {
                    ForEach(toolCurves) { curve in
                        Toggle(isOn: binding(for: curve)) {
                            Text(curve.accountQualifier.map { "\(curve.bucketTitle) · \($0)" }
                                ?? curve.bucketTitle)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: max(8, density.segmentedFontSize - 3), weight: .semibold))
                Text(selectionSummary)
                    .font(
                        .system(
                            size: max(9, density.segmentedFontSize - 2),
                            weight: .semibold,
                            design: .rounded
                        )
                    )
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .frame(minHeight: 22)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Choose which quota curves to show")
    }

    private var selectionSummary: String {
        let shown = visibleCurves.count
        let total = curves.count
        return shown == total ? "All \(total)" : "\(shown) of \(total)"
    }

    private func binding(for curve: OverviewQuotaCurve) -> Binding<Bool> {
        Binding(
            get: { !settingsStore.settings.overviewQuotaHistoryHiddenCurveIds.contains(curve.id) },
            set: { isVisible in
                var hidden = settingsStore.settings.overviewQuotaHistoryHiddenCurveIds
                if isVisible {
                    hidden.remove(curve.id)
                } else {
                    hidden.insert(curve.id)
                }
                setHidden(hidden)
            }
        )
    }

    private func setHidden(_ hidden: Set<String>) {
        guard hidden != settingsStore.settings.overviewQuotaHistoryHiddenCurveIds else { return }
        settingsStore.settings.overviewQuotaHistoryHiddenCurveIds = hidden
        hoverResetToken &+= 1
    }

    /// Quick way back to a readable chart from a wall of curves: keep the ones
    /// that have actually moved recently and hide the flat ones.
    private func showOnlyBusiest() {
        let ranked = curves
            .map { ($0.id, movement(of: $0)) }
            .sorted { $0.1 > $1.1 }
        let keep = Set(ranked.prefix(5).map(\.0))
        setHidden(Set(curves.map(\.id)).subtracting(keep))
    }

    /// How much a curve's newest segment actually swings — a quota sitting at
    /// 100% all week tells the reader nothing.
    private func movement(of curve: OverviewQuotaCurve) -> Double {
        guard let segment = segmentsByCurve[curve.id]?.last, segment.count > 1 else { return 0 }
        let values = segment.map(\.remainingPercent)
        return (values.max() ?? 0) - (values.min() ?? 0)
    }

    // MARK: - Selection

    private var visibleCurves: [OverviewQuotaCurve] {
        let hidden = settingsStore.settings.overviewQuotaHistoryHiddenCurveIds
        return curves.filter { !hidden.contains($0.id) }
    }

    private var curvesByTool: [(ToolType, [OverviewQuotaCurve])] {
        var order: [ToolType] = []
        var grouped: [ToolType: [OverviewQuotaCurve]] = [:]
        for curve in curves {
            if grouped[curve.tool] == nil { order.append(curve.tool) }
            grouped[curve.tool, default: []].append(curve)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    private var rangeBinding: Binding<ChartTimeWindow> {
        Binding(
            get: {
                window ?? ChartTimeWindow(
                    domainStart: .distantPast,
                    domainEnd: .distantPast,
                    minimumSpan: 0,
                    visibleSpan: 0
                )
            },
            set: { window = $0 }
        )
    }

    // MARK: - Discovery

    /// Every `(tool, account, bucket)` with a drawable lane, in a stable order:
    /// core providers in the user's configured order first, then everything
    /// else, and inside a provider the account and bucket order the adapters
    /// produced.
    private var candidateLanes: [(account: AccountIdentity, bucket: QuotaBucket)] {
        let order = settingsStore.settings.orderedCoreProviders
        let rank: (ToolType) -> Int = { tool in
            order.firstIndex(of: tool.coreProviderRepresentative ?? tool) ?? order.count
        }
        let accounts = accountStore.accounts.sorted { left, right in
            let leftRank = rank(left.tool)
            let rightRank = rank(right.tool)
            if leftRank != rightRank { return leftRank < rightRank }
            if left.tool != right.tool { return left.tool.rawValue < right.tool.rawValue }
            return left.id < right.id
        }
        var lanes: [(AccountIdentity, QuotaBucket)] = []
        for account in accounts {
            guard let buckets = quotaService.cachedQuota(for: account.id)?.buckets else { continue }
            for bucket in buckets where drawableCount(account: account, bucket: bucket) > 1 {
                lanes.append((account, bucket))
            }
        }
        return lanes
    }

    private func drawableCount(account: AccountIdentity, bucket: QuotaBucket) -> Int {
        let key = SubscriptionHistoryKey(accountId: account.id, bucketId: bucket.id)
        return quotaService.observationsByAccountBucket[key]?.count ?? 0
    }

    private func fillPoints(accountId: String, bucketId: String) -> [FillTimelinePoint] {
        let key = SubscriptionHistoryKey(accountId: accountId, bucketId: bucketId)
        return quotaService.observationsByAccountBucket[key] ?? []
    }

    private var seriesSignature: OverviewSeriesSignature {
        OverviewSeriesSignature(
            entries: candidateLanes.map { signatureEntry(account: $0.account, bucket: $0.bucket) }
        )
    }

    /// One lane's shape. Shared by the rebuild trigger and by the per-lane cache
    /// key so the two can never disagree about what "changed".
    private func signatureEntry(
        account: AccountIdentity,
        bucket: QuotaBucket
    ) -> OverviewSeriesSignature.Entry {
        let points = fillPoints(accountId: account.id, bucketId: bucket.id)
        return OverviewSeriesSignature.Entry(
            curveId: OverviewQuotaCurve.id(
                tool: account.tool,
                accountId: account.id,
                bucketId: bucket.id
            ),
            // Titles are part of the signature because a plan change can
            // rename a bucket without adding an observation.
            title: bucketTitle(bucket),
            count: points.count,
            first: points.first?.sampledAt,
            last: points.last?.sampledAt
        )
    }

    // MARK: - Rebuild

    /// Re-segment the lanes whose inputs changed and keep the rest.
    ///
    /// Reusing a lane built against an *earlier* domain is safe because the
    /// domain is the union of every lane's own span, only ever widened (the
    /// six-hour floor extends the lower bound downwards): every lane's samples
    /// therefore always lie inside it, so the builder's range filter never drops
    /// one, and this card draws only `.actual` — the one part of the series that
    /// does not otherwise depend on the range.
    private func rebuild() {
        let lanes = candidateLanes
        guard !lanes.isEmpty, let domain = domainRange(lanes) else {
            curves = []
            laneCache = [:]
            segmentsByCurve = [:]
            flatByCurve = [:]
            miniByCurve = [:]
            window = nil
            windowKey = nil
            seriesRevision &+= 1
            return
        }

        // A tool only gets an account qualifier when it actually has more than
        // one account here — otherwise every Claude curve would carry a masked
        // address that distinguishes nothing.
        var accountsPerTool: [ToolType: Set<String>] = [:]
        for (account, _) in lanes {
            accountsPerTool[account.tool, default: []].insert(account.id)
        }

        var built: [OverviewQuotaCurve] = []
        var series: [String: [[QuotaHistorySample]]] = [:]
        var flat: [String: [QuotaHistorySample]] = [:]
        var mini: [String: [[QuotaHistorySample]]] = [:]
        var rebuiltCache: [String: OverviewLaneBuild] = [:]
        var indexPerTool: [ToolType: Int] = [:]
        for (account, bucket) in lanes {
            let id = OverviewQuotaCurve.id(
                tool: account.tool,
                accountId: account.id,
                bucketId: bucket.id
            )
            let index = indexPerTool[account.tool, default: 0]
            indexPerTool[account.tool] = index + 1
            let qualifier = (accountsPerTool[account.tool]?.count ?? 0) > 1
                ? Self.qualifier(for: account)
                : nil
            let signature = signatureEntry(account: account, bucket: bucket)
            if let cached = laneCache[id],
               cached.signature == signature,
               cached.variantIndex == index,
               cached.qualifier == qualifier {
                built.append(cached.curve)
                series[id] = cached.segments
                flat[id] = cached.flat
                mini[id] = cached.mini
                rebuiltCache[id] = cached
                continue
            }

            let variant = Self.variant(Theme.providerAccent(for: account.tool), index: index)
            let curve = OverviewQuotaCurve(
                id: id,
                tool: account.tool,
                accountId: account.id,
                bucketId: bucket.id,
                toolTitle: displayTitle(for: account.tool),
                bucketTitle: bucketTitle(bucket),
                accountQualifier: qualifier,
                windowSeconds: bucket.rawWindowSeconds,
                color: variant.color,
                dash: variant.dash
            )
            let actual = QuotaHistorySeriesBuilder.build(
                fillPoints: fillPoints(accountId: account.id, bucketId: bucket.id),
                range: domain
            ).actual
            let flattened = actual.flatMap { $0 }
            let thinned = ChartMarkBudget.thinned(actual, budget: Self.miniMarkLimit)
            built.append(curve)
            series[id] = actual
            flat[id] = flattened
            mini[id] = thinned
            rebuiltCache[id] = OverviewLaneBuild(
                signature: signature,
                variantIndex: index,
                qualifier: qualifier,
                curve: curve,
                segments: actual,
                flat: flattened,
                mini: thinned
            )
        }

        curves = built
        laneCache = rebuiltCache
        segmentsByCurve = series
        flatByCurve = flat
        miniByCurve = mini
        // Everything the drawing view memoizes has just been replaced, so
        // invalidate it with one integer instead of a deep compare of every lane.
        seriesRevision &+= 1

        let key = built.map(\.id).joined(separator: ",")
        let sameCurves = windowKey == key
        windowKey = key
        initialSpan = min(
            Self.preferredInitialSpan,
            max(6 * 3_600, domain.upperBound.timeIntervalSince(domain.lowerBound))
        )

        if sameCurves,
           let existing = window,
           existing.domainStart == domain.lowerBound,
           existing.domainEnd == domain.upperBound {
            return
        }
        if sameCurves, let existing = window {
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
            visibleSpan: initialSpan
        )
    }

    /// Zoom floor for a chart that mixes five-hour and weekly quotas: deep
    /// enough for the fast ones to show their sawtooth, shallow enough that a
    /// weekly line is never a single flat pixel-row.
    private static let minimumSpan: TimeInterval = 3 * 3_600

    /// Opening zoom, matching the per-group chart: one day of recent movement
    /// rather than a whole week compressed into the card's width. Still clamped
    /// to the stored domain, so a chart with only a few hours of evidence opens
    /// on what it actually has.
    private static let preferredInitialSpan: TimeInterval = 24 * 3_600

    private func domainRange(
        _ lanes: [(account: AccountIdentity, bucket: QuotaBucket)]
    ) -> ClosedRange<Date>? {
        var low: Date?
        var high: Date?
        for (account, bucket) in lanes {
            let points = fillPoints(accountId: account.id, bucketId: bucket.id)
            if let first = points.first?.sampledAt {
                low = low.map { min($0, first) } ?? first
            }
            if let last = points.last?.sampledAt {
                high = high.map { max($0, last) } ?? last
            }
        }
        guard let low, let high, high >= low else { return nil }
        let floorSpan: TimeInterval = 6 * 3_600
        if high.timeIntervalSince(low) < floorSpan {
            return high.addingTimeInterval(-floorSpan)...high
        }
        return low...high
    }

    // MARK: - Naming

    private func displayTitle(for tool: ToolType) -> String {
        tool == .gemini ? "Gemini" : tool.menuTitle
    }

    /// Claude titles six different quotas "Weekly" and only the group name
    /// tells them apart, so the group wins when there is one — matching the
    /// section headings in Subscription Utilization.
    private func bucketTitle(_ bucket: QuotaBucket) -> String {
        guard let group = bucket.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !group.isEmpty
        else { return bucket.title }
        return group == bucket.title ? group : "\(group) \(bucket.title)"
    }

    /// Short, non-identifying account hint. Aliases are the user's own words so
    /// they pass through; an address is masked, never printed raw.
    private static func qualifier(for account: AccountIdentity) -> String {
        if let alias = account.alias?.trimmingCharacters(in: .whitespacesAndNewlines),
           !alias.isEmpty {
            return alias
        }
        let masked = EmailMasker.mask(account.email)
        return masked.isEmpty ? String(account.id.suffix(4)) : masked
    }

    // MARK: - Palette

    /// One brand hue per provider, stepped in lightness (then in dash pattern)
    /// so the quotas inside a provider stay recognisably that provider's while
    /// still being told apart — Claude's 5 Hours and Weekly are the same coral
    /// at two weights, not two unrelated colours.
    private static func variant(_ base: Color, index: Int) -> (color: Color, dash: [CGFloat]) {
        let lightnessSteps: [Double] = [0, 0.34, -0.24, 0.58]
        let dashes: [[CGFloat]] = [[], [5, 3], [1.8, 2.6]]
        let step = lightnessSteps[index % lightnessSteps.count]
        let dash = dashes[(index / lightnessSteps.count) % dashes.count]
        let shifted: Color
        if step > 0 {
            shifted = base.mix(with: .white, by: step)
        } else if step < 0 {
            shifted = base.mix(with: .black, by: -step)
        } else {
            shifted = base
        }
        return (legible(shifted), dash)
    }

    /// Make a brand hue survive a dark card.
    ///
    /// Two providers ship near-black accents (xAI, Kimi/Ollama) that would be
    /// invisible as a 1.6pt line on a dark background, so a dark accent is
    /// lifted hard and everything else gets the same small lift the forecast
    /// strokes get. Resolved by *appearance* rather than by reading
    /// `@Environment(\.colorScheme)`: an environment read would be a hidden
    /// dependency, and a dynamic `NSColor` re-resolves itself at draw time.
    private static func legible(_ base: Color) -> Color {
        let plain = NSColor(base)
        let srgb = plain.usingColorSpace(.sRGB) ?? plain
        let luminance = 0.2126 * srgb.redComponent
            + 0.7152 * srgb.greenComponent
            + 0.0722 * srgb.blueComponent
        let lifted = NSColor(base.mix(with: .white, by: luminance < 0.28 ? 0.58 : 0.16))
        return Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? lifted : plain
            }
        )
    }

}

/// The drawn half of the all-providers quota history card.
///
/// Split out of `OverviewQuotaHistoryCard` and made `Equatable` on purpose. That
/// card has to read `AccountStore`, `QuotaService` and `SettingsStore` to
/// discover which lanes exist, and an `@EnvironmentObject` invalidates the views
/// that read it *directly* — so every publish from a refresh, and a refresh
/// publishes repeatedly, re-ran the clip → budget → thin → build pipeline for
/// every curve on the main thread. Here the inputs are plain values and the diff
/// is a counter plus the window, so an unrelated publish stops at this boundary.
///
/// Like the card it came from, this view reads no wall clock and no environment
/// value, so it is safe under any re-proposal from above.
private struct OverviewQuotaChartBody: View, Equatable {
    let density: Theme.Density
    let curves: [OverviewQuotaCurve]
    let segmentsByCurve: [String: [[QuotaHistorySample]]]
    let flatByCurve: [String: [QuotaHistorySample]]
    let miniByCurve: [String: [[QuotaHistorySample]]]
    /// Stands in for the three dictionaries above; see the card's
    /// `seriesRevision`.
    let revision: Int
    let window: ChartTimeWindow
    let initialSpan: TimeInterval
    let resetToken: Int
    /// A plain setter rather than a `Binding`, so `==` never has to pull a
    /// value back through a binding whose view may no longer be installed.
    let setWindow: (ChartTimeWindow) -> Void

    /// Curves are compared by id rather than by value on purpose. Everything
    /// else about a curve — its hue, its dash, its label — is written by
    /// `rebuild()`, which bumps `revision`, so the ids answer the only question
    /// left: which curves the picker is currently showing. It also keeps the
    /// diff off `Color` equality, whose result for an appearance-aware
    /// `NSColor` is not something this comparison should depend on.
    static func == (lhs: OverviewQuotaChartBody, rhs: OverviewQuotaChartBody) -> Bool {
        lhs.revision == rhs.revision
            && lhs.window == rhs.window
            && lhs.density == rhs.density
            && lhs.initialSpan == rhs.initialSpan
            && lhs.resetToken == rhs.resetToken
            && lhs.curves.elementsEqual(rhs.curves) { $0.id == $1.id }
    }

    /// Shared across every visible curve, so a provider with nine quotas
    /// cannot starve the rest of the chart of detail. It is a *chart* budget:
    /// each curve draws one thinned line, so the plot stays inside it up to ten
    /// curves and thins every curve to the floor past that.
    private static let visibleMarkBudget = 900
    private static let minimumMarkBudget = 90

    /// One curve's drawable marks. Also carries the stroke, so the `Chart`
    /// closure never has to look a curve back up while laying marks out.
    private struct CurveLines: Identifiable {
        let id: String
        let color: Color
        let dash: [CGFloat]
        let points: [QuotaChartLinePoint]
        let bridges: [QuotaChartLinePoint]
    }

    private struct PlanKey: Equatable {
        let revision: Int
        let curveIds: [String]
        let range: ClosedRange<Date>
    }

    /// Reference box, so a memo hit or update during `body` never dirties view
    /// state; correctness comes from the key, not from invalidation timing.
    /// Same pattern (and reasoning) as `UsageTrendChartView`.
    private final class PlanCache {
        var key: PlanKey?
        var lines: [CurveLines]?
    }

    @State private var planCache = PlanCache()

    private var lines: [CurveLines] {
        let key = PlanKey(
            revision: revision,
            curveIds: curves.map(\.id),
            range: window.visibleRange
        )
        if let cached = planCache.lines, planCache.key == key { return cached }
        let built = Self.buildLines(
            curves: curves,
            segmentsByCurve: segmentsByCurve,
            range: key.range
        )
        planCache.key = key
        planCache.lines = built
        return built
    }

    private static func buildLines(
        curves: [OverviewQuotaCurve],
        segmentsByCurve: [String: [[QuotaHistorySample]]],
        range: ClosedRange<Date>
    ) -> [CurveLines] {
        // One budget per curve, split again across the segments that curve is
        // drawn in — a five-hour quota over months of history is hundreds of
        // small segments, and thinning each to the curve's budget would have
        // meant multiplying it by their count.
        let budget = max(minimumMarkBudget, visibleMarkBudget / max(1, curves.count))
        return curves.map { curve in
            let segments = segmentsByCurve[curve.id] ?? []
            return CurveLines(
                id: curve.id,
                color: curve.color,
                dash: curve.dash,
                points: QuotaChartMarks.points(
                    segments,
                    kind: curve.id,
                    range: range,
                    budget: budget,
                    time: { $0.time },
                    value: { $0.remainingPercent }
                ),
                bridges: QuotaChartMarks.bridges(
                    segments,
                    kind: curve.id,
                    range: range,
                    time: { $0.time },
                    value: { $0.remainingPercent }
                )
            )
        }
    }

    var body: some View {
        let binding = Binding<ChartTimeWindow>(get: { window }, set: setWindow)
        // Memoized on (series revision, curves, visible range): a pan or a zoom
        // is a genuine miss and rebuilds, every other re-proposal reuses what is
        // already laid out.
        let lines = self.lines

        VStack(alignment: .leading, spacing: 6) {
            legend

            Chart {
                // Bridges first so a real observation always draws over the
                // connector that leads into it.
                ForEach(lines) { line in
                    ForEach(line.bridges) { point in
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
                    ForEach(line.points) { point in
                        LineMark(
                            x: .value("Time", point.time),
                            y: .value("Left", point.value),
                            series: .value("Line", point.seriesKey)
                        )
                        .foregroundStyle(line.color)
                        .lineStyle(
                            StrokeStyle(
                                lineWidth: 1.6,
                                lineCap: .round,
                                lineJoin: .round,
                                dash: line.dash
                            )
                        )
                    }
                }
            }
            .chartLegend(.hidden)
            .chartXScale(domain: window.visibleRange)
            // Same clip as QuotaHistoryChartView: bridge marks deliberately
            // carry endpoints outside the visible range, and unclipped they
            // stroke across whatever sits left of the card.
            .chartPlotStyle { plotArea in
                plotArea.clipped()
            }
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
            // A view of its own rather than a closure over this body, so a
            // pointer move re-renders the crosshair and the tooltip and leaves
            // the marks above untouched.
            .chartOverlay { proxy in
                OverviewQuotaHoverOverlay(
                    proxy: proxy,
                    curves: curves,
                    flatByCurve: flatByCurve,
                    initialSpan: initialSpan,
                    resetToken: resetToken,
                    window: binding
                )
            }
            .frame(height: density.overviewQuotaHistoryChartHeight)

            ChartBrushNavigator(
                window: binding,
                accent: Color.secondary,
                height: density.chartBrushHeight,
                accessibilityDescription: "All-providers quota history range navigator"
            ) { geometry in
                miniPaths(in: geometry)
            }

            Text(scopeNote)
                .font(.system(size: max(8, density.resetCountdownFontSize - 1)))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    // MARK: - Brush mini

    private func miniPaths(in geometry: ChartBrushGeometry) -> some View {
        ZStack {
            ForEach(curves) { curve in
                Path { path in
                    // Already thinned when the lanes were built — this only
                    // projects the samples into the strip's coordinate space.
                    for segment in miniByCurve[curve.id] ?? [] {
                        guard let first = segment.first else { continue }
                        path.move(to: miniPoint(first, in: geometry))
                        for sample in segment.dropFirst() {
                            path.addLine(to: miniPoint(sample, in: geometry))
                        }
                    }
                }
                .stroke(
                    curve.color.opacity(0.6),
                    style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round)
                )
            }
        }
    }

    private func miniPoint(
        _ sample: QuotaHistorySample,
        in geometry: ChartBrushGeometry
    ) -> CGPoint {
        CGPoint(
            x: geometry.x(for: sample.time),
            y: geometry.y(forFraction: sample.remainingPercent / 100)
        )
    }

    // MARK: - Legend

    private var legend: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 138), spacing: 8)],
            alignment: .leading,
            spacing: 3
        ) {
            ForEach(curves) { curve in
                HStack(spacing: 4) {
                    swatch(curve)
                    Text(curve.label)
                        .font(.system(size: max(8, density.subtitleFontSize - 2)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func swatch(_ curve: OverviewQuotaCurve) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 1))
            path.addLine(to: CGPoint(x: 13, y: 1))
        }
        .stroke(curve.color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: curve.dash))
        .frame(width: 13, height: 2)
    }

    // MARK: - Footer

    private var scopeNote: String {
        let providers = Set(curves.map(\.tool)).count
        let curveWord = curves.count == 1 ? "curve" : "curves"
        let providerWord = providers == 1 ? "provider" : "providers"
        return "\(curves.count) \(curveWord) · \(providers) \(providerWord) · showing "
            + "\(Self.spanLabel(window.visibleSpan)) of \(Self.spanLabel(window.domainSpan)) recorded"
    }

    private static func spanLabel(_ seconds: TimeInterval) -> String {
        if seconds < 90 * 60 { return "\(max(1, Int((seconds / 60).rounded())))m" }
        if seconds < 48 * 3_600 { return "\(Int((seconds / 3_600).rounded()))h" }
        return "\(Int((seconds / 86_400).rounded()))d"
    }
}

/// Crosshair, tooltip and the all-providers plot's pan / pinch / double-tap
/// gestures.
///
/// A view of its own, with its own `@State`, for the same reason
/// `QuotaChartHoverOverlay` is: `hoverDate` used to sit on the card, so every
/// pointer move invalidated the card and re-ran the mark pipeline for every
/// curve before the crosshair could move a pixel. Here a pointer move
/// re-renders only this overlay, and the reading itself is one binary search per
/// curve over an array flattened when the lanes were built.
private struct OverviewQuotaHoverOverlay: View {
    let proxy: ChartProxy
    let curves: [OverviewQuotaCurve]
    let flatByCurve: [String: [QuotaHistorySample]]
    let initialSpan: TimeInterval
    /// Incremented by the card when the picker or a range pill has to drop the
    /// crosshair.
    let resetToken: Int
    @Binding var window: ChartTimeWindow

    @State private var hoverDate: Date?
    @State private var panBase: ChartTimeWindow?
    @State private var magnifyBase: ChartTimeWindow?

    private static let tooltipWidth: CGFloat = 214
    /// Past this many rows the tooltip stops being a readout and becomes a
    /// second chart; the rest are counted instead. Safe to cap only because
    /// the rows are sorted lowest-remaining first — the quotas that get folded
    /// into "+N more" are the ones with the most headroom.
    private static let tooltipRowLimit = 8

    // Built per language rather than once per process: a formatter
    // parked in a `static let` keeps the language it was created in.
    private static var tooltipFormatter: DateFormatter {
        AppLocale.dateFormatter(template: "MMMdHHmm")
    }

    var body: some View {
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
                            let value = proxy.value(atX: location.x - plotMinX, as: Date.self)
                            hoverDate = value.flatMap {
                                window.visibleRange.contains($0) ? $0 : nil
                            }
                        case .ended:
                            hoverDate = nil
                        }
                    }
                    .gesture(panGesture(plotWidth: plotWidth))
                    .simultaneousGesture(magnifyGesture(plotMinX: plotMinX))
                    .onTapGesture(count: 2) {
                        window = window.jumped(toSpan: initialSpan)
                        hoverDate = nil
                    }

                if let hoverDate,
                   let x = proxy.position(forX: hoverDate),
                   let plot {
                    let readings = hoverReadings(at: hoverDate)
                    Rectangle()
                        .fill(Color.primary.opacity(0.22))
                        .frame(width: 1, height: plot.height)
                        .offset(x: plotMinX + x, y: plot.minY)
                        .allowsHitTesting(false)
                    tooltip(at: hoverDate, readings: readings)
                        .offset(x: tooltipX(plotMinX: plotMinX, x: x, width: geometry.size.width))
                        .allowsHitTesting(false)
                }
            }
        }
        .onChange(of: resetToken) { _, _ in hoverDate = nil }
    }

    // MARK: - Gestures

    private func panGesture(plotWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard plotWidth > 0 else { return }
                let base = panBase ?? window
                if panBase == nil { panBase = base }
                let secondsPerPoint = base.visibleSpan / TimeInterval(plotWidth)
                window = base.panned(by: -TimeInterval(value.translation.width) * secondsPerPoint)
            }
            .onEnded { _ in panBase = nil }
    }

    private func magnifyGesture(plotMinX: CGFloat) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                let base = magnifyBase ?? window
                if magnifyBase == nil { magnifyBase = base }
                let anchor = proxy.value(atX: value.startLocation.x - plotMinX, as: Date.self)
                    ?? base.visibleMidpoint
                window = base.zoomed(scale: value.magnification, around: anchor)
            }
            .onEnded { _ in magnifyBase = nil }
    }

    // MARK: - Tooltip

    private func tooltipX(plotMinX: CGFloat, x: CGFloat, width: CGFloat) -> CGFloat {
        min(max(plotMinX + x - Self.tooltipWidth / 2, 0), max(0, width - Self.tooltipWidth))
    }

    private func tooltip(at date: Date, readings: [OverviewHoverReading]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Self.tooltipFormatter.string(from: date))
                .font(.system(size: 10, weight: .semibold))
            if readings.isEmpty {
                // Same wording as the per-group chart's empty row, and for the
                // same reason: an absent sample says the app was not watching,
                // not that the quota was between windows.
                Text("No data recorded")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                ForEach(readings.prefix(Self.tooltipRowLimit)) { reading in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle()
                            .fill(reading.color)
                            .frame(width: 5, height: 5)
                        Text(reading.label)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text("\(Int(reading.value.rounded()))%")
                            .font(
                                .system(size: 9, weight: .semibold, design: .rounded)
                                    .monospacedDigit()
                            )
                    }
                }
                if readings.count > Self.tooltipRowLimit {
                    Text("+\(readings.count - Self.tooltipRowLimit) more")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.87)))
        .foregroundStyle(.white)
        .frame(width: Self.tooltipWidth, alignment: .leading)
    }

    /// Nearest observation per curve, **lowest remaining first**.
    ///
    /// The order is the whole point of the card: the reader is looking for
    /// whichever quota is closest to running out, and the tooltip caps its rows
    /// — so sorting the fullest quotas to the top would have buried exactly the
    /// curves this card exists to surface behind "+N more". Curves with no
    /// coverage near the cursor are omitted rather than shown as zero.
    ///
    /// Resolved by binary search over each curve's flattened, time-sorted
    /// samples, because this runs on every pointer move — and with a tolerance
    /// resolved per curve, because this card exists to overlay quotas whose
    /// windows (and therefore whose sampling rhythms) differ by orders of
    /// magnitude.
    private func hoverReadings(at date: Date) -> [OverviewHoverReading] {
        var result: [OverviewHoverReading] = []
        for curve in curves {
            guard let sample = ChartSampleSearch.nearest(
                in: flatByCurve[curve.id] ?? [],
                to: date,
                tolerance: ChartHoverTolerance.seconds(
                    windowSeconds: curve.windowSeconds,
                    visibleSpan: window.visibleSpan
                ),
                time: { $0.time }
            ) else { continue }
            result.append(
                OverviewHoverReading(
                    id: curve.id,
                    label: curve.label,
                    color: curve.color,
                    value: sample.remainingPercent
                )
            )
        }
        return result.sorted { $0.value < $1.value }
    }
}
