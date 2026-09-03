import XCTest
@testable import VibeBarCore

/// The aggregation behind the Reset History Compare module: which lanes get in,
/// what "wasted" means, how the rows are ordered, and what the header sentence
/// is allowed to say.
final class ResetHistoryComparisonTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let week = 7.0 * 86_400

    // MARK: - Fixtures

    private func sample(
        bucketId: String,
        endingDaysAgo: Double,
        used: Double,
        windowSeconds: Int = 7 * 86_400,
        completed: Bool = true,
        resetKind: SubscriptionWindowSample.ResetKind? = .onSchedule
    ) -> SubscriptionWindowSample {
        let end = now.addingTimeInterval(-endingDaysAgo * 86_400)
        return SubscriptionWindowSample(
            accountId: "acct",
            tool: .claude,
            bucketId: bucketId,
            windowEnd: end,
            windowStart: end.addingTimeInterval(-Double(windowSeconds)),
            rawWindowSeconds: windowSeconds,
            peakUsedPercent: used,
            lastUsedPercent: used,
            firstSeenAt: end.addingTimeInterval(-Double(windowSeconds)),
            lastSeenAt: end,
            completedAt: completed ? end : nil,
            completionReason: completed ? .refillDetected : nil,
            resetKind: completed ? resetKind : nil
        )
    }

    private func lane(
        id: String = "weekly",
        tool: ToolType = .claude,
        company: String = "Anthropic",
        subProvider: String = "Claude",
        group: String? = nil,
        bucketTitle: String = "Weekly",
        windowSeconds: Int? = 7 * 86_400,
        currentUsed: Double? = nil,
        currentResetAt: Date? = nil,
        samples: [SubscriptionWindowSample]
    ) -> ResetHistoryLaneInput {
        ResetHistoryLaneInput(
            accountId: "acct",
            tool: tool,
            bucketId: id,
            company: company,
            subProvider: subProvider,
            groupTitle: group,
            bucketTitle: bucketTitle,
            liveWindowSeconds: windowSeconds,
            currentUsedPercent: currentUsed,
            currentResetAt: currentResetAt,
            samples: samples
        )
    }

    // MARK: - Window filter

    func testFiveHourLanesAreExcludedAndWeeklyLanesAreKept() {
        // The cut is on the window length, never on the bucket's name: bucket
        // ids differ per provider and change without notice.
        let fiveHour = lane(
            id: "five_hour",
            bucketTitle: "5 Hours",
            windowSeconds: 5 * 3_600,
            samples: [sample(bucketId: "five_hour", endingDaysAgo: 1, used: 20, windowSeconds: 5 * 3_600)]
        )
        let weekly = lane(samples: [sample(bucketId: "weekly", endingDaysAgo: 3, used: 40)])
        let result = ResetHistoryComparison.build(inputs: [fiveHour, weekly], now: now)
        XCTAssertEqual(result.lanes.map(\.id), ["acct.weekly"])
    }

    func testAMonthlyLaneQualifies() {
        // "Weekly and up" — Cursor's 744-hour pools are the up.
        let monthly = lane(
            id: "other_models",
            bucketTitle: "Other Models",
            windowSeconds: 744 * 3_600,
            samples: [sample(bucketId: "other_models", endingDaysAgo: 10, used: 12, windowSeconds: 744 * 3_600)]
        )
        let result = ResetHistoryComparison.build(inputs: [monthly], window: .all, now: now)
        XCTAssertEqual(result.lanes.count, 1)
        XCTAssertEqual(result.lanes[0].windowSeconds, 744 * 3_600)
    }

    func testLaneWindowFallsBackToTheSamplesWhenTheLiveBucketHasNone() {
        // A bucket the live quota no longer carries still has history, and the
        // samples know how long its window was.
        let input = lane(
            windowSeconds: nil,
            samples: [
                sample(bucketId: "weekly", endingDaysAgo: 3, used: 40),
                sample(bucketId: "weekly", endingDaysAgo: 10, used: 50)
            ]
        )
        XCTAssertEqual(ResetHistoryComparison.laneWindowSeconds(input), 7 * 86_400)
        XCTAssertEqual(ResetHistoryComparison.build(inputs: [input], now: now).lanes.count, 1)
    }

    func testALaneWithNoWindowEvidenceAtAllIsDropped() {
        var input = lane(windowSeconds: nil, samples: [])
        input.samples = []
        XCTAssertNil(ResetHistoryComparison.laneWindowSeconds(input))
        XCTAssertTrue(ResetHistoryComparison.build(inputs: [input], now: now).isEmpty)
    }

    // MARK: - Picker

    func testThePickerCountsCyclesAndKeepsTheNewestOnes() {
        // Counted in cycles, not weeks: "last 4" must mean the same four
        // columns for every row, however far apart its refills fall. A cycle
        // a year old is in scope if it is one of the newest four.
        var samples: [SubscriptionWindowSample] = []
        for index in 0..<6 {
            samples.append(
                sample(bucketId: "weekly", endingDaysAgo: Double(7 * (index + 1)), used: Double(index * 10))
            )
        }
        let input = lane(samples: samples)

        let four = ResetHistoryComparison.build(inputs: [input], window: .four, now: now)
        XCTAssertEqual(four.lanes[0].cycles.count, 4)
        XCTAssertEqual(four.totals.cycleCount, 4)
        // The four newest: the oldest two (used 50 and 40) are dropped.
        XCTAssertEqual(four.lanes[0].cycles.map(\.usedPercent), [30, 20, 10, 0])

        let all = ResetHistoryComparison.build(inputs: [input], window: .all, now: now)
        XCTAssertEqual(all.lanes[0].cycles.count, 6)
    }

    func testAnAgeingCycleIsNotDroppedJustForBeingOld() {
        // The time-axis version dropped anything outside a fixed number of
        // weeks, which silently emptied a slow-refilling lane.
        let input = lane(samples: [
            sample(bucketId: "weekly", endingDaysAgo: 3, used: 90),
            sample(bucketId: "weekly", endingDaysAgo: 400, used: 10)
        ])
        let result = ResetHistoryComparison.build(inputs: [input], window: .eight, now: now)
        XCTAssertEqual(result.lanes[0].cycles.count, 2)
    }

    func testEveryWindowIsBoundedByTheColumnCeiling() {
        var samples: [SubscriptionWindowSample] = []
        for index in 0..<(ResetHistoryComparison.ColumnPlan.maximumColumns + 20) {
            samples.append(sample(bucketId: "weekly", endingDaysAgo: Double(7 * (index + 1)), used: 50))
        }
        let result = ResetHistoryComparison.build(inputs: [lane(samples: samples)], window: .all, now: now)
        XCTAssertEqual(
            result.columns.completedColumnCount,
            ResetHistoryComparison.ColumnPlan.maximumColumns
        )
    }

    // MARK: - Ordinal alignment

    func testRowsWithFewerCyclesRightAlignToTheNewestColumn() {
        // The alignment the whole redesign is for: whatever a row's newest
        // cycle is, it sits in the last completed column, so reading down a
        // column compares like with like.
        let long = lane(id: "weekly", samples: [
            sample(bucketId: "weekly", endingDaysAgo: 28, used: 10),
            sample(bucketId: "weekly", endingDaysAgo: 21, used: 20),
            sample(bucketId: "weekly", endingDaysAgo: 14, used: 30),
            sample(bucketId: "weekly", endingDaysAgo: 7, used: 40)
        ])
        let short = lane(id: "weekly_fable", group: "Fable", samples: [
            sample(bucketId: "weekly_fable", endingDaysAgo: 7, used: 90)
        ])
        let result = ResetHistoryComparison.build(inputs: [long, short], window: .all, now: now)
        let columns = result.columns
        XCTAssertEqual(columns.completedColumnCount, 4)

        // The four-cycle lane fills columns 0…3.
        XCTAssertEqual(columns.column(ofCycleAt: 0, inLaneWithCycleCount: 4), 0)
        XCTAssertEqual(columns.column(ofCycleAt: 3, inLaneWithCycleCount: 4), 3)
        // The one-cycle lane starts at column 3 — beside the other's newest,
        // not beside its oldest.
        XCTAssertEqual(columns.column(ofCycleAt: 0, inLaneWithCycleCount: 1), 3)
    }

    func testTheCurrentCycleGetsATrailingColumnOfItsOwn() {
        let live = lane(
            currentUsed: 25,
            currentResetAt: now.addingTimeInterval(3 * 86_400),
            samples: [sample(bucketId: "weekly", endingDaysAgo: 7, used: 40)]
        )
        let result = ResetHistoryComparison.build(inputs: [live], window: .all, now: now)
        XCTAssertTrue(result.columns.hasCurrentColumn)
        XCTAssertEqual(result.columns.completedColumnCount, 1)
        XCTAssertEqual(result.columns.currentColumn, 1)
        XCTAssertEqual(result.columns.totalColumnCount, 2)
        XCTAssertEqual(result.columns.axisLabel(forColumn: 1), "now")
        XCTAssertEqual(result.columns.axisLabel(forColumn: 0), "−1")
    }

    func testAGridOfOnlyRetiredLanesHasNoCurrentColumn() {
        let retired = ResetHistoryLaneInput(
            accountId: "acct",
            tool: .claude,
            bucketId: "weekly",
            company: "Anthropic",
            subProvider: "Claude",
            bucketTitle: "Weekly",
            liveWindowSeconds: nil,
            isRetired: true,
            samples: [sample(bucketId: "weekly", endingDaysAgo: 7, used: 40)]
        )
        let result = ResetHistoryComparison.build(inputs: [retired], window: .all, now: now)
        XCTAssertFalse(result.columns.hasCurrentColumn)
        XCTAssertNil(result.columns.currentColumn)
        XCTAssertEqual(result.columns.totalColumnCount, 1)
    }

    func testTheAxisCountsBackwardsFromTheNewestCycle() {
        let plan = ResetHistoryComparison.ColumnPlan(completedColumnCount: 3, hasCurrentColumn: true)
        XCTAssertEqual(plan.axisLabel(forColumn: 0), "−3")
        XCTAssertEqual(plan.axisLabel(forColumn: 2), "−1")
        XCTAssertEqual(plan.axisLabel(forColumn: 3), "now")
        XCTAssertNil(plan.axisLabel(forColumn: 4))
    }

    func testCyclesComeBackOldestFirst() {
        let input = lane(samples: [
            sample(bucketId: "weekly", endingDaysAgo: 7, used: 10),
            sample(bucketId: "weekly", endingDaysAgo: 21, used: 20),
            sample(bucketId: "weekly", endingDaysAgo: 14, used: 30)
        ])
        let result = ResetHistoryComparison.build(inputs: [input], now: now)
        XCTAssertEqual(result.lanes[0].cycles.map(\.usedPercent), [20, 30, 10])
    }

    // MARK: - Waste maths

    func testAverageWasteCoversTheLastFourCyclesOnly() {
        // Five cycles: the oldest 0%-used one must not drag the average.
        let input = lane(samples: [
            sample(bucketId: "weekly", endingDaysAgo: 35, used: 0),
            sample(bucketId: "weekly", endingDaysAgo: 28, used: 100),
            sample(bucketId: "weekly", endingDaysAgo: 21, used: 100),
            sample(bucketId: "weekly", endingDaysAgo: 14, used: 100),
            sample(bucketId: "weekly", endingDaysAgo: 7, used: 100)
        ])
        let result = ResetHistoryComparison.build(inputs: [input], window: .all, now: now)
        XCTAssertEqual(result.lanes[0].averagedCycleCount, 4)
        XCTAssertEqual(try XCTUnwrap(result.lanes[0].averageWastedPercent), 0, accuracy: 0.001)
    }

    func testWasteIsTheUnusedRemainderAtReset() {
        let input = lane(samples: [
            sample(bucketId: "weekly", endingDaysAgo: 7, used: 30),
            sample(bucketId: "weekly", endingDaysAgo: 14, used: 10)
        ])
        let result = ResetHistoryComparison.build(inputs: [input], window: .all, now: now)
        // (100-30 + 100-10) / 2 = 80
        XCTAssertEqual(try XCTUnwrap(result.lanes[0].averageWastedPercent), 80, accuracy: 0.001)
        XCTAssertEqual(result.lanes[0].wasteSummary, "avg wasted 80% · last 2 cycles")
    }

    func testTheDrawnValueIsWhatWasLeftAtReset() {
        // The bar height is the waste, not the spend: the module answers "am I
        // wasting quota", so a cycle spent to the last percent must draw as an
        // empty slot and one that expired untouched as a full bar.
        let input = lane(
            currentUsed: 10,
            currentResetAt: now.addingTimeInterval(2 * 86_400),
            samples: [
                sample(bucketId: "weekly", endingDaysAgo: 14, used: 100),
                sample(bucketId: "weekly", endingDaysAgo: 7, used: 0)
            ]
        )
        let result = ResetHistoryComparison.build(inputs: [input], window: .all, now: now)
        XCTAssertEqual(result.lanes[0].cycles.map(\.wastedPercent), [0, 100])
        // And for the cycle still running, the same arithmetic is "left now".
        XCTAssertEqual(result.lanes[0].currentCycle?.wastedPercent, 90)
    }

    func testALaneWithNoCompletedCyclesHasNoAverageAndSaysSo() {
        let input = lane(currentUsed: 42, currentResetAt: now.addingTimeInterval(3 * 86_400), samples: [])
        let result = ResetHistoryComparison.build(inputs: [input], now: now)
        XCTAssertNil(result.lanes[0].averageWastedPercent)
        XCTAssertEqual(result.lanes[0].wasteSummary, "No completed cycles yet")
        XCTAssertEqual(
            result.lanes[0].emptyStateText,
            "No completed cycles yet — a cycle is recorded when the quota refills"
        )
    }

    func testTotalsAreTheShareOfRefilledCapacityThatWasSpent() {
        let a = lane(id: "weekly", samples: [
            sample(bucketId: "weekly", endingDaysAgo: 7, used: 100),
            sample(bucketId: "weekly", endingDaysAgo: 14, used: 60)
        ])
        let b = lane(id: "weekly_fable", group: "Fable", samples: [
            sample(bucketId: "weekly_fable", endingDaysAgo: 7, used: 20),
            sample(bucketId: "weekly_fable", endingDaysAgo: 14, used: 20)
        ])
        let result = ResetHistoryComparison.build(inputs: [a, b], window: .all, now: now)
        XCTAssertEqual(result.totals.cycleCount, 4)
        XCTAssertEqual(result.totals.usedPercent, 50, accuracy: 0.001)
        XCTAssertEqual(result.totals.wastedPercent, 50, accuracy: 0.001)
        XCTAssertEqual(result.totals.headline, "50% used · 50% wasted · 4 cycles")
    }

    // MARK: - Current cycle

    func testTheOpenSampleBecomesTheCurrentCycle() {
        let input = lane(samples: [
            sample(bucketId: "weekly", endingDaysAgo: 7, used: 80),
            sample(bucketId: "weekly", endingDaysAgo: -2, used: 25, completed: false)
        ])
        let result = ResetHistoryComparison.build(inputs: [input], now: now)
        let current = try? XCTUnwrap(result.lanes[0].currentCycle)
        XCTAssertEqual(current?.usedPercent, 25)
        XCTAssertEqual(current?.isCompleted, false)
        XCTAssertEqual(result.lanes[0].cycles.count, 1)
    }

    func testTheLiveQuotaSuppliesTheCurrentCycleWhenTheHistoryHasNoOpenSample() {
        let resetAt = now.addingTimeInterval(4 * 86_400)
        let input = lane(
            currentUsed: 66,
            currentResetAt: resetAt,
            samples: [sample(bucketId: "weekly", endingDaysAgo: 3, used: 80)]
        )
        let result = ResetHistoryComparison.build(inputs: [input], now: now)
        let current = try? XCTUnwrap(result.lanes[0].currentCycle)
        XCTAssertEqual(current?.usedPercent, 66)
        XCTAssertEqual(current?.end, resetAt)
        XCTAssertEqual(current?.start, resetAt.addingTimeInterval(-week))
    }

    // MARK: - Reset kind

    func testEarlyRefillsSurviveOntoTheCycle() {
        let input = lane(samples: [
            sample(bucketId: "weekly", endingDaysAgo: 7, used: 40, resetKind: .earlyClockRestarted),
            sample(bucketId: "weekly", endingDaysAgo: 14, used: 40, resetKind: .onSchedule)
        ])
        let result = ResetHistoryComparison.build(inputs: [input], window: .all, now: now)
        XCTAssertEqual(result.lanes[0].cycles.map(\.refilledEarly), [false, true])
        XCTAssertEqual(result.lanes[0].cycles[1].resetDescription, "refilled early, next window restarted")
        XCTAssertEqual(result.lanes[0].cycles[0].resetDescription, "")
    }

    // MARK: - History-only lanes

    func testALaneWithNoLiveBucketStillComparesItsRecordedCycles() {
        // A bucket the provider renamed or withdrew keeps its samples in the
        // history, and its waste record is exactly the one the user would
        // otherwise never see again. No live window, no live percent, no
        // reset time — only what was recorded.
        let retired = ResetHistoryLaneInput(
            accountId: "acct",
            tool: .claude,
            bucketId: "weekly_opus",
            company: "Anthropic",
            subProvider: "Claude",
            groupTitle: nil,
            bucketTitle: "Opus · Weekly",
            liveWindowSeconds: nil,
            currentUsedPercent: nil,
            currentResetAt: nil,
            isRetired: true,
            samples: [
                sample(bucketId: "weekly_opus", endingDaysAgo: 7, used: 20),
                sample(bucketId: "weekly_opus", endingDaysAgo: 14, used: 30)
            ]
        )
        let live = lane(samples: [sample(bucketId: "weekly", endingDaysAgo: 7, used: 95)])
        let result = ResetHistoryComparison.build(inputs: [retired, live], window: .all, now: now)

        XCTAssertEqual(result.lanes.map(\.id), ["acct.weekly_opus", "acct.weekly"])
        let lane = result.lanes[0]
        XCTAssertEqual(lane.cycles.count, 2)
        XCTAssertEqual(lane.windowSeconds, 7 * 86_400)
        XCTAssertEqual(lane.label, "Anthropic · Claude · Opus · Weekly")
        // Nothing is running, so there is no dashed bar to draw.
        XCTAssertNil(lane.currentCycle)
        XCTAssertEqual(try XCTUnwrap(lane.averageWastedPercent), 75, accuracy: 0.001)
    }

    func testARetiredLaneNeverShowsACurrentCycleFromItsStaleOpenSample() {
        // A cycle closes only when another observation arrives, so a bucket
        // the provider withdrew — or one whose account was signed out of —
        // keeps its last open sample forever. Reading that as the present
        // tense would draw a dashed "Current" bar for a quota that stopped
        // existing months ago.
        let retired = ResetHistoryLaneInput(
            accountId: "acct",
            tool: .claude,
            bucketId: "weekly_opus",
            company: "Anthropic",
            subProvider: "Claude",
            bucketTitle: "Opus · Weekly",
            liveWindowSeconds: nil,
            isRetired: true,
            samples: [
                sample(bucketId: "weekly_opus", endingDaysAgo: 14, used: 30),
                // Never closed: nothing observed this bucket again.
                sample(bucketId: "weekly_opus", endingDaysAgo: 7, used: 45, completed: false)
            ]
        )
        let result = ResetHistoryComparison.build(inputs: [retired], window: .all, now: now)
        XCTAssertEqual(result.lanes.count, 1)
        XCTAssertNil(result.lanes[0].currentCycle)
        // The open sample is not a completed cycle either, so it contributes
        // nothing to the waste arithmetic.
        XCTAssertEqual(result.lanes[0].cycles.count, 1)
        XCTAssertEqual(result.totals.cycleCount, 1)
    }

    func testARetiredLaneIgnoresLiveQuotaFieldsEvenIfTheyAreSupplied() {
        // Belt and braces: the flag, not the nil-ness of the live fields, is
        // what decides whether a lane has a present tense.
        let retired = ResetHistoryLaneInput(
            accountId: "acct",
            tool: .claude,
            bucketId: "weekly",
            company: "Anthropic",
            subProvider: "Claude",
            bucketTitle: "Weekly",
            liveWindowSeconds: 7 * 86_400,
            currentUsedPercent: 40,
            currentResetAt: now.addingTimeInterval(2 * 86_400),
            isRetired: true,
            samples: [sample(bucketId: "weekly", endingDaysAgo: 7, used: 30)]
        )
        XCTAssertNil(
            ResetHistoryComparison.build(inputs: [retired], window: .all, now: now).lanes[0].currentCycle
        )
    }

    func testALiveLaneStillTakesItsCurrentCycleFromAnOpenSample() {
        // The guard must not cost a live lane its dashed bar.
        let live = lane(samples: [
            sample(bucketId: "weekly", endingDaysAgo: 7, used: 80),
            sample(bucketId: "weekly", endingDaysAgo: -2, used: 25, completed: false)
        ])
        let result = ResetHistoryComparison.build(inputs: [live], window: .all, now: now)
        XCTAssertEqual(result.lanes[0].currentCycle?.usedPercent, 25)
    }

    func testASignedOutAccountsLanesCompareAlongsideTheLiveOnes() {
        // The discovery path that produces these lives in the app target, so
        // what is pinned here is the contract it relies on: a lane whose
        // account no longer exists is an ordinary retired lane, sorts by its
        // own waste, and carries the label that says whose it was.
        let signedOut = ResetHistoryLaneInput(
            accountId: "former",
            tool: .claude,
            bucketId: "weekly",
            company: "Anthropic",
            subProvider: "Claude",
            bucketTitle: "Weekly",
            accountLabel: "Signed-out account",
            liveWindowSeconds: nil,
            isRetired: true,
            samples: [
                sample(bucketId: "weekly", endingDaysAgo: 14, used: 5),
                sample(bucketId: "weekly", endingDaysAgo: 21, used: 5)
            ]
        )
        let live = lane(samples: [sample(bucketId: "weekly", endingDaysAgo: 7, used: 92)])
        let result = ResetHistoryComparison.build(inputs: [live, signedOut], window: .all, now: now)

        // Hierarchy order, not waste order: both are Anthropic / Claude, so
        // they keep the order they were discovered in.
        XCTAssertEqual(result.lanes.map(\.id), ["acct.weekly", "former.weekly"])
        XCTAssertEqual(result.lanes[1].label, "Anthropic · Claude · Weekly · Signed-out account")
        XCTAssertEqual(result.lanes[1].cycles.count, 2)
        XCTAssertNil(result.lanes[1].currentCycle)
        // Both accounts' cycles count toward the header arithmetic; hiding the
        // signed-out one is what made the totals disagree with the Workbench
        // reset calendar, which reads the same history directly.
        XCTAssertEqual(result.totals.cycleCount, 3)
    }

    func testAHistoryOnlyFiveHourLaneIsStillExcluded() {
        // Losing the live bucket must not smuggle a sub-daily lane in through
        // the sample fallback.
        let retired = ResetHistoryLaneInput(
            accountId: "acct",
            tool: .claude,
            bucketId: "five_hour_legacy",
            company: "Anthropic",
            subProvider: "Claude",
            bucketTitle: "5 Hours",
            liveWindowSeconds: nil,
            isRetired: true,
            samples: [
                sample(bucketId: "five_hour_legacy", endingDaysAgo: 1, used: 20, windowSeconds: 5 * 3_600)
            ]
        )
        XCTAssertTrue(ResetHistoryComparison.build(inputs: [retired], window: .all, now: now).isEmpty)
    }

    // MARK: - Ordering

    func testRowsAreOrderedByCompanyThenSubProviderThenDiscoveryOrder() {
        // Hierarchy, not a sorted list. Discovery order is the app's canonical
        // provider order and, inside a provider, the order the popover lists
        // the buckets in — alphabetical would reshuffle the table whenever a
        // vendor renamed itself, and a waste sort mixed the companies up.
        let codexWeekly = lane(
            id: "codex_weekly", tool: .codex, company: "OpenAI", subProvider: "ChatGPT Agentic",
            samples: [sample(bucketId: "codex_weekly", endingDaysAgo: 7, used: 90)]
        )
        let codexSpark = lane(
            id: "spark_weekly", tool: .codex, company: "OpenAI", subProvider: "ChatGPT Agentic",
            group: "Codex Spark",
            samples: [sample(bucketId: "spark_weekly", endingDaysAgo: 7, used: 5)]
        )
        let geminiWeb = lane(
            id: "gemini_weekly", tool: .gemini, company: "Google AI", subProvider: "Gemini Web",
            samples: [sample(bucketId: "gemini_weekly", endingDaysAgo: 7, used: 50)]
        )
        let antigravity = lane(
            id: "claude_gpt_weekly", tool: .antigravity, company: "Google AI",
            subProvider: "AntiGravity", group: "Claude & GPT Models",
            samples: [sample(bucketId: "claude_gpt_weekly", endingDaysAgo: 7, used: 1)]
        )
        let claude = lane(samples: [sample(bucketId: "weekly", endingDaysAgo: 7, used: 99)])

        let result = ResetHistoryComparison.build(
            inputs: [codexWeekly, codexSpark, claude, geminiWeb, antigravity],
            window: .all,
            now: now
        )
        XCTAssertEqual(
            result.lanes.map(\.id),
            [
                "acct.codex_weekly",    // OpenAI, first discovered
                "acct.spark_weekly",    // …its second bucket, in popover order
                "acct.weekly",          // Anthropic
                "acct.gemini_weekly",   // Google AI, Gemini Web first
                "acct.claude_gpt_weekly" // …then AntiGravity
            ]
        )
        // Waste plays no part: the 1%-used AntiGravity lane is last, and the
        // 99%-used Claude lane sits in the middle where its company puts it.
        XCTAssertEqual(result.lanes.last?.subProvider, "AntiGravity")
    }

    func testALaneWithNoCompletedCyclesKeepsItsPlaceInTheHierarchy() {
        // It has no waste figure to sort by, but it is still that company's
        // quota and belongs under that company's heading.
        let empty = lane(id: "gpt_reserve_weekly", group: "Reserve", samples: [])
        let busy = lane(id: "weekly", samples: [sample(bucketId: "weekly", endingDaysAgo: 7, used: 20)])
        let result = ResetHistoryComparison.build(inputs: [empty, busy], now: now)
        XCTAssertEqual(result.lanes.map(\.id), ["acct.gpt_reserve_weekly", "acct.weekly"])
        XCTAssertNil(result.lanes[0].averageWastedPercent)
    }

    func testEachCompanyIsContiguousSoOneHeadingCoversIt() {
        // The drawing surface emits one heading per run of a company, so a
        // company appearing in two runs would render two headings for it.
        let openAI = lane(
            id: "codex_weekly", tool: .codex, company: "OpenAI", subProvider: "ChatGPT Agentic",
            samples: [sample(bucketId: "codex_weekly", endingDaysAgo: 7, used: 90)]
        )
        let anthropicLeaky = lane(
            id: "weekly_fable", group: "Fable",
            samples: [sample(bucketId: "weekly_fable", endingDaysAgo: 7, used: 2)]
        )
        let anthropicTight = lane(
            id: "weekly",
            samples: [sample(bucketId: "weekly", endingDaysAgo: 7, used: 99)]
        )
        // Interleaved on the way in, so only the ordering can group them.
        let result = ResetHistoryComparison.build(
            inputs: [openAI, anthropicLeaky, openAI, anthropicTight],
            now: now
        )
        var runs: [String] = []
        for lane in result.lanes where runs.last != lane.company {
            runs.append(lane.company)
        }
        XCTAssertEqual(runs, ["OpenAI", "Anthropic"])
        XCTAssertEqual(Set(runs).count, runs.count)
    }

    // MARK: - Labels

    func testLabelsUseTheQuotaNamingAxis() {
        let input = lane(
            id: "weekly_fable", company: "Anthropic", subProvider: "Claude",
            group: "Fable", bucketTitle: "Weekly",
            samples: [sample(bucketId: "weekly_fable", endingDaysAgo: 7, used: 10)]
        )
        let lane = ResetHistoryComparison.build(inputs: [input], now: now).lanes[0]
        XCTAssertEqual(lane.label, "Anthropic · Claude · Fable · Weekly")
        XCTAssertEqual(lane.labelWithoutCompany, "Claude · Fable · Weekly")
    }

    func testABucketTitleEqualToItsGroupIsNotRepeated() {
        let input = lane(
            id: "grok_bot_weekly", company: "SpaceXAI", subProvider: "Grok Bot",
            group: "Weekly", bucketTitle: "Weekly",
            samples: [sample(bucketId: "grok_bot_weekly", endingDaysAgo: 7, used: 10)]
        )
        XCTAssertEqual(
            ResetHistoryComparison.build(inputs: [input], now: now).lanes[0].label,
            "SpaceXAI · Grok Bot · Weekly"
        )
    }

    // MARK: - Verdict

    func testVerdictNamesTheLaneThatKeepsRefillingMoreThanHalfUnused() {
        let leaky = lane(id: "weekly", samples: [
            sample(bucketId: "weekly", endingDaysAgo: 7, used: 10),
            sample(bucketId: "weekly", endingDaysAgo: 14, used: 20),
            sample(bucketId: "weekly", endingDaysAgo: 21, used: 30)
        ])
        let result = ResetHistoryComparison.build(inputs: [leaky], window: .all, now: now)
        XCTAssertEqual(
            result.verdict,
            "Anthropic · Claude · Weekly refilled 3 times with more than half unused."
        )
    }

    func testASingleWastefulCycleIsCalledOutInTheSingular() {
        let input = lane(samples: [
            sample(bucketId: "weekly", endingDaysAgo: 7, used: 10),
            sample(bucketId: "weekly", endingDaysAgo: 14, used: 95)
        ])
        let result = ResetHistoryComparison.build(inputs: [input], window: .all, now: now)
        XCTAssertEqual(
            result.verdict,
            "Anthropic · Claude · Weekly refilled once with more than half unused."
        )
    }

    func testANotableAverageIsQuotedWhenNoSingleCycleCrossesHalf() {
        // 60% used every cycle: never more than half unused, but 40% average
        // waste is still worth a sentence.
        let input = lane(samples: [
            sample(bucketId: "weekly", endingDaysAgo: 7, used: 60),
            sample(bucketId: "weekly", endingDaysAgo: 14, used: 60)
        ])
        let result = ResetHistoryComparison.build(inputs: [input], window: .all, now: now)
        XCTAssertEqual(
            result.verdict,
            "Anthropic · Claude · Weekly left 40% unused on average across 2 cycles."
        )
    }

    func testAHealthySetOfLanesGetsTheNumberRatherThanAPlatitude() {
        let input = lane(samples: [
            sample(bucketId: "weekly", endingDaysAgo: 7, used: 90),
            sample(bucketId: "weekly", endingDaysAgo: 14, used: 90)
        ])
        let result = ResetHistoryComparison.build(inputs: [input], window: .all, now: now)
        XCTAssertEqual(
            result.verdict,
            "Nothing is going noticeably to waste — 90% of the refilled capacity was spent."
        )
    }

    func testVerdictWhenThereIsNothingToCompare() {
        XCTAssertEqual(
            ResetHistoryComparison.build(inputs: [], now: now).verdict,
            "No weekly or longer quota is being tracked yet."
        )
    }

    func testVerdictWhenLanesExistButNothingHasCompleted() {
        let input = lane(currentUsed: 10, currentResetAt: now.addingTimeInterval(86_400), samples: [])
        XCTAssertEqual(
            ResetHistoryComparison.build(inputs: [input], now: now).verdict,
            "No completed cycles yet — a cycle is recorded when a quota refills."
        )
    }

    // MARK: - Caching contract

    func testTheBuildClockIsCarriedSoTheViewNeedNotReadItWhileDrawing() {
        let input = lane(samples: [sample(bucketId: "weekly", endingDaysAgo: 7, used: 40)])
        let result = ResetHistoryComparison.build(inputs: [input], now: now)
        XCTAssertEqual(result.now, now)
    }

    func testEqualInputsProduceEqualComparisons() {
        // The App caches on the inputs; if two identical builds compared
        // unequal the cache would rebuild on every render.
        let input = lane(samples: [sample(bucketId: "weekly", endingDaysAgo: 7, used: 40)])
        XCTAssertEqual(
            ResetHistoryComparison.build(inputs: [input], now: now),
            ResetHistoryComparison.build(inputs: [input], now: now)
        )
    }

    // MARK: - Accessibility

    func testAccessibilitySummaryNamesTheLanesAndTheHeadline() {
        let input = lane(samples: [sample(bucketId: "weekly", endingDaysAgo: 7, used: 40)])
        let summary = ResetHistoryComparison.build(inputs: [input], now: now).accessibilitySummary
        XCTAssertTrue(summary.contains("Anthropic · Claude · Weekly"))
        XCTAssertTrue(summary.contains("60% wasted on average"))
        XCTAssertTrue(summary.contains("last 8 cycles"))
        XCTAssertTrue(summary.contains("remaining"))
    }
}
