import XCTest
@testable import VibeBarCore

final class TencentTokenPlanParserTests: XCTestCase {

    // MARK: - Variant resolution

    func testVariantDefaultsToGenericForUnknownOrEmptySetting() {
        XCTAssertEqual(TencentTokenPlanVariant.from(settingsRegion: nil), .generic)
        XCTAssertEqual(TencentTokenPlanVariant.from(settingsRegion: ""), .generic)
        XCTAssertEqual(TencentTokenPlanVariant.from(settingsRegion: "generic"), .generic)
        XCTAssertEqual(TencentTokenPlanVariant.from(settingsRegion: "personal"), .generic)
        XCTAssertEqual(TencentTokenPlanVariant.from(settingsRegion: "unknown"), .generic)
    }

    func testVariantResolvesHunyuanFromMultipleAliases() {
        XCTAssertEqual(TencentTokenPlanVariant.from(settingsRegion: "hunyuan"), .hunyuan)
        XCTAssertEqual(TencentTokenPlanVariant.from(settingsRegion: "HY"), .hunyuan)
        XCTAssertEqual(TencentTokenPlanVariant.from(settingsRegion: "hy3"), .hunyuan)
    }

    func testEditionParamMapsVariantsToBffEditionString() {
        XCTAssertEqual(TencentTokenPlanVariant.generic.editionParam, "personal")
        XCTAssertEqual(TencentTokenPlanVariant.hunyuan.editionParam, "hunyuan")
    }

    // MARK: - Live shape (captured from console)

    /// Captured 2026-05 from `console.cloud.tencent.com/tokenhub/tokenplan`
    /// with `Edition: "personal"`. Numbers are real shape; identifiers
    /// are scrubbed.
    func testParsesPersonalEditionEnvelope() throws {
        let json = """
        {
          "code": 0,
          "data": {
            "code": 0,
            "cgwerrorCode": 0,
            "data": {
              "Response": {
                "RequestId": "00000000-0000-0000-0000-000000000000",
                "TokenPlanUsageList": [
                  {
                    "TokenPlanPackage": {
                      "Plan": "tp_standard",
                      "Level": 2,
                      "QuotaStatus": 1,
                      "StartTime": "2026-05-19 00:17:00",
                      "ExpireTime": "2026-06-19 00:16:59",
                      "ResourceId": "sp_lmp_tokenplan-example-1",
                      "RenewFlag": 0
                    },
                    "TokenPlanResource": {
                      "RemainCycles": "0",
                      "CycleCapacity": "100000000",
                      "CycleRemain": "99999949",
                      "CycleTotalUsage": "51",
                      "CycleInputUsage": "43",
                      "CycleOutputUsage": "8",
                      "CycleCacheUsage": "0"
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
        XCTAssertEqual(snap.planName, "Standard")
        XCTAssertEqual(snap.buckets.count, 1)
        let bucket = snap.buckets[0]
        XCTAssertEqual(bucket.id, "tencentTokenPlan.generic.tp_standard")
        XCTAssertEqual(bucket.groupTitle, "Standard")
        // 51 / 100_000_000 * 100 ≈ 0.000051
        XCTAssertEqual(bucket.usedPercent, 0.000051, accuracy: 0.00001)
        XCTAssertNotNil(bucket.resetAt)
    }

    /// Captured 2026-05 from `Edition: "hunyuan"`. Same response
    /// envelope, different `Plan` code (`tp_hy_standard`).
    func testParsesHunyuanEditionEnvelope() throws {
        let json = """
        {
          "code": 0,
          "data": {
            "code": 0,
            "cgwerrorCode": 0,
            "data": {
              "Response": {
                "RequestId": "00000000-0000-0000-0000-000000000000",
                "TokenPlanUsageList": [
                  {
                    "TokenPlanPackage": {
                      "Plan": "tp_hy_standard",
                      "Level": 2,
                      "QuotaStatus": 1,
                      "StartTime": "2026-05-16 04:23:00",
                      "ExpireTime": "2026-06-16 04:22:59"
                    },
                    "TokenPlanResource": {
                      "CycleCapacity": "100000000",
                      "CycleRemain": "98149494",
                      "CycleTotalUsage": "1850506"
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
            variant: .hunyuan
        )
        XCTAssertEqual(snap.planName, "HY Standard")
        XCTAssertEqual(snap.buckets.count, 1)
        let bucket = snap.buckets[0]
        XCTAssertEqual(bucket.id, "tencentTokenPlan.hunyuan.tp_hy_standard")
        XCTAssertEqual(bucket.groupTitle, "HY Standard")
        // 1_850_506 / 100_000_000 * 100 ≈ 1.85
        XCTAssertEqual(bucket.usedPercent, 1.850506, accuracy: 0.001)
        XCTAssertNotNil(bucket.resetAt)
    }

    func testFallsBackToRemainWhenCycleTotalUsageMissing() throws {
        // Defensive — if Tencent ever omits CycleTotalUsage, derive it
        // from capacity - remain.
        let json = """
        {
          "code": 0,
          "data": {
            "code": 0,
            "data": {
              "Response": {
                "TokenPlanUsageList": [
                  {
                    "TokenPlanPackage": {
                      "Plan": "tp_hy_pro",
                      "ExpireTime": "2026-06-30 00:00:00"
                    },
                    "TokenPlanResource": {
                      "CycleCapacity": "1000",
                      "CycleRemain": "250"
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
            variant: .hunyuan
        )
        XCTAssertEqual(snap.buckets.count, 1)
        XCTAssertEqual(snap.buckets[0].usedPercent, 75.0, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[0].id, "tencentTokenPlan.hunyuan.tp_hy_pro")
        XCTAssertEqual(snap.buckets[0].groupTitle, "HY Pro")
    }

    func testMultipleUsageEntriesSurfaceAsMultipleBuckets() throws {
        // A user could in principle hold more than one Token Plan
        // subscription per edition (e.g. a primary + a top-up). The
        // parser surfaces one bucket per entry.
        let json = """
        {
          "code": 0,
          "data": {
            "code": 0,
            "data": {
              "Response": {
                "TokenPlanUsageList": [
                  {
                    "TokenPlanPackage": {"Plan": "tp_standard", "ExpireTime": "2026-06-19 00:00:00"},
                    "TokenPlanResource": {"CycleCapacity": "100", "CycleRemain": "75", "CycleTotalUsage": "25"}
                  },
                  {
                    "TokenPlanPackage": {"Plan": "tp_pro", "ExpireTime": "2026-07-19 00:00:00"},
                    "TokenPlanResource": {"CycleCapacity": "200", "CycleRemain": "100", "CycleTotalUsage": "100"}
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
        XCTAssertEqual(snap.buckets.count, 2)
        XCTAssertEqual(snap.buckets[0].usedPercent, 25.0, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[0].id, "tencentTokenPlan.generic.tp_standard")
        XCTAssertEqual(snap.buckets[1].usedPercent, 50.0, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[1].id, "tencentTokenPlan.generic.tp_pro")
    }

    // MARK: - Error envelopes

    func testUnknownParameterMapsToNetworkError() {
        // Captured shape — what the BFF returns when an unrecognised
        // parameter (e.g. `PkgType: "tokenplan"`) is sent in the body.
        // The outer `code` is a string, not 0, but data.data.Response
        // still carries the Error envelope.
        let json = """
        {
          "code": "UnknownParameter",
          "mccode": "UnknownParameter",
          "data": {
            "code": "UnknownParameter",
            "cgwerrorCode": "UnknownParameter",
            "data": {
              "Response": {
                "Error": {
                  "Code": "UnknownParameter",
                  "Message": "The parameter `PkgType` is not recognized."
                },
                "RequestId": "00000000-0000-0000-0000-000000000000"
              }
            }
          }
        }
        """
        XCTAssertThrowsError(try TencentTokenPlanResponseParser.parse(
            data: Data(json.utf8),
            variant: .generic
        )) { error in
            guard let qe = error as? QuotaError, case .network = qe else {
                XCTFail("Expected network error, got \(error)")
                return
            }
        }
    }

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

    func testEmptyTokenPlanUsageListThrowsParseFailure() {
        // User signed in but does not own a Token Plan for this
        // edition — the BFF returns a 0/0 envelope with an empty list.
        let json = """
        {
          "code": 0,
          "data": {
            "code": 0,
            "data": {
              "Response": {
                "TokenPlanUsageList": []
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
}
