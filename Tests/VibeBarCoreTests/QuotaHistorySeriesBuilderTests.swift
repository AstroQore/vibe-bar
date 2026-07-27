import XCTest
@testable import VibeBarCore

final class QuotaHistorySeriesBuilderTests: XCTestCase {
    private let week = 7 * 86_400
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func fill(
        used: Double,
        at date: Date,
        resetAt: Date?,
        windowSeconds: Int? = 7 * 86_400
    ) -> FillTimelinePoint {
        FillTimelinePoint(
            accountId: "acct-1",
            tool: .codex,
            bucketId: "weekly",
            slotStart: UsageTimelineSlotPolicy.slotStart(for: date, windowSeconds: windowSeconds),
            usedPercent: used,
            sampledAt: date,
            resetAt: resetAt,
            rawWindowSeconds: windowSeconds
        )
    }

    private func forecast(
        projected: Double,
        lower: Double,
        upper: Double,
        at date: Date,
        resetAt: Date?,
        windowSeconds: Int? = 7 * 86_400
    ) -> ForecastTimelinePoint {
        ForecastTimelinePoint(
            accountId: "acct-1",
            tool: .codex,
            bucketId: "weekly",
            slotStart: UsageTimelineSlotPolicy.slotStart(for: date, windowSeconds: windowSeconds),
            sampledAt: date,
            projectedUsedPercent: projected,
            projectedUsedLowerPercent: lower,
            projectedUsedUpperPercent: upper,
            resetAt: resetAt,
            rawWindowSeconds: windowSeconds
        )
    }

    private func range(_ span: TimeInterval = 30 * 86_400) -> ClosedRange<Date> {
        base.addingTimeInterval(-span)...base.addingTimeInterval(span)
    }

    // MARK: - Actual series

    func testActualConvertsUsedPercentToRemaining() {
        let reset = base.addingTimeInterval(TimeInterval(week))
        let series = QuotaHistorySeriesBuilder.build(
            fillPoints: [
                fill(used: 10, at: base, resetAt: reset),
                fill(used: 25, at: base.addingTimeInterval(3_600), resetAt: reset)
            ],
            range: range()
        )
        XCTAssertEqual(series.actual.count, 1)
        XCTAssertEqual(series.actual[0].map(\.remainingPercent), [90, 75])
        XCTAssertEqual(series.actual[0].map(\.time), [base, base.addingTimeInterval(3_600)])
    }

    func testPointsOutsideRangeAreExcluded() {
        let reset = base.addingTimeInterval(TimeInterval(week))
        let series = QuotaHistorySeriesBuilder.build(
            fillPoints: [
                fill(used: 5, at: base.addingTimeInterval(-40 * 86_400), resetAt: reset),
                fill(used: 20, at: base, resetAt: reset)
            ],
            range: range()
        )
        XCTAssertEqual(series.actual.flatMap { $0 }.count, 1)
        XCTAssertEqual(series.actual[0].first?.remainingPercent, 80)
    }

    // MARK: - Segmentation

    func testWindowChangeStartsNewSegment() {
        let firstReset = base.addingTimeInterval(3_600)
        let secondReset = firstReset.addingTimeInterval(TimeInterval(week))
        let series = QuotaHistorySeriesBuilder.build(
            fillPoints: [
                fill(used: 80, at: base, resetAt: firstReset),
                // Same cadence, but the provider now reports the next window.
                fill(used: 2, at: base.addingTimeInterval(3_600), resetAt: secondReset),
                fill(used: 6, at: base.addingTimeInterval(7_200), resetAt: secondReset)
            ],
            range: range()
        )
        XCTAssertEqual(series.actual.count, 2)
        XCTAssertEqual(series.actual[0].map(\.remainingPercent), [20])
        XCTAssertEqual(series.actual[1].map(\.remainingPercent), [98, 94])
    }

    func testSamplingGapBeyondTwoSlotsStartsNewSegment() {
        let reset = base.addingTimeInterval(TimeInterval(week))
        // Weekly windows use hourly slots, so the split threshold is 2 hours —
        // already wider than the slowest refresh cadence, so the floor does not
        // move it.
        let series = QuotaHistorySeriesBuilder.build(
            fillPoints: [
                fill(used: 10, at: base, resetAt: reset),
                fill(used: 12, at: base.addingTimeInterval(2 * 3_600), resetAt: reset),
                fill(used: 30, at: base.addingTimeInterval(2 * 3_600 + 2 * 3_600 + 1), resetAt: reset)
            ],
            range: range()
        )
        XCTAssertEqual(series.actual.count, 2)
        XCTAssertEqual(series.actual[0].count, 2)
        XCTAssertEqual(series.actual[1].count, 1)
        XCTAssertEqual(series.actual[1][0].remainingPercent, 70)
    }

    func testExactlyTwoSlotGapStaysInOneSegment() {
        let reset = base.addingTimeInterval(TimeInterval(week))
        let series = QuotaHistorySeriesBuilder.build(
            fillPoints: [
                fill(used: 10, at: base, resetAt: reset),
                fill(used: 12, at: base.addingTimeInterval(2 * 3_600), resetAt: reset)
            ],
            range: range()
        )
        XCTAssertEqual(series.actual.count, 1)
        XCTAssertEqual(series.actual[0].count, 2)
    }

    func testFiveHourWindowKeepsSlowestRefreshCadenceInOneSegment() {
        let reset = base.addingTimeInterval(18_000)
        // Five-hour windows slot at 5 minutes, so the slot-derived threshold is
        // 10 — but 30 minutes is a cadence the refresh picker offers, and a
        // line drawn from single-point segments draws nothing at all.
        let cadence = TimeInterval(AppSettings.slowestRefreshIntervalSeconds)
        let series = QuotaHistorySeriesBuilder.build(
            fillPoints: [
                fill(used: 10, at: base, resetAt: reset, windowSeconds: 18_000),
                fill(used: 14, at: base.addingTimeInterval(cadence), resetAt: reset, windowSeconds: 18_000),
                fill(
                    used: 21,
                    at: base.addingTimeInterval(2 * cadence),
                    resetAt: reset,
                    windowSeconds: 18_000
                )
            ],
            range: range()
        )
        XCTAssertEqual(series.actual.count, 1)
        XCTAssertEqual(series.actual[0].map(\.remainingPercent), [90, 86, 79])
    }

    func testFiveHourWindowStillSplitsOnRealCoverageGap() {
        let reset = base.addingTimeInterval(18_000)
        // Beyond two missed refreshes at the slowest cadence (plus the
        // scheduler's 30s tolerance) the app really was not running.
        let series = QuotaHistorySeriesBuilder.build(
            fillPoints: [
                fill(used: 10, at: base, resetAt: reset, windowSeconds: 18_000),
                fill(used: 14, at: base.addingTimeInterval(65 * 60), resetAt: reset, windowSeconds: 18_000)
            ],
            range: range()
        )
        XCTAssertEqual(series.actual.count, 2)
        XCTAssertEqual(series.actual[0].count, 1)
        XCTAssertEqual(series.actual[1].count, 1)
    }

    func testGapFloorTracksTheSlowestSelectableRefreshInterval() {
        // The floor is derived, not hardcoded: adding a slower option to the
        // picker must widen it rather than silently shred slow-cadence lines.
        XCTAssertEqual(
            QuotaHistorySeriesBuilder.minimumGapSeconds,
            2 * TimeInterval(AppSettings.slowestRefreshIntervalSeconds) + 30
        )
        XCTAssertEqual(AppSettings.slowestRefreshIntervalSeconds, 1_800)
    }

    // MARK: - Pace replay

    func testPaceReplaysElapsedTimeFromEachPointsOwnWindow() {
        let reset = base.addingTimeInterval(TimeInterval(week))
        // Pace is time-only: a sample a quarter of the way into its window
        // expects 25% used no matter what the account actually burned.
        func paceRemaining(atElapsedFraction fraction: Double, used: Double) -> Double {
            let time = reset.addingTimeInterval(-TimeInterval(week) * (1 - fraction))
            let series = QuotaHistorySeriesBuilder.build(
                fillPoints: [fill(used: used, at: time, resetAt: reset)],
                range: range(60 * 86_400)
            )
            return series.pace[0][0].remainingPercent
        }
        XCTAssertEqual(paceRemaining(atElapsedFraction: 0, used: 0), 100, accuracy: 0.001)
        XCTAssertEqual(paceRemaining(atElapsedFraction: 0.25, used: 90), 75, accuracy: 0.001)
        XCTAssertEqual(paceRemaining(atElapsedFraction: 0.5, used: 3), 50, accuracy: 0.001)
        XCTAssertEqual(paceRemaining(atElapsedFraction: 1, used: 40), 0, accuracy: 0.001)
    }

    func testPaceSkipsPointsMissingResetMetadataWithoutSplitting() {
        let reset = base.addingTimeInterval(TimeInterval(week) / 2)
        let series = QuotaHistorySeriesBuilder.build(
            fillPoints: [
                fill(used: 10, at: base, resetAt: reset),
                // Legacy point: no window metadata, so it cannot be replayed —
                // but it must not tear the segment in half either.
                fill(used: 14, at: base.addingTimeInterval(3_600), resetAt: reset, windowSeconds: nil),
                fill(used: 18, at: base.addingTimeInterval(7_200), resetAt: reset)
            ],
            range: range()
        )
        XCTAssertEqual(series.actual.count, 1)
        XCTAssertEqual(series.actual[0].count, 3)
        XCTAssertEqual(series.pace.count, 1)
        XCTAssertEqual(series.pace[0].count, 2)
        XCTAssertEqual(series.pace[0].map(\.time), [base, base.addingTimeInterval(7_200)])
    }

    func testPaceSegmentIsDroppedWhenNoPointCanBeReplayed() {
        let series = QuotaHistorySeriesBuilder.build(
            fillPoints: [
                fill(used: 10, at: base, resetAt: nil, windowSeconds: nil),
                fill(used: 14, at: base.addingTimeInterval(3_600), resetAt: nil, windowSeconds: nil)
            ],
            range: range()
        )
        XCTAssertEqual(series.actual.count, 1)
        XCTAssertTrue(series.pace.isEmpty)
    }

    func testPaceClampsPastReset() {
        let reset = base.addingTimeInterval(-3_600)
        let series = QuotaHistorySeriesBuilder.build(
            fillPoints: [fill(used: 90, at: base, resetAt: reset)],
            range: range()
        )
        XCTAssertEqual(series.pace[0][0].remainingPercent, 0)
    }

    // MARK: - Forecast

    func testForecastRemainingFlipsProjectionBounds() {
        let reset = base.addingTimeInterval(TimeInterval(week))
        let series = QuotaHistorySeriesBuilder.build(
            fillPoints: [],
            forecastPoints: [
                forecast(projected: 60, lower: 45, upper: 82, at: base, resetAt: reset)
            ],
            range: range()
        )
        XCTAssertEqual(series.forecast.count, 1)
        let sample = series.forecast[0][0]
        XCTAssertEqual(sample.remainingPercent, 40)
        // Pessimistic (most used) becomes the lower remaining bound.
        XCTAssertEqual(sample.lowerRemainingPercent, 18)
        XCTAssertEqual(sample.upperRemainingPercent, 55)
    }

    func testForecastOverOneHundredClampsToZeroRemaining() {
        let reset = base.addingTimeInterval(TimeInterval(week))
        let series = QuotaHistorySeriesBuilder.build(
            fillPoints: [],
            forecastPoints: [
                forecast(projected: 130, lower: 110, upper: 165, at: base, resetAt: reset)
            ],
            range: range()
        )
        let sample = series.forecast[0][0]
        XCTAssertEqual(sample.remainingPercent, 0)
        XCTAssertEqual(sample.lowerRemainingPercent, 0)
        XCTAssertEqual(sample.upperRemainingPercent, 0)
    }

    func testForecastSegmentsOnWindowChange() {
        let firstReset = base.addingTimeInterval(3_600)
        let secondReset = firstReset.addingTimeInterval(TimeInterval(week))
        let series = QuotaHistorySeriesBuilder.build(
            fillPoints: [],
            forecastPoints: [
                forecast(projected: 95, lower: 90, upper: 99, at: base, resetAt: firstReset),
                forecast(projected: 20, lower: 10, upper: 30, at: base.addingTimeInterval(3_600), resetAt: secondReset)
            ],
            range: range()
        )
        XCTAssertEqual(series.forecast.count, 2)
        XCTAssertEqual(series.forecast[0].count, 1)
        XCTAssertEqual(series.forecast[1].count, 1)
    }

    // MARK: - Reset boundaries

    func testResetBoundariesAreDistinctSortedAndInsideRange() {
        let insideEarly = base.addingTimeInterval(-2 * 86_400)
        let insideLate = base.addingTimeInterval(5 * 86_400)
        let outside = base.addingTimeInterval(90 * 86_400)
        let series = QuotaHistorySeriesBuilder.build(
            fillPoints: [
                fill(used: 30, at: base.addingTimeInterval(-3 * 86_400), resetAt: insideEarly),
                fill(used: 5, at: base.addingTimeInterval(-86_400), resetAt: insideLate),
                fill(used: 9, at: base, resetAt: insideLate),
                fill(used: 12, at: base.addingTimeInterval(86_400), resetAt: outside)
            ],
            range: range()
        )
        XCTAssertEqual(series.resetBoundaries, [insideEarly, insideLate])
    }

    func testResetBoundariesIncludeWindowsFromSamplesOutsideRange() {
        // The visible range starts after the sample, but the reset it predicts
        // lands inside — the boundary line still belongs on the chart.
        let reset = base.addingTimeInterval(86_400)
        let series = QuotaHistorySeriesBuilder.build(
            fillPoints: [fill(used: 44, at: base.addingTimeInterval(-90 * 86_400), resetAt: reset)],
            range: range()
        )
        XCTAssertTrue(series.actual.isEmpty)
        XCTAssertEqual(series.resetBoundaries, [reset])
    }

    func testEmptyInputProducesEmptySeries() {
        let series = QuotaHistorySeriesBuilder.build(fillPoints: [], range: range())
        XCTAssertTrue(series.isEmpty)
        XCTAssertTrue(series.resetBoundaries.isEmpty)
    }

    func testUnsortedInputIsOrderedBeforeSegmentation() {
        let reset = base.addingTimeInterval(TimeInterval(week))
        let series = QuotaHistorySeriesBuilder.build(
            fillPoints: [
                fill(used: 12, at: base.addingTimeInterval(3_600), resetAt: reset),
                fill(used: 10, at: base, resetAt: reset)
            ],
            range: range()
        )
        XCTAssertEqual(series.actual.count, 1)
        XCTAssertEqual(series.actual[0].map(\.remainingPercent), [90, 88])
    }
}
