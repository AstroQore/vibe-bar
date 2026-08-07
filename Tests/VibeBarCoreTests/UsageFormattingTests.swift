import XCTest
@testable import VibeBarCore

final class UsageFormattingTests: XCTestCase {
    func testMicroUSDFormatting() {
        XCTAssertEqual(UsageFormatting.formatMicroUSD(0), "$0.00")
        XCTAssertEqual(UsageFormatting.formatMicroUSD(1_234_567), "$1.23")
        XCTAssertEqual(UsageFormatting.formatMicroUSD(1_235_000), "$1.24")
        XCTAssertEqual(UsageFormatting.formatMicroUSD(123_456_789), "$123.46")
        XCTAssertEqual(UsageFormatting.formatMicroUSD(1_234_567, precision: 0), "$1")
        XCTAssertEqual(UsageFormatting.formatMicroUSD(1_234_567, precision: 4), "$1.2346")
    }

    /// A tiny-but-nonzero amount must never print as `$0.00` — that reads
    /// as free, and the whole point of the ledger is that a long tail of
    /// cheap requests adds up.
    func testSubCentAmountsFallBackToALessThanForm() {
        XCTAssertEqual(UsageFormatting.formatMicroUSD(1), "<$0.01")
        XCTAssertEqual(UsageFormatting.formatMicroUSD(4_000), "<$0.01")
        XCTAssertEqual(UsageFormatting.formatMicroUSD(-1), "-<$0.01")
        XCTAssertEqual(UsageFormatting.formatMicroUSD(5_000), "$0.01")
    }

    func testNegativeAmountsKeepTheSignOutsideTheCurrency() {
        XCTAssertEqual(UsageFormatting.formatMicroUSD(-1_500_000), "-$1.50")
    }

    func testPrecisionIsClampedToTheStoredResolution() {
        XCTAssertEqual(UsageFormatting.formatMicroUSD(1_234_567, precision: -5), "$1")
        XCTAssertEqual(UsageFormatting.formatMicroUSD(1_234_567, precision: 99), "$1.234567")
    }

    func testCompactTokenFormatting() {
        XCTAssertEqual(UsageFormatting.compactTokens(0), "0")
        XCTAssertEqual(UsageFormatting.compactTokens(999), "999")
        XCTAssertEqual(UsageFormatting.compactTokens(1_000), "1.0k")
        XCTAssertEqual(UsageFormatting.compactTokens(12_345), "12.3k")
        XCTAssertEqual(UsageFormatting.compactTokens(3_400_000), "3.40M")
        XCTAssertEqual(UsageFormatting.compactTokens(2_000_000_000), "2.00B")
        XCTAssertEqual(UsageFormatting.compactTokens(-12_345), "-12.3k")
    }

    func testTokenFormattingKeepsTheExistingSuffix() {
        XCTAssertEqual(UsageFormatting.formatTokens(500), "500 tok")
        XCTAssertEqual(UsageFormatting.formatTokens(1_500_000), "1.50M tok")
    }

    func testPercentFormatting() {
        XCTAssertEqual(UsageFormatting.formatPercent(nil), "—")
        XCTAssertEqual(UsageFormatting.formatPercent(0), "0.0%")
        XCTAssertEqual(UsageFormatting.formatPercent(0.6), "60.0%")
        XCTAssertEqual(UsageFormatting.formatPercent(0.12345, precision: 2), "12.35%")
        XCTAssertEqual(UsageFormatting.formatPercent(1), "100.0%")
        XCTAssertEqual(UsageFormatting.formatPercent(.nan), "—")
    }

    /// The one place a `Double` cost becomes money.
    func testCostUSDToMicrosRoundsHalfAwayFromZeroOnce() {
        XCTAssertEqual(PricedUsageEvent.micros(fromUSD: 1.2345675), 1_234_568)
        XCTAssertEqual(PricedUsageEvent.micros(fromUSD: 0), 0)
        XCTAssertEqual(PricedUsageEvent.micros(fromUSD: -0.5), -500_000)
        XCTAssertNil(PricedUsageEvent.micros(fromUSD: .nan))
        XCTAssertNil(PricedUsageEvent.micros(fromUSD: .infinity))
        XCTAssertNil(PricedUsageEvent.micros(fromUSD: 1e30))
    }
}
