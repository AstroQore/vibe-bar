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

    // MARK: - Visible span

    func testTheFixedWindowDropsCyclesOlderThanIt() {
        let input = lane(samples: [
            sample(bucketId: "weekly", endingDaysAgo: 3, used: 90),
            sample(bucketId: "weekly", endingDaysAgo: 40, used: 10)
        ])
        let fourWeeks = ResetHistoryComparison.build(inputs: [input], window: .fourWeeks, now: now)
        XCTAssertEqual(fourWeeks.lanes[0].cycles.count, 1)
        XCTAssertEqual(fourWeeks.totals.cycleCount, 1)

        let all = ResetHistoryComparison.build(inputs: [input], window: .all, now: now)
        XCTAssertEqual(all.lanes[0].cycles.count, 2)
        XCTAssertLessThanOrEqual(all.rangeStart, now.addingTimeInterval(-40 * 86_400))
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
            samples: [
                sample(bucketId: "five_hour_legacy", endingDaysAgo: 1, used: 20, windowSeconds: 5 * 3_600)
            ]
        )
        XCTAssertTrue(ResetHistoryComparison.build(inputs: [retired], window: .all, now: now).isEmpty)
    }

    // MARK: - Ordering

    func testLanesSortByAverageWasteDescendingAndEmptyLanesSinkToTheBottom() {
        let leaky = lane(id: "weekly_fable", group: "Fable", samples: [
            sample(bucketId: "weekly_fable", endingDaysAgo: 7, used: 10)
        ])
        let tight = lane(id: "weekly", samples: [
            sample(bucketId: "weekly", endingDaysAgo: 7, used: 95)
        ])
        let unknown = lane(id: "gpt_reserve_weekly", group: "Reserve", samples: [])
        let result = ResetHistoryComparison.build(inputs: [tight, unknown, leaky], now: now)
        XCTAssertEqual(
            result.lanes.map(\.id),
            ["acct.weekly_fable", "acct.weekly", "acct.gpt_reserve_weekly"]
        )
    }

    func testCompanyOrderingKeepsDiscoveryOrderAndSortsByWasteInside() {
        // Discovery order is the app's canonical provider order; alphabetical
        // would reshuffle the page whenever a vendor renames itself.
        let openAITight = lane(
            id: "codex_weekly", tool: .codex, company: "OpenAI", subProvider: "ChatGPT Agentic",
            samples: [sample(bucketId: "codex_weekly", endingDaysAgo: 7, used: 90)]
        )
        let openAILeaky = lane(
            id: "spark_weekly", tool: .codex, company: "OpenAI", subProvider: "ChatGPT Agentic",
            group: "Codex Spark",
            samples: [sample(bucketId: "spark_weekly", endingDaysAgo: 7, used: 5)]
        )
        let anthropic = lane(samples: [sample(bucketId: "weekly", endingDaysAgo: 7, used: 1)])
        let result = ResetHistoryComparison.build(
            inputs: [openAITight, openAILeaky, anthropic],
            ordering: .company,
            now: now
        )
        XCTAssertEqual(
            result.lanes.map(\.id),
            ["acct.spark_weekly", "acct.codex_weekly", "acct.weekly"]
        )
        // …and by pure waste, Anthropic's 1%-used lane would have led.
        let byWaste = ResetHistoryComparison.build(
            inputs: [openAITight, openAILeaky, anthropic],
            ordering: .waste,
            now: now
        )
        XCTAssertEqual(byWaste.lanes.first?.id, "acct.weekly")
    }

    func testCompanyOrderingKeepsEachCompanyContiguous() {
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
        let result = ResetHistoryComparison.build(
            inputs: [openAI, anthropicLeaky, anthropicTight],
            ordering: .company,
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

    // MARK: - Draw budget

    private func cycle(index: Int, used: Double) -> ResetHistoryComparison.Cycle {
        let start: Date = now.addingTimeInterval(Double(index) * week)
        let end: Date = start.addingTimeInterval(week)
        return ResetHistoryComparison.Cycle(
            id: "c\(index)",
            start: start,
            end: end,
            usedPercent: used,
            isCompleted: true
        )
    }

    func testDownsamplingKeepsEndpointsAndTheWorstCyclesInTimeOrder() {
        var cycles: [ResetHistoryComparison.Cycle] = []
        for index in 0..<10 {
            cycles.append(cycle(index: index, used: index == 5 ? 1 : 90))
        }
        let kept = ResetHistoryComparison.downsampled(cycles, limit: 3)
        XCTAssertEqual(kept.map(\.id), ["c0", "c5", "c9"])
    }

    func testDownsamplingLeavesAShortLaneAlone() {
        var cycles: [ResetHistoryComparison.Cycle] = []
        for index in 0..<3 {
            cycles.append(cycle(index: index, used: 50))
        }
        XCTAssertEqual(ResetHistoryComparison.downsampled(cycles, limit: 10).count, 3)
        XCTAssertTrue(ResetHistoryComparison.downsampled(cycles, limit: 0).isEmpty)
    }

    // MARK: - Caching contract

    func testTheBuildClockIsCarriedSoTheViewNeedNotReadItWhileDrawing() {
        let input = lane(samples: [sample(bucketId: "weekly", endingDaysAgo: 7, used: 40)])
        let result = ResetHistoryComparison.build(inputs: [input], now: now)
        XCTAssertEqual(result.now, now)
        XCTAssertGreaterThanOrEqual(result.rangeEnd, result.now)
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
        XCTAssertTrue(summary.contains("last 8 weeks"))
    }
}
