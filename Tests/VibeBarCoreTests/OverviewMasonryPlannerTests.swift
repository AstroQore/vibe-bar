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
}
