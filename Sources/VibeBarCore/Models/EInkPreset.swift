import Foundation

/// The layouts the panel can draw. Each one draws in both a landscape
/// (296 × 152) and a portrait (152 × 296) arrangement.
///
/// The first eight are the verified Dot. demo ports; the five after them come
/// from the owner's round 2 review, which asked for content that answers a
/// question rather than restating a number ("am I on pace", "when does
/// anything reset", "when do I actually work"). `alert` is the engine's own
/// and is never offered in the picker — see `userSelectable`.
public enum EInkPreset: String, Codable, CaseIterable, Sendable {
    case quotaLedger
    case quotaRings
    case quotaRail
    case usageTiles
    case usageSplit
    case usageTable
    case usageDual
    case usageTrend
    case briefing
    case forecast
    case resets
    case heatmap
    case topModels
    /// Pushed by the sync engine when a bucket crosses its alert threshold,
    /// with `border: 1`. Not a layout the user places on a slide.
    case alert

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
        case .quotaLedger, .quotaRings, .quotaRail, .briefing, .forecast, .resets: .quotaFields
        case .usageTiles, .usageSplit: .usagePeriods
        case .usageTable, .usageDual: .harnessRows
        // A heatmap is the whole week, the top models are the top models, and
        // the alert names the one bucket that tripped it. None of the three
        // has a subset worth picking.
        case .heatmap, .topModels, .alert: SelectionAxis.none
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
        // Landscape briefing wraps a name that will not fit onto a second
        // line rather than cutting it (`EInkPresets.briefing`), and a wrapped
        // row is twice as tall. Six was the count for one-line rows only, so a
        // panel showing three-tier names was choosing between a clipped name
        // and a row pushed off the bottom; four is what the panel holds in
        // either form.
        case .briefing: return portrait ? 8 : 4
        case .forecast: return portrait ? 6 : 4
        case .resets: return portrait ? 7 : 5
        case .heatmap, .topModels, .alert: return 1
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
        case .briefing: "Briefing"
        case .forecast: "Forecast"
        case .resets: "Resets"
        case .heatmap: "Heatmap"
        case .topModels: "Top Models"
        case .alert: "Alert"
        }
    }

    public var isQuotaPreset: Bool { selectionAxis == .quotaFields }

    /// Everything a slide may be set to. `alert` is the engine's and appears
    /// in no picker: it names one bucket that just tripped a threshold, which
    /// is not something a user can place in advance.
    public static var userSelectable: [EInkPreset] { allCases.filter { $0 != .alert } }

    /// How many rows the layout prints when nothing is selectable — the
    /// heatmap's weekdays, the top model list.
    public func rowCount(for orientation: EInkOrientation) -> Int {
        switch self {
        case .topModels: orientation.isPortrait ? 7 : 5
        default: capacity(for: orientation)
        }
    }

    /// Whether drawing this layout needs the usage ledger at all. The three
    /// quota layouts do not, which is what lets a quota-only device keep
    /// pushing when the ledger is unreadable.
    public var needsUsageData: Bool {
        switch self {
        // Briefing prints today's and the week's spend under its quota lines,
        // and the heatmap and the model table are nothing else.
        case .briefing, .heatmap, .topModels: return true
        // Forecast, resets and the alert are quota only, so a device showing
        // them keeps pushing when the ledger will not open.
        case .forecast, .resets, .alert: return false
        default: return !isQuotaPreset
        }
    }
}
