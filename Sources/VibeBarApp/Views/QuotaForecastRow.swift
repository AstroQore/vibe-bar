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
        // One nested fragment rather than four sentences × two modes: the
        // figure is the only part that changes between Remaining and Used,
        // and both languages put it in the same slot.
        let forecastValue = displayMode == .remaining
            ? L10n.Quota.forecastValueLeft(percent: left)
            : L10n.Quota.forecastValueUsed(percent: used)
        switch forecast.verdict {
        case .enough:
            return L10n.Quota.forecastStatusEnough(value: forecastValue)
        case .surplus:
            return L10n.Quota.forecastStatusSurplus(value: forecastValue)
        case .watch:
            return L10n.Quota.forecastStatusWatch(value: forecastValue)
        case .atRisk:
            return L10n.Quota.forecastStatusAtRisk
        case .learning:
            return L10n.Quota.forecastStatusLearning(value: forecastValue)
        }
    }

    private var useUpText: String {
        if let runOutAt = forecast.runOutAt,
           let countdown = ResetCountdownFormatter.string(from: runOutAt, now: now) {
            return forecast.verdict == .watch
                ? L10n.Quota.forecastUseUpCouldRunOut(countdown: countdown)
                : L10n.Quota.forecastUseUpEstimated(countdown: countdown)
        }
        switch forecast.verdict {
        case .watch:
            return L10n.Quota.forecastUseUpUncertain
        case .atRisk:
            return L10n.Quota.forecastUseUpBeforeReset
        case .enough, .surplus, .learning:
            return L10n.Quota.forecastUseUpLastsUntilReset
        }
    }

    private var guidanceText: String {
        guard displayMode == .used else { return forecast.guidanceSummary }
        let usedTarget = Int((100 - forecast.targetRemainingPercent).rounded())
        let unused = Int(forecast.potentialUnusedPercent.rounded())
        if forecast.verdict == .atRisk { return L10n.Quota.forecastGuidanceAtRisk }
        if forecast.verdict == .watch { return L10n.Quota.forecastGuidanceWatch }
        if forecast.verdict == .surplus {
            return L10n.Quota.forecastGuidanceUsedSurplus(unused: unused, target: usedTarget)
        }
        if unused >= 3 {
            return L10n.Quota.forecastGuidanceUsedAvailable(target: usedTarget, unused: unused)
        }
        return L10n.Quota.forecastGuidanceUsedWithinTarget(target: usedTarget)
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
