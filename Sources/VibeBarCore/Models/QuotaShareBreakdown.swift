import Foundation

/// A bucket's used percent broken down by product, ready to draw as the
/// "Used by product" line: one row per product, heaviest first, each with
/// a whole-number share of the pool and its fraction of what was used.
///
/// The whole numbers are apportioned (largest remainder) so they add up to
/// the rounded total — Claude's shares are the week's utilisation split by
/// product and rarely whole, and rounding each on its own made the parts
/// disagree with the sum (4.5 + 1.5 read as 5% · 2%).
public struct QuotaShareBreakdown: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let label: String
        /// Whole points of the pool this product used.
        public let points: Int
        /// Its share of what the pool has used, 0…1 — the segment's width.
        public let fraction: Double
        /// Used something, but less than half a point.
        public var isBelowOnePoint: Bool { points == 0 }

        public init(label: String, points: Int, fraction: Double) {
            self.label = label
            self.points = points
            self.fraction = fraction
        }
    }

    public let rows: [Row]

    /// `nil` when nothing was used: an empty breakdown draws nothing.
    public init?(shares: [QuotaBucketShare]) {
        var order: [String] = []
        var totals: [String: Double] = [:]
        for share in shares where share.usedPercent > 0 {
            let label = SharedPoolSummary.legacyLabels[share.label] ?? share.label
            if totals[label] == nil { order.append(label) }
            totals[label, default: 0] += share.usedPercent
        }
        let sum = totals.values.reduce(0, +)
        guard sum > 0 else { return nil }

        func rank(_ label: String) -> Int {
            SharedPoolSummary.displayOrder.firstIndex { $0.caseInsensitiveCompare(label) == .orderedSame }
                ?? SharedPoolSummary.displayOrder.count
        }
        let labels = order.enumerated().sorted { lhs, rhs in
            let (lu, ru) = (totals[lhs.element] ?? 0, totals[rhs.element] ?? 0)
            if lu != ru { return lu > ru }
            let (lr, rr) = (rank(lhs.element), rank(rhs.element))
            return lr == rr ? lhs.offset < rhs.offset : lr < rr
        }.map(\.element)

        let points = Self.apportion(labels.map { totals[$0] ?? 0 })
        rows = zip(labels, points).map { label, points in
            Row(label: label, points: points, fraction: (totals[label] ?? 0) / sum)
        }
    }

    /// Largest-remainder rounding: whole numbers that add up to the rounded
    /// sum, each within one of its exact value.
    static func apportion(_ values: [Double]) -> [Int] {
        let target = Int(values.reduce(0, +).rounded())
        var floors = values.map { Int($0.rounded(.down)) }
        var missing = target - floors.reduce(0, +)
        let byRemainder = values.indices.sorted {
            let (l, r) = (values[$0] - Double(floors[$0]), values[$1] - Double(floors[$1]))
            return l == r ? $0 < $1 : l > r
        }
        var index = 0
        while missing > 0, !byRemainder.isEmpty {
            floors[byRemainder[index % byRemainder.count]] += 1
            missing -= 1
            index += 1
        }
        return floors
    }
}

/// Segment widths that fit `span` exactly: one point of gap between
/// segments while there is room for a point of colour in each, no gaps once
/// there is not, and never wider than the span either way.
public enum QuotaShareSegments {
    public static func layout(span: CGFloat, fractions: [Double]) -> (widths: [CGFloat], spacing: CGFloat) {
        guard span > 0, !fractions.isEmpty else { return (fractions.map { _ in 0 }, 0) }
        let gaps = CGFloat(fractions.count - 1)
        let spacing: CGFloat = span - gaps >= CGFloat(fractions.count) ? 1 : 0
        let content = max(0, span - gaps * spacing)
        let total = fractions.reduce(0, +)
        let widths = fractions.map { total > 0 ? content * CGFloat($0 / total) : 0 }
        return (widths, spacing)
    }
}
