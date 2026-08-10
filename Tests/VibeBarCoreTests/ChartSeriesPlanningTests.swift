import XCTest
@testable import VibeBarCore

final class ChartMarkBudgetTests: XCTestCase {
    // MARK: - Allocation

    func testSeriesAlreadyInsideBudgetIsLeftAlone() {
        // Thinning a series that does not need it only costs fidelity.
        let counts = [4, 9, 2]
        XCTAssertEqual(ChartMarkBudget.allocate(segmentCounts: counts, budget: 100), counts)
    }

    func testManySmallSegmentsStayInsideTheBudget() {
        // The regression this exists for: a five-hour quota over months of
        // history is hundreds of segments, each individually smaller than the
        // budget. Thinning them one at a time meant every one passed through
        // untouched and the curve rendered segmentCount × budget marks.
        let counts = Array(repeating: 60, count: 300)   // 18,000 points
        let allowance = ChartMarkBudget.allocate(segmentCounts: counts, budget: 900)
        XCTAssertEqual(allowance.count, counts.count)
        XCTAssertLessThanOrEqual(allowance.reduce(0, +), 900)
        XCTAssertTrue(allowance.allSatisfy { $0 >= ChartMarkBudget.minimumSegmentPoints })
    }

    func testBudgetIsSpentAlmostExactlyRatherThanDriftingLow() {
        let counts = [130, 47, 900, 3, 61]
        let allowance = ChartMarkBudget.allocate(segmentCounts: counts, budget: 400)
        XCTAssertEqual(allowance.reduce(0, +), 400)
    }

    func testShareIsProportionalToHowMuchOfTheCurveASegmentIs() {
        let allowance = ChartMarkBudget.allocate(segmentCounts: [900, 100], budget: 200)
        XCTAssertEqual(allowance.reduce(0, +), 200)
        XCTAssertGreaterThan(allowance[0], allowance[1])
        // Roughly 9:1, allowing for the two-point floors coming off the top.
        XCTAssertEqual(Double(allowance[0]) / Double(allowance[1]), 9, accuracy: 1.5)
    }

    func testNoSegmentIsAllocatedMoreThanItHas() {
        let counts = [3, 3, 5_000]
        let allowance = ChartMarkBudget.allocate(segmentCounts: counts, budget: 600)
        for (allowed, count) in zip(allowance, counts) {
            XCTAssertLessThanOrEqual(allowed, count)
        }
        XCTAssertLessThanOrEqual(allowance.reduce(0, +), 600)
    }

    func testEverySegmentKeepsAtLeastItsTwoEndpoints() {
        // Segment endpoints are what the bridging connectors attach to, so
        // thinning must never be able to strand a bridge.
        let allowance = ChartMarkBudget.allocate(
            segmentCounts: Array(repeating: 40, count: 50),
            budget: 60
        )
        XCTAssertTrue(allowance.allSatisfy { $0 == ChartMarkBudget.minimumSegmentPoints })
    }

    func testSingletonSegmentsKeepTheirOnlyPoint() {
        let allowance = ChartMarkBudget.allocate(segmentCounts: [1, 1, 500], budget: 20)
        XCTAssertEqual(allowance[0], 1)
        XCTAssertEqual(allowance[1], 1)
        XCTAssertLessThanOrEqual(allowance.reduce(0, +), 20)
    }

    func testFloorsWinWhenTheyAlreadyExceedTheBudget() {
        // Deliberately over budget: dropping segments would delete evidence,
        // and two marks each is already the cheapest honest rendering.
        let allowance = ChartMarkBudget.allocate(
            segmentCounts: Array(repeating: 9, count: 100),
            budget: 50
        )
        XCTAssertEqual(allowance, Array(repeating: 2, count: 100))
    }

    func testEmptyAndZeroBudgetInputsAreHandled() {
        XCTAssertEqual(ChartMarkBudget.allocate(segmentCounts: [], budget: 100), [])
        XCTAssertEqual(ChartMarkBudget.allocate(segmentCounts: [5, 5], budget: 0), [5, 5])
    }

    // MARK: - Allocation applied

    func testThinnedKeepsWholeCurveInsideBudgetAndPreservesEndpoints() {
        let segments = (0..<40).map { segment in
            (0..<120).map { point in segment * 1_000 + point }
        }
        let thinned = ChartMarkBudget.thinned(segments, budget: 500)
        XCTAssertLessThanOrEqual(thinned.reduce(0) { $0 + $1.count }, 500)
        for (original, drawn) in zip(segments, thinned) {
            XCTAssertEqual(drawn.first, original.first)
            XCTAssertEqual(drawn.last, original.last)
        }
    }

    func testThinnedLeavesAShortCurveUntouched() {
        let segments = [[1, 2, 3], [4, 5]]
        XCTAssertEqual(ChartMarkBudget.thinned(segments, budget: 500), segments)
    }

    // MARK: - Striding

    func testStridedKeepsBothEndpointsAndRespectsTheLimit() {
        let elements = Array(0..<1_000)
        let thinned = ChartSeriesThinning.strided(elements, limit: 37)
        XCTAssertLessThanOrEqual(thinned.count, 37)
        XCTAssertEqual(thinned.first, 0)
        XCTAssertEqual(thinned.last, 999)
        XCTAssertEqual(thinned, thinned.sorted())
    }

    func testUsageDownsamplingPreservesExactEndpointsPeaksAndMarkBudget() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var input: [UsageTrendPoint] = []
        for index in 0..<100 {
            let tokens: Int64 = index == 37 ? 10_000 : 10
            let output: Int64 = index == 37 ? 1_000 : 1
            let cost: Int64 = index == 61 ? 900_000 : 100
            input.append(
                UsageTrendPoint(
                    bucketStart: base.addingTimeInterval(TimeInterval(index * 3_600)),
                    freshInput: tokens,
                    output: output,
                    cacheRead: 0,
                    cacheCreation: 0,
                    costMicros: cost
                )
            )
        }

        let projected = UsageTrendSeriesDownsampling.points(input, limit: 15)
        let tokenPeak = input[37]
        let costPeak = input[61]
        let timestamps: [Date] = projected.map { $0.bucketStart }

        XCTAssertLessThanOrEqual(projected.count, 15)
        XCTAssertEqual(projected.first, input.first)
        XCTAssertEqual(projected.last, input.last)
        XCTAssertTrue(projected.contains(tokenPeak))
        XCTAssertTrue(projected.contains(costPeak))
        XCTAssertTrue(projected.allSatisfy { input.contains($0) })
        XCTAssertEqual(timestamps, timestamps.sorted())
    }

    func testUsageDownsamplingHonorsSmallBudgetsWithDocumentedPriorities() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let input = [
            UsageTrendPoint(bucketStart: base, freshInput: 1, output: 0, cacheRead: 0, cacheCreation: 0, costMicros: 1),
            UsageTrendPoint(bucketStart: base.addingTimeInterval(3_600), freshInput: 100, output: 0, cacheRead: 0, cacheCreation: 0, costMicros: 2),
            UsageTrendPoint(bucketStart: base.addingTimeInterval(7_200), freshInput: 2, output: 0, cacheRead: 0, cacheCreation: 0, costMicros: 100),
            UsageTrendPoint(bucketStart: base.addingTimeInterval(10_800), freshInput: 3, output: 0, cacheRead: 0, cacheCreation: 0, costMicros: 3)
        ]

        XCTAssertEqual(UsageTrendSeriesDownsampling.points(input, limit: 1), [input[1]])
        XCTAssertEqual(UsageTrendSeriesDownsampling.points(input, limit: 2), [input[0], input[3]])
        XCTAssertEqual(UsageTrendSeriesDownsampling.points(input, limit: 3), [input[0], input[1], input[3]])
        XCTAssertEqual(UsageTrendSeriesDownsampling.points(input, limit: 4), input)
    }
}

final class ChartSampleSearchTests: XCTestCase {
    private struct Sample {
        let time: Date
        let value: Int
    }

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func samples(_ offsets: [TimeInterval]) -> [Sample] {
        offsets.enumerated().map { Sample(time: base.addingTimeInterval($0.element), value: $0.offset) }
    }

    func testFindsTheNearestSampleOnEitherSide() {
        let sorted = samples([0, 300, 600, 900])
        let before = ChartSampleSearch.nearest(
            in: sorted, to: base.addingTimeInterval(340), tolerance: 600, time: { $0.time }
        )
        let after = ChartSampleSearch.nearest(
            in: sorted, to: base.addingTimeInterval(560), tolerance: 600, time: { $0.time }
        )
        XCTAssertEqual(before?.value, 1)
        XCTAssertEqual(after?.value, 2)
    }

    func testExactHitsAndTheArrayEdgesResolve() {
        let sorted = samples([0, 300, 600])
        XCTAssertEqual(
            ChartSampleSearch.nearest(
                in: sorted, to: base.addingTimeInterval(300), tolerance: 1, time: { $0.time }
            )?.value,
            1
        )
        XCTAssertEqual(
            ChartSampleSearch.nearest(
                in: sorted, to: base.addingTimeInterval(-10), tolerance: 60, time: { $0.time }
            )?.value,
            0
        )
        XCTAssertEqual(
            ChartSampleSearch.nearest(
                in: sorted, to: base.addingTimeInterval(610), tolerance: 60, time: { $0.time }
            )?.value,
            2
        )
    }

    func testNothingIsReturnedBeyondTheTolerance() {
        // A gap is information: the hover must say "nothing here" rather than
        // reach across it for whichever sample happens to be closest.
        let sorted = samples([0, 86_400])
        XCTAssertNil(
            ChartSampleSearch.nearest(
                in: sorted, to: base.addingTimeInterval(43_200), tolerance: 600, time: { $0.time }
            )
        )
        XCTAssertNil(
            ChartSampleSearch.nearest(
                in: [], to: base, tolerance: 600, time: { (_: Sample) in base }
            )
        )
    }

    func testMatchesAnExhaustiveScanAcrossTheWholeArray() {
        let sorted = samples(stride(from: 0, to: 400 * 300, by: 300).map(TimeInterval.init))
        let tolerance: TimeInterval = 900
        for step in stride(from: -1_000, through: 400 * 300 + 1_000, by: 617) {
            let target = base.addingTimeInterval(TimeInterval(step))
            let expected = sorted
                .filter { abs($0.time.timeIntervalSince(target)) <= tolerance }
                .min { abs($0.time.timeIntervalSince(target)) < abs($1.time.timeIntervalSince(target)) }
            let actual = ChartSampleSearch.nearest(
                in: sorted, to: target, tolerance: tolerance, time: { $0.time }
            )
            XCTAssertEqual(actual?.value, expected?.value, "target offset \(step)")
        }
    }
}

final class ChartSegmentClipTests: XCTestCase {
    private struct Sample {
        let time: Date
        let value: Int
    }

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func samples(_ offsets: [TimeInterval]) -> [Sample] {
        offsets.enumerated().map { Sample(time: base.addingTimeInterval($0.element), value: $0.offset) }
    }

    private func range(_ from: TimeInterval, _ to: TimeInterval) -> ClosedRange<Date> {
        base.addingTimeInterval(from)...base.addingTimeInterval(to)
    }

    private func clip(_ segment: [Sample], _ window: ClosedRange<Date>) -> [Int] {
        ChartSegmentClip.visible(segment, time: { $0.time }, to: window).map(\.value)
    }

    func testKeepsOneSampleBeyondEachEdge() {
        // So a line entering the window starts at the frame border rather than
        // at its first visible observation.
        let segment = samples([0, 300, 600, 900, 1_200])
        XCTAssertEqual(clip(segment, range(400, 800)), [1, 2, 3])
    }

    func testSegmentCrossingTheWindowWithNoSampleInsideStillDraws() {
        // The regression this exists for. An hourly-slotted weekly lane can
        // step straight over a window a user zoomed into; dropping the segment
        // erased the whole curve while the five-minute-slotted five-hour lane
        // beside it drew normally.
        let segment = samples([0, 3_600, 7_200])
        XCTAssertEqual(clip(segment, range(4_000, 5_000)), [1, 2])
    }

    func testDailySlotsSurviveASixHourWindow() {
        // A quota whose window length the provider never reported is filed into
        // daily slots, so almost every window a user would open contains none
        // of its samples at all.
        let segment = samples([0, 86_400, 172_800])
        let sixHoursIn = range(30 * 3_600, 36 * 3_600)
        XCTAssertEqual(clip(segment, sixHoursIn), [1, 2])
    }

    func testNoCoverageNearTheWindowDrawsNothing() {
        // A hole is information: only a segment that actually crosses the
        // window is kept, never the nearest samples on one side of it.
        let before = samples([0, 300])
        XCTAssertEqual(clip(before, range(10_000, 20_000)), [])
        let after = samples([30_000, 30_300])
        XCTAssertEqual(clip(after, range(10_000, 20_000)), [])
        XCTAssertEqual(clip([], range(0, 100)), [])
    }

    func testSingleSampleSegmentsAreNotInventedIntoLines() {
        // One observation is one observation, whichever side of the window it
        // sits on — the straddle rule needs a pair or it declines.
        XCTAssertEqual(clip(samples([0]), range(1_000, 2_000)), [])
        XCTAssertEqual(clip(samples([1_500]), range(1_000, 2_000)), [0])
    }

    func testSamplesOnTheBoundaryCountAsInside() {
        let segment = samples([0, 300, 600])
        XCTAssertEqual(clip(segment, range(300, 600)), [0, 1, 2])
    }
}

final class ChartHoverToleranceTests: XCTestCase {
    /// Widest spacing a lane's own samples can have: its slot width, or the
    /// refresh cadence when that is slower.
    private func spacing(windowSeconds: Int?) -> TimeInterval {
        max(
            UsageTimelineSlotPolicy.slotSeconds(windowSeconds: windowSeconds),
            TimeInterval(AppSettings.slowestRefreshIntervalSeconds)
        )
    }

    func testEveryLaneResolvesASampleHalfItsOwnRhythmAway() {
        // The defect: one tolerance for the whole chart. A cursor parked
        // between two of a lane's consecutive samples has to resolve to one of
        // them, whatever that lane's sampling rhythm is.
        for window: Int? in [18_000, 604_800, 30 * 86_400, 90 * 86_400, nil] {
            let tolerance = ChartHoverTolerance.seconds(
                windowSeconds: window,
                visibleSpan: 6 * 3_600
            )
            XCTAssertGreaterThanOrEqual(
                tolerance,
                spacing(windowSeconds: window) / 2,
                "window \(String(describing: window))"
            )
        }
    }

    func testSparseLanesGetAWiderToleranceThanDenseOnes() {
        let visibleSpan: TimeInterval = 6 * 3_600
        let fiveHour = ChartHoverTolerance.seconds(windowSeconds: 18_000, visibleSpan: visibleSpan)
        let weekly = ChartHoverTolerance.seconds(windowSeconds: 604_800, visibleSpan: visibleSpan)
        let monthly = ChartHoverTolerance.seconds(windowSeconds: 30 * 86_400, visibleSpan: visibleSpan)
        XCTAssertLessThan(fiveHour, weekly)
        XCTAssertLessThan(weekly, monthly)
    }

    func testAWeeklyLaneNoLongerMissesOnAFiveHourSizedTolerance() {
        // Reproduces the reported hover: a six-hour view of a group whose
        // shortest window is five hours. The old tolerance came from that
        // shortest window (five-minute slots), so an hourly-slotted weekly
        // sample half an hour from the cursor was reported as no reading at
        // all while its line was drawn under the crosshair.
        let visibleSpan: TimeInterval = 6 * 3_600
        let old = max(UsageTimelineSlotPolicy.slotSeconds(windowSeconds: 18_000) * 2, visibleSpan / 80)
        let cursor = Date(timeIntervalSince1970: 1_800_000_000)
        let weeklySamples = [cursor.addingTimeInterval(-1_800), cursor.addingTimeInterval(1_800)]

        XCTAssertNil(
            ChartSampleSearch.nearest(in: weeklySamples, to: cursor, tolerance: old, time: { $0 })
        )
        XCTAssertNotNil(
            ChartSampleSearch.nearest(
                in: weeklySamples,
                to: cursor,
                tolerance: ChartHoverTolerance.seconds(
                    windowSeconds: 604_800,
                    visibleSpan: visibleSpan
                ),
                time: { $0 }
            )
        )
    }

    func testZoomingOutWidensTheToleranceButZoomingInNeverGoesBelowTheRhythm() {
        let wide = ChartHoverTolerance.seconds(windowSeconds: 18_000, visibleSpan: 60 * 86_400)
        XCTAssertGreaterThan(wide, 60 * 86_400 / 100)
        let tight = ChartHoverTolerance.seconds(windowSeconds: 604_800, visibleSpan: 0)
        XCTAssertEqual(tight, spacing(windowSeconds: 604_800) * ChartHoverTolerance.cadenceFraction)
    }

    func testAFastLaneStillCoversTheSlowestRefreshCadenceAUserCanPick() {
        // Five-minute slots do not mean five-minute samples: on the slowest
        // cadence the picker offers, even a five-hour lane is sampled half an
        // hour apart, and the hover has to survive that.
        let tolerance = ChartHoverTolerance.seconds(windowSeconds: 18_000, visibleSpan: 3_600)
        XCTAssertGreaterThanOrEqual(
            tolerance,
            TimeInterval(AppSettings.slowestRefreshIntervalSeconds) / 2
        )
    }
}
