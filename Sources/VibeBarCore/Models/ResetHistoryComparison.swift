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
    /// No live bucket backs this lane any more — the provider stopped
    /// returning it, or the account it belonged to is gone.
    ///
    /// It is not the same question as "are the live fields nil", and the
    /// difference is a bar on screen. A cycle closes only when another
    /// observation arrives, so a withdrawn bucket keeps its last *open*
    /// sample forever. Without this flag `build` would read that stale sample
    /// as the current cycle and draw a dashed "Current" bar for a quota that
    /// stopped existing months ago.
    public var isRetired: Bool
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
        isRetired: Bool = false,
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
        self.isRetired = isRetired
        self.samples = samples
    }
}

/// Every weekly-and-longer quota's reset history, side by side as one table,
/// answering a single question: how much of what was paid for expired unused?
///
/// The columns are cycle *ordinals*, not dates: the newest completed cycle of
/// every quota sits in the same column, the one before it in the column to its
/// left, and so on. Quotas refill on their own schedules, so a shared calendar
/// axis scattered their bars and made two rows impossible to read against each
/// other — which is the comparison the module exists for. A row with fewer
/// recorded cycles is right-aligned to the newest column and simply starts
/// further right.
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

    /// How many cycles back the table reaches. Counted in cycles rather than
    /// weeks, because the columns are ordinals: "last 8" means the same eight
    /// columns for every row, however far apart one row's refills happen to
    /// fall.
    public enum Window: String, CaseIterable, Hashable, Sendable, Codable {
        case four
        case eight
        case twelve
        case all

        /// `nil` for `all`, which is then bounded by `ColumnPlan.maximumColumns`.
        public var cycleLimit: Int? {
            switch self {
            case .four: 4
            case .eight: 8
            case .twelve: 12
            case .all: nil
            }
        }

        /// Compact picker label.
        public var shortTitle: String {
            switch self {
            case .four: "4"
            case .eight: "8"
            case .twelve: "12"
            case .all: "All"
            }
        }

        public var spokenTitle: String {
            switch self {
            case .four: "last 4 cycles"
            case .eight: "last 8 cycles"
            case .twelve: "last 12 cycles"
            case .all: "every recorded cycle"
            }
        }
    }

    /// The shared column grid every row is drawn against.
    ///
    /// One column per cycle ordinal, oldest on the left, plus an optional
    /// trailing column for the cycle running right now. Rows are right-aligned
    /// into it: whatever a row's newest completed cycle is, it lands in the
    /// last completed column, so reading straight down a column compares
    /// like with like.
    public struct ColumnPlan: Equatable, Sendable {
        /// Hard ceiling on the number of *drawn* columns, so a year of weeklies
        /// stays legible at the widths this module actually gets.
        ///
        /// A drawing budget only. Every statistic — the totals, each lane's
        /// average and wasteful-cycle count, the verdict — is computed over
        /// every cycle the window covers, because the picker says "All" and
        /// a headline that quietly meant "the newest 52" would be a lie.
        /// `ResetHistoryComparison.truncationNote` says so on screen when the
        /// two numbers differ.
        public static let maximumColumns = 52

        public let completedColumnCount: Int
        public let hasCurrentColumn: Bool

        public init(completedColumnCount: Int, hasCurrentColumn: Bool) {
            self.completedColumnCount = max(0, completedColumnCount)
            self.hasCurrentColumn = hasCurrentColumn
        }

        public var totalColumnCount: Int {
            completedColumnCount + (hasCurrentColumn ? 1 : 0)
        }

        public var isEmpty: Bool { totalColumnCount == 0 }

        /// Where the in-progress bar goes, when there is one.
        public var currentColumn: Int? {
            hasCurrentColumn ? completedColumnCount : nil
        }

        /// The column a lane's `index`-th completed cycle occupies.
        ///
        /// Right-aligned, which is the whole trick: a lane with three cycles
        /// and a lane with eight both put their newest in the last completed
        /// column, and the shorter row simply begins further right instead of
        /// pretending its oldest cycle is contemporary with the other's.
        public func column(ofCycleAt index: Int, inLaneWithCycleCount count: Int) -> Int {
            completedColumnCount - count + index
        }

        /// Axis caption for a column: how many cycles back it is, and `now`
        /// for the live one. `nil` where the axis should stay quiet.
        public func axisLabel(forColumn column: Int) -> String? {
            if column == currentColumn { return "now" }
            guard column >= 0, column < completedColumnCount else { return nil }
            return "−\(completedColumnCount - column)"
        }
    }

    /// One bar: a subscription cycle placed on the shared axis.
    public struct Cycle: Equatable, Sendable, Identifiable {
        public let id: String
        public let start: Date
        public let end: Date
        /// Peak used percent over the cycle. The bar draws `wastedPercent`,
        /// the complement — see there.
        public let usedPercent: Double
        public let isCompleted: Bool
        public let resetKind: SubscriptionWindowSample.ResetKind?

        /// What was left when the window refilled — and the bar's height.
        ///
        /// The module answers "am I wasting quota", so the quantity it draws
        /// is the waste itself: a tall bar is a cycle that expired mostly
        /// unused, an empty slot is one that was spent. For the in-progress
        /// cycle the same arithmetic reads as "remaining right now".
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
        /// Completed cycles the grid draws, oldest first. Capped at
        /// `ColumnPlan.maximumColumns`; `windowCycleCount` is how many the
        /// window actually covers.
        public let cycles: [Cycle]
        /// The cycle running right now, if one is known.
        public let currentCycle: Cycle?
        /// Mean unused percent over the most recent `averagedCycleCount`
        /// completed cycles. `nil` when nothing has completed yet.
        public let averageWastedPercent: Double?
        /// How many cycles that average actually covers — the copy says so
        /// rather than promising "last 4" it does not have.
        public let averagedCycleCount: Int
        /// Completed cycles in the window that refilled with more than half
        /// unused. Counted over every cycle the window covers, not only the
        /// drawn ones.
        public let wastefulCycleCount: Int

        /// Completed cycles the window covers, before the drawing cap. Equal
        /// to `cycles.count` unless the lane has more history than the grid
        /// has columns.
        public let windowCycleCount: Int

        /// True when the grid is showing fewer cycles than the statistics
        /// were computed from.
        public var isTruncated: Bool { windowCycleCount > cycles.count }

        /// Full quota-axis name: company · SubProvider · group · bucket.
        public var label: String {
            var parts = [company, subProvider]
            if let groupTitle, !groupTitle.isEmpty { parts.append(groupTitle) }
            if !bucketTitle.isEmpty, bucketTitle != groupTitle { parts.append(bucketTitle) }
            if let accountLabel, !accountLabel.isEmpty { parts.append(accountLabel) }
            return parts.joined(separator: " · ")
        }

        /// The row's own name: SubProvider / group / bucket, with the company
        /// dropped because the heading above the group already carries it.
        /// "Gemini Web / Weekly", "AntiGravity / Claude & GPT Models / Weekly".
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
    /// The clock the comparison was built against, so the view never reads the
    /// wall clock inside a draw pass — a value that changed under an
    /// otherwise-equal comparison would make the drawing surface's `Equatable`
    /// short-circuit a lie.
    public let now: Date
    /// The shared column grid every row is drawn against.
    public let columns: ColumnPlan
    /// Rows in hierarchy order: L1 company, then L2 SubProvider, then the L3
    /// groups and buckets in the order the popover lists them.
    public let lanes: [Lane]
    public let totals: Totals
    /// One plain sentence generated from the data, never a template with a
    /// blank in it. Always non-empty.
    public let verdict: String

    public var isEmpty: Bool { lanes.isEmpty }

    /// What to say when the grid shows fewer cycles than the numbers describe.
    ///
    /// `All` on a three-year retention can reach past the column ceiling. The
    /// statistics still cover everything — only the drawing is capped — and
    /// this is the sentence that keeps the two honest with each other.
    public var truncationNote: String? {
        guard lanes.contains(where: \.isTruncated) else { return nil }
        let deepest = lanes.map(\.windowCycleCount).max() ?? 0
        return "showing the newest \(columns.completedColumnCount) of \(deepest) cycles"
    }

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
        // The note comes before the numbers on purpose: it is the caveat on
        // them, not a footnote to the lane list.
        let truncation = truncationNote.map { " Grid \($0); the figures cover every one." } ?? ""
        return "Reset history comparison, \(window.spokenTitle), bar height is the quota remaining at reset.\(truncation) \(totals.headline). \(verdict) \(laneText).\(more)"
    }

    // MARK: - Building

    /// Build the comparison. Pure: everything it needs is in `inputs`.
    public static func build(
        inputs: [ResetHistoryLaneInput],
        window: Window = .eight,
        now: Date
    ) -> ResetHistoryComparison {
        // 1. Weekly and up, decided on the window length rather than a name.
        let qualifying: [(input: ResetHistoryLaneInput, windowSeconds: Int)] = inputs.compactMap { input in
            guard let seconds = laneWindowSeconds(input), seconds >= minimumWindowSeconds else {
                return nil
            }
            return (input, seconds)
        }

        // 2. One lane per qualifying quota.
        //
        //    Two limits, deliberately different. `retained` is what the window
        //    means — the newest N cycles, or every recorded one for `all` — and
        //    every statistic is computed from it. `drawable` is what the grid
        //    has columns for. Capping the statistics at the drawing budget
        //    would make "All" quietly mean "the newest 52" in the headline, the
        //    verdict and the wasteful-cycle counts.
        let statisticsLimit = window.cycleLimit ?? Int.max
        let drawLimit = min(statisticsLimit, ColumnPlan.maximumColumns)
        var lanes: [Lane] = []
        var totalCycleCount = 0
        var totalUsedSum: Double = 0
        for (input, windowSeconds) in qualifying {
            var completed: [Cycle] = []
            var open: Cycle?
            // A retired lane has no present tense. Its last open sample was
            // never closed because nothing observed it again, and the live
            // quota that would have closed it is gone.
            let hasCurrentCycle = !input.isRetired
            for sample in input.samples {
                let start = cycleStart(sample, windowSeconds: windowSeconds)
                // A cycle ends when the refill was noticed, which is not always
                // the boundary it advertised — an early refill genuinely ended
                // sooner, and the tooltip should say when it actually happened.
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
                    completed.append(cycle)
                } else if hasCurrentCycle, open == nil || cycle.end > open!.end {
                    open = cycle
                }
            }
            completed.sort { $0.end < $1.end }
            let retained = Array(completed.suffix(statisticsLimit))
            let drawable = Array(retained.suffix(drawLimit))
            totalCycleCount += retained.count
            totalUsedSum += retained.reduce(0) { $0 + $1.usedPercent }

            // The live quota is the fallback for the in-progress cycle: a lane
            // whose history holds only closed samples still has one running.
            if hasCurrentCycle,
               open == nil,
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

            let averaged = Array(retained.suffix(averageCycleCount))
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
                    cycles: drawable,
                    currentCycle: open,
                    averageWastedPercent: average,
                    averagedCycleCount: averaged.count,
                    wastefulCycleCount: retained.count { $0.wastedPercent > wastefulCyclePercent },
                    windowCycleCount: retained.count
                )
            )
        }

        // 3. Hierarchy order, then the grid every row shares.
        let ordered = hierarchical(lanes, ranks: hierarchyRanks(qualifying.map(\.input)))
        let columns = ColumnPlan(
            completedColumnCount: ordered.map(\.cycles.count).max() ?? 0,
            hasCurrentColumn: ordered.contains { $0.currentCycle != nil }
        )

        // 4. Header arithmetic and the sentence under it, over every cycle the
        //    window covers — not only the ones that fit on the grid.
        let totals = Totals(
            cycleCount: totalCycleCount,
            usedPercent: totalCycleCount == 0 ? 0 : totalUsedSum / Double(totalCycleCount)
        )

        return ResetHistoryComparison(
            window: window,
            now: now,
            columns: columns,
            lanes: ordered,
            totals: totals,
            verdict: verdict(lanes: ordered, totals: totals)
        )
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

    /// L1 and L2 ranks, taken from the order the caller discovered them in.
    ///
    /// That order is the app's canonical provider order and, inside a
    /// provider, the order the popover lists the buckets in. Ranking by first
    /// appearance rather than alphabetically is deliberate: a vendor renaming
    /// itself must not reshuffle the table.
    static func hierarchyRanks(
        _ inputs: [ResetHistoryLaneInput]
    ) -> (company: [String: Int], subProvider: [String: Int]) {
        var company: [String: Int] = [:]
        var subProvider: [String: Int] = [:]
        for input in inputs {
            if company[input.company] == nil { company[input.company] = company.count }
            let key = subProviderKey(company: input.company, subProvider: input.subProvider)
            if subProvider[key] == nil { subProvider[key] = subProvider.count }
        }
        return (company, subProvider)
    }

    static func subProviderKey(company: String, subProvider: String) -> String {
        "\(company)/\(subProvider)"
    }

    /// Company, then SubProvider, then discovery order for the groups and
    /// buckets underneath — the same three levels the popover reads in.
    ///
    /// Sorted through the original offsets because `sort` is not stable, and
    /// L3 order *is* the input order: losing it would scramble a SubProvider's
    /// own buckets.
    private static func hierarchical(
        _ lanes: [Lane],
        ranks: (company: [String: Int], subProvider: [String: Int])
    ) -> [Lane] {
        lanes.enumerated().sorted { lhs, rhs in
            let leftCompany = ranks.company[lhs.element.company] ?? Int.max
            let rightCompany = ranks.company[rhs.element.company] ?? Int.max
            if leftCompany != rightCompany { return leftCompany < rightCompany }
            let leftSub = ranks.subProvider[
                subProviderKey(company: lhs.element.company, subProvider: lhs.element.subProvider)
            ] ?? Int.max
            let rightSub = ranks.subProvider[
                subProviderKey(company: rhs.element.company, subProvider: rhs.element.subProvider)
            ] ?? Int.max
            if leftSub != rightSub { return leftSub < rightSub }
            return lhs.offset < rhs.offset
        }.map(\.element)
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
