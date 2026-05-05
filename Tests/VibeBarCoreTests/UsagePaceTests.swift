import XCTest
@testable import VibeBarCore

final class UsagePaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_730_000_000)
    private let fiveHourSeconds = 18_000

    private func bucket(used: Double, secondsUntilReset: Int, windowSeconds: Int) -> QuotaBucket {
        QuotaBucket(
            id: "test",
            title: "5h",
            shortLabel: "5h",
            usedPercent: used,
            resetAt: now.addingTimeInterval(TimeInterval(secondsUntilReset)),
            rawWindowSeconds: windowSeconds
        )
    }

    // MARK: - Stage classification

    func testOnTrackWhenWithinTwoPercent() {
        // elapsed 60% of window, used 61% → delta +1 → onTrack
        let b = bucket(used: 61, secondsUntilReset: fiveHourSeconds * 2 / 5, windowSeconds: fiveHourSeconds)
        let pace = UsagePace.compute(bucket: b, now: now)
        XCTAssertNotNil(pace)
        XCTAssertEqual(pace?.stage, .onTrack)
    }

    func testSlightlyAheadAtFivePercentDelta() {
        // elapsed 60%, used 65% → delta +5 → slightlyAhead
        let b = bucket(used: 65, secondsUntilReset: fiveHourSeconds * 2 / 5, windowSeconds: fiveHourSeconds)
        let pace = UsagePace.compute(bucket: b, now: now)
        XCTAssertEqual(pace?.stage, .slightlyAhead)
    }

    func testFarAheadAtTwentyPercentDelta() {
        // elapsed 60%, used 85% → delta +25 → farAhead
        let b = bucket(used: 85, secondsUntilReset: fiveHourSeconds * 2 / 5, windowSeconds: fiveHourSeconds)
        let pace = UsagePace.compute(bucket: b, now: now)
        XCTAssertEqual(pace?.stage, .farAhead)
    }

    func testFarBehindAtNegativeTwentyPercentDelta() {
        // elapsed 60%, used 35% → delta -25 → farBehind
        let b = bucket(used: 35, secondsUntilReset: fiveHourSeconds * 2 / 5, windowSeconds: fiveHourSeconds)
        let pace = UsagePace.compute(bucket: b, now: now)
        XCTAssertEqual(pace?.stage, .farBehind)
    }

    // MARK: - ETA / willLastToReset

    func testWillLastToResetWhenZeroUsage() {
        // halfway through window, 0% used → willLastToReset
        let b = bucket(used: 0, secondsUntilReset: fiveHourSeconds / 2, windowSeconds: fiveHourSeconds)
        let pace = UsagePace.compute(bucket: b, now: now)
        XCTAssertTrue(pace?.willLastToReset ?? false)
        XCTAssertNil(pace?.etaSeconds)
    }

    func testWillLastToResetWhenLowBurnRate() {
        // 90% of window elapsed, only 50% used → rate 50/90, eta = 50/(50/90) = 90 minutes from elapsed start
        // since rate is slow, ETA > timeUntilReset → willLastToReset
        let b = bucket(used: 50, secondsUntilReset: fiveHourSeconds / 10, windowSeconds: fiveHourSeconds)
        let pace = UsagePace.compute(bucket: b, now: now)
        XCTAssertTrue(pace?.willLastToReset ?? false)
    }

    func testRunsOutBeforeResetWhenBurningFast() {
        // 20% elapsed, 80% used → rate 80/20 = 4 → eta = 20/4 = 5 (units of elapsed-pct space)
        // mapped back: timeUntilReset 80%, eta 5/100 = much sooner → runs out before reset
        let b = bucket(used: 80, secondsUntilReset: fiveHourSeconds * 4 / 5, windowSeconds: fiveHourSeconds)
        let pace = UsagePace.compute(bucket: b, now: now)
        XCTAssertFalse(pace?.willLastToReset ?? true)
        XCTAssertNotNil(pace?.etaSeconds)
        // Sanity: ETA should be substantially less than the time until reset
        XCTAssertLessThan(pace?.etaSeconds ?? .infinity, TimeInterval(fiveHourSeconds * 4 / 5))
    }

    // MARK: - Edge cases

    func testReturnsNilWithoutResetAt() {
        let b = QuotaBucket(id: "x", title: "x", shortLabel: "x", usedPercent: 50, resetAt: nil, rawWindowSeconds: fiveHourSeconds)
        XCTAssertNil(UsagePace.compute(bucket: b, now: now))
    }

    func testReturnsNilWithoutWindowSeconds() {
        let b = QuotaBucket(id: "x", title: "x", shortLabel: "x", usedPercent: 50, resetAt: now.addingTimeInterval(3600), rawWindowSeconds: nil)
        XCTAssertNil(UsagePace.compute(bucket: b, now: now))
    }

    func testReturnsNilWhenAlreadyPastReset() {
        let b = bucket(used: 30, secondsUntilReset: -60, windowSeconds: fiveHourSeconds)
        XCTAssertNil(UsagePace.compute(bucket: b, now: now))
    }

    func testReturnsNilWhenResetMoreThanWindowAway() {
        // pretend the bucket reset is in the future further than the window — invalid state
        let b = bucket(used: 30, secondsUntilReset: fiveHourSeconds * 2, windowSeconds: fiveHourSeconds)
        XCTAssertNil(UsagePace.compute(bucket: b, now: now))
    }

    // MARK: - Summary text

    func testStageSummaryOnTrack() {
        let pace = UsagePace(stage: .onTrack, deltaPercent: 1, expectedUsedPercent: 50, actualUsedPercent: 51, etaSeconds: nil, willLastToReset: true)
        XCTAssertEqual(pace.stageSummary, "On pace")
    }

    func testStageSummaryDeficit() {
        let pace = UsagePace(stage: .ahead, deltaPercent: 8, expectedUsedPercent: 50, actualUsedPercent: 58, etaSeconds: 3600, willLastToReset: false)
        XCTAssertEqual(pace.stageSummary, "8% in deficit")
    }

    func testStageSummaryReserve() {
        let pace = UsagePace(stage: .behind, deltaPercent: -8, expectedUsedPercent: 50, actualUsedPercent: 42, etaSeconds: nil, willLastToReset: true)
        XCTAssertEqual(pace.stageSummary, "8% in reserve")
    }
}
