import XCTest
@testable import VibeBarCore

final class KimiParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_715_000_000)

    func testParsesWeeklyAndRateLimit() throws {
        let json = """
        {
          "usages": [
            {
              "scope": "FEATURE_CODING",
              "detail": {
                "limit": "1000",
                "used": "234",
                "remaining": "766",
                "resetTime": "2026-05-15T00:00:00Z"
              },
              "limits": [
                {
                  "window": {"duration": 5, "timeUnit": "HOUR"},
                  "detail": {
                    "limit": "100",
                    "used": "12",
                    "remaining": "88",
                    "resetTime": "2026-05-08T20:00:00Z"
                  }
                }
              ]
            }
          ]
        }
        """
        let snap = try KimiResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snap.buckets.count, 2)

        XCTAssertEqual(snap.buckets[0].title, "Weekly")
        XCTAssertEqual(snap.buckets[0].usedPercent, 23.4, accuracy: 0.01)
        XCTAssertNotNil(snap.buckets[0].resetAt)

        XCTAssertEqual(snap.buckets[1].title, "5 Hours")
        XCTAssertEqual(snap.buckets[1].usedPercent, 12.0, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[1].rawWindowSeconds, 5 * 3600)
    }

    func testNoCodingScopeThrowsParseFailure() {
        let json = """
        {
          "usages": [
            {"scope": "FEATURE_CHAT", "detail": {"limit": "100"}}
          ]
        }
        """
        XCTAssertThrowsError(try KimiResponseParser.parse(data: Data(json.utf8), now: now))
    }

    func testJWTSessionInfoExtraction() {
        // Synthetic JWT carrying device_id, ssid, sub claims.
        let payload = #"{"device_id":"d-123","ssid":"s-456","sub":"t-789"}"#
        let payloadB64 = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "header.\(payloadB64).sig"

        let info = KimiSessionInfo.fromJWT(token)
        XCTAssertEqual(info.deviceId, "d-123")
        XCTAssertEqual(info.sessionId, "s-456")
        XCTAssertEqual(info.trafficId, "t-789")
    }

    func testJWTSessionInfoEmptyOnGarbage() {
        XCTAssertEqual(KimiSessionInfo.fromJWT("garbage").deviceId, nil)
        XCTAssertEqual(KimiSessionInfo.fromJWT("a.b").sessionId, nil)
    }
}

final class MiniMaxParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_715_000_000)

    func testParsesCodingPlanRemains() throws {
        let json = """
        {
          "data": {
            "base_resp": {"status_code": 0, "status_msg": "ok"},
            "current_subscribe_title": "MiniMax Coding Plan Pro",
            "model_remains": [
              {
                "current_interval_total_count": 1000,
                "current_interval_usage_count": 234,
                "start_time": 1714400000,
                "end_time": 1715200000,
                "remains_time": 600
              }
            ]
          }
        }
        """
        let snap = try MiniMaxResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snap.planName, "MiniMax Coding Plan Pro")
        XCTAssertEqual(snap.buckets.count, 1)
        // MiniMax reports current_interval_usage_count as used:
        // used=234, remaining=766.
        XCTAssertEqual(snap.buckets[0].usedPercent, 23.4, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[0].title, "5 Hours")
        XCTAssertEqual(snap.buckets[0].shortLabel, "5h")
        XCTAssertEqual(snap.buckets[0].groupTitle, "766/1000 · 222 hours")
        XCTAssertNotNil(snap.buckets[0].resetAt)
        XCTAssertEqual(snap.buckets[0].rawWindowSeconds, 5 * 3600)
    }

    func testParsesRootLevelModelRemainsResponse() throws {
        let json = """
        {
          "model_remains": [
            {
              "start_time": 1771588800000,
              "end_time": 1771603200000,
              "remains_time": 5925660,
              "current_interval_total_count": 1500,
              "current_interval_usage_count": 1437,
              "model_name": "MiniMax-M2"
            }
          ],
          "base_resp": {
            "status_code": 0,
            "status_msg": "success"
          }
        }
        """
        let snap = try MiniMaxResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snap.buckets.count, 1)
        // used=1437, remaining=63.
        XCTAssertEqual(snap.buckets[0].usedPercent, 95.8, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[0].title, "Text Generation")
        XCTAssertEqual(snap.buckets[0].groupTitle, "63/1500 · 5 hours")
        XCTAssertEqual(snap.buckets[0].rawWindowSeconds, 5 * 3600)
    }

    func testPrefersChatModelRemainsOverMediaRows() throws {
        let json = """
        {
          "model_remains": [
            {
              "current_interval_total_count": 0,
              "current_interval_usage_count": 0,
              "model_name": "speech-2.8-hd"
            },
            {
              "current_interval_total_count": 1500,
              "current_interval_usage_count": 1200,
              "model_name": "MiniMax-M2.7"
            }
          ],
          "base_resp": {"status_code": 0}
        }
        """
        let snap = try MiniMaxResponseParser.parse(data: Data(json.utf8), now: now)
        // used=1200, remaining=300.
        XCTAssertEqual(snap.buckets[0].usedPercent, 80.0, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[0].title, "Text Generation")
    }

    func testAuthenticationErrorMapsToNeedsLogin() {
        let json = """
        {
          "base_resp": {"status_code": 1004, "status_msg": "login fail: invalid API key"}
        }
        """
        XCTAssertThrowsError(try MiniMaxResponseParser.parse(data: Data(json.utf8), now: now)) { error in
            guard let qe = error as? QuotaError, case .needsLogin = qe else {
                XCTFail("Expected QuotaError.needsLogin, got \(error)")
                return
            }
        }
    }

    func testChinaMainlandRemainsRequestUsesOfficialTokenPlanEndpoint() {
        let region = MiniMaxRegion.chinaMainland

        XCTAssertEqual(
            region.remainsURLs.first?.absoluteString,
            "https://www.minimaxi.com/v1/token_plan/remains"
        )
        XCTAssertEqual(region.apiHost.absoluteString, "https://www.minimaxi.com")
        XCTAssertEqual(
            region.remainsURLs.last?.absoluteString,
            "https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains"
        )
    }

    func testGlobalRemainsRequestUsesOfficialTokenPlanEndpoint() {
        let endpoints = MiniMaxRegion.global.remainsURLs.map(\.absoluteString)

        XCTAssertEqual(endpoints.first, "https://www.minimax.io/v1/token_plan/remains")
        XCTAssertTrue(endpoints.contains("https://api.minimax.io/v1/api/openplatform/coding_plan/remains"))
        XCTAssertTrue(endpoints.contains("https://www.minimax.io/v1/api/openplatform/coding_plan/remains"))
    }

    func testEnvironmentOverridesPrependMiniMaxRemainsURLs() {
        let endpoints = MiniMaxRegion.global.remainsURLs(environment: [
            "MINIMAX_REMAINS_URL": "https://minimax.example/remains",
            "MINIMAX_HOST": "minimax-host.example"
        ]).map(\.absoluteString)

        XCTAssertEqual(endpoints[0], "https://minimax.example/remains")
        XCTAssertEqual(endpoints[1], "https://minimax-host.example/v1/api/openplatform/coding_plan/remains")
        XCTAssertTrue(endpoints.contains("https://www.minimax.io/v1/token_plan/remains"))
    }

    func testRegionSettingSelectsMiniMaxPreferredRegion() {
        XCTAssertEqual(
            MiniMaxRegion.resolve(settings: MiscProviderSettings(region: "cn")),
            [.chinaMainland, .global]
        )
        XCTAssertEqual(
            MiniMaxRegion.resolve(settings: MiscProviderSettings(region: "global")),
            [.global, .chinaMainland]
        )
        XCTAssertEqual(
            MiniMaxRegion.resolve(settings: MiscProviderSettings(region: "www.minimaxi.com")),
            [.chinaMainland, .global]
        )
    }

    func testMissingModelRemainsThrowsParseFailure() {
        let json = """
        {
          "data": {
            "base_resp": {"status_code": 0},
            "current_subscribe_title": "Coding Plan Free"
          }
        }
        """
        XCTAssertThrowsError(try MiniMaxResponseParser.parse(data: Data(json.utf8), now: now)) { error in
            guard let qe = error as? QuotaError, case .parseFailure = qe else {
                XCTFail("Expected parseFailure, got \(error)")
                return
            }
        }
    }

    func testEpochInMillisecondsResetsAt() throws {
        let json = """
        {
          "data": {
            "base_resp": {"status_code": 0},
            "model_remains": [
              {
                "current_interval_total_count": 100,
                "current_interval_usage_count": 10,
                "end_time": 1715200000000
              }
            ]
          }
        }
        """
        let snap = try MiniMaxResponseParser.parse(data: Data(json.utf8), now: now)
        // used=10, remaining=90.
        XCTAssertEqual(snap.buckets[0].usedPercent, 10.0, accuracy: 0.01)
        let reset = snap.buckets[0].resetAt
        XCTAssertNotNil(reset)
        XCTAssertEqual(reset?.timeIntervalSince1970, 1_715_200_000)
    }

    func testParsesWeeklyWindowFromModelRemains() throws {
        let json = """
        {
          "data": {
            "base_resp": {"status_code": 0},
            "model_remains": [
              {
                "current_interval_total_count": 100,
                "current_interval_usage_count": 10,
                "current_weekly_total_count": 1000,
                "current_weekly_usage_count": 250,
                "weekly_end_time": 1715600000
              }
            ]
          }
        }
        """
        let snap = try MiniMaxResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snap.buckets.count, 2)
        XCTAssertEqual(snap.buckets[1].id, "minimax.weekly")
        XCTAssertEqual(snap.buckets[1].usedPercent, 25.0, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[1].groupTitle, "750/1000 · Weekly")
    }

    func testMapsEveryMiniMaxModelRemainServiceShownByCodexBar() throws {
        let json = """
        {
          "model_remains": [
            {
              "current_interval_total_count": 450,
              "current_interval_usage_count": 1,
              "model_name": "MiniMax-M2",
              "start_time": 1771588800000,
              "end_time": 1771603200000
            },
            {
              "current_interval_total_count": 19000,
              "current_interval_usage_count": 0,
              "model_name": "speech-02-hd"
            },
            {
              "current_interval_total_count": 3,
              "current_interval_usage_count": 0,
              "model_name": "hailuo-02-fast"
            },
            {
              "current_interval_total_count": 3,
              "current_interval_usage_count": 0,
              "model_name": "hailuo-02"
            },
            {
              "current_interval_total_count": 7,
              "current_interval_usage_count": 0,
              "model_name": "music-01"
            },
            {
              "current_interval_total_count": 100,
              "current_interval_usage_count": 0,
              "model_name": "lyrics_generation"
            },
            {
              "current_interval_total_count": 200,
              "current_interval_usage_count": 0,
              "model_name": "image-01"
            },
            {
              "current_interval_total_count": 450,
              "current_interval_usage_count": 0,
              "model_name": "coding-plan-search"
            }
          ],
          "base_resp": {"status_code": 0}
        }
        """
        let snap = try MiniMaxResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(
            snap.buckets.map(\.title),
            [
                "Text Generation",
                "Text to Speech",
                "Image to Video",
                "Text to Video",
                "Music Generation",
                "Lyrics Generation",
                "Image Generation",
                "Coding Plan Search"
            ]
        )
        XCTAssertEqual(snap.buckets.map(\.shortLabel), Array(repeating: "5h", count: 8))
        XCTAssertEqual(snap.buckets.first?.usedPercent ?? -1, 0.222, accuracy: 0.001)
        XCTAssertEqual(snap.buckets.first?.groupTitle, "449/450 · 5 hours")
    }

    func testParsesMiniMaxServiceUsageShape() throws {
        let json = """
        {
          "data": {
            "base_resp": {"status_code": 0},
            "current_subscribe_title": "MiniMax Coding Plan Pro",
            "services": [
              {
                "service_type": "coding",
                "window_type": "weekly",
                "usage": 25,
                "limit": 100,
                "reset_in_seconds": 3600
              }
            ]
          }
        }
        """
        let snap = try MiniMaxResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snap.planName, "MiniMax Coding Plan Pro")
        XCTAssertEqual(snap.buckets.count, 1)
        XCTAssertEqual(snap.buckets[0].id, "minimax.weekly")
        XCTAssertEqual(snap.buckets[0].usedPercent, 25.0, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[0].rawWindowSeconds, 7 * 86_400)
    }

    func testMiniMaxServiceUsageHourBucketIsFiveHours() throws {
        let json = """
        {
          "data": {
            "base_resp": {"status_code": 0},
            "services": [
              {
                "service_type": "coding",
                "window_type": "hourly",
                "usage": 25,
                "limit": 100,
                "reset_in_seconds": 3600
              }
            ]
          }
        }
        """
        let snap = try MiniMaxResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snap.buckets[0].title, "5 Hours")
        XCTAssertEqual(snap.buckets[0].shortLabel, "5h")
        XCTAssertEqual(snap.buckets[0].rawWindowSeconds, 5 * 3600)
    }
}
