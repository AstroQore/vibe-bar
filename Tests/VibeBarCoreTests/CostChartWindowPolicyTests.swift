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

    // MARK: - Hourly retention window

    func testHourlyRetentionStartIsMidnightThirteenDaysBack() {
        XCTAssertEqual(CostChartWindowPolicy.hourlyRetentionDays, 14)
        XCTAssertEqual(
            CostChartWindowPolicy.hourlyRetentionStart(now: date(2026, 6, 20, 17), calendar: calendar),
            date(2026, 6, 7)
        )
    }

    /// Counted in calendar days, not in 86 400-second multiples, so the window
    /// still starts at a midnight when a DST change falls inside it.
    func testHourlyRetentionStartLandsOnMidnightAcrossDst() {
        let start = CostChartWindowPolicy.hourlyRetentionStart(
            now: date(2026, 3, 14, 17),
            calendar: calendar
        )
        XCTAssertEqual(start, date(2026, 3, 1))
        XCTAssertEqual(calendar.startOfDay(for: start), start)
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

    /// Fed the declared retention start rather than the oldest bucket, the same
    /// function reports the whole retained window — which is what lets Auto
    /// reach Hour at three, four and five days instead of falling back to Day
    /// because the scan only found spend yesterday.
    func testCoverageFromRetentionStartSpansTheWholeWindow() {
        let now = date(2026, 6, 20, 10)
        let coverage = CostChartWindowPolicy.hourlyCoverage(
            firstHour: CostChartWindowPolicy.hourlyRetentionStart(now: now, calendar: calendar),
            lastHour: date(2026, 6, 20, 10),
            calendar: calendar
        )
        XCTAssertEqual(coverage?.lowerBound, date(2026, 6, 7))
        XCTAssertEqual(coverage?.upperBound, date(2026, 6, 21))
        for days in [3, 4, 5, 7] {
            let start = calendar.date(byAdding: .day, value: -days, to: date(2026, 6, 21))!
            XCTAssertTrue(
                CostChartWindowPolicy.covers(coverage, range: start...date(2026, 6, 21)),
                "a \(days)-day window inside the retained window should be covered"
            )
        }
    }

    /// A window reaching past the retained days is still not hourly, however
    /// the coverage was derived — the point of the retention constant is that
    /// it has an edge.
    func testWindowOlderThanTheRetentionWindowIsNotCovered() {
        let now = date(2026, 6, 20, 10)
        let coverage = CostChartWindowPolicy.hourlyCoverage(
            firstHour: CostChartWindowPolicy.hourlyRetentionStart(now: now, calendar: calendar),
            lastHour: date(2026, 6, 20, 10),
            calendar: calendar
        )
        XCTAssertFalse(
            CostChartWindowPolicy.covers(coverage, range: date(2026, 6, 6)...date(2026, 6, 21))
        )
        XCTAssertFalse(
            CostChartWindowPolicy.covers(coverage, range: date(2026, 5, 20)...date(2026, 6, 21))
        )
    }

    /// A snapshot cached longer ago than the whole window has nothing left
    /// inside it, and must not claim coverage from its retention start.
    func testCoverageIsNilWhenTheNewestBucketPredatesTheWindow() {
        let now = date(2026, 6, 20, 10)
        XCTAssertNil(
            CostChartWindowPolicy.hourlyCoverage(
                firstHour: CostChartWindowPolicy.hourlyRetentionStart(now: now, calendar: calendar),
                lastHour: date(2026, 5, 30, 9),
                calendar: calendar
            )
        )
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
