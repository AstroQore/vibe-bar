import XCTest
@testable import VibeBarCore

/// A Cursor account on The X Subscription: one weekly pool shared with Grok,
/// read on the Grok card, so Cursor itself reports a plan badge and no
/// buckets. Payload shapes are copied from a live unified account.
final class CursorUnifiedPoolTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    /// `usage-summary` keeps answering with the legacy monthly block for a
    /// unified account; it must not become two Monthly buckets.
    private let unifiedSummary = """
    {
      "billingCycleStart": "2026-10-01T00:00:00.000Z",
      "billingCycleEnd": "2026-11-01T00:00:00.000Z",
      "membershipType": "unified_ultra",
      "limitType": "user",
      "isUnlimited": false,
      "individualUsage": {
        "plan": {"enabled": true, "used": 0, "limit": 55395, "remaining": 55395,
                 "autoPercentUsed": 0, "apiPercentUsed": 0, "totalPercentUsed": 0},
        "onDemand": {"enabled": false, "used": 0, "limit": null, "remaining": null}
      }
    }
    """

    private let unifiedGrokBot = """
    {
      "currentPeriodStart": "2026-10-15T03:44:55.845Z",
      "nextResetTimestampUtc": "2026-10-22T03:44:55.845Z",
      "usagePercent": 1.3394710713963354,
      "hasAvailableUsage": true,
      "hasNonZeroIncludedLimit": true,
      "grokPlanLabel": "Grok Bot Plan",
      "cursorPlanName": "Ultra",
      "isUnified": true,
      "billingBrand": "SAND_BILLING_BRAND_GROK"
    }
    """

    func testUnifiedAccountReportsThePlanAndNoBuckets() throws {
        let summary = try CursorResponseParser.decodeUsageSummary(data: Data(unifiedSummary.utf8))
        let bot = try XCTUnwrap(CursorResponseParser.decodeGrokBotUsage(data: Data(unifiedGrokBot.utf8)))
        XCTAssertEqual(bot.isUnified, true)
        XCTAssertEqual(bot.cursorPlanName, "Ultra")

        let snap = CursorResponseParser.parseSummary(
            summary: summary, userInfo: nil, requestUsage: nil, grokBotUsage: bot, now: now)
        XCTAssertEqual(snap.planName, "X Ultra")
        XCTAssertEqual(snap.buckets.map(\.id), ["grok_bot_weekly"],
                       "The legacy monthly block is not quota; the pool stays as the Grok Bot bucket for when Grok's own snapshot is missing")
        XCTAssertEqual(snap.buckets.first?.usedPercent ?? 0, 1.339, accuracy: 0.001)
    }

    func testUnifiedStatusNamesThePlanWhenMembershipStillReadsLegacy() throws {
        let legacyMembership = try CursorResponseParser.decodeUsageSummary(
            data: Data(unifiedSummary.replacingOccurrences(of: "unified_ultra", with: "ultra").utf8))
        let bot = try XCTUnwrap(CursorResponseParser.decodeGrokBotUsage(data: Data(unifiedGrokBot.utf8)))
        let snap = CursorResponseParser.parseSummary(
            summary: legacyMembership, userInfo: nil, requestUsage: nil, grokBotUsage: bot, now: now)
        XCTAssertEqual(snap.planName, "X Ultra", "`cursorPlanName` outranks a membership type still reading as a legacy seat")
        XCTAssertEqual(snap.buckets.map(\.id), ["grok_bot_weekly"])
    }

    func testMembershipTypeAloneMarksTheAccountUnified() throws {
        // The Grok Bot status call failed this refresh: the membership type
        // still says The X Subscription, so the legacy block stays unread.
        let summary = try CursorResponseParser.decodeUsageSummary(data: Data(unifiedSummary.utf8))
        let snap = CursorResponseParser.parseSummary(
            summary: summary, userInfo: nil, requestUsage: nil, grokBotUsage: nil, now: now)
        XCTAssertEqual(snap.planName, "X Ultra")
        XCTAssertTrue(snap.buckets.isEmpty, "No pool reading this refresh, and the legacy block is not one")
        XCTAssertTrue(CursorResponseParser.isUnified(summary: summary, grokBotUsage: nil))
    }

    func testGrokBotFlagOverridesTheMembershipType() throws {
        // A legacy membership with the status saying unified is unified;
        // a unified-looking membership with the status saying otherwise is not.
        let legacy = try CursorResponseParser.decodeUsageSummary(
            data: Data(unifiedSummary.replacingOccurrences(of: "unified_ultra", with: "ultra").utf8))
        XCTAssertTrue(CursorResponseParser.isUnified(summary: legacy, grokBotUsage: CursorGrokBotUsage(isUnified: true)))
        let unified = try CursorResponseParser.decodeUsageSummary(data: Data(unifiedSummary.utf8))
        XCTAssertFalse(CursorResponseParser.isUnified(summary: unified, grokBotUsage: CursorGrokBotUsage(isUnified: false)))
    }

    func testLegacyAccountKeepsItsTwoPoolsAndGrokBot() throws {
        let legacy = try CursorResponseParser.decodeUsageSummary(
            data: Data(unifiedSummary.replacingOccurrences(of: "unified_ultra", with: "ultra").utf8))
        let bot = CursorGrokBotUsage(
            nextResetTimestampUtc: "2026-10-22T03:44:55.845Z", usagePercent: 1.3,
            hasNonZeroIncludedLimit: true, isUnified: false)
        let snap = CursorResponseParser.parseSummary(
            summary: legacy, userInfo: nil, requestUsage: nil, grokBotUsage: bot, now: now)
        XCTAssertEqual(snap.planName, "Ultra")
        XCTAssertEqual(snap.buckets.map(\.id), ["models", "other_models", "grok_bot_weekly"])
    }

    func testUnifiedPlanNamesRenderUnderTheXBrand() throws {
        for (raw, expected) in [("unified_ultra", "X Ultra"), ("unified_super", "X Super"),
                                ("unified_premium", "X Premium"), ("unified_plus", "X Plus")] {
            let data = try JSONSerialization.data(withJSONObject: ["membershipType": raw])
            let summary = try CursorResponseParser.decodeUsageSummary(data: data)
            let snap = CursorResponseParser.parseSummary(summary: summary, userInfo: nil, requestUsage: nil, now: now)
            XCTAssertEqual(snap.planName, expected, raw)
            XCTAssertEqual(ProviderPlanDisplay.displayName(for: .cursor, rawPlan: expected, format: .tier),
                           String(expected.dropFirst(2)))
        }
    }

    func testGrokPoolLabelsTheBotProductByName() {
        XCTAssertEqual(GrokQuotaAdapter.productLabel("GrokBot"), "Grok Bot")
        XCTAssertEqual(GrokQuotaAdapter.productLabel("GrokBuild"), "Build")
        XCTAssertEqual(GrokQuotaAdapter.productLabel("Cursor"), "Cursor")
    }
}
