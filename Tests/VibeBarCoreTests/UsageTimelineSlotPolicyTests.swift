import XCTest
@testable import VibeBarCore

final class UsageTimelineSlotPolicyTests: XCTestCase {
    func testSlotWidthFollowsWindowLength() {
        XCTAssertEqual(UsageTimelineSlotPolicy.slotSeconds(windowSeconds: 18_000), 5 * 60)
        XCTAssertEqual(UsageTimelineSlotPolicy.slotSeconds(windowSeconds: 6 * 3_600), 5 * 60)
        XCTAssertEqual(UsageTimelineSlotPolicy.slotSeconds(windowSeconds: 6 * 3_600 + 1), 3_600)
        XCTAssertEqual(UsageTimelineSlotPolicy.slotSeconds(windowSeconds: 7 * 86_400), 3_600)
        XCTAssertEqual(UsageTimelineSlotPolicy.slotSeconds(windowSeconds: 8 * 86_400 + 1), 6 * 3_600)
        XCTAssertEqual(UsageTimelineSlotPolicy.slotSeconds(windowSeconds: 45 * 86_400 + 1), 86_400)
    }

    func testUnknownWindowFallsBackToDailySlots() {
        XCTAssertEqual(UsageTimelineSlotPolicy.slotSeconds(windowSeconds: nil), 86_400)
    }

    func testSlotStartFloorsToSlotBoundary() {
        let date = Date(timeIntervalSince1970: 1_780_000_123)
        let fiveMinute = UsageTimelineSlotPolicy.slotStart(for: date, windowSeconds: 18_000)
        XCTAssertEqual(fiveMinute.timeIntervalSince1970.truncatingRemainder(dividingBy: 300), 0)
        XCTAssertLessThanOrEqual(fiveMinute, date)
        XCTAssertLessThan(date.timeIntervalSince(fiveMinute), 300)

        let hourly = UsageTimelineSlotPolicy.slotStart(for: date, windowSeconds: 604_800)
        XCTAssertEqual(hourly.timeIntervalSince1970.truncatingRemainder(dividingBy: 3_600), 0)
    }

    func testFillStoreStillUsesTheSharedPolicy() {
        let date = Date(timeIntervalSince1970: 1_780_000_123)
        for window in [18_000, 604_800, 30 * 86_400, 90 * 86_400] {
            XCTAssertEqual(
                UsageFillTimelineStore.slotStart(for: date, windowSeconds: window),
                UsageTimelineSlotPolicy.slotStart(for: date, windowSeconds: window)
            )
        }
    }

    func testRetentionHorizonIsShortenedByFiniteRetention() {
        XCTAssertEqual(
            UsageTimelineSlotPolicy.retentionHorizonDays(windowSeconds: 604_800, retentionDays: 30),
            30
        )
        XCTAssertEqual(
            UsageTimelineSlotPolicy.retentionHorizonDays(
                windowSeconds: 604_800,
                retentionDays: CostDataSettings.defaultRetentionDays
            ),
            16 * 7
        )
        // A retention setting longer than the natural horizon cannot extend it.
        XCTAssertEqual(
            UsageTimelineSlotPolicy.retentionHorizonDays(windowSeconds: 18_000, retentionDays: 365),
            30
        )
    }
}
