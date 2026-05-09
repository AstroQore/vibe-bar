import XCTest
@testable import VibeBarCore

final class MimoParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_715_000_000)

    func testParsesMonthUsageHeadlineRow() throws {
        let json = """
        {
          "code": 0,
          "message": "",
          "data": {
            "monthUsage": {
              "percent": 0.2324,
              "items": [
                {
                  "name": "month_total_token",
                  "used": 162691481,
                  "limit": 700000000,
                  "percent": 0.2324
                }
              ]
            }
          }
        }
        """
        let snap = try MimoResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snap.buckets.count, 1)
        XCTAssertEqual(snap.buckets[0].id, "mimo.month")
        XCTAssertEqual(snap.buckets[0].title, "Monthly")
        // 162_691_481 / 700_000_000 ≈ 23.24%
        XCTAssertEqual(snap.buckets[0].usedPercent, 23.241640, accuracy: 0.01)
    }

    func testFallsBackToUsagePlanTotalWhenMonthUsageMissing() throws {
        let json = """
        {
          "code": 0,
          "data": {
            "usage": {
              "percent": 0.5,
              "items": [
                {"name": "plan_total_token", "used": 50, "limit": 100, "percent": 0.5},
                {"name": "compensation_total_token", "used": 0, "limit": 0, "percent": 0}
              ]
            }
          }
        }
        """
        let snap = try MimoResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snap.buckets.count, 1)
        XCTAssertEqual(snap.buckets[0].usedPercent, 50.0, accuracy: 0.01)
    }

    func testStringCoercedNumericCounters() throws {
        let json = """
        {
          "code": 0,
          "data": {
            "monthUsage": {
              "items": [
                {"name": "month_total_token", "used": "1234567890", "limit": "10000000000", "percent": 0.1234567}
              ]
            }
          }
        }
        """
        let snap = try MimoResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snap.buckets.count, 1)
        XCTAssertEqual(snap.buckets[0].usedPercent, 12.34567, accuracy: 0.01)
    }

    func testZeroLimitFallsBackToServerPercent() throws {
        // limit == 0 happens for compensation rows; if the headline row also
        // has limit == 0 we still want to surface the server-supplied percent
        // rather than NaN'ing. Synthetic case to lock that in.
        let json = """
        {
          "code": 0,
          "data": {
            "monthUsage": {
              "items": [
                {"name": "month_total_token", "used": 0, "limit": 0, "percent": 0.42}
              ]
            }
          }
        }
        """
        let snap = try MimoResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snap.buckets[0].usedPercent, 42.0, accuracy: 0.01)
    }

    func testMissingDataThrowsParseFailure() {
        let json = "{\"code\": 0}"
        XCTAssertThrowsError(try MimoResponseParser.parse(data: Data(json.utf8), now: now)) { error in
            guard let qe = error as? QuotaError, case .parseFailure = qe else {
                XCTFail("Expected parseFailure, got \(error)")
                return
            }
        }
    }

    func testNoMatchingItemThrowsParseFailure() {
        let json = """
        {
          "code": 0,
          "data": {
            "monthUsage": {"items": [{"name": "something_else", "used": 1, "limit": 10}]}
          }
        }
        """
        XCTAssertThrowsError(try MimoResponseParser.parse(data: Data(json.utf8), now: now)) { error in
            guard let qe = error as? QuotaError, case .parseFailure = qe else {
                XCTFail("Expected parseFailure, got \(error)")
                return
            }
        }
    }

    func testNonZeroCodeMapsToNetworkError() {
        let json = """
        {"code": 500, "message": "Internal server error"}
        """
        XCTAssertThrowsError(try MimoResponseParser.parse(data: Data(json.utf8), now: now)) { error in
            guard let qe = error as? QuotaError, case .network = qe else {
                XCTFail("Expected network error, got \(error)")
                return
            }
        }
    }

    func testCode401MapsToNeedsLogin() {
        let json = """
        {"code": 401, "message": "Unauthorized"}
        """
        XCTAssertThrowsError(try MimoResponseParser.parse(data: Data(json.utf8), now: now)) { error in
            guard let qe = error as? QuotaError, case .needsLogin = qe else {
                XCTFail("Expected needsLogin, got \(error)")
                return
            }
        }
    }

    func testEmptyBodyThrowsParseFailure() {
        XCTAssertThrowsError(try MimoResponseParser.parse(data: Data(), now: now)) { error in
            guard let qe = error as? QuotaError, case .parseFailure = qe else {
                XCTFail("Expected parseFailure, got \(error)")
                return
            }
        }
    }

    func testCookieSpecRequiresAllThreeNamedCookies() {
        let spec = MimoQuotaAdapter.cookieSpec
        XCTAssertEqual(spec.tool, .mimo)
        XCTAssertTrue(spec.requiredNames.contains("userId"))
        XCTAssertTrue(spec.requiredNames.contains("api-platform_slh"))
        XCTAssertTrue(spec.requiredNames.contains("api-platform_ph"))
        XCTAssertEqual(spec.requiredNames.count, 3)
        XCTAssertTrue(spec.domains.contains("platform.xiaomimimo.com"))
    }
}
