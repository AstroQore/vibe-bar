import XCTest
@testable import VibeBarCore

final class PopoverResizeGateTests: XCTestCase {
    func testGrowthAppliesImmediately() {
        XCTAssertEqual(
            PopoverResizeGate.verdict(
                currentHeight: 720, targetHeight: 900,
                currentWidth: 420, targetWidth: 420
            ),
            .applyNow
        )
    }

    func testTransientDipIsHeldInsteadOfCollapsingTheFrame() {
        // The reopen bounce: content momentarily measures tiny, the resolved
        // target lands on the minimum height, and applying it snapped the
        // visible popover down before the settled height arrived.
        XCTAssertEqual(
            PopoverResizeGate.verdict(
                currentHeight: 900, targetHeight: 460,
                currentWidth: 420, targetWidth: 420
            ),
            .holdForSettle
        )
    }

    func testSettledSameHeightIsIgnored() {
        // Recovery report after a held dip: nothing to change (the caller
        // also drops the pending shrink on this verdict).
        XCTAssertEqual(
            PopoverResizeGate.verdict(
                currentHeight: 900, targetHeight: 900.4,
                currentWidth: 420, targetWidth: 420
            ),
            .ignore
        )
    }

    func testWidthChangeAppliesEvenWithoutHeightChange() {
        XCTAssertEqual(
            PopoverResizeGate.verdict(
                currentHeight: 900, targetHeight: 900,
                currentWidth: 420, targetWidth: 460
            ),
            .applyNow
        )
    }

    func testShrinkWithWidthChangeStaysImmediateToKeepFrameInSync() {
        XCTAssertEqual(
            PopoverResizeGate.verdict(
                currentHeight: 900, targetHeight: 700,
                currentWidth: 420, targetWidth: 460
            ),
            .applyNow
        )
    }
}
