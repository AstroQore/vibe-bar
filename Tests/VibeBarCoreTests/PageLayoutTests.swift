import XCTest
@testable import VibeBarCore

final class PageLayoutTests: XCTestCase {

    // MARK: - PageLayoutModuleID

    func testModuleIDConventionHelpers() {
        XCTAssertEqual(
            PageLayoutModuleID.quotaGroup(tool: .claude, groupKey: "five_hour").rawValue,
            "quota-group:claude:five_hour"
        )
        XCTAssertEqual(PageLayoutModuleID.cost(tool: .codex).rawValue, "cost:codex")
        XCTAssertEqual(PageLayoutModuleID.costAll.rawValue, "cost-all")
        XCTAssertEqual(PageLayoutModuleID.quotaHistoryAll.rawValue, "quota-history-all")
        XCTAssertEqual(PageLayoutModuleID.status.rawValue, "status")
        XCTAssertEqual(
            PageLayoutModuleID.modelBreakdown(tool: .gemini).rawValue,
            "model-breakdown:gemini"
        )
        XCTAssertEqual(PageLayoutModuleID.custom("whatever").rawValue, "whatever")
    }

    func testModuleIDFamilyAndToolParsing() {
        XCTAssertEqual(PageLayoutModuleID.quotaGroup(tool: .grok, groupKey: "weekly").family, "quota-group")
        XCTAssertEqual(PageLayoutModuleID.quotaGroup(tool: .grok, groupKey: "weekly").tool, .grok)
        XCTAssertEqual(PageLayoutModuleID.cost(tool: .antigravity).tool, .antigravity)
        XCTAssertEqual(PageLayoutModuleID.modelBreakdown(tool: .claude).tool, .claude)

        XCTAssertEqual(PageLayoutModuleID.status.family, "status")
        XCTAssertNil(PageLayoutModuleID.status.tool)
        XCTAssertNil(PageLayoutModuleID.costAll.tool)

        // A tool this build does not know does not crash or half-parse.
        let future = PageLayoutModuleID("cost:some-future-provider")
        XCTAssertEqual(future.family, "cost")
        XCTAssertNil(future.tool)
    }

    func testModuleIDRoundTripsIncludingUnknownStrings() throws {
        let ids: [PageLayoutModuleID] = [
            .quotaGroup(tool: .claude, groupKey: "weekly_fable"),
            .cost(tool: .codex),
            .costAll,
            .quotaHistoryAll,
            .status,
            .modelBreakdown(tool: .grok),
            PageLayoutModuleID("some-future-card"),
            PageLayoutModuleID("future:with:many:qualifiers"),
            PageLayoutModuleID(""),
            PageLayoutModuleID("中文卡片")
        ]

        let data = try JSONEncoder().encode(ids)
        let decoded = try JSONDecoder().decode([PageLayoutModuleID].self, from: data)
        XCTAssertEqual(decoded, ids)

        // Encodes as bare strings, not as a wrapper object.
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String])
        XCTAssertEqual(raw, ids.map(\.rawValue))
    }

    // MARK: - PageLayoutPageID

    func testPageIDConventionAndParsing() {
        XCTAssertEqual(PageLayoutPageID.overview.rawValue, "overview")
        XCTAssertEqual(PageLayoutPageID.detail(.claude).rawValue, "detail:claude")
        XCTAssertTrue(PageLayoutPageID.overview.isOverview)
        XCTAssertFalse(PageLayoutPageID.detail(.codex).isOverview)
        XCTAssertEqual(PageLayoutPageID.detail(.codex).detailTool, .codex)
        XCTAssertNil(PageLayoutPageID.overview.detailTool)
        XCTAssertNil(PageLayoutPageID("detail:some-future-provider").detailTool)
        XCTAssertNil(PageLayoutPageID("something-else").detailTool)
    }

    func testPageIDRoundTripsIncludingUnknownStrings() throws {
        let pages: [PageLayoutPageID] = [
            .overview,
            .detail(.claude),
            .detail(.antigravity),
            PageLayoutPageID("detail:some-future-provider"),
            PageLayoutPageID("misc"),
            PageLayoutPageID("")
        ]
        let data = try JSONEncoder().encode(pages)
        XCTAssertEqual(try JSONDecoder().decode([PageLayoutPageID].self, from: data), pages)
    }

    // MARK: - PageColumnRatio

    func testColumnRatioFractions() {
        XCTAssertEqual(PageColumnRatio.narrowWide.leftFraction, 0.38, accuracy: 0.0001)
        XCTAssertEqual(PageColumnRatio.narrowWide.rightFraction, 0.62, accuracy: 0.0001)
        XCTAssertEqual(PageColumnRatio.equal.leftFraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(PageColumnRatio.equal.rightFraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(PageColumnRatio.wideNarrow.leftFraction, 0.62, accuracy: 0.0001)
        XCTAssertEqual(PageColumnRatio.wideNarrow.rightFraction, 0.38, accuracy: 0.0001)

        for ratio in PageColumnRatio.allCases {
            XCTAssertEqual(ratio.leftFraction + ratio.rightFraction, 1, accuracy: 0.0001)
            XCTAssertEqual(ratio.fraction(forColumn: 0), ratio.leftFraction)
            XCTAssertEqual(ratio.fraction(forColumn: 1), ratio.rightFraction)
        }
    }

    func testColumnRatioRoundTripsAndFallsBackForUnknownValues() throws {
        for ratio in PageColumnRatio.allCases {
            let data = try JSONEncoder().encode([ratio])
            XCTAssertEqual(try JSONDecoder().decode([PageColumnRatio].self, from: data), [ratio])
        }

        let unknown = Data(#"["golden-spiral"]"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode([PageColumnRatio].self, from: unknown), [.equal])
    }

    // MARK: - PageLayoutConfig

    func testConfigNormalizesToTwoColumns() {
        let tooFew = PageLayoutConfig(columns: [[.status]])
        XCTAssertEqual(tooFew.columns.count, 2)
        XCTAssertEqual(tooFew.leftColumn, [.status])
        XCTAssertTrue(tooFew.rightColumn.isEmpty)

        // Extra columns from a hypothetical three-column build fold into the
        // last column rather than losing those modules.
        let tooMany = PageLayoutConfig(columns: [[.status], [.costAll], [.quotaHistoryAll]])
        XCTAssertEqual(tooMany.columns.count, 2)
        XCTAssertEqual(tooMany.leftColumn, [.status])
        XCTAssertEqual(tooMany.rightColumn, [.costAll, .quotaHistoryAll])

        XCTAssertEqual(PageLayoutConfig().columns, [[], []])
        XCTAssertTrue(PageLayoutConfig().isEmpty)
    }

    func testConfigDropsDuplicatesAndEmptyIdentifiers() {
        let config = PageLayoutConfig(
            columns: [
                [.status, .costAll, .status],
                [.costAll, PageLayoutModuleID(""), .quotaHistoryAll]
            ]
        )
        XCTAssertEqual(config.leftColumn, [.status, .costAll])
        XCTAssertEqual(config.rightColumn, [.quotaHistoryAll])
        XCTAssertEqual(config.moduleIDs.count, Set(config.moduleIDs).count)
    }

    func testConfigSanitizesMeasuredHeights() {
        let config = PageLayoutConfig(
            columns: [[.status], []],
            measuredHeights: [
                .status: 120,
                .costAll: 0,
                .quotaHistoryAll: -5,
                PageLayoutModuleID("nan"): .nan,
                PageLayoutModuleID("inf"): .infinity
            ]
        )
        XCTAssertEqual(config.measuredHeights, [.status: 120])
        XCTAssertEqual(config.measuredHeight(for: .status), 120)
        XCTAssertNil(config.measuredHeight(for: .costAll))
    }

    func testConfigColumnAccessorsAreClampedAndSearchable() {
        let config = PageLayoutConfig(columns: [[.status], [.costAll]])
        XCTAssertEqual(config.column(-3), [.status])
        XCTAssertEqual(config.column(0), [.status])
        XCTAssertEqual(config.column(1), [.costAll])
        XCTAssertEqual(config.column(9), [.costAll])
        XCTAssertEqual(config.columnIndex(of: .status), 0)
        XCTAssertEqual(config.columnIndex(of: .costAll), 1)
        XCTAssertNil(config.columnIndex(of: .quotaHistoryAll))
        XCTAssertEqual(config.moduleIDs, [.status, .costAll])
    }

    func testConfigMovingNeverDuplicatesAndClampsIndices() {
        let config = PageLayoutConfig(
            columns: [[.status, .costAll], [.quotaHistoryAll]]
        )

        let acrossColumns = config.moving(.status, toColumn: 1, at: 0)
        XCTAssertEqual(acrossColumns.leftColumn, [.costAll])
        XCTAssertEqual(acrossColumns.rightColumn, [.status, .quotaHistoryAll])

        let withinColumn = config.moving(.costAll, toColumn: 0, at: 0)
        XCTAssertEqual(withinColumn.leftColumn, [.costAll, .status])

        let clamped = config.moving(.quotaHistoryAll, toColumn: 42, at: 99)
        XCTAssertEqual(clamped.rightColumn, [.quotaHistoryAll])
        XCTAssertEqual(clamped.moduleIDs.count, 3)
        XCTAssertEqual(clamped.moduleIDs.count, Set(clamped.moduleIDs).count)
    }

    func testConfigSetColumnsReappliesInvariants() {
        var config = PageLayoutConfig(ratio: .wideNarrow)
        config.setColumns([[.status, .status, .costAll]])
        XCTAssertEqual(config.leftColumn, [.status, .costAll])
        XCTAssertTrue(config.rightColumn.isEmpty)
        XCTAssertEqual(config.ratio, .wideNarrow)
    }

    func testConfigRoundTripsWithStringKeyedHeights() throws {
        let config = PageLayoutConfig(
            ratio: .narrowWide,
            columns: [[.status, .cost(tool: .codex)], [.costAll]],
            measuredHeights: [.status: 88.5, .costAll: 132]
        )
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(PageLayoutConfig.self, from: data), config)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["ratio"] as? String, "narrow-wide")
        let heights = try XCTUnwrap(object["measuredHeights"] as? [String: Double])
        XCTAssertEqual(heights["status"], 88.5)
        XCTAssertEqual(heights["cost-all"], 132)
    }

    func testConfigDecodeToleratesMissingAndMalformedFields() throws {
        let empty = try JSONDecoder().decode(PageLayoutConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.ratio, .equal)
        XCTAssertEqual(empty.columns, [[], []])
        XCTAssertTrue(empty.measuredHeights.isEmpty)

        let junk = Data(#"""
        {
          "ratio": 17,
          "columns": "left-and-right",
          "measuredHeights": ["status", 12],
          "someFutureField": {"nested": true}
        }
        """#.utf8)
        let decoded = try JSONDecoder().decode(PageLayoutConfig.self, from: junk)
        XCTAssertEqual(decoded.ratio, .equal)
        XCTAssertEqual(decoded.columns, [[], []])
        XCTAssertTrue(decoded.measuredHeights.isEmpty)

        // Unknown module identifiers inside a well-formed file survive intact.
        let forward = Data(#"""
        {
          "ratio": "wide-narrow",
          "columns": [["status", "future-card:v9"], ["cost-all"]],
          "measuredHeights": {"future-card:v9": 44},
          "unknownKey": 1
        }
        """#.utf8)
        let ahead = try JSONDecoder().decode(PageLayoutConfig.self, from: forward)
        XCTAssertEqual(ahead.ratio, .wideNarrow)
        XCTAssertEqual(ahead.leftColumn, [.status, PageLayoutModuleID("future-card:v9")])
        XCTAssertEqual(ahead.rightColumn, [.costAll])
        XCTAssertEqual(ahead.measuredHeight(for: PageLayoutModuleID("future-card:v9")), 44)
    }

    // MARK: - PageLayoutResolver

    private var defaultConfig: PageLayoutConfig {
        PageLayoutConfig(
            ratio: .narrowWide,
            columns: [
                [.quotaGroup(tool: .codex, groupKey: "weekly"), .costAll],
                [.quotaGroup(tool: .claude, groupKey: "weekly"), .quotaHistoryAll, .status]
            ]
        )
    }

    func testResolveWithoutConfiguredLayoutReproducesTheDefault() {
        let resolved = PageLayoutResolver.resolve(
            configured: nil,
            available: defaultConfig.moduleIDs.shuffled(),
            defaultConfig: defaultConfig
        )
        XCTAssertEqual(resolved.columns, defaultConfig.columns)
        XCTAssertEqual(resolved.ratio, .narrowWide)
    }

    func testResolveDropsModulesThatAreNoLongerAvailable() {
        let configured = PageLayoutConfig(
            ratio: .wideNarrow,
            columns: [
                [.status, .costAll],
                [.quotaHistoryAll, .quotaGroup(tool: .claude, groupKey: "weekly")]
            ]
        )
        let resolved = PageLayoutResolver.resolve(
            configured: configured,
            available: [.status, .quotaHistoryAll],
            defaultConfig: defaultConfig
        )
        XCTAssertEqual(resolved.leftColumn, [.status])
        XCTAssertEqual(resolved.rightColumn, [.quotaHistoryAll])
        XCTAssertEqual(resolved.ratio, .wideNarrow)
    }

    func testResolveAppendsNewModulesAtTheirDefaultColumnAfterConfiguredItems() {
        // User moved `status` (default: right) to the left column and dropped
        // nothing. `quotaHistoryAll` and `costAll` are newly available.
        let configured = PageLayoutConfig(
            ratio: .equal,
            columns: [
                [.status, .quotaGroup(tool: .codex, groupKey: "weekly")],
                [.quotaGroup(tool: .claude, groupKey: "weekly")]
            ]
        )
        let resolved = PageLayoutResolver.resolve(
            configured: configured,
            available: [
                .status,
                .quotaGroup(tool: .codex, groupKey: "weekly"),
                .quotaGroup(tool: .claude, groupKey: "weekly"),
                .quotaHistoryAll,
                .costAll
            ],
            defaultConfig: defaultConfig
        )

        // Left keeps the user's order, then gains `costAll` (default column 0).
        XCTAssertEqual(
            resolved.leftColumn,
            [.status, .quotaGroup(tool: .codex, groupKey: "weekly"), .costAll]
        )
        // Right keeps its configured item, then gains `quotaHistoryAll`.
        XCTAssertEqual(
            resolved.rightColumn,
            [.quotaGroup(tool: .claude, groupKey: "weekly"), .quotaHistoryAll]
        )
        XCTAssertEqual(resolved.ratio, .equal)
    }

    func testResolveAppendsSeveralNewModulesInDefaultRelativeOrder() {
        let configured = PageLayoutConfig(
            ratio: .equal,
            columns: [[.quotaGroup(tool: .codex, groupKey: "weekly")], []]
        )
        // Presented out of default order on purpose.
        let resolved = PageLayoutResolver.resolve(
            configured: configured,
            available: [
                .status,
                .quotaHistoryAll,
                .quotaGroup(tool: .claude, groupKey: "weekly"),
                .quotaGroup(tool: .codex, groupKey: "weekly"),
                .costAll
            ],
            defaultConfig: defaultConfig
        )
        XCTAssertEqual(
            resolved.leftColumn,
            [.quotaGroup(tool: .codex, groupKey: "weekly"), .costAll]
        )
        XCTAssertEqual(
            resolved.rightColumn,
            [.quotaGroup(tool: .claude, groupKey: "weekly"), .quotaHistoryAll, .status]
        )
    }

    func testResolveNeverLosesOrDuplicatesAModule() {
        let configured = PageLayoutConfig(
            columns: [
                [.status, .costAll, .status],
                [.costAll, .quotaHistoryAll]
            ]
        )
        let available: [PageLayoutModuleID] = [
            .status,
            .costAll,
            .quotaHistoryAll,
            .quotaGroup(tool: .codex, groupKey: "weekly"),
            .quotaGroup(tool: .claude, groupKey: "weekly"),
            // Listed twice by a sloppy caller.
            .status
        ]
        let resolved = PageLayoutResolver.resolve(
            configured: configured,
            available: available,
            defaultConfig: defaultConfig
        )
        XCTAssertEqual(Set(resolved.moduleIDs), Set(available))
        XCTAssertEqual(resolved.moduleIDs.count, Set(available).count)
    }

    func testResolveWithNoAvailableModulesYieldsEmptyColumns() {
        let resolved = PageLayoutResolver.resolve(
            configured: PageLayoutConfig(ratio: .wideNarrow, columns: [[.status], [.costAll]]),
            available: [],
            defaultConfig: defaultConfig
        )
        XCTAssertEqual(resolved.columns, [[], []])
        XCTAssertTrue(resolved.isEmpty)
    }

    func testResolvePutsModulesUnknownToTheDefaultInTheLeftColumn() {
        let stranger = PageLayoutModuleID("future-card:v9")
        let resolved = PageLayoutResolver.resolve(
            configured: nil,
            available: [stranger, .status, .costAll],
            defaultConfig: defaultConfig
        )
        XCTAssertEqual(resolved.leftColumn, [.costAll, stranger])
        XCTAssertEqual(resolved.rightColumn, [.status])
    }

    func testResolveUsesDefaultRatioForAConfigWithNoModules() {
        // What a heights-only store entry looks like: the user never arranged
        // anything, so the page keeps the built-in ratio.
        let heightsOnly = PageLayoutConfig(
            ratio: .equal,
            columns: [],
            measuredHeights: [.status: 90]
        )
        let resolved = PageLayoutResolver.resolve(
            configured: heightsOnly,
            available: defaultConfig.moduleIDs,
            defaultConfig: defaultConfig
        )
        XCTAssertEqual(resolved.ratio, .narrowWide)
        XCTAssertEqual(resolved.columns, defaultConfig.columns)
        XCTAssertEqual(resolved.measuredHeight(for: .status), 90)
    }

    func testResolveCarriesMeasuredHeightsThroughWithConfiguredValuesWinning() {
        let defaults = PageLayoutConfig(
            columns: [[.status], [.costAll]],
            measuredHeights: [.status: 40, .costAll: 50]
        )
        let configured = PageLayoutConfig(
            columns: [[.costAll], [.status]],
            measuredHeights: [.status: 41]
        )
        let resolved = PageLayoutResolver.resolve(
            configured: configured,
            available: [.status, .costAll],
            defaultConfig: defaults
        )
        XCTAssertEqual(resolved.measuredHeight(for: .status), 41)
        XCTAssertEqual(resolved.measuredHeight(for: .costAll), 50)
    }

    func testResolveIsStableWhenNothingChanged() {
        let configured = PageLayoutConfig(
            ratio: .wideNarrow,
            columns: [[.costAll, .status], [.quotaHistoryAll]]
        )
        let available = configured.moduleIDs
        let once = PageLayoutResolver.resolve(
            configured: configured,
            available: available,
            defaultConfig: defaultConfig
        )
        let twice = PageLayoutResolver.resolve(
            configured: once,
            available: available,
            defaultConfig: defaultConfig
        )
        XCTAssertEqual(once, configured)
        XCTAssertEqual(twice, once)
    }

    // MARK: - PageLayoutResolver.mergingEdit

    func testMergingEditWithoutASavedLayoutKeepsTheEdit() {
        let edited = PageLayoutConfig(
            ratio: .wideNarrow,
            columns: [[.status], [.costAll]]
        )
        let merged = PageLayoutResolver.mergingEdit(
            edited,
            into: nil,
            available: [.status, .costAll]
        )
        XCTAssertEqual(merged, edited)
    }

    func testMergingEditKeepsUnavailableModulesInTheirSavedColumn() {
        // Saved with four cards; only two can be drawn right now.
        let stored = PageLayoutConfig(
            ratio: .equal,
            columns: [
                [.status, .quotaGroup(tool: .claude, groupKey: "weekly")],
                [.costAll, .quotaHistoryAll]
            ]
        )
        let available: [PageLayoutModuleID] = [.status, .costAll]
        // The user dragged `status` across to the right column.
        let edited = PageLayoutConfig(ratio: .equal, columns: [[], [.costAll, .status]])

        let merged = PageLayoutResolver.mergingEdit(edited, into: stored, available: available)

        // The move lands, and the two invisible cards keep their saved column.
        XCTAssertEqual(merged.leftColumn, [.quotaGroup(tool: .claude, groupKey: "weekly")])
        // `quotaHistoryAll` was saved directly behind `costAll`, so it stays
        // there; the dropped card lands after both.
        XCTAssertEqual(merged.rightColumn, [.costAll, .quotaHistoryAll, .status])
    }

    func testMergingEditReAnchorsAnUnavailableModuleBehindItsSavedNeighbour() {
        let stored = PageLayoutConfig(
            ratio: .equal,
            columns: [
                [.status, .quotaHistoryAll, .costAll],
                []
            ]
        )
        // `quotaHistoryAll` is temporarily gone; the user swapped the two that
        // remain.
        let available: [PageLayoutModuleID] = [.status, .costAll]
        let edited = PageLayoutConfig(ratio: .equal, columns: [[.costAll, .status], []])

        let merged = PageLayoutResolver.mergingEdit(edited, into: stored, available: available)

        // It followed `status`, the saved neighbour it used to sit behind,
        // rather than snapping back to a fixed index.
        XCTAssertEqual(merged.leftColumn, [.costAll, .status, .quotaHistoryAll])
    }

    func testMergingEditKeepsARunOfUnavailableModulesInOrder() {
        let stored = PageLayoutConfig(
            ratio: .equal,
            columns: [
                [
                    .status,
                    .quotaGroup(tool: .codex, groupKey: "weekly"),
                    .quotaGroup(tool: .claude, groupKey: "weekly"),
                    .costAll
                ],
                []
            ]
        )
        let available: [PageLayoutModuleID] = [.status, .costAll]
        let edited = PageLayoutConfig(ratio: .equal, columns: [[.costAll, .status], []])

        let merged = PageLayoutResolver.mergingEdit(edited, into: stored, available: available)

        XCTAssertEqual(
            merged.leftColumn,
            [
                .costAll,
                .status,
                .quotaGroup(tool: .codex, groupKey: "weekly"),
                .quotaGroup(tool: .claude, groupKey: "weekly")
            ]
        )
    }

    func testMergingEditPutsAnUnavailableModuleFirstWhenItHadNoVisiblePredecessor() {
        let stored = PageLayoutConfig(
            ratio: .equal,
            columns: [[.quotaHistoryAll, .status], []]
        )
        let edited = PageLayoutConfig(ratio: .equal, columns: [[.status], []])

        let merged = PageLayoutResolver.mergingEdit(
            edited,
            into: stored,
            available: [.status]
        )

        XCTAssertEqual(merged.leftColumn, [.quotaHistoryAll, .status])
    }

    func testMergingEditKeepsTheSavedColumnWhenTheAnchorMovedAway() {
        let stored = PageLayoutConfig(
            ratio: .equal,
            columns: [[.status, .quotaHistoryAll], [.costAll]]
        )
        // `status` — the only saved neighbour of the hidden card — moved to the
        // right column. The hidden card stays put rather than following it.
        let edited = PageLayoutConfig(ratio: .equal, columns: [[], [.costAll, .status]])

        let merged = PageLayoutResolver.mergingEdit(
            edited,
            into: stored,
            available: [.status, .costAll]
        )

        XCTAssertEqual(merged.leftColumn, [.quotaHistoryAll])
        XCTAssertEqual(merged.rightColumn, [.costAll, .status])
    }

    func testMergingEditTakesTheRatioFromTheEdit() {
        let stored = PageLayoutConfig(
            ratio: .equal,
            columns: [[.status, .quotaHistoryAll], []]
        )
        let edited = PageLayoutConfig(ratio: .wideNarrow, columns: [[.status], []])

        let merged = PageLayoutResolver.mergingEdit(
            edited,
            into: stored,
            available: [.status]
        )

        XCTAssertEqual(merged.ratio, .wideNarrow)
        XCTAssertEqual(merged.leftColumn, [.status, .quotaHistoryAll])
    }

    func testMergingEditSurvivesRepeatedEditsWhileAModuleStaysUnavailable() {
        // The regression this guards: every drag used to persist the resolved
        // layout, so the second drag would have already forgotten the hidden
        // card dropped by the first.
        var stored = PageLayoutConfig(
            ratio: .equal,
            columns: [[.status, .quotaHistoryAll], [.costAll]]
        )
        let available: [PageLayoutModuleID] = [.status, .costAll]

        for _ in 0..<3 {
            let resolved = PageLayoutResolver.resolve(
                configured: stored,
                available: available,
                defaultConfig: defaultConfig
            )
            let moved = resolved.moving(.costAll, toColumn: 0, at: 0)
            stored = PageLayoutResolver.mergingEdit(moved, into: stored, available: available)
        }

        XCTAssertTrue(stored.moduleIDs.contains(.quotaHistoryAll))
        XCTAssertEqual(stored.leftColumn, [.costAll, .status, .quotaHistoryAll])
        XCTAssertEqual(stored.rightColumn, [])
    }

    func testMergingEditMergesMeasuredHeightsWithTheEditWinning() {
        let stored = PageLayoutConfig(
            ratio: .equal,
            columns: [[.status, .quotaHistoryAll], []],
            measuredHeights: [.status: 120, .quotaHistoryAll: 300]
        )
        let edited = PageLayoutConfig(
            ratio: .equal,
            columns: [[.status], []],
            measuredHeights: [.status: 140]
        )

        let merged = PageLayoutResolver.mergingEdit(
            edited,
            into: stored,
            available: [.status]
        )

        XCTAssertEqual(merged.measuredHeight(for: .status), 140)
        // A card that is not on screen keeps the height it last reported, so
        // the editor can still draw it to scale.
        XCTAssertEqual(merged.measuredHeight(for: .quotaHistoryAll), 300)
    }
}
