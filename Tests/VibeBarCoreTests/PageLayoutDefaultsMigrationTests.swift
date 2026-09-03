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

    // MARK: - Once, and only once

    func testMigrateRecordsItsIdentifierAndDoesNothingOnASecondPass() {
        let first = PageLayoutDefaultsMigration.migrate(
            layouts: [page: previousDefault()],
            applied: []
        )
        XCTAssertTrue(
            first.applied.contains(PageLayoutDefaultsMigration.providerRightColumnIdentifier)
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
            [PageLayoutDefaultsMigration.providerRightColumnIdentifier]
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

    func testSettingsWrittenBeforeMigrationsExistedDecodeToNoneApplied() throws {
        // Which is what makes the first launch on this build run them.
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.appliedLayoutMigrations.isEmpty)
    }
}
