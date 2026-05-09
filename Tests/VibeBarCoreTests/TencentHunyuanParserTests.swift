import XCTest
@testable import VibeBarCore

final class TencentHunyuanParserTests: XCTestCase {
    func testParsesAllThreeWindows() throws {
        let json = """
        {
          "Response": {
            "RequestId": "req-1",
            "PkgList": [
              {
                "PkgName": "Coding Plan Pro",
                "PkgType": "pro",
                "UsagePercent": 3.18,
                "UsageDetail": {
                  "PerFiveHour": {
                    "Total": 6000, "Used": 191,
                    "UsagePercent": 3.18,
                    "EndTime": "2026-05-09 03:43:15"
                  },
                  "PerWeek": {
                    "Total": 45000, "Used": 5777,
                    "UsagePercent": 12.83,
                    "EndTime": "2026-05-11 00:00:00"
                  },
                  "PerMonth": {
                    "Total": 90000, "Used": 17588,
                    "UsagePercent": 19.54,
                    "EndTime": "2026-05-24 00:00:42"
                  }
                }
              }
            ]
          }
        }
        """
        let snap = try TencentHunyuanResponseParser.parse(data: Data(json.utf8))
        XCTAssertEqual(snap.planName, "Coding Plan Pro")
        XCTAssertEqual(snap.buckets.count, 3)
        XCTAssertEqual(snap.buckets[0].id, "tencentHunyuan.fiveHour")
        XCTAssertEqual(snap.buckets[0].usedPercent, 3.18, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[0].rawWindowSeconds, 5 * 3600)
        XCTAssertNotNil(snap.buckets[0].resetAt)

        XCTAssertEqual(snap.buckets[1].id, "tencentHunyuan.weekly")
        XCTAssertEqual(snap.buckets[1].usedPercent, 12.83, accuracy: 0.01)

        XCTAssertEqual(snap.buckets[2].id, "tencentHunyuan.monthly")
        XCTAssertEqual(snap.buckets[2].usedPercent, 19.54, accuracy: 0.01)
    }

    func testFallsBackToComputedPercentWhenMissing() throws {
        // Some plans don't surface UsagePercent — fall back to Used/Total.
        let json = """
        {
          "Response": {
            "PkgList": [
              {
                "PkgName": "Coding Plan Lite",
                "UsageDetail": {
                  "PerFiveHour": {"Total": 100, "Used": 25, "EndTime": "2026-05-09 03:43:15"},
                  "PerWeek":     {"Total": 1000, "Used": 100, "EndTime": "2026-05-11 00:00:00"},
                  "PerMonth":    {"Total": 5000, "Used": 250, "EndTime": "2026-05-24 00:00:00"}
                }
              }
            ]
          }
        }
        """
        let snap = try TencentHunyuanResponseParser.parse(data: Data(json.utf8))
        XCTAssertEqual(snap.buckets[0].usedPercent, 25.0, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[1].usedPercent, 10.0, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[2].usedPercent, 5.0, accuracy: 0.01)
    }

    func testSkipsWindowsWithNeitherPercentNorTotal() throws {
        // A plan that only carries the monthly window — earlier buckets
        // should be filtered out, not crash with NaN.
        let json = """
        {
          "Response": {
            "PkgList": [
              {
                "PkgName": "Lite",
                "UsageDetail": {
                  "PerFiveHour": null,
                  "PerWeek": null,
                  "PerMonth": {"Total": 100, "Used": 10, "UsagePercent": 10}
                }
              }
            ]
          }
        }
        """
        let snap = try TencentHunyuanResponseParser.parse(data: Data(json.utf8))
        XCTAssertEqual(snap.buckets.count, 1)
        XCTAssertEqual(snap.buckets[0].id, "tencentHunyuan.monthly")
    }

    func testNumericAuthErrorMapsToNeedsLogin() {
        let json = """
        {"Response": {"Error": {"Code": 401, "Message": "Unauthorized"}}}
        """
        XCTAssertThrowsError(try TencentHunyuanResponseParser.parse(data: Data(json.utf8))) { error in
            guard let qe = error as? QuotaError, case .needsLogin = qe else {
                XCTFail("Expected needsLogin, got \(error)")
                return
            }
        }
    }

    func testStringAuthFailureMapsToNeedsLogin() {
        let json = """
        {"Response": {"Error": {"Code": "AuthFailure.SignatureExpire", "Message": "Session Invalid"}}}
        """
        XCTAssertThrowsError(try TencentHunyuanResponseParser.parse(data: Data(json.utf8))) { error in
            guard let qe = error as? QuotaError, case .needsLogin = qe else {
                XCTFail("Expected needsLogin, got \(error)")
                return
            }
        }
    }

    func testChineseLoginMessageMapsToNeedsLogin() {
        let json = """
        {"Response": {"Error": {"Code": 4, "Message": "请登录后重试"}}}
        """
        XCTAssertThrowsError(try TencentHunyuanResponseParser.parse(data: Data(json.utf8))) { error in
            guard let qe = error as? QuotaError, case .needsLogin = qe else {
                XCTFail("Expected needsLogin, got \(error)")
                return
            }
        }
    }

    func testRequestLimitMapsToRateLimited() {
        let json = """
        {"Response": {"Error": {"Code": "RequestLimitExceeded", "Message": "rate"}}}
        """
        XCTAssertThrowsError(try TencentHunyuanResponseParser.parse(data: Data(json.utf8))) { error in
            guard let qe = error as? QuotaError, case .rateLimited = qe else {
                XCTFail("Expected rateLimited, got \(error)")
                return
            }
        }
    }

    func testParameterErrorMapsToNetworkError() {
        let json = """
        {"Response": {"Error": {"Code": 4, "Message": "参数有误，请检查后再试:参数不能为空"}}}
        """
        XCTAssertThrowsError(try TencentHunyuanResponseParser.parse(data: Data(json.utf8))) { error in
            guard let qe = error as? QuotaError, case .network = qe else {
                XCTFail("Expected network error, got \(error)")
                return
            }
        }
    }

    func testEmptyPkgListThrowsParseFailure() {
        let json = """
        {"Response": {"PkgList": []}}
        """
        XCTAssertThrowsError(try TencentHunyuanResponseParser.parse(data: Data(json.utf8))) { error in
            guard let qe = error as? QuotaError, case .parseFailure = qe else {
                XCTFail("Expected parseFailure, got \(error)")
                return
            }
        }
    }

    func testEndTimeParsedInShanghaiTimezone() throws {
        let json = """
        {
          "Response": {
            "PkgList": [
              {
                "PkgName": "X",
                "UsageDetail": {
                  "PerFiveHour": {
                    "Total": 100, "Used": 10, "UsagePercent": 10,
                    "EndTime": "2026-05-09 03:43:15"
                  }
                }
              }
            ]
          }
        }
        """
        let snap = try TencentHunyuanResponseParser.parse(data: Data(json.utf8))
        let resetAt = try XCTUnwrap(snap.buckets[0].resetAt)
        // 2026-05-09 03:43:15 Asia/Shanghai (+08:00) = 2026-05-08 19:43:15 UTC
        var components = DateComponents()
        components.year = 2026; components.month = 5; components.day = 8
        components.hour = 19; components.minute = 43; components.second = 15
        components.timeZone = TimeZone(identifier: "UTC")
        let calendar = Calendar(identifier: .gregorian)
        let expected = try XCTUnwrap(calendar.date(from: components))
        XCTAssertEqual(resetAt.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1)
    }

    func testEmptyBodyThrowsParseFailure() {
        XCTAssertThrowsError(try TencentHunyuanResponseParser.parse(data: Data())) { error in
            guard let qe = error as? QuotaError, case .parseFailure = qe else {
                XCTFail("Expected parseFailure, got \(error)")
                return
            }
        }
    }
}
