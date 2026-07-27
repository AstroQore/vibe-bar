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

    func testJitteringResetEstimatesStayInOneSegment() {
        // The bug this guards: a provider that reports "resets in N seconds"
        // yields a slightly different absolute instant on every fetch. Exact
        // comparison made every consecutive pair look like a new window, so a
        // weekly lane became a run of one-point segments and drew nothing at
        // all while its legend kept showing the right percentage.
        let reset = base.addingTimeInterval(TimeInterval(week) / 2)
        let drifts: [TimeInterval] = [0, -0.81, 0.34, -0.19, 0.94]
        let points = drifts.enumerated().map { index, drift in
            fill(
                used: Double(10 + index),
                at: base.addingTimeInterval(TimeInterval(index) * 3_600),
                resetAt: reset.addingTimeInterval(drift)
            )
        }
        let series = QuotaHistorySeriesBuilder.build(fillPoints: points, range: range())
        XCTAssertEqual(series.actual.count, 1)
        XCTAssertEqual(series.actual[0].map(\.remainingPercent), [90, 89, 88, 87, 86])
        XCTAssertEqual(series.pace.count, 1)
        XCTAssertEqual(series.pace[0].count, 5)
    }

    func testSampleAfterRecordedResetStartsNewSegment() {
        // Crossing is the honest signal: the second sample is taken past the
        // instant the first one said the window would refill.
        let reset = base.addingTimeInterval(3_600)
        let series = QuotaHistorySeriesBuilder.build(
            fillPoints: [
                fill(used: 80, at: base, resetAt: reset),
                fill(
                    used: 3,
                    at: reset.addingTimeInterval(QuotaHistorySeriesBuilder.resetEstimateTolerance + 1),
                    resetAt: reset.addingTimeInterval(TimeInterval(week))
                )
            ],
            range: range()
        )
        XCTAssertEqual(series.actual.count, 2)
    }

    func testSampleInsideTheResetToleranceStaysInOneSegment() {
        let reset = base.addingTimeInterval(3_600)
        let series = QuotaHistorySeriesBuilder.build(
            fillPoints: [
                fill(used: 80, at: base, resetAt: reset),
                // Still the same window: a sample a few seconds past a reset
                // estimate has not proved anything refilled.
                fill(used: 82, at: reset.addingTimeInterval(5), resetAt: reset.addingTimeInterval(0.4))
            ],
            range: range()
        )
        XCTAssertEqual(series.actual.count, 1)
        XCTAssertEqual(series.actual[0].count, 2)
    }

    func testWindowLengthChangeStartsNewSegment() {
        let reset = base.addingTimeInterval(TimeInterval(week) / 2)
        let series = QuotaHistorySeriesBuilder.build(
            fillPoints: [
                fill(used: 40, at: base, resetAt: reset, windowSeconds: week),
                // A count of seconds is not an estimate — the plan's shape
                // really did change.
                fill(used: 41, at: base.addingTimeInterval(3_600), resetAt: reset, windowSeconds: 18_000)
            ],
            range: range()
        )
        XCTAssertEqual(series.actual.count, 2)
    }

    func testActualDrawsForPointsWithoutResetMetadata() {
        // Legacy weekly-style history: no reset instant was ever recorded, so
        // nothing can be replayed — but the observations themselves are still
        // evidence and have to draw.
        let series = QuotaHistorySeriesBuilder.build(
            fillPoints: (0..<4).map { index in
                fill(
                    used: Double(20 + index * 5),
                    at: base.addingTimeInterval(TimeInterval(index) * 3_600),
                    resetAt: nil,
                    windowSeconds: week
                )
            },
            range: range()
        )
        XCTAssertEqual(series.actual.count, 1)
        XCTAssertEqual(series.actual[0].map(\.remainingPercent), [80, 75, 70, 65])
        XCTAssertTrue(series.pace.isEmpty)
    }

    func testResetMetadataAppearingMidLaneDoesNotSplitTheActualLine() {
        // Vibe Bar started recording `resetAt` partway through this lane's
        // history. That is a change in what *we* stored, not evidence that the
        // quota refilled, so the line stays continuous.
        let reset = base.addingTimeInterval(TimeInterval(week) / 2)
        let series = QuotaHistorySeriesBuilder.build(
            fillPoints: [
                fill(used: 20, at: base, resetAt: nil, windowSeconds: week),
                fill(used: 24, at: base.addingTimeInterval(3_600), resetAt: nil, windowSeconds: week),
                fill(used: 28, at: base.addingTimeInterval(7_200), resetAt: reset),
                fill(used: 31, at: base.addingTimeInterval(10_800), resetAt: reset.addingTimeInterval(0.6))
            ],
            range: range()
        )
        XCTAssertEqual(series.actual.count, 1)
        XCTAssertEqual(series.actual[0].count, 4)
        XCTAssertEqual(series.pace.count, 1)
        XCTAssertEqual(series.pace[0].count, 2)
    }

    func testNilResetPointsStillSplitOnSamplingGap() {
        let series = QuotaHistorySeriesBuilder.build(
            fillPoints: [
                fill(used: 20, at: base, resetAt: nil, windowSeconds: week),
                fill(used: 24, at: base.addingTimeInterval(3_600), resetAt: nil, windowSeconds: week),
                // Beyond two hourly slots: coverage genuinely stopped.
                fill(
                    used: 61,
                    at: base.addingTimeInterval(TimeInterval(3 * 3_600 + 1)),
                    resetAt: nil,
                    windowSeconds: week
                )
            ],
            range: range()
        )
        XCTAssertEqual(series.actual.count, 2)
        XCTAssertEqual(series.actual[0].count, 2)
        XCTAssertEqual(series.actual[1].count, 1)
    }

    func testForecastToleratesJitteringResetEstimates() {
        let reset = base.addingTimeInterval(TimeInterval(week) / 2)
        let drifts: [TimeInterval] = [0.27, -0.63, 0.11]
        var points: [ForecastTimelinePoint] = []
        for (index, drift) in drifts.enumerated() {
            let at: Date = base.addingTimeInterval(TimeInterval(index) * 3_600)
            points.append(
                forecast(
                    projected: Double(50 + index),
                    lower: 40,
                    upper: 70,
                    at: at,
                    resetAt: reset.addingTimeInterval(drift)
                )
            )
        }
        let series = QuotaHistorySeriesBuilder.build(
            fillPoints: [],
            forecastPoints: points,
            range: range()
        )
        XCTAssertEqual(series.forecast.count, 1)
        XCTAssertEqual(series.forecast[0].count, 3)
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
