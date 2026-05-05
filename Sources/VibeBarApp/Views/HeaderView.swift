import SwiftUI
import VibeBarCore

/// Single-line popover header: title left, plan badge + refresh button right.
/// No email column; that information lives in Settings if needed.
struct HeaderView: View {
    let title: String
    let subtitle: String?
    let plan: String?
    let lastUpdated: Date?
    let isRefreshing: Bool
    let titleFontSize: CGFloat
    let subtitleFontSize: CGFloat
    let accessory: AnyView?
    let onRefresh: () -> Void
    let onShowSettings: () -> Void

    @State private var rotation: Double = 0

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: titleFontSize, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(2)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(updatedSummary(now: context.date))
                        .font(.system(size: subtitleFontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(2)
            Spacer(minLength: 6)
            if let accessory {
                accessory
                    .layoutPriority(1)
            }
            if let plan, !plan.isEmpty {
                Text(plan)
                    .font(.system(size: max(9, subtitleFontSize - 1), weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .fixedSize()
            }
            BorderlessIconButton(
                systemImage: "arrow.clockwise",
                help: "Refresh",
                rotation: rotation,
                size: max(11, subtitleFontSize),
                action: refreshTapped
            )
            BorderlessIconButton(
                systemImage: "gearshape",
                help: "Settings",
                size: max(11, subtitleFontSize),
                action: onShowSettings
            )
        }
    }

    private func refreshTapped() {
        if !isRefreshing {
            withAnimation(.easeInOut(duration: 0.5)) {
                rotation += 360
            }
        }
        onRefresh()
    }

    private func updatedSummary(now: Date) -> String {
        if isRefreshing { return "Refreshing…" }
        let base = ResetCountdownFormatter.updatedAgo(from: lastUpdated, now: now)
        if let subtitle, !subtitle.isEmpty {
            return "\(subtitle) · \(base)"
        }
        return base
    }
}
