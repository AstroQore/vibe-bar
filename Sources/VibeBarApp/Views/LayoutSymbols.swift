import SwiftUI
import VibeBarCore

/// The one table of glyphs the layout editors and the Layout Studio share for
/// a page's arranging mode and a mini window's style, so the same choice
/// looks the same in Settings and on the stage.
extension PageLayoutMode {
    var symbolName: String {
        switch self {
        case .auto:    return "wand.and.stars"
        case .compact: return "arrow.down.forward.and.arrow.up.backward"
        case .manual:  return "hand.point.up.left"
        }
    }
}

extension MiniWindowDisplayMode {
    var symbolName: String {
        switch self {
        case .regular: return "circle.grid.2x2"
        case .compact: return "chart.bar"
        case .ledger:  return "list.bullet"
        case .strip:   return "rectangle.split.3x1"
        case .tile:    return "square.grid.3x2"
        case .focus:   return "scope"
        case .rail:    return "timeline.selection"
        }
    }

    /// Styles whose cells are laid out in a reading order the Studio can
    /// re-arrange by dragging. Focus pages through its buckets and Rail sorts
    /// them by time, so neither has a place to drop a cell.
    var supportsStageArranging: Bool {
        switch self {
        case .regular, .compact, .ledger, .strip, .tile: return true
        case .focus, .rail: return false
        }
    }

    /// The axis a style's reading order runs along, for the drop rule.
    var stageAxis: StudioArranging.Axis {
        self == .ledger ? .vertical : .horizontal
    }
}
