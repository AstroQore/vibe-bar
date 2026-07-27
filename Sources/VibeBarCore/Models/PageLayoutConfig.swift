import Foundation

/// Width split between the two columns of a page.
///
/// Three presets rather than a free slider: the popover is narrow, and a
/// continuous ratio makes it trivial to produce an unusable 5 % column.
public enum PageColumnRatio: String, CaseIterable, Codable, Hashable, Sendable {
    case narrowWide = "narrow-wide"
    case equal
    case wideNarrow = "wide-narrow"

    /// What an unknown ratio in `layout.json` decodes to.
    public static let fallback: PageColumnRatio = .equal

    /// Share of the available content width given to the left column, before
    /// inter-column spacing.
    public var leftFraction: Double {
        switch self {
        case .narrowWide: return 0.38
        case .equal:      return 0.5
        case .wideNarrow: return 0.62
        }
    }

    public var rightFraction: Double { 1 - leftFraction }

    public func fraction(forColumn index: Int) -> Double {
        index <= 0 ? leftFraction : rightFraction
    }

    /// Forward-tolerant: a ratio written by a newer build decodes to `.equal`
    /// instead of throwing away the whole page entry.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = PageColumnRatio(rawValue: raw) ?? Self.fallback
    }
}

/// One page's saved layout: the column ratio, the two ordered module columns,
/// and the last-known measured height of each module.
///
/// `measuredHeights` exists for the Settings editor. The editor draws modules
/// as proportional rectangles, and a page the user has not opened this session
/// has never reported a height — without a persisted last-known value the
/// editor would have to render every card as the same featureless block.
///
/// Invariants, enforced by `init` / `setColumns(_:)` / `moving(_:toColumn:at:)`
/// and re-applied on decode:
///
/// - `columns.count == 2` exactly.
/// - No module identifier appears twice, in either column.
/// - `measuredHeights` holds only finite, positive values.
public struct PageLayoutConfig: Hashable, Sendable {
    /// The layout editor is a two-column model by design; the popover is too
    /// narrow for three and one column needs no editor.
    public static let columnCount = 2

    public var ratio: PageColumnRatio
    public private(set) var columns: [[PageLayoutModuleID]]
    public var measuredHeights: [PageLayoutModuleID: Double]

    public init(
        ratio: PageColumnRatio = .equal,
        columns: [[PageLayoutModuleID]] = [],
        measuredHeights: [PageLayoutModuleID: Double] = [:]
    ) {
        self.ratio = ratio
        self.columns = Self.normalized(columns)
        self.measuredHeights = Self.sanitized(measuredHeights)
    }

    // MARK: - Accessors

    public var leftColumn: [PageLayoutModuleID] { columns[0] }
    public var rightColumn: [PageLayoutModuleID] { columns[1] }

    /// Left column first, then right — the reading order the editor uses.
    public var moduleIDs: [PageLayoutModuleID] { columns.flatMap { $0 } }

    /// True when the config carries no layout intent at all. A heights-only
    /// entry (written by `PageLayoutStore.updateMeasuredHeights` for a page the
    /// user has never customized) is empty in this sense, and the resolver
    /// treats it as "not configured".
    public var isEmpty: Bool { columns.allSatisfy(\.isEmpty) }

    public func column(_ index: Int) -> [PageLayoutModuleID] {
        columns[min(max(0, index), Self.columnCount - 1)]
    }

    public func columnIndex(of moduleID: PageLayoutModuleID) -> Int? {
        columns.firstIndex { $0.contains(moduleID) }
    }

    public func measuredHeight(for moduleID: PageLayoutModuleID) -> Double? {
        measuredHeights[moduleID]
    }

    // MARK: - Mutation

    /// Replace both columns, re-applying the two-column and no-duplicate
    /// invariants.
    public mutating func setColumns(_ columns: [[PageLayoutModuleID]]) {
        self.columns = Self.normalized(columns)
    }

    /// Result of dragging `moduleID` to `index` in `column`. The module is
    /// removed from wherever it currently sits first, so a drag can never
    /// duplicate a card. `column` and `index` are clamped into range.
    public func moving(
        _ moduleID: PageLayoutModuleID,
        toColumn column: Int,
        at index: Int
    ) -> PageLayoutConfig {
        var next = columns
        for columnIndex in next.indices {
            next[columnIndex].removeAll { $0 == moduleID }
        }
        let target = min(max(0, column), Self.columnCount - 1)
        let position = min(max(0, index), next[target].count)
        next[target].insert(moduleID, at: position)

        var updated = self
        updated.setColumns(next)
        return updated
    }

    // MARK: - Normalization

    static func normalized(_ columns: [[PageLayoutModuleID]]) -> [[PageLayoutModuleID]] {
        var result = [[PageLayoutModuleID]](repeating: [], count: columnCount)
        var seen = Set<PageLayoutModuleID>()
        for (index, column) in columns.enumerated() {
            // A file written by a build with more columns folds its extras into
            // the last column rather than losing those modules.
            let target = min(index, columnCount - 1)
            for moduleID in column where !moduleID.rawValue.isEmpty {
                guard seen.insert(moduleID).inserted else { continue }
                result[target].append(moduleID)
            }
        }
        return result
    }

    static func sanitized(_ heights: [PageLayoutModuleID: Double]) -> [PageLayoutModuleID: Double] {
        heights.filter { $0.value.isFinite && $0.value > 0 }
    }
}

extension PageLayoutConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case ratio
        case columns
        case measuredHeights
    }

    /// Every field is optional and individually tolerant: a page entry written
    /// by a newer build, or hand-edited into something malformed, degrades to
    /// defaults for that field instead of throwing the whole layout away.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ratio = (try? container.decode(PageColumnRatio.self, forKey: .ratio)) ?? .equal
        let columns = (try? container.decode([[PageLayoutModuleID]].self, forKey: .columns)) ?? []
        let heights = (try? container.decode([PageLayoutModuleID: Double].self, forKey: .measuredHeights)) ?? [:]
        self.init(ratio: ratio, columns: columns, measuredHeights: heights)
    }
}
