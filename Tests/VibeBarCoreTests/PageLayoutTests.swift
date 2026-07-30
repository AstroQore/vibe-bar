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

    // MARK: - PageLayoutMode

    func testLayoutModeRoundTripsAndFallsBackForUnknownValues() throws {
        for mode in PageLayoutMode.allCases {
            let data = try JSONEncoder().encode([mode])
            XCTAssertEqual(try JSONDecoder().decode([PageLayoutMode].self, from: data), [mode])
        }

        let unknown = Data(#"["telepathic"]"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode([PageLayoutMode].self, from: unknown), [.auto])
    }

    func testOnlyManualIsNotComputed() {
        XCTAssertTrue(PageLayoutMode.auto.isComputed)
        XCTAssertTrue(PageLayoutMode.compact.isComputed)
        XCTAssertFalse(PageLayoutMode.manual.isComputed)
    }

    // MARK: - StoredPageLayout modes

    func testStoredLayoutDerivesItsModeFromItsColumnsWhenUnspecified() {
        // An entry that carries an arrangement is one somebody arranged.
        let arranged = StoredPageLayout(ratio: .equal, columns: [[.status], [.costAll]])
        XCTAssertEqual(arranged.mode, .manual)

        // An entry that carries none is a page still drawing itself.
        XCTAssertEqual(StoredPageLayout().mode, .auto)
        XCTAssertEqual(StoredPageLayout(ratio: .wideNarrow).mode, .auto)
    }

    func testStoredLayoutHonoursAnExplicitModeOverTheDerivedOne() {
        let compact = StoredPageLayout(mode: .compact, ratio: .equal, columns: [[.status], []])
        XCTAssertEqual(compact.mode, .compact)
        // The columns survive: switching modes is not a reset.
        XCTAssertEqual(compact.columns.first, [.status])

        let auto = StoredPageLayout(mode: .auto, ratio: .equal, columns: [[.status], [.costAll]])
        XCTAssertEqual(auto.mode, .auto)
        XCTAssertFalse(auto.isEmpty)

        let manual = StoredPageLayout(mode: .manual)
        XCTAssertEqual(manual.mode, .manual)
        XCTAssertTrue(manual.isEmpty)
    }

    func testStoredLayoutFromAConfigTakesTheGivenMode() {
        let config = PageLayoutConfig(
            ratio: .narrowWide,
            columns: [[.status], [.costAll]],
            measuredHeights: [.status: 140]
        )

        XCTAssertEqual(StoredPageLayout(config).mode, .manual)
        XCTAssertEqual(StoredPageLayout(config, mode: .compact).mode, .compact)
        // Measurement never rides along into settings.
        XCTAssertEqual(StoredPageLayout(config, mode: .compact).columns, [[.status], [.costAll]])
    }

    func testLegacyStoredLayoutWithoutAModeDecodesByItsColumns() throws {
        // Every entry written before modes existed is an arrangement the user
        // dragged, so it has to come back as `manual` — decoding it as `auto`
        // would silently discard their layout on first launch.
        let arranged = Data(#"{"ratio":"wide-narrow","columns":[["status"],["cost-all"]]}"#.utf8)
        let decodedArranged = try JSONDecoder().decode(StoredPageLayout.self, from: arranged)
        XCTAssertEqual(decodedArranged.mode, .manual)
        XCTAssertEqual(decodedArranged.ratio, .wideNarrow)
        XCTAssertEqual(decodedArranged.columns, [[.status], [.costAll]])

        // A heights-only entry carried no arrangement and stays automatic.
        let bare = Data(#"{"ratio":"equal","columns":[[],[]]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(StoredPageLayout.self, from: bare).mode, .auto)
    }

    func testStoredLayoutWithAnUnknownModeFallsBackToAuto() throws {
        // A PRESENT but unrecognized mode is a newer build's setting, not a
        // pre-modes entry — after a downgrade the page should fall back to
        // automatic rather than surprise-activate a fixed manual layout. The
        // columns survive untouched for when the newer build returns.
        let json = Data(#"{"mode":"telepathic","ratio":"equal","columns":[["status"],[]]}"#.utf8)
        let decoded = try JSONDecoder().decode(StoredPageLayout.self, from: json)

        XCTAssertEqual(decoded.mode, PageLayoutMode.fallback)
        XCTAssertEqual(decoded.mode, .auto)
        XCTAssertEqual(decoded.columns.first, [.status])
    }

    func testStoredLayoutRoundTripsEveryModeIncludingAutoWithColumns() throws {
        for mode in PageLayoutMode.allCases {
            let stored = StoredPageLayout(
                mode: mode,
                ratio: .narrowWide,
                columns: [[.status], [.costAll, .quotaHistoryAll]]
            )
            let decoded = try JSONDecoder().decode(
                StoredPageLayout.self,
                from: try JSONEncoder().encode(stored)
            )

            XCTAssertEqual(decoded.mode, mode)
            XCTAssertEqual(decoded.ratio, .narrowWide)
            XCTAssertEqual(decoded.columns, [[.status], [.costAll, .quotaHistoryAll]])
        }
    }

    func testStoredLayoutEncodesTheModeAsAPlainString() throws {
        let stored = StoredPageLayout(mode: .compact, ratio: .equal, columns: [[.status], []])
        let data = try JSONEncoder().encode(stored)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["mode"] as? String, "compact")
    }

    // MARK: - Returning to Manual

    func testReturningToManualRestoresTheSavedArrangement() {
        // The round trip that must not lose work: arrange by hand, switch to a
        // computed mode, switch back. The columns kept through `compact` are
        // the ones that come back — not whatever the packer was showing.
        let arranged = StoredPageLayout(
            mode: .manual,
            ratio: .wideNarrow,
            columns: [[.costAll], [.status, .quotaHistoryAll]]
        )
        let parked = StoredPageLayout(
            mode: .compact,
            ratio: arranged.ratio,
            columns: arranged.columns
        )

        let restored = parked.restoredAsManual()

        XCTAssertEqual(restored?.mode, .manual)
        XCTAssertEqual(restored?.ratio, .wideNarrow)
        XCTAssertEqual(restored?.columns, [[.costAll], [.status, .quotaHistoryAll]])
    }

    func testReturningToManualRestoresFromAutoToo() {
        let parked = StoredPageLayout(
            mode: .auto,
            ratio: .narrowWide,
            columns: [[.status], [.costAll]]
        )

        XCTAssertEqual(parked.restoredAsManual()?.columns, [[.status], [.costAll]])
        XCTAssertEqual(parked.restoredAsManual()?.ratio, .narrowWide)
    }

    func testAPageWithNoHandArrangementHasNothingToRestore() {
        // Nil is the caller's signal to materialize what is on screen, which is
        // the right starting point for a first-time edit.
        XCTAssertNil(StoredPageLayout().restoredAsManual())
        XCTAssertNil(StoredPageLayout(mode: .compact, ratio: .equal).restoredAsManual())
        XCTAssertNil(StoredPageLayout(mode: .auto, ratio: .wideNarrow, columns: [[], []]).restoredAsManual())
    }

    func testRestoringAsManualIsIdempotent() {
        let manual = StoredPageLayout(mode: .manual, ratio: .equal, columns: [[.status], [.costAll]])

        XCTAssertEqual(manual.restoredAsManual(), manual)
        XCTAssertEqual(manual.restoredAsManual()?.restoredAsManual(), manual)
    }

    // MARK: - StoredPageLayoutPreset

    func testPresetMatchingIsCaseInsensitiveAndTrimmed() {
        let presets = [
            StoredPageLayoutPreset(name: "Tall left", layout: StoredPageLayout()),
            StoredPageLayoutPreset(name: "Shortest", layout: StoredPageLayout())
        ]

        XCTAssertEqual(StoredPageLayoutPreset.index(of: "Tall left", in: presets), 0)
        XCTAssertEqual(StoredPageLayoutPreset.index(of: "TALL LEFT", in: presets), 0)
        XCTAssertEqual(StoredPageLayoutPreset.index(of: "  shortest  ", in: presets), 1)
        // A new name is what costs a slot against the per-page cap.
        XCTAssertNil(StoredPageLayoutPreset.index(of: "Widest", in: presets))
        XCTAssertNil(StoredPageLayoutPreset.index(of: "   ", in: presets))
        XCTAssertNil(StoredPageLayoutPreset.index(of: "Tall left", in: []))
    }

    func testPresetMatchingUsesTheSameRuleAsTheSettingsDedupe() {
        // One rule, so saving, deleting and the settings normalizer cannot
        // disagree about which presets are "the same".
        let presets = [StoredPageLayoutPreset(name: "Keep", layout: StoredPageLayout())]
        let duplicate = StoredPageLayoutPreset(name: "  keep  ", layout: StoredPageLayout())

        XCTAssertEqual(duplicate.matchKey, presets[0].matchKey)
        XCTAssertNotNil(StoredPageLayoutPreset.index(of: duplicate.name, in: presets))
    }

    func testPresetTrimsAndCapsItsName() {
        XCTAssertEqual(
            StoredPageLayoutPreset(name: "  Cost on the left  ", layout: StoredPageLayout()).name,
            "Cost on the left"
        )
        let long = String(repeating: "x", count: StoredPageLayoutPreset.maximumNameLength + 40)
        XCTAssertEqual(
            StoredPageLayoutPreset(name: long, layout: StoredPageLayout()).name.count,
            StoredPageLayoutPreset.maximumNameLength
        )
    }

    func testAPresetWithNoUsableNameIsInvalid() {
        XCTAssertFalse(StoredPageLayoutPreset(name: "   ", layout: StoredPageLayout()).isValid)
        XCTAssertFalse(StoredPageLayoutPreset(name: "", layout: StoredPageLayout()).isValid)
        XCTAssertTrue(StoredPageLayoutPreset(name: "Tall left", layout: StoredPageLayout()).isValid)
    }

    func testPresetRoundTripsItsWholeLayout() throws {
        let preset = StoredPageLayoutPreset(
            name: "Cost first",
            layout: StoredPageLayout(
                mode: .compact,
                ratio: .wideNarrow,
                columns: [[.costAll], [.status, .quotaHistoryAll]]
            )
        )

        let decoded = try JSONDecoder().decode(
            StoredPageLayoutPreset.self,
            from: try JSONEncoder().encode(preset)
        )

        XCTAssertEqual(decoded.name, "Cost first")
        XCTAssertEqual(decoded.layout.mode, .compact)
        XCTAssertEqual(decoded.layout.ratio, .wideNarrow)
        XCTAssertEqual(decoded.layout.columns, [[.costAll], [.status, .quotaHistoryAll]])
    }

    func testPresetDecodeToleratesMissingAndMalformedFields() throws {
        // A nameless preset decodes, then fails `isValid` so the settings
        // normalizer can drop it rather than showing a blank menu row.
        let nameless = try JSONDecoder().decode(
            StoredPageLayoutPreset.self,
            from: Data(#"{"layout":{"mode":"manual","columns":[["status"],[]]}}"#.utf8)
        )
        XCTAssertFalse(nameless.isValid)
        XCTAssertEqual(nameless.layout.columns.first, [.status])

        // A mangled layout costs the arrangement, not the whole preset list.
        let mangled = try JSONDecoder().decode(
            StoredPageLayoutPreset.self,
            from: Data(#"{"name":"Broken","layout":"not-an-object"}"#.utf8)
        )
        XCTAssertTrue(mangled.isValid)
        XCTAssertTrue(mangled.layout.isEmpty)
        XCTAssertEqual(mangled.layout.mode, .auto)
    }

    // MARK: - Stored segments

    func testStoredLayoutRoundTripsItsSegments() throws {
        let stored = StoredPageLayout(
            mode: .compact,
            ratio: .wideNarrow,
            columns: [[.status], [.costAll]],
            segments: [[.status], [.costAll, .quotaHistoryAll]]
        )

        let decoded = try JSONDecoder().decode(
            StoredPageLayout.self,
            from: try JSONEncoder().encode(stored)
        )

        XCTAssertEqual(decoded.mode, .compact)
        XCTAssertEqual(decoded.columns, [[.status], [.costAll]])
        XCTAssertEqual(decoded.segments, [[.status], [.costAll, .quotaHistoryAll]])
    }

    func testStoredLayoutEncodesSegmentsAsArraysOfIdentifierStrings() throws {
        let stored = StoredPageLayout(
            mode: .compact,
            segments: [[.status], [.costAll, .quotaHistoryAll]]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(stored)) as? [String: Any]
        )

        XCTAssertEqual(
            object["segments"] as? [[String]],
            [["status"], ["cost-all", "quota-history-all"]]
        )
    }

    func testStoredLayoutWithoutSegmentsDecodesToNoChosenSegmentation() throws {
        // Every entry written before segments existed: the page falls back to
        // its default banding, which is what it was already doing.
        let legacy = Data(#"{"mode":"compact","ratio":"equal","columns":[["status"],[]]}"#.utf8)
        let decoded = try JSONDecoder().decode(StoredPageLayout.self, from: legacy)

        XCTAssertEqual(decoded.segments, [])
        XCTAssertEqual(decoded.mode, .compact)
        XCTAssertEqual(decoded.columns.first, [.status])
    }

    func testMalformedSegmentsCostTheSegmentationAndNothingElse() throws {
        let mangled = Data(#"{"mode":"compact","columns":[["status"],[]],"segments":"nope"}"#.utf8)
        let decoded = try JSONDecoder().decode(StoredPageLayout.self, from: mangled)

        XCTAssertEqual(decoded.segments, [])
        XCTAssertEqual(decoded.columns.first, [.status])
    }

    func testStoredSegmentsAreNormalizedOnTheWayIn() {
        // A duplicate across bands would render one card twice; an empty band
        // would draw a header with nothing under it.
        let stored = StoredPageLayout(
            mode: .compact,
            segments: [[.status, .costAll], [], [.costAll, .quotaHistoryAll], [PageLayoutModuleID("")]]
        )

        XCTAssertEqual(stored.segments, [[.status, .costAll], [.quotaHistoryAll]])
    }

    func testAnEntryCanCarrySegmentsAndStillCountAsUncustomized() {
        // `isEmpty` asks "is there a hand arrangement to go back to". A banding
        // is an input to Compact, not a hand arrangement.
        let stored = StoredPageLayout(mode: .compact, segments: [[.status], [.costAll]])

        XCTAssertTrue(stored.isEmpty)
        XCTAssertNil(stored.restoredAsManual())
    }

    func testReturningToManualKeepsTheSegmentation() {
        let parked = StoredPageLayout(
            mode: .compact,
            ratio: .wideNarrow,
            columns: [[.costAll], [.status]],
            segments: [[.status], [.costAll]]
        )

        let restored = parked.restoredAsManual()

        XCTAssertEqual(restored?.mode, .manual)
        XCTAssertEqual(restored?.segments, [[.status], [.costAll]])
    }

    func testPresetCarriesTheSegmentationItWasCapturedFrom() throws {
        let preset = StoredPageLayoutPreset(
            name: "Quotas first",
            layout: StoredPageLayout(
                mode: .compact,
                ratio: .equal,
                segments: [[.status], [.costAll, .quotaHistoryAll]]
            )
        )

        let decoded = try JSONDecoder().decode(
            StoredPageLayoutPreset.self,
            from: try JSONEncoder().encode(preset)
        )

        // The mode rides along too: applying a Compact preset has to put the
        // page back into Compact, not freeze one packing of it as Manual.
        XCTAssertEqual(decoded.layout.mode, .compact)
        XCTAssertEqual(decoded.layout.segments, [[.status], [.costAll, .quotaHistoryAll]])
    }

    // MARK: - PageLayoutSegments

    private static let summaryCost = PageLayoutModuleID("overview-summary-cost")
    private static let summaryStatus = PageLayoutModuleID("overview-summary-status")

    /// The Overview's module set, in catalog declaration order, with the phases
    /// `PageModuleCatalog` gives them.
    private func overviewModules() -> [PageLayoutSegments.Module] {
        [
            .init(id: Self.summaryCost, phase: .summary),
            .init(id: Self.summaryStatus, phase: .summary),
            .init(id: PageLayoutModuleID("overview-quota:codex"), phase: .quota),
            .init(id: PageLayoutModuleID("overview-quota:claude"), phase: .quota),
            .init(id: PageLayoutModuleID("overview-quota:gemini"), phase: .quota),
            .init(id: PageLayoutModuleID("overview-quota:grok"), phase: .quota),
            .init(id: .quotaHistoryAll, phase: .quota),
            .init(id: .costAll, phase: .cost),
            .init(id: .cost(tool: .codex), phase: .cost),
            .init(id: PageLayoutModuleID("model-breakdown:all"), phase: .auxiliary),
            .init(id: PageLayoutModuleID("heatmap-year:all"), phase: .auxiliary)
        ]
    }

    func testOverviewDefaultsToSummaryThenQuotaThenEverythingElse() {
        let segments = PageLayoutSegments.defaultSegments(
            modules: overviewModules(),
            page: .overview
        )

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0], [Self.summaryCost, Self.summaryStatus])
        XCTAssertEqual(
            segments[1],
            [
                PageLayoutModuleID("overview-quota:codex"),
                PageLayoutModuleID("overview-quota:claude"),
                PageLayoutModuleID("overview-quota:gemini"),
                PageLayoutModuleID("overview-quota:grok"),
                .quotaHistoryAll
            ]
        )
        // Cost and the analytics derived from it read as one block.
        XCTAssertEqual(
            segments[2],
            [
                .costAll,
                .cost(tool: .codex),
                PageLayoutModuleID("model-breakdown:all"),
                PageLayoutModuleID("heatmap-year:all")
            ]
        )
    }

    func testAProviderPageDefaultsToASingleSegment() {
        // `compact` on a provider page keeps meaning exactly what it meant
        // before segments existed: one packing of the whole page.
        let modules: [PageLayoutSegments.Module] = [
            .init(id: .quotaGroup(tool: .claude, groupKey: "five_hour"), phase: .quota),
            .init(id: .status, phase: .quota),
            .init(id: .cost(tool: .claude), phase: .cost),
            .init(id: .modelBreakdown(tool: .claude), phase: .auxiliary)
        ]

        let segments = PageLayoutSegments.defaultSegments(modules: modules, page: .detail(.claude))

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].count, 4)
    }

    func testEmptyPhasesDoNotProduceEmptySegments() {
        // A page with no cost data at all is two bands, not three with a hole.
        let segments = PageLayoutSegments.defaultSegments(
            modules: [
                .init(id: Self.summaryCost, phase: .summary),
                .init(id: .quotaHistoryAll, phase: .quota)
            ],
            page: .overview
        )

        XCTAssertEqual(segments, [[Self.summaryCost], [.quotaHistoryAll]])
    }

    func testSegmentNormalizationFoldsBandsPastTheCapIntoTheLast() {
        let overflowing = (0..<(PageLayoutSegments.maximumCount + 2)).map {
            [PageLayoutModuleID("card-\($0)")]
        }

        let normalized = PageLayoutSegments.normalized(overflowing)

        XCTAssertEqual(normalized.count, PageLayoutSegments.maximumCount)
        // Folding rather than dropping: no card is lost to the cap.
        XCTAssertEqual(normalized.flatMap { $0 }.count, PageLayoutSegments.maximumCount + 2)
        XCTAssertEqual(
            normalized[PageLayoutSegments.maximumCount - 1],
            [
                PageLayoutModuleID("card-\(PageLayoutSegments.maximumCount - 1)"),
                PageLayoutModuleID("card-\(PageLayoutSegments.maximumCount)"),
                PageLayoutModuleID("card-\(PageLayoutSegments.maximumCount + 1)")
            ]
        )
    }

    func testSegmentNormalizationKeepsIdentifiersThisBuildDoesNotKnow() {
        let future = PageLayoutModuleID("overview-something-new:v3")

        XCTAssertEqual(
            PageLayoutSegments.normalized([[future], [.status]]),
            [[future], [.status]]
        )
    }

    func testResolvingWithoutStoredSegmentsUsesThePageDefault() {
        let modules = overviewModules()
        let defaults = PageLayoutSegments.defaultSegments(modules: modules, page: .overview)

        let resolved = PageLayoutSegments.resolve(
            stored: [],
            available: modules.map(\.id),
            defaultSegments: defaults
        )

        XCTAssertEqual(resolved, defaults)
    }

    func testResolvingDropsModulesThePageCannotDrawAndTheirEmptyBands() {
        let resolved = PageLayoutSegments.resolve(
            stored: [[.status], [.costAll], [.quotaHistoryAll]],
            available: [.status, .quotaHistoryAll],
            defaultSegments: [[.status], [.quotaHistoryAll]]
        )

        XCTAssertEqual(resolved, [[.status], [.quotaHistoryAll]])
    }

    func testANewModuleJoinsTheBandItsFamilyDefaultsTo() {
        // The case that matters in practice: a build adds a card, or a provider
        // is switched back on, while the user has a saved banding.
        let resolved = PageLayoutSegments.resolve(
            stored: [[Self.summaryCost], [.quotaHistoryAll], [.costAll]],
            available: [Self.summaryCost, Self.summaryStatus, .quotaHistoryAll, .costAll],
            defaultSegments: [
                [Self.summaryCost, Self.summaryStatus],
                [.quotaHistoryAll],
                [.costAll]
            ]
        )

        XCTAssertEqual(resolved[0], [Self.summaryCost, Self.summaryStatus])
        XCTAssertEqual(resolved[1], [.quotaHistoryAll])
        XCTAssertEqual(resolved[2], [.costAll])
    }

    func testANewModuleWithNowhereToGoLandsInTheLastBand() {
        // A page saved with fewer bands than the default has no band for the
        // newcomer's family; visible at the end beats silently missing.
        let resolved = PageLayoutSegments.resolve(
            stored: [[Self.summaryCost, Self.summaryStatus]],
            available: [Self.summaryCost, Self.summaryStatus, .costAll],
            defaultSegments: [[Self.summaryCost, Self.summaryStatus], [.quotaHistoryAll], [.costAll]]
        )

        XCTAssertEqual(resolved, [[Self.summaryCost, Self.summaryStatus, .costAll]])
    }

    func testResolvingPlacesEveryAvailableModuleExactlyOnce() {
        let modules = overviewModules()
        let resolved = PageLayoutSegments.resolve(
            // A hand-edited file: duplicated, unknown and missing entries.
            stored: [[.costAll, .costAll], [PageLayoutModuleID("gone:forever")]],
            available: modules.map(\.id),
            defaultSegments: PageLayoutSegments.defaultSegments(modules: modules, page: .overview)
        )

        let placed = resolved.flatMap { $0 }
        XCTAssertEqual(Set(placed), Set(modules.map(\.id)))
        XCTAssertEqual(placed.count, modules.count)
    }

    func testMergingAnEditKeepsBandsForModulesThatAreNotOnScreen() {
        // The quota card of a provider that is mid-refresh must not lose its
        // band because the user dragged something else.
        let merged = PageLayoutSegments.mergingEdit(
            [[.status], [.costAll]],
            into: [[.status, .quotaHistoryAll], [.costAll]],
            available: [.status, .costAll]
        )

        XCTAssertEqual(merged, [[.status, .quotaHistoryAll], [.costAll]])
    }

    func testMergingAnEditHonoursTheMoveItWasGiven() {
        let merged = PageLayoutSegments.mergingEdit(
            [[.status, .costAll], [.quotaHistoryAll]],
            into: [[.status], [.costAll, .quotaHistoryAll]],
            available: [.status, .costAll, .quotaHistoryAll]
        )

        XCTAssertEqual(merged, [[.status, .costAll], [.quotaHistoryAll]])
    }

    // MARK: - Compact, end to end

    func testCompactOverviewPacksTheQuotaCardsAsTheirOwnBand() {
        // The user's actual complaint: on a packed Overview the quota cards must
        // form one minimal-height block, with the summary above them and
        // everything else below — no stored segmentation required.
        //
        // This is the pipeline `PageLayoutModel.compactArrangement` runs:
        // default banding from the catalog's phases, then one packing per band.
        let modules = overviewModules()
        let heights: [PageLayoutModuleID: Double] = [
            Self.summaryCost: 178,
            Self.summaryStatus: 178,
            PageLayoutModuleID("overview-quota:codex"): 300,
            PageLayoutModuleID("overview-quota:claude"): 260,
            PageLayoutModuleID("overview-quota:gemini"): 220,
            PageLayoutModuleID("overview-quota:grok"): 180,
            .quotaHistoryAll: 300,
            .costAll: 340,
            .cost(tool: .codex): 320,
            PageLayoutModuleID("model-breakdown:all"): 200,
            PageLayoutModuleID("heatmap-year:all"): 210
        ]
        let segments = PageLayoutSegments.defaultSegments(modules: modules, page: .overview)

        let packed = PageLayoutPacker.packedSegmentColumns(
            segments: segments.map { band in
                band.map { PageLayoutPacker.Item(id: $0, height: heights[$0] ?? 0) }
            },
            spacing: 12
        )

        XCTAssertEqual(packed.count, 3)
        XCTAssertEqual(Set(packed[0].flatMap { $0 }), [Self.summaryCost, Self.summaryStatus])
        XCTAssertEqual(
            Set(packed[1].flatMap { $0 }),
            Set([
                PageLayoutModuleID("overview-quota:codex"),
                PageLayoutModuleID("overview-quota:claude"),
                PageLayoutModuleID("overview-quota:gemini"),
                PageLayoutModuleID("overview-quota:grok"),
                .quotaHistoryAll
            ])
        )
        // Nothing from below leaks into the quota band, which is exactly what
        // the unsegmented packer was free to do.
        XCTAssertEqual(
            Set(packed[2].flatMap { $0 }),
            Set([
                .costAll,
                .cost(tool: .codex),
                PageLayoutModuleID("model-breakdown:all"),
                PageLayoutModuleID("heatmap-year:all")
            ])
        )
        // The summary band is one row: one card per column.
        XCTAssertEqual(packed[0][0].count, 1)
        XCTAssertEqual(packed[0][1].count, 1)
        // And each band is genuinely balanced, not just grouped.
        let quotaColumns = packed[1].map {
            PageLayoutPacker.stackedHeight($0, heights: heights, spacing: 12)
        }
        XCTAssertLessThan(abs(quotaColumns[0] - quotaColumns[1]), 100)
    }
}
