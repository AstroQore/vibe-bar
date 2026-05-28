import XCTest
@testable import VibeBarCore

final class SubscriptionWindowProgressTests: XCTestCase {
    func testWeeklyWindowMidweek() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let reset = now.addingTimeInterval(2 * 86_400)  // 2 days remaining of 7
        let summary = SubscriptionWindowProgress.summary(
            usedPercent: 56,
            resetAt: reset,
            rawWindowSeconds: 604_800,
            now: now
        )
        XCTAssertEqual(summary, "Day 6 of 7 · 56% used")
    }

    func testWeeklyWindowJustStarted() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let reset = now.addingTimeInterval(7 * 86_400 - 60)  // basically the full window left
        let summary = SubscriptionWindowProgress.summary(
            usedPercent: 1,
            resetAt: reset,
            rawWindowSeconds: 604_800,
            now: now
        )
        XCTAssertEqual(summary, "Day 1 of 7 · 1% used")
    }

    func testWeeklyWindowAboutToReset() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let reset = now.addingTimeInterval(60)  // a minute remaining of 7-day window
        let summary = SubscriptionWindowProgress.summary(
            usedPercent: 92,
            resetAt: reset,
            rawWindowSeconds: 604_800,
            now: now
        )
        XCTAssertEqual(summary, "Day 7 of 7 · 92% used")
    }

    func testFiveHourWindowMidway() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let reset = now.addingTimeInterval(2 * 3_600 + 25 * 60)  // 2h 25m remaining
        let summary = SubscriptionWindowProgress.summary(
            usedPercent: 7,
            resetAt: reset,
            rawWindowSeconds: 18_000,
            now: now
        )
        XCTAssertEqual(summary, "2h 35m of 5h · 7% used")
    }

    func testFiveHourWindowSubHourElapsed() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let reset = now.addingTimeInterval(4 * 3_600 + 30 * 60)  // 4h 30m remaining
        let summary = SubscriptionWindowProgress.summary(
            usedPercent: 12,
            resetAt: reset,
            rawWindowSeconds: 18_000,
            now: now
        )
        XCTAssertEqual(summary, "30m of 5h · 12% used")
    }

    func testMissingResetAtFallsBackToPercentOnly() {
        let summary = SubscriptionWindowProgress.summary(
            usedPercent: 33,
            resetAt: nil,
            rawWindowSeconds: nil
        )
        XCTAssertEqual(summary, "33% used")
    }

    func testWindowSecondsNilStillFallsBackToPercent() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let summary = SubscriptionWindowProgress.summary(
            usedPercent: 42,
            resetAt: now.addingTimeInterval(20 * 86_400),
            rawWindowSeconds: nil,
            now: now
        )
        XCTAssertEqual(summary, "42% used")
    }

    func testResetInThePastReportsResetsSoon() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let summary = SubscriptionWindowProgress.summary(
            usedPercent: 99,
            resetAt: now.addingTimeInterval(-60),
            rawWindowSeconds: 604_800,
            now: now
        )
        XCTAssertEqual(summary, "Resets soon · 99% used")
    }
}
