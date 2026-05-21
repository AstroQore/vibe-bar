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

    func testGeminiSupportsTokenCostAntigravityDoesNot() {
        // Gemini joined the cost-aware club: the OpenTelemetry log
        // (~/.gemini/telemetry.log, when telemetry is enabled) carries
        // per-call token counts. Antigravity has no public protocol
        // exposing token-level data, so it stays cost-blind.
        XCTAssertTrue(ToolType.gemini.supportsTokenCost,
                      "Gemini should support token cost via OpenTelemetry log scanning")
        XCTAssertFalse(ToolType.antigravity.supportsTokenCost,
                       "Antigravity has no public token-count protocol")
    }

    func testGoogleAIPairSupportsStatusPage() {
        // Both Gemini and Antigravity share Google's Workspace Status
        // dashboard feed (one product entry covers the Gemini family).
        for tool in ToolType.googleAIPair {
            XCTAssertTrue(tool.supportsStatusPage,
                          "\(tool) should support status page via Google Apps Status feed")
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
