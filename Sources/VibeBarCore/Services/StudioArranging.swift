import Foundation
import CoreGraphics

/// Where a pointer lands among the things a surface is made of.
///
/// The Layout Studio arranges a real popover page or a real mini window by
/// dragging its cards and cells directly, so the questions it asks are
/// geometric: which column is the pointer in, which card is it above, which
/// cell is it beside. The answers are pure functions of frames the surface
/// reported, which keeps the gestures thin and lets the rules be tested
/// without a window.
///
/// Two shapes of surface. A page is two columns of cards, each column a
/// vertical stack. A mini window is one reading order of cells laid out along
/// an axis — a row of gauges, a list of rows, a grid that wraps — and its
/// order is what the drag rearranges.
///
/// Every rule here is a **midpoint** rule, and deliberately so. A card is
/// "before" the pointer once the pointer passes its centre, which is stable
/// under the live reflow the Studio animates while a drag is in flight: after
/// the dragged item is re-slotted, the item that made room for it has moved
/// *away* from the pointer, so the same test keeps giving the same answer
/// until the pointer genuinely crosses another centre.
public enum StudioArranging {
    /// A place in a page's columns: the column, and the index among that
    /// column's *other* cards — the one being dragged does not count.
    public struct ColumnSlot: Hashable, Sendable {
        public let column: Int
        public let index: Int

        public init(column: Int, index: Int) {
            self.column = column
            self.index = index
        }
    }

    /// The axis a reading order runs along on a surface.
    public enum Axis: Sendable {
        case horizontal
        case vertical
    }

    // MARK: - Pages

    /// Where `dragging` would sit if it were dropped at `point`.
    ///
    /// - Parameters:
    ///   - point: pointer, in the surface's coordinates.
    ///   - columnRanges: the horizontal extent of each column, in the same
    ///     coordinates. The pointer picks the column it is inside, or the
    ///     nearest one — a card carried past the page's edge still lands.
    ///   - columns: the page's columns as they are before the move; the
    ///     dragged card's own entry is ignored wherever it is.
    ///   - frames: the cards' current frames. A card with no frame yet is
    ///     skipped, not guessed at.
    public static func columnSlot(
        at point: CGPoint,
        columnRanges: [ClosedRange<CGFloat>],
        columns: [[PageLayoutModuleID]],
        frames: [PageLayoutModuleID: CGRect],
        dragging: PageLayoutModuleID
    ) -> ColumnSlot {
        let column = nearestColumn(to: point.x, ranges: columnRanges)
        let others = (columns.indices.contains(column) ? columns[column] : [])
            .filter { $0 != dragging }
        var index = others.count
        for (offset, moduleID) in others.enumerated() {
            guard let frame = frames[moduleID] else { continue }
            if point.y < frame.midY {
                index = offset
                break
            }
        }
        return ColumnSlot(column: column, index: index)
    }

    /// The columns with `moduleID` moved to `slot`. Removed from wherever it
    /// was first, so a card can never appear twice; a card that was not in the
    /// columns at all (one dragged back out of the hidden tray) is inserted.
    public static func columnsMoving(
        _ moduleID: PageLayoutModuleID,
        to slot: ColumnSlot,
        in columns: [[PageLayoutModuleID]]
    ) -> [[PageLayoutModuleID]] {
        var next = columns
        while next.count < PageLayoutConfig.columnCount { next.append([]) }
        for index in next.indices {
            next[index].removeAll { $0 == moduleID }
        }
        let column = min(max(0, slot.column), next.count - 1)
        let position = min(max(0, slot.index), next[column].count)
        next[column].insert(moduleID, at: position)
        return next
    }

    /// The columns with `moduleID` taken out — what the page looks like while
    /// the card hovers over the hide well.
    public static func columnsRemoving(
        _ moduleID: PageLayoutModuleID,
        from columns: [[PageLayoutModuleID]]
    ) -> [[PageLayoutModuleID]] {
        columns.map { $0.filter { $0 != moduleID } }
    }

    /// Segment membership after `moduleID` landed where `columns` now has it.
    ///
    /// A card joins the segment of the card directly above it in its new
    /// column; with nothing above, the one below; with an empty column, it
    /// keeps its own. Segments are a reading order, so "the card I dropped it
    /// under" is the group the user meant — and the result always obeys the
    /// ordering constraint, because the columns already do.
    public static func segmentsAfterMove(
        _ moduleID: PageLayoutModuleID,
        columns: [[PageLayoutModuleID]],
        segments: [[PageLayoutModuleID]]
    ) -> [[PageLayoutModuleID]] {
        guard segments.count > 1 else { return segments }
        let rank = PageLayoutSegments.ordering(segments)
        var neighbourRank: Int?
        for column in columns {
            guard let position = column.firstIndex(of: moduleID) else { continue }
            if position > 0, let above = rank[column[position - 1]] {
                neighbourRank = above
            } else if position + 1 < column.count, let below = rank[column[position + 1]] {
                neighbourRank = below
            }
            break
        }
        let target = min(neighbourRank ?? rank[moduleID] ?? segments.count - 1, segments.count - 1)
        var next = segments.map { $0.filter { $0 != moduleID } }
        next[target].append(moduleID)
        return next
    }

    // MARK: - Reading orders

    /// Where `dragging` would sit in `order` if it were dropped at `point`:
    /// the index among the *other* entries.
    ///
    /// The cell under the pointer decides — before it or after it, by the
    /// pointer's side of its centre along `axis`. With the pointer in a gap,
    /// the nearest cell decides the same way. Entries with no frame (a field
    /// the window is not drawing right now) keep their place in the order but
    /// never catch the pointer.
    public static func linearSlot(
        at point: CGPoint,
        order: [String],
        frames: [String: CGRect],
        dragging: String,
        axis: Axis
    ) -> Int {
        let others = order.filter { $0 != dragging }
        guard !others.isEmpty else { return 0 }

        func isBefore(_ frame: CGRect) -> Bool {
            switch axis {
            case .horizontal: return point.x < frame.midX
            case .vertical:   return point.y < frame.midY
            }
        }

        if let hit = others.enumerated().first(where: { frames[$0.element]?.contains(point) == true }),
           let frame = frames[hit.element] {
            return isBefore(frame) ? hit.offset : hit.offset + 1
        }

        var nearest: (offset: Int, frame: CGRect, distance: CGFloat)?
        for (offset, id) in others.enumerated() {
            guard let frame = frames[id] else { continue }
            let distance = hypot(point.x - frame.midX, point.y - frame.midY)
            if nearest == nil || distance < nearest!.distance {
                nearest = (offset, frame, distance)
            }
        }
        guard let nearest else { return others.count }
        return isBefore(nearest.frame) ? nearest.offset : nearest.offset + 1
    }

    /// `order` with `id` moved to `index` among the others. An `id` the order
    /// did not contain is inserted.
    public static func orderMoving(
        _ id: String,
        to index: Int,
        in order: [String]
    ) -> [String] {
        var next = order.filter { $0 != id }
        next.insert(id, at: min(max(0, index), next.count))
        return next
    }

    // MARK: - Helpers

    /// The range containing `x`, or the nearest by edge distance. A point
    /// left of every column is in the first, right of every column in the
    /// last; a point in the gutter goes to whichever edge is closer.
    static func nearestColumn(to x: CGFloat, ranges: [ClosedRange<CGFloat>]) -> Int {
        guard !ranges.isEmpty else { return 0 }
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, range) in ranges.enumerated() {
            if range.contains(x) { return index }
            let distance = min(abs(x - range.lowerBound), abs(x - range.upperBound))
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }
}
