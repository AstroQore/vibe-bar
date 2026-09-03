import SwiftUI
import VibeBarCore

struct QuotaBucketView: View {
    let bucket: QuotaBucket
    let mode: DisplayMode
    let now: Date

    var body: some View {
        let percent = bucket.displayPercent(mode)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(QuotaGroupLabelLocalizer.display(bucket.title))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(L10n.Common.percent(value: Int(percent.rounded())))
                    .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.barColor(percent: percent, mode: mode))
            }
            QuotaBarShape(percent: percent, mode: mode, height: 12)
            HStack {
                if let s = ResetCountdownFormatter.stringWithAbsoluteTime(from: bucket.resetAt, now: now) {
                    Text(L10n.Quota.bucketResetsIn(when: s))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text(L10n.Quota.bucketNoResetInfo)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(modeCaption(mode))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func modeCaption(_ mode: DisplayMode) -> String {
        switch mode {
        case .remaining: return L10n.Quota.modeRemaining
        case .used: return L10n.Quota.modeUsed
        }
    }
}
