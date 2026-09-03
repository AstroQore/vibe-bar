import Foundation

/// One quota lane handed to the reset-history comparison.
///
/// The App layer does the discovery (which accounts, which buckets, what they
/// are called); everything downstream of that — the weekly-and-up filter, the
/// waste arithmetic, the ordering, the verdict sentence, the draw budget —
/// lives here so it can be tested without a view and computed once per data
/// change instead of once per render.
///
/// `Equatable` on purpose: the App caches a built comparison keyed on the
/// inputs, and `[SubscriptionWindowSample]` comparison short-circuits on
/// identical storage, so an unchanged history costs one pointer compare per
/// lane rather than a walk over every sample.
public struct ResetHistoryLaneInput: Equatable, Sendable, Identifiable {
    public var accountId: String
    public var tool: ToolType
    public var bucketId: String
    /// L1 company ("Anthropic"). See `AGENTS.md` § 7.1 — this surface is on
    /// the quota axis, so it speaks company / SubProvider / group / bucket.
    public var company: String
    /// L2 SubProvider ("Claude"), from `ToolType.quotaSubProviderName`.
    public var subProvider: String
    /// L3 quota / model group ("Fable"), `nil` for a SubProvider's primary lane.
    public var groupTitle: String?
    /// The bucket itself ("Weekly").
    public var bucketTitle: String
    /// Set only when the provider has more than one account, so a
    /// single-account setup keeps its short labels.
    public var accountLabel: String?
    /// Window length from the live bucket, used when a sample carries none.
    public var liveWindowSeconds: Int?
    /// The in-progress cycle as the live quota sees it. Used only when the
    /// history has no open sample of its own.
    public var currentUsedPercent: Double?
    public var currentResetAt: Date?
    public var samples: [SubscriptionWindowSample]

    public var id: String { "\(accountId).\(bucketId)" }

    public init(
        accountId: String,
        tool: ToolType,
        bucketId: String,
        company: String,
        subProvider: String,
        groupTitle: String? = nil,
        bucketTitle: String,
        accountLabel: String? = nil,
        liveWindowSeconds: Int? = nil,
        currentUsedPercent: Double? = nil,
        currentResetAt: Date? = nil,
        samples: [SubscriptionWindowSample]
    ) {
        self.accountId = accountId
        self.tool = tool
        self.bucketId = bucketId
        self.company = company
        self.subProvider = subProvider
        self.groupTitle = groupTitle
        self.bucketTitle = bucketTitle
        self.accountLabel = accountLabel
        self.liveWindowSeconds = liveWindowSeconds
        self.currentUsedPercent = currentUsedPercent
        self.currentResetAt = currentResetAt
        self.samples = samples
    }
}

/// Every weekly-and-longer quota's reset history, side by side on one time
/// axis, answering a single question: how much of what was paid for expired
/// unused?
///
/// Five-hour lanes are deliberately excluded. They refill several times a day,
/// so a bar per cycle would be noise at any width the module can occupy, and
/// "wasted" is not a meaningful verdict on a window that comes back before
/// lunch. The cut is made on the *window length* (`minimumWindowSeconds`),
/// never on a bucket name — bucket ids and titles vary per provider and change
/// without notice.
public struct ResetHistoryComparison: Equatable, Sendable {
    // MARK: - Policy

    /// Weekly and up. A lane whose window is shorter than this never appears.
    public static let minimumWindowSeconds = 7 * 86_400

    /// How many recent cycles the per-lane "avg wasted" figure covers.
    public static let averageCycleCount = 4

    /// A cycle that refilled with more than this much unused is the shape the
    /// verdict sentence is allowed to call out.
    public static let wastefulCyclePercent: Double = 50

    /// Below this, an average is not worth a sentence of its own.
    public static let notableAverageWastePercent: Double = 25

    // MARK: - Nested types

    /// Visible span of the shared time axis.
    public enum Window: String, CaseIterable, Hashable, Sendable, Codable {
        case fourWeeks
        case eightWeeks
        case twelveWeeks
        case all

        public var weeks: Int? {
            switch self {
            case .fourWeeks: 4
            case .eightWeeks: 8
            case .twelveWeeks: 12
            case .all: nil
            }
        }

        /// Compact picker label.
        public var shortTitle: String {
            switch self {
            case .fourWeeks: "4w"
            case .eightWeeks: "8w"
            case .twelveWeeks: "12w"
            case .all: "All"
            }
        }

        public var spokenTitle: String {
            switch self {
            case .fourWeeks: "last 4 weeks"
            case .eightWeeks: "last 8 weeks"
            case .twelveWeeks: "last 12 weeks"
            case .all: "all recorded history"
            }
        }
    }

    /// Row order.
    public enum Ordering: String, CaseIterable, Hashable, Sendable, Codable {
        /// Most wasted first — the default, because the module exists to
        /// answer "where am I throwing quota away".
        case waste
        /// Grouped by L1 company, most wasted first inside each company.
        case company
    }

    /// One bar: a subscription cycle placed on the shared axis.
    public struct Cycle: Equatable, Sendable, Identifiable {
        public let id: String
        public let start: Date
        public let end: Date
        /// Peak used percent — the bar's height.
        public let usedPercent: Double
        public let isCompleted: Bool
        public let resetKind: SubscriptionWindowSample.ResetKind?

        /// The muted remainder above the fill: quota that expired unused.
        public var wastedPercent: Double { max(0, 100 - usedPercent) }

        /// Did this window refill before it said it would? Same question, and
        /// the same answer, as `SubscriptionWindowSample.refilledEarly`.
        public var refilledEarly: Bool {
            switch resetKind {
            case .earlyClockRestarted, .earlyClockUnchanged, .earlyUnclear: true
            case .onSchedule, .unobserved, nil: false
            }
        }

        /// What the provider did to the clock, when it did anything unusual.
        /// Empty for an ordinary on-schedule reset — the two early shapes mean
        /// opposite things, so the copy says which (see `AGENTS.md` § 11).
        public var resetDescription: String {
            switch resetKind {
            case .earlyClockRestarted: "refilled early, next window restarted"
            case .earlyClockUnchanged: "refilled early, next reset unchanged"
            case .earlyUnclear: "refilled early, onto a different schedule"
            case .onSchedule, .unobserved, nil: ""
            }
        }

        public init(
            id: String,
            start: Date,
            end: Date,
            usedPercent: Double,
            isCompleted: Bool,
            resetKind: SubscriptionWindowSample.ResetKind? = nil
        ) {
            self.id = id
            self.start = start
            self.end = end
            self.usedPercent = usedPercent.isFinite ? min(100, max(0, usedPercent)) : 0
            self.isCompleted = isCompleted
            self.resetKind = resetKind
        }
    }

    /// One row: a quota that resets independently of every other row.
    public struct Lane: Equatable, Sendable, Identifiable {
        public let id: String
        public let tool: ToolType
        public let company: String
        public let subProvider: String
        public let groupTitle: String?
        public let bucketTitle: String
        public let accountLabel: String?
        /// The lane's own window length, in seconds. Always at least
        /// `minimumWindowSeconds`.
        public let windowSeconds: Int
        /// Completed cycles inside the visible span, oldest first.
        public let cycles: [Cycle]
        /// The cycle running right now, if one is known.
        public let currentCycle: Cycle?
        /// Mean unused percent over the most recent `averagedCycleCount`
        /// completed cycles. `nil` when nothing has completed yet.
        public let averageWastedPercent: Double?
        /// How many cycles that average actually covers — the copy says so
        /// rather than promising "last 4" it does not have.
        public let averagedCycleCount: Int
        /// Completed cycles in the span that refilled with more than half
        /// unused.
        public let wastefulCycleCount: Int

        /// Full quota-axis name: company · SubProvider · group · bucket.
        public var label: String {
            var parts = [company, subProvider]
            if let groupTitle, !groupTitle.isEmpty { parts.append(groupTitle) }
            if !bucketTitle.isEmpty, bucketTitle != groupTitle { parts.append(bucketTitle) }
            if let accountLabel, !accountLabel.isEmpty { parts.append(accountLabel) }
            return parts.joined(separator: " · ")
        }

        /// The same name with the company dropped, for the company-grouped
        /// ordering where the heading already carries it.
        public var labelWithoutCompany: String {
            var parts = [subProvider]
            if let groupTitle, !groupTitle.isEmpty { parts.append(groupTitle) }
            if !bucketTitle.isEmpty, bucketTitle != groupTitle { parts.append(bucketTitle) }
            if let accountLabel, !accountLabel.isEmpty { parts.append(accountLabel) }
            return parts.joined(separator: " · ")
        }

        /// The line under the label. Says how many cycles it is averaging so a
        /// one-cycle lane cannot read as a settled habit.
        public var wasteSummary: String {
            guard let averageWastedPercent else {
                return "No completed cycles yet"
            }
            let cycleWord = averagedCycleCount == 1 ? "cycle" : "cycles"
            return "avg wasted \(Self.percentText(averageWastedPercent))% · last \(averagedCycleCount) \(cycleWord)"
        }

        /// Empty-state copy for a lane the history has never closed a cycle on
        /// — a brand-new bucket, or one whose provider has not refilled since
        /// Vibe Bar first saw it.
        public var emptyStateText: String {
            "No completed cycles yet — a cycle is recorded when the quota refills"
        }

        static func percentText(_ value: Double) -> String {
            String(Int(value.rounded()))
        }
    }

    /// The header's one-line arithmetic across every visible lane.
    public struct Totals: Equatable, Sendable {
        public let cycleCount: Int
        /// Share of the refilled capacity that was actually spent.
        public let usedPercent: Double
        public var wastedPercent: Double { max(0, 100 - usedPercent) }

        public init(cycleCount: Int, usedPercent: Double) {
            self.cycleCount = cycleCount
            self.usedPercent = usedPercent.isFinite ? min(100, max(0, usedPercent)) : 0
        }

        public var headline: String {
            guard cycleCount > 0 else { return "No completed cycles in this window" }
            let cycleWord = cycleCount == 1 ? "cycle" : "cycles"
            return "\(Lane.percentText(usedPercent))% used · \(Lane.percentText(wastedPercent))% wasted · \(cycleCount) \(cycleWord)"
        }
    }

    // MARK: - Value

    public let window: Window
    public let ordering: Ordering
    /// The clock the comparison was built against, so the view can draw its
    /// "now" hairline without reading the wall clock inside a draw pass — a
    /// value that changed under an otherwise-equal comparison would make the
    /// drawing surface's `Equatable` short-circuit a lie.
    public let now: Date
    public let rangeStart: Date
    public let rangeEnd: Date
    public let lanes: [Lane]
    public let totals: Totals
    /// One plain sentence generated from the data, never a template with a
    /// blank in it. Always non-empty.
    public let verdict: String

    public var isEmpty: Bool { lanes.isEmpty }

    /// Whole-module screen-reader text. The lanes are a drawing surface, so
    /// this is the only thing VoiceOver gets to read.
    public var accessibilitySummary: String {
        guard !lanes.isEmpty else {
            return "Reset history comparison. \(verdict)"
        }
        let laneText = lanes.prefix(8).map { lane -> String in
            guard let wasted = lane.averageWastedPercent else {
                return "\(lane.label): no completed cycles"
            }
            return "\(lane.label): \(Lane.percentText(wasted))% wasted on average over \(lane.averagedCycleCount) cycles"
        }.joined(separator: ". ")
        let more = lanes.count > 8 ? " And \(lanes.count - 8) more quotas." : ""
        return "Reset history comparison over \(window.spokenTitle). \(totals.headline). \(verdict) \(laneText).\(more)"
    }

    // MARK: - Building

    /// Build the comparison. Pure: everything it needs is in `inputs`.
    public static func build(
        inputs: [ResetHistoryLaneInput],
        window: Window = .eightWeeks,
        ordering: Ordering = .waste,
        now: Date
    ) -> ResetHistoryComparison {
        // 1. Weekly and up, decided on the window length rather than a name.
        let qualifying: [(input: ResetHistoryLaneInput, windowSeconds: Int)] = inputs.compactMap { input in
            guard let seconds = laneWindowSeconds(input), seconds >= minimumWindowSeconds else {
                return nil
            }
            return (input, seconds)
        }

        // 2. The visible span. A fixed window counts back from now; `all`
        //    starts at the oldest cycle anything recorded.
        var rangeStart: Date
        if let weeks = window.weeks {
            rangeStart = now.addingTimeInterval(-Double(weeks) * 7 * 86_400)
        } else {
            let earliest = qualifying.compactMap { entry in
                entry.input.samples
                    .map { cycleStart($0, windowSeconds: entry.windowSeconds) }
                    .min()
            }.min()
            rangeStart = earliest ?? now.addingTimeInterval(-8 * 7 * 86_400)
        }
        if rangeStart >= now {
            rangeStart = now.addingTimeInterval(-Double(minimumWindowSeconds))
        }

        // 3. One lane per qualifying quota.
        var lanes: [Lane] = []
        var latestEnd = now
        for (input, windowSeconds) in qualifying {
            var completed: [Cycle] = []
            var open: Cycle?
            for sample in input.samples {
                let start = cycleStart(sample, windowSeconds: windowSeconds)
                // A cycle ends when the refill was noticed, which is not always
                // the boundary it advertised — an early refill genuinely ended
                // sooner, and drawing it at the advertised end would put the
                // bar where nothing happened.
                let end = sample.isCompleted ? (sample.completedAt ?? sample.windowEnd) : sample.windowEnd
                let cycle = Cycle(
                    id: "\(input.id).\(end.timeIntervalSinceReferenceDate)",
                    start: min(start, end),
                    end: end,
                    usedPercent: sample.peakUsedPercent,
                    isCompleted: sample.isCompleted,
                    resetKind: sample.resetKind
                )
                if sample.isCompleted {
                    guard cycle.end >= rangeStart else { continue }
                    completed.append(cycle)
                    latestEnd = max(latestEnd, cycle.end)
                } else if open == nil || cycle.end > open!.end {
                    open = cycle
                }
            }
            completed.sort { $0.end < $1.end }

            // The live quota is the fallback for the in-progress cycle: a lane
            // whose history holds only closed samples still has one running.
            if open == nil,
               let used = input.currentUsedPercent,
               let resetAt = input.currentResetAt {
                open = Cycle(
                    id: "\(input.id).current",
                    start: resetAt.addingTimeInterval(-Double(windowSeconds)),
                    end: resetAt,
                    usedPercent: used,
                    isCompleted: false,
                    resetKind: nil
                )
            }
            if let open { latestEnd = max(latestEnd, min(open.end, now)) }

            let averaged = Array(completed.suffix(averageCycleCount))
            let average = averaged.isEmpty
                ? nil
                : averaged.reduce(0) { $0 + $1.wastedPercent } / Double(averaged.count)

            lanes.append(
                Lane(
                    id: input.id,
                    tool: input.tool,
                    company: input.company,
                    subProvider: input.subProvider,
                    groupTitle: input.groupTitle,
                    bucketTitle: input.bucketTitle,
                    accountLabel: input.accountLabel,
                    windowSeconds: windowSeconds,
                    cycles: completed,
                    currentCycle: open,
                    averageWastedPercent: average,
                    averagedCycleCount: averaged.count,
                    wastefulCycleCount: completed.count { $0.wastedPercent > wastefulCyclePercent }
                )
            )
        }

        // 4. Order.
        let ordered = sorted(lanes, by: ordering, companyOrder: companyOrder(qualifying.map(\.input)))

        // 5. Header arithmetic and the sentence under it.
        let allCycles = ordered.flatMap(\.cycles)
        let totals = Totals(
            cycleCount: allCycles.count,
            usedPercent: allCycles.isEmpty
                ? 0
                : allCycles.reduce(0) { $0 + $1.usedPercent } / Double(allCycles.count)
        )

        return ResetHistoryComparison(
            window: window,
            ordering: ordering,
            now: now,
            rangeStart: rangeStart,
            rangeEnd: max(latestEnd, rangeStart.addingTimeInterval(Double(minimumWindowSeconds))),
            lanes: ordered,
            totals: totals,
            verdict: verdict(lanes: ordered, totals: totals)
        )
    }

    // MARK: - Draw budget

    /// Bars that actually get drawn when a lane has more cycles than the row
    /// has pixels.
    ///
    /// Not uniform striding: this chart's whole point is the wasteful cycles,
    /// and an even stride is exactly as likely to drop the worst one as any
    /// other. Endpoints survive first (they anchor the axis), then the largest
    /// waste, and the result comes back in time order.
    public static func downsampled(_ cycles: [Cycle], limit: Int) -> [Cycle] {
        guard limit > 0 else { return [] }
        guard cycles.count > limit else { return cycles }
        var keep: Set<Int> = []
        if limit >= 1 { keep.insert(0) }
        if limit >= 2 { keep.insert(cycles.count - 1) }
        let byWaste = cycles.indices.sorted { lhs, rhs in
            let left = cycles[lhs].wastedPercent
            let right = cycles[rhs].wastedPercent
            return left == right ? lhs < rhs : left > right
        }
        for index in byWaste where keep.count < limit {
            keep.insert(index)
        }
        return keep.sorted().map { cycles[$0] }
    }

    // MARK: - Internals

    /// The lane's window length: what the live bucket says, else the length
    /// the samples agree on most often. Ties go to the longer window, because
    /// under-reporting a window is what would wrongly demote a weekly lane
    /// into the excluded five-hour band.
    static func laneWindowSeconds(_ input: ResetHistoryLaneInput) -> Int? {
        if let live = input.liveWindowSeconds, live > 0 { return live }
        var counts: [Int: Int] = [:]
        for sample in input.samples {
            guard let seconds = sample.rawWindowSeconds, seconds > 0 else { continue }
            counts[seconds, default: 0] += 1
        }
        guard !counts.isEmpty else { return nil }
        return counts.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value
        }?.key
    }

    /// Where a cycle's bar starts. The stored `windowStart` is the measured
    /// truth and wins whenever it exists — reconstructing it from the nominal
    /// window is the "fix" § 11 of `AGENTS.md` records as already wrong.
    private static func cycleStart(_ sample: SubscriptionWindowSample, windowSeconds: Int) -> Date {
        if let start = sample.windowStart { return start }
        let end = sample.isCompleted ? (sample.completedAt ?? sample.windowEnd) : sample.windowEnd
        return end.addingTimeInterval(-Double(sample.rawWindowSeconds ?? windowSeconds))
    }

    /// Companies in the order the caller discovered them, which is the app's
    /// canonical provider order — not alphabetical, which would reshuffle the
    /// page whenever a vendor renames itself.
    private static func companyOrder(_ inputs: [ResetHistoryLaneInput]) -> [String: Int] {
        var order: [String: Int] = [:]
        for input in inputs where order[input.company] == nil {
            order[input.company] = order.count
        }
        return order
    }

    private static func sorted(
        _ lanes: [Lane],
        by ordering: Ordering,
        companyOrder: [String: Int]
    ) -> [Lane] {
        func wasteFirst(_ lhs: Lane, _ rhs: Lane) -> Bool {
            // A lane with no completed cycle has no verdict to offer, so it
            // sinks below every lane that does rather than sorting as 0% waste.
            switch (lhs.averageWastedPercent, rhs.averageWastedPercent) {
            case let (left?, right?) where left != right:
                return left > right
            case (nil, .some):
                return false
            case (.some, nil):
                return true
            default:
                return lhs.label < rhs.label
            }
        }
        switch ordering {
        case .waste:
            return lanes.sorted(by: wasteFirst)
        case .company:
            return lanes.sorted { lhs, rhs in
                let left = companyOrder[lhs.company] ?? Int.max
                let right = companyOrder[rhs.company] ?? Int.max
                if left != right { return left < right }
                return wasteFirst(lhs, rhs)
            }
        }
    }

    /// The header sentence, in priority order:
    ///
    /// 1. Nothing to compare — no weekly-or-longer lane exists at all.
    /// 2. Lanes exist but nothing has closed a cycle yet.
    /// 3. Some lane refilled with more than half unused; name it and count it.
    ///    This is the finding the module was built to surface.
    /// 4. Nothing that stark, but the leakiest lane still averages a notable
    ///    amount of waste; quote it.
    /// 5. Everything is being spent; say so with the number, not a platitude.
    static func verdict(lanes: [Lane], totals: Totals) -> String {
        guard !lanes.isEmpty else {
            return "No weekly or longer quota is being tracked yet."
        }
        guard totals.cycleCount > 0 else {
            return "No completed cycles yet — a cycle is recorded when a quota refills."
        }
        let worstByCount = lanes
            .filter { $0.wastefulCycleCount > 0 }
            .max { lhs, rhs in
                lhs.wastefulCycleCount == rhs.wastefulCycleCount
                    ? (lhs.averageWastedPercent ?? 0) < (rhs.averageWastedPercent ?? 0)
                    : lhs.wastefulCycleCount < rhs.wastefulCycleCount
            }
        if let worst = worstByCount {
            let count = worst.wastefulCycleCount
            let times = count == 1 ? "once" : "\(count) times"
            return "\(worst.label) refilled \(times) with more than half unused."
        }
        let leakiest = lanes.max { ($0.averageWastedPercent ?? -1) < ($1.averageWastedPercent ?? -1) }
        if let leakiest, let wasted = leakiest.averageWastedPercent, wasted >= notableAverageWastePercent {
            let cycleWord = leakiest.averagedCycleCount == 1 ? "cycle" : "cycles"
            return "\(leakiest.label) left \(Lane.percentText(wasted))% unused on average across \(leakiest.averagedCycleCount) \(cycleWord)."
        }
        return "Nothing is going noticeably to waste — \(Lane.percentText(totals.usedPercent))% of the refilled capacity was spent."
    }
}
