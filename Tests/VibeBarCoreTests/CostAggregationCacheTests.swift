import XCTest
@testable import VibeBarCore

/// The popover reads these derived values dozens of times per render pass, so
/// the cache has to be both correct (same answers as recomputing) and actually
/// caching (a changed source that was never announced must NOT be picked up —
/// that is what proves the memo, and why every write path has to call
/// `setSource`).
final class CostAggregationCacheTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth, hour: hour))!
    }

    private func snapshot(
        tool: ToolType,
        history: [(Date, Double, Int)],
        jsonlFilesFound: Int = 3,
        updatedAt: Date
    ) -> CostSnapshot {
        CostSnapshot(
            tool: tool,
            todayCostUSD: 0,
            last7DaysCostUSD: 0,
            last30DaysCostUSD: 0,
            allTimeCostUSD: 0,
            todayTokens: 0,
            last7DaysTokens: 0,
            last30DaysTokens: 0,
            allTimeTokens: 0,
            dailyHistory: history.map {
                DailyCostPoint(date: $0.0, costUSD: $0.1, totalTokens: $0.2)
            },
            heatmap: UsageHeatmap(
                tool: tool,
                cells: Array(repeating: Array(repeating: 1, count: 24), count: 7),
                totalTokens: 168
            ),
            modelBreakdowns: [
                CostSnapshot.ModelBreakdown(modelName: "model-a", costUSD: 1, totalTokens: 10)
            ],
            jsonlFilesFound: jsonlFilesFound,
            updatedAt: updatedAt
        )
    }

    func testRebasedSnapshotMatchesDirectComputationAndIsMemoized() throws {
        let now = day(2026, 7, 30)
        let source = snapshot(
            tool: .codex,
            history: [
                (day(2026, 7, 30, hour: 9), 2, 200),
                (day(2026, 7, 29, hour: 9), 3, 300),
                (day(2026, 6, 1, hour: 9), 40, 4_000)
            ],
            updatedAt: now
        )
        let cache = CostAggregationCache(calendar: calendar)
        cache.setSource([.codex: source])

        let expected = source.rebasedForCurrentDay(now: now, calendar: calendar)
        XCTAssertEqual(cache.snapshot(for: .codex, now: now), expected)

        // A source swapped in behind the cache's back is deliberately not
        // visible: that is the memo doing its job.
        let replaced = snapshot(tool: .codex, history: [(day(2026, 7, 30, hour: 9), 99, 9)], updatedAt: now)
        cache.setSourceWithoutInvalidatingForTesting([.codex: replaced])
        XCTAssertEqual(cache.snapshot(for: .codex, now: now)?.todayCostUSD, expected.todayCostUSD)

        // Announced, it is.
        cache.setSource([.codex: replaced])
        XCTAssertEqual(
            try XCTUnwrap(cache.snapshot(for: .codex, now: now)).todayCostUSD,
            99,
            accuracy: 0.0001
        )
    }

    func testDayRolloverDropsEveryMemo() throws {
        let today = day(2026, 7, 30)
        let source = snapshot(
            tool: .codex,
            history: [
                (day(2026, 7, 30, hour: 9), 2, 200),
                (day(2026, 7, 31, hour: 9), 5, 500)
            ],
            updatedAt: today
        )
        let cache = CostAggregationCache(calendar: calendar)
        cache.setSource([.codex: source])

        // Tomorrow's point is in the future today, so it is excluded — and
        // included once the day rolls over. Same object, no `setSource`.
        XCTAssertEqual(
            try XCTUnwrap(cache.snapshot(for: .codex, now: today)).allTimeCostUSD,
            2,
            accuracy: 0.0001
        )
        let tomorrow = day(2026, 7, 31)
        XCTAssertEqual(
            try XCTUnwrap(cache.snapshot(for: .codex, now: tomorrow)).allTimeCostUSD,
            7,
            accuracy: 0.0001
        )
    }

    func testCombinedSnapshotMatchesAggregatorAndSharesTheMemoWithRollupGroups() {
        let now = day(2026, 7, 30)
        let gemini = snapshot(tool: .gemini, history: [(day(2026, 7, 30, hour: 8), 1, 100)], updatedAt: now)
        let antigravity = snapshot(
            tool: .antigravity,
            history: [(day(2026, 7, 30, hour: 8), 4, 400)],
            updatedAt: now
        )
        let cache = CostAggregationCache(calendar: calendar)
        cache.setSource([.gemini: gemini, .antigravity: antigravity])

        let expected = CostSnapshotAggregator.combinedSnapshot(
            tool: .antigravity,
            snapshots: [gemini, antigravity],
            now: now,
            calendar: calendar
        )
        let combined = cache.combinedSnapshot(of: [.gemini, .antigravity], labelledAs: .antigravity, now: now)
        XCTAssertEqual(combined, expected)

        let rollup = cache.rollup(
            individualTools: [],
            groups: [CostSnapshotGroup(label: .antigravity, tools: [.gemini, .antigravity])],
            labelledAs: .codex,
            now: now
        )
        XCTAssertEqual(rollup.groupSnapshots.first, combined)
        XCTAssertEqual(rollup.snapshots.count, 1)
        XCTAssertTrue(rollup.hasCostData)
    }

    func testRollupMatchesAggregatorAndDropsEmptyGroups() {
        let now = day(2026, 7, 30)
        let codex = snapshot(tool: .codex, history: [(day(2026, 7, 29, hour: 8), 2, 200)], updatedAt: now)
        let emptyGemini = snapshot(
            tool: .gemini,
            history: [],
            jsonlFilesFound: 0,
            updatedAt: now
        )
        let cache = CostAggregationCache(calendar: calendar)
        cache.setSource([.codex: codex, .gemini: emptyGemini])

        let rollup = cache.rollup(
            individualTools: [.codex],
            groups: [CostSnapshotGroup(label: .antigravity, tools: [.gemini, .antigravity])],
            labelledAs: .codex,
            now: now
        )
        // A group with no session logs contributes nothing to the aggregate —
        // otherwise a zero-filled snapshot would claim the Overview has data.
        XCTAssertEqual(rollup.snapshots.count, 1)
        XCTAssertEqual(rollup.groupSnapshots.count, 1)
        XCTAssertEqual(rollup.groupSnapshots.first?.jsonlFilesFound, 0)

        let rebased = codex.rebasedForCurrentDay(now: now, calendar: calendar)
        XCTAssertEqual(
            rollup.dailyHistory,
            CostSnapshotAggregator.combinedDailyHistory([rebased], calendar: calendar)
        )
        XCTAssertEqual(rollup.heatmap, CostSnapshotAggregator.combinedHeatmap([rebased]))
        XCTAssertEqual(
            rollup.modelBreakdowns,
            CostSnapshotAggregator.combinedModelBreakdowns([rebased])
        )
        XCTAssertEqual(
            rollup.combinedSnapshot,
            CostSnapshotAggregator.combinedSnapshot(
                tool: .codex,
                snapshots: [rebased],
                now: now,
                calendar: calendar
            )
        )
    }

    func testHasJSONLFilesReadsRawCountsWithoutRebasing() {
        let now = day(2026, 7, 30)
        let cache = CostAggregationCache(calendar: calendar)
        cache.setSource([
            .codex: snapshot(tool: .codex, history: [], jsonlFilesFound: 0, updatedAt: now),
            .gemini: snapshot(tool: .gemini, history: [], jsonlFilesFound: 2, updatedAt: now)
        ])

        XCTAssertFalse(cache.hasJSONLFiles(in: [.codex]))
        XCTAssertFalse(cache.hasJSONLFiles(in: [.claude]))
        XCTAssertTrue(cache.hasJSONLFiles(in: [.codex, .gemini]))
        // The Overview's real question: a Gemini snapshot with logs but no
        // history still counts, which is what keeps the cost cards on screen
        // while the daily history is empty.
        XCTAssertTrue(cache.hasJSONLFiles(in: [.gemini, .antigravity]))
    }

    func testTotalsMatchPerProviderSumsIncludingYesterdayAndPeaks() {
        let now = day(2026, 7, 30)
        let codex = snapshot(
            tool: .codex,
            history: [
                (day(2026, 7, 30, hour: 8), 2, 200),
                (day(2026, 7, 29, hour: 8), 7, 700)
            ],
            updatedAt: now
        )
        let claude = snapshot(
            tool: .claude,
            history: [
                (day(2026, 7, 30, hour: 8), 3, 300),
                (day(2026, 7, 29, hour: 8), 1, 100)
            ],
            updatedAt: now
        )
        let cache = CostAggregationCache(calendar: calendar)
        cache.setSource([.codex: codex, .claude: claude])

        let totals = cache.totals(of: [.codex, .claude], now: now)
        XCTAssertEqual(totals.todayCostUSD, 5, accuracy: 0.0001)
        XCTAssertEqual(totals.yesterdayCostUSD, 8, accuracy: 0.0001)
        XCTAssertEqual(totals.allTimeCostUSD, 13, accuracy: 0.0001)
        XCTAssertEqual(totals.todayTokens, 500)
        XCTAssertEqual(totals.yesterdayTokens, 800)
        XCTAssertEqual(totals.allTimeTokens, 1_300)
        // Peaks are over the *combined* day, so yesterday's 7 + 1 outranks
        // today's 2 + 3.
        XCTAssertEqual(totals.peakDayCostUSD, 8, accuracy: 0.0001)
        XCTAssertEqual(totals.peakDayTokens, 800)
    }

    func testTotalsAreKeyedByProviderSetSoHidingOneChangesTheAnswer() {
        let now = day(2026, 7, 30)
        let cache = CostAggregationCache(calendar: calendar)
        cache.setSource([
            .codex: snapshot(tool: .codex, history: [(day(2026, 7, 30, hour: 8), 2, 200)], updatedAt: now),
            .claude: snapshot(tool: .claude, history: [(day(2026, 7, 30, hour: 8), 3, 300)], updatedAt: now)
        ])

        XCTAssertEqual(cache.totals(of: [.codex, .claude], now: now).todayCostUSD, 5, accuracy: 0.0001)
        XCTAssertEqual(cache.totals(of: [.codex], now: now).todayCostUSD, 2, accuracy: 0.0001)
    }
}
