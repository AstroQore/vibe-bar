import XCTest
@testable import VibeBarCore

final class IFlyTekParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_715_000_000)

    func testParsesActiveRowWithThreeBuckets() throws {
        let json = """
        {
          "code": 0,
          "data": {
            "page": 1,
            "total": 2,
            "rows": [
              {
                "id": 1111,
                "expiresAt": "2026-04-15 10:00:00",
                "codingPlanUsageDTO": {
                  "dailyLimit": null, "dailyUsage": null,
                  "rp5hLimit": null, "rp5hUsage": null,
                  "rpwLimit": null, "rpwUsage": null,
                  "packageLimit": null, "packageUsage": null
                }
              },
              {
                "id": 2611051064654849,
                "expiresAt": "2026-05-22 14:49:10",
                "codingPlanUsageDTO": {
                  "dailyLimit": null, "dailyUsage": null,
                  "rp5hLimit": 6000, "rp5hUsage": 83,
                  "rpwLimit": 45000, "rpwUsage": 4547,
                  "packageLimit": 90000, "packageUsage": 4555,
                  "packageLeft": 85445
                }
              }
            ]
          }
        }
        """
        let snap = try IFlyTekResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snap.buckets.count, 3)

        XCTAssertEqual(snap.buckets[0].id, "iflytek.fiveHour")
        XCTAssertEqual(snap.buckets[0].title, "5 Hours")
        // 83 / 6000 ≈ 1.383%
        XCTAssertEqual(snap.buckets[0].usedPercent, 1.383, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[0].rawWindowSeconds, 5 * 3600)

        XCTAssertEqual(snap.buckets[1].id, "iflytek.weekly")
        // 4547 / 45000 ≈ 10.10%
        XCTAssertEqual(snap.buckets[1].usedPercent, 10.104, accuracy: 0.01)

        XCTAssertEqual(snap.buckets[2].id, "iflytek.package")
        // 4555 / 90000 ≈ 5.06%
        XCTAssertEqual(snap.buckets[2].usedPercent, 5.061, accuracy: 0.01)
        XCTAssertNotNil(snap.buckets[2].resetAt, "package bucket should carry expiresAt")
    }

    func testIncludesDailyBucketWhenLimitNonZero() throws {
        let json = """
        {
          "code": 0,
          "data": {
            "rows": [
              {
                "expiresAt": "2026-06-01 00:00:00",
                "codingPlanUsageDTO": {
                  "dailyLimit": 1000, "dailyUsage": 200,
                  "rp5hLimit": 500, "rp5hUsage": 100,
                  "rpwLimit": null, "rpwUsage": null,
                  "packageLimit": 30000, "packageUsage": 1500
                }
              }
            ]
          }
        }
        """
        let snap = try IFlyTekResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snap.buckets.count, 3)
        XCTAssertEqual(snap.buckets[0].id, "iflytek.daily")
        XCTAssertEqual(snap.buckets[0].usedPercent, 20.0, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[1].id, "iflytek.fiveHour")
        XCTAssertEqual(snap.buckets[2].id, "iflytek.package")
    }

    func testFiltersUnpaidRowsWhereAllLimitsAreNull() {
        let json = """
        {
          "code": 0,
          "data": {
            "rows": [
              {
                "expiresAt": null,
                "codingPlanUsageDTO": {
                  "dailyLimit": null, "dailyUsage": null,
                  "rp5hLimit": null, "rp5hUsage": null,
                  "rpwLimit": null, "rpwUsage": null,
                  "packageLimit": null, "packageUsage": null
                }
              }
            ]
          }
        }
        """
        XCTAssertThrowsError(try IFlyTekResponseParser.parse(data: Data(json.utf8), now: now)) { error in
            guard let qe = error as? QuotaError, case .parseFailure = qe else {
                XCTFail("Expected parseFailure, got \(error)")
                return
            }
        }
    }

    func testCode4001MapsToNeedsLogin() {
        let json = """
        {"code": 4001, "failed": true, "message": "用户未登录", "succeed": false}
        """
        XCTAssertThrowsError(try IFlyTekResponseParser.parse(data: Data(json.utf8), now: now)) { error in
            guard let qe = error as? QuotaError, case .needsLogin = qe else {
                XCTFail("Expected needsLogin, got \(error)")
                return
            }
        }
    }

    func testNonZeroNonAuthCodeMapsToNetworkError() {
        let json = """
        {"code": 5000, "message": "internal"}
        """
        XCTAssertThrowsError(try IFlyTekResponseParser.parse(data: Data(json.utf8), now: now)) { error in
            guard let qe = error as? QuotaError, case .network = qe else {
                XCTFail("Expected network error, got \(error)")
                return
            }
        }
    }

    func testEmptyRowsThrowsParseFailure() {
        let json = """
        {"code": 0, "data": {"rows": []}}
        """
        XCTAssertThrowsError(try IFlyTekResponseParser.parse(data: Data(json.utf8), now: now)) { error in
            guard let qe = error as? QuotaError, case .parseFailure = qe else {
                XCTFail("Expected parseFailure, got \(error)")
                return
            }
        }
    }

    func testExpiresAtParsedInShanghaiTimezone() throws {
        // 2026-05-22 14:49:10 in Asia/Shanghai (UTC+8) is
        // 2026-05-22 06:49:10 UTC.
        let json = """
        {
          "code": 0,
          "data": {
            "rows": [
              {
                "expiresAt": "2026-05-22 14:49:10",
                "codingPlanUsageDTO": {
                  "dailyLimit": null, "dailyUsage": null,
                  "rp5hLimit": null, "rp5hUsage": null,
                  "rpwLimit": null, "rpwUsage": null,
                  "packageLimit": 100, "packageUsage": 0
                }
              }
            ]
          }
        }
        """
        let snap = try IFlyTekResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snap.buckets.count, 1)
        let resetAt = try XCTUnwrap(snap.buckets[0].resetAt)
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 22
        components.hour = 6
        components.minute = 49
        components.second = 10
        components.timeZone = TimeZone(identifier: "UTC")
        let calendar = Calendar(identifier: .gregorian)
        let expected = try XCTUnwrap(calendar.date(from: components))
        XCTAssertEqual(resetAt.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1)
    }

    func testEmptyBodyThrowsParseFailure() {
        XCTAssertThrowsError(try IFlyTekResponseParser.parse(data: Data(), now: now)) { error in
            guard let qe = error as? QuotaError, case .parseFailure = qe else {
                XCTFail("Expected parseFailure, got \(error)")
                return
            }
        }
    }

    func testCookieSpecRequiresAtpAuthToken() {
        let spec = IFlyTekQuotaAdapter.cookieSpec
        XCTAssertEqual(spec.tool, .iflytek)
        XCTAssertEqual(
            spec.requiredNames,
            ["atp-auth-token", "account_id", "ssoSessionId", "tenantToken"]
        )
        XCTAssertTrue(spec.domains.contains("maas.xfyun.cn"))
        XCTAssertTrue(spec.domains.contains(".xfyun.cn"))
    }
}
