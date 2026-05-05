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
                Text(bucket.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.barColor(percent: percent, mode: mode))
            }
            QuotaBarShape(percent: percent, mode: mode, height: 12)
            HStack {
                if let s = ResetCountdownFormatter.string(from: bucket.resetAt, now: now) {
                    Text("Resets in \(s)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("No reset info")
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
        case .remaining: return "remaining"
        case .used: return "used"
        }
    }
}
