import XCTest
@testable import VibeBarCore

final class CostSnapshotTests: XCTestCase {
    func testRebasedForCurrentDayClearsStaleTodayTotalsAndHours() throws {
        let shanghai = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3600))
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = shanghai

        let yesterdayNow = try XCTUnwrap(calendar.date(from: DateComponents(
            timeZone: shanghai,
            year: 2026,
            month: 5,
            day: 6,
            hour: 20
        )))
        let todayNow = try XCTUnwrap(calendar.date(from: DateComponents(
            timeZone: shanghai,
            year: 2026,
            month: 5,
            day: 7,
            hour: 3
        )))
        let yesterday = calendar.startOfDay(for: yesterdayNow)
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: todayNow)))
        let staleHour = try XCTUnwrap(calendar.date(byAdding: .hour, value: 20, to: yesterday))

        let snapshot = CostSnapshot(
            tool: .codex,
            todayCostUSD: 720,
            last7DaysCostUSD: 720,
            last30DaysCostUSD: 720,
            allTimeCostUSD: 720,
            todayTokens: 1_043_270_000,
            last7DaysTokens: 1_043_270_000,
            last30DaysTokens: 1_043_270_000,
            allTimeTokens: 1_043_270_000,
            dailyHistory: [
                DailyCostPoint(date: yesterday, costUSD: 720, totalTokens: 1_043_270_000),
                DailyCostPoint(date: tomorrow, costUSD: 999, totalTokens: 9_990)
            ],
            todayHourlyHistory: [
                HourlyCostPoint(date: staleHour, costUSD: 720, totalTokens: 1_043_270_000)
            ],
            heatmap: .empty(tool: .codex),
            modelBreakdowns: [],
            jsonlFilesFound: 1,
            updatedAt: yesterdayNow
        )

        let rebased = snapshot.rebasedForCurrentDay(now: todayNow, calendar: calendar)

        XCTAssertEqual(rebased.todayCostUSD, 0, accuracy: 0.001)
        XCTAssertEqual(rebased.todayTokens, 0)
        XCTAssertTrue(rebased.todayHourlyHistory.isEmpty)
        XCTAssertEqual(rebased.last7DaysCostUSD, 720, accuracy: 0.001)
        XCTAssertEqual(rebased.last7DaysTokens, 1_043_270_000)
        XCTAssertEqual(rebased.allTimeCostUSD, 720, accuracy: 0.001)
    }
}
