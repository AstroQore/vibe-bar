import XCTest
@testable import VibeBarCore

final class AlibabaParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_715_000_000)

    func testParsesFlatQuotaInfo() throws {
        let json = """
        {
          "code": 200,
          "data": {
            "codingPlanInstanceInfos": [
              {
                "planName": "Coding Plan Pro",
                "codingPlanQuotaInfo": {
                  "per5HourUsedQuota": 56,
                  "per5HourTotalQuota": 100,
                  "per5HourQuotaNextRefreshTime": 1715432400000,
                  "perWeekUsedQuota": 13,
                  "perWeekTotalQuota": 100,
                  "perWeekQuotaNextRefreshTime": 1715432400000,
                  "perBillMonthUsedQuota": 5,
                  "perBillMonthTotalQuota": 100,
                  "perBillMonthQuotaNextRefreshTime": 1717000000000
                }
              }
            ]
          }
        }
        """
        let snap = try AlibabaResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snap.planName, "Coding Plan Pro")
        XCTAssertEqual(snap.buckets.count, 3)

        XCTAssertEqual(snap.buckets[0].title, "5 Hours")
        XCTAssertEqual(snap.buckets[0].usedPercent, 56.0, accuracy: 0.01)
        XCTAssertNotNil(snap.buckets[0].resetAt)

        XCTAssertEqual(snap.buckets[1].title, "Weekly")
        XCTAssertEqual(snap.buckets[1].usedPercent, 13.0, accuracy: 0.01)

        XCTAssertEqual(snap.buckets[2].title, "Monthly")
        XCTAssertEqual(snap.buckets[2].usedPercent, 5.0, accuracy: 0.01)
    }

    func testHandlesPerFiveHourAndPerMonthAliases() throws {
        let json = """
        {
          "data": {
            "codingPlanQuotaInfo": {
              "perFiveHourUsedQuota": 10,
              "perFiveHourTotalQuota": 50,
              "perMonthUsedQuota": 80,
              "perMonthTotalQuota": 200
            }
          }
        }
        """
        let snap = try AlibabaResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snap.buckets.count, 2)
        XCTAssertEqual(snap.buckets[0].title, "5 Hours")
        XCTAssertEqual(snap.buckets[0].usedPercent, 20.0, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[1].title, "Monthly")
        XCTAssertEqual(snap.buckets[1].usedPercent, 40.0, accuracy: 0.01)
    }

    func testStringifiedNestedJSONIsExpanded() throws {
        // Alibaba sometimes wraps the data envelope as a stringified
        // JSON value inside the outer object. expandedJSON should
        // unwrap it before parsing.
        let nested = """
        {"codingPlanQuotaInfo":{"per5HourUsedQuota":3,"per5HourTotalQuota":10}}
        """.replacingOccurrences(of: "\"", with: "\\\"")
        let json = """
        {
          "data": "\(nested)"
        }
        """
        let snap = try AlibabaResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snap.buckets.count, 1)
        XCTAssertEqual(snap.buckets[0].title, "5 Hours")
        XCTAssertEqual(snap.buckets[0].usedPercent, 30.0, accuracy: 0.01)
    }

    func testApiKeyErrorThrowsNeedsLogin() {
        let json = """
        {
          "code": 401,
          "message": "API key invalid"
        }
        """
        XCTAssertThrowsError(try AlibabaResponseParser.parse(data: Data(json.utf8), now: now)) { error in
            guard let qe = error as? QuotaError, case .needsLogin = qe else {
                XCTFail("Expected QuotaError.needsLogin, got \(error)")
                return
            }
        }
    }

    func testConsoleNeedLoginStringCodeThrowsNeedsLogin() {
        // Real shape returned by bailian.console.aliyun.com when
        // the request lacks a console session, even with an API
        // key attached. We must classify this as needsLogin so the
        // misc card surfaces a sign-in hint.
        let json = """
        {"code":"ConsoleNeedLogin","message":"请登录","successResponse":false}
        """
        XCTAssertThrowsError(try AlibabaResponseParser.parse(data: Data(json.utf8), now: now)) { error in
            guard let qe = error as? QuotaError, case .needsLogin = qe else {
                XCTFail("Expected QuotaError.needsLogin, got \(error)")
                return
            }
        }
    }

    func testNotLoginStringCodeAlsoMapsToNeedsLogin() {
        let json = #"{"code":"NotLogin","message":"login required"}"#
        XCTAssertThrowsError(try AlibabaResponseParser.parse(data: Data(json.utf8), now: now)) { error in
            guard let qe = error as? QuotaError, case .needsLogin = qe else {
                XCTFail("Expected QuotaError.needsLogin, got \(error)")
                return
            }
        }
    }

    func testSuccessFalseWithUnknownCodeMapsToNetwork() {
        let json = #"{"code":"InvalidParameter","message":"bad input","successResponse":false}"#
        XCTAssertThrowsError(try AlibabaResponseParser.parse(data: Data(json.utf8), now: now)) { error in
            guard let qe = error as? QuotaError, case .network = qe else {
                XCTFail("Expected QuotaError.network, got \(error)")
                return
            }
        }
    }

    func testEmptyBodyThrowsParseFailure() {
        XCTAssertThrowsError(try AlibabaResponseParser.parse(data: Data(), now: now))
    }

    func testNoQuotaWindowsThrowsParseFailure() {
        // Quota envelope present but every total is zero / missing.
        let json = """
        {
          "data": {
            "codingPlanQuotaInfo": {
              "per5HourUsedQuota": 0,
              "per5HourTotalQuota": 0
            }
          }
        }
        """
        XCTAssertThrowsError(try AlibabaResponseParser.parse(data: Data(json.utf8), now: now)) { error in
            guard let qe = error as? QuotaError, case .parseFailure = qe else {
                XCTFail("Expected QuotaError.parseFailure, got \(error)")
                return
            }
        }
    }

    func testRegionURLs() {
        XCTAssertEqual(
            AlibabaRegion.international.apiKeyQuotaURL.host,
            "modelstudio.console.alibabacloud.com"
        )
        XCTAssertEqual(
            AlibabaRegion.chinaMainland.apiKeyQuotaURL.host,
            "bailian.console.aliyun.com"
        )
        // Region ID propagates to the query string.
        let intlQuery = AlibabaRegion.international.apiKeyQuotaURL.query ?? ""
        XCTAssertTrue(intlQuery.contains("currentRegionId=ap-southeast-1"))
        let cnQuery = AlibabaRegion.chinaMainland.apiKeyQuotaURL.query ?? ""
        XCTAssertTrue(cnQuery.contains("currentRegionId=cn-beijing"))
    }
}
