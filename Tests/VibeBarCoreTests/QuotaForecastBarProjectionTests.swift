import XCTest

@testable import VibeBarCore

final class QuotaForecastBarProjectionTests: XCTestCase {
    func testAtRiskIntervalKeepsUsedMarkerInsideVisibleBand() {
        let projection = QuotaForecastBarProjection(
            projectedUsedLowerPercent: 84,
            projectedUsedUpperPercent: 116,
            projectedUsedMedianPercent: 100,
            displayMode: .used
        )

        XCTAssertEqual(projection.lowerPercent, 84)
        XCTAssertEqual(projection.upperPercent, 100)
        XCTAssertEqual(projection.medianPercent, 100)
        XCTAssertTrue(projection.clipsUpperBound)
        XCTAssertTrue(projection.lowerPercent...projection.upperPercent ~= projection.medianPercent)
    }

    func testAtRiskIntervalFlipsConsistentlyForRemainingMode() {
        let projection = QuotaForecastBarProjection(
            projectedUsedLowerPercent: 84,
            projectedUsedUpperPercent: 116,
            projectedUsedMedianPercent: 100,
            displayMode: .remaining
        )

        XCTAssertEqual(projection.lowerPercent, 0)
        XCTAssertEqual(projection.upperPercent, 16)
        XCTAssertEqual(projection.medianPercent, 0)
        XCTAssertTrue(projection.clipsLowerBound)
        XCTAssertTrue(projection.lowerPercent...projection.upperPercent ~= projection.medianPercent)
    }

    func testProjectionDefensivelyIncludesMedianInMalformedInterval() {
        let projection = QuotaForecastBarProjection(
            projectedUsedLowerPercent: 40,
            projectedUsedUpperPercent: 60,
            projectedUsedMedianPercent: 75,
            displayMode: .used
        )

        XCTAssertEqual(projection.lowerPercent, 40)
        XCTAssertEqual(projection.upperPercent, 75)
        XCTAssertEqual(projection.medianPercent, 75)
        XCTAssertTrue(projection.lowerPercent...projection.upperPercent ~= projection.medianPercent)
    }
}
