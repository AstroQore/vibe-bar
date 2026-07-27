import XCTest
@testable import VibeBarCore

final class ChartTimeWindowTests: XCTestCase {
    private let domainStart = Date(timeIntervalSince1970: 1_800_000_000)
    private var domainEnd: Date { domainStart.addingTimeInterval(30 * 86_400) }
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400

    private func window(
        visibleSpan: TimeInterval = 7 * 86_400,
        minimumSpan: TimeInterval = 3_600
    ) -> ChartTimeWindow {
        ChartTimeWindow(
            domainStart: domainStart,
            domainEnd: domainEnd,
            minimumSpan: minimumSpan,
            visibleSpan: visibleSpan
        )
    }

    // MARK: - Initialization and clamping

    func testSpanInitAnchorsAtDomainEnd() {
        let subject = window(visibleSpan: 7 * 86_400)
        XCTAssertEqual(subject.visibleEnd, domainEnd)
        XCTAssertEqual(subject.visibleStart, domainEnd.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(subject.visibleSpan, 7 * 86_400, accuracy: 0.001)
        XCTAssertTrue(subject.isAtDomainEnd)
        XCTAssertFalse(subject.isAtDomainStart)
    }

    func testVisibleRangeBeforeDomainIsPulledToDomainStart() {
        let subject = ChartTimeWindow(
            domainStart: domainStart,
            domainEnd: domainEnd,
            minimumSpan: hour,
            visibleStart: domainStart.addingTimeInterval(-100 * day),
            visibleEnd: domainStart.addingTimeInterval(-99 * day)
        )
        XCTAssertEqual(subject.visibleStart, domainStart)
        XCTAssertEqual(subject.visibleSpan, day, accuracy: 0.001)
    }

    func testVisibleRangeAfterDomainIsPulledToDomainEnd() {
        let subject = ChartTimeWindow(
            domainStart: domainStart,
            domainEnd: domainEnd,
            minimumSpan: hour,
            visibleStart: domainEnd.addingTimeInterval(10 * day),
            visibleEnd: domainEnd.addingTimeInterval(12 * day)
        )
        XCTAssertEqual(subject.visibleEnd, domainEnd)
        XCTAssertEqual(subject.visibleStart, domainEnd.addingTimeInterval(-2 * day))
    }

    func testVisibleSpanWiderThanDomainCollapsesToDomain() {
        let subject = window(visibleSpan: 400 * 86_400)
        XCTAssertEqual(subject.visibleStart, domainStart)
        XCTAssertEqual(subject.visibleEnd, domainEnd)
        XCTAssertTrue(subject.coversDomain)
    }

    func testVisibleSpanBelowMinimumIsWidened() {
        let subject = ChartTimeWindow(
            domainStart: domainStart,
            domainEnd: domainEnd,
            minimumSpan: 6 * hour,
            visibleStart: domainStart.addingTimeInterval(day),
            visibleEnd: domainStart.addingTimeInterval(day + 60)
        )
        XCTAssertEqual(subject.visibleSpan, 6 * hour, accuracy: 0.001)
    }

    func testMinimumSpanIsCappedByDomainSpan() {
        let shortDomainEnd = domainStart.addingTimeInterval(2 * hour)
        let subject = ChartTimeWindow(
            domainStart: domainStart,
            domainEnd: shortDomainEnd,
            minimumSpan: 30 * day,
            visibleSpan: hour
        )
        XCTAssertEqual(subject.effectiveMinimumSpan, 2 * hour, accuracy: 0.001)
        XCTAssertEqual(subject.visibleSpan, 2 * hour, accuracy: 0.001)
        XCTAssertTrue(subject.coversDomain)
    }

    func testDegenerateDomainCollapsesVisibleRange() {
        let subject = ChartTimeWindow(
            domainStart: domainStart,
            domainEnd: domainStart,
            minimumSpan: hour,
            visibleSpan: 7 * day
        )
        XCTAssertEqual(subject.domainSpan, 0)
        XCTAssertEqual(subject.visibleSpan, 0)
        XCTAssertEqual(subject.visibleStart, domainStart)
        XCTAssertEqual(subject.visibleEnd, domainStart)
    }

    func testInvertedDomainIsNormalized() {
        let subject = ChartTimeWindow(
            domainStart: domainEnd,
            domainEnd: domainStart,
            minimumSpan: hour,
            visibleSpan: day
        )
        XCTAssertEqual(subject.domainStart, domainEnd)
        XCTAssertEqual(subject.domainEnd, domainEnd)
        XCTAssertEqual(subject.domainSpan, 0)
    }

    // MARK: - Pan

    func testPanBackwardsKeepsSpan() {
        let subject = window(visibleSpan: 7 * day).panned(by: -3 * day)
        XCTAssertEqual(subject.visibleSpan, 7 * day, accuracy: 0.001)
        XCTAssertEqual(subject.visibleEnd, domainEnd.addingTimeInterval(-3 * day))
    }

    func testPanPastNewestEdgeParksAtDomainEnd() {
        let subject = window(visibleSpan: 7 * day).panned(by: 50 * day)
        XCTAssertEqual(subject.visibleEnd, domainEnd)
        XCTAssertEqual(subject.visibleSpan, 7 * day, accuracy: 0.001)
        XCTAssertTrue(subject.isAtDomainEnd)
    }

    func testPanPastOldestEdgeParksAtDomainStart() {
        let subject = window(visibleSpan: 7 * day).panned(by: -500 * day)
        XCTAssertEqual(subject.visibleStart, domainStart)
        XCTAssertEqual(subject.visibleSpan, 7 * day, accuracy: 0.001)
        XCTAssertTrue(subject.isAtDomainStart)
    }

    func testPanByZeroIsIdentity() {
        let subject = window(visibleSpan: 7 * day)
        XCTAssertEqual(subject.panned(by: 0), subject)
    }

    func testNonFinitePanIsIgnored() {
        let subject = window(visibleSpan: 7 * day)
        XCTAssertEqual(subject.panned(by: .infinity), subject)
    }

    // MARK: - Zoom

    func testZoomInHalvesSpanAndKeepsAnchorPosition() {
        let subject = window(visibleSpan: 8 * day)
        let anchor = subject.visibleStart.addingTimeInterval(2 * day) // 25% across
        let zoomed = subject.zoomed(scale: 2, around: anchor)
        XCTAssertEqual(zoomed.visibleSpan, 4 * day, accuracy: 0.001)
        let fraction = anchor.timeIntervalSince(zoomed.visibleStart) / zoomed.visibleSpan
        XCTAssertEqual(fraction, 0.25, accuracy: 0.0001)
    }

    func testZoomOutWidensSpanAndClampsToDomain() {
        let subject = window(visibleSpan: 8 * day).panned(by: -5 * day)
        let zoomed = subject.zoomed(scale: 0.25, around: subject.visibleMidpoint)
        XCTAssertEqual(zoomed.visibleSpan, 30 * day, accuracy: 0.001)
        XCTAssertTrue(zoomed.coversDomain)
    }

    func testZoomInStopsAtMinimumSpan() {
        let subject = window(visibleSpan: 8 * day, minimumSpan: 6 * hour)
        let zoomed = subject.zoomed(scale: 1_000, around: subject.visibleMidpoint)
        XCTAssertEqual(zoomed.visibleSpan, 6 * hour, accuracy: 0.001)
    }

    func testZoomAnchoredAtNewestEdgeStaysAtNewestEdge() {
        let subject = window(visibleSpan: 8 * day)
        let zoomed = subject.zoomed(scale: 4, around: subject.visibleEnd)
        XCTAssertEqual(zoomed.visibleEnd, domainEnd)
        XCTAssertEqual(zoomed.visibleSpan, 2 * day, accuracy: 0.001)
    }

    func testZoomAnchorOutsideVisibleRangeIsClampedToIt() {
        let subject = window(visibleSpan: 8 * day)
        let outside = domainStart.addingTimeInterval(-100 * day)
        let zoomed = subject.zoomed(scale: 2, around: outside)
        // Anchor clamps to visibleStart, so the left edge is preserved.
        XCTAssertEqual(zoomed.visibleStart, subject.visibleStart)
        XCTAssertEqual(zoomed.visibleSpan, 4 * day, accuracy: 0.001)
    }

    func testNonPositiveZoomScaleIsIgnored() {
        let subject = window(visibleSpan: 8 * day)
        XCTAssertEqual(subject.zoomed(scale: 0, around: subject.visibleMidpoint), subject)
        XCTAssertEqual(subject.zoomed(scale: -2, around: subject.visibleMidpoint), subject)
        XCTAssertEqual(subject.zoomed(scale: .nan, around: subject.visibleMidpoint), subject)
    }

    // MARK: - Jump

    func testJumpAnchorsPresetSpanToDomainEnd() {
        let subject = window(visibleSpan: 7 * day)
            .panned(by: -20 * day)
            .jumped(toSpan: day)
        XCTAssertEqual(subject.visibleEnd, domainEnd)
        XCTAssertEqual(subject.visibleSpan, day, accuracy: 0.001)
    }

    func testJumpBeyondDomainShowsWholeDomain() {
        let subject = window(visibleSpan: day).jumped(toSpan: 365 * day)
        XCTAssertTrue(subject.coversDomain)
        XCTAssertEqual(subject.visibleSpan, 30 * day, accuracy: 0.001)
    }

    func testJumpBelowMinimumSpanIsWidened() {
        let subject = window(visibleSpan: 7 * day, minimumSpan: 6 * hour).jumped(toSpan: 60)
        XCTAssertEqual(subject.visibleSpan, 6 * hour, accuracy: 0.001)
        XCTAssertEqual(subject.visibleEnd, domainEnd)
    }

    // MARK: - Mutating variants and progress

    func testMutatingOperationsMatchPureOnes() {
        var subject = window(visibleSpan: 8 * day)
        let anchor = subject.visibleStart
        let expected = subject.panned(by: -2 * day).zoomed(scale: 2, around: anchor)
        subject.pan(by: -2 * day)
        subject.zoom(scale: 2, around: anchor)
        XCTAssertEqual(subject, expected)
    }

    func testScrollProgressSpansZeroToOne() {
        let newest = window(visibleSpan: 7 * day)
        XCTAssertEqual(newest.scrollProgress, 1, accuracy: 0.0001)
        let oldest = newest.panned(by: -500 * day)
        XCTAssertEqual(oldest.scrollProgress, 0, accuracy: 0.0001)
        let full = newest.jumped(toSpan: 400 * day)
        XCTAssertEqual(full.scrollProgress, 1, accuracy: 0.0001)
    }
}
