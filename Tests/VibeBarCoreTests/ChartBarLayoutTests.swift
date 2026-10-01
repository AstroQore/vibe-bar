import XCTest
@testable import VibeBarCore

final class ChartBarLayoutTests: XCTestCase {
    private let plotWidths: [Double] = [300, 700, 1_340]
    private let bucketCounts: [Double] = [1, 7, 30, 168, 5_000]

    // MARK: - Bar width

    func testWidthMatrixStaysInsideItsSlotAndCap() {
        for plot in plotWidths {
            for count in bucketCounts {
                let slot = ChartBarLayout.slotWidth(plotWidth: plot, slotCount: count)
                let width = ChartBarLayout.barWidth(plotWidth: plot, slotCount: count)
                XCTAssertGreaterThanOrEqual(width, ChartBarLayout.minimumWidth, "\(plot)×\(count)")
                XCTAssertLessThanOrEqual(width, ChartBarLayout.defaultMaximumWidth, "\(plot)×\(count)")
                if slot >= ChartBarLayout.minimumWidth + ChartBarLayout.minimumGap {
                    // Room for a gap: neighbours never touch.
                    XCTAssertLessThanOrEqual(width, slot - ChartBarLayout.minimumGap, "\(plot)×\(count)")
                }
            }
        }
    }

    func testSparseBarsFillMostOfTheirSlotUpToTheCap() {
        // The reported case: a week of daily bars on a wide chart drew 22pt
        // posts 190pt apart. Now each bar takes its share, capped.
        XCTAssertEqual(ChartBarLayout.barWidth(plotWidth: 1_340, slotCount: 7), 44)
        XCTAssertEqual(ChartBarLayout.barWidth(plotWidth: 300, slotCount: 7), 30, accuracy: 0.01)
        // A month of days at a wide window: 70% of a ~45pt slot.
        let slot = 1_340.0 / 30
        XCTAssertEqual(ChartBarLayout.barWidth(plotWidth: 1_340, slotCount: 30), slot * 0.7, accuracy: 0.01)
        // A single bucket never becomes a wall.
        XCTAssertEqual(ChartBarLayout.barWidth(plotWidth: 1_340, slotCount: 1), 44)
    }

    func testDenseBarsNearlyFillTheirSlot() {
        // 168 hourly bars across a wide chart: the old rule drew 2pt hairs in
        // an 8pt slot. Now they leave about a point and a bit between them.
        let slot = 1_340.0 / 168
        let width = ChartBarLayout.barWidth(plotWidth: 1_340, slotCount: 168)
        XCTAssertEqual(width, slot * 0.85, accuracy: 0.01)
        XCTAssertGreaterThan(width, 6)
        XCTAssertLessThan(slot - width, 1.5)
    }

    func testOverDenseBarsKeepAVisibleFloor() {
        XCTAssertEqual(ChartBarLayout.barWidth(plotWidth: 1_340, slotCount: 5_000), ChartBarLayout.minimumWidth)
        XCTAssertEqual(ChartBarLayout.barWidth(plotWidth: 300, slotCount: 168), ChartBarLayout.minimumWidth)
    }

    func testFillEasesWithoutJumps() {
        // Resizing a window must not make bars snap: sweep slot widths and
        // check the bar never shrinks as its slot grows.
        var previous = 0.0
        for tenth in 10...600 {
            let slot = Double(tenth) / 10
            let width = ChartBarLayout.barWidth(plotWidth: slot, slotCount: 1, maximumWidth: 1_000)
            XCTAssertGreaterThanOrEqual(width + 1e-9, previous, "slot \(slot)")
            previous = width
        }
    }

    func testZoomingInWidensBars() {
        // The brush narrows the visible span, so fewer slots share the plot.
        let full = ChartBarLayout.barWidth(plotWidth: 1_340, slotCount: 168)
        let zoomed = ChartBarLayout.barWidth(plotWidth: 1_340, slotCount: 24)
        XCTAssertGreaterThan(zoomed, full * 4)
    }

    func testDegenerateInputsFallBackToTheFloor() {
        XCTAssertEqual(ChartBarLayout.barWidth(plotWidth: 0, slotCount: 7), ChartBarLayout.minimumWidth)
        XCTAssertEqual(ChartBarLayout.barWidth(plotWidth: 700, slotCount: .nan), ChartBarLayout.minimumWidth)
        // Less than one slot counts as one.
        XCTAssertEqual(ChartBarLayout.slotWidth(plotWidth: 700, slotCount: 0.2), 700)
    }

    // MARK: - Label stride

    func testLabelStrideUsesCalendarSteps() {
        let hourSteps = UsageTrendBucket.hour.axisLabelSteps
        // 168 hourly slots at ~8pt need ≥ 60pt between labels → every 12 h.
        XCTAssertEqual(ChartBarLayout.labelStride(slotWidth: 1_340.0 / 168, minimumLabelSpacing: 60, steps: hourSteps), 12)
        // Seven roomy daily slots label every day.
        XCTAssertEqual(ChartBarLayout.labelStride(
            slotWidth: 1_340.0 / 7, minimumLabelSpacing: 60, steps: UsageTrendBucket.day.axisLabelSteps
        ), 1)
        // 90 days at ~15pt → every 7 days.
        XCTAssertEqual(ChartBarLayout.labelStride(
            slotWidth: 1_340.0 / 90, minimumLabelSpacing: 60, steps: UsageTrendBucket.day.axisLabelSteps
        ), 7)
    }

    func testLabelStrideBeyondTheLargestStepUsesItsMultiples() {
        // 5 000 hourly slots on 300pt need ~1 000 buckets per label.
        let stride = ChartBarLayout.labelStride(
            slotWidth: 300.0 / 5_000, minimumLabelSpacing: 60, steps: UsageTrendBucket.hour.axisLabelSteps
        )
        XCTAssertEqual(stride % 168, 0)
        XCTAssertGreaterThanOrEqual(Double(stride) * 300.0 / 5_000, 60)
    }

    func testLabelStrideNeverDropsBelowOne() {
        XCTAssertEqual(ChartBarLayout.labelStride(slotWidth: 0, minimumLabelSpacing: 60, steps: [1, 2]), 1)
        XCTAssertEqual(ChartBarLayout.labelStride(slotWidth: 500, minimumLabelSpacing: 60, steps: []), 1)
        XCTAssertEqual(ChartBarLayout.labelStride(slotWidth: 10, minimumLabelSpacing: 60, steps: []), 6)
    }

    // MARK: - Automatic granularity

    func testAutomaticBucketKeepsBarCountsInTheTens() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        func bucket(days: Double, width: Double) -> UsageTrendBucket {
            UsageTrendBucket.recommended(
                for: DateInterval(start: start, duration: days * 86_400),
                chartWidth: width
            )
        }
        // A wide (~1 400pt) chart.
        XCTAssertEqual(bucket(days: 1, width: 1_400), .hour)        // 24 bars
        XCTAssertEqual(bucket(days: 7, width: 1_400), .sixHours)    // 28 bars, was 168 hourly
        XCTAssertEqual(bucket(days: 14, width: 1_400), .sixHours)   // 56 bars
        XCTAssertEqual(bucket(days: 30, width: 1_400), .day)        // 30 bars
        XCTAssertEqual(bucket(days: 90, width: 1_400), .day)        // 90 bars
        XCTAssertEqual(bucket(days: 365, width: 1_400), .week)      // 53 bars
        // A narrower (~700pt) chart coarsens sooner.
        XCTAssertEqual(bucket(days: 7, width: 700), .sixHours)      // 28 bars
        XCTAssertEqual(bucket(days: 14, width: 700), .day)          // 14 bars
        XCTAssertEqual(bucket(days: 90, width: 700), .week)         // 13 bars
        // No width yet: the width-blind rule.
        XCTAssertEqual(bucket(days: 7, width: 0), .day)
    }
}
