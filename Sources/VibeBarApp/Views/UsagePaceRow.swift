import SwiftUI
import VibeBarCore

/// One-line pace summary shown beneath each bucket bar.
/// Format: "{stage} · {ETA}" — e.g. "On pace · Lasts until reset", "5% in deficit · Runs out in 1h 30m".
struct UsagePaceRow: View {
    let pace: UsagePace
    let now: Date
    let fontSize: CGFloat

    init(pace: UsagePace, now: Date = Date(), fontSize: CGFloat = 10) {
        self.pace = pace
        self.now = now
        self.fontSize = fontSize
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(stageColor)
                .frame(width: 5, height: 5)
            Text(pace.stageSummary)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(stageColor)
            if let detail = etaText {
                Text("·")
                    .font(.system(size: fontSize))
                    .foregroundStyle(.tertiary)
                Text(detail)
                    .font(.system(size: fontSize))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// Color encodes whether the user is in reserve (good, behind linear) or
    /// in deficit (bad, ahead of linear). Magnitude bumps the saturation:
    ///   - in reserve → green shades (more reserve is better)
    ///   - in deficit → amber → orange → red (more deficit is worse)
    /// On-pace stays neutral.
    private var stageColor: Color {
        switch pace.stage {
        case .onTrack:
            return .secondary
        case .slightlyBehind:
            return Color(red: 0.40, green: 0.78, blue: 0.50)   // light green
        case .behind:
            return Color(red: 0.25, green: 0.72, blue: 0.45)   // green
        case .farBehind:
            return Color(red: 0.18, green: 0.62, blue: 0.40)   // deep green
        case .slightlyAhead:
            return Color(red: 0.96, green: 0.78, blue: 0.30)   // amber
        case .ahead:
            return Color(red: 0.97, green: 0.55, blue: 0.20)   // orange
        case .farAhead:
            return Color(red: 0.95, green: 0.32, blue: 0.32)   // red
        }
    }

    private var etaText: String? {
        if pace.willLastToReset {
            return "Lasts until reset"
        }
        guard let etaSeconds = pace.etaSeconds, etaSeconds > 0 else { return nil }
        let target = now.addingTimeInterval(etaSeconds)
        guard let countdown = ResetCountdownFormatter.string(from: target, now: now) else {
            return nil
        }
        return "Runs out in \(countdown)"
    }
}
