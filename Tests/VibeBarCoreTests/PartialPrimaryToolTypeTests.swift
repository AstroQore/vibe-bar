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

    func testGrokFamilyIsExactlyGrokAndCursor() {
        XCTAssertEqual(ToolType.grokFamily, [.grok, .cursor])
        XCTAssertEqual(ToolType.cursor.coreProviderRepresentative, .grok)
    }

    func testPartialPrimaryProvidersIncludeCursor() {
        XCTAssertEqual(ToolType.partialPrimaryProviders, [.chatgptChat, .gemini, .antigravity, .grok, .cursor, .muse, .devin, .mistralVibe])
    }

    func testDedicatedCardProvidersIncludePrimaryAndPartialPrimary() {
        XCTAssertEqual(
            ToolType.dedicatedCardProviders,
            [.chatgptChat, .codex, .claude, .gemini, .antigravity, .grok, .cursor, .muse, .devin, .mistralVibe]
        )
    }

    /// Meta AI is a company of one: Muse Code represents itself, reads token
    /// usage from local session logs, and polls Meta's Model API status.
    func testMuseCodeIsMetaAIsPartialPrimary() {
        XCTAssertTrue(ToolType.muse.isPartialPrimary)
        XCTAssertFalse(ToolType.muse.isPrimary)
        XCTAssertFalse(ToolType.muse.isMiscPageProvider)
        XCTAssertEqual(ToolType.muse.coreProviderRepresentative, .muse)
        XCTAssertEqual(ToolType.muse.coreProviderMembers, [.muse])
        XCTAssertEqual(ToolType.muse.vendorName, "Meta AI")
        XCTAssertEqual(ToolType.muse.productName, "Muse Code")
        XCTAssertEqual(ToolType.muse.quotaSubProviderName(), "Muse Code")
        XCTAssertTrue(ToolType.muse.supportsTokenCost)
        XCTAssertTrue(ToolType.muse.supportsStatusPage)
        XCTAssertEqual(ToolType.muse.statusPageURL.absoluteString, "https://dev.meta.ai/status")
    }

    /// Cognition and Mistral AI are companies of one, like Meta AI.
    func testCognitionAndMistralAIAreCompaniesOfOne() {
        for (tool, company, product) in [
            (ToolType.devin, "Cognition", "Devin"),
            (ToolType.mistralVibe, "Mistral AI", "Mistral Vibe")
        ] {
            XCTAssertTrue(tool.isPartialPrimary)
            XCTAssertFalse(tool.isPrimary)
            XCTAssertEqual(tool.coreProviderRepresentative, tool)
            XCTAssertEqual(tool.coreProviderMembers, [tool])
            XCTAssertEqual(tool.vendorName, company)
            XCTAssertEqual(tool.productName, product)
            XCTAssertEqual(tool.quotaSubProviderName(), product)
            XCTAssertTrue(tool.supportsTokenCost)
            XCTAssertTrue(tool.supportsStatusPage)
        }
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

    func testCursorIsGrokLinkedAndCostAware() {
        XCTAssertTrue(ToolType.cursor.supportsDedicatedCard)
        XCTAssertTrue(ToolType.cursor.isPartialPrimary)
        XCTAssertTrue(ToolType.cursor.supportsTokenCost)
        XCTAssertTrue(ToolType.cursor.supportsStatusPage)
        XCTAssertFalse(ToolType.cursor.isMiscPageProvider)
        XCTAssertEqual(ToolType.cursor.productName, "Cursor")
        XCTAssertEqual(ToolType.cursor.vendorName, ToolType.grok.vendorName)
        XCTAssertEqual(ToolType.cursor.toolName, "Cursor")
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
            [.codex, .claude, .gemini, .antigravity, .grok, .cursor, .muse, .devin, .mistralVibe]
        )
    }

    func testCombinedStatusDisplayProvidersMergeGoogleAI() {
        XCTAssertEqual(
            ToolType.combinedStatusPageProviders,
            [.codex, .claude, .gemini, .grok, .muse, .devin, .mistralVibe]
        )
    }

    func testCostAwareProvidersIncludeGoogleAIAndGrokFamily() {
        XCTAssertEqual(
            ToolType.costAwareProviders,
            [.codex, .claude, .gemini, .antigravity, .grok, .cursor, .muse, .devin, .mistralVibe]
        )
    }

    func testUsageStatsKeepsCursorAsSubProvider() {
        XCTAssertEqual(
            ToolType.usageStatsProviders,
            [.codex, .claude, .gemini, .antigravity, .grok, .cursor, .muse, .devin, .mistralVibe]
        )
    }

    func testPartialPrimaryProvidersSupportDedicatedCards() {
        for tool in ToolType.partialPrimaryProviders {
            XCTAssertTrue(tool.supportsDedicatedCard, "\(tool) should support a dedicated card")
            XCTAssertTrue(tool.isPartialPrimary, "\(tool) should be partial-primary")
            XCTAssertFalse(tool.isPrimary, "\(tool) should not be `isPrimary`")
            XCTAssertFalse(tool.isMiscPageProvider, "\(tool) should not show on the Misc page")
        }
    }

    func testIsMiscStaysTrueForPartialPrimaryForBackwardCompat() {
        // Keep `isMisc` true for linked tools so legacy
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
        XCTAssertFalse(ToolType.miscPageProviders.contains(.cursor))
    }
}
