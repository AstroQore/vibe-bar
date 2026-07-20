import SwiftUI
import VibeBarCore

/// Capsule progress bar with an "expected pace" tick mark.
///
/// Visually identical to `QuotaBarShape` but overlays a compact pace marker at
/// `expectedUsedPercent`. When the actual percent leads the expected line the
/// user is "in deficit" (burning faster than linear); when it lags, the user
/// has reserve.
struct PaceMarkerCapsule: View {
    let usedPercent: Double      // displayed value (already mode-adjusted)
    let expectedPercent: Double  // 0..100 in displayed terms (already mode-adjusted)
    let mode: DisplayMode
    var height: CGFloat = 12
    var forecastLowerPercent: Double? = nil
    var forecastUpperPercent: Double? = nil
    var forecastMedianPercent: Double? = nil

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let pct = clamp(usedPercent, 0, 100) / 100
            let markerPos = clamp(expectedPercent, 0, 100) / 100
            // When the expected line is essentially at the start or end of the
            // bar the tick collapses into the rounded capsule cap and looks
            // like a stray dark sliver. Hide it once it gets within a few
            // percent of either edge — the user can already see the bar's
            // fill is way ahead/behind without it.
            let showMarker = expectedPercent > 3 && expectedPercent < 97
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Theme.barTrack)
                Capsule(style: .continuous)
                    .fill(Theme.barColor(percent: usedPercent, mode: mode))
                    .frame(width: max(height, width * pct))
                if let lower = forecastLowerPercent,
                   let upper = forecastUpperPercent,
                   upper > lower {
                    let start = clamp(lower, 0, 100) / 100
                    let end = clamp(upper, 0, 100) / 100
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.primary.opacity(0.24))
                        .frame(width: max(2, width * (end - start)), height: max(2, height * 0.24))
                        .offset(x: width * start, y: -height * 0.28)
                }
                if let median = forecastMedianPercent,
                   median > 2,
                   median < 98 {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color.primary.opacity(0.48))
                        .frame(width: 1.5, height: max(3, height * 0.42))
                        .offset(x: max(0, min(width - 1.5, width * clamp(median, 0, 100) / 100 - 0.75)), y: -height * 0.27)
                }
                if showMarker {
                    paceMarker
                        .offset(x: max(0, min(width - 7, width * markerPos - 3.5)))
                }
            }
            .clipShape(Capsule(style: .continuous))
        }
        .frame(height: height)
    }

    private var paceMarker: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.black.opacity(0.18))
                .frame(width: 5, height: height)
            RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                .fill(markerColor)
                .frame(width: 2.4, height: max(2, height - 1))
                .shadow(color: Color.black.opacity(0.18), radius: 1.2, y: 0.4)
        }
    }

    private var markerColor: Color {
        Color.primary.opacity(0.72)
    }

    private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
