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

    /// What a column already carries when a packing starts.
    ///
    /// Segments are packed as a relay rather than as isolated bands: the first
    /// segment's answer becomes the second's starting point, so the second
    /// segment's cards flow up into whichever column the first one left short.
    /// `isOccupied` is separate from `height` because a column can be non-empty
    /// and still measure zero (a card the page has never rendered), and it is
    /// occupancy — not height — that decides whether the next card pays a gap.
    public struct ColumnSeed: Hashable, Sendable {
        public let height: Double
        public let isOccupied: Bool

        public init(height: Double, isOccupied: Bool) {
            self.height = height.isFinite ? max(0, height) : 0
            self.isOccupied = isOccupied
        }

        public static let empty = ColumnSeed(height: 0, isOccupied: false)
    }

    /// A chosen partition, with the column heights it implies.
    public struct Packing: Hashable, Sendable {
        /// Exactly `PageLayoutConfig.columnCount` columns. Within each column
        /// the cards keep the relative order they arrived in.
        public let columns: [[PageLayoutModuleID]]
        /// Each column's height *after* this packing, seeds included — so on a
        /// segmented page the last segment's `pageHeight` is the whole page's.
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
    ///   - seeds: what each column already carries. Empty on an unsegmented
    ///     page; on a segmented one it is the previous segment's answer, and
    ///     every score term — the page height it minimizes as well as the
    ///     tie-breaks — is computed on the resulting *totals*, because the
    ///     page's height is what the columns measure at the bottom, not what
    ///     this one segment contributed.
    public static func pack(
        items: [Item],
        spacing: Double,
        ratio: PageColumnRatio = .equal,
        seeds: [ColumnSeed] = []
    ) -> Packing {
        let unique = deduplicated(items)
        let gap = spacing.isFinite ? max(0, spacing) : 0
        let seeded = normalized(seeds)
        guard !unique.isEmpty else {
            // A segment with nothing in it must hand the relay on untouched,
            // not reset the columns to zero.
            return Packing(
                columns: [[PageLayoutModuleID]](repeating: [], count: PageLayoutConfig.columnCount),
                columnHeights: seeded.map(\.height),
                isExact: true
            )
        }

        let isExact = unique.count <= exactSearchLimit
        let assignment = isExact
            ? exactAssignment(unique, spacing: gap, ratio: ratio, seeds: seeded)
            : greedyAssignment(unique, spacing: gap, ratio: ratio, seeds: seeded)

        var columns = [[PageLayoutModuleID]](repeating: [], count: PageLayoutConfig.columnCount)
        var heights = seeded.map(\.height)
        var counts = seeded.map { $0.isOccupied ? 1 : 0 }
        for (index, item) in unique.enumerated() {
            let column = min(max(0, assignment[index]), PageLayoutConfig.columnCount - 1)
            heights[column] = appended(heights[column], counts[column], item.height, spacing: gap)
            counts[column] += 1
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

    // MARK: - Segments

    /// Pack the segments as a relay: each one starts from the column heights the
    /// one before it finished at.
    ///
    /// A segment is an ordering constraint, not a horizontal cut. Every card in
    /// segment *k* renders above every card in segment *k+1* **within its own
    /// column**, and the two columns are never made to line up at the boundary —
    /// so a segment whose cards all landed on one side leaves the other side
    /// short, and the next segment's cards flow straight up into it. Packing the
    /// segments independently instead left that gap on screen as a hole, which
    /// is the bug this relay exists to fix.
    ///
    /// Identifiers are deduplicated across segments as well as within one,
    /// keeping the first occurrence, so a hand-edited file cannot render one
    /// card twice.
    public static func pack(
        segments: [[Item]],
        spacing: Double,
        ratio: PageColumnRatio = .equal
    ) -> [Packing] {
        var seen = Set<PageLayoutModuleID>()
        var seeds = [ColumnSeed](repeating: .empty, count: PageLayoutConfig.columnCount)
        var result: [Packing] = []
        result.reserveCapacity(segments.count)
        for segment in segments {
            let unique = segment.filter { !$0.id.rawValue.isEmpty && seen.insert($0.id).inserted }
            let packing = pack(items: unique, spacing: spacing, ratio: ratio, seeds: seeds)
            seeds = (0..<PageLayoutConfig.columnCount).map { index in
                ColumnSeed(
                    height: packing.columnHeights[index],
                    // Occupancy is cumulative: a column filled by segment 0 and
                    // skipped by segment 1 still owes a gap to segment 2.
                    isOccupied: seeds[index].isOccupied || !packing.columns[index].isEmpty
                )
            }
            result.append(packing)
        }
        return result
    }

    /// `pack(segments:spacing:ratio:)` as the per-segment columns the renderer
    /// concatenates.
    public static func packedSegmentColumns(
        segments: [[Item]],
        spacing: Double,
        ratio: PageColumnRatio = .equal
    ) -> [[[PageLayoutModuleID]]] {
        pack(segments: segments, spacing: spacing, ratio: ratio).map(\.columns)
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

    /// The two columns of a segmented arrangement as they actually flow:
    /// segment 0's left column, then segment 1's, and so on, and the same for
    /// the right.
    ///
    /// This is what the renderer draws. A segment boundary exists only inside a
    /// column, which is why there is nothing here that lines the two sides up.
    public static func flowColumns(
        segments: [[[PageLayoutModuleID]]]
    ) -> [[PageLayoutModuleID]] {
        var columns = [[PageLayoutModuleID]](repeating: [], count: PageLayoutConfig.columnCount)
        for segment in segments {
            for index in columns.indices where segment.indices.contains(index) {
                columns[index].append(contentsOf: segment[index])
            }
        }
        return columns
    }

    /// What a *segmented* arrangement would measure: the taller of the two
    /// columns once every segment has flowed into them.
    ///
    /// The number `compact`'s re-pack hysteresis has to compare once a page has
    /// segments. It used to sum each band's taller column plus an inter-band
    /// gap, which is what a page of rigid horizontal bands measured; the
    /// segments flow now, so the page is exactly as tall as its taller column.
    public static func pageHeight(
        segments: [[[PageLayoutModuleID]]],
        heights: [PageLayoutModuleID: Double],
        spacing: Double
    ) -> Double {
        pageHeight(columns: flowColumns(segments: segments), heights: heights, spacing: spacing)
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
    ///
    /// The seeds only move where the search starts: both bounds stay valid
    /// because a seeded column, like an empty one, can only grow.
    private static func exactAssignment(
        _ items: [Item],
        spacing: Double,
        ratio: PageColumnRatio,
        seeds: [ColumnSeed]
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

        visit(
            0,
            seeds[0].height,
            seeds[0].isOccupied ? 1 : 0,
            seeds[1].height,
            seeds[1].isOccupied ? 1 : 0,
            0
        )
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
        ratio: PageColumnRatio,
        seeds: [ColumnSeed]
    ) -> [Int] {
        let tallestFirst = items.indices.sorted { lhs, rhs in
            items[lhs].height == items[rhs].height
                ? lhs < rhs
                : items[lhs].height > items[rhs].height
        }
        var assignment = [Int](repeating: 0, count: items.count)
        var heights = seeds.map(\.height)
        var counts = seeds.map { $0.isOccupied ? 1 : 0 }
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

    /// Exactly `PageLayoutConfig.columnCount` seeds, so the search can index
    /// them without checking.
    private static func normalized(_ seeds: [ColumnSeed]) -> [ColumnSeed] {
        (0..<PageLayoutConfig.columnCount).map { index in
            seeds.indices.contains(index) ? seeds[index] : .empty
        }
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
