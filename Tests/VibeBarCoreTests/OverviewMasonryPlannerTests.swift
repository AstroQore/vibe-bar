import XCTest
@testable import VibeBarCore

final class OverviewMasonryPlannerTests: XCTestCase {
    func testQuotaCardsBalanceBeforeCostCardsAreConsidered() {
        let items: [OverviewMasonryPlanner.Item] = [
            .init(id: "chatgpt", height: 300, phase: .quota),
            .init(id: "claude", height: 280, phase: .quota),
            .init(id: "gemini", height: 120, phase: .quota),
            .init(id: "grok", height: 100, phase: .quota),
            .init(id: "huge-cost", height: 900, phase: .cost)
        ]

        let plan = OverviewMasonryPlanner.plan(items: items, spacing: 12)
        let leftQuota = Set(plan.positions.compactMap { id, position in
            position.column == 0 && id != "huge-cost" ? id : nil
        })
        let rightQuota = Set(plan.positions.compactMap { id, position in
            position.column == 1 && id != "huge-cost" ? id : nil
        })

        XCTAssertEqual(leftQuota.count, 2)
        XCTAssertEqual(rightQuota.count, 2)
        XCTAssertTrue(leftQuota == ["chatgpt", "grok"] || leftQuota == ["claude", "gemini"])
    }

    func testCostAssignmentStartsFromQuotaColumnHeights() {
        let items: [OverviewMasonryPlanner.Item] = [
            .init(id: "q1", height: 300, phase: .quota),
            .init(id: "q2", height: 300, phase: .quota),
            .init(id: "q3", height: 100, phase: .quota),
            .init(id: "q4", height: 100, phase: .quota),
            .init(id: "cost1", height: 220, phase: .cost),
            .init(id: "cost2", height: 180, phase: .cost),
            .init(id: "cost3", height: 140, phase: .cost)
        ]

        let plan = OverviewMasonryPlanner.plan(items: items, spacing: 10)
        XCTAssertLessThan(abs(plan.columnHeights[0] - plan.columnHeights[1]), 200)
    }

    func testAuxiliaryCardsGreedilyFillTheShorterFinishedColumn() {
        let items: [OverviewMasonryPlanner.Item] = [
            .init(id: "q1", height: 200, phase: .quota),
            .init(id: "q2", height: 190, phase: .quota),
            .init(id: "q3", height: 180, phase: .quota),
            .init(id: "q4", height: 170, phase: .quota),
            .init(id: "cost", height: 300, phase: .cost),
            .init(id: "aux1", height: 80, phase: .auxiliary),
            .init(id: "aux2", height: 60, phase: .auxiliary)
        ]

        let plan = OverviewMasonryPlanner.plan(items: items, spacing: 10)
        XCTAssertNotNil(plan.positions["aux1"])
        XCTAssertNotNil(plan.positions["aux2"])
        XCTAssertGreaterThan(plan.positions["aux1"]?.y ?? 0, 0)
    }

    func testFixedColumnsKeepExpandedCostCardOnTheSameSide() throws {
        let collapsed: [OverviewMasonryPlanner.Item] = [
            .init(id: "quota-left", height: 200, phase: .quota),
            .init(id: "quota-right", height: 180, phase: .quota),
            .init(id: "cost-detail", height: 220, phase: .cost),
            .init(id: "cost-following", height: 160, phase: .cost),
            .init(id: "aux", height: 80, phase: .auxiliary)
        ]
        let initial = OverviewMasonryPlanner.plan(items: collapsed, spacing: 10)
        let fixedColumns = initial.positions.mapValues(\.column)
        let expanded = collapsed.map { item in
            item.id == "cost-detail"
                ? .init(id: item.id, height: 420, phase: item.phase)
                : item
        }

        let locked = OverviewMasonryPlanner.plan(
            items: expanded,
            fixedColumns: fixedColumns,
            spacing: 10
        )

        for item in expanded {
            XCTAssertEqual(locked.positions[item.id]?.column, fixedColumns[item.id])
        }
        let detail = try XCTUnwrap(locked.positions["cost-detail"])
        let following = try XCTUnwrap(locked.positions["cost-following"])
        if detail.column == following.column {
            XCTAssertGreaterThan(following.y, detail.y + 420)
        }
    }

    func testTheSummaryBandTakesTheTopRowBeforeAnythingIsBalanced() throws {
        // The Overview's cost and status summaries used to be a hard-coded row
        // above the waterfall. As modules they have to land exactly where that
        // row was: one per column, at the top, whatever the quota cards do.
        let items: [OverviewMasonryPlanner.Item] = [
            .init(id: "summary-cost", height: 178, phase: .summary),
            .init(id: "summary-status", height: 178, phase: .summary),
            .init(id: "q1", height: 300, phase: .quota),
            .init(id: "q2", height: 280, phase: .quota),
            .init(id: "q3", height: 120, phase: .quota),
            .init(id: "q4", height: 100, phase: .quota),
            .init(id: "cost", height: 320, phase: .cost)
        ]

        let plan = OverviewMasonryPlanner.plan(items: items, spacing: 12)

        let cost = try XCTUnwrap(plan.positions["summary-cost"])
        let status = try XCTUnwrap(plan.positions["summary-status"])
        XCTAssertEqual(cost.column, 0)
        XCTAssertEqual(status.column, 1)
        XCTAssertEqual(cost.y, 0)
        XCTAssertEqual(status.y, 0)
        // Everything below starts under the band, in both columns.
        for id in ["q1", "q2", "q3", "q4", "cost"] {
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(plan.positions[id]).y, 190)
        }
    }

    func testTheSummaryBandSeedsBothColumnsEquallySoQuotaBalancingIsUnchanged() throws {
        let quotas: [OverviewMasonryPlanner.Item] = [
            .init(id: "q1", height: 300, phase: .quota),
            .init(id: "q2", height: 280, phase: .quota),
            .init(id: "q3", height: 120, phase: .quota),
            .init(id: "q4", height: 100, phase: .quota)
        ]
        let summaries: [OverviewMasonryPlanner.Item] = [
            .init(id: "s1", height: 178, phase: .summary),
            .init(id: "s2", height: 178, phase: .summary)
        ]

        let withoutBand = OverviewMasonryPlanner.plan(items: quotas, spacing: 12)
        let withBand = OverviewMasonryPlanner.plan(items: summaries + quotas, spacing: 12)

        for item in quotas {
            XCTAssertEqual(
                withBand.positions[item.id]?.column,
                withoutBand.positions[item.id]?.column
            )
        }
    }

    // MARK: - Grouping

    func testPlanningWithNoGroupingIsExactlyGroupingByPhase() {
        // The compatibility pin: `auto` gets its grouping from the page's
        // resolved segments now, and an Overview with no chosen segmentation
        // resolves to the phase grouping. The two must be the same plan, or
        // shipping segments to `auto` would silently re-arrange every untouched
        // Overview.
        let items: [OverviewMasonryPlanner.Item] = [
            .init(id: "s1", height: 178, phase: .summary),
            .init(id: "s2", height: 178, phase: .summary),
            .init(id: "q1", height: 300, phase: .quota),
            .init(id: "q2", height: 280, phase: .quota),
            .init(id: "q3", height: 120, phase: .quota),
            .init(id: "q4", height: 100, phase: .quota),
            .init(id: "c1", height: 320, phase: .cost),
            .init(id: "c2", height: 210, phase: .cost),
            .init(id: "a1", height: 80, phase: .auxiliary)
        ]

        XCTAssertEqual(
            OverviewMasonryPlanner.plan(items: items, spacing: 12),
            OverviewMasonryPlanner.plan(
                items: items,
                groups: [["s1", "s2"], ["q1", "q2", "q3", "q4"], ["c1", "c2"], ["a1"]],
                spacing: 12
            )
        )
    }

    func testAChosenGroupingDecidesWhatIsBalancedTogether() throws {
        let items: [OverviewMasonryPlanner.Item] = [
            .init(id: "q1", height: 300, phase: .quota),
            .init(id: "q2", height: 100, phase: .quota),
            .init(id: "c1", height: 300, phase: .cost),
            .init(id: "c2", height: 100, phase: .cost)
        ]

        // By phase: both quota cards are placed before either cost card, so q2
        // balances against q1 and lands on the right.
        let byPhase = OverviewMasonryPlanner.plan(items: items, spacing: 0)
        XCTAssertEqual(try XCTUnwrap(byPhase.positions["q1"]).column, 0)
        XCTAssertEqual(try XCTUnwrap(byPhase.positions["q2"]).column, 1)

        // Grouped {q1, c1} then {q2, c2}: q2 is now planned after c1 took the
        // right column, so it goes left instead. Same page height, different
        // reading order — which is the point of letting the user group.
        let grouped = OverviewMasonryPlanner.plan(
            items: items,
            groups: [["q1", "c1"], ["q2", "c2"]],
            spacing: 0
        )
        XCTAssertEqual(try XCTUnwrap(grouped.positions["q1"]).column, 0)
        XCTAssertEqual(try XCTUnwrap(grouped.positions["c1"]).column, 1)
        XCTAssertEqual(try XCTUnwrap(grouped.positions["q2"]).column, 0)
        XCTAssertEqual(try XCTUnwrap(grouped.positions["c2"]).column, 1)
        XCTAssertEqual(grouped.columnHeights, [400, 400])
    }

    func testALaterGroupFlowsIntoTheColumnTheEarlierOneLeftShort() throws {
        // The planner's half of the fix the packer got: a group starts from the
        // column heights the one before it finished at, so its cards fill the
        // short side instead of waiting for the tall one.
        let plan = OverviewMasonryPlanner.plan(
            items: [
                .init(id: "tall", height: 400, phase: .quota),
                .init(id: "short", height: 100, phase: .quota),
                .init(id: "a", height: 50, phase: .auxiliary),
                .init(id: "b", height: 50, phase: .auxiliary)
            ],
            groups: [["tall", "short"], ["a", "b"]],
            spacing: 0
        )

        XCTAssertEqual(try XCTUnwrap(plan.positions["a"]).column, 1)
        XCTAssertEqual(try XCTUnwrap(plan.positions["a"]).y, 100)
        XCTAssertEqual(try XCTUnwrap(plan.positions["b"]).column, 1)
        XCTAssertEqual(try XCTUnwrap(plan.positions["b"]).y, 150)
        XCTAssertEqual(plan.columnHeights, [400, 200])
    }

    func testAnItemNoGroupClaimsJoinsTheLastGroup() throws {
        // Same rule `PageLayoutSegments.resolve` clamps a newcomer by: visible
        // at the end beats silently unplaced.
        let plan = OverviewMasonryPlanner.plan(
            items: [
                .init(id: "known", height: 100, phase: .quota),
                .init(id: "stranger", height: 100, phase: .quota)
            ],
            groups: [["known"]],
            spacing: 0
        )

        XCTAssertNotNil(plan.positions["stranger"])
        XCTAssertEqual(plan.columnHeights, [100, 100])
    }

    func testFixedColumnsFollowTheGroupOrderRatherThanThePhaseOrder() throws {
        let items: [OverviewMasonryPlanner.Item] = [
            .init(id: "quota", height: 100, phase: .quota),
            .init(id: "cost", height: 200, phase: .cost)
        ]

        // Both pinned to the left column, and the grouping says cost reads
        // first. Without the grouping the phase order would put quota on top.
        let locked = OverviewMasonryPlanner.plan(
            items: items,
            fixedColumns: ["quota": 0, "cost": 0],
            groups: [["cost"], ["quota"]],
            spacing: 10
        )

        XCTAssertEqual(try XCTUnwrap(locked.positions["cost"]).y, 0)
        XCTAssertEqual(try XCTUnwrap(locked.positions["quota"]).y, 210)
    }

    func testALockedSessionKeepsTheSummaryBandWhereItWas() throws {
        let items: [OverviewMasonryPlanner.Item] = [
            .init(id: "summary-cost", height: 178, phase: .summary),
            .init(id: "summary-status", height: 178, phase: .summary),
            .init(id: "q1", height: 200, phase: .quota),
            .init(id: "q2", height: 180, phase: .quota)
        ]
        let fixedColumns = OverviewMasonryPlanner.plan(items: items, spacing: 12)
            .positions
            .mapValues(\.column)

        let locked = OverviewMasonryPlanner.plan(
            items: items,
            fixedColumns: fixedColumns,
            spacing: 12
        )

        XCTAssertEqual(locked.positions["summary-cost"]?.column, 0)
        XCTAssertEqual(locked.positions["summary-status"]?.column, 1)
        XCTAssertEqual(try XCTUnwrap(locked.positions["summary-cost"]).y, 0)
        XCTAssertEqual(try XCTUnwrap(locked.positions["summary-status"]).y, 0)
    }
}
