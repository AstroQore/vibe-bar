import Foundation

/// The eight layouts ported from the verified Dot. demo. Each one draws in
/// both a landscape (296 × 152) and a portrait (152 × 296) arrangement.
public enum EInkPreset: String, Codable, CaseIterable, Sendable {
    case quotaLedger
    case quotaRings
    case quotaRail
    case usageTiles
    case usageSplit
    case usageTable
    case usageDual
    case usageTrend

    /// Which list the slide's selection applies to.
    public enum SelectionAxis: String, Sendable {
        /// Quota buckets, picked by `MenuBarFieldCatalog` field ID.
        case quotaFields
        /// The four usage windows.
        case usagePeriods
        /// Per-harness rows, taken from the snapshot in cost order.
        case harnessRows
        /// Nothing to pick. The layout's content is fixed by what it is, so
        /// the settings UI must not offer a selection for it at all.
        case none
    }

    public var selectionAxis: SelectionAxis {
        switch self {
        case .quotaLedger, .quotaRings, .quotaRail: .quotaFields
        case .usageTiles, .usageSplit: .usagePeriods
        case .usageTable, .usageDual: .harnessRows
        // Trend draws today plus the last seven days, always. There is no
        // meaningful subset of that — a "trend" of one bucket is a number —
        // so the slide's period selection does not apply to it.
        case .usageTrend: SelectionAxis.none
        }
    }

    /// How many items of `selectionAxis` the layout has room for. Fewer than
    /// the capacity is always allowed — the layout packs what it is given and
    /// leaves no empty slot. A preset with no axis reports 1: it draws one
    /// screen, and there is nothing to choose.
    public func capacity(for orientation: EInkOrientation) -> Int {
        let portrait = orientation.isPortrait
        switch self {
        case .quotaLedger, .quotaRings, .quotaRail: return portrait ? 6 : 5
        case .usageTiles: return 4
        case .usageSplit: return 3
        case .usageTable: return 5
        case .usageDual: return portrait ? 5 : 4
        case .usageTrend: return 1
        }
    }

    /// English identifier used in logs and in the task alias sent to the
    /// device. User-visible naming lands with the settings UI in phase 2.
    public var identifierName: String {
        switch self {
        case .quotaLedger: "Quota · Ledger"
        case .quotaRings: "Quota · Rings"
        case .quotaRail: "Quota · Rail"
        case .usageTiles: "Usage · Tiles"
        case .usageSplit: "Usage · Split"
        case .usageTable: "Usage · Table"
        case .usageDual: "Usage · Dual Bars"
        case .usageTrend: "Usage · Trend"
        }
    }

    public var isQuotaPreset: Bool { selectionAxis == .quotaFields }
}
