import XCTest
@testable import VibeBarCore

final class CopilotParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_715_000_000)

    func testParsesPremiumAndChat() throws {
        let json = """
        {
          "copilot_plan": "individual",
          "quota_reset_date": "2026-06-01",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 300,
              "remaining": 132,
              "percent_remaining": 44.0,
              "quota_id": "premium-2025"
            },
            "chat": {
              "entitlement": 1000,
              "remaining": 750,
              "percent_remaining": 75.0,
              "quota_id": "chat-2025"
            }
          }
        }
        """
        let snap = try CopilotResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snap.planName, "Pro")
        XCTAssertEqual(snap.buckets.count, 2)

        let premium = snap.buckets[0]
        XCTAssertEqual(premium.title, "Premium")
        XCTAssertEqual(premium.usedPercent, 56.0, accuracy: 0.01)
        XCTAssertNotNil(premium.resetAt)

        let chat = snap.buckets[1]
        XCTAssertEqual(chat.title, "Chat")
        XCTAssertEqual(chat.usedPercent, 25.0, accuracy: 0.01)
    }

    func testPlaceholderSnapshotIsDropped() throws {
        let json = """
        {
          "copilot_plan": "business",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 0, "remaining": 0, "percent_remaining": 0, "quota_id": ""
            },
            "chat": {
              "entitlement": 500, "remaining": 100, "percent_remaining": 20.0, "quota_id": "chat-x"
            }
          }
        }
        """
        let snap = try CopilotResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snap.planName, "Business")
        XCTAssertEqual(snap.buckets.count, 1)
        XCTAssertEqual(snap.buckets[0].title, "Chat")
        XCTAssertEqual(snap.buckets[0].usedPercent, 80.0, accuracy: 0.01)
    }

    func testDerivesPercentWhenMissing() throws {
        let json = """
        {
          "copilot_plan": "enterprise",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 1000,
              "remaining": 250,
              "quota_id": "x"
            }
          }
        }
        """
        let snap = try CopilotResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snap.planName, "Enterprise")
        XCTAssertEqual(snap.buckets.count, 1)
        // remaining/entitlement = 25%, used = 75%
        XCTAssertEqual(snap.buckets[0].usedPercent, 75.0, accuracy: 0.01)
    }

    func testUnknownPlanFallsBackToCapitalized() throws {
        let json = """
        {
          "copilot_plan": "edu",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 100, "remaining": 50, "percent_remaining": 50.0, "quota_id": "x"
            }
          }
        }
        """
        let snap = try CopilotResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snap.planName, "Edu")
    }

    func testEmptyOrUnknownPlanProducesNil() throws {
        let json = """
        {
          "copilot_plan": "unknown",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 100, "remaining": 50, "percent_remaining": 50.0, "quota_id": "x"
            }
          }
        }
        """
        let snap = try CopilotResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertNil(snap.planName)
    }
}

final class CopilotEndpointTests: XCTestCase {
    func testDefaultHostMapsToApiGithubCom() {
        let url = CopilotEndpoint.usageURL(enterpriseHost: nil)
        XCTAssertEqual(url?.absoluteString, "https://api.github.com/copilot_internal/user")
    }

    func testEnterpriseHostPrefixesApi() {
        let url = CopilotEndpoint.usageURL(enterpriseHost: "github.example.com")
        XCTAssertEqual(url?.absoluteString, "https://api.github.example.com/copilot_internal/user")
    }

    func testEnterpriseHostStripsScheme() {
        let url = CopilotEndpoint.usageURL(enterpriseHost: "https://github.example.com/")
        XCTAssertEqual(url?.absoluteString, "https://api.github.example.com/copilot_internal/user")
    }

    func testEnterpriseHostPreservesApiPrefix() {
        let url = CopilotEndpoint.usageURL(enterpriseHost: "api.github.example.com")
        XCTAssertEqual(url?.absoluteString, "https://api.github.example.com/copilot_internal/user")
    }
}
