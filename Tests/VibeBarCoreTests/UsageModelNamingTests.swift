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

    func testUnlearnedAntiGravityEnumsAreNotNames() {
        XCTAssertTrue(UsageModelNaming.isUnlabelledModelEnum("MODEL_PLACEHOLDER_M318"))
        XCTAssertTrue(UsageModelNaming.isUnlabelledModelEnum(" MODEL_GEMINI_2_5_PRO "))
        XCTAssertFalse(UsageModelNaming.isUnlabelledModelEnum("gemini-default"))
        XCTAssertFalse(UsageModelNaming.isUnlabelledModelEnum("MODEL_"))
        XCTAssertFalse(UsageModelNaming.isUnlabelledModelEnum("model_placeholder"))
        XCTAssertEqual(UsageModelNaming.canonicalDisplayName("MODEL_PLACEHOLDER_M318"), "Unlabelled model")
    }
}

extension UsageModelNamingTests {
    /// A Sessions row names an AntiGravity model by resolving the internal
    /// enum through the labels AntiGravity's own status endpoint taught us —
    /// the same file the cost scanner has always priced through. Before
    /// this, the row read the raw id, decided it was unreadable, and drew no
    /// chip at all.
    func testSessionChipResolvesAnAntigravityEnumThroughTheLearnedLabels() {
        let labels = AntigravityModelLabelStore(labels: [
            "MODEL_PLACEHOLDER_M318": "Gemini 3.8 Flash (High)",
            "MODEL_OPENAI_GPT_OSS_120B_MEDIUM": "GPT-OSS 120B (Medium)"
        ])
        XCTAssertEqual(
            UsageModelNaming.sessionChipLabel(model: "MODEL_PLACEHOLDER_M318", labels: labels),
            UsageModelNaming.canonicalDisplayName("Gemini 3.8 Flash (High)")
        )
        XCTAssertEqual(
            UsageModelNaming.sessionChipLabel(model: "MODEL_OPENAI_GPT_OSS_120B_MEDIUM", labels: labels),
            UsageModelNaming.canonicalDisplayName("GPT-OSS 120B (Medium)")
        )
        // An enum with no label learned yet still says nothing worth drawing.
        XCTAssertNil(UsageModelNaming.sessionChipLabel(model: "MODEL_PLACEHOLDER_M999", labels: labels))
        XCTAssertNil(UsageModelNaming.sessionChipLabel(model: nil, labels: labels))
        XCTAssertNil(UsageModelNaming.sessionChipLabel(model: "", labels: labels))
        // Every other provider's model names are untouched by the lookup.
        XCTAssertEqual(
            UsageModelNaming.sessionChipLabel(model: "claude-fable-5-1", labels: labels),
            UsageModelNaming.canonicalDisplayName("claude-fable-5-1")
        )
        XCTAssertEqual(
            UsageModelNaming.sessionChipLabel(model: "gemini-3.8-flash", labels: AntigravityModelLabelStore()),
            UsageModelNaming.canonicalDisplayName("gemini-3.8-flash")
        )
    }
}
