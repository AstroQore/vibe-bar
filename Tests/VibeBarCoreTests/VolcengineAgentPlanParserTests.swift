import XCTest
@testable import VibeBarCore

final class VolcengineAgentPlanParserTests: XCTestCase {
    /// Captured live from `GetAgentPlanAFPUsage` (numbers only, no PII).
    private let liveBody = """
    {
      "ResponseMetadata": {"RequestId": "req-1", "Action": "GetAgentPlanAFPUsage"},
      "Result": {
        "PlanType": "medium",
        "AFPFiveHour": {"Quota": 10000, "Used": 411.0225, "SubscribeTime": 1781701260000, "ResetTime": 1781719260000},
        "AFPWeekly":   {"Quota": 35000, "Used": 411.0718, "SubscribeTime": 1781452800000, "ResetTime": 1782057600000},
        "AFPMonthly":  {"Quota": 100000, "Used": 411.0718, "SubscribeTime": 1781591283000, "ResetTime": 1784217599000},
        "AFPDaily":    {"Quota": 50000, "Used": 0, "SubscribeTime": 1781625600000, "ResetTime": 1781712000000}
      }
    }
    """

    func testParsesThreeWindowsAndSkipsDaily() throws {
        let snap = try VolcengineAgentPlanResponseParser.parseUsage(data: Data(liveBody.utf8))
        // AFPDaily is present in the payload but intentionally not surfaced.
        XCTAssertEqual(snap.buckets.count, 3)

        XCTAssertEqual(snap.buckets[0].id, "volcengineAgentPlan.session")
        XCTAssertEqual(snap.buckets[0].title, "5 Hours")
        XCTAssertEqual(snap.buckets[0].shortLabel, "5 Hours")
        XCTAssertEqual(snap.buckets[0].rawWindowSeconds, 5 * 3600)
        // 411.0225 / 10000 * 100 = 4.110225
        XCTAssertEqual(snap.buckets[0].usedPercent, 4.110225, accuracy: 0.0001)
        // ResetTime is in milliseconds → seconds.
        XCTAssertEqual(snap.buckets[0].resetAt?.timeIntervalSince1970 ?? 0, 1781719260, accuracy: 1)

        XCTAssertEqual(snap.buckets[1].id, "volcengineAgentPlan.weekly")
        XCTAssertEqual(snap.buckets[1].rawWindowSeconds, 7 * 86_400)
        XCTAssertEqual(snap.buckets[1].usedPercent, 411.0718 / 35000 * 100, accuracy: 0.0001)

        XCTAssertEqual(snap.buckets[2].id, "volcengineAgentPlan.monthly")
        XCTAssertEqual(snap.buckets[2].rawWindowSeconds, 30 * 86_400)
        XCTAssertEqual(snap.buckets[2].usedPercent, 411.0718 / 100000 * 100, accuracy: 0.0001)
    }

    func testPlanTypeBecomesCapitalizedBadge() throws {
        let snap = try VolcengineAgentPlanResponseParser.parseUsage(data: Data(liveBody.utf8))
        XCTAssertEqual(snap.planName, "Agent Plan Medium")
    }

    func testMissingPlanTypeLeavesPlanNameNil() throws {
        let json = """
        {"Result": {"AFPFiveHour": {"Quota": 10000, "Used": 100, "ResetTime": 1781719260000}}}
        """
        let snap = try VolcengineAgentPlanResponseParser.parseUsage(data: Data(json.utf8))
        XCTAssertNil(snap.planName)
        XCTAssertEqual(snap.buckets.count, 1)
        XCTAssertEqual(snap.buckets[0].id, "volcengineAgentPlan.session")
    }

    func testZeroQuotaWindowIsSkipped() throws {
        let json = """
        {
          "Result": {
            "PlanType": "small",
            "AFPFiveHour": {"Quota": 0, "Used": 0, "ResetTime": 1781719260000},
            "AFPWeekly":   {"Quota": 35000, "Used": 350, "ResetTime": 1782057600000}
          }
        }
        """
        let snap = try VolcengineAgentPlanResponseParser.parseUsage(data: Data(json.utf8))
        XCTAssertEqual(snap.buckets.count, 1)
        XCTAssertEqual(snap.buckets[0].id, "volcengineAgentPlan.weekly")
        XCTAssertEqual(snap.buckets[0].usedPercent, 1.0, accuracy: 0.0001)
    }

    func testZeroUsageIsAValidZeroPercentBucket() throws {
        let json = """
        {"Result": {"PlanType": "large", "AFPMonthly": {"Quota": 100000, "Used": 0, "ResetTime": 1784217599000}}}
        """
        let snap = try VolcengineAgentPlanResponseParser.parseUsage(data: Data(json.utf8))
        XCTAssertEqual(snap.buckets.count, 1)
        XCTAssertEqual(snap.buckets[0].id, "volcengineAgentPlan.monthly")
        XCTAssertEqual(snap.buckets[0].usedPercent, 0, accuracy: 0.0001)
    }

    func testInvalidStateMapsToNeedsLogin() {
        let json = """
        {"ResponseMetadata": {"Error": {"Code": "InvalidState", "Message": "登录态已更新"}}}
        """
        XCTAssertThrowsError(try VolcengineAgentPlanResponseParser.parseUsage(data: Data(json.utf8))) { error in
            guard let qe = error as? QuotaError, case .needsLogin = qe else {
                XCTFail("Expected needsLogin, got \(error)")
                return
            }
        }
    }

    func testRequestLimitMapsToRateLimited() {
        let json = """
        {"ResponseMetadata": {"Error": {"Code": "RequestLimitExceeded", "Message": "rate"}}}
        """
        XCTAssertThrowsError(try VolcengineAgentPlanResponseParser.parseUsage(data: Data(json.utf8))) { error in
            guard let qe = error as? QuotaError, case .rateLimited = qe else {
                XCTFail("Expected rateLimited, got \(error)")
                return
            }
        }
    }

    func testGenericErrorMapsToNetworkError() {
        let json = """
        {"ResponseMetadata": {"Error": {"Code": "InternalError", "Message": "boom"}}}
        """
        XCTAssertThrowsError(try VolcengineAgentPlanResponseParser.parseUsage(data: Data(json.utf8))) { error in
            guard let qe = error as? QuotaError, case .network = qe else {
                XCTFail("Expected network error, got \(error)")
                return
            }
        }
    }

    func testMissingResultBlockThrowsParseFailure() {
        let json = """
        {"ResponseMetadata": {"RequestId": "x"}}
        """
        XCTAssertThrowsError(try VolcengineAgentPlanResponseParser.parseUsage(data: Data(json.utf8))) { error in
            guard let qe = error as? QuotaError, case .parseFailure = qe else {
                XCTFail("Expected parseFailure, got \(error)")
                return
            }
        }
    }

    func testResultWithNoWindowsThrowsParseFailure() {
        let json = """
        {"Result": {"PlanType": "medium"}}
        """
        XCTAssertThrowsError(try VolcengineAgentPlanResponseParser.parseUsage(data: Data(json.utf8))) { error in
            guard let qe = error as? QuotaError, case .parseFailure = qe else {
                XCTFail("Expected parseFailure, got \(error)")
                return
            }
        }
    }

    func testEmptyBodyThrowsParseFailure() {
        XCTAssertThrowsError(try VolcengineAgentPlanResponseParser.parseUsage(data: Data())) { error in
            guard let qe = error as? QuotaError, case .parseFailure = qe else {
                XCTFail("Expected parseFailure, got \(error)")
                return
            }
        }
    }
}
