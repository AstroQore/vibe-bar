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

/// Current quota with a forecast interval integrated into the same capsule.
///
/// The actual fill remains the dominant layer. The forecast uses one coherent
/// visual vocabulary: a soft, full-height interval band plus one color-matched
/// endpoint. The matching labeled row directly below supplies the meaning.
struct ForecastQuotaBar: View {
    let percent: Double
    let mode: DisplayMode
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
            let inset = max(1.5, height * 0.14)
            let endpointSize = min(7, max(5, height * 0.52))

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Theme.barTrack)
                Capsule(style: .continuous)
                    .fill(Theme.barColor(percent: percent, mode: mode))
                    .frame(width: max(height, width * fillFraction))

                if upper > lower {
                    RoundedRectangle(
                        cornerRadius: max(2, (height - inset * 2) / 2),
                        style: .continuous
                    )
                    .fill(
                        LinearGradient(
                            colors: [
                                forecastColor.opacity(0.10),
                                forecastColor.opacity(0.28),
                                forecastColor.opacity(0.10),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: max(2, (height - inset * 2) / 2),
                            style: .continuous
                        )
                        .stroke(forecastColor.opacity(0.24), lineWidth: 0.75)
                    }
                    .frame(
                        width: max(endpointSize, width * (upper - lower)),
                        height: max(3, height - inset * 2)
                    )
                    .offset(x: width * lower)
                }

                Circle()
                    .fill(forecastColor)
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.72), lineWidth: 1)
                    }
                    .shadow(color: Color.black.opacity(0.18), radius: 1.5, y: 0.5)
                    .frame(width: endpointSize, height: endpointSize)
                    .offset(
                        x: max(1, min(width - endpointSize - 1, width * median - endpointSize / 2))
                    )
            }
            .clipShape(Capsule(style: .continuous))
        }
        .frame(height: height)
    }

    private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
