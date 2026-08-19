import XCTest
@testable import VibeBarCore

final class TranscriptPageWindowTests: XCTestCase {
    func testRangeBoundsAndClampsAWindow() {
        XCTAssertEqual(TranscriptPageWindow.range(itemCount: 0, start: 0), 0..<0)
        XCTAssertEqual(TranscriptPageWindow.range(itemCount: 200, start: 0), 0..<80)
        XCTAssertEqual(TranscriptPageWindow.range(itemCount: 200, start: 80), 80..<160)
        XCTAssertEqual(TranscriptPageWindow.range(itemCount: 200, start: 160), 160..<200)
        XCTAssertEqual(TranscriptPageWindow.range(itemCount: 200, start: 10_000), 160..<200)
        XCTAssertEqual(TranscriptPageWindow.range(itemCount: 10, start: -20), 0..<10)
    }

    func testContainingItemChoosesItsPage() {
        XCTAssertEqual(TranscriptPageWindow.start(containingItemAt: 0, itemCount: 200), 0)
        XCTAssertEqual(TranscriptPageWindow.start(containingItemAt: 79, itemCount: 200), 0)
        XCTAssertEqual(TranscriptPageWindow.start(containingItemAt: 80, itemCount: 200), 80)
        XCTAssertEqual(TranscriptPageWindow.start(containingItemAt: 199, itemCount: 200), 160)
        XCTAssertEqual(TranscriptPageWindow.start(containingItemAt: 999, itemCount: 200), 160)
    }

    func testPreviousAndNextStopAtTheEdges() {
        XCTAssertEqual(TranscriptPageWindow.previousStart(itemCount: 200, start: 0), 0)
        XCTAssertEqual(TranscriptPageWindow.previousStart(itemCount: 200, start: 160), 80)
        XCTAssertEqual(TranscriptPageWindow.nextStart(itemCount: 200, start: 0), 80)
        XCTAssertEqual(TranscriptPageWindow.nextStart(itemCount: 200, start: 160), 160)
    }
}
