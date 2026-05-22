import XCTest
@testable import VibeBarCore

/// `GeminiResponseParser` previously collapsed every Flash Lite variant
/// onto the same display label, so two `gemini-*-flash-lite` buckets
/// with distinct ids rendered as two identical-looking "Flash Lite"
/// rows on the popover card. The version extractor disambiguates them.
final class GeminiModelNameTests: XCTestCase {
    func testExtractVersionHandlesDottedAndPlainVersions() {
        XCTAssertEqual(GeminiResponseParser.extractGeminiVersion(from: "gemini-2.5-flash-lite"), "2.5")
        XCTAssertEqual(GeminiResponseParser.extractGeminiVersion(from: "gemini-3-pro"), "3")
        XCTAssertEqual(GeminiResponseParser.extractGeminiVersion(from: "gemini-3.0-pro"), "3.0")
        XCTAssertEqual(GeminiResponseParser.extractGeminiVersion(from: "models/gemini-3.1-flash"), "3.1")
    }

    func testExtractVersionReturnsEmptyWhenAbsent() {
        XCTAssertEqual(GeminiResponseParser.extractGeminiVersion(from: "gemini-pro"), "")
        XCTAssertEqual(GeminiResponseParser.extractGeminiVersion(from: "some-other-model"), "")
    }

    func testPrettyModelNameCarriesVersion() {
        XCTAssertEqual(GeminiResponseParser.prettyModelName("gemini-2.5-flash-lite"), "Flash Lite 2.5")
        XCTAssertEqual(GeminiResponseParser.prettyModelName("gemini-3-pro"), "Pro 3")
        XCTAssertEqual(GeminiResponseParser.prettyModelName("gemini-3.0-flash"), "Flash 3.0")
    }

    func testPrettyModelNameFallsBackWhenVersionMissing() {
        XCTAssertEqual(GeminiResponseParser.prettyModelName("gemini-flash"), "Flash")
        XCTAssertEqual(GeminiResponseParser.prettyModelName("unknown-foo"), "unknown-foo")
    }

    func testShortLabelCarriesVersion() {
        XCTAssertEqual(GeminiResponseParser.shortLabel(for: "gemini-2.5-flash-lite"), "Lite 2.5")
        XCTAssertEqual(GeminiResponseParser.shortLabel(for: "gemini-3-pro"), "Pro 3")
    }

    func testTwoFlashLiteVariantsRenderAsDistinctRows() throws {
        // The actual bug: two different Flash Lite quota buckets
        // rendered with an identical "Flash Lite" header.
        let json = """
        {
          "buckets": [
            { "modelId": "gemini-2.5-flash-lite", "remainingFraction": 0.5, "resetTime": "2026-05-22T00:00:00Z", "tokenType": "input" },
            { "modelId": "gemini-3.0-flash-lite", "remainingFraction": 0.8, "resetTime": "2026-05-22T00:00:00Z", "tokenType": "input" }
          ]
        }
        """
        let snapshot = try GeminiResponseParser.parse(
            data: Data(json.utf8),
            email: nil,
            now: Date()
        )
        XCTAssertEqual(snapshot.buckets.count, 2)
        let titles = Set(snapshot.buckets.map(\.title))
        XCTAssertEqual(titles, ["Flash Lite 2.5", "Flash Lite 3.0"])
        let groups = Set(snapshot.buckets.compactMap(\.groupTitle))
        XCTAssertEqual(groups, ["Flash Lite 2.5", "Flash Lite 3.0"])
    }
}
