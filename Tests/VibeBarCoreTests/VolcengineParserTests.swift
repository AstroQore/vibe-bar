import XCTest
@testable import VibeBarCore

final class VolcengineParserTests: XCTestCase {
    func testParsesAllThreeBuckets() throws {
        let json = """
        {
          "ResponseMetadata": {"RequestId": "req-1"},
          "Result": {
            "Status": "Running",
            "UpdateTimestamp": 1778271028,
            "QuotaUsage": [
              {"Level": "session", "Percent": 25.0, "ResetTimestamp": 1778302618},
              {"Level": "weekly",  "Percent": 12.0, "ResetTimestamp": 1778649600},
              {"Level": "monthly", "Percent": 25.0, "ResetTimestamp": 1779148800}
            ]
          }
        }
        """
        let snap = try VolcengineResponseParser.parseUsage(data: Data(json.utf8))
        XCTAssertEqual(snap.buckets.count, 3)

        XCTAssertEqual(snap.buckets[0].id, "volcengine.session")
        XCTAssertEqual(snap.buckets[0].title, "5 Hours")
        XCTAssertEqual(snap.buckets[0].usedPercent, 25.0, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[0].rawWindowSeconds, 5 * 3600)
        XCTAssertEqual(snap.buckets[0].resetAt?.timeIntervalSince1970 ?? 0, 1778302618, accuracy: 1)

        XCTAssertEqual(snap.buckets[1].id, "volcengine.weekly")
        XCTAssertEqual(snap.buckets[1].usedPercent, 12.0, accuracy: 0.01)

        XCTAssertEqual(snap.buckets[2].id, "volcengine.monthly")
        XCTAssertEqual(snap.buckets[2].usedPercent, 25.0, accuracy: 0.01)
    }

    func testIgnoresUnknownLevels() throws {
        let json = """
        {
          "ResponseMetadata": {"RequestId": "x"},
          "Result": {
            "Status": "Running",
            "QuotaUsage": [
              {"Level": "session", "Percent": 10.0, "ResetTimestamp": 1},
              {"Level": "yearly",  "Percent": 99.0, "ResetTimestamp": 2},
              {"Level": "weekly",  "Percent": 20.0, "ResetTimestamp": 3}
            ]
          }
        }
        """
        let snap = try VolcengineResponseParser.parseUsage(data: Data(json.utf8))
        XCTAssertEqual(snap.buckets.count, 2)
        XCTAssertEqual(snap.buckets[0].id, "volcengine.session")
        XCTAssertEqual(snap.buckets[1].id, "volcengine.weekly")
    }

    func testInvalidStateMapsToNeedsLogin() {
        let json = """
        {"ResponseMetadata": {"Error": {"Code": "InvalidState", "Message": "登录态已更新"}}}
        """
        XCTAssertThrowsError(try VolcengineResponseParser.parseUsage(data: Data(json.utf8))) { error in
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
        XCTAssertThrowsError(try VolcengineResponseParser.parseUsage(data: Data(json.utf8))) { error in
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
        XCTAssertThrowsError(try VolcengineResponseParser.parseUsage(data: Data(json.utf8))) { error in
            guard let qe = error as? QuotaError, case .network = qe else {
                XCTFail("Expected network error, got \(error)")
                return
            }
        }
    }

    func testEmptyQuotaUsageThrowsParseFailure() {
        let json = """
        {"ResponseMetadata": {"RequestId": "x"}, "Result": {"Status": "Running", "QuotaUsage": []}}
        """
        XCTAssertThrowsError(try VolcengineResponseParser.parseUsage(data: Data(json.utf8))) { error in
            guard let qe = error as? QuotaError, case .parseFailure = qe else {
                XCTFail("Expected parseFailure, got \(error)")
                return
            }
        }
    }

    func testMissingResultBlockThrowsParseFailure() {
        let json = """
        {"ResponseMetadata": {"RequestId": "x"}}
        """
        XCTAssertThrowsError(try VolcengineResponseParser.parseUsage(data: Data(json.utf8))) { error in
            guard let qe = error as? QuotaError, case .parseFailure = qe else {
                XCTFail("Expected parseFailure, got \(error)")
                return
            }
        }
    }

    func testEmptyBodyThrowsParseFailure() {
        XCTAssertThrowsError(try VolcengineResponseParser.parseUsage(data: Data())) { error in
            guard let qe = error as? QuotaError, case .parseFailure = qe else {
                XCTFail("Expected parseFailure, got \(error)")
                return
            }
        }
    }

    func testParsePlanNameSurfacesCapitalizedBizInfo() throws {
        let json = """
        {
          "Result": {
            "InfoList": [
              {"BizInfo": "pro", "Status": "Active"},
              {"BizInfo": "lite", "Status": "Inactive"}
            ]
          }
        }
        """
        let plan = try VolcengineResponseParser.parsePlanName(data: Data(json.utf8))
        XCTAssertEqual(plan, "Coding Plan Pro")
    }

    func testParsePlanNameReturnsNilOnEmptyInfoList() throws {
        let json = """
        {"Result": {"InfoList": []}}
        """
        let plan = try VolcengineResponseParser.parsePlanName(data: Data(json.utf8))
        XCTAssertNil(plan)
    }
}
