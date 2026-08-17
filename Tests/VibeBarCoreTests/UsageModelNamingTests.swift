import XCTest
@testable import VibeBarCore

final class UsageModelNamingTests: XCTestCase {
    func testCanonicalizesAntiGravityGeminiLabelsWithDecimalVersion() {
        XCTAssertEqual(
            UsageModelNaming.canonicalDisplayName("Gemini 3.5 Flash (High)"),
            "gemini-3.5-flash-high"
        )
        XCTAssertEqual(
            UsageModelNaming.canonicalDisplayName("Gemini 3.6 Flash (Low)"),
            "gemini-3.6-flash-low"
        )
        XCTAssertEqual(
            UsageModelNaming.canonicalDisplayName("Gemini 3.1 Pro (Medium)"),
            "gemini-3.1-pro-medium"
        )
    }

    func testKeepsAlreadyCanonicalAndNonGeminiNames() {
        XCTAssertEqual(
            UsageModelNaming.canonicalDisplayName("gemini-3.5-flash"),
            "gemini-3.5-flash"
        )
        XCTAssertEqual(
            UsageModelNaming.canonicalDisplayName("claude-sonnet-5"),
            "claude-sonnet-5"
        )
        XCTAssertEqual(UsageModelNaming.canonicalDisplayName("  "), "Unknown model")
    }

    /// Vendor ids pass through untouched. Only human labels get slugged, so a
    /// display site can call this unconditionally without inventing a new
    /// spelling for a model the provider already named.
    func testCanonicalVendorIdsPassThroughUnchanged() {
        for raw in [
            "gemini-2.5-pro",
            "gemini-2.5-flash-lite",
            "gemini-3-pro",
            "gpt-5",
            "claude-opus-4-6",
            "grok-build",
            "composer-1"
        ] {
            XCTAssertEqual(UsageModelNaming.canonicalDisplayName(raw), raw)
        }
        // Surrounding whitespace is the one thing it does normalize.
        XCTAssertEqual(UsageModelNaming.canonicalDisplayName(" gemini-2.5-pro "), "gemini-2.5-pro")
    }
}
