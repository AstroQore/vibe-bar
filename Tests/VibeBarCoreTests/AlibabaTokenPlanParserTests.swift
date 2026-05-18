import XCTest
@testable import VibeBarCore

final class AlibabaTokenPlanParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_715_000_000)
    private let cnProductCode = "sfm_tokenplanteams_dp_cn"

    // MARK: - Happy path (captured from the live console)

    func testParsesSeatSubscriptionSummaryWithStandardCredits() throws {
        // This is the live shape captured from the Token Plan dashboard
        // (with the BSS request id swapped out for a synthetic value).
        let json = """
        {
          "code": "200",
          "data": {
            "RequestId": "00000000-0000-0000-0000-000000000000",
            "Message": "Successful!",
            "Data": {
              "Uid": 1234567890,
              "EndTime": 1781769600000,
              "ProductCode": "sfm_tokenplanteams_dp_cn",
              "StartTime": 1779091200000,
              "RemainingDays": "30",
              "SubscriptionGroupList": [
                {
                  "SubscriptionAssignedNumber": 1,
                  "EquityList": [
                    {
                      "EquityCode": "credit_value",
                      "TotalValue": "25000.00000000",
                      "EquityType": "CREDITS",
                      "SurplusValue": "24999.55340000"
                    }
                  ],
                  "SpecType": "standard",
                  "SubscriptionTotalNumber": 1,
                  "NextCycleFlushTime": 1781769600000
                }
              ]
            },
            "Code": "Success",
            "Success": true
          },
          "httpStatusCode": "200",
          "successResponse": true
        }
        """
        let snap = try AlibabaTokenPlanResponseParser.parse(
            data: Data(json.utf8),
            productCode: cnProductCode,
            now: now
        )
        XCTAssertEqual(snap.buckets.count, 1)
        let bucket = snap.buckets[0]
        XCTAssertEqual(bucket.id, "alibabaTokenPlan.\(cnProductCode).standard")
        XCTAssertEqual(bucket.groupTitle, "Standard")
        // (25000 - 24999.5534) / 25000 * 100 ≈ 0.001786
        XCTAssertEqual(bucket.usedPercent, 0.001786, accuracy: 0.001)
        XCTAssertNotNil(bucket.resetAt)
        XCTAssertEqual(
            bucket.resetAt?.timeIntervalSince1970 ?? 0,
            1781769600,
            accuracy: 0.5
        )
    }

    func testMultipleSpecTiersBecomeMultipleBuckets() throws {
        let json = """
        {
          "code": "200",
          "data": {
            "Data": {
              "SubscriptionGroupList": [
                {
                  "SpecType": "standard",
                  "EquityList": [{
                    "EquityCode": "credit_value",
                    "TotalValue": "100",
                    "SurplusValue": "75"
                  }],
                  "NextCycleFlushTime": 1781769600000
                },
                {
                  "SpecType": "advanced",
                  "EquityList": [{
                    "EquityCode": "credit_value",
                    "TotalValue": "200",
                    "SurplusValue": "50"
                  }]
                }
              ]
            },
            "Success": true
          }
        }
        """
        let snap = try AlibabaTokenPlanResponseParser.parse(
            data: Data(json.utf8),
            productCode: cnProductCode,
            now: now
        )
        XCTAssertEqual(snap.buckets.count, 2)
        XCTAssertEqual(snap.buckets[0].usedPercent, 25.0, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[1].usedPercent, 75.0, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[0].groupTitle, "Standard")
        XCTAssertEqual(snap.buckets[1].groupTitle, "Advanced")
    }

    func testFallsBackToFlatTotalValueWhenNoGroupList() throws {
        // The simpler GetSubscriptionSummary response shape carries the
        // aggregate in `TotalValue` / `TotalSurplusValue` without a
        // SubscriptionGroupList. The parser surfaces a single
        // aggregate bucket in that case.
        let json = """
        {
          "code": "200",
          "data": {
            "Data": {
              "TotalSurplusValue": "8000",
              "TotalValue": "10000",
              "ProductCode": "sfm_tokenplanteams_dp_cn",
              "NearestExpireDate": 1781769600000
            },
            "Success": true
          }
        }
        """
        let snap = try AlibabaTokenPlanResponseParser.parse(
            data: Data(json.utf8),
            productCode: cnProductCode,
            now: now
        )
        XCTAssertEqual(snap.buckets.count, 1)
        XCTAssertEqual(snap.buckets[0].id, "alibabaTokenPlan.\(cnProductCode).summary")
        XCTAssertEqual(snap.buckets[0].usedPercent, 20.0, accuracy: 0.01)
        XCTAssertNotNil(snap.buckets[0].resetAt)
    }

    // MARK: - Error envelopes

    func testConsoleNeedLoginStringCodeThrowsNeedsLogin() {
        let json = """
        {"code":"ConsoleNeedLogin","message":"请登录","successResponse":false}
        """
        XCTAssertThrowsError(try AlibabaTokenPlanResponseParser.parse(
            data: Data(json.utf8),
            productCode: cnProductCode,
            now: now
        )) { error in
            guard let qe = error as? QuotaError, case .needsLogin = qe else {
                XCTFail("Expected QuotaError.needsLogin, got \(error)")
                return
            }
        }
    }

    func testSuccessFalseMapsToNetwork() {
        let json = """
        {"code":"InvalidParameter","message":"bad input","successResponse":false}
        """
        XCTAssertThrowsError(try AlibabaTokenPlanResponseParser.parse(
            data: Data(json.utf8),
            productCode: cnProductCode,
            now: now
        )) { error in
            guard let qe = error as? QuotaError, case .network = qe else {
                XCTFail("Expected QuotaError.network, got \(error)")
                return
            }
        }
    }

    func testEmptyBodyThrowsParseFailure() {
        XCTAssertThrowsError(try AlibabaTokenPlanResponseParser.parse(
            data: Data(),
            productCode: cnProductCode,
            now: now
        ))
    }

    func testEmptySubscriptionGroupListThrowsParseFailure() {
        // User signed in to a console session that lacks a Token Plan
        // subscription — the BFF still returns a 200/Success envelope
        // but with an empty group list and no flat totals.
        let json = """
        {
          "code": "200",
          "data": {
            "Data": {
              "SubscriptionGroupList": []
            },
            "Success": true
          }
        }
        """
        XCTAssertThrowsError(try AlibabaTokenPlanResponseParser.parse(
            data: Data(json.utf8),
            productCode: cnProductCode,
            now: now
        )) { error in
            guard let qe = error as? QuotaError, case .parseFailure = qe else {
                XCTFail("Expected QuotaError.parseFailure, got \(error)")
                return
            }
        }
    }

    // MARK: - Region wiring

    func testRegionURLs() {
        XCTAssertEqual(
            AlibabaTokenPlanRegion.chinaMainland.consoleRPCURL.host,
            "bailian.console.aliyun.com"
        )
        XCTAssertEqual(
            AlibabaTokenPlanRegion.international.consoleRPCURL.host,
            "modelstudio.console.alibabacloud.com"
        )
        // RPC URL carries the action + product as query parameters so
        // gateway-side routing sees the same shape the browser uses.
        let cnQuery = AlibabaTokenPlanRegion.chinaMainland.consoleRPCURL.query ?? ""
        XCTAssertTrue(cnQuery.contains("action=GetSeatSubscriptionSummary"))
        XCTAssertTrue(cnQuery.contains("product=BssOpenAPI-V3"))

        // BSS body-region is independent of the user-facing region ID
        // — China site billing lives in cn-qingdao.
        XCTAssertEqual(AlibabaTokenPlanRegion.chinaMainland.bssRegion, "cn-qingdao")
        XCTAssertEqual(AlibabaTokenPlanRegion.international.bssRegion, "ap-southeast-1")

        // Product codes follow the `_dp_cn` / `_dp_intl` Aliyun
        // convention used by the Coding Plan adapter as well.
        XCTAssertEqual(
            AlibabaTokenPlanRegion.chinaMainland.productCode,
            "sfm_tokenplanteams_dp_cn"
        )
        XCTAssertEqual(
            AlibabaTokenPlanRegion.international.productCode,
            "sfm_tokenplanteams_dp_intl"
        )
    }
}
