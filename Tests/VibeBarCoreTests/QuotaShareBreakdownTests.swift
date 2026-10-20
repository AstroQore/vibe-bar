import XCTest
@testable import VibeBarCore

final class QuotaShareBreakdownTests: XCTestCase {
    /// Claude on 2026-10-21: 64% of the week used, 66 / 32 / 2 by product.
    func testClaudesFractionalSharesBecomeWholePointsThatAddUp() throws {
        let breakdown = try XCTUnwrap(QuotaShareBreakdown(shares: [
            QuotaBucketShare(label: "Claude Code", usedPercent: 42.24),
            QuotaBucketShare(label: "Chats", usedPercent: 1.28),
            QuotaBucketShare(label: "Cowork", usedPercent: 20.48)
        ]))
        XCTAssertEqual(breakdown.rows.map(\.label), ["Claude Code", "Cowork", "Chats"], "Heaviest first")
        XCTAssertEqual(breakdown.rows.map(\.points), [42, 21, 1])
        XCTAssertEqual(breakdown.rows.map(\.points).reduce(0, +), 64, "The parts add up to the rounded total")
        XCTAssertEqual(breakdown.rows[0].fraction, 0.66, accuracy: 0.0001)
    }

    /// SpaceXAI on 2026-10-21, whole points from xAI.
    func testGrokWholePointsStayAsTheyAreInTheUsagePagesOrder() throws {
        let breakdown = try XCTUnwrap(QuotaShareBreakdown(shares: [
            QuotaBucketShare(label: "Chat", usedPercent: 1), QuotaBucketShare(label: "Grok Bot", usedPercent: 8),
            QuotaBucketShare(label: "Cursor", usedPercent: 1), QuotaBucketShare(label: "API", usedPercent: 5),
            QuotaBucketShare(label: "Grok Build", usedPercent: 33), QuotaBucketShare(label: "Voice", usedPercent: 1),
            QuotaBucketShare(label: "Imagine", usedPercent: 5)
        ]))
        XCTAssertEqual(breakdown.rows.map(\.label), ["Grok Build", "Grok Bot", "API", "Imagine", "Chat", "Voice", "Cursor"])
        XCTAssertEqual(breakdown.rows.map(\.points), [33, 8, 5, 5, 1, 1, 1])
    }

    func testASliverReadsAsBelowOnePointAndNothingUsedIsNoBreakdown() throws {
        let breakdown = try XCTUnwrap(QuotaShareBreakdown(shares: [
            QuotaBucketShare(label: "Claude Code", usedPercent: 5.8),
            QuotaBucketShare(label: "Chats", usedPercent: 0.2),
            QuotaBucketShare(label: "Other", usedPercent: 0)
        ]))
        XCTAssertEqual(breakdown.rows.map(\.label), ["Claude Code", "Chats"], "A product that drew nothing is not a row")
        XCTAssertEqual(breakdown.rows.map(\.points), [6, 0])
        XCTAssertTrue(breakdown.rows[1].isBelowOnePoint)
        XCTAssertNil(QuotaShareBreakdown(shares: [QuotaBucketShare(label: "Chats", usedPercent: 0)]))
    }

    func testACachedLegacyLabelMergesIntoTheCurrentProduct() throws {
        let breakdown = try XCTUnwrap(QuotaShareBreakdown(shares: [
            QuotaBucketShare(label: "Build", usedPercent: 2), QuotaBucketShare(label: "Grok Build", usedPercent: 1)
        ]))
        XCTAssertEqual(breakdown.rows.map(\.label), ["Grok Build"])
        XCTAssertEqual(breakdown.rows.map(\.points), [3])
    }
}
