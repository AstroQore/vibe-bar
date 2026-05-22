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

        // Sorted alphabetically by model id. Titles now carry the
        // Gemini family version to disambiguate variants like
        // gemini-2.5-flash-lite vs gemini-3.0-flash-lite.
        XCTAssertEqual(snap.buckets[0].title, "Flash 2.5")
        XCTAssertEqual(snap.buckets[0].usedPercent, 45.0, accuracy: 0.01)

        XCTAssertEqual(snap.buckets[1].title, "Flash Lite 2.5")
        XCTAssertEqual(snap.buckets[1].usedPercent, 5.0, accuracy: 0.01)

        // Pro keeps the LOWER fraction (input 30%, not output 85%) → 70% used.
        XCTAssertEqual(snap.buckets[2].title, "Pro 2.5")
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
        XCTAssertEqual(snap.buckets[0].title, "Flash 2.5")
    }

}
