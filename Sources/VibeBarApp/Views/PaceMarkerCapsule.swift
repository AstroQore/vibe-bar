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
/// status-colored tick marks the projected usage *at reset*. The confidence
/// interval is a full-height capsule. It is opaque in ordinary geometry, uses
/// a soft overlap or curved endpoint seam for the two Used-mode contact cases,
/// and switches to an outlined tint when every mark crowds the lower axis. It
/// is intentionally not a second bar or a gradient.
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
            let median = forecastProjection.medianPercent / 100
            let timePace = timePacePercent.map { clamp($0, 0, 100) / 100 }
            let forecastLineWidth = max(3.2, min(4.2, height * 0.30))
            let paceMarkerWidth = max(4.5, min(5.5, height * 0.42))
            let minimumBandWidth = forecastLineWidth + 6
            let band = forecastProjection.confidenceBandLayout(
                actualDisplayedPercent: clamp(percent, 0, 100),
                minimumVisibleWidthPercent: width > 0 ? minimumBandWidth / width * 100 : 100,
                contactTolerancePercent: width > 0 ? 0.5 / width * 100 : 100
            )
            let naturalBandX = width * band.startPercent / 100
            let naturalBandWidth = width * band.widthPercent / 100
            let softJoinOverlap = band.style == .softJoin
                ? min(height / 2, naturalBandX)
                : 0
            let bandX = naturalBandX - softJoinOverlap
            let bandWidth = naturalBandWidth + softJoinOverlap
            let bandOverlapWidth = band.style == .softJoin
                ? softJoinOverlap
                : width * band.overlapPercent / 100
            let actualFillWidth = min(width, max(height, width * fillFraction))
            let connectorCapOverlap = height / 2
            let connectorStartX = max(0, actualFillWidth - connectorCapOverlap)
            let connectorEndX = min(width, bandX + connectorCapOverlap)
            let connectorWidth = max(0, connectorEndX - connectorStartX)
            let seamWidth = min(3, max(2, height * 0.25))
            let actualColor = Theme.barColor(percent: percent, mode: mode)
            let visibleForecastColor = colorScheme == .dark
                ? forecastColor.mix(with: .white, by: 0.16)
                : forecastColor

            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Theme.barTrack)

                    if forecastProjection.hasUncertainty,
                       band.showsGapConnector,
                       connectorWidth > 0.5
                    {
                        Capsule(style: .continuous)
                            .fill(visibleForecastColor.opacity(colorScheme == .dark ? 0.34 : 0.24))
                            .frame(width: connectorWidth, height: max(1.5, min(2.5, height * 0.18)))
                            .offset(x: connectorStartX)
                    }

                    Capsule(style: .continuous)
                        .fill(Theme.barColor(percent: percent, mode: mode))
                        .frame(width: actualFillWidth)
                }
                .clipShape(Capsule(style: .continuous))

                if forecastProjection.hasUncertainty {
                    confidenceBand(
                        style: band.style,
                        actualColor: actualColor,
                        overlapWidth: bandOverlapWidth,
                        seamWidth: seamWidth,
                        visibleForecastColor: visibleForecastColor
                    )
                    .frame(width: bandWidth, height: height, alignment: .leading)
                    .offset(x: bandX)
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
                        .fill(visibleForecastColor)
                        .frame(width: forecastLineWidth, height: height)
                        .shadow(color: Color.black.opacity(0.30), radius: 0.7)
                }
                .frame(width: forecastLineWidth + 3, height: height)
                .offset(x: markerOffset(width: width, fraction: median, markerWidth: forecastLineWidth + 3))
            }
        }
        .frame(height: height)
    }

    @ViewBuilder
    private func confidenceBand(
        style: QuotaForecastBandStyle,
        actualColor: Color,
        overlapWidth: CGFloat,
        seamWidth: CGFloat,
        visibleForecastColor: Color
    ) -> some View {
        switch style {
        case .outlinedTint:
            ZStack(alignment: .trailing) {
                Capsule(style: .continuous)
                    .fill(visibleForecastColor.opacity(colorScheme == .dark ? 0.30 : 0.18))
                Capsule(style: .continuous)
                    .strokeBorder(visibleForecastColor.opacity(0.88), lineWidth: 1)
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(visibleForecastColor.opacity(0.95))
                    .frame(width: 2, height: max(4, height - 4))
                    .padding(.trailing, 1)
            }

        case .softJoin:
            Capsule(style: .continuous)
                .fill(visibleForecastColor)

        case .opaque:
            solidConfidenceBand(
                actualColor: actualColor,
                overlapWidth: overlapWidth,
                seamWidth: seamWidth,
                showsCurvedSeam: false,
                visibleForecastColor: visibleForecastColor
            )

        case .curvedSeam:
            solidConfidenceBand(
                actualColor: actualColor,
                overlapWidth: overlapWidth,
                seamWidth: seamWidth,
                showsCurvedSeam: true,
                visibleForecastColor: visibleForecastColor
            )
        }
    }

    private func solidConfidenceBand(
        actualColor: Color,
        overlapWidth: CGFloat,
        seamWidth: CGFloat,
        showsCurvedSeam: Bool,
        visibleForecastColor: Color
    ) -> some View {
        ZStack(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(visibleForecastColor)

            if showsCurvedSeam {
                Capsule(style: .continuous)
                    .fill(confidenceSeamColor)
                    .frame(width: overlapWidth + seamWidth)
            }

            if overlapWidth > 0.5 {
                Capsule(style: .continuous)
                    .fill(actualColor.mix(with: visibleForecastColor, by: 0.42))
                    .frame(width: overlapWidth)
            }
        }
    }

    private var confidenceSeamColor: Color {
        colorScheme == .dark ? .black : .white
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
