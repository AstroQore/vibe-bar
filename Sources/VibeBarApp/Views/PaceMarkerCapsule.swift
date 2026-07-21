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

/// Current quota with wall-clock pace and reset forecast integrated into the
/// same capsule.
///
/// The actual fill remains the dominant layer. A short gray tick marks where
/// usage should be *now* under a time-only pace. A taller status-colored tick
/// marks the projected usage *at reset*. The matching color gradient hugs the
/// bottom edge and expresses the forecast interval without obscuring the fill.
struct ForecastQuotaBar: View {
    let percent: Double
    let mode: DisplayMode
    let timePacePercent: Double?
    let forecastLowerPercent: Double
    let forecastUpperPercent: Double
    let forecastMedianPercent: Double
    let forecastColor: Color
    var height: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fillFraction = clamp(percent, 0, 100) / 100
            let lower = clamp(min(forecastLowerPercent, forecastUpperPercent), 0, 100) / 100
            let upper = clamp(max(forecastLowerPercent, forecastUpperPercent), 0, 100) / 100
            let median = clamp(forecastMedianPercent, 0, 100) / 100
            let timePace = timePacePercent.map { clamp($0, 0, 100) / 100 }
            let intervalHeight = max(2.5, height * 0.28)
            let forecastLineWidth = max(2, min(3, height * 0.22))
            let paceLineWidth = max(1, min(1.5, height * 0.11))

            ZStack(alignment: .bottomLeading) {
                Capsule(style: .continuous)
                    .fill(Theme.barTrack)
                Capsule(style: .continuous)
                    .fill(Theme.barColor(percent: percent, mode: mode))
                    .frame(width: max(height, width * fillFraction))

                if upper > lower {
                    RoundedRectangle(cornerRadius: intervalHeight / 2, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                forecastColor.opacity(0.08),
                                forecastColor.opacity(0.48),
                                forecastColor.opacity(0.20),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(
                        width: max(forecastLineWidth * 2, width * (upper - lower)),
                        height: intervalHeight
                    )
                    .offset(x: width * lower)
                }

                if let timePace, timePacePercent.map({ $0 > 2 && $0 < 98 }) == true {
                    RoundedRectangle(cornerRadius: paceLineWidth / 2, style: .continuous)
                        .fill(Color.secondary.opacity(0.78))
                        .frame(width: paceLineWidth, height: max(4, height * 0.62))
                        .offset(x: markerOffset(width: width, fraction: timePace, markerWidth: paceLineWidth))
                        .padding(.bottom, max(1, height * 0.18))
                }

                RoundedRectangle(cornerRadius: forecastLineWidth / 2, style: .continuous)
                    .fill(forecastColor)
                    .frame(width: forecastLineWidth, height: max(5, height * 0.90))
                    .offset(x: markerOffset(width: width, fraction: median, markerWidth: forecastLineWidth))
                    .padding(.bottom, max(0.5, height * 0.05))
            }
            .clipShape(Capsule(style: .continuous))
        }
        .frame(height: height)
    }

    private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    private func markerOffset(width: CGFloat, fraction: Double, markerWidth: CGFloat) -> CGFloat {
        max(0, min(width - markerWidth, width * fraction - markerWidth / 2))
    }
}
