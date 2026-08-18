import XCTest
@testable import VibeBarCore

final class MenuBarFieldCatalogTests: XCTestCase {
    func testDedicatedProviderMiniFieldsAreCatalogued() {
        // Gemini Web (jSf9Qc parser) only emits 5-hour and weekly
        // buckets — the per-model CLI ids the catalog used to carry
        // (gemini.gemini-2.5-pro etc.) are migrated to `gemini.five_hour`
        // via `fieldIdMigrations`.
        let expected = [
            "gemini.five_hour",
            "gemini.weekly",
            "antigravity.gemini_five_hour",
            "antigravity.gemini_weekly",
            "antigravity.claude_gpt_five_hour",
            "antigravity.claude_gpt_weekly",
            "grok.weekly",
            "cursor.models",
            "cursor.other_models",
            "cursor.grok_bot_weekly"
        ]

        for id in expected {
            XCTAssertNotNil(MenuBarFieldCatalog.field(id: id), "\(id) should be selectable in the mini window")
        }
    }

    func testDefaultMiniWindowIncludesDedicatedProviderFields() {
        let selected = Set(AppSettings.defaultMiniWindow.selectedFieldIds)
        XCTAssertTrue(selected.contains("gemini.five_hour"))
        XCTAssertTrue(selected.contains("gemini.weekly"))
        XCTAssertTrue(selected.contains("antigravity.gemini_five_hour"))
        XCTAssertTrue(selected.contains("antigravity.gemini_weekly"))
        XCTAssertTrue(selected.contains("antigravity.claude_gpt_five_hour"))
        XCTAssertTrue(selected.contains("antigravity.claude_gpt_weekly"))
        XCTAssertTrue(selected.contains("grok.weekly"))
        XCTAssertTrue(selected.contains("cursor.models"))
        XCTAssertTrue(selected.contains("cursor.other_models"))
        XCTAssertTrue(selected.contains("cursor.grok_bot_weekly"))
    }

    func testDefaultLabelsUseFullQuotaWindowNames() {
        for field in MenuBarFieldCatalog.allFields {
            let words = field.defaultLabel
                .split(whereSeparator: { $0.isWhitespace })
                .map { $0.lowercased() }
            XCTAssertFalse(words.contains("5h"), "\(field.id) must spell out 5 Hours")
            XCTAssertFalse(words.contains("wk"), "\(field.id) must spell out Weekly")
        }
    }

    func testCursorFieldsUseMonthlyModelsAndWeeklyBotLabels() throws {
        XCTAssertEqual(
            try XCTUnwrap(MenuBarFieldCatalog.field(id: "cursor.models")).title,
            "Cursor Models · Monthly"
        )
        XCTAssertEqual(
            try XCTUnwrap(MenuBarFieldCatalog.field(id: "cursor.other_models")).title,
            "Other Models · Monthly"
        )
        XCTAssertEqual(
            try XCTUnwrap(MenuBarFieldCatalog.field(id: "cursor.grok_bot_weekly")).title,
            "Grok Bot · Weekly"
        )
    }

    /// Grok Bot rides Cursor's adapter but is its own L2 SubProvider, so it
    /// gets its own catalog slice — and therefore its own section header —
    /// without changing a single field id.
    func testGrokBotIsItsOwnCatalogSliceWithUnchangedFieldIds() {
        XCTAssertEqual(
            MenuBarFieldCatalog.cursorFields.map(\.id),
            ["cursor.models", "cursor.other_models"]
        )
        XCTAssertEqual(MenuBarFieldCatalog.grokBotFields.map(\.id), ["cursor.grok_bot_weekly"])
        XCTAssertEqual(MenuBarFieldCatalog.grokBotFields.map(\.tool), [.cursor])
        XCTAssertEqual(
            ToolType.cursor.quotaSubProviderName(bucketID: "grok_bot_weekly"),
            "Grok Bot"
        )

        // Regrouping, not migration: every id still resolves, the set is
        // unchanged, and nothing needs a `fieldIdMigrations` entry.
        let all = MenuBarFieldCatalog.allFields.map(\.id)
        XCTAssertEqual(Set(all).count, all.count, "field ids must stay unique")
        XCTAssertTrue(all.contains("cursor.grok_bot_weekly"))
        XCTAssertEqual(
            MenuBarFieldCatalog.migratedFieldIds(["cursor.grok_bot_weekly"]),
            ["cursor.grok_bot_weekly"]
        )
        let sliced = MenuBarFieldCatalog.codexFields + MenuBarFieldCatalog.claudeFields
            + MenuBarFieldCatalog.geminiFields + MenuBarFieldCatalog.antigravityFields
            + MenuBarFieldCatalog.grokFields + MenuBarFieldCatalog.cursorFields
            + MenuBarFieldCatalog.grokBotFields
        XCTAssertEqual(sliced.map(\.id), all)
    }

    // MARK: - SubProvider grouping

    private func allSelectedGroups() -> [MenuBarCompanyFieldGroup] {
        MenuBarFieldCatalog.subProviderGroups(
            for: ToolType.dedicatedCardProviders,
            selectedFieldIds: Set(MenuBarFieldCatalog.allFields.map(\.id))
        )
    }

    /// The mini window's middle tier. Companies fold by vendor, and one tool
    /// can contribute two SubProviders — which is the whole point: Grok Bot
    /// rides Cursor's adapter but must not sit inside Cursor's section.
    func testSubProviderGroupsFollowTheQuotaHierarchy() {
        let groups = allSelectedGroups()
        XCTAssertEqual(groups.map(\.company), ["OpenAI", "Anthropic", "Google AI", "SpaceXAI"])
        XCTAssertEqual(
            groups.map { $0.subProviders.map(\.name) },
            [
                ["ChatGPT Agentic"],
                ["Claude"],
                ["Gemini Web", "AntiGravity"],
                ["Grok", "Cursor", "Grok Bot"]
            ]
        )
        XCTAssertEqual(groups.map(\.accentTool), [.codex, .claude, .gemini, .grok])
    }

    func testSubProviderGroupsCarryTheirBucketsInCatalogOrder() throws {
        let byName = allSelectedGroups()
            .flatMap(\.subProviders)
            .reduce(into: [String: MenuBarSubProviderGroup]()) { $0[$1.name] = $1 }

        XCTAssertEqual(
            try XCTUnwrap(byName["ChatGPT Agentic"]).bucketIds,
            ["five_hour", "weekly", "gpt_5_3_codex_spark_five_hour", "gpt_5_3_codex_spark_weekly"]
        )
        XCTAssertEqual(
            try XCTUnwrap(byName["Claude"]).bucketIds,
            [
                "five_hour", "weekly", "weekly_sonnet", "weekly_design",
                "daily_routines", "weekly_opus", "weekly_fable", "weekly_oauth_apps"
            ]
        )
        XCTAssertEqual(try XCTUnwrap(byName["Gemini Web"]).bucketIds, ["five_hour", "weekly"])
        XCTAssertEqual(
            try XCTUnwrap(byName["AntiGravity"]).bucketIds,
            ["gemini_five_hour", "gemini_weekly", "claude_gpt_five_hour", "claude_gpt_weekly"]
        )
        XCTAssertEqual(try XCTUnwrap(byName["Grok"]).bucketIds, ["weekly"])
        XCTAssertEqual(try XCTUnwrap(byName["Cursor"]).bucketIds, ["models", "other_models"])
        XCTAssertEqual(try XCTUnwrap(byName["Grok Bot"]).bucketIds, ["grok_bot_weekly"])

        // Cursor and Grok Bot share one adapter, so the tool alone can't
        // identify a section — the id has to carry the SubProvider name.
        XCTAssertEqual(try XCTUnwrap(byName["Cursor"]).tool, .cursor)
        XCTAssertEqual(try XCTUnwrap(byName["Grok Bot"]).tool, .cursor)
        XCTAssertEqual(try XCTUnwrap(byName["Grok Bot"]).id, "cursor/Grok Bot")
    }

    /// Every selected field lands in exactly one section, and nothing that
    /// wasn't selected sneaks in — the layout partitions the selection.
    func testSubProviderGroupsPartitionTheSelection() {
        let selected: Set<String> = [
            "codex.weekly",
            "claude.five_hour",
            "antigravity.gemini_weekly",
            "cursor.grok_bot_weekly"
        ]
        let groups = MenuBarFieldCatalog.subProviderGroups(
            for: ToolType.dedicatedCardProviders,
            selectedFieldIds: selected
        )
        XCTAssertEqual(groups.map(\.company), ["OpenAI", "Anthropic", "Google AI", "SpaceXAI"])
        XCTAssertEqual(
            groups.map { $0.subProviders.map(\.name) },
            [["ChatGPT Agentic"], ["Claude"], ["AntiGravity"], ["Grok Bot"]]
        )
        let emitted = groups.flatMap { $0.subProviders.flatMap(\.fieldIds) }
        XCTAssertEqual(Set(emitted), selected)
        XCTAssertEqual(emitted.count, selected.count)
    }

    func testSubProviderGroupsDropCompaniesWithNothingSelected() {
        XCTAssertTrue(
            MenuBarFieldCatalog.subProviderGroups(
                for: ToolType.dedicatedCardProviders,
                selectedFieldIds: []
            ).isEmpty
        )
        let onlyCursor = MenuBarFieldCatalog.subProviderGroups(
            for: ToolType.dedicatedCardProviders,
            selectedFieldIds: ["cursor.models"]
        )
        XCTAssertEqual(onlyCursor.map(\.company), ["SpaceXAI"])
        XCTAssertEqual(onlyCursor.first?.accentTool, .cursor)
        XCTAssertEqual(onlyCursor.flatMap { $0.subProviders.map(\.name) }, ["Cursor"])
    }

    func testGeminiCLIModelIdsMigrateToWebBuckets() {
        // Old Gemini CLI fields no longer have catalog entries; all of
        // them must migrate to the Web parser's `gemini.five_hour`
        // bucket so users upgrading from <= 0.1 builds don't lose
        // their Gemini quota cells.
        let legacy = [
            "gemini.gemini_pro",
            "gemini.gemini_flash",
            "gemini.gemini_flash_lite",
            "gemini.gemini-2.5-pro",
            "gemini.gemini-2.5-flash",
            "gemini.gemini-2.5-flash-lite",
            "gemini.gemini-3-pro",
            "gemini.gemini-3-flash"
        ]
        let migrated = MenuBarFieldCatalog.migratedFieldIds(legacy)
        XCTAssertEqual(migrated, ["gemini.five_hour"])
    }

    func testAntigravityPerModelIdsMigrateToSharedFiveHourPools() {
        let legacy = [
            "antigravity.gemini-3.5-flash-high",
            "antigravity.gemini-3.1-pro-low",
            "antigravity.claude-sonnet-4.6-thinking",
            "antigravity.gpt-oss-120b-medium"
        ]
        XCTAssertEqual(MenuBarFieldCatalog.migratedFieldIds(legacy), [
            "antigravity.gemini_five_hour",
            "antigravity.claude_gpt_five_hour"
        ])
    }
}
