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
/// supporting analytics. Quota height changes trigger a fresh optimization;
/// transient height changes below the quota block keep the current columns and
/// only move later cards down within their existing column. This lets inline
/// Cost History inspection expand naturally without reshuffling the Overview.
struct ColumnMasonryLayout: Layout {
    var columns: Int = 2
    var spacing: CGFloat = 12

    struct Cache {
        var columnsByID: [String: Int] = [:]
        var structureKey: [String] = []
        var quotaHeightKey: [String: Int] = [:]
        var columnWidthKey: Int?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let totalWidth = proposal.width ?? 0
        let plan = placementPlan(
            for: subviews,
            columnWidth: columnWidth(for: totalWidth),
            cache: &cache
        )
        return CGSize(width: totalWidth, height: CGFloat(plan.columnHeights.max() ?? 0))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let width = columnWidth(for: bounds.width)
        let plan = placementPlan(for: subviews, columnWidth: width, cache: &cache)
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

    private func placementPlan(
        for subviews: Subviews,
        columnWidth: CGFloat,
        cache: inout Cache
    ) -> OverviewMasonryPlanner.Plan {
        let proposal = ProposedViewSize(width: columnWidth, height: nil)
        let items = subviews.enumerated().map { index, subview in
            OverviewMasonryPlanner.Item(
                id: stableID(for: subview, index: index),
                height: Double(subview.sizeThatFits(proposal).height),
                phase: subview[OverviewMasonryPhaseKey.self].corePhase
            )
        }
        let structureKey = items.map { "\($0.phase.rawValue):\($0.id)" }
        let quotaHeightKey = Dictionary(uniqueKeysWithValues:
            items.filter { $0.phase == .quota }.map { item in
                (item.id, Int((item.height * 2).rounded()))
            }
        )
        let columnWidthKey = Int((columnWidth * 2).rounded())
        if cache.columnsByID.isEmpty
            || cache.structureKey != structureKey
            || cache.quotaHeightKey != quotaHeightKey
            || cache.columnWidthKey != columnWidthKey
        {
            let optimized = OverviewMasonryPlanner.plan(
                items: items,
                columns: columns,
                spacing: Double(spacing)
            )
            cache.columnsByID = optimized.positions.mapValues(\.column)
            cache.structureKey = structureKey
            cache.quotaHeightKey = quotaHeightKey
            cache.columnWidthKey = columnWidthKey
        }
        return OverviewMasonryPlanner.plan(
            items: items,
            fixedColumns: cache.columnsByID,
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
