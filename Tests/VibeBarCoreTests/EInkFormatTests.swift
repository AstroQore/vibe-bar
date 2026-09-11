import XCTest
@testable import VibeBarCore

final class EInkFormatTests: XCTestCase {
    func testMoneyMatchesTheVerifiedDemo() {
        XCTAssertEqual(EInkFormat.money(280.4), "$280")
        XCTAssertEqual(EInkFormat.money(6299.2), "$6,299")
        XCTAssertEqual(EInkFormat.money(121_216.3), "$121,216")
        XCTAssertEqual(EInkFormat.money(67.9), "$67.9")
        XCTAssertEqual(EInkFormat.money(9.994), "$9.99")
        XCTAssertEqual(EInkFormat.money(0), "$0.00")
        XCTAssertEqual(EInkFormat.money(100), "$100")
    }

    func testMoneyCompactOnlyKicksInAboveAThousand() {
        XCTAssertEqual(EInkFormat.moneyCompact(67.9), "$67.9")
        XCTAssertEqual(EInkFormat.moneyCompact(999), "$999")
        XCTAssertEqual(EInkFormat.moneyCompact(6299.2), "$6.3k")
        XCTAssertEqual(EInkFormat.moneyCompact(121_216.3), "$121k")
    }

    func testTokensMatchTheVerifiedDemo() {
        XCTAssertEqual(EInkFormat.tokens(Int64(315_556_500)), "316M")
        XCTAssertEqual(EInkFormat.tokens(Int64(4_841_587_557)), "4.8B")
        XCTAssertEqual(EInkFormat.tokens(Int64(12_400)), "12K")
        XCTAssertEqual(EInkFormat.tokens(Int64(999)), "999")
        XCTAssertEqual(EInkFormat.tokens(Int64(0)), "0")
    }

    func testIntegersUseFixedGroupingRegardlessOfLocale() {
        XCTAssertEqual(EInkFormat.int(987_654), "987,654")
        XCTAssertEqual(EInkFormat.int(0), "0")
        XCTAssertEqual(EInkFormat.int(Int64(1_000)), "1,000")
    }

    func testCountdownBuckets() {
        let now = EInkFixtures.referenceDate
        XCTAssertEqual(EInkFormat.countdown(nil, now: now), "")
        XCTAssertEqual(EInkFormat.countdown(now.addingTimeInterval(-60), now: now), "0m")
        XCTAssertEqual(EInkFormat.countdown(now.addingTimeInterval(42 * 60), now: now), "42m")
        XCTAssertEqual(EInkFormat.countdown(now.addingTimeInterval(3 * 3600 + 7 * 60), now: now), "3h 07m")
        XCTAssertEqual(EInkFormat.countdown(now.addingTimeInterval(5 * 86_400 + 23 * 3600), now: now), "5d 23h")
    }

    func testTimestampLabel() {
        XCTAssertEqual(EInkFormat.timestampLabel(EInkFixtures.referenceDate, calendar: EInkFixtures.calendar()), "01-01 00:00")
    }
}
