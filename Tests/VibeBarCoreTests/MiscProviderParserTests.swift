import XCTest
@testable import VibeBarCore

final class MiscProviderParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_715_000_000)

    func testOpenRouterCreditsAndKeyStatsProduceBuckets() throws {
        let creditsJSON = """
        {"data":{"total_credits":100.0,"total_usage":25.5}}
        """
        let keyJSON = """
        {"data":{"label":"Personal","limit":50.0,"usage":10.0}}
        """
        let credits = try OpenRouterResponseParser.parseCredits(data: Data(creditsJSON.utf8))
        let keyStats = try OpenRouterResponseParser.parseKeyStats(data: Data(keyJSON.utf8))
        let snapshot = OpenRouterResponseParser.snapshot(credits: credits, keyStats: keyStats)

        XCTAssertEqual(snapshot.planName, "Personal")
        XCTAssertEqual(snapshot.creditsRemainingUSD ?? -1, 74.5, accuracy: 0.01)
        XCTAssertEqual(snapshot.buckets.map(\.id), ["openrouter.key", "openrouter.credits"])
        XCTAssertEqual(snapshot.buckets[0].usedPercent, 20.0, accuracy: 0.01)
    }

    func testOpenRouterTokenLikeKeyLabelIsNotDisplayed() throws {
        let creditsJSON = """
        {"data":{"total_credits":10.0,"total_usage":1.0}}
        """
        let keyJSON = """
        {"data":{"label":"sk-or-v1-abcdefghijklmnopqrstuvwxyz0123456789secret","limit":10.0,"usage":1.0}}
        """
        let credits = try OpenRouterResponseParser.parseCredits(data: Data(creditsJSON.utf8))
        let keyStats = try OpenRouterResponseParser.parseKeyStats(data: Data(keyJSON.utf8))
        let snapshot = OpenRouterResponseParser.snapshot(credits: credits, keyStats: keyStats)

        XCTAssertNil(snapshot.planName)
        XCTAssertEqual(snapshot.buckets[0].groupTitle, "$1.00 / $10.00")
    }

    func testOpenRouterTruncatedKeyLabelIsNotDisplayed() throws {
        let creditsJSON = """
        {"data":{"total_credits":10.0,"total_usage":1.0}}
        """
        let keyJSON = """
        {"data":{"label":"sk-or-v1-ca5...3fa","limit":10.0,"usage":1.0}}
        """
        let credits = try OpenRouterResponseParser.parseCredits(data: Data(creditsJSON.utf8))
        let keyStats = try OpenRouterResponseParser.parseKeyStats(data: Data(keyJSON.utf8))
        let snapshot = OpenRouterResponseParser.snapshot(credits: credits, keyStats: keyStats)

        XCTAssertNil(snapshot.planName)
    }

    func testKiloParserMapsCreditsAndPass() throws {
        let json = """
        [
          {
            "result": {
              "data": {
                "creditBlocks": [
                  {"balance_mUsd": 75000000, "amount_mUsd": 100000000}
                ],
                "autoTopUpEnabled": false
              }
            }
          },
          {
            "result": {
              "data": {
                "subscription": {
                  "tier": "tier_49",
                  "currentPeriodUsageUsd": 5,
                  "currentPeriodBaseCreditsUsd": 50,
                  "currentPeriodBonusCreditsUsd": 10,
                  "nextBillingAt": "2026-03-28T04:00:00.000Z"
                }
              }
            }
          },
          {"result":{"data":{"enabled":false}}}
        ]
        """
        let snapshot = try KiloResponseParser.parse(data: Data(json.utf8), now: now)

        XCTAssertEqual(snapshot.planName, "Pro · Auto top-up: off")
        XCTAssertEqual(snapshot.buckets.map(\.id), ["kilo.credits", "kilo.pass"])
        XCTAssertEqual(snapshot.buckets[0].usedPercent, 25.0, accuracy: 0.01)
        XCTAssertEqual(snapshot.buckets[1].usedPercent, 8.333, accuracy: 0.01)
        XCTAssertNotNil(snapshot.buckets[1].resetAt)
    }

    func testOpenCodeGoParserMapsRollingWeeklyMonthly() throws {
        let json = """
        {
          "rollingUsage": {"usagePercent": 10, "resetInSec": 100},
          "weeklyUsage": {"usagePercent": 25, "resetInSec": 200},
          "monthlyUsage": {"usagePercent": 50, "resetInSec": 300}
        }
        """
        let snapshot = try OpenCodeGoResponseParser.parse(text: json, now: now)

        XCTAssertEqual(snapshot.buckets.map(\.id), [
            "opencodego.rolling",
            "opencodego.weekly",
            "opencodego.monthly"
        ])
        XCTAssertEqual(snapshot.buckets[2].usedPercent, 50.0, accuracy: 0.01)
        XCTAssertEqual(OpenCodeGoResponseParser.normalizeWorkspaceID("https://opencode.ai/workspace/wrk_abc123/go"), "wrk_abc123")
    }

    func testOllamaParserMapsCloudUsage() throws {
        let html = """
        <div id="header-email">dev@example.com</div>
        <span>Cloud Usage</span><span>Pro</span>
        <section>
          <h2>Hourly usage</h2>
          <div>25% used</div>
          <time data-time="2026-05-12T12:00:00Z"></time>
        </section>
        <section>
          <h2>Weekly usage</h2>
          <div style="width: 40%"></div>
          <time data-time="2026-05-18T12:00:00Z"></time>
        </section>
        """
        let snapshot = try OllamaResponseParser.parse(html: html, now: now)

        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertEqual(snapshot.email, "dev@example.com")
        XCTAssertEqual(snapshot.buckets.map(\.id), ["ollama.hourly", "ollama.weekly"])
        XCTAssertEqual(snapshot.buckets[0].usedPercent, 25.0, accuracy: 0.01)
        XCTAssertEqual(snapshot.buckets[1].usedPercent, 40.0, accuracy: 0.01)
        XCTAssertTrue(OllamaQuotaAdapter.hasRecognizedSessionCookie("__Secure-next-auth.session-token.0=abc; other=x"))
    }

    func testKiroParserMapsLegacyAndManagedFormats() throws {
        let legacy = """
        | KIRO PRO                                           |
        ████████████████████████████████████████████████████ 80%
        (40.00 of 50 covered in plan), resets on 02/01
        Bonus credits: 5.00/10 credits used, expires in 7 days
        """
        let snapshot = try KiroResponseParser.parse(output: legacy, now: now)
        XCTAssertEqual(snapshot.planName, "KIRO PRO")
        XCTAssertEqual(snapshot.buckets.map(\.id), ["kiro.credits", "kiro.bonus"])
        XCTAssertEqual(snapshot.buckets[0].usedPercent, 80.0, accuracy: 0.01)
        XCTAssertEqual(snapshot.buckets[1].usedPercent, 50.0, accuracy: 0.01)

        let managed = """
        Plan: Q Developer Pro
        Your plan is managed by admin
        """
        let managedSnapshot = try KiroResponseParser.parse(output: managed, now: now)
        XCTAssertEqual(managedSnapshot.planName, "Q Developer Pro")
        XCTAssertEqual(managedSnapshot.buckets[0].usedPercent, 0)
    }

    func testKiroParserMapsCurrentQDeveloperUsageFormat() throws {
        let output = """
        Estimated Usage | resets on 2026-06-01 | KIRO FREE

        Credits (0.00 of 50 covered in plan)
        ████████████████████████████████████████████████████ 0%

        Overages: Disabled
        """
        let snapshot = try KiroResponseParser.parse(output: output, now: now)

        XCTAssertEqual(snapshot.planName, "KIRO FREE")
        XCTAssertEqual(snapshot.buckets.map(\.id), ["kiro.credits"])
        XCTAssertEqual(snapshot.buckets[0].usedPercent, 0.0, accuracy: 0.01)
        let reset = try XCTUnwrap(snapshot.buckets[0].resetAt)
        let resetParts = Calendar.current.dateComponents([.year, .month, .day], from: reset)
        XCTAssertEqual(resetParts.year, 2026)
        XCTAssertEqual(resetParts.month, 6)
        XCTAssertEqual(resetParts.day, 1)
        XCTAssertEqual(snapshot.buckets[0].groupTitle, "0 / 50 covered")
    }
}
