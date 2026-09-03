import XCTest
@testable import VibeBarCore

/// The menu bar's "combine a group's windows" merge: which fields collapse
/// into one `5%/100%` piece, and what that piece is called.
final class MenuBarQuotaGroupingTests: XCTestCase {
    private func field(_ id: String) -> MenuBarFieldOption {
        guard let option = MenuBarFieldCatalog.field(id: id) else {
            fatalError("\(id) is not in the static catalog")
        }
        return option
    }

    /// Stand-in for the mini window's group-label table, which lives in the
    /// App target. Only the entries these tests exercise.
    private let catalogLabels: [String: String] = [
        "codex.all-models": "All",
        "codex.spark": "Spark",
        "claude.all-models": "All",
        "claude.fable": "Fable",
        "gemini.all-models": "All",
        "antigravity.gemini-models": "Gemini",
        "antigravity.claude-gpt-models": "Claude + GPT",
        "cursor.models": "Cursor"
    ]

    private func label(
        _ run: MenuBarFieldRun,
        customLabels: [String: String] = [:]
    ) -> String {
        MenuBarFieldCatalog.mergedGroupLabel(
            for: run,
            customLabels: customLabels,
            groupCatalogLabel: { self.catalogLabels[$0] }
        )
    }

    // MARK: - Which fields are "the same group"

    func testHeadlineWindowsOfOneSubProviderShareTheAllModelsKey() {
        XCTAssertEqual(
            MenuBarFieldCatalog.namingGroupKey(for: field("claude.five_hour")),
            "claude.all-models"
        )
        XCTAssertEqual(
            MenuBarFieldCatalog.namingGroupKey(for: field("claude.weekly")),
            "claude.all-models"
        )
        // A named model group is its own key, so Fable never folds into the
        // SubProvider's headline pair.
        XCTAssertEqual(
            MenuBarFieldCatalog.namingGroupKey(for: field("claude.weekly_fable")),
            "claude.fable"
        )
    }

    func testGrokBotSitsDirectlyUnderItsSubProviderAndNeverMerges() {
        XCTAssertNil(MenuBarFieldCatalog.namingGroupKey(for: field("cursor.grok_bot_weekly")))
        let runs = MenuBarFieldCatalog.runs(
            [field("cursor.other_models"), field("cursor.grok_bot_weekly")],
            merging: true
        )
        XCTAssertEqual(runs.count, 2)
        XCTAssertFalse(runs[0].isMerged)
        XCTAssertFalse(runs[1].isMerged)
    }

    // MARK: - Runs

    func testMergingOffLeavesEveryFieldOnItsOwn() {
        let fields = [field("claude.five_hour"), field("claude.weekly")]
        let runs = MenuBarFieldCatalog.runs(fields, merging: false)
        XCTAssertEqual(runs.count, 2)
        XCTAssertTrue(runs.allSatisfy { !$0.isMerged })
        // No key is computed at all while the setting is off.
        XCTAssertTrue(runs.allSatisfy { $0.groupKey == nil })
    }

    func testFiveHourAndWeeklyOfOneSubProviderMergeIntoOnePiece() {
        let runs = MenuBarFieldCatalog.runs(
            [field("claude.five_hour"), field("claude.weekly")],
            merging: true
        )
        XCTAssertEqual(runs.count, 1)
        XCTAssertTrue(runs[0].isMerged)
        XCTAssertEqual(runs[0].groupKey, "claude.all-models")
        XCTAssertEqual(runs[0].fields.map(\.id), ["claude.five_hour", "claude.weekly"])
        XCTAssertEqual(runs[0].primary.id, "claude.five_hour")
    }

    func testMergedPieceFollowsSelectionOrder() {
        let runs = MenuBarFieldCatalog.runs(
            [field("claude.weekly"), field("claude.five_hour")],
            merging: true
        )
        XCTAssertEqual(runs[0].fields.map(\.id), ["claude.weekly", "claude.five_hour"])
        XCTAssertEqual(runs[0].primary.id, "claude.weekly")
    }

    func testDifferentGroupsUnderOneSubProviderStayApart() {
        let runs = MenuBarFieldCatalog.runs(
            [
                field("codex.five_hour"),
                field("codex.weekly"),
                field("codex.gpt_5_3_codex_spark_five_hour"),
                field("codex.gpt_5_3_codex_spark_weekly")
            ],
            merging: true
        )
        XCTAssertEqual(runs.map(\.groupKey), ["codex.all-models", "codex.spark"])
        XCTAssertEqual(runs.map(\.fields.count), [2, 2])
    }

    func testAntigravityPoolsMergeSeparately() {
        let runs = MenuBarFieldCatalog.runs(
            [
                field("antigravity.gemini_five_hour"),
                field("antigravity.gemini_weekly"),
                field("antigravity.claude_gpt_five_hour"),
                field("antigravity.claude_gpt_weekly")
            ],
            merging: true
        )
        XCTAssertEqual(
            runs.map(\.groupKey),
            ["antigravity.gemini-models", "antigravity.claude-gpt-models"]
        )
    }

    func testOnlyAdjacentFieldsMerge() {
        // The user's arrangement is the arrangement: interleaving two
        // providers is a deliberate layout, not something to reshuffle.
        let runs = MenuBarFieldCatalog.runs(
            [field("claude.five_hour"), field("codex.weekly"), field("claude.weekly")],
            merging: true
        )
        XCTAssertEqual(runs.count, 3)
        XCTAssertTrue(runs.allSatisfy { !$0.isMerged })
    }

    func testDiscoveredWindowsOfOneRuntimeGroupMerge() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let registry = QuotaFieldRegistry(fields: [
            DiscoveredQuotaField(
                tool: .codex,
                bucketId: "gpt_reserve_five_hour",
                title: "5 Hours",
                groupTitle: "GPT-reserve",
                shortLabel: "5 Hours",
                firstSeen: now,
                lastSeen: now
            ),
            DiscoveredQuotaField(
                tool: .codex,
                bucketId: "gpt_reserve_weekly",
                title: "Weekly",
                groupTitle: "GPT-reserve",
                shortLabel: "Weekly",
                firstSeen: now,
                lastSeen: now
            )
        ])
        let fields = registry.fields.map(MenuBarFieldCatalog.option(for:))
        let runs = MenuBarFieldCatalog.runs(fields, merging: true)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].groupKey, "codex.gpt_reserve")
        // No static catalog entry names this group; the adapter's own group
        // title is the fallback.
        XCTAssertEqual(label(runs[0]), "GPT-reserve")
    }

    // MARK: - What a merged piece is called

    func testMergedHeadlinePieceNamesTheSubProviderNotAWindow() {
        let claude = MenuBarFieldCatalog.runs(
            [field("claude.five_hour"), field("claude.weekly")],
            merging: true
        )[0]
        // "Claude 5%/100%", never "5 Hours 5%/100%" and never the mini
        // window's bare "All", which only reads because a SubProvider header
        // sits above it there.
        XCTAssertEqual(label(claude), "Claude")

        let gemini = MenuBarFieldCatalog.runs(
            [field("gemini.five_hour"), field("gemini.weekly")],
            merging: true
        )[0]
        XCTAssertEqual(label(gemini), "Gemini Web")
    }

    func testMergedBranchPieceNamesItsQuotaGroup() {
        let spark = MenuBarFieldCatalog.runs(
            [
                field("codex.gpt_5_3_codex_spark_five_hour"),
                field("codex.gpt_5_3_codex_spark_weekly")
            ],
            merging: true
        )[0]
        XCTAssertEqual(label(spark), "Spark")

        let antigravity = MenuBarFieldCatalog.runs(
            [field("antigravity.claude_gpt_five_hour"), field("antigravity.claude_gpt_weekly")],
            merging: true
        )[0]
        XCTAssertEqual(label(antigravity), "Claude + GPT")
    }

    func testCustomLabelOfTheFirstNamedMemberWins() {
        let run = MenuBarFieldCatalog.runs(
            [field("claude.five_hour"), field("claude.weekly")],
            merging: true
        )[0]
        XCTAssertEqual(
            label(run, customLabels: ["claude.five_hour": "CC", "claude.weekly": "CW"]),
            "CC"
        )
        // Only a later member was renamed: that name still wins over the
        // group's default, because the user named this group something.
        XCTAssertEqual(label(run, customLabels: ["claude.weekly": "CW"]), "CW")
        // Whitespace is not a name.
        XCTAssertEqual(label(run, customLabels: ["claude.five_hour": "   "]), "Claude")
    }
}
