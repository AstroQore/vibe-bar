import Foundation

/// Pure layout planner for the Overview's two-column waterfall.
///
/// Placement is deliberately phased: quota cards are balanced first without
/// considering anything below them, cost cards are then balanced from those
/// seeded column heights, and auxiliary cards finally fill the shorter column.
/// Keeping this policy in Core makes the behavior deterministic and testable
/// while SwiftUI remains responsible only for live height measurement.
public enum OverviewMasonryPlanner {
    public enum Phase: Int, Sendable, Comparable {
        case quota
        case cost
        case auxiliary

        public static func < (lhs: Phase, rhs: Phase) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public struct Item: Sendable, Equatable {
        public let id: String
        public let height: Double
        public let phase: Phase

        public init(id: String, height: Double, phase: Phase) {
            self.id = id
            self.height = max(0, height)
            self.phase = phase
        }
    }

    public struct Position: Sendable, Equatable {
        public let column: Int
        public let y: Double

        public init(column: Int, y: Double) {
            self.column = column
            self.y = y
        }
    }

    public struct Plan: Sendable, Equatable {
        public let positions: [String: Position]
        public let columnHeights: [Double]

        public init(positions: [String: Position], columnHeights: [Double]) {
            self.positions = positions
            self.columnHeights = columnHeights
        }
    }

    public static func plan(
        items: [Item],
        columns: Int = 2,
        spacing: Double
    ) -> Plan {
        let columnCount = max(1, columns)
        guard columnCount == 2 else {
            return greedyPlan(items: items, columns: columnCount, spacing: spacing)
        }

        let quotas = items.filter { $0.phase == .quota }
        let costs = items.filter { $0.phase == .cost }
        let auxiliary = items.filter { $0.phase == .auxiliary }
        var positions: [String: Position] = [:]
        var heights = Array(repeating: 0.0, count: columnCount)

        // AQ's Overview has four quota cards. Enumerating all 24 orders lets
        // either pair occupy either column while preserving the invariant of
        // two quota cards per column. For any other count, use deterministic
        // shortest-column placement rather than making brittle assumptions.
        if quotas.count == 4 {
            let order = bestQuotaOrder(quotas, spacing: spacing)
            for (offset, item) in order.enumerated() {
                let column = offset < 2 ? 0 : 1
                append(item, to: column, spacing: spacing, heights: &heights, positions: &positions)
            }
        } else {
            for item in quotas {
                let column = shortestColumn(heights)
                append(item, to: column, spacing: spacing, heights: &heights, positions: &positions)
            }
        }

        // There are only five Cost cards, so exhaustive assignment is both
        // cheaper and more accurate than greedy placement. Declaration order
        // remains the vertical order within each column.
        if !costs.isEmpty {
            let columns = bestCostColumns(costs, seededBy: heights, spacing: spacing)
            for (item, column) in zip(costs, columns) {
                append(item, to: column, spacing: spacing, heights: &heights, positions: &positions)
            }
        }

        for item in auxiliary {
            let column = shortestColumn(heights)
            append(item, to: column, spacing: spacing, heights: &heights, positions: &positions)
        }
        return Plan(positions: positions, columnHeights: heights)
    }

    /// Rebuild positions from a previously chosen column assignment while
    /// honoring each item's current height. Interactive card expansion can
    /// therefore push later cards down within the same column without making
    /// any card jump to the other side. Declaration order remains the vertical
    /// order within each phase.
    public static func plan(
        items: [Item],
        fixedColumns: [String: Int],
        columns: Int = 2,
        spacing: Double
    ) -> Plan {
        let columnCount = max(1, columns)
        var positions: [String: Position] = [:]
        var heights = Array(repeating: 0.0, count: columnCount)

        for phase in [Phase.quota, .cost, .auxiliary] {
            for item in items where item.phase == phase {
                let preferred = fixedColumns[item.id] ?? shortestColumn(heights)
                let column = min(max(0, preferred), columnCount - 1)
                append(
                    item,
                    to: column,
                    spacing: spacing,
                    heights: &heights,
                    positions: &positions
                )
            }
        }
        return Plan(positions: positions, columnHeights: heights)
    }

    private static func bestQuotaOrder(_ items: [Item], spacing: Double) -> [Item] {
        var best = items
        var bestScore = quotaScore(items, spacing: spacing)
        for permutation in permutations(items) {
            let score = quotaScore(permutation, spacing: spacing)
            if score.lexicographicallyPrecedes(bestScore) {
                best = permutation
                bestScore = score
            }
        }
        return best
    }

    /// Balance the quota block itself first. The lexicographic tail is a
    /// stable tie-breaker that favors original declaration order.
    private static func quotaScore(_ order: [Item], spacing: Double) -> [Double] {
        let left = stackedHeight(Array(order.prefix(2)), spacing: spacing)
        let right = stackedHeight(Array(order.dropFirst(2)), spacing: spacing)
        return [abs(left - right), max(left, right)]
    }

    private static func bestCostColumns(
        _ items: [Item],
        seededBy seed: [Double],
        spacing: Double
    ) -> [Int] {
        var bestColumns = Array(repeating: 0, count: items.count)
        var bestScore = [Double.infinity, Double.infinity, Double.infinity]
        let combinations = 1 << items.count
        for mask in 0..<combinations {
            var heights = seed
            var columns: [Int] = []
            columns.reserveCapacity(items.count)
            for (index, item) in items.enumerated() {
                let column = (mask >> index) & 1
                columns.append(column)
                heights[column] = appendedHeight(heights[column], item.height, spacing: spacing)
            }
            // Minimize the total waterfall height first, then its ragged
            // bottom edge. The last term makes ties prefer fewer right-column
            // moves, which prevents arbitrary flipping between redraws.
            let score = [
                max(heights[0], heights[1]),
                abs(heights[0] - heights[1]),
                Double(columns.reduce(0, +))
            ]
            if score.lexicographicallyPrecedes(bestScore) {
                bestScore = score
                bestColumns = columns
            }
        }
        return bestColumns
    }

    private static func greedyPlan(items: [Item], columns: Int, spacing: Double) -> Plan {
        var heights = Array(repeating: 0.0, count: columns)
        var positions: [String: Position] = [:]
        for item in items.sorted(by: { $0.phase < $1.phase }) {
            let column = shortestColumn(heights)
            append(item, to: column, spacing: spacing, heights: &heights, positions: &positions)
        }
        return Plan(positions: positions, columnHeights: heights)
    }

    private static func append(
        _ item: Item,
        to column: Int,
        spacing: Double,
        heights: inout [Double],
        positions: inout [String: Position]
    ) {
        let y = heights[column] + (heights[column] > 0 ? spacing : 0)
        positions[item.id] = Position(column: column, y: y)
        heights[column] = y + item.height
    }

    private static func appendedHeight(_ current: Double, _ item: Double, spacing: Double) -> Double {
        current + (current > 0 ? spacing : 0) + item
    }

    private static func stackedHeight(_ items: [Item], spacing: Double) -> Double {
        guard !items.isEmpty else { return 0 }
        return items.reduce(0) { appendedHeight($0, $1.height, spacing: spacing) }
    }

    private static func shortestColumn(_ heights: [Double]) -> Int {
        heights.indices.min { lhs, rhs in
            heights[lhs] == heights[rhs] ? lhs < rhs : heights[lhs] < heights[rhs]
        } ?? 0
    }

    private static func permutations<T>(_ values: [T]) -> [[T]] {
        guard values.count > 1 else { return [values] }
        return values.indices.flatMap { index -> [[T]] in
            var remainder = values
            let head = remainder.remove(at: index)
            return permutations(remainder).map { [head] + $0 }
        }
    }
}

private extension Array where Element == Double {
    func lexicographicallyPrecedes(_ other: [Double]) -> Bool {
        for (lhs, rhs) in zip(self, other) where lhs != rhs {
            return lhs < rhs
        }
        return count < other.count
    }
}
