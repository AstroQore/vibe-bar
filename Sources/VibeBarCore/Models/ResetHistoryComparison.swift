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

/// Which axis the reset-history comparison lays its bars out on.
///
/// Two honest answers to "compare these quotas", and the module ships both
/// because they answer different questions. `cycle` puts every quota's newest
/// refill in the same column, so two rows can be read against each other even
/// though they refill on unrelated schedules — the comparison the module was
/// built for. `time` puts each cycle where it actually happened, which is the
/// only way to see that two quotas ran dry in the same week, or that a lane
/// stopped refilling in March.
///
/// Persisted in `AppSettings.resetHistoryCompareAxis`, one choice shared by
/// every surface that draws the module.
public enum ResetHistoryAxis: String, CaseIterable, Hashable, Sendable, Codable {
    case cycle
    case time

    /// Segmented-control label. Plain words: the difference between the two is
    /// not something an icon can carry.
    public var title: String {
        switch self {
        case .cycle: L10n.ResetHistory.Axis.cycle
        case .time: L10n.ResetHistory.Axis.time
        }
    }

    public var help: String {
        switch self {
        case .cycle: L10n.ResetHistory.Axis.cycleHelp
        case .time: L10n.ResetHistory.Axis.timeHelp
        }
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

    /// How far back the comparison reaches.
    ///
    /// The four steps are shared by both axes, but the unit is the axis's own:
    /// on `cycle` they count cycles, because the columns are ordinals and
    /// "last 8" has to mean the same eight columns for every row however far
    /// apart its refills fall; on `time` they count weeks, because there the
    /// x position *is* the calendar.
    public enum Window: String, CaseIterable, Hashable, Sendable, Codable {
        case four
        case eight
        case twelve
        case all

        /// Cycle axis: how many of the newest cycles the window keeps. `nil`
        /// for `all`, whose *drawing* is then bounded by
        /// `ColumnPlan.maximumColumns`.
        public var cycleLimit: Int? {
            switch self {
            case .four: 4
            case .eight: 8
            case .twelve: 12
            case .all: nil
            }
        }

        /// Time axis: how many weeks back the span starts. `nil` for `all`,
        /// which starts at the oldest recorded cycle.
        public var weeks: Int? {
            switch self {
            case .four: 4
            case .eight: 8
            case .twelve: 12
            case .all: nil
            }
        }

        /// Compact picker label. Carries the unit on the time axis, because
        /// "8" next to a calendar would read as eight of the wrong thing.
        public func shortTitle(for axis: ResetHistoryAxis) -> String {
            switch (self, axis) {
            case (.four, .cycle): "4"
            case (.eight, .cycle): "8"
            case (.twelve, .cycle): "12"
            case (.four, .time): L10n.ResetHistory.Window.fourWeeks
            case (.eight, .time): L10n.ResetHistory.Window.eightWeeks
            case (.twelve, .time): L10n.ResetHistory.Window.twelveWeeks
            case (.all, _): L10n.ResetHistory.Window.all
            }
        }

        public func spokenTitle(for axis: ResetHistoryAxis) -> String {
            switch (self, axis) {
            case (.four, .cycle): L10n.ResetHistory.Spoken.fourCycles
            case (.eight, .cycle): L10n.ResetHistory.Spoken.eightCycles
            case (.twelve, .cycle): L10n.ResetHistory.Spoken.twelveCycles
            case (.all, .cycle): L10n.ResetHistory.Spoken.allCycles
            case (.four, .time): L10n.ResetHistory.Spoken.fourWeeks
            case (.eight, .time): L10n.ResetHistory.Spoken.eightWeeks
            case (.twelve, .time): L10n.ResetHistory.Spoken.twelveWeeks
            case (.all, .time): L10n.ResetHistory.Spoken.allTime
            }
        }
    }

    /// The stretch of calendar the time axis maps onto the plot.
    public struct TimeSpan: Equatable, Sendable {
        public let start: Date
        public let end: Date

        public init(start: Date, end: Date) {
            self.start = start
            // A span has to have width, or every bar lands on the same pixel.
            self.end = max(end, start.addingTimeInterval(1))
        }

        public var duration: TimeInterval { end.timeIntervalSince(start) }

        /// Where a date sits across the span, 0…1 at the ends. Deliberately
        /// unclamped: a cycle that begins before the span still has to be
        /// drawn from off the left edge and clipped, not stacked at zero.
        public func fraction(of date: Date) -> Double {
            date.timeIntervalSince(start) / duration
        }
    }

    /// The grid the bars are placed on, which is what the two axes actually
    /// differ in — everything else about a comparison is shared.
    public enum Grid: Equatable, Sendable {
        case cycles(ColumnPlan)
        case time(TimeSpan)
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
            if column == currentColumn { return L10n.ResetHistory.axisNow }
            guard column >= 0, column < completedColumnCount else { return nil }
            return L10n.ResetHistory.axisCyclesBack(count: completedColumnCount - column)
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
            case .earlyClockRestarted: L10n.ResetHistory.Reset.earlyClockRestarted
            case .earlyClockUnchanged: L10n.ResetHistory.Reset.earlyClockUnchanged
            case .earlyUnclear: L10n.ResetHistory.Reset.earlyUnclear
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

        /// Full quota-axis name on one line: company · SubProvider · group ·
        /// bucket. The tooltip and the screen-reader summary use this — both
        /// are prose, with no column to line levels up in. The row itself uses
        /// `subProvider` over `bucketLine` instead.
        public var label: String {
            // `company` and `subProvider` are L1/L2 quota-axis names —
            // OpenAI, Anthropic, ChatGPT Agentic — and are never
            // translated. The L3 group and bucket are the level where a
            // generic window word lives, so they go through the
            // localizer: without it a Chinese verdict reads "… Weekly 有 1
            // 次補額後超過一半未使用", with an English word in the middle of
            // a Chinese sentence. `Sonnet`, `Fable` and `Gemini Models`
            // are not in its table and come back untouched.
            var parts = [company, subProvider]
            parts.append(contentsOf: displayedGroupAndBucket)
            if let accountLabel, !accountLabel.isEmpty { parts.append(accountLabel) }
            return parts.joined(separator: " · ")
        }

        /// Second line of the row label: the quota group and the bucket inside
        /// the SubProvider, plus the account when the provider has more than
        /// one of them.
        ///
        /// The row label is drawn as two *levels*, not as one string that
        /// wraps: `subProvider` is line one and this is line two. Joined, they
        /// read "ChatGPT Agentic · Weekly" and the break landed wherever the
        /// column happened to run out, so no two rows agreed on where the
        /// SubProvider ended and the bucket began.
        ///
        /// The group and the bucket *are* one level, so they stay joined here —
        /// "GPT-5.3 Codex Spark · Weekly" is one answer to "which quota", not
        /// two. A lane whose L3 is only a bucket gets just the bucket.
        public var bucketLine: String {
            var parts = displayedGroupAndBucket
            if let accountLabel, !accountLabel.isEmpty { parts.append(accountLabel) }
            return parts.joined(separator: " · ")
        }

        /// The L3 level as it is shown: the group, then the bucket when it
        /// says something the group did not.
        ///
        /// The "is the bucket just the group again?" test is made on the
        /// *displayed* strings rather than the stored ones. Two contract
        /// values that render to the same word would otherwise print it
        /// twice, which is the exact duplicate this check exists to stop.
        private var displayedGroupAndBucket: [String] {
            var parts: [String] = []
            let group = groupTitle
                .map(QuotaGroupLabelLocalizer.display)
                .flatMap { $0.isEmpty ? nil : $0 }
            if let group { parts.append(group) }
            let bucket = QuotaGroupLabelLocalizer.display(bucketTitle)
            if !bucket.isEmpty, bucket != group { parts.append(bucket) }
            return parts
        }

        /// The line under the label. Says how many cycles it is averaging so a
        /// one-cycle lane cannot read as a settled habit.
        public var wasteSummary: String {
            guard let averageWastedPercent else {
                return L10n.ResetHistory.noCompletedCycles
            }
            // No hand-rolled "cycle"/"cycles": the catalog carries the plural,
            // so Chinese — which has one form — never has to pick.
            return L10n.ResetHistory.laneAverage(
                percent: Self.percentText(averageWastedPercent),
                count: averagedCycleCount
            )
        }

        /// Empty-state copy for a lane the history has never closed a cycle on
        /// — a brand-new bucket, or one whose provider has not refilled since
        /// Vibe Bar first saw it.
        public var emptyStateText: String {
            L10n.ResetHistory.Lane.emptyState
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
            guard cycleCount > 0 else { return L10n.ResetHistory.Totals.none }
            return L10n.ResetHistory.wastedSummary(
                used: Lane.percentText(usedPercent),
                wasted: Lane.percentText(wastedPercent),
                count: cycleCount
            )
        }
    }

    // MARK: - Value

    public let axis: ResetHistoryAxis
    public let window: Window
    /// The clock the comparison was built against, so the view never reads the
    /// wall clock inside a draw pass — a value that changed under an
    /// otherwise-equal comparison would make the drawing surface's `Equatable`
    /// short-circuit a lie.
    public let now: Date
    /// Where the bars go: ordinal columns, or a stretch of calendar.
    public let grid: Grid
    /// Rows in hierarchy order: L1 company, then L2 SubProvider, then the L3
    /// groups and buckets in the order the popover lists them.
    public let lanes: [Lane]
    public let totals: Totals

    /// One plain sentence generated from the data, never a template with a
    /// blank in it. Always non-empty.
    ///
    /// Derived on access rather than stored, because this value is
    /// localized and the comparison outlives a language change.
    /// `ResetHistoryCompareView`'s memo is keyed on the inputs, the axis,
    /// the window and the hour — the things that decide the *numbers* —
    /// and a stored sentence would survive that key untouched, leaving the
    /// old language on screen (and inside `accessibilitySummary`) until
    /// data changed or the hour turned over.
    ///
    /// Widening the cache key was the other option and is the worse one: a
    /// memo that has to enumerate every global the value secretly depends
    /// on will miss the next one. Keeping every localized string on this
    /// type computed means the memo only ever has to know about data.
    /// It costs one pass over `lanes` — a handful of rows, the same order
    /// as `truncationNote` next to it — and no allocation the sentence
    /// would not have made anyway.
    public var verdict: String { Self.verdict(lanes: lanes, totals: totals) }

    public var isEmpty: Bool { lanes.isEmpty }

    /// The cycle axis's column grid. An empty plan on the time axis, which
    /// has no columns — callers switch on `grid`, and this is the convenience
    /// for the ones that only ever ask about one of them.
    public var columns: ColumnPlan {
        guard case let .cycles(plan) = grid else {
            return ColumnPlan(completedColumnCount: 0, hasCurrentColumn: false)
        }
        return plan
    }

    /// The time axis's span, or `nil` on the cycle axis.
    public var span: TimeSpan? {
        guard case let .time(span) = grid else { return nil }
        return span
    }

    /// What to say when the grid shows fewer cycles than the numbers describe.
    ///
    /// `All` on a three-year retention can reach past the column ceiling. The
    /// statistics still cover everything — only the drawing is capped — and
    /// this is the sentence that keeps the two honest with each other.
    public var truncationNote: String? {
        // Only the cycle axis has a ceiling to overflow: the time axis draws
        // every retained cycle and thins by pixel at draw time, which loses no
        // cycle from the arithmetic and needs no caveat on it.
        guard case let .cycles(plan) = grid,
              lanes.contains(where: \.isTruncated)
        else { return nil }
        let deepest = lanes.map(\.windowCycleCount).max() ?? 0
        return L10n.ResetHistory.truncation(
            shown: plan.completedColumnCount, total: deepest
        )
    }

    /// Whole-module screen-reader text. The lanes are a drawing surface, so
    /// this is the only thing VoiceOver gets to read.
    public var accessibilitySummary: String {
        guard !lanes.isEmpty else {
            return L10n.ResetHistory.A11y.empty(verdict: verdict)
        }
        let laneText = lanes.prefix(8).map { lane -> String in
            guard let wasted = lane.averageWastedPercent else {
                return L10n.ResetHistory.Lane.spokenNoCycles(label: lane.label)
            }
            return L10n.ResetHistory.Lane.spokenWaste(
                label: lane.label,
                percent: Lane.percentText(wasted),
                count: lane.averagedCycleCount
            )
        }.joined(separator: ". ")
        let more = lanes.count > 8
            ? L10n.ResetHistory.A11y.more(count: lanes.count - 8)
            : ""
        // The note comes before the numbers on purpose: it is the caveat on
        // them, not a footnote to the lane list.
        let truncation = truncationNote.map { L10n.ResetHistory.A11y.truncation(note: $0) } ?? ""
        return L10n.ResetHistory.A11y.summary(
            window: window.spokenTitle(for: axis),
            truncation: truncation,
            headline: totals.headline,
            verdict: verdict,
            lanes: laneText,
            more: more
        )
    }

    // MARK: - Building

    /// Build the comparison. Pure: everything it needs is in `inputs`.
    public static func build(
        inputs: [ResetHistoryLaneInput],
        axis: ResetHistoryAxis = .cycle,
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

        // 2. The window, in whichever unit this axis counts. The cycle axis
        //    keeps the newest N cycles per lane; the time axis keeps whatever
        //    fell inside a stretch of calendar, which is a different set and
        //    a different size per lane.
        //
        //    On the cycle axis, two limits, deliberately different. `retained`
        //    is what the window means and every statistic is computed from it;
        //    `drawable` is what the grid has columns for. Capping the
        //    statistics at the drawing budget would make "All" quietly mean
        //    "the newest 52" in the headline, the verdict and the
        //    wasteful-cycle counts. The time axis needs no such cap — it thins
        //    by pixel at draw time, which drops no cycle from the arithmetic.
        let statisticsLimit = axis == .cycle ? (window.cycleLimit ?? Int.max) : Int.max
        let drawLimit = axis == .cycle
            ? min(statisticsLimit, ColumnPlan.maximumColumns)
            : Int.max
        let spanStart = axis == .time
            ? timeSpanStart(window: window, qualifying: qualifying, now: now)
            : nil
        var latestEnd = now
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
            if let spanStart {
                // The time axis's window is a date, not a count: a lane that
                // refilled twice in twelve weeks contributes two bars, and a
                // lane that refilled thirty times contributes thirty.
                completed.removeAll { $0.end < spanStart }
            }
            let retained = Array(completed.suffix(statisticsLimit))
            let drawable = Array(retained.suffix(drawLimit))
            totalCycleCount += retained.count
            totalUsedSum += retained.reduce(0) { $0 + $1.usedPercent }
            if let last = retained.last { latestEnd = max(latestEnd, last.end) }

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
        let grid: Grid
        if let spanStart {
            // The live cycle's bar runs to its scheduled reset, which is in
            // the future — the span has to reach it or the dashed bar is
            // clipped off the right edge on every lane.
            for lane in ordered {
                if let current = lane.currentCycle { latestEnd = max(latestEnd, current.end) }
            }
            grid = .time(TimeSpan(start: spanStart, end: latestEnd))
        } else {
            grid = .cycles(
                ColumnPlan(
                    completedColumnCount: ordered.map(\.cycles.count).max() ?? 0,
                    hasCurrentColumn: ordered.contains { $0.currentCycle != nil }
                )
            )
        }

        // 4. Header arithmetic over every cycle the window covers — not only
        //    the ones that fit on the grid. The sentence under it is derived
        //    from these on access, so it follows the app's language.
        let totals = Totals(
            cycleCount: totalCycleCount,
            usedPercent: totalCycleCount == 0 ? 0 : totalUsedSum / Double(totalCycleCount)
        )

        return ResetHistoryComparison(
            axis: axis,
            window: window,
            now: now,
            grid: grid,
            lanes: ordered,
            totals: totals
        )
    }

    // MARK: - Default window

    /// A bar narrower than this is a hairline, not a bar. Twelve points of
    /// bar plus the point-and-a-half of air `barRect` insets on each side.
    public static let minimumComfortableColumnWidth: Double = 15

    /// The window a card of this width should open on.
    ///
    /// The widest of the fixed steps whose columns still draw as bars. A card
    /// half the popover wide and one filling the Workbench are the same module
    /// with very different room, and a single hard-coded default left one of
    /// them either sparse or crammed.
    ///
    /// `all` is never chosen for you: it is a deliberate "show me everything",
    /// and on a lane with years of history it is exactly the choice that needs
    /// to be made on purpose.
    ///
    /// One extra column is assumed for the cycle running now — the common case,
    /// and guessing it wrong costs a slightly *wider* bar rather than a
    /// narrower one.
    public static func defaultWindow(
        chartWidth: Double,
        minimumColumnWidth: Double = minimumComfortableColumnWidth
    ) -> Window {
        for window in [Window.twelve, .eight, .four] {
            guard let cycles = window.cycleLimit else { continue }
            if chartWidth / Double(cycles + 1) >= minimumColumnWidth { return window }
        }
        // Fewer bars beats unreadable ones, so the narrowest step is the floor
        // rather than an even narrower ad-hoc count.
        return .four
    }

    // MARK: - Draw budget

    /// Bars a lane actually draws on the **time** axis, when it has more
    /// cycles than the row has pixels.
    ///
    /// The cycle axis needs none of this — one column is one cycle, and the
    /// ceiling is the plan. The time axis has no such bound: a year of Codex
    /// weeklies on a 200-point row is a bar every two pixels, so something has
    /// to go, and *which* something matters. Not a uniform stride, which is
    /// exactly as likely to drop the worst cycle as any other: the endpoints
    /// survive first because they anchor the span, then the largest waste,
    /// because a chart about wasted quota that drops the wasteful cycles is
    /// worse than no chart. The result comes back in time order.
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

    /// Where the time axis starts: a fixed number of weeks back, or the oldest
    /// recorded cycle for `all`.
    private static func timeSpanStart(
        window: Window,
        qualifying: [(input: ResetHistoryLaneInput, windowSeconds: Int)],
        now: Date
    ) -> Date {
        if let weeks = window.weeks {
            return now.addingTimeInterval(-Double(weeks) * 7 * 86_400)
        }
        let earliest = qualifying.compactMap { entry in
            entry.input.samples
                .map { cycleStart($0, windowSeconds: entry.windowSeconds) }
                .min()
        }.min()
        // Nothing recorded yet still needs a span with width to it.
        guard let earliest, earliest < now else {
            return now.addingTimeInterval(-8 * 7 * 86_400)
        }
        return earliest
    }


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
            return L10n.ResetHistory.Verdict.noQuota
        }
        guard totals.cycleCount > 0 else {
            return L10n.ResetHistory.Verdict.noCycles
        }
        let worstByCount = lanes
            .filter { $0.wastefulCycleCount > 0 }
            .max { lhs, rhs in
                lhs.wastefulCycleCount == rhs.wastefulCycleCount
                    ? (lhs.averageWastedPercent ?? 0) < (rhs.averageWastedPercent ?? 0)
                    : lhs.wastefulCycleCount < rhs.wastefulCycleCount
            }
        if let worst = worstByCount {
            return L10n.ResetHistory.Verdict.wasteful(
                label: worst.label, count: worst.wastefulCycleCount
            )
        }
        let leakiest = lanes.max { ($0.averageWastedPercent ?? -1) < ($1.averageWastedPercent ?? -1) }
        if let leakiest, let wasted = leakiest.averageWastedPercent, wasted >= notableAverageWastePercent {
            return L10n.ResetHistory.Verdict.leaky(
                label: leakiest.label,
                percent: Lane.percentText(wasted),
                count: leakiest.averagedCycleCount
            )
        }
        return L10n.ResetHistory.Verdict.clean(
            percent: Lane.percentText(totals.usedPercent)
        )
    }
}
