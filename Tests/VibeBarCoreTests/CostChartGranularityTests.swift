import XCTest
@testable import VibeBarCore

final class CostChartGranularityTests: XCTestCase {
    private let day: TimeInterval = 86_400

    // MARK: - Auto resolution

    func testAutoResolvesToHourForShortSpans() {
        XCTAssertEqual(CostChartGranularity.resolve(autoFor: 0), .hour)
        XCTAssertEqual(CostChartGranularity.resolve(autoFor: 3_600), .hour)
        XCTAssertEqual(CostChartGranularity.resolve(autoFor: 2.6 * day), .hour)
    }

    func testAutoResolvesToDayJustPastTheHourThreshold() {
        XCTAssertEqual(CostChartGranularity.resolve(autoFor: 2.6 * day + 1), .day)
        XCTAssertEqual(CostChartGranularity.resolve(autoFor: 30 * day), .day)
        XCTAssertEqual(CostChartGranularity.resolve(autoFor: 110 * day), .day)
    }

    func testAutoResolvesToWeekPastTheDayThreshold() {
        XCTAssertEqual(CostChartGranularity.resolve(autoFor: 110 * day + 1), .week)
        XCTAssertEqual(CostChartGranularity.resolve(autoFor: 365 * day), .week)
    }

    func testNegativeSpanIsTreatedAsZero() {
        XCTAssertEqual(CostChartGranularity.resolve(autoFor: -5 * day), .hour)
    }

    // MARK: - Allowed options

    func testHourIsOfferedUpToOneWeek() {
        XCTAssertEqual(CostChartGranularity.allowed(for: day), [.hour, .day])
        XCTAssertEqual(CostChartGranularity.allowed(for: 7 * day), [.hour, .day])
        XCTAssertEqual(CostChartGranularity.allowed(for: 7 * day + 1), [.day])
    }

    func testWeekIsOfferedFromThreeWeeks() {
        XCTAssertEqual(CostChartGranularity.allowed(for: 20 * day), [.day])
        XCTAssertEqual(CostChartGranularity.allowed(for: 21 * day), [.day, .week])
        XCTAssertEqual(CostChartGranularity.allowed(for: 365 * day), [.day, .week])
    }

    func testDayIsAlwaysAllowed() {
        for span in [0, 1, 7, 21, 200].map({ Double($0) * day }) {
            XCTAssertTrue(
                CostChartGranularity.isAllowed(.day, for: span),
                "day should be allowed at \(span / day) days"
            )
        }
    }

    func testIsAllowedMatchesAllowedList() {
        XCTAssertTrue(CostChartGranularity.isAllowed(.hour, for: 2 * day))
        XCTAssertFalse(CostChartGranularity.isAllowed(.hour, for: 30 * day))
        XCTAssertFalse(CostChartGranularity.isAllowed(.week, for: 10 * day))
        XCTAssertTrue(CostChartGranularity.isAllowed(.week, for: 60 * day))
    }

    // MARK: - Weekly aggregation

    /// Sunday-first locale on purpose: weeks must still start on Monday.
    private func sundayFirstCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar.firstWeekday = 1
        return calendar
    }

    private func date(_ iso: String, calendar: Calendar) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: iso)!
    }

    func testMondayStartIgnoresLocaleFirstWeekday() {
        let calendar = sundayFirstCalendar()
        // 2026-07-27 is a Monday.
        let monday = date("2026-07-27", calendar: calendar)
        for offset in 0..<7 {
            let day = calendar.date(byAdding: .day, value: offset, to: monday)!
            XCTAssertEqual(
                CostChartAggregation.mondayStart(of: day, calendar: calendar),
                monday,
                "offset \(offset) should map back to the same Monday"
            )
        }
        // The Sunday before belongs to the previous week, not this one.
        let sunday = calendar.date(byAdding: .day, value: -1, to: monday)!
        XCTAssertEqual(
            CostChartAggregation.mondayStart(of: sunday, calendar: calendar),
            calendar.date(byAdding: .day, value: -7, to: monday)
        )
    }

    func testWeeklyAggregationSumsWithinMondayWeeks() {
        let calendar = sundayFirstCalendar()
        let monday = date("2026-07-27", calendar: calendar)
        let days = (0..<7).map { offset in
            DailyCostPoint(
                date: calendar.date(byAdding: .day, value: offset, to: monday)!,
                costUSD: Double(offset + 1),
                totalTokens: (offset + 1) * 100
            )
        }
        let weeks = CostChartAggregation.weekly(days, calendar: calendar)
        XCTAssertEqual(weeks.count, 1)
        XCTAssertEqual(weeks[0].weekStart, monday)
        XCTAssertEqual(weeks[0].costUSD, 28, accuracy: 0.000_001)
        XCTAssertEqual(weeks[0].totalTokens, 2_800)
    }

    func testWeeklyAggregationSplitsAtTheWeekBoundary() {
        let calendar = sundayFirstCalendar()
        let monday = date("2026-07-27", calendar: calendar)
        let sunday = calendar.date(byAdding: .day, value: 6, to: monday)!
        let nextMonday = calendar.date(byAdding: .day, value: 7, to: monday)!
        let weeks = CostChartAggregation.weekly(
            [
                DailyCostPoint(date: sunday, costUSD: 3, totalTokens: 30),
                DailyCostPoint(date: nextMonday, costUSD: 4, totalTokens: 40)
            ],
            calendar: calendar
        )
        XCTAssertEqual(weeks.map(\.weekStart), [monday, nextMonday])
        XCTAssertEqual(weeks[0].costUSD, 3, accuracy: 0.000_001)
        XCTAssertEqual(weeks[1].costUSD, 4, accuracy: 0.000_001)
    }

    func testWeeklyAggregationKeepsPartialWeeksAndSortsOldestFirst() {
        let calendar = sundayFirstCalendar()
        let monday = date("2026-07-27", calendar: calendar)
        let previousWednesday = calendar.date(byAdding: .day, value: -5, to: monday)!
        let nextTuesday = calendar.date(byAdding: .day, value: 8, to: monday)!
        let weeks = CostChartAggregation.weekly(
            [
                DailyCostPoint(date: nextTuesday, costUSD: 5, totalTokens: 50),
                DailyCostPoint(date: monday, costUSD: 2, totalTokens: 20),
                DailyCostPoint(date: previousWednesday, costUSD: 1, totalTokens: 10)
            ],
            calendar: calendar
        )
        XCTAssertEqual(weeks.count, 3)
        XCTAssertEqual(
            weeks.map(\.weekStart),
            [
                calendar.date(byAdding: .day, value: -7, to: monday)!,
                monday,
                calendar.date(byAdding: .day, value: 7, to: monday)!
            ]
        )
        XCTAssertEqual(weeks.map(\.totalTokens), [10, 20, 50])
    }

    func testWeeklyAggregationOfEmptyInputIsEmpty() {
        XCTAssertTrue(CostChartAggregation.weekly([], calendar: sundayFirstCalendar()).isEmpty)
    }

    func testWeeklyAggregationIgnoresIntraDayTimes() {
        let calendar = sundayFirstCalendar()
        let monday = date("2026-07-27", calendar: calendar)
        let weeks = CostChartAggregation.weekly(
            [
                DailyCostPoint(date: monday.addingTimeInterval(1), costUSD: 1, totalTokens: 10),
                DailyCostPoint(date: monday.addingTimeInterval(23 * 3_600), costUSD: 2, totalTokens: 20)
            ],
            calendar: calendar
        )
        XCTAssertEqual(weeks.count, 1)
        XCTAssertEqual(weeks[0].weekStart, monday)
        XCTAssertEqual(weeks[0].totalTokens, 30)
    }
}
