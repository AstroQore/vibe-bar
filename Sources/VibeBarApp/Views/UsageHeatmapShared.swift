import SwiftUI

/// Layout metrics shared by `UsageActivityView`'s bar row and heatmap grid so
/// they line up column-for-column at every popover width.
struct HeatmapGridMetrics {
    let labelWidth: CGFloat
    let cellSide: CGFloat
    let cellSpacing: CGFloat

    /// Pixel width of a 6-hour block at the current cell size, used for the
    /// `0 / 6am / 12pm / 6pm` axis labels.
    var hourBlockWidth: CGFloat {
        cellSide * 6 + cellSpacing * 5
    }

    var cellCornerRadius: CGFloat {
        min(2.5, max(1.5, cellSide * 0.16))
    }

    /// Size of the 7 × 24 cell block — what the per-row `HStack`s used to
    /// measure to on their own, now the frame of the single grid `Canvas`.
    var gridWidth: CGFloat {
        cellSide * 24 + cellSpacing * 23
    }

    var gridHeight: CGFloat {
        cellSide * 7 + cellSpacing * 6
    }

    /// Compute the metrics that fit `availableWidth`. A measured width of 0
    /// (first layout pass before GeometryReader has a real width) falls back
    /// to a conservative 520 pt so a nested popover cannot inflate itself
    /// and then keep measuring the inflated width.
    static func compute(forWidth availableWidth: CGFloat) -> HeatmapGridMetrics {
        let labelWidth: CGFloat = 28
        let cellSpacing: CGFloat = 2
        let fallbackWidth: CGFloat = 520
        let resolvedWidth = availableWidth > 1 ? availableWidth : fallbackWidth
        let usableWidth = max(0, resolvedWidth - labelWidth - cellSpacing * 24)
        let rawSide = usableWidth / 24
        let cellSide = min(max(rawSide, 9), 30)
        return HeatmapGridMetrics(
            labelWidth: labelWidth,
            cellSide: cellSide,
            cellSpacing: cellSpacing
        )
    }
}

/// PreferenceKey used by `UsageActivityView` to read the GeometryReader width
/// without triggering a layout loop.
struct HeatmapGridWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Which cell a hover point lands on in a uniform `side + spacing` grid.
///
/// Both heatmaps draw their cells into a single `Canvas` rather than one view
/// per cell, so the per-cell `.help()` tooltip is reproduced by hit-testing the
/// hover location against the same geometry the canvas drew with. Returns `nil`
/// in the gaps between cells, because the old per-cell tooltip only covered the
/// filled square.
func heatmapCellIndex(for offset: CGFloat, side: CGFloat, spacing: CGFloat, count: Int) -> Int? {
    let step = side + spacing
    guard step > 0, side > 0, offset >= 0 else { return nil }
    let index = Int(offset / step)
    guard index >= 0, index < count else { return nil }
    guard offset - CGFloat(index) * step <= side else { return nil }
    return index
}

/// Continuous faint-blue → warm-orange gradient. `intensity` is clamped to 0…1.
/// Opacity also rises with intensity so 0-value cells stay almost invisible.
func intensityColor(intensity: Double) -> Color {
    let clamped = min(max(intensity, 0), 1)
    let r = 0.42 + (0.97 - 0.42) * clamped
    let g = 0.60 - (0.60 - 0.55) * clamped
    let b = 0.97 - (0.97 - 0.20) * clamped
    return Color(red: r, green: g, blue: b).opacity(0.35 + 0.65 * clamped)
}
