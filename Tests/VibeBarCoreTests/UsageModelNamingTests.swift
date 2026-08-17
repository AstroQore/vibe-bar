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
}
