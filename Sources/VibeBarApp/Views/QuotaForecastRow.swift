import SwiftUI
import VibeBarCore

/// Compact, stable-height expression of the two forecast goals: survive the
/// reset window and avoid leaving materially more than the safety target.
struct QuotaForecastRow: View {
    let forecast: QuotaPaceForecast
    let now: Date
    let fontSize: CGFloat
    var showGuidance = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if showGuidance {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        statusLabel
                        Spacer(minLength: 4)
                        confidenceLabel
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        statusLabel
                        confidenceLabel
                    }
                }
            } else {
                statusLabel
            }
            Text(useUpText)
                .font(.system(size: max(8, fontSize - 1), weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if showGuidance {
                Text(forecast.guidanceSummary)
                    .font(.system(size: max(8, fontSize - 1)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusLabel: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(QuotaForecastPalette.color(for: forecast.verdict))
                .frame(width: 5, height: 5)
            Text(primaryText)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(QuotaForecastPalette.color(for: forecast.verdict))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var confidenceLabel: some View {
        Text(forecast.confidenceLabel)
            .font(.system(size: max(8, fontSize - 1)))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var primaryText: String {
        let left = Int(forecast.projectedRemainingPercent.rounded())
        switch forecast.verdict {
        case .enough:
            return "Enough · forecast \(left)% left at reset"
        case .surplus:
            return "Surplus · forecast \(left)% left at reset"
        case .watch:
            return "Watch · forecast \(left)% left at reset"
        case .atRisk:
            return "At risk · likely to run out before reset"
        case .learning:
            return "Learning · about \(left)% left at reset"
        }
    }

    private var useUpText: String {
        if let runOutAt = forecast.runOutAt,
           let countdown = ResetCountdownFormatter.string(from: runOutAt, now: now) {
            return forecast.verdict == .watch
                ? "Could run out in \(countdown)"
                : "Estimated to run out in \(countdown)"
        }
        switch forecast.verdict {
        case .watch:
            return "Use-up time uncertain · may run short before reset"
        case .atRisk:
            return "Expected to run out before reset"
        case .enough, .surplus, .learning:
            return "Projected to last until reset"
        }
    }

}

enum QuotaForecastPalette {
    static func color(for verdict: QuotaPaceForecast.Verdict) -> Color {
        switch verdict {
        case .enough: Color(red: 0.20, green: 0.70, blue: 0.48)
        case .surplus: Color(red: 0.20, green: 0.56, blue: 0.88)
        case .watch: Color(red: 0.96, green: 0.62, blue: 0.20)
        case .atRisk: Color(red: 0.95, green: 0.32, blue: 0.32)
        case .learning: .secondary
        }
    }
}
