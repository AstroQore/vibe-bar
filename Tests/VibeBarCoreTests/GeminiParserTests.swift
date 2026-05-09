import XCTest
@testable import VibeBarCore

final class GeminiParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_715_000_000)

    func testGroupsBucketsByModelKeepingLowestRemaining() throws {
        let json = """
        {
          "buckets": [
            {"modelId": "gemini-2.5-pro", "tokenType": "input", "remainingFraction": 0.30, "resetTime": "2026-05-09T00:00:00Z"},
            {"modelId": "gemini-2.5-pro", "tokenType": "output", "remainingFraction": 0.85, "resetTime": "2026-05-09T00:00:00Z"},
            {"modelId": "gemini-2.5-flash", "tokenType": "input", "remainingFraction": 0.55, "resetTime": "2026-05-09T00:00:00Z"},
            {"modelId": "gemini-2.5-flash-lite", "tokenType": "input", "remainingFraction": 0.95, "resetTime": "2026-05-09T00:00:00Z"}
          ]
        }
        """
        let snap = try GeminiResponseParser.parse(data: Data(json.utf8), email: "user@example.com", now: now)
        XCTAssertEqual(snap.email, "user@example.com")
        XCTAssertEqual(snap.buckets.count, 3)

        // Sorted alphabetically by model id.
        XCTAssertEqual(snap.buckets[0].title, "Flash")
        XCTAssertEqual(snap.buckets[0].usedPercent, 45.0, accuracy: 0.01)

        XCTAssertEqual(snap.buckets[1].title, "Flash Lite")
        XCTAssertEqual(snap.buckets[1].usedPercent, 5.0, accuracy: 0.01)

        // Pro keeps the LOWER fraction (input 30%, not output 85%) → 70% used.
        XCTAssertEqual(snap.buckets[2].title, "Pro")
        XCTAssertEqual(snap.buckets[2].usedPercent, 70.0, accuracy: 0.01)
        XCTAssertNotNil(snap.buckets[2].resetAt)
    }

    func testEmptyBucketsThrows() {
        let json = """
        { "buckets": [] }
        """
        XCTAssertThrowsError(try GeminiResponseParser.parse(data: Data(json.utf8), email: nil, now: now))
    }

    func testMissingFractionDropsRow() throws {
        let json = """
        {
          "buckets": [
            {"modelId": "gemini-2.5-pro", "tokenType": "input"},
            {"modelId": "gemini-2.5-flash", "tokenType": "input", "remainingFraction": 0.5}
          ]
        }
        """
        let snap = try GeminiResponseParser.parse(data: Data(json.utf8), email: nil, now: now)
        XCTAssertEqual(snap.buckets.count, 1)
        XCTAssertEqual(snap.buckets[0].title, "Flash")
    }

    func testCredentialFileLoadsAccessAndExpiry() throws {
        let json = """
        {
          "access_token": "ya29.fake",
          "id_token": "fake.jwt",
          "refresh_token": "1//0fake",
          "expiry_date": 1715000000000,
          "scope": "https://www.googleapis.com/auth/cloud-platform",
          "token_type": "Bearer"
        }
        """
        let dir = NSTemporaryDirectory()
        let url = URL(fileURLWithPath: dir).appendingPathComponent("oauth_creds_test_\(UUID()).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let creds = try GeminiCredentials.load(from: url)
        XCTAssertEqual(creds.accessToken, "ya29.fake")
        XCTAssertEqual(creds.idToken, "fake.jwt")
        XCTAssertEqual(creds.refreshToken, "1//0fake")
        XCTAssertEqual(creds.expiry?.timeIntervalSince1970, 1_715_000_000)
    }

    func testGeminiTokenRefreshDecisionUsesLeadTime() {
        let leadTime: TimeInterval = 10 * 60

        XCTAssertTrue(GeminiTokenRefreshHelper.shouldRefresh(
            expiry: now.addingTimeInterval(5 * 60),
            now: now,
            leadTime: leadTime
        ))
        XCTAssertTrue(GeminiTokenRefreshHelper.shouldRefresh(
            expiry: now.addingTimeInterval(-60),
            now: now,
            leadTime: leadTime
        ))
        XCTAssertFalse(GeminiTokenRefreshHelper.shouldRefresh(
            expiry: now.addingTimeInterval(30 * 60),
            now: now,
            leadTime: leadTime
        ))
        XCTAssertFalse(GeminiTokenRefreshHelper.shouldRefresh(
            expiry: nil,
            now: now,
            leadTime: leadTime
        ))
    }

    func testEmailExtractionFromJWT() {
        // Synthetic JWT with payload {"email":"alice@example.com","hd":"example.com"}.
        // Header and signature are not validated here — base64url payload only.
        let payload = #"{"email":"alice@example.com","hd":"example.com"}"#
        let payloadB64 = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "fakeheader.\(payloadB64).fakesig"

        XCTAssertEqual(GeminiCredentials.email(from: token), "alice@example.com")
    }

    func testEmailExtractionReturnsNilForGarbage() {
        XCTAssertNil(GeminiCredentials.email(from: nil))
        XCTAssertNil(GeminiCredentials.email(from: ""))
        XCTAssertNil(GeminiCredentials.email(from: "notajwt"))
    }
}
