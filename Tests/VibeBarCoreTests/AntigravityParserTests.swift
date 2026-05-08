import XCTest
@testable import VibeBarCore

final class AntigravityParserTests: XCTestCase {
    func testParsesUserStatusWithModelQuotas() throws {
        let json = """
        {
          "code": 0,
          "userStatus": {
            "email": "user@example.com",
            "userTier": {"id": "tier-paid", "name": "Pro"},
            "cascadeModelConfigData": {
              "clientModelConfigs": [
                {
                  "label": "Claude Sonnet 4",
                  "modelOrAlias": {"model": "claude-sonnet-4-20250514"},
                  "quotaInfo": {"remainingFraction": 0.42, "resetTime": "2026-06-01T00:00:00Z"}
                },
                {
                  "label": "Gemini 2.5 Pro",
                  "modelOrAlias": {"model": "gemini-2.5-pro"},
                  "quotaInfo": {"remainingFraction": 0.78}
                },
                {
                  "label": "Gemini Flash Lite",
                  "modelOrAlias": {"model": "gemini-2.5-flash-lite"},
                  "quotaInfo": {"remainingFraction": 0.95}
                }
              ]
            }
          }
        }
        """
        let snap = try AntigravityResponseParser.parseUserStatus(data: Data(json.utf8))
        XCTAssertEqual(snap.email, "user@example.com")
        XCTAssertEqual(snap.planName, "Pro")
        XCTAssertEqual(snap.buckets.count, 3)
        XCTAssertEqual(snap.buckets[0].title, "Claude Sonnet 4")
        XCTAssertEqual(snap.buckets[0].usedPercent, 58.0, accuracy: 0.01)
        XCTAssertNotNil(snap.buckets[0].resetAt)
        XCTAssertEqual(snap.buckets[0].groupTitle, "Claude")

        XCTAssertEqual(snap.buckets[1].usedPercent, 22.0, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[1].groupTitle, "Gemini Pro")

        XCTAssertEqual(snap.buckets[2].usedPercent, 5.0, accuracy: 0.01)
        XCTAssertEqual(snap.buckets[2].groupTitle, "Gemini Flash Lite")
    }

    func testFallsBackToPlanInfoWhenUserTierMissing() throws {
        let json = """
        {
          "code": 0,
          "userStatus": {
            "email": null,
            "planStatus": {
              "planInfo": {"planDisplayName": "Pro Trial", "productName": "AntiGravity"}
            },
            "cascadeModelConfigData": {
              "clientModelConfigs": [
                {"label": "x", "modelOrAlias": {"model": "x"}, "quotaInfo": {"remainingFraction": 1.0}}
              ]
            }
          }
        }
        """
        let snap = try AntigravityResponseParser.parseUserStatus(data: Data(json.utf8))
        XCTAssertEqual(snap.planName, "Pro Trial")
        XCTAssertEqual(snap.buckets.count, 1)
        XCTAssertEqual(snap.buckets[0].usedPercent, 0.0, accuracy: 0.01)
    }

    func testMissingUserStatusThrowsParseFailure() {
        let json = """
        { "code": 0 }
        """
        XCTAssertThrowsError(try AntigravityResponseParser.parseUserStatus(data: Data(json.utf8)))
    }

    func testNonZeroNumericCodeThrowsNetwork() {
        let json = """
        { "code": 16, "message": "unauthenticated" }
        """
        XCTAssertThrowsError(try AntigravityResponseParser.parseUserStatus(data: Data(json.utf8))) { error in
            guard let qe = error as? QuotaError, case .network = qe else {
                XCTFail("Expected QuotaError.network, got \(error)")
                return
            }
        }
    }

    func testStringCodeUnauthenticatedThrowsNetwork() {
        let json = """
        { "code": "unauthenticated", "message": "session expired" }
        """
        XCTAssertThrowsError(try AntigravityResponseParser.parseUserStatus(data: Data(json.utf8))) { error in
            guard let qe = error as? QuotaError, case .network = qe else {
                XCTFail("Expected QuotaError.network, got \(error)")
                return
            }
        }
    }

    func testCodeOKStringIsAcceptedAsSuccess() throws {
        let json = """
        {
          "code": "OK",
          "userStatus": {
            "cascadeModelConfigData": {
              "clientModelConfigs": [
                {"label": "Pro", "modelOrAlias": {"model": "x"}, "quotaInfo": {"remainingFraction": 0.6}}
              ]
            }
          }
        }
        """
        let snap = try AntigravityResponseParser.parseUserStatus(data: Data(json.utf8))
        XCTAssertEqual(snap.buckets.count, 1)
        XCTAssertEqual(snap.buckets[0].usedPercent, 40.0, accuracy: 0.01)
    }

    func testProcessLineParse() {
        let line = "  12345 /Applications/Antigravity/Resources/.../language_server_macos --csrf_token=abc --extension_server_port=44567"
        let parsed = AntigravityProcessLine.parse(line)
        XCTAssertEqual(parsed?.pid, 12345)
        XCTAssertTrue(parsed?.command.contains("language_server_macos") ?? false)
    }

    func testLocalhostTrustPolicyAcceptsLocalhostOnly() {
        XCTAssertTrue(
            AntigravityLocalhostTrustPolicy.shouldAcceptServerTrust(
                host: "127.0.0.1",
                authenticationMethod: NSURLAuthenticationMethodServerTrust,
                hasServerTrust: true
            )
        )
        XCTAssertTrue(
            AntigravityLocalhostTrustPolicy.shouldAcceptServerTrust(
                host: "localhost",
                authenticationMethod: NSURLAuthenticationMethodServerTrust,
                hasServerTrust: true
            )
        )
        XCTAssertFalse(
            AntigravityLocalhostTrustPolicy.shouldAcceptServerTrust(
                host: "evil.example.com",
                authenticationMethod: NSURLAuthenticationMethodServerTrust,
                hasServerTrust: true
            )
        )
        XCTAssertFalse(
            AntigravityLocalhostTrustPolicy.shouldAcceptServerTrust(
                host: "127.0.0.1",
                authenticationMethod: NSURLAuthenticationMethodHTTPBasic,
                hasServerTrust: true
            )
        )
    }
}
