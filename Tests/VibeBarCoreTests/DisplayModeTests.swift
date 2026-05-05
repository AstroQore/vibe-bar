import XCTest
@testable import VibeBarCore

final class DisplayModeTests: XCTestCase {
    func testRemainingShowsRemainingPercent() {
        let bucket = QuotaBucket(id: "x", title: "x", shortLabel: "x", usedPercent: 30)
        XCTAssertEqual(bucket.displayPercent(.remaining), 70)
    }

    func testUsedShowsUsedPercent() {
        let bucket = QuotaBucket(id: "x", title: "x", shortLabel: "x", usedPercent: 30)
        XCTAssertEqual(bucket.displayPercent(.used), 30)
    }

    func testNegativeUsedPercentClampsToZero() {
        let bucket = QuotaBucket(id: "x", title: "x", shortLabel: "x", usedPercent: -5)
        XCTAssertEqual(bucket.usedPercent, 0)
        XCTAssertEqual(bucket.remainingPercent, 100)
    }

    func testOver100UsedPercentClampsTo100() {
        let bucket = QuotaBucket(id: "x", title: "x", shortLabel: "x", usedPercent: 105)
        XCTAssertEqual(bucket.usedPercent, 100)
        XCTAssertEqual(bucket.remainingPercent, 0)
    }
}
