import XCTest
@testable import VibeBarCore

/// The X Subscription's one pool, assembled from Grok's and Cursor's quotas.
final class SharedPoolSummaryTests: XCTestCase {
    private let reset = Date(timeIntervalSince1970: 1_792_092_466)

    private func grokQuota(usedPercent: Double = 2, shares: [QuotaBucketShare]? = nil, reset: Date? = nil) -> AccountQuota {
        AccountQuota(
            accountId: "oauth-grok", tool: .grok,
            buckets: [QuotaBucket(id: "weekly", title: "Weekly", shortLabel: "Weekly", usedPercent: usedPercent,
                                  resetAt: reset ?? self.reset, rawWindowSeconds: 604_800, shares: shares)],
            plan: "X Ultra")
    }

    private func cursorQuota(unified: Bool = true, poolPercent: Double = 2.594, reset: Date? = nil) -> AccountQuota {
        var buckets: [QuotaBucket] = []
        if !unified {
            buckets.append(QuotaBucket(id: "models", title: "Monthly", shortLabel: "Cursor", usedPercent: 0, groupTitle: "Cursor Models"))
        }
        buckets.append(QuotaBucket(id: "grok_bot_weekly", title: "Weekly", shortLabel: "Grok Bot", usedPercent: poolPercent,
                                   resetAt: reset ?? self.reset, rawWindowSeconds: 604_800, groupTitle: "Grok Bot"))
        return AccountQuota(accountId: "misc-cursor", tool: .cursor, buckets: buckets, plan: unified ? "X Ultra" : "Ultra")
    }

    func testOnePoolTakesCursorsFinerReadingAndGroupsTheMembers() throws {
        let shares = [
            QuotaBucketShare(label: "Build", usedPercent: 0.6),
            QuotaBucketShare(label: "Chat", usedPercent: 0.4),
            QuotaBucketShare(label: "Grok Bot", usedPercent: 1.0),
            QuotaBucketShare(label: "Other", usedPercent: 0.5)
        ]
        let summary = try XCTUnwrap(SharedPoolSummary.make(grok: grokQuota(shares: shares), cursor: cursorQuota()))
        XCTAssertEqual(summary.bucket.id, "weekly")
        XCTAssertEqual(summary.bucket.usedPercent, 2.594, accuracy: 0.0001, "xAI rounds the pool to a whole number; Cursor's decimals win")
        XCTAssertEqual(summary.bucket.resetAt, reset)
        XCTAssertNil(summary.bucket.shares, "The members carry the split; the pool row does not repeat it")
        XCTAssertEqual(summary.members.map(\.member), [.grok, .grokBot, .other])
        XCTAssertEqual(summary.members[0].usedPercent, 1.0, accuracy: 0.0001, "Grok's own products fold into one row")
        XCTAssertEqual(summary.members[1].usedPercent, 1.0, accuracy: 0.0001)
    }

    func testTwoAccountsThatDoNotResetTogetherAreTwoPools() {
        let otherReset = reset.addingTimeInterval(3_600)
        XCTAssertNil(SharedPoolSummary.make(grok: grokQuota(), cursor: cursorQuota(reset: otherReset)))
        XCTAssertNotNil(SharedPoolSummary.make(grok: grokQuota(), cursor: cursorQuota(reset: reset.addingTimeInterval(0.5))))
    }

    func testLegacyCursorOrMissingAccountHasNoSharedPool() {
        XCTAssertNil(SharedPoolSummary.make(grok: grokQuota(), cursor: cursorQuota(unified: false)), "Two monthly pools are a legacy seat")
        XCTAssertNil(SharedPoolSummary.make(grok: nil, cursor: cursorQuota()))
        XCTAssertNil(SharedPoolSummary.make(grok: grokQuota(), cursor: nil))
    }

    func testPoolWithoutASplitHasNoMembers() throws {
        let summary = try XCTUnwrap(SharedPoolSummary.make(grok: grokQuota(shares: nil), cursor: cursorQuota()))
        XCTAssertTrue(summary.members.isEmpty)
    }

    func testMemberMappingKnowsTheProductsAndKeepsTheRestApart() {
        XCTAssertEqual(SharedPoolSummary.member(for: "Grok Bot"), .grokBot)
        XCTAssertEqual(SharedPoolSummary.member(for: "Cursor"), .cursor)
        XCTAssertEqual(SharedPoolSummary.member(for: "Build"), .grok)
        XCTAssertEqual(SharedPoolSummary.member(for: "Imagine"), .grok)
        XCTAssertEqual(SharedPoolSummary.member(for: "Something New"), .other)
    }
}
