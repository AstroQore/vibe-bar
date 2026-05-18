import XCTest
@testable import VibeBarCore

final class BaiduQianfanParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_715_000_000)

    // MARK: - Happy path (captured from the live console)

    func testParsesResourceListWithThreeQuotaWindows() throws {
        // Captured from `/api/qianfan/charge/codingPlan/resourceList`
        // on a `Coding Plan Pro` account, with personal identifiers
        // swapped out for synthetic values.
        let json = """
        {
          "success": true,
          "result": {
            "totalCount": 1,
            "items": [
              {
                "resourceId": "cp-EXAMPLEAAA",
                "planType": "PRO",
                "resourceStatus": "Running",
                "effectiveAt": "2026-05-18T20:55:19+08:00",
                "expiresAt": "2026-06-18T20:55:19+08:00",
                "quota": {
                  "fiveHour": {
                    "used": 300,
                    "limit": 6000,
                    "resetAt": "2026-05-19T02:00:00+08:00"
                  },
                  "week": {
                    "used": 4500,
                    "limit": 45000,
                    "resetAt": "2026-05-25T00:00:00+08:00"
                  },
                  "month": {
                    "used": 9000,
                    "limit": 90000,
                    "resetAt": "2026-06-18T20:55:19+08:00"
                  }
                }
              }
            ]
          },
          "log_id": "3206732019"
        }
        """
        let snap = try BaiduQianfanResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snap.buckets.count, 3)
        XCTAssertEqual(snap.planName, "Pro")

        let fiveHour = snap.buckets[0]
        XCTAssertEqual(fiveHour.id, "baiduQianfan.5h")
        XCTAssertEqual(fiveHour.usedPercent, 5.0, accuracy: 0.01)
        XCTAssertEqual(fiveHour.rawWindowSeconds, 5 * 3600)
        XCTAssertNotNil(fiveHour.resetAt)

        let weekly = snap.buckets[1]
        XCTAssertEqual(weekly.id, "baiduQianfan.weekly")
        XCTAssertEqual(weekly.usedPercent, 10.0, accuracy: 0.01)
        XCTAssertEqual(weekly.rawWindowSeconds, 7 * 86_400)

        let monthly = snap.buckets[2]
        XCTAssertEqual(monthly.id, "baiduQianfan.monthly")
        XCTAssertEqual(monthly.usedPercent, 10.0, accuracy: 0.01)
        XCTAssertNil(monthly.rawWindowSeconds)
        XCTAssertNotNil(monthly.resetAt)
    }

    func testSkipsWindowsWithZeroLimit() throws {
        // A user on a plan that doesn't include a weekly cap — the
        // dashboard ships the field as 0/0 with a present `resetAt`.
        // The parser must drop it rather than emit a divide-by-zero
        // 100%-used bucket.
        let json = """
        {
          "success": true,
          "result": {
            "items": [{
              "planType": "BASIC",
              "resourceStatus": "Running",
              "quota": {
                "fiveHour": {"used": 5, "limit": 1000, "resetAt": "2026-05-19T02:00:00+08:00"},
                "week": {"used": 0, "limit": 0, "resetAt": null},
                "month": {"used": 100, "limit": 5000, "resetAt": "2026-06-18T20:55:19+08:00"}
              }
            }]
          }
        }
        """
        let snap = try BaiduQianfanResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snap.buckets.count, 2)
        XCTAssertEqual(snap.buckets.map(\.id),
                       ["baiduQianfan.5h", "baiduQianfan.monthly"])
        XCTAssertEqual(snap.planName, "Basic")
    }

    func testPrefersRunningResourceOverExpiredOne() throws {
        // BCE lists historical resources too. The parser should pick
        // the active row even when it isn't first.
        let json = """
        {
          "success": true,
          "result": {
            "items": [
              {
                "planType": "BASIC",
                "resourceStatus": "Expired",
                "quota": {
                  "fiveHour": {"used": 0, "limit": 1000, "resetAt": null}
                }
              },
              {
                "planType": "PRO",
                "resourceStatus": "Running",
                "quota": {
                  "fiveHour": {"used": 60, "limit": 6000, "resetAt": "2026-05-19T02:00:00+08:00"}
                }
              }
            ]
          }
        }
        """
        let snap = try BaiduQianfanResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snap.buckets.count, 1)
        XCTAssertEqual(snap.planName, "Pro")
        XCTAssertEqual(snap.buckets[0].usedPercent, 1.0, accuracy: 0.001)
    }

    func testFallsBackToFirstQuotaWhenNoRunningRow() throws {
        // No `Running` row, but the only listed plan still has a usable
        // quota envelope — surface it so the user sees `0 left` rather
        // than a generic "no plans" error.
        let json = """
        {
          "success": true,
          "result": {
            "items": [{
              "planType": "PRO",
              "resourceStatus": "PendingRenew",
              "quota": {
                "month": {"used": 90000, "limit": 90000, "resetAt": "2026-06-18T20:55:19+08:00"}
              }
            }]
          }
        }
        """
        let snap = try BaiduQianfanResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snap.buckets.count, 1)
        XCTAssertEqual(snap.buckets[0].usedPercent, 100.0, accuracy: 0.001)
    }

    // MARK: - Error envelopes

    func testNeedLoginCodeMapsToNeedsLogin() {
        let json = """
        {"success": false, "code": "NeedLogin", "message": "请登录"}
        """
        XCTAssertThrowsError(try BaiduQianfanResponseParser.parse(
            data: Data(json.utf8),
            now: now
        )) { error in
            guard let qe = error as? QuotaError, case .needsLogin = qe else {
                XCTFail("Expected QuotaError.needsLogin, got \(error)")
                return
            }
        }
    }

    func testForbiddenCodeMapsToNeedsLogin() {
        let json = """
        {"success": false, "code": "Forbidden", "message": "no permission"}
        """
        XCTAssertThrowsError(try BaiduQianfanResponseParser.parse(
            data: Data(json.utf8),
            now: now
        )) { error in
            guard let qe = error as? QuotaError, case .needsLogin = qe else {
                XCTFail("Expected QuotaError.needsLogin, got \(error)")
                return
            }
        }
    }

    func testGenericFailureMapsToNetwork() {
        let json = """
        {"success": false, "code": "InvalidParameter", "message": "missing field"}
        """
        XCTAssertThrowsError(try BaiduQianfanResponseParser.parse(
            data: Data(json.utf8),
            now: now
        )) { error in
            guard let qe = error as? QuotaError, case .network = qe else {
                XCTFail("Expected QuotaError.network, got \(error)")
                return
            }
        }
    }

    func testEmptyBodyThrowsParseFailure() {
        XCTAssertThrowsError(try BaiduQianfanResponseParser.parse(
            data: Data(),
            now: now
        )) { error in
            guard let qe = error as? QuotaError, case .parseFailure = qe else {
                XCTFail("Expected QuotaError.parseFailure, got \(error)")
                return
            }
        }
    }

    func testEmptyItemsArrayThrowsParseFailure() {
        let json = """
        {"success": true, "result": {"totalCount": 0, "items": []}}
        """
        XCTAssertThrowsError(try BaiduQianfanResponseParser.parse(
            data: Data(json.utf8),
            now: now
        )) { error in
            guard let qe = error as? QuotaError, case .parseFailure = qe else {
                XCTFail("Expected QuotaError.parseFailure, got \(error)")
                return
            }
        }
    }

    // MARK: - Plan name normalisation

    func testPlanNameNormalisation() throws {
        // Title-case the well-known tiers; pass other enum values
        // through with underscore-to-space splitting so we never
        // surface raw ENTERPRISE_V2 strings in the UI.
        let basis: [(raw: String, expected: String)] = [
            ("PRO", "Pro"),
            ("BASIC", "Basic"),
            ("FREE", "Free"),
            ("TRIAL", "Trial"),
            ("ENTERPRISE_V2", "Enterprise V2"),
            ("standard", "Standard")
        ]
        for (raw, expected) in basis {
            let json = """
            {
              "success": true,
              "result": {
                "items": [{
                  "planType": "\(raw)",
                  "resourceStatus": "Running",
                  "quota": {
                    "fiveHour": {"used": 1, "limit": 100, "resetAt": "2026-05-19T02:00:00+08:00"}
                  }
                }]
              }
            }
            """
            let snap = try BaiduQianfanResponseParser.parse(data: Data(json.utf8), now: now)
            XCTAssertEqual(snap.planName, expected, "planType=\(raw)")
        }
    }
}
