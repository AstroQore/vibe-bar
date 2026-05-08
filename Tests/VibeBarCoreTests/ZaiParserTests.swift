import XCTest
@testable import VibeBarCore

final class ZaiParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_715_000_000)

    func testParsesSingleTokenLimit() throws {
        let json = """
        {
          "code": 200,
          "msg": "OK",
          "success": true,
          "data": {
            "planName": "GLM Coding Pro",
            "limits": [
              {
                "type": "TOKENS_LIMIT",
                "unit": 6,
                "number": 1,
                "usage": 10000000,
                "remaining": 6500000,
                "currentValue": 3500000,
                "percentage": 35,
                "nextResetTime": 1715432400000
              }
            ]
          }
        }
        """
        let snap = try ZaiResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snap.planName, "GLM Coding Pro")
        XCTAssertEqual(snap.buckets.count, 1)
        let bucket = snap.buckets[0]
        XCTAssertEqual(bucket.title, "Weekly")
        XCTAssertEqual(bucket.shortLabel, "Wk")
        // (10_000_000 - 6_500_000) / 10_000_000 * 100 = 35.0
        XCTAssertEqual(bucket.usedPercent, 35.0, accuracy: 0.01)
        XCTAssertEqual(bucket.rawWindowSeconds, 7 * 86_400)
        XCTAssertNotNil(bucket.resetAt)
    }

    func testTwoTokenLimitsProduceLongestPrimaryShortestSecondary() throws {
        let json = """
        {
          "code": 200,
          "msg": "OK",
          "success": true,
          "data": {
            "planName": "GLM Coding Pro",
            "limits": [
              {"type": "TOKENS_LIMIT", "unit": 6, "number": 1, "usage": 100, "remaining": 50, "currentValue": 50, "percentage": 50, "nextResetTime": 1715432400000},
              {"type": "TOKENS_LIMIT", "unit": 3, "number": 5, "usage": 100, "remaining": 80, "currentValue": 20, "percentage": 20, "nextResetTime": 1715000000000}
            ]
          }
        }
        """
        let snap = try ZaiResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snap.buckets.count, 2)
        // Longest window first.
        XCTAssertEqual(snap.buckets[0].rawWindowSeconds, 7 * 86_400)
        XCTAssertEqual(snap.buckets[0].title, "Weekly")
        // Then 5-hour shorter window.
        XCTAssertEqual(snap.buckets[1].rawWindowSeconds, 5 * 3600)
        XCTAssertEqual(snap.buckets[1].title, "5 Hours")
    }

    func testTimeLimitAppendsAfterTokenLimits() throws {
        let json = """
        {
          "code": 200,
          "msg": "OK",
          "success": true,
          "data": {
            "limits": [
              {"type": "TOKENS_LIMIT", "unit": 6, "number": 1, "usage": 100, "remaining": 50, "currentValue": 50, "percentage": 50, "nextResetTime": null},
              {"type": "TIME_LIMIT", "unit": 1, "number": 30, "usage": 30, "remaining": 7, "currentValue": 23, "percentage": 76, "nextResetTime": 1717000000000}
            ]
          }
        }
        """
        let snap = try ZaiResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snap.buckets.count, 2)
        XCTAssertEqual(snap.buckets.last?.title, "30 Days")
        XCTAssertEqual(snap.buckets.last?.rawWindowSeconds, 30 * 86_400)
    }

    func testNonSuccessThrowsNetwork() {
        let json = """
        { "code": 500, "msg": "internal error", "success": false }
        """
        XCTAssertThrowsError(try ZaiResponseParser.parse(data: Data(json.utf8), now: now)) { error in
            guard let qe = error as? QuotaError, case .network = qe else {
                XCTFail("Expected QuotaError.network, got \(error)")
                return
            }
        }
    }

    func testEnterpriseHostOverrideBuildsValidQuotaURL() {
        let env = ["Z_AI_API_HOST": "https://zai.example.com"]
        let settings = ZaiSettings.resolve(environment: env)
        XCTAssertEqual(
            settings.quotaURL.absoluteString,
            "https://zai.example.com/api/monitor/usage/quota/limit"
        )
    }

    func testSettingsEnterpriseHostBuildsValidQuotaURL() {
        let providerSettings = MiscProviderSettings(
            enterpriseHost: URL(string: "https://zai-settings.example.com")!
        )
        let settings = ZaiSettings.resolve(environment: [:], providerSettings: providerSettings)
        XCTAssertEqual(
            settings.quotaURL.absoluteString,
            "https://zai-settings.example.com/api/monitor/usage/quota/limit"
        )
    }

    func testSettingsRegionCanSelectBigModelCN() {
        let providerSettings = MiscProviderSettings(region: "bigmodel-cn")
        let settings = ZaiSettings.resolve(environment: [:], providerSettings: providerSettings)
        XCTAssertEqual(
            settings.quotaURL.absoluteString,
            "https://open.bigmodel.cn/api/monitor/usage/quota/limit"
        )
    }

    func testQuotaURLEnvOverridePreemptsHostOverride() {
        let env = [
            "Z_AI_QUOTA_URL": "https://custom.example.com/v2/quota",
            "Z_AI_API_HOST": "https://other.example.com"
        ]
        let settings = ZaiSettings.resolve(environment: env)
        XCTAssertEqual(
            settings.quotaURL.absoluteString,
            "https://custom.example.com/v2/quota"
        )
    }

    func testDefaultIsGlobal() {
        let settings = ZaiSettings.resolve(environment: [:])
        XCTAssertEqual(
            settings.quotaURL.absoluteString,
            "https://api.z.ai/api/monitor/usage/quota/limit"
        )
    }
}
