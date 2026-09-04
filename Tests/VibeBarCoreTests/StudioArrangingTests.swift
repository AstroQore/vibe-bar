import XCTest
@testable import VibeBarCore

final class StudioArrangingTests: XCTestCase {
    private let a = PageLayoutModuleID("a")
    private let b = PageLayoutModuleID("b")
    private let c = PageLayoutModuleID("c")
    private let d = PageLayoutModuleID("d")

    /// Two columns, 100 wide each with a 12 gutter; a/b stacked left, c/d right.
    private let ranges: [ClosedRange<CGFloat>] = [0...100, 112...212]
    private var columns: [[PageLayoutModuleID]] { [[a, b], [c, d]] }
    private var frames: [PageLayoutModuleID: CGRect] {
        [
            a: CGRect(x: 0, y: 0, width: 100, height: 100),
            b: CGRect(x: 0, y: 110, width: 100, height: 60),
            c: CGRect(x: 112, y: 0, width: 100, height: 40),
            d: CGRect(x: 112, y: 50, width: 100, height: 200)
        ]
    }

    // MARK: - Column slots

    func testPointerAboveACardsCentreLandsBeforeIt() {
        let slot = StudioArranging.columnSlot(
            at: CGPoint(x: 50, y: 20), columnRanges: ranges,
            columns: columns, frames: frames, dragging: d
        )
        XCTAssertEqual(slot, .init(column: 0, index: 0))
    }

    func testPointerBelowACardsCentreLandsAfterIt() {
        let slot = StudioArranging.columnSlot(
            at: CGPoint(x: 50, y: 60), columnRanges: ranges,
            columns: columns, frames: frames, dragging: d
        )
        XCTAssertEqual(slot, .init(column: 0, index: 1))
    }

    func testPointerBelowEveryCardAppends() {
        let slot = StudioArranging.columnSlot(
            at: CGPoint(x: 50, y: 400), columnRanges: ranges,
            columns: columns, frames: frames, dragging: d
        )
        XCTAssertEqual(slot, .init(column: 0, index: 2))
    }

    func testTheDraggedCardDoesNotCountAmongTheOthers() {
        // Dragging `b` within its own column: only `a` is an "other".
        let slot = StudioArranging.columnSlot(
            at: CGPoint(x: 50, y: 130), columnRanges: ranges,
            columns: columns, frames: frames, dragging: b
        )
        XCTAssertEqual(slot, .init(column: 0, index: 1))
    }

    func testGutterGoesToTheNearerColumnAndOverflowClamps() {
        XCTAssertEqual(StudioArranging.nearestColumn(to: 104, ranges: ranges), 0)
        XCTAssertEqual(StudioArranging.nearestColumn(to: 109, ranges: ranges), 1)
        XCTAssertEqual(StudioArranging.nearestColumn(to: -40, ranges: ranges), 0)
        XCTAssertEqual(StudioArranging.nearestColumn(to: 900, ranges: ranges), 1)
    }

    func testCardsWithoutFramesAreSkippedNotGuessed() {
        var partial = frames
        partial.removeValue(forKey: a)
        let slot = StudioArranging.columnSlot(
            at: CGPoint(x: 50, y: 20), columnRanges: ranges,
            columns: columns, frames: partial, dragging: d
        )
        // `a` cannot catch the pointer; `b` (centre 140) can, and 20 < 140.
        XCTAssertEqual(slot, .init(column: 0, index: 1))
    }

    // MARK: - Moving

    func testColumnsMovingRemovesFirstSoNothingDuplicates() {
        let moved = StudioArranging.columnsMoving(d, to: .init(column: 0, index: 1), in: columns)
        XCTAssertEqual(moved, [[a, d, b], [c]])
    }

    func testColumnsMovingClampsAndInsertsANewcomer() {
        let newcomer = PageLayoutModuleID("x")
        let moved = StudioArranging.columnsMoving(newcomer, to: .init(column: 7, index: 99), in: columns)
        XCTAssertEqual(moved, [[a, b], [c, d, newcomer]])
    }

    func testColumnsRemovingTakesTheCardOut() {
        XCTAssertEqual(StudioArranging.columnsRemoving(c, from: columns), [[a, b], [d]])
    }

    // MARK: - Segments

    func testDroppedCardJoinsTheSegmentOfTheCardAboveIt() {
        let segments = [[a, c], [b, d]]
        let moved = StudioArranging.columnsMoving(d, to: .init(column: 0, index: 1), in: columns)
        let next = StudioArranging.segmentsAfterMove(d, columns: moved, segments: segments)
        XCTAssertEqual(next, [[a, c, d], [b]])
    }

    func testDroppedCardAtTheTopJoinsTheCardBelowIt() {
        let segments = [[a, c], [b, d]]
        let moved = StudioArranging.columnsMoving(a, to: .init(column: 1, index: 0), in: columns)
        let next = StudioArranging.segmentsAfterMove(a, columns: moved, segments: segments)
        // `a` now sits above `c`, whose segment is the first — so no change.
        XCTAssertEqual(next, [[c, a], [b, d]])
    }

    func testDroppedCardIntoAnEmptyColumnKeepsItsSegment() {
        let segments = [[a], [b]]
        let next = StudioArranging.segmentsAfterMove(b, columns: [[a], [b]], segments: segments)
        XCTAssertEqual(next, [[a], [b]])
    }

    func testSingleSegmentIsLeftAlone() {
        let segments = [[a, b, c, d]]
        XCTAssertEqual(StudioArranging.segmentsAfterMove(d, columns: [[d, a, b], [c]], segments: segments), segments)
    }

    // MARK: - Reading orders

    private let rowFrames: [String: CGRect] = [
        "p": CGRect(x: 0, y: 0, width: 60, height: 100),
        "q": CGRect(x: 70, y: 0, width: 60, height: 100),
        "r": CGRect(x: 140, y: 0, width: 60, height: 100)
    ]

    func testHoveringACellsLeftHalfLandsBeforeIt() {
        let slot = StudioArranging.linearSlot(
            at: CGPoint(x: 80, y: 50), order: ["p", "q", "r"],
            frames: rowFrames, dragging: "r", axis: .horizontal
        )
        XCTAssertEqual(slot, 1)
    }

    func testHoveringACellsRightHalfLandsAfterIt() {
        let slot = StudioArranging.linearSlot(
            at: CGPoint(x: 120, y: 50), order: ["p", "q", "r"],
            frames: rowFrames, dragging: "r", axis: .horizontal
        )
        XCTAssertEqual(slot, 2)
    }

    func testAGapUsesTheNearestCell() {
        // Between p (centre 30) and q (centre 100), closer to q's left half.
        let slot = StudioArranging.linearSlot(
            at: CGPoint(x: 66, y: 50), order: ["p", "q", "r"],
            frames: rowFrames, dragging: "r", axis: .horizontal
        )
        XCTAssertEqual(slot, 1)
    }

    func testVerticalAxisReadsTheOtherCoordinate() {
        let frames = [
            "p": CGRect(x: 0, y: 0, width: 200, height: 20),
            "q": CGRect(x: 0, y: 24, width: 200, height: 20)
        ]
        XCTAssertEqual(
            StudioArranging.linearSlot(at: CGPoint(x: 100, y: 30), order: ["p", "q"], frames: frames, dragging: "z", axis: .vertical),
            1
        )
        XCTAssertEqual(
            StudioArranging.linearSlot(at: CGPoint(x: 100, y: 40), order: ["p", "q"], frames: frames, dragging: "z", axis: .vertical),
            2
        )
    }

    func testEntriesWithoutFramesKeepTheirPlaceButNeverCatchThePointer() {
        // "hidden" sits between p and q in the order but draws nothing.
        let slot = StudioArranging.linearSlot(
            at: CGPoint(x: 80, y: 50), order: ["p", "hidden", "q", "r"],
            frames: rowFrames, dragging: "r", axis: .horizontal
        )
        // Before q, which is index 2 among the others.
        XCTAssertEqual(slot, 2)
    }

    func testEmptyOrderAndNoFramesDegradeGracefully() {
        XCTAssertEqual(StudioArranging.linearSlot(at: .zero, order: [], frames: [:], dragging: "x", axis: .horizontal), 0)
        XCTAssertEqual(StudioArranging.linearSlot(at: .zero, order: ["p", "q"], frames: [:], dragging: "x", axis: .horizontal), 2)
    }

    func testOrderMovingClampsAndDedupes() {
        XCTAssertEqual(StudioArranging.orderMoving("r", to: 0, in: ["p", "q", "r"]), ["r", "p", "q"])
        XCTAssertEqual(StudioArranging.orderMoving("p", to: 9, in: ["p", "q", "r"]), ["q", "r", "p"])
        XCTAssertEqual(StudioArranging.orderMoving("new", to: 1, in: ["p", "q"]), ["p", "new", "q"])
    }
}
