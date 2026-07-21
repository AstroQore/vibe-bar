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
/// status-colored tick marks the projected usage *at reset*. A quiet,
/// full-height flat tint expresses the confidence interval behind both the
/// fill and markers; it is intentionally not a second bar or a gradient.
struct ForecastQuotaBar: View {
    let percent: Double
    let mode: DisplayMode
    let timePacePercent: Double?
    let forecastProjection: QuotaForecastBarProjection
    let forecastColor: Color
    var height: CGFloat = 12

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fillFraction = clamp(percent, 0, 100) / 100
            let lower = forecastProjection.lowerPercent / 100
            let upper = forecastProjection.upperPercent / 100
            let median = forecastProjection.medianPercent / 100
            let timePace = timePacePercent.map { clamp($0, 0, 100) / 100 }
            let forecastLineWidth = max(3.2, min(4.2, height * 0.30))
            let paceMarkerWidth = max(4.5, min(5.5, height * 0.42))
            let minimumBandWidth = forecastLineWidth + 6
            let band = confidenceBandLayout(
                width: width,
                lower: lower,
                upper: upper,
                minimumWidth: minimumBandWidth
            )

            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Theme.barTrack)
                    Capsule(style: .continuous)
                        .fill(Theme.barColor(percent: percent, mode: mode))
                        .frame(width: max(height, width * fillFraction))
                }
                .clipShape(Capsule(style: .continuous))

                if forecastProjection.hasUncertainty {
                    RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                        .fill(forecastColor.opacity(colorScheme == .dark ? 0.22 : 0.15))
                        .overlay {
                            RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                                .stroke(
                                    forecastColor.opacity(colorScheme == .dark ? 0.30 : 0.22),
                                    lineWidth: 0.8
                                )
                        }
                        .frame(width: band.width, height: height)
                        .offset(x: band.x)
                }

                if let timePace, timePacePercent.map({ $0 > 2 && $0 < 98 }) == true {
                    neutralPaceMarker(width: paceMarkerWidth)
                        .frame(width: paceMarkerWidth, height: height)
                        .offset(x: markerOffset(width: width, fraction: timePace, markerWidth: paceMarkerWidth))
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(colorScheme == .dark ? Color.black.opacity(0.82) : Color.white.opacity(0.92))
                        .frame(width: forecastLineWidth + 3, height: height)
                    RoundedRectangle(cornerRadius: forecastLineWidth / 2, style: .continuous)
                        .fill(forecastColor)
                        .frame(width: forecastLineWidth, height: height)
                        .shadow(color: Color.black.opacity(0.30), radius: 0.7)
                }
                .frame(width: forecastLineWidth + 3, height: height)
                .offset(x: markerOffset(width: width, fraction: median, markerWidth: forecastLineWidth + 3))
            }
        }
        .frame(height: height)
    }

    private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    private func markerOffset(width: CGFloat, fraction: Double, markerWidth: CGFloat) -> CGFloat {
        max(0, min(width - markerWidth, width * fraction - markerWidth / 2))
    }

    private func confidenceBandLayout(
        width: CGFloat,
        lower: Double,
        upper: Double,
        minimumWidth: CGFloat
    ) -> (x: CGFloat, width: CGFloat) {
        let naturalStart = width * lower
        let naturalEnd = width * upper
        let naturalWidth = max(0, naturalEnd - naturalStart)
        guard naturalWidth < minimumWidth else {
            return (naturalStart, naturalWidth)
        }
        if lower <= 0 {
            return (0, min(width, minimumWidth))
        }
        if upper >= 1 {
            let bandWidth = min(width, minimumWidth)
            return (max(0, width - bandWidth), bandWidth)
        }
        let bandWidth = min(width, minimumWidth)
        let center = (naturalStart + naturalEnd) / 2
        return (max(0, min(width - bandWidth, center - bandWidth / 2)), bandWidth)
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
