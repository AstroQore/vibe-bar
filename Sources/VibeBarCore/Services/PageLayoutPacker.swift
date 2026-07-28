import Foundation

/// Packs a page's cards into two columns so the rendered page is as short as
/// possible.
///
/// This is the engine behind `PageLayoutMode.compact`. It differs from
/// `OverviewMasonryPlanner` in exactly one way, and that way is the whole
/// point: the planner places cards in phases — every quota card first, then the
/// cost cards from those seeded column heights, then the analytics — because
/// the Overview reads better with the subscription panels at the top. The
/// phase constraint also puts arrangements out of reach that are simply
/// shorter, which is why a hand-packed page can beat the balancer. `compact`
/// drops the constraint and optimizes for height alone.
///
/// Pure and deterministic: same items, same spacing, same ratio, same answer.
/// SwiftUI stays responsible only for measuring heights.
///
/// ### Objective
///
/// A page's height is the taller of its two column stacks, where a stack is the
/// sum of its cards plus one inter-card gap between each neighbouring pair.
/// Minimizing that is the two-way partition problem — NP-hard in general, and
/// entirely tractable at the sizes involved here (a page has at most a dozen
/// cards).
public enum PageLayoutPacker {
    /// One card to place, with the height it last rendered at.
    public struct Item: Hashable, Sendable {
        public let id: PageLayoutModuleID
        public let height: Double

        public init(id: PageLayoutModuleID, height: Double) {
            self.id = id
            // A card that has never been measured, or measured as NaN mid
            // layout pass, contributes nothing rather than poisoning every
            // comparison it takes part in.
            self.height = height.isFinite ? max(0, height) : 0
        }
    }

    /// A chosen partition, with the column heights it implies.
    public struct Packing: Hashable, Sendable {
        /// Exactly `PageLayoutConfig.columnCount` columns. Within each column
        /// the cards keep the relative order they arrived in.
        public let columns: [[PageLayoutModuleID]]
        public let columnHeights: [Double]
        /// False when the module count forced the greedy fallback, i.e. the
        /// result is a good partition rather than a provably optimal one.
        public let isExact: Bool

        public init(columns: [[PageLayoutModuleID]], columnHeights: [Double], isExact: Bool) {
            self.columns = columns
            self.columnHeights = columnHeights
            self.isExact = isExact
        }

        /// What the page will measure: the taller column.
        public var pageHeight: Double { columnHeights.max() ?? 0 }
    }

    /// Largest module count still searched exhaustively.
    ///
    /// A real page has at most about a dozen cards, so the search never
    /// actually runs at the limit; 2^16 leaves plenty of headroom before the
    /// greedy fallback takes over, and with the two bounds below most of that
    /// space is never visited. The cap exists so a future page with dozens of
    /// modules degrades in speed rather than hanging the layout pass.
    public static let exactSearchLimit = 16

    // MARK: - Packing

    /// The partition of `items` that minimizes the page's height.
    ///
    /// - Parameters:
    ///   - items: cards in the order they should appear *within* a column —
    ///     normally the page's default config read left column then right, so
    ///     a compact page still reads in its familiar order top to bottom.
    ///     Duplicate identifiers are collapsed, keeping the first.
    ///   - spacing: the page's inter-card gap. Counted between neighbours
    ///     only, so a column of one card carries no gap and the packer is not
    ///     biased towards splitting.
    ///   - ratio: the page's width split. Does not change which partitions
    ///     exist — the heights are what they are — but breaks ties in favour
    ///     of putting the heavier stack under the wider column, which is where
    ///     those cards will render shortest next time they are measured.
    public static func pack(
        items: [Item],
        spacing: Double,
        ratio: PageColumnRatio = .equal
    ) -> Packing {
        let unique = deduplicated(items)
        let gap = spacing.isFinite ? max(0, spacing) : 0
        guard !unique.isEmpty else {
            return Packing(
                columns: [[PageLayoutModuleID]](repeating: [], count: PageLayoutConfig.columnCount),
                columnHeights: [Double](repeating: 0, count: PageLayoutConfig.columnCount),
                isExact: true
            )
        }

        let isExact = unique.count <= exactSearchLimit
        let assignment = isExact
            ? exactAssignment(unique, spacing: gap, ratio: ratio)
            : greedyAssignment(unique, spacing: gap, ratio: ratio)

        var columns = [[PageLayoutModuleID]](repeating: [], count: PageLayoutConfig.columnCount)
        var heights = [Double](repeating: 0, count: PageLayoutConfig.columnCount)
        for (index, item) in unique.enumerated() {
            let column = min(max(0, assignment[index]), PageLayoutConfig.columnCount - 1)
            heights[column] = appended(heights[column], columns[column].count, item.height, spacing: gap)
            columns[column].append(item.id)
        }
        return Packing(columns: columns, columnHeights: heights, isExact: isExact)
    }

    /// `pack(items:spacing:ratio:)` as a `PageLayoutConfig`, ready to hand to
    /// the fixed-order renderer.
    public static func packedConfig(
        items: [Item],
        spacing: Double,
        ratio: PageColumnRatio = .equal,
        measuredHeights: [PageLayoutModuleID: Double] = [:]
    ) -> PageLayoutConfig {
        PageLayoutConfig(
            ratio: ratio,
            columns: pack(items: items, spacing: spacing, ratio: ratio).columns,
            measuredHeights: measuredHeights
        )
    }

    // MARK: - Measuring an arrangement

    /// Height of one column: its cards plus a gap between each neighbouring
    /// pair. A module with no known height counts as zero.
    public static func stackedHeight(
        _ moduleIDs: [PageLayoutModuleID],
        heights: [PageLayoutModuleID: Double],
        spacing: Double
    ) -> Double {
        let gap = spacing.isFinite ? max(0, spacing) : 0
        var total = 0.0
        var count = 0
        for moduleID in moduleIDs {
            let height = heights[moduleID].map { $0.isFinite ? max(0, $0) : 0 } ?? 0
            total = appended(total, count, height, spacing: gap)
            count += 1
        }
        return total
    }

    /// What an already-chosen arrangement would measure at these heights — the
    /// number to beat before moving a card the user is currently looking at.
    public static func pageHeight(
        columns: [[PageLayoutModuleID]],
        heights: [PageLayoutModuleID: Double],
        spacing: Double
    ) -> Double {
        columns
            .map { stackedHeight($0, heights: heights, spacing: spacing) }
            .max() ?? 0
    }

    // MARK: - Exact search

    /// Depth-first search over every assignment of cards to columns, with two
    /// bounds that cut most of the tree:
    ///
    /// 1. A partial stack only grows, so once the taller partial column
    ///    already exceeds the best complete page found, nothing below can beat
    ///    it.
    /// 2. Even a perfect split of what is left cannot bring the page below
    ///    half the total height still to place.
    ///
    /// Both prune on strict `>` so subtrees that could *tie* the best score are
    /// still explored — the tie-breaks below decide those, not the traversal.
    private static func exactAssignment(
        _ items: [Item],
        spacing: Double,
        ratio: PageColumnRatio
    ) -> [Int] {
        let count = items.count
        var remaining = [Double](repeating: 0, count: count + 1)
        for index in stride(from: count - 1, through: 0, by: -1) {
            remaining[index] = remaining[index + 1] + items[index].height
        }

        var assignment = [Int](repeating: 0, count: count)
        var best = [Int](repeating: 0, count: count)
        var bestScore = [Double](repeating: .infinity, count: 4)

        func visit(
            _ index: Int,
            _ left: Double,
            _ leftCount: Int,
            _ right: Double,
            _ rightCount: Int,
            _ mask: Double
        ) {
            if max(left, right) > bestScore[0] { return }
            if (left + right + remaining[index]) / 2 > bestScore[0] { return }
            guard index < count else {
                let score = [
                    max(left, right),
                    ratioPenalty(left: left, right: right, ratio: ratio),
                    abs(left - right),
                    mask
                ]
                if score.precedesLexicographically(bestScore) {
                    bestScore = score
                    best = assignment
                }
                return
            }
            let height = items[index].height
            // The mask weights the *first* card most heavily, so minimizing it
            // is a left-first preference read in input order: among partitions
            // that are otherwise exactly as good, the one that leaves the
            // earliest cards where the page's default put them wins. Making it
            // a score term rather than relying on "first one found" keeps the
            // answer independent of the traversal.
            assignment[index] = 0
            visit(
                index + 1,
                appended(left, leftCount, height, spacing: spacing),
                leftCount + 1,
                right,
                rightCount,
                mask
            )
            assignment[index] = 1
            visit(
                index + 1,
                left,
                leftCount,
                appended(right, rightCount, height, spacing: spacing),
                rightCount + 1,
                mask + Double(1 << (count - 1 - index))
            )
        }

        visit(0, 0, 0, 0, 0, 0)
        return best
    }

    /// Longest-processing-time-first: place the tallest card remaining into
    /// whichever column it leaves shorter. The classic 4/3 approximation, and
    /// the fallback once the module count puts an exhaustive search out of
    /// reach. Input order is restored by the caller, so the greedy pass decides
    /// columns only, never the order within one.
    private static func greedyAssignment(
        _ items: [Item],
        spacing: Double,
        ratio: PageColumnRatio
    ) -> [Int] {
        let tallestFirst = items.indices.sorted { lhs, rhs in
            items[lhs].height == items[rhs].height
                ? lhs < rhs
                : items[lhs].height > items[rhs].height
        }
        var assignment = [Int](repeating: 0, count: items.count)
        var heights = [Double](repeating: 0, count: PageLayoutConfig.columnCount)
        var counts = [Int](repeating: 0, count: PageLayoutConfig.columnCount)
        let preferred = widerColumn(ratio)
        for index in tallestFirst {
            let height = items[index].height
            let candidates = (0..<PageLayoutConfig.columnCount).map {
                appended(heights[$0], counts[$0], height, spacing: spacing)
            }
            let shortest = candidates.min() ?? 0
            let tied = candidates.indices.filter { candidates[$0] == shortest }
            let column = tied.contains(preferred) ? preferred : (tied.first ?? 0)
            assignment[index] = column
            heights[column] = candidates[column]
            counts[column] += 1
        }
        return assignment
    }

    // MARK: - Scoring

    /// Penalty applied when the heavier stack sits under the *narrower*
    /// column.
    ///
    /// Two partitions can leave the page exactly as tall while disagreeing
    /// about which side carries the load. Cards render shorter where they are
    /// wider, so loading the wide side is the arrangement more likely to be
    /// genuinely shorter once these cards are measured again. With an equal
    /// split there is no wider side and nothing to prefer.
    private static func ratioPenalty(
        left: Double,
        right: Double,
        ratio: PageColumnRatio
    ) -> Double {
        guard ratio != .equal, left != right else { return 0 }
        return (left > right) == (ratio.leftFraction > ratio.rightFraction) ? 0 : 1
    }

    private static func widerColumn(_ ratio: PageColumnRatio) -> Int {
        ratio.leftFraction >= ratio.rightFraction ? 0 : 1
    }

    // MARK: - Helpers

    /// A column's height after one more card. The gap is counted only between
    /// neighbours, so the first card in a column adds no spacing.
    private static func appended(
        _ current: Double,
        _ count: Int,
        _ height: Double,
        spacing: Double
    ) -> Double {
        count == 0 ? height : current + spacing + height
    }

    private static func deduplicated(_ items: [Item]) -> [Item] {
        var seen = Set<PageLayoutModuleID>()
        return items.filter { !$0.id.rawValue.isEmpty && seen.insert($0.id).inserted }
    }
}

private extension Array where Element == Double {
    /// Strict lexicographic comparison over a fixed-length score vector.
    func precedesLexicographically(_ other: [Double]) -> Bool {
        for (lhs, rhs) in zip(self, other) where lhs != rhs {
            return lhs < rhs
        }
        return count < other.count
    }
}
