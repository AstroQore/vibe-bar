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
        // Total bucket
        let total = try XCTUnwrap(snap.buckets.first { $0.id == "cursor.total" })
        XCTAssertEqual(total.usedPercent, 0.36, accuracy: 0.001)
        // Auto / API
        let auto = try XCTUnwrap(snap.buckets.first { $0.id == "cursor.auto" })
        XCTAssertEqual(auto.usedPercent, 0.20, accuracy: 0.001)
        let api = try XCTUnwrap(snap.buckets.first { $0.id == "cursor.api" })
        XCTAssertEqual(api.usedPercent, 0.52, accuracy: 0.001)
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
        // Total derives from overall.used / overall.limit * 100.
        XCTAssertEqual(snap.buckets.first(where: { $0.id == "cursor.total" })?.usedPercent ?? -1,
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
        XCTAssertEqual(snap.buckets.first(where: { $0.id == "cursor.total" })?.usedPercent ?? -1,
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
        XCTAssertEqual(snap.buckets.first(where: { $0.id == "cursor.total" })?.usedPercent ?? -1,
                       70.0, accuracy: 0.01)
    }

    /// On-demand budget surfaces as a dedicated bucket with the
    /// dollar amounts in groupTitle — the misc card lifts that as a
    /// separate row. Crucially, this does *not* go through the global
    /// cost pipeline (covered by `tool.supportsTokenCost == false`).
    func testOnDemandBucketCarriesDollarString() throws {
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
        let onDemand = try XCTUnwrap(snap.buckets.first { $0.id == "cursor.onDemand" })
        XCTAssertEqual(onDemand.groupTitle, "On-demand: $7.30 / $20.00")
        XCTAssertEqual(onDemand.usedPercent, 36.5, accuracy: 0.01)
    }

    /// Unlimited on-demand: limit is 0 / nil. Bucket still renders,
    /// label says "unlimited", percent is zero.
    func testOnDemandUnlimitedRendersUnlimited() throws {
        let json = """
        {
          "membershipType": "business",
          "individualUsage": {
            "plan": {"used": 0, "limit": 0, "totalPercentUsed": 0.0},
            "onDemand": {"used": 1234}
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
        let onDemand = try XCTUnwrap(snap.buckets.first { $0.id == "cursor.onDemand" })
        XCTAssertEqual(onDemand.groupTitle, "On-demand: $12.34 / unlimited")
        XCTAssertEqual(onDemand.usedPercent, 0.0, accuracy: 0.01)
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
