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

    func testUsedBandFullyInsideActualFillUsesOrdinaryOpaqueOverlay() {
        let projection = QuotaForecastBarProjection(
            projectedUsedLowerPercent: 40,
            projectedUsedUpperPercent: 60,
            projectedUsedMedianPercent: 50,
            displayMode: .used
        )

        let layout = projection.confidenceBandLayout(
            actualDisplayedPercent: 80,
            minimumVisibleWidthPercent: 2
        )

        XCTAssertEqual(layout.startPercent, 40)
        XCTAssertEqual(layout.widthPercent, 20)
        XCTAssertEqual(layout.overlapPercent, 20)
        XCTAssertEqual(layout.style, .opaque)
        XCTAssertFalse(layout.showsGapConnector)
    }

    func testUsedBandWithActualEndpointInsideIntervalUsesCurvedSeam() {
        let projection = QuotaForecastBarProjection(
            projectedUsedLowerPercent: 40,
            projectedUsedUpperPercent: 80,
            projectedUsedMedianPercent: 65,
            displayMode: .used
        )

        let layout = projection.confidenceBandLayout(
            actualDisplayedPercent: 60,
            minimumVisibleWidthPercent: 2
        )

        XCTAssertEqual(layout.startPercent, 40)
        XCTAssertEqual(layout.widthPercent, 40)
        XCTAssertEqual(layout.overlapPercent, 20)
        XCTAssertEqual(layout.style, .curvedSeam)
        XCTAssertEqual(layout.startPercent + layout.widthPercent, 80)
        XCTAssertGreaterThan(layout.startPercent + layout.widthPercent, 60)
    }

    func testUsedBandOutsideActualFillRemainsFullyVisibleAndOpaque() {
        let projection = QuotaForecastBarProjection(
            projectedUsedLowerPercent: 70,
            projectedUsedUpperPercent: 90,
            projectedUsedMedianPercent: 80,
            displayMode: .used
        )

        let layout = projection.confidenceBandLayout(
            actualDisplayedPercent: 50,
            minimumVisibleWidthPercent: 2
        )

        XCTAssertEqual(layout.startPercent, 70)
        XCTAssertEqual(layout.widthPercent, 20)
        XCTAssertEqual(layout.overlapPercent, 0)
        XCTAssertEqual(layout.style, .opaque)
        XCTAssertTrue(layout.showsGapConnector)
    }

    func testUsedBandStartingAtActualEndpointUsesSoftJoin() {
        let projection = QuotaForecastBarProjection(
            projectedUsedLowerPercent: 40,
            projectedUsedUpperPercent: 60,
            projectedUsedMedianPercent: 50,
            displayMode: .used
        )

        let layout = projection.confidenceBandLayout(
            actualDisplayedPercent: 40,
            minimumVisibleWidthPercent: 2
        )

        XCTAssertEqual(layout.startPercent, 40)
        XCTAssertEqual(layout.overlapPercent, 0)
        XCTAssertEqual(layout.style, .softJoin)
        XCTAssertFalse(layout.showsGapConnector)
    }

    func testUsedBandPileupAtLowerAxisUsesOutlinedTint() {
        let projection = QuotaForecastBarProjection(
            projectedUsedLowerPercent: 0,
            projectedUsedUpperPercent: 10,
            projectedUsedMedianPercent: 2,
            displayMode: .used
        )

        let layout = projection.confidenceBandLayout(
            actualDisplayedPercent: 0,
            minimumVisibleWidthPercent: 2
        )

        XCTAssertEqual(layout.overlapPercent, 0)
        XCTAssertEqual(layout.style, .outlinedTint)
    }

    func testRemainingBandPileupAtLowerAxisUsesInsetTint() {
        let projection = QuotaForecastBarProjection(
            projectedUsedLowerPercent: 95,
            projectedUsedUpperPercent: 100,
            projectedUsedMedianPercent: 98,
            displayMode: .remaining
        )

        let layout = projection.confidenceBandLayout(
            actualDisplayedPercent: 5,
            minimumVisibleWidthPercent: 2
        )

        XCTAssertEqual(layout.startPercent, 0)
        XCTAssertEqual(layout.widthPercent, 5)
        XCTAssertEqual(layout.overlapPercent, 5)
        XCTAssertEqual(layout.style, .insetTint)
        XCTAssertFalse(layout.showsGapConnector)
    }

    func testRemainingInsetTintNeverExtendsBeyondActualFill() {
        let projection = QuotaForecastBarProjection(
            projectedUsedLowerPercent: 99.7,
            projectedUsedUpperPercent: 100,
            projectedUsedMedianPercent: 99.9,
            displayMode: .remaining
        )

        let layout = projection.confidenceBandLayout(
            actualDisplayedPercent: 0.4,
            minimumVisibleWidthPercent: 2
        )

        XCTAssertEqual(layout.style, .insetTint)
        XCTAssertEqual(layout.startPercent, 0)
        XCTAssertEqual(layout.widthPercent, 0.4, accuracy: 0.0001)
        XCTAssertEqual(layout.overlapPercent, 0.4, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(layout.startPercent + layout.widthPercent, 0.4)
    }

    func testRemainingBandAboveExtremeThresholdUsesOrdinaryOpaqueOverlay() {
        let projection = QuotaForecastBarProjection(
            projectedUsedLowerPercent: 89,
            projectedUsedUpperPercent: 94,
            projectedUsedMedianPercent: 92,
            displayMode: .remaining
        )

        let layout = projection.confidenceBandLayout(
            actualDisplayedPercent: 11,
            minimumVisibleWidthPercent: 2
        )

        XCTAssertEqual(layout.startPercent, 6)
        XCTAssertEqual(layout.widthPercent, 5)
        XCTAssertEqual(layout.style, .opaque)
        XCTAssertFalse(layout.showsGapConnector)
    }

    func testRemainingBandReachingActualEndpointStaysOpaque() {
        let projection = QuotaForecastBarProjection(
            projectedUsedLowerPercent: 42,
            projectedUsedUpperPercent: 53,
            projectedUsedMedianPercent: 46,
            displayMode: .remaining
        )

        let layout = projection.confidenceBandLayout(
            actualDisplayedPercent: 58,
            minimumVisibleWidthPercent: 2
        )

        XCTAssertEqual(layout.startPercent, 47)
        XCTAssertEqual(layout.widthPercent, 11)
        XCTAssertEqual(layout.overlapPercent, 11)
        XCTAssertEqual(layout.style, .opaque)
        XCTAssertFalse(layout.showsGapConnector)
    }

    func testCurvedSeamKeepsRoundedLowerBoundInsideActualFill() {
        let projection = QuotaForecastBarProjection(
            projectedUsedLowerPercent: 36,
            projectedUsedUpperPercent: 60,
            projectedUsedMedianPercent: 51,
            displayMode: .used
        )

        let layout = projection.confidenceBandLayout(
            actualDisplayedPercent: 42,
            minimumVisibleWidthPercent: 2
        )

        XCTAssertEqual(layout.startPercent, 36)
        XCTAssertEqual(layout.widthPercent, 24)
        XCTAssertEqual(layout.overlapPercent, 6)
        XCTAssertEqual(layout.style, .curvedSeam)
    }
}
