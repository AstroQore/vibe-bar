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
/// supporting analytics. It optimizes column assignment once for this layout
/// lifetime, then keeps every existing card on that side until the Overview is
/// entered again. Refreshes and inline expansion may move later cards down,
/// but never reshuffle the visible dashboard.
struct ColumnMasonryLayout: Layout {
    /// Owned by `OverviewWaterfall` for exactly one visible Overview session.
    /// Keeping assignments outside SwiftUI's disposable Layout cache prevents
    /// a live subview-set change from silently triggering a second shuffle.
    final class Session {
        var columnsByID: [String: Int] = [:]
    }

    var columns: Int = 2
    var spacing: CGFloat = 12
    let session: Session

    init(columns: Int = 2, spacing: CGFloat = 12, session: Session = Session()) {
        self.columns = columns
        self.spacing = spacing
        self.session = session
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
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
        cache: inout Void
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
        cache: inout Void
    ) -> OverviewMasonryPlanner.Plan {
        let proposal = ProposedViewSize(width: columnWidth, height: nil)
        let items = subviews.enumerated().map { index, subview in
            OverviewMasonryPlanner.Item(
                id: stableID(for: subview, index: index),
                height: Double(subview.sizeThatFits(proposal).height),
                phase: subview[OverviewMasonryPhaseKey.self].corePhase
            )
        }
        // A zero-width speculative pass is not a real Overview placement.
        // Wait for the first usable proposal, optimize once, then lock the
        // assignment for the lifetime of this visible Overview session.
        if session.columnsByID.isEmpty, columnWidth > 0, !items.isEmpty {
            let optimized = OverviewMasonryPlanner.plan(
                items: items,
                columns: columns,
                spacing: Double(spacing)
            )
            session.columnsByID = optimized.positions.mapValues(\.column)
        }
        if session.columnsByID.isEmpty {
            return OverviewMasonryPlanner.plan(
                items: items,
                columns: columns,
                spacing: Double(spacing)
            )
        }
        return OverviewMasonryPlanner.plan(
            items: items,
            fixedColumns: session.columnsByID,
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
