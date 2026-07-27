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
