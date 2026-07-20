import SwiftUI
import VibeBarCore

enum OverviewMasonryPhase: Int {
    case quota
    case cost
    case auxiliary

    var corePhase: OverviewMasonryPlanner.Phase {
        switch self {
        case .quota: .quota
        case .cost: .cost
        case .auxiliary: .auxiliary
        }
    }
}

private struct OverviewMasonryPhaseKey: LayoutValueKey {
    static let defaultValue = OverviewMasonryPhase.auxiliary
}

private struct OverviewMasonryIDKey: LayoutValueKey {
    static let defaultValue = ""
}

extension View {
    func overviewMasonryItem(id: String, phase: OverviewMasonryPhase) -> some View {
        layoutValue(key: OverviewMasonryIDKey.self, value: id)
            .layoutValue(key: OverviewMasonryPhaseKey.self, value: phase)
    }
}

/// A live-measured waterfall whose policy is quota-first, then Cost, then
/// supporting analytics. See `OverviewMasonryPlanner` for the tested optimizer.
struct ColumnMasonryLayout: Layout {
    var columns: Int = 2
    var spacing: CGFloat = 12

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let totalWidth = proposal.width ?? 0
        let plan = placementPlan(for: subviews, columnWidth: columnWidth(for: totalWidth))
        return CGSize(width: totalWidth, height: CGFloat(plan.columnHeights.max() ?? 0))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        let width = columnWidth(for: bounds.width)
        let plan = placementPlan(for: subviews, columnWidth: width)
        for (index, subview) in subviews.enumerated() {
            let id = stableID(for: subview, index: index)
            guard let position = plan.positions[id] else { continue }
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            subview.place(
                at: CGPoint(
                    x: bounds.minX + CGFloat(position.column) * (width + spacing),
                    y: bounds.minY + CGFloat(position.y)
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: size.height)
            )
        }
    }

    private func placementPlan(for subviews: Subviews, columnWidth: CGFloat) -> OverviewMasonryPlanner.Plan {
        let proposal = ProposedViewSize(width: columnWidth, height: nil)
        let items = subviews.enumerated().map { index, subview in
            OverviewMasonryPlanner.Item(
                id: stableID(for: subview, index: index),
                height: Double(subview.sizeThatFits(proposal).height),
                phase: subview[OverviewMasonryPhaseKey.self].corePhase
            )
        }
        return OverviewMasonryPlanner.plan(
            items: items,
            columns: columns,
            spacing: Double(spacing)
        )
    }

    private func stableID(for subview: Subviews.Element, index: Int) -> String {
        let supplied = subview[OverviewMasonryIDKey.self]
        return supplied.isEmpty ? "overview-item-\(index)" : supplied
    }

    private func columnWidth(for totalWidth: CGFloat) -> CGFloat {
        let columnCount = max(1, columns)
        return max(0, (totalWidth - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))
    }
}
