import XCTest
@testable import VibeBarCore

/// The one-time repair that moves a card whose *default* position changed.
///
/// The stakes are asymmetric: failing to migrate leaves a card where an old
/// release put it, which is a cosmetic disappointment; migrating too eagerly
/// rearranges a page somebody built by hand, which is data loss they cannot
/// undo. Every test here is about the second.
final class PageLayoutDefaultsMigrationTests: XCTestCase {
    private let page = PageLayoutPageID.detail(.grok)
    private let resetHistory = PageLayoutModuleID(rawValue: "reset-history-compare:grok")

    /// Exactly what 1.6.1 materialized for a SpaceXAI page: status closing the
    /// narrow column, the reset table opening the wide one.
    private func previousDefault() -> StoredPageLayout {
        StoredPageLayout(
            mode: .manual,
            ratio: .narrowWide,
            columns: [
                [PageLayoutModuleID(rawValue: "quota-group:grok:weekly"), .status],
                [
                    resetHistory,
                    .cost(tool: .grok),
                    PageLayoutModuleID(rawValue: "cost-history:grok"),
                    .modelBreakdown(tool: .grok),
                    PageLayoutModuleID(rawValue: "heatmap-year:grok"),
                    PageLayoutModuleID(rawValue: "heatmap-activity:grok")
                ]
            ]
        )
    }

    // MARK: - The move

    func testALayoutStillHoldingTheOldDefaultIsMovedToTheNewOne() {
        let migrated = PageLayoutDefaultsMigration.migratedProviderRightColumn([page: previousDefault()])
        let layout = try? XCTUnwrap(migrated[page])
        XCTAssertEqual(layout?.columns[0], [PageLayoutModuleID(rawValue: "quota-group:grok:weekly")])
        XCTAssertEqual(
            layout?.columns[1],
            [
                .cost(tool: .grok),
                PageLayoutModuleID(rawValue: "cost-history:grok"),
                .modelBreakdown(tool: .grok),
                resetHistory,
                PageLayoutModuleID(rawValue: "heatmap-year:grok"),
                PageLayoutModuleID(rawValue: "heatmap-activity:grok"),
                .status
            ]
        )
    }

    func testTheRestOfTheSavedIntentSurvivesTheMove() {
        // Mode and hidden cards ride through: switching a page to Compact does
        // not move a card, and hiding one says where nothing should go rather
        // than where anything sits.
        let before = StoredPageLayout(
            mode: .compact,
            ratio: .narrowWide,
            columns: previousDefault().columns,
            hidden: [PageLayoutModuleID(rawValue: "heatmap-year:grok")]
        )
        let after = try? XCTUnwrap(
            PageLayoutDefaultsMigration.migratedProviderRightColumn([page: before])[page]
        )
        XCTAssertEqual(after?.columns[0].last, PageLayoutModuleID(rawValue: "quota-group:grok:weekly"))
        XCTAssertEqual(after?.columns[1].last, .status)
        XCTAssertEqual(after?.mode, .compact)
        XCTAssertEqual(after?.ratio, .narrowWide)
        XCTAssertEqual(after?.hidden, [PageLayoutModuleID(rawValue: "heatmap-year:grok")])
    }

    func testAPageCombiningTwoSubProvidersQuotaGroupsStillMatches() {
        // The Google AI page's left column carries AntiGravity's groups beside
        // Gemini Web's, so the check cannot pin the quota groups to the page's
        // own tool.
        let gemini = PageLayoutPageID.detail(.gemini)
        let layout = StoredPageLayout(
            mode: .manual,
            ratio: .narrowWide,
            columns: [
                [
                    PageLayoutModuleID(rawValue: "quota-group:gemini:weekly"),
                    PageLayoutModuleID(rawValue: "quota-group:antigravity:gemini_weekly"),
                    .status
                ],
                [PageLayoutModuleID(rawValue: "reset-history-compare:gemini")]
                    + PageLayoutDefaultsMigration.previousCostTail(.gemini)
            ]
        )
        let after = try? XCTUnwrap(
            PageLayoutDefaultsMigration.migratedProviderRightColumn([gemini: layout])[gemini]
        )
        XCTAssertEqual(after?.columns[0].count, 2)
        XCTAssertEqual(after?.columns[1].last, .status)
    }

    func testAPageWithNoModelRankingPutsTheTableAtTheEnd() {
        // No cost data means no ranking to sit under, so the table takes the
        // last analytics slot and status still closes the column.
        let layout = StoredPageLayout(
            mode: .manual,
            ratio: .narrowWide,
            columns: [
                [PageLayoutModuleID(rawValue: "quota-group:grok:weekly"), .status],
                [resetHistory, PageLayoutModuleID(rawValue: "cost-empty:grok")]
            ]
        )
        let after = try? XCTUnwrap(
            PageLayoutDefaultsMigration.migratedProviderRightColumn([page: layout])[page]
        )
        XCTAssertEqual(
            after?.columns[1],
            [PageLayoutModuleID(rawValue: "cost-empty:grok"), resetHistory, .status]
        )
    }

    // MARK: - What it refuses to touch

    func testALayoutWhoseStatusWasMovedIsLeftAlone() {
        // Status pulled to the top of the left column is somebody's decision.
        var columns = previousDefault().columns
        columns[0] = [.status, PageLayoutModuleID(rawValue: "quota-group:grok:weekly")]
        let arranged = StoredPageLayout(mode: .manual, ratio: .narrowWide, columns: columns)
        XCTAssertEqual(
            PageLayoutDefaultsMigration.migratedProviderRightColumn([page: arranged])[page],
            arranged
        )
    }

    func testALayoutWhoseResetTableWasMovedIsLeftAlone() {
        var columns = previousDefault().columns
        columns[1] = [.cost(tool: .grok), resetHistory]
        let arranged = StoredPageLayout(mode: .manual, ratio: .narrowWide, columns: columns)
        XCTAssertEqual(
            PageLayoutDefaultsMigration.migratedProviderRightColumn([page: arranged])[page],
            arranged
        )
    }

    func testAnUnrelatedCardReorderedIsEnoughToLeaveThePageAlone() {
        // Both endpoints are still where 1.6.1 put them — status last on the
        // left, the table first on the right — but the analytics between them
        // were rearranged. Two endpoints prove nothing about the cards in
        // between, which is why the whole arrangement is checked.
        var columns = previousDefault().columns
        columns[1] = [
            resetHistory,
            .cost(tool: .grok),
            PageLayoutModuleID(rawValue: "cost-history:grok"),
            PageLayoutModuleID(rawValue: "heatmap-activity:grok"),   // pulled up
            .modelBreakdown(tool: .grok),
            PageLayoutModuleID(rawValue: "heatmap-year:grok")
        ]
        let arranged = StoredPageLayout(mode: .manual, ratio: .narrowWide, columns: columns)
        XCTAssertEqual(
            PageLayoutDefaultsMigration.migratedProviderRightColumn([page: arranged])[page],
            arranged
        )
    }

    func testAnExtraCardInAColumnIsEnoughToLeaveThePageAlone() {
        var columns = previousDefault().columns
        columns[1].append(PageLayoutModuleID(rawValue: "quota-group:grok:weekly#2"))
        let arranged = StoredPageLayout(mode: .manual, ratio: .narrowWide, columns: columns)
        XCTAssertEqual(
            PageLayoutDefaultsMigration.migratedProviderRightColumn([page: arranged])[page],
            arranged
        )
    }

    func testACardDraggedIntoTheLeftColumnIsEnoughToLeaveThePageAlone() {
        var columns = previousDefault().columns
        columns[0].insert(PageLayoutModuleID(rawValue: "heatmap-year:grok"), at: 0)
        columns[1].removeAll { $0 == PageLayoutModuleID(rawValue: "heatmap-year:grok") }
        let arranged = StoredPageLayout(mode: .manual, ratio: .narrowWide, columns: columns)
        XCTAssertEqual(
            PageLayoutDefaultsMigration.migratedProviderRightColumn([page: arranged])[page],
            arranged
        )
    }

    func testAChosenSegmentationIsEnoughToLeaveThePageAlone() {
        // Grouping a page is an explicit act on it, and the bands would be
        // wrong for the cards after they moved.
        let grouped = StoredPageLayout(
            mode: .manual,
            ratio: .narrowWide,
            columns: previousDefault().columns,
            segments: [[.cost(tool: .grok)], [.status]]
        )
        XCTAssertEqual(
            PageLayoutDefaultsMigration.migratedProviderRightColumn([page: grouped])[page],
            grouped
        )
    }

    func testAChosenWidthSplitIsEnoughToLeaveThePageAlone() {
        // Picking a ratio is one of the things that materializes a layout, so
        // a page whose ratio is not the provider default was taken over.
        let widened = StoredPageLayout(
            mode: .manual,
            ratio: .equal,
            columns: previousDefault().columns
        )
        XCTAssertEqual(
            PageLayoutDefaultsMigration.migratedProviderRightColumn([page: widened])[page],
            widened
        )
    }

    func testALayoutWithNoArrangementIsLeftAlone() {
        // Nothing to repair: `PageLayoutResolver` places a module the config has
        // never seen at its current default, so this page already gets the new
        // one for free.
        let heightsOnly = StoredPageLayout(mode: .auto, ratio: .narrowWide, columns: [])
        XCTAssertEqual(
            PageLayoutDefaultsMigration.migratedProviderRightColumn([page: heightsOnly])[page],
            heightsOnly
        )
    }

    func testTheOverviewIsNeverTouched() {
        let overview = StoredPageLayout(
            mode: .manual,
            ratio: .equal,
            columns: [[.status], [PageLayoutModuleID(rawValue: "overview-reset-history-compare")]]
        )
        let key = PageLayoutPageID.overview
        XCTAssertEqual(
            PageLayoutDefaultsMigration.migratedProviderRightColumn([key: overview])[key],
            overview
        )
    }

    func testAnotherProvidersTableIdDoesNotCountAsThisPagesSignature() {
        // The identifier is per tool; a Claude table sitting on the Grok page
        // would be a layout nobody should be second-guessing.
        var columns = previousDefault().columns
        columns[1][0] = PageLayoutModuleID(rawValue: "reset-history-compare:claude")
        let arranged = StoredPageLayout(mode: .manual, ratio: .narrowWide, columns: columns)
        XCTAssertEqual(
            PageLayoutDefaultsMigration.migratedProviderRightColumn([page: arranged])[page],
            arranged
        )
    }

    // MARK: - Overview history segment

    private let overview = PageLayoutPageID.overview
    private let summaryIDs = [
        PageLayoutModuleID(rawValue: "overview-summary-cost"),
        PageLayoutModuleID(rawValue: "overview-summary-status")
    ]

    /// The three bands the old phase grouping produced.
    private func previousOverviewSegments() -> [[PageLayoutModuleID]] {
        [
            summaryIDs,
            [
                PageLayoutModuleID(rawValue: "overview-quota:codex"),
                PageLayoutModuleID(rawValue: "overview-quota:claude"),
                PageLayoutModuleID(rawValue: "overview-upcoming-resets"),
                PageLayoutModuleID(rawValue: "overview-reset-history-compare"),
                PageLayoutModuleID(rawValue: "overview-usage-mix"),
                .quotaHistoryAll
            ],
            [
                .costAll,
                .cost(tool: .codex),
                .modelBreakdown(tool: .codex),
                PageLayoutModuleID(rawValue: "heatmap-year:all"),
                PageLayoutModuleID(rawValue: "heatmap-activity:all")
            ]
        ]
    }

    func testAnOverviewStillSegmentedTheOldWayIsLetGoOfItsSegmentation() {
        // Clearing means "no chosen segmentation", which is what makes the new
        // four-band default derive. The columns are not touched: the Overview's
        // default arrangement is planner-computed from measured heights, so
        // there is no cross-Mac signature to match there.
        let columns = [[PageLayoutModuleID.quotaHistoryAll], [PageLayoutModuleID.costAll]]
        let layout = StoredPageLayout(
            mode: .compact,
            ratio: .equal,
            columns: columns,
            segments: previousOverviewSegments(),
            hidden: [.costAll]
        )
        let after = try? XCTUnwrap(
            PageLayoutDefaultsMigration.migratedOverviewHistorySegment([overview: layout])[overview]
        )
        XCTAssertEqual(after?.segments, [])
        XCTAssertEqual(after?.columns, columns)
        XCTAssertEqual(after?.mode, .compact)
        XCTAssertEqual(after?.ratio, .equal)
        XCTAssertEqual(after?.hidden, [.costAll])
    }

    func testAnOverviewWithNoStoredSegmentationIsLeftAlone() {
        // It already derives the new default; there is nothing to repair.
        let layout = StoredPageLayout(mode: .compact, ratio: .equal, columns: [[.costAll], []])
        XCTAssertEqual(
            PageLayoutDefaultsMigration.migratedOverviewHistorySegment([overview: layout])[overview],
            layout
        )
    }

    func testAHandGroupedOverviewKeepsItsSegmentation() {
        // The real shape this has to refuse: a segmentation somebody packed by
        // hand, where the all-providers history sits in the cost band rather
        // than the quota one. `PageLayoutSegments.resolve` will re-place the
        // three moved cards by their new phase anyway, so refusing costs the
        // user nothing.
        var segments = previousOverviewSegments()
        segments[1].removeAll {
            [
                PageLayoutModuleID(rawValue: "overview-upcoming-resets"),
                PageLayoutModuleID(rawValue: "overview-reset-history-compare"),
                PageLayoutModuleID(rawValue: "overview-usage-mix"),
                .quotaHistoryAll
            ].contains($0)
        }
        segments[2].append(.quotaHistoryAll)
        let arranged = StoredPageLayout(
            mode: .compact,
            ratio: .equal,
            columns: [[.quotaHistoryAll], [.costAll]],
            segments: segments
        )
        XCTAssertEqual(
            PageLayoutDefaultsMigration.migratedOverviewHistorySegment([overview: arranged])[overview],
            arranged
        )
    }

    func testAnOverviewSegmentedIntoSomethingOtherThanThreeBandsIsLeftAlone() {
        let arranged = StoredPageLayout(
            mode: .manual,
            ratio: .equal,
            columns: [[.costAll], []],
            segments: [summaryIDs, [.quotaHistoryAll]]
        )
        XCTAssertEqual(
            PageLayoutDefaultsMigration.migratedOverviewHistorySegment([overview: arranged])[overview],
            arranged
        )
    }

    func testAnUnrecognizedModuleIsEnoughToLeaveTheOverviewAlone() {
        // A card this table cannot classify may be exactly the one the user
        // placed by hand.
        var segments = previousOverviewSegments()
        segments[1].append(PageLayoutModuleID(rawValue: "overview-something-new"))
        let arranged = StoredPageLayout(
            mode: .compact, ratio: .equal, columns: [[.costAll], []], segments: segments
        )
        XCTAssertEqual(
            PageLayoutDefaultsMigration.migratedOverviewHistorySegment([overview: arranged])[overview],
            arranged
        )
    }

    func testAProviderPageIsNeverTouchedByTheOverviewMigration() {
        let layout = previousDefault()
        XCTAssertEqual(
            PageLayoutDefaultsMigration.migratedOverviewHistorySegment([page: layout])[page],
            layout
        )
    }

    func testThePreviousPhaseTableClassifiesEveryOverviewCardItShipped() {
        typealias Phase = PageLayoutDefaultsMigration.PreviousOverviewPhase
        func phase(_ raw: String) -> Phase? {
            PageLayoutDefaultsMigration.previousOverviewPhase(PageLayoutModuleID(rawValue: raw))
        }
        XCTAssertEqual(phase("overview-summary-cost"), .summary)
        XCTAssertEqual(phase("overview-quota:grok"), .quota)
        // The four that used to ride in the quota band with the provider cards.
        XCTAssertEqual(phase("overview-upcoming-resets"), .quota)
        XCTAssertEqual(phase("overview-reset-history-compare"), .quota)
        XCTAssertEqual(phase("overview-usage-mix"), .quota)
        XCTAssertEqual(phase("quota-history-all"), .quota)
        XCTAssertEqual(phase("cost-all"), .costOrAuxiliary)
        XCTAssertEqual(phase("cost:codex"), .costOrAuxiliary)
        XCTAssertEqual(phase("model-breakdown:all"), .costOrAuxiliary)
        XCTAssertEqual(phase("heatmap-year:all"), .costOrAuxiliary)
        XCTAssertEqual(phase("heatmap-activity:all"), .costOrAuxiliary)
        XCTAssertNil(phase("status"))
        XCTAssertNil(phase("overview-something-new"))
    }

    // MARK: - Once, and only once

    func testMigrateRecordsItsIdentifierAndDoesNothingOnASecondPass() {
        let first = PageLayoutDefaultsMigration.migrate(
            layouts: [page: previousDefault()],
            applied: []
        )
        XCTAssertTrue(
            first.applied.contains(PageLayoutDefaultsMigration.providerRightColumnIdentifier)
        )
        XCTAssertTrue(
            first.applied.contains(PageLayoutDefaultsMigration.overviewHistorySegmentIdentifier)
        )
        XCTAssertEqual(first.layouts[page]?.columns[0].count, 1)

        // The user drags status back to the left column. The next launch must
        // leave that alone rather than "fixing" it again.
        var draggedBack = first.layouts
        draggedBack[page] = StoredPageLayout(
            mode: .manual,
            ratio: .narrowWide,
            columns: [
                [PageLayoutModuleID(rawValue: "quota-group:grok:weekly"), .status],
                first.layouts[page]!.columns[1].filter { $0 != .status }
            ]
        )
        let second = PageLayoutDefaultsMigration.migrate(
            layouts: draggedBack,
            applied: first.applied
        )
        XCTAssertEqual(second.layouts[page], draggedBack[page])
        XCTAssertEqual(second.applied, first.applied)
    }

    func testMigrateRecordsTheIdentifierEvenWhenNothingNeededMoving() {
        // "Has this migration run" is the question, not "did it find
        // anything" — otherwise it re-asks forever.
        let result = PageLayoutDefaultsMigration.migrate(layouts: [:], applied: [])
        XCTAssertEqual(
            result.applied,
            [
                PageLayoutDefaultsMigration.providerRightColumnIdentifier,
                PageLayoutDefaultsMigration.overviewHistorySegmentIdentifier
            ]
        )
        XCTAssertTrue(result.layouts.isEmpty)
    }

    // MARK: - Settings round trip

    func testAppliedMigrationsRoundTripThroughSettings() throws {
        var settings = AppSettings.default
        settings.appliedLayoutMigrations = [
            PageLayoutDefaultsMigration.providerRightColumnIdentifier
        ]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.appliedLayoutMigrations, settings.appliedLayoutMigrations)
    }

    func testTheResetHistoryAxisRoundTripsThroughSettings() throws {
        // A user-facing control, so it round-trips through `AppSettings` like
        // every other one (`AGENTS.md` § 11).
        var settings = AppSettings.default
        settings.resetHistoryCompareAxis = .time
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.resetHistoryCompareAxis, .time)
    }

    func testSettingsWrittenBeforeTheAxisToggleDecodeToCycles() throws {
        // An upgrade must not silently re-lay-out a module the user was
        // reading yesterday.
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.resetHistoryCompareAxis, .cycle)
        XCTAssertEqual(AppSettings.default.resetHistoryCompareAxis, .cycle)
    }

    func testAnUnknownAxisInTheSettingsFileFallsBackToCycles() throws {
        // A value written by a newer build must cost the axis, not the file.
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"resetHistoryCompareAxis":"spiral"}"#.utf8)
        )
        XCTAssertEqual(decoded.resetHistoryCompareAxis, .cycle)
    }

    func testSettingsWrittenBeforeMigrationsExistedDecodeToNoneApplied() throws {
        // Which is what makes the first launch on this build run them.
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.appliedLayoutMigrations.isEmpty)
    }
}
