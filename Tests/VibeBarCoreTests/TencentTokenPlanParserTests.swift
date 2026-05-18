import XCTest
@testable import VibeBarCore

final class TencentTokenPlanParserTests: XCTestCase {

    // MARK: - Variant resolution

    func testVariantDefaultsToGenericForUnknownOrEmptySetting() {
        XCTAssertEqual(TencentTokenPlanVariant.from(settingsRegion: nil), .generic)
        XCTAssertEqual(TencentTokenPlanVariant.from(settingsRegion: ""), .generic)
        XCTAssertEqual(TencentTokenPlanVariant.from(settingsRegion: "generic"), .generic)
        XCTAssertEqual(TencentTokenPlanVariant.from(settingsRegion: "general"), .generic)
        XCTAssertEqual(TencentTokenPlanVariant.from(settingsRegion: "unknown"), .generic)
    }

    func testVariantResolvesHunyuanFromMultipleAliases() {
        XCTAssertEqual(TencentTokenPlanVariant.from(settingsRegion: "hunyuan"), .hunyuan)
        XCTAssertEqual(TencentTokenPlanVariant.from(settingsRegion: "HY"), .hunyuan)
        XCTAssertEqual(TencentTokenPlanVariant.from(settingsRegion: "hy3"), .hunyuan)
    }

    // MARK: - Time-window envelope (Coding Plan-style)

    func testParsesTimeWindowEnvelope() throws {
        // If Tencent ships Token Plan through the same DescribePkg
        // envelope as Coding Plan, all three time-window buckets must
        // be surfaced. The CGI wrapper is unwrapped first.
        let json = """
        {
          "code": 0,
          "data": {
            "code": 0,
            "cgwerrorCode": 0,
            "data": {
              "Response": {
                "PkgList": [
                  {
                    "PkgName": "Token Plan Pro",
                    "PkgType": "tokenplan",
                    "UsageDetail": {
                      "PerFiveHour": {
                        "Total": 6000, "Used": 200, "UsagePercent": 3.33,
                        "EndTime": "2026-05-09 03:43:15"
                      },
                      "PerWeek": {
                        "Total": 45000, "Used": 1000, "UsagePercent": 2.22,
                        "EndTime": "2026-05-11 00:00:00"
                      },
                      "PerMonth": {
                        "Total": 90000, "Used": 9000, "UsagePercent": 10.0,
                        "EndTime": "2026-05-24 00:00:00"
                      }
                    }
                  }
                ]
              }
            }
          }
        }
        """
        let snap = try TencentTokenPlanResponseParser.parse(
            data: Data(json.utf8),
            variant: .generic
        )
        XCTAssertEqual(snap.planName, "Token Plan Pro")
        XCTAssertEqual(snap.buckets.count, 3)
        XCTAssertEqual(snap.buckets[0].id, "tencentTokenPlan.generic.fiveHour")
        XCTAssertEqual(snap.buckets[0].usedPercent, 3.33, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[1].id, "tencentTokenPlan.generic.weekly")
        XCTAssertEqual(snap.buckets[2].id, "tencentTokenPlan.generic.monthly")
        XCTAssertEqual(snap.buckets[2].usedPercent, 10.0, accuracy: 0.01)
        XCTAssertNotNil(snap.buckets[0].resetAt)
    }

    func testTimeWindowBucketIdsCarryVariantPrefix() throws {
        // The bucket id namespace is per-variant so the cache stays
        // stable when a user clones an instance and toggles the other
        // variant.
        let json = """
        {
          "code": 0,
          "data": {
            "code": 0,
            "data": {
              "Response": {
                "PkgList": [{
                  "PkgName": "HY Token Plan",
                  "UsageDetail": {
                    "PerMonth": {
                      "Total": 100, "Used": 50, "UsagePercent": 50,
                      "EndTime": "2026-05-24 00:00:00"
                    }
                  }
                }]
              }
            }
          }
        }
        """
        let snap = try TencentTokenPlanResponseParser.parse(
            data: Data(json.utf8),
            variant: .hunyuan
        )
        XCTAssertEqual(snap.buckets.count, 1)
        XCTAssertEqual(snap.buckets[0].id, "tencentTokenPlan.hunyuan.monthly")
    }

    // MARK: - Credit envelope (Token Plan-style)

    func testParsesFlatCreditEnvelope() throws {
        // Token-style plans usually expose a flat credit counter
        // instead of time-windowed buckets. Surface a single
        // "Credits" bucket so the card renders.
        let json = """
        {
          "code": 0,
          "data": {
            "code": 0,
            "data": {
              "Response": {
                "PkgName": "Token Plan",
                "TotalCredits": 100000,
                "UsedCredits": 25000,
                "RemainingCredits": 75000,
                "EndTime": "2026-06-30 00:00:00"
              }
            }
          }
        }
        """
        let snap = try TencentTokenPlanResponseParser.parse(
            data: Data(json.utf8),
            variant: .generic
        )
        XCTAssertEqual(snap.buckets.count, 1)
        XCTAssertEqual(snap.buckets[0].id, "tencentTokenPlan.generic.credits")
        XCTAssertEqual(snap.buckets[0].usedPercent, 25.0, accuracy: 0.01)
        XCTAssertNotNil(snap.buckets[0].resetAt)
    }

    func testCreditEnvelopeFallsBackToRemainingWhenUsedMissing() throws {
        let json = """
        {
          "code": 0,
          "data": {
            "code": 0,
            "data": {
              "Response": {
                "TokenInfo": {
                  "TotalValue": 1000,
                  "SurplusValue": 250
                }
              }
            }
          }
        }
        """
        let snap = try TencentTokenPlanResponseParser.parse(
            data: Data(json.utf8),
            variant: .hunyuan
        )
        XCTAssertEqual(snap.buckets.count, 1)
        // (1000 - 250) / 1000 = 75% used.
        XCTAssertEqual(snap.buckets[0].usedPercent, 75.0, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[0].id, "tencentTokenPlan.hunyuan.credits")
        XCTAssertEqual(snap.buckets[0].groupTitle, "Hunyuan 3 Token Plan")
    }

    // MARK: - Error envelopes

    func testAuthFailureMapsToNeedsLogin() {
        let json = """
        {
          "code": 0,
          "data": {
            "code": 0,
            "data": {
              "Response": {
                "Error": {
                  "Code": "AuthFailure.SignatureExpire",
                  "Message": "Session Invalid"
                }
              }
            }
          }
        }
        """
        XCTAssertThrowsError(try TencentTokenPlanResponseParser.parse(
            data: Data(json.utf8),
            variant: .generic
        )) { error in
            guard let qe = error as? QuotaError, case .needsLogin = qe else {
                XCTFail("Expected needsLogin, got \(error)")
                return
            }
        }
    }

    func testCgiOuter401MapsToNeedsLogin() {
        let json = """
        {"code": 401, "message": "session expired", "data": null}
        """
        XCTAssertThrowsError(try TencentTokenPlanResponseParser.parse(
            data: Data(json.utf8),
            variant: .generic
        )) { error in
            guard let qe = error as? QuotaError, case .needsLogin = qe else {
                XCTFail("Expected needsLogin, got \(error)")
                return
            }
        }
    }

    func testChineseLoginMessageMapsToNeedsLogin() {
        let json = """
        {
          "code": 0,
          "data": {
            "code": 0,
            "data": {
              "Response": {
                "Error": {"Code": 4, "Message": "请登录后重试"}
              }
            }
          }
        }
        """
        XCTAssertThrowsError(try TencentTokenPlanResponseParser.parse(
            data: Data(json.utf8),
            variant: .hunyuan
        )) { error in
            guard let qe = error as? QuotaError, case .needsLogin = qe else {
                XCTFail("Expected needsLogin, got \(error)")
                return
            }
        }
    }

    func testRateLimitErrorMapsToRateLimited() {
        let json = """
        {
          "code": 0,
          "data": {
            "code": 0,
            "data": {
              "Response": {
                "Error": {"Code": "RequestLimitExceeded", "Message": "rate"}
              }
            }
          }
        }
        """
        XCTAssertThrowsError(try TencentTokenPlanResponseParser.parse(
            data: Data(json.utf8),
            variant: .generic
        )) { error in
            guard let qe = error as? QuotaError, case .rateLimited = qe else {
                XCTFail("Expected rateLimited, got \(error)")
                return
            }
        }
    }

    func testEmptyBodyThrowsParseFailure() {
        XCTAssertThrowsError(try TencentTokenPlanResponseParser.parse(
            data: Data(),
            variant: .generic
        )) { error in
            guard let qe = error as? QuotaError, case .parseFailure = qe else {
                XCTFail("Expected parseFailure, got \(error)")
                return
            }
        }
    }

    func testCgiEnvelopeWithoutUsableShapeThrowsParseFailure() {
        // Outer success, no PkgList and no credit fields anywhere —
        // we don't synthesise a card, we surface a parse failure so
        // the user knows the BFF returned something unexpected.
        let json = """
        {
          "code": 0,
          "data": {
            "code": 0,
            "data": {
              "Response": {
                "RequestId": "req-1"
              }
            }
          }
        }
        """
        XCTAssertThrowsError(try TencentTokenPlanResponseParser.parse(
            data: Data(json.utf8),
            variant: .generic
        )) { error in
            guard let qe = error as? QuotaError, case .parseFailure = qe else {
                XCTFail("Expected parseFailure, got \(error)")
                return
            }
        }
    }
}
