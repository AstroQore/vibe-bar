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
        XCTAssertEqual(CostChartGranularity.resolve(autoFor: 420 * day), .week)
    }

    func testAutoResolvesToMonthPastTheWeekThreshold() {
        XCTAssertEqual(CostChartGranularity.resolve(autoFor: 420 * day + 1), .month)
        XCTAssertEqual(CostChartGranularity.resolve(autoFor: 3 * 365 * day), .month)
    }

    func testAutoResolutionIsMonotonicAcrossThresholds() {
        let order: [CostChartGranularity] = [.hour, .day, .week, .month]
        var lowest = 0
        for days in stride(from: 0.0, through: 900.0, by: 0.5) {
            let resolved = CostChartGranularity.resolve(autoFor: days * day)
            guard let rank = order.firstIndex(of: resolved) else {
                return XCTFail("unexpected granularity \(resolved)")
            }
            XCTAssertGreaterThanOrEqual(
                rank,
                lowest,
                "granularity got finer again at \(days) days"
            )
            lowest = rank
        }
        XCTAssertEqual(lowest, order.count - 1, "the widest span should reach month")
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

    func testWeekIsOfferedFromFourWeeks() {
        XCTAssertEqual(CostChartGranularity.allowed(for: 21 * day), [.day])
        XCTAssertEqual(CostChartGranularity.allowed(for: 27 * day), [.day])
        XCTAssertEqual(CostChartGranularity.allowed(for: 28 * day), [.day, .week])
        XCTAssertEqual(CostChartGranularity.allowed(for: 365 * day), [.day, .week, .month])
    }

    /// The unlock threshold and the bar floor have to agree: the first span
    /// that offers weekly must also be able to draw the four weekly bars a
    /// manual pick has to survive.
    func testWeekUnlocksExactlyWhenItCanDrawItsBarFloor() {
        XCTAssertFalse(CostChartGranularity.drawsEnoughBuckets(.week, for: 27 * day))
        XCTAssertTrue(CostChartGranularity.drawsEnoughBuckets(.week, for: 28 * day))
        XCTAssertTrue(CostChartGranularity.survivesManualSelection(.week, for: 28 * day))
    }

    func testMonthIsOfferedFromSixtyDays() {
        XCTAssertEqual(CostChartGranularity.allowed(for: 59 * day), [.day, .week])
        XCTAssertEqual(CostChartGranularity.allowed(for: 60 * day), [.day, .week, .month])
        XCTAssertEqual(CostChartGranularity.allowed(for: 900 * day), [.day, .week, .month])
    }

    // MARK: - Manual selections that stop paying their way

    func testManualPickIsDroppedWhenItWouldDrawTooFewBars() {
        // Monthly is offered from 60 days, but 60 days is only two bars.
        XCTAssertTrue(CostChartGranularity.isAllowed(.month, for: 60 * day))
        XCTAssertFalse(CostChartGranularity.survivesManualSelection(.month, for: 60 * day))
        XCTAssertTrue(CostChartGranularity.survivesManualSelection(.month, for: 120 * day))
    }

    func testManualPickIsDroppedWhenItIsNoLongerOffered() {
        XCTAssertFalse(CostChartGranularity.survivesManualSelection(.hour, for: 30 * day))
        XCTAssertFalse(CostChartGranularity.survivesManualSelection(.week, for: 10 * day))
    }

    func testHourAlwaysClearsTheBarFloorAtEveryUsableSpan() {
        // The chart's zoom floor is half a day, which is still twelve bars.
        for hours in [12.0, 24.0, 48.0, 7 * 24.0] {
            XCTAssertTrue(
                CostChartGranularity.survivesManualSelection(.hour, for: hours * 3_600),
                "hour should survive a \(hours)h span"
            )
        }
    }

    /// Daily is the option the control always offers, so it is never taken
    /// away — not even at the zoom floor, where it draws a single bar.
    func testDayIsExemptFromTheBarFloor() {
        XCTAssertFalse(CostChartGranularity.drawsEnoughBuckets(.day, for: 12 * 3_600))
        XCTAssertTrue(CostChartGranularity.survivesManualSelection(.day, for: 12 * 3_600))
        XCTAssertTrue(CostChartGranularity.survivesManualSelection(.day, for: 900 * day))
    }

    func testBarFloorCountsWholeBucketsAndIgnoresNegativeSpans() {
        XCTAssertEqual(CostChartGranularity.minimumManualBuckets, 4)
        XCTAssertFalse(CostChartGranularity.drawsEnoughBuckets(.week, for: -30 * day))
        XCTAssertTrue(CostChartGranularity.drawsEnoughBuckets(.week, for: 30 * day, minimum: 0))
        XCTAssertTrue(CostChartGranularity.drawsEnoughBuckets(.day, for: 4 * day, minimum: 4))
        XCTAssertFalse(CostChartGranularity.drawsEnoughBuckets(.day, for: 3.9 * day, minimum: 4))
    }

    func testDayIsAlwaysAllowed() {
        for span in [0, 1, 7, 21, 60, 200, 900].map({ Double($0) * day }) {
            XCTAssertTrue(
                CostChartGranularity.isAllowed(.day, for: span),
                "day should be allowed at \(span / day) days"
            )
        }
    }

    /// Auto never picks something the user could not have picked, or the
    /// selector would light up an option the control cannot offer.
    func testAutoResolutionIsAlwaysAnAllowedOption() {
        for days in stride(from: 0.0, through: 900.0, by: 0.5) {
            let span = days * day
            XCTAssertTrue(
                CostChartGranularity.isAllowed(
                    CostChartGranularity.resolve(autoFor: span),
                    for: span
                ),
                "auto resolved to a disallowed granularity at \(days) days"
            )
        }
    }

    func testIsAllowedMatchesAllowedList() {
        XCTAssertTrue(CostChartGranularity.isAllowed(.hour, for: 2 * day))
        XCTAssertFalse(CostChartGranularity.isAllowed(.hour, for: 30 * day))
        XCTAssertFalse(CostChartGranularity.isAllowed(.week, for: 10 * day))
        XCTAssertTrue(CostChartGranularity.isAllowed(.week, for: 60 * day))
        XCTAssertFalse(CostChartGranularity.isAllowed(.month, for: 30 * day))
        XCTAssertTrue(CostChartGranularity.isAllowed(.month, for: 120 * day))
    }

    func testAllCasesCoversEveryBucketWidthCoarsestLast() {
        XCTAssertEqual(CostChartGranularity.allCases, [.hour, .day, .week, .month])
        XCTAssertEqual(
            CostChartGranularity.allCases.map(\.displayName),
            ["Hour", "Day", "Week", "Month"]
        )
        XCTAssertEqual(
            CostChartGranularity.allCases.map(\.approximateBucketSeconds),
            CostChartGranularity.allCases.map(\.approximateBucketSeconds).sorted()
        )
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

    // MARK: - Monthly aggregation

    /// Months don't care about `firstWeekday`; the same fixed UTC calendar keeps
    /// the fixtures timezone-stable.
    private func utcCalendar() -> Calendar { sundayFirstCalendar() }

    func testMonthStartSnapsEveryDayToTheFirst() {
        let calendar = utcCalendar()
        let first = date("2026-07-01", calendar: calendar)
        // July has 31 days; every one of them belongs to the same bucket.
        for offset in 0..<31 {
            let day = calendar.date(byAdding: .day, value: offset, to: first)!
            XCTAssertEqual(
                CostChartAggregation.monthStart(of: day, calendar: calendar),
                first,
                "day \(offset + 1) should map back to July 1"
            )
        }
        // The day before belongs to June, not July.
        XCTAssertEqual(
            CostChartAggregation.monthStart(
                of: calendar.date(byAdding: .day, value: -1, to: first)!,
                calendar: calendar
            ),
            date("2026-06-01", calendar: calendar)
        )
    }

    func testMonthStartHandlesYearRollover() {
        let calendar = utcCalendar()
        XCTAssertEqual(
            CostChartAggregation.monthStart(of: date("2025-12-31", calendar: calendar), calendar: calendar),
            date("2025-12-01", calendar: calendar)
        )
        XCTAssertEqual(
            CostChartAggregation.monthStart(of: date("2026-01-01", calendar: calendar), calendar: calendar),
            date("2026-01-01", calendar: calendar)
        )
    }

    func testMonthStartHandlesLeapFebruary() {
        let calendar = utcCalendar()
        XCTAssertEqual(
            CostChartAggregation.monthStart(of: date("2028-02-29", calendar: calendar), calendar: calendar),
            date("2028-02-01", calendar: calendar)
        )
    }

    func testMonthlyAggregationSumsWithinCalendarMonths() {
        let calendar = utcCalendar()
        let first = date("2026-07-01", calendar: calendar)
        let days = (0..<31).map { offset in
            DailyCostPoint(
                date: calendar.date(byAdding: .day, value: offset, to: first)!,
                costUSD: Double(offset + 1),
                totalTokens: (offset + 1) * 100
            )
        }
        let months = CostChartAggregation.monthly(days, calendar: calendar)
        XCTAssertEqual(months.count, 1)
        XCTAssertEqual(months[0].monthStart, first)
        // 1 + 2 + … + 31
        XCTAssertEqual(months[0].costUSD, 496, accuracy: 0.000_001)
        XCTAssertEqual(months[0].totalTokens, 49_600)
    }

    func testMonthlyAggregationSplitsAtTheMonthBoundary() {
        let calendar = utcCalendar()
        let months = CostChartAggregation.monthly(
            [
                DailyCostPoint(date: date("2026-01-31", calendar: calendar), costUSD: 3, totalTokens: 30),
                DailyCostPoint(date: date("2026-02-01", calendar: calendar), costUSD: 4, totalTokens: 40)
            ],
            calendar: calendar
        )
        XCTAssertEqual(
            months.map(\.monthStart),
            [date("2026-01-01", calendar: calendar), date("2026-02-01", calendar: calendar)]
        )
        XCTAssertEqual(months[0].costUSD, 3, accuracy: 0.000_001)
        XCTAssertEqual(months[1].costUSD, 4, accuracy: 0.000_001)
    }

    func testMonthlyAggregationSplitsAcrossTheYearBoundary() {
        let calendar = utcCalendar()
        let months = CostChartAggregation.monthly(
            [
                DailyCostPoint(date: date("2025-12-30", calendar: calendar), costUSD: 1, totalTokens: 10),
                DailyCostPoint(date: date("2025-12-31", calendar: calendar), costUSD: 2, totalTokens: 20),
                DailyCostPoint(date: date("2026-01-01", calendar: calendar), costUSD: 5, totalTokens: 50)
            ],
            calendar: calendar
        )
        XCTAssertEqual(
            months.map(\.monthStart),
            [date("2025-12-01", calendar: calendar), date("2026-01-01", calendar: calendar)]
        )
        XCTAssertEqual(months.map(\.totalTokens), [30, 50])
        XCTAssertEqual(months[0].costUSD, 3, accuracy: 0.000_001)
    }

    func testMonthlyAggregationKeepsPartialMonthsAndSortsOldestFirst() {
        let calendar = utcCalendar()
        let months = CostChartAggregation.monthly(
            [
                DailyCostPoint(date: date("2026-09-02", calendar: calendar), costUSD: 5, totalTokens: 50),
                DailyCostPoint(date: date("2026-07-28", calendar: calendar), costUSD: 2, totalTokens: 20),
                DailyCostPoint(date: date("2026-06-15", calendar: calendar), costUSD: 1, totalTokens: 10)
            ],
            calendar: calendar
        )
        XCTAssertEqual(months.count, 3)
        XCTAssertEqual(
            months.map(\.monthStart),
            [
                date("2026-06-01", calendar: calendar),
                date("2026-07-01", calendar: calendar),
                date("2026-09-01", calendar: calendar)
            ]
        )
        // August has no data at all and is simply absent — no zero-filled bar.
        XCTAssertEqual(months.map(\.totalTokens), [10, 20, 50])
    }

    func testMonthlyAggregationOfEmptyInputIsEmpty() {
        XCTAssertTrue(CostChartAggregation.monthly([], calendar: utcCalendar()).isEmpty)
    }

    func testMonthlyAggregationIgnoresIntraDayTimes() {
        let calendar = utcCalendar()
        let first = date("2026-07-01", calendar: calendar)
        let months = CostChartAggregation.monthly(
            [
                DailyCostPoint(date: first.addingTimeInterval(1), costUSD: 1, totalTokens: 10),
                DailyCostPoint(
                    date: date("2026-07-31", calendar: calendar).addingTimeInterval(23 * 3_600),
                    costUSD: 2,
                    totalTokens: 20
                )
            ],
            calendar: calendar
        )
        XCTAssertEqual(months.count, 1)
        XCTAssertEqual(months[0].monthStart, first)
        XCTAssertEqual(months[0].totalTokens, 30)
    }

    func testMonthlyAggregationCoversLeapFebruaryWithoutLeaking() {
        let calendar = utcCalendar()
        let feb = date("2028-02-01", calendar: calendar)
        let days = (0..<29).map { offset in
            DailyCostPoint(
                date: calendar.date(byAdding: .day, value: offset, to: feb)!,
                costUSD: 1,
                totalTokens: 10
            )
        }
        let months = CostChartAggregation.monthly(days, calendar: calendar)
        XCTAssertEqual(months.count, 1, "all 29 days of a leap February belong to one bucket")
        XCTAssertEqual(months[0].monthStart, feb)
        XCTAssertEqual(months[0].costUSD, 29, accuracy: 0.000_001)
    }

    /// Weekly and monthly slice the same history differently but must never
    /// disagree about how much it cost in total.
    func testWeeklyAndMonthlyPreserveTheSameTotal() {
        let calendar = utcCalendar()
        let start = date("2025-11-15", calendar: calendar)
        let days = (0..<120).map { offset in
            DailyCostPoint(
                date: calendar.date(byAdding: .day, value: offset, to: start)!,
                costUSD: Double(offset % 7) + 0.5,
                totalTokens: offset * 3
            )
        }
        let weeklyCost = CostChartAggregation.weekly(days, calendar: calendar).reduce(0) { $0 + $1.costUSD }
        let monthlyCost = CostChartAggregation.monthly(days, calendar: calendar).reduce(0) { $0 + $1.costUSD }
        let rawCost = days.reduce(0) { $0 + $1.costUSD }
        XCTAssertEqual(weeklyCost, rawCost, accuracy: 0.000_001)
        XCTAssertEqual(monthlyCost, rawCost, accuracy: 0.000_001)
        XCTAssertEqual(
            CostChartAggregation.monthly(days, calendar: calendar).reduce(0) { $0 + $1.totalTokens },
            days.reduce(0) { $0 + $1.totalTokens }
        )
    }
}
