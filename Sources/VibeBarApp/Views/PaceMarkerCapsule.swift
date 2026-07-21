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
/// The actual fill remains the dominant layer. A substantial neutral tick
/// marks where usage should be *now* under a time-only pace. A
/// status-colored tick marks the projected usage *at reset*. A soft,
/// full-height gradient expresses the confidence interval as one integrated
/// layer rather than looking like a second progress bar below the quota.
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
            let forecastLineWidth = max(2.5, min(3.5, height * 0.25))
            let paceMarkerWidth = max(4.5, min(5.5, height * 0.42))

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Theme.barTrack)
                Capsule(style: .continuous)
                    .fill(Theme.barColor(percent: percent, mode: mode))
                    .frame(width: max(height, width * fillFraction))

                if upper > lower {
                    Rectangle()
                        .fill(
                        LinearGradient(
                            colors: [
                                forecastColor.opacity(0.06),
                                forecastColor.opacity(0.26),
                                forecastColor.opacity(0.42),
                                forecastColor.opacity(0.26),
                                forecastColor.opacity(0.06),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(
                        width: max(forecastLineWidth * 2, width * (upper - lower)),
                        height: height
                    )
                    .offset(x: width * lower)
                }

                if let timePace, timePacePercent.map({ $0 > 2 && $0 < 98 }) == true {
                    neutralPaceMarker(width: paceMarkerWidth)
                        .frame(width: paceMarkerWidth, height: height)
                        .offset(x: markerOffset(width: width, fraction: timePace, markerWidth: paceMarkerWidth))
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.black.opacity(0.12))
                        .frame(width: forecastLineWidth + 2, height: height)
                    RoundedRectangle(cornerRadius: forecastLineWidth / 2, style: .continuous)
                        .fill(forecastColor)
                        .frame(width: forecastLineWidth, height: max(4, height - 1))
                }
                .frame(width: forecastLineWidth + 2, height: height)
                .offset(x: markerOffset(width: width, fraction: median, markerWidth: forecastLineWidth + 2))
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

    private func neutralPaceMarker(width: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.black.opacity(0.16))
                .frame(width: width, height: height)
            RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                .fill(Color.primary.opacity(0.62))
                .frame(width: max(2.2, width * 0.46), height: max(4, height - 1))
        }
    }
}
