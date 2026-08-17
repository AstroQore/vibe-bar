import XCTest
@testable import VibeBarCore

final class CursorParserEdgeCasesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_715_000_000)

    /// Pro fractional percent. Cursor's percent fields are already
    /// in percent units even when fractional (0.36 means 0.36%, not
    /// 36%). The parser must not multiply by 100.
    func testProFractionalPercentNotScaled() throws {
        let json = """
        {
          "membershipType": "pro",
          "billingCycleEnd": "2026-06-01T00:00:00Z",
          "individualUsage": {
            "plan": {
              "used": 7384,
              "limit": 20000,
              "totalPercentUsed": 0.36,
              "autoPercentUsed": 0.20,
              "apiPercentUsed": 0.52
            },
            "onDemand": {"used": 0, "limit": 0}
          }
        }
        """
        let summary = try CursorResponseParser.decodeUsageSummary(data: Data(json.utf8))
        let snap = CursorResponseParser.parseSummary(
            summary: summary,
            userInfo: nil,
            requestUsage: nil,
            now: now
        )
        XCTAssertEqual(snap.planName, "Pro")
        XCTAssertEqual(snap.buckets.map(\.title), ["Cursor Models", "Other Models"])
        let cursorModels = try XCTUnwrap(snap.buckets.first { $0.id == "models" })
        XCTAssertEqual(cursorModels.usedPercent, 0.20, accuracy: 0.001)
        let otherModels = try XCTUnwrap(snap.buckets.first { $0.id == "other_models" })
        XCTAssertEqual(otherModels.usedPercent, 0.52, accuracy: 0.001)
    }

    /// Enterprise / team-member personal cap reported under
    /// `individualUsage.overall` instead of `plan`.
    func testEnterpriseOverallFallback() throws {
        let json = """
        {
          "membershipType": "enterprise",
          "individualUsage": {
            "overall": {"used": 7500, "limit": 10000}
          }
        }
        """
        let summary = try CursorResponseParser.decodeUsageSummary(data: Data(json.utf8))
        let snap = CursorResponseParser.parseSummary(
            summary: summary,
            userInfo: nil,
            requestUsage: nil,
            now: now
        )
        XCTAssertEqual(snap.planName, "Enterprise")
        // Legacy aggregate derives from overall.used / overall.limit * 100.
        XCTAssertEqual(snap.buckets.first(where: { $0.id == "models" })?.usedPercent ?? -1,
                       75.0, accuracy: 0.01)
    }

    /// Shared team/enterprise pool fallback under `teamUsage.pooled`
    /// when neither plan nor overall is present.
    func testTeamPooledFallback() throws {
        let json = """
        {
          "membershipType": "business",
          "individualUsage": {},
          "teamUsage": {"pooled": {"used": 4000, "limit": 50000}}
        }
        """
        let summary = try CursorResponseParser.decodeUsageSummary(data: Data(json.utf8))
        let snap = CursorResponseParser.parseSummary(
            summary: summary,
            userInfo: nil,
            requestUsage: nil,
            now: now
        )
        XCTAssertEqual(snap.planName, "Business")
        XCTAssertEqual(snap.buckets.first(where: { $0.id == "models" })?.usedPercent ?? -1,
                       8.0, accuracy: 0.01)
    }

    /// Legacy "request plan" — usage-summary lacks a plan block, so
    /// the parser falls through to `requestUsage.gpt4` numbers.
    func testLegacyRequestPlan() throws {
        let summaryJSON = """
        { "individualUsage": {} }
        """
        let summary = try CursorResponseParser.decodeUsageSummary(data: Data(summaryJSON.utf8))
        let requestJSON = """
        {
          "gpt-4": {
            "numRequestsTotal": 350,
            "maxRequestUsage": 500
          }
        }
        """
        let requestUsage = try JSONDecoder().decode(
            CursorRequestUsage.self,
            from: Data(requestJSON.utf8)
        )
        let snap = CursorResponseParser.parseSummary(
            summary: summary,
            userInfo: nil,
            requestUsage: requestUsage,
            now: now
        )
        XCTAssertEqual(snap.planName, "Legacy")
        // 350 / 500 * 100 = 70%
        XCTAssertEqual(snap.buckets.first(where: { $0.id == "models" })?.usedPercent ?? -1,
                       70.0, accuracy: 0.01)
    }

    /// On-demand spend is billing state, not a subscription quota lane. Cursor
    /// cost now comes from token-level dashboard events instead.
    func testOnDemandDoesNotBecomeQuotaBucket() throws {
        let json = """
        {
          "membershipType": "pro",
          "individualUsage": {
            "plan": {"used": 1000, "limit": 2000, "totalPercentUsed": 50.0},
            "onDemand": {"used": 730, "limit": 2000}
          }
        }
        """
        let summary = try CursorResponseParser.decodeUsageSummary(data: Data(json.utf8))
        let snap = CursorResponseParser.parseSummary(
            summary: summary,
            userInfo: nil,
            requestUsage: nil,
            now: now
        )
        XCTAssertFalse(snap.buckets.contains { $0.id == "on_demand" })
        XCTAssertEqual(snap.buckets.map(\.id), ["models"])
    }

    func testGrokBotWeeklyBucketUsesDedicatedResetWindow() throws {
        let json = """
        {
          "membershipType": "ultra",
          "billingCycleStart": "2026-08-12T05:36:22.000Z",
          "billingCycleEnd": "2026-09-12T05:36:22.000Z",
          "individualUsage": {"plan": {"autoPercentUsed": 1, "apiPercentUsed": 2}}
        }
        """
        let summary = try CursorResponseParser.decodeUsageSummary(data: Data(json.utf8))
        let bot = try XCTUnwrap(CursorResponseParser.decodeGrokBotUsage(data: Data("""
        {
          "currentPeriodStart": "2026-08-12T05:39:26.906Z",
          "nextResetTimestampUtc": "2026-08-19T05:39:26.906Z",
          "usagePercent": 5.361195,
          "hasAvailableUsage": true,
          "hasNonZeroIncludedLimit": true
        }
        """.utf8)))
        let snap = CursorResponseParser.parseSummary(
            summary: summary,
            userInfo: nil,
            requestUsage: nil,
            grokBotUsage: bot,
            now: now
        )
        let weekly = try XCTUnwrap(snap.buckets.first { $0.id == "grok_bot_weekly" })
        XCTAssertEqual(weekly.title, "Weekly usage")
        XCTAssertEqual(weekly.groupTitle, "Grok Bot")
        XCTAssertEqual(weekly.usedPercent, 5.361195, accuracy: 0.000_001)
        XCTAssertEqual(weekly.rawWindowSeconds, 604_800)
    }

    /// Plan name unknown / missing returns nil so the misc card
    /// suppresses the badge instead of showing "Nil".
    func testUnknownMembershipReturnsNilPlanName() throws {
        let json = """
        { "individualUsage": {} }
        """
        let summary = try CursorResponseParser.decodeUsageSummary(data: Data(json.utf8))
        let snap = CursorResponseParser.parseSummary(
            summary: summary,
            userInfo: nil,
            requestUsage: nil,
            now: now
        )
        XCTAssertNil(snap.planName)
    }
}
