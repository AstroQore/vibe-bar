import XCTest
@testable import VibeBarCore

/// Locks the capability-flag taxonomy for the dedicated-card tier.
/// Without these tests it's easy to regress `isMisc` semantics or
/// silently drop the Google AI pair out of the dedicated-card filter.
final class PartialPrimaryToolTypeTests: XCTestCase {
    func testPrimaryProvidersUnchanged() {
        XCTAssertEqual(ToolType.primaryProviders, [.codex, .claude])
    }

    func testGoogleAIPairIsExactlyGeminiAndAntigravity() {
        XCTAssertEqual(ToolType.googleAIPair, [.gemini, .antigravity])
    }

    func testPartialPrimaryProvidersAreGeminiAndAntigravity() {
        XCTAssertEqual(ToolType.partialPrimaryProviders, [.gemini, .antigravity])
    }

    func testDedicatedCardProvidersIncludePrimaryAndPartialPrimary() {
        XCTAssertEqual(ToolType.dedicatedCardProviders, [.codex, .claude, .gemini, .antigravity])
    }

    func testGoogleAIPairDoesNotSupportTokenCost() {
        for tool in ToolType.googleAIPair {
            XCTAssertFalse(tool.supportsTokenCost, "\(tool) should not support token cost")
        }
    }

    func testGoogleAIPairDoesNotSupportStatusPage() {
        for tool in ToolType.googleAIPair {
            XCTAssertFalse(tool.supportsStatusPage, "\(tool) should not support status page")
        }
    }

    func testGoogleAIPairSupportsDedicatedCard() {
        for tool in ToolType.googleAIPair {
            XCTAssertTrue(tool.supportsDedicatedCard, "\(tool) should support a dedicated card")
            XCTAssertTrue(tool.isPartialPrimary, "\(tool) should be partial-primary")
            XCTAssertFalse(tool.isPrimary, "\(tool) should not be `isPrimary`")
            XCTAssertFalse(tool.isMiscPageProvider, "\(tool) should not show on the Misc page")
        }
    }

    func testIsMiscStaysTrueForPartialPrimaryForBackwardCompat() {
        // The plan keeps `isMisc` true for Gemini/Antigravity so legacy
        // misc-only call sites (MiscCookieSlotStore, etc.) keep working.
        // Code that wants to filter the Misc page should use the new
        // `isMiscPageProvider`.
        for tool in ToolType.googleAIPair {
            XCTAssertTrue(tool.isMisc, "\(tool).isMisc must stay true for legacy compat")
        }
    }

    func testMiscPageProvidersExcludesPartialPrimary() {
        XCTAssertFalse(ToolType.miscPageProviders.contains(.gemini))
        XCTAssertFalse(ToolType.miscPageProviders.contains(.antigravity))
        XCTAssertTrue(ToolType.miscPageProviders.contains(.copilot))
        XCTAssertTrue(ToolType.miscPageProviders.contains(.cursor))
    }
}
