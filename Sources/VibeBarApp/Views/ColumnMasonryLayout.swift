import SwiftUI

/// Two-column "shortest column wins" masonry. Used by the Overview to lay out
/// cost cards plus the four combined summary cards (Model Ranking, Past Year,
/// When You Use, Hourly Burn Rate) without one column ending up dramatically
/// taller than the other.
///
/// Each column is the same width (`(totalWidth - spacing) / columns`). For
/// each subview we measure the height it would take at that width, then place
/// it in whichever column currently has the shortest stack. Ties always
/// resolve to the leftmost shorter column, which keeps the layout
/// deterministic across redraws.
struct ColumnMasonryLayout: Layout {
    var columns: Int = 2
    var spacing: CGFloat = 12
    /// The first `anchoredItems` subviews are pinned to columns 0…N-1 in
    /// declaration order, regardless of column height. Everything after
    /// fills whichever column is currently shortest. This lets the Overview
    /// keep OpenAI Quota / Claude Quota locked to their respective columns
    /// while the cost + summary cards below flow into the empty space under
    /// whichever provider's quota came up shorter.
    var anchoredItems: Int = 0

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let totalWidth = proposal.width ?? 0
        let columnWidth = columnWidth(for: totalWidth)
        let placement = placements(for: subviews, columnWidth: columnWidth)
        let totalHeight = placement.columnHeights.max() ?? 0
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        let columnWidth = columnWidth(for: bounds.width)
        let placement = placements(for: subviews, columnWidth: columnWidth)
        for (index, slot) in placement.slots.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + slot.x, y: bounds.minY + slot.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: columnWidth, height: slot.height)
            )
        }
    }

    private struct Slot {
        let x: CGFloat
        let y: CGFloat
        let height: CGFloat
    }

    private struct Placement {
        let slots: [Slot]
        let columnHeights: [CGFloat]
    }

    private func placements(for subviews: Subviews, columnWidth: CGFloat) -> Placement {
        let columnCount = max(1, columns)
        let anchorLimit = max(0, min(anchoredItems, columnCount))
        var heights = Array(repeating: CGFloat(0), count: columnCount)
        var slots: [Slot] = []
        slots.reserveCapacity(subviews.count)
        for (index, subview) in subviews.enumerated() {
            let proposed = ProposedViewSize(width: columnWidth, height: nil)
            let size = subview.sizeThatFits(proposed)
            let column = index < anchorLimit ? index : shortestColumn(in: heights)
            let needsLeadingSpacing = heights[column] > 0
            let y = heights[column] + (needsLeadingSpacing ? spacing : 0)
            let x = CGFloat(column) * (columnWidth + spacing)
            slots.append(Slot(x: x, y: y, height: size.height))
            heights[column] = y + size.height
        }
        return Placement(slots: slots, columnHeights: heights)
    }

    /// Leftmost column whose running height is the smallest. Ties prefer the
    /// earlier index — important so re-runs of `sizeThatFits` and
    /// `placeSubviews` agree on placement when several columns are at zero.
    private func shortestColumn(in heights: [CGFloat]) -> Int {
        var bestIndex = 0
        var bestHeight = heights[0]
        for index in 1..<heights.count where heights[index] < bestHeight {
            bestHeight = heights[index]
            bestIndex = index
        }
        return bestIndex
    }

    private func columnWidth(for totalWidth: CGFloat) -> CGFloat {
        let columnCount = max(1, columns)
        let totalSpacing = spacing * CGFloat(columnCount - 1)
        return max(0, (totalWidth - totalSpacing) / CGFloat(columnCount))
    }
}
