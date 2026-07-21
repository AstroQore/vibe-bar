import SwiftUI
import VibeBarCore

/// Compact, stable-height expression of the two forecast goals: survive the
/// reset window and avoid leaving materially more than the safety target.
struct QuotaForecastRow: View {
    let forecast: QuotaPaceForecast
    let now: Date
    let fontSize: CGFloat
    var showGuidance = false
    var displayMode: DisplayMode = .remaining

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
                Text(guidanceText)
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
        let used = Int(forecast.projectedUsedPercent.rounded())
        let forecastValue = displayMode == .remaining ? "\(left)% left" : "\(used)% used"
        switch forecast.verdict {
        case .enough:
            return "Enough · forecast \(forecastValue) at reset"
        case .surplus:
            return "Surplus · forecast \(forecastValue) at reset"
        case .watch:
            return "Watch · forecast \(forecastValue) at reset"
        case .atRisk:
            return "At risk · likely to run out before reset"
        case .learning:
            return "Learning · about \(forecastValue) at reset"
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

    private var guidanceText: String {
        guard displayMode == .used else { return forecast.guidanceSummary }
        let usedTarget = Int((100 - forecast.targetRemainingPercent).rounded())
        let unused = Int(forecast.potentialUnusedPercent.rounded())
        if forecast.verdict == .atRisk { return "Slow down or shift work to another quota" }
        if forecast.verdict == .watch { return "Recent usage is above the safe range" }
        if forecast.verdict == .surplus {
            return "About \(unused)% capacity may remain beyond the \(usedTarget)% used target"
        }
        if unused >= 3 {
            return "Target \(usedTarget)% used · about \(unused)% capacity available"
        }
        return "Within the \(usedTarget)% used target"
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
