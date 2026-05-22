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

    func testPartialPrimaryProvidersAreGeminiAntigravityAndGrok() {
        XCTAssertEqual(ToolType.partialPrimaryProviders, [.gemini, .antigravity, .grok])
    }

    func testDedicatedCardProvidersIncludePrimaryAndPartialPrimary() {
        XCTAssertEqual(
            ToolType.dedicatedCardProviders,
            [.codex, .claude, .gemini, .antigravity, .grok]
        )
    }

    func testGrokIsPartialPrimary() {
        XCTAssertTrue(ToolType.grok.isPartialPrimary)
        XCTAssertTrue(ToolType.grok.supportsDedicatedCard)
        XCTAssertFalse(ToolType.grok.isPrimary)
        XCTAssertTrue(ToolType.grok.supportsTokenCost,
                      "Grok joined the cost-aware club: ~/.grok/sessions/**/updates.jsonl carries per-session running totals")
        XCTAssertTrue(ToolType.grok.supportsStatusPage)
        XCTAssertEqual(ToolType.grok.statusPageURL.absoluteString, "https://status.x.ai/")
        XCTAssertFalse(ToolType.grok.isMiscPageProvider)
    }

    func testGoogleAIPairSupportsTokenCost() {
        // Gemini reads the OpenTelemetry log + chat-history JSONL;
        // AntiGravity reads the per-conversation SQLite stores under
        // ~/.gemini/antigravity/conversations/*.db. Both join Codex /
        // Claude in the cost-aware tier, even though they're
        // partial-primary in every other respect.
        XCTAssertTrue(ToolType.gemini.supportsTokenCost,
                      "Gemini should support token cost via telemetry + chat-history scanning")
        XCTAssertTrue(ToolType.antigravity.supportsTokenCost,
                      "AntiGravity should support token cost via per-conversation SQLite scanning")
    }

    func testGoogleAIPairSupportsStatusPage() {
        // Both Gemini and Antigravity share Google's Workspace Status
        // dashboard feed (one product entry covers the Gemini family).
        for tool in ToolType.googleAIPair {
            XCTAssertTrue(tool.supportsStatusPage,
                          "\(tool) should support status page via Google Apps Status feed")
        }
    }

    func testDedicatedStatusProvidersIncludeGrok() {
        XCTAssertEqual(
            ToolType.statusPageProviders,
            [.codex, .claude, .gemini, .antigravity, .grok]
        )
    }

    func testCombinedStatusDisplayProvidersMergeGoogleAI() {
        XCTAssertEqual(
            ToolType.combinedStatusPageProviders,
            [.codex, .claude, .gemini, .grok]
        )
    }

    func testCostAwareProvidersIncludeGoogleAIAndGrok() {
        XCTAssertEqual(
            ToolType.costAwareProviders,
            [.codex, .claude, .gemini, .antigravity, .grok]
        )
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
