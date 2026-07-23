import XCTest
@testable import VibeBarCore

final class CostSnapshotAggregatorTests: XCTestCase {
    private func calendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    private func makeSnapshot(
        tool: ToolType,
        days: [(Date, Double, Int)],
        hours: [(Date, Double, Int)] = [],
        heatmap: [[Int]],
        models: [(String, Double, Int)],
        last7Models: [(String, Double, Int)] = [],
        dailyModels: [Date: [(String, Double, Int)]] = [:],
        updatedAt: Date = Date(timeIntervalSince1970: 0)
    ) -> CostSnapshot {
        CostSnapshot(
            tool: tool,
            todayCostUSD: hours.reduce(0) { $0 + $1.1 },
            last7DaysCostUSD: days.reduce(0) { $0 + $1.1 },
            last30DaysCostUSD: days.reduce(0) { $0 + $1.1 },
            allTimeCostUSD: days.reduce(0) { $0 + $1.1 },
            todayTokens: hours.reduce(0) { $0 + $1.2 },
            last7DaysTokens: days.reduce(0) { $0 + $1.2 },
            last30DaysTokens: days.reduce(0) { $0 + $1.2 },
            allTimeTokens: days.reduce(0) { $0 + $1.2 },
            dailyHistory: days.map { DailyCostPoint(date: $0.0, costUSD: $0.1, totalTokens: $0.2) },
            todayHourlyHistory: hours.map { HourlyCostPoint(date: $0.0, costUSD: $0.1, totalTokens: $0.2) },
            heatmap: UsageHeatmap(tool: tool, cells: heatmap, totalTokens: heatmap.flatMap { $0 }.reduce(0, +)),
            modelBreakdowns: models.map { CostSnapshot.ModelBreakdown(modelName: $0.0, costUSD: $0.1, totalTokens: $0.2) },
            last7DaysModelBreakdowns: last7Models.map { CostSnapshot.ModelBreakdown(modelName: $0.0, costUSD: $0.1, totalTokens: $0.2) },
            dailyModelBreakdown: dailyModels.mapValues { values in
                values.map { CostSnapshot.ModelBreakdown(modelName: $0.0, costUSD: $0.1, totalTokens: $0.2) }
            },
            jsonlFilesFound: 1,
            updatedAt: updatedAt
        )
    }

    func testCombinedDailyHistorySumsByCalendarDay() throws {
        let cal = calendar()
        let day1 = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 5, day: 1)))
        let day2 = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 5, day: 2)))
        let day1Afternoon = try XCTUnwrap(cal.date(byAdding: .hour, value: 14, to: day1))

        let codex = makeSnapshot(
            tool: .codex,
            days: [(day1, 1.50, 1_000), (day2, 0.50, 500)],
            heatmap: Array(repeating: Array(repeating: 0, count: 24), count: 7),
            models: []
        )
        let claude = makeSnapshot(
            tool: .claude,
            days: [(day1Afternoon, 2.00, 2_000), (day2, 0.25, 250)],
            heatmap: Array(repeating: Array(repeating: 0, count: 24), count: 7),
            models: []
        )

        let combined = CostSnapshotAggregator.combinedDailyHistory([codex, claude], calendar: cal)
        XCTAssertEqual(combined.count, 2)
        XCTAssertEqual(combined[0].date, day1)
        XCTAssertEqual(combined[0].costUSD, 3.50, accuracy: 0.0001)
        XCTAssertEqual(combined[0].totalTokens, 3_000)
        XCTAssertEqual(combined[1].date, day2)
        XCTAssertEqual(combined[1].costUSD, 0.75, accuracy: 0.0001)
        XCTAssertEqual(combined[1].totalTokens, 750)
    }

    func testDailyCostAndTokenPeaksUseIndependentDays() throws {
        let cal = calendar()
        let costPeakDay = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 5, day: 1)))
        let tokenPeakDay = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 5, day: 2)))
        let history = [
            DailyCostPoint(date: costPeakDay, costUSD: 100, totalTokens: 1_000),
            DailyCostPoint(date: tokenPeakDay, costUSD: 10, totalTokens: 9_000),
        ]

        XCTAssertEqual(CostSnapshotAggregator.peakDailyCost(in: history), 100, accuracy: 0.0001)
        XCTAssertEqual(CostSnapshotAggregator.peakDailyTokens(in: history), 9_000)
    }

    func testDailyPeaksDefaultToZeroForEmptyHistory() {
        XCTAssertEqual(CostSnapshotAggregator.peakDailyCost(in: []), 0, accuracy: 0.0001)
        XCTAssertEqual(CostSnapshotAggregator.peakDailyTokens(in: []), 0)
    }

    func testCombinedHeatmapAddsCellsAndTotalsAcrossProviders() {
        var codexCells = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        codexCells[1][9] = 100
        codexCells[3][14] = 50
        var claudeCells = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        claudeCells[1][9] = 25
        claudeCells[5][22] = 200

        let codex = makeSnapshot(tool: .codex, days: [], heatmap: codexCells, models: [])
        let claude = makeSnapshot(tool: .claude, days: [], heatmap: claudeCells, models: [])

        let combined = CostSnapshotAggregator.combinedHeatmap([codex, claude])
        XCTAssertEqual(combined.cells[1][9], 125)
        XCTAssertEqual(combined.cells[3][14], 50)
        XCTAssertEqual(combined.cells[5][22], 200)
        XCTAssertEqual(combined.totalTokens, 375)
    }

    func testCombinedHeatmapWithNoSnapshotsReturnsZeroes() {
        let combined = CostSnapshotAggregator.combinedHeatmap([])
        XCTAssertEqual(combined.cells.count, 7)
        XCTAssertEqual(combined.cells.first?.count, 24)
        XCTAssertEqual(combined.totalTokens, 0)
    }

    func testCombinedModelBreakdownsSortByCostDescending() throws {
        let codex = makeSnapshot(
            tool: .codex,
            days: [],
            heatmap: Array(repeating: Array(repeating: 0, count: 24), count: 7),
            models: [
                ("gpt-5", 3.00, 30_000),
                ("o4-mini", 0.40, 4_000)
            ]
        )
        let claude = makeSnapshot(
            tool: .claude,
            days: [],
            heatmap: Array(repeating: Array(repeating: 0, count: 24), count: 7),
            models: [
                ("claude-sonnet-4-5", 5.00, 50_000),
                ("claude-haiku-4-5", 0.10, 1_000),
                ("gpt-5", 1.00, 10_000)   // simulate a name collision
            ]
        )

        let combined = CostSnapshotAggregator.combinedModelBreakdowns([codex, claude])
        XCTAssertEqual(combined.map(\.modelName), [
            "claude-sonnet-4-5",
            "gpt-5",
            "o4-mini",
            "claude-haiku-4-5"
        ])
        let merged = try XCTUnwrap(combined.first { $0.modelName == "gpt-5" })
        XCTAssertEqual(merged.costUSD, 4.00, accuracy: 0.0001)
        XCTAssertEqual(merged.totalTokens, 40_000)
    }

    func testCombinedSnapshotMergesGoogleAICostAndUsage() throws {
        let cal = calendar()
        let day = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 5, day: 22)))
        let hour = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 5, day: 22, hour: 8)))
        var geminiCells = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        geminiCells[5][8] = 1_000
        var antigravityCells = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        antigravityCells[5][8] = 2_000

        let gemini = makeSnapshot(
            tool: .gemini,
            days: [(day, 1.50, 10_000)],
            hours: [(hour, 0.50, 3_000)],
            heatmap: geminiCells,
            models: [("gemini-3-flash", 1.50, 10_000)],
            last7Models: [("gemini-3-flash", 1.50, 10_000)],
            dailyModels: [day: [("gemini-3-flash", 1.50, 10_000)]],
            updatedAt: day
        )
        let antigravity = makeSnapshot(
            tool: .antigravity,
            days: [(day, 2.00, 20_000)],
            hours: [(hour, 0.75, 4_000)],
            heatmap: antigravityCells,
            models: [("gemini-3-flash-a", 2.00, 20_000)],
            last7Models: [("gemini-3-flash-a", 2.00, 20_000)],
            dailyModels: [day: [("gemini-3-flash-a", 2.00, 20_000)]],
            updatedAt: hour
        )

        let combined = CostSnapshotAggregator.combinedSnapshot(
            tool: .gemini,
            snapshots: [gemini, antigravity],
            now: day,
            calendar: cal
        )
        XCTAssertEqual(combined.tool, .gemini)
        XCTAssertEqual(combined.allTimeCostUSD, 3.50, accuracy: 0.0001)
        XCTAssertEqual(combined.allTimeTokens, 30_000)
        let combinedHour = try XCTUnwrap(combined.todayHourlyHistory.first)
        XCTAssertEqual(combinedHour.costUSD, 1.25, accuracy: 0.0001)
        XCTAssertEqual(combined.heatmap.cells[5][8], 3_000)
        XCTAssertEqual(combined.modelBreakdowns.map(\.modelName), ["gemini-3-flash-a", "gemini-3-flash"])
        XCTAssertEqual(combined.jsonlFilesFound, 2)
        XCTAssertEqual(combined.updatedAt, hour)
    }
}
