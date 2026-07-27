import XCTest
@testable import VibeBarCore

final class CostChartWindowPolicyTests: XCTestCase {
    private let day: TimeInterval = 86_400

    /// A zone with a real DST rule, so the 23- and 25-hour days the presets
    /// have to survive are reachable from a fixed date rather than from
    /// whatever the machine happens to be set to.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour)
        )!
    }

    // MARK: - Bucket overlap

    func testBucketEndingExactlyAtVisibleStartIsExcluded() {
        let start = date(2026, 6, 1)
        let range = date(2026, 6, 2)...date(2026, 6, 5)
        XCTAssertFalse(
            CostChartWindowPolicy.bucketOverlaps(start: start, width: day, range: range)
        )
    }

    func testBucketStartingExactlyAtVisibleEndIsExcluded() {
        let range = date(2026, 6, 2)...date(2026, 6, 5)
        XCTAssertFalse(
            CostChartWindowPolicy.bucketOverlaps(start: date(2026, 6, 5), width: day, range: range)
        )
    }

    func testBucketStraddlingAnEdgeIsIncluded() {
        let range = date(2026, 6, 2, 12)...date(2026, 6, 5, 12)
        XCTAssertTrue(
            CostChartWindowPolicy.bucketOverlaps(start: date(2026, 6, 2), width: day, range: range)
        )
        XCTAssertTrue(
            CostChartWindowPolicy.bucketOverlaps(start: date(2026, 6, 5), width: day, range: range)
        )
    }

    func testBucketFlushWithBothEdgesIsIncludedOnce() {
        let range = date(2026, 6, 2)...date(2026, 6, 3)
        XCTAssertTrue(
            CostChartWindowPolicy.bucketOverlaps(start: date(2026, 6, 2), width: day, range: range)
        )
    }

    /// The regression this predicate exists for: a midnight-aligned 30-day
    /// window used to count a 31st daily bar that occupied no visible time, so
    /// TOTAL / AVG / PEAK disagreed with the chart.
    func testThirtyDayWindowCountsThirtyDailyBuckets() {
        let now = date(2026, 6, 20, 14)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let span = CostChartWindowPolicy.anchoredSpan(days: 30, now: now, calendar: calendar)
        let range = end.addingTimeInterval(-span)...end
        let buckets = (0..<45).compactMap {
            calendar.date(byAdding: .day, value: -$0, to: calendar.startOfDay(for: now))
        }
        let visible = buckets.filter {
            CostChartWindowPolicy.bucketOverlaps(start: $0, width: day, range: range)
        }
        XCTAssertEqual(visible.count, 30)
        XCTAssertEqual(visible.min(), range.lowerBound)
    }

    // MARK: - Anchored preset spans

    func testAnchoredSpanIsAWholeCalendarDayOnASpringForwardDay() {
        // 2026-03-08 loses an hour in New York, so "today" is 23 hours long.
        let span = CostChartWindowPolicy.anchoredSpan(
            days: 1,
            now: date(2026, 3, 8, 12),
            calendar: calendar
        )
        XCTAssertEqual(span, 23 * 3_600)
    }

    func testAnchoredSpanIsAWholeCalendarDayOnAFallBackDay() {
        // 2026-11-01 repeats an hour, so "today" is 25 hours long.
        let span = CostChartWindowPolicy.anchoredSpan(
            days: 1,
            now: date(2026, 11, 1, 12),
            calendar: calendar
        )
        XCTAssertEqual(span, 25 * 3_600)
    }

    func testAnchoredSpansLandOnMidnightWhenMeasuredBackFromTheDomainEnd() {
        for now in [date(2026, 3, 8, 9), date(2026, 11, 1, 9), date(2026, 6, 20, 9)] {
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            for days in [1, 7, 30] {
                let span = CostChartWindowPolicy.anchoredSpan(
                    days: days,
                    now: now,
                    calendar: calendar
                )
                let start = end.addingTimeInterval(-span)
                XCTAssertEqual(
                    start,
                    calendar.startOfDay(for: start),
                    "\(days)d preset drifted off midnight at \(now)"
                )
                XCTAssertEqual(
                    start,
                    calendar.date(byAdding: .day, value: -days, to: end),
                    "\(days)d preset covered the wrong number of calendar days at \(now)"
                )
            }
        }
    }

    /// The preset pills light up by comparing the visible span against the
    /// preset's span with a 3% tolerance. A DST hour is well outside that on
    /// the shorter presets, which is why both sides have to be calendar spans:
    /// the old fixed-multiple arithmetic would have unlit the pill the user
    /// just clicked.
    func testDstDriftExceedsThePillHighlightTolerance() {
        let span = CostChartWindowPolicy.anchoredSpan(
            days: 1,
            now: date(2026, 3, 8, 12),
            calendar: calendar
        )
        XCTAssertGreaterThan(abs(span - day), day * 0.03)
        // Matched against itself — what the view now compares — it is exact.
        XCTAssertLessThanOrEqual(abs(span - span), span * 0.03)
    }

    func testAnchoredSpanFallsBackToNominalDaysForNonPositiveCounts() {
        let span = CostChartWindowPolicy.anchoredSpan(
            days: 0,
            now: date(2026, 6, 20, 12),
            calendar: calendar
        )
        XCTAssertEqual(span, day)
    }

    // MARK: - Yesterday bounds

    func testYesterdayBoundsAreCalendarDays() {
        let (start, end) = CostChartWindowPolicy.yesterdayBounds(
            now: date(2026, 6, 20, 17),
            calendar: calendar
        )
        XCTAssertEqual(start, date(2026, 6, 19))
        XCTAssertEqual(end, date(2026, 6, 20))
    }

    func testYesterdayBoundsKeepTheShortDayShortAcrossDst() {
        let (start, end) = CostChartWindowPolicy.yesterdayBounds(
            now: date(2026, 3, 9, 17),
            calendar: calendar
        )
        XCTAssertEqual(start, date(2026, 3, 8))
        XCTAssertEqual(end.timeIntervalSince(start), 23 * 3_600)
    }

    // MARK: - Hourly coverage

    func testHourlyCoverageSnapsOutToWholeRetainedDays() {
        // Yesterday's first spend at 09:00, today's last at 10:00 — the hours
        // on either side are zeros, not holes.
        let coverage = CostChartWindowPolicy.hourlyCoverage(
            firstHour: date(2026, 6, 19, 9),
            lastHour: date(2026, 6, 20, 10),
            calendar: calendar
        )
        XCTAssertEqual(coverage?.lowerBound, date(2026, 6, 19))
        XCTAssertEqual(coverage?.upperBound, date(2026, 6, 21))
    }

    func testHourlyCoverageIsNilWithoutHourlyPoints() {
        XCTAssertNil(
            CostChartWindowPolicy.hourlyCoverage(
                firstHour: nil,
                lastHour: nil,
                calendar: calendar
            )
        )
        XCTAssertNil(
            CostChartWindowPolicy.hourlyCoverage(
                firstHour: date(2026, 6, 20, 9),
                lastHour: date(2026, 6, 19, 9),
                calendar: calendar
            )
        )
    }

    func testTodayAndYesterdayPresetsAreFullyCovered() {
        let coverage = CostChartWindowPolicy.hourlyCoverage(
            firstHour: date(2026, 6, 19, 9),
            lastHour: date(2026, 6, 20, 10),
            calendar: calendar
        )
        let today = date(2026, 6, 20)...date(2026, 6, 21)
        let yesterday = date(2026, 6, 19)...date(2026, 6, 20)
        XCTAssertTrue(CostChartWindowPolicy.covers(coverage, range: today))
        XCTAssertTrue(CostChartWindowPolicy.covers(coverage, range: yesterday))
    }

    /// The regression: a 3-day window overlaps the retained hourly days, and
    /// used to switch to hours — drawing (and totalling) only the two covered
    /// days while the third silently read as zero.
    func testPartiallyCoveredWindowIsNotHourly() {
        let coverage = CostChartWindowPolicy.hourlyCoverage(
            firstHour: date(2026, 6, 19, 9),
            lastHour: date(2026, 6, 20, 10),
            calendar: calendar
        )
        XCTAssertFalse(
            CostChartWindowPolicy.covers(coverage, range: date(2026, 6, 18)...date(2026, 6, 21))
        )
        XCTAssertFalse(
            CostChartWindowPolicy.covers(coverage, range: date(2026, 6, 14)...date(2026, 6, 21))
        )
    }

    func testCoverageIsNeverAssumedWithoutHourlyData() {
        XCTAssertFalse(
            CostChartWindowPolicy.covers(nil, range: date(2026, 6, 20)...date(2026, 6, 21))
        )
    }
}
