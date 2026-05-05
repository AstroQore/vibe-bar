import SwiftUI
import AppKit
import VibeBarCore

struct ActionButtonRow: View {
    @EnvironmentObject var environment: AppEnvironment
    var onToggleMiniWindow: () -> Void
    var onShowSettings: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ActionPill(title: "Refresh", systemImage: "arrow.clockwise") {
                    environment.refreshAll()
                }
                ActionPill(title: "Mini", systemImage: "rectangle.on.rectangle") {
                    onToggleMiniWindow()
                }
                ActionPill(title: "Settings", systemImage: "gearshape") {
                    onShowSettings()
                }
                ActionPill(title: "Quit", systemImage: "power") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }
}

private struct ActionPill: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.primary)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .glassEffect(
            .regular.interactive(),
            in: .rect(cornerRadius: Theme.glassPillCornerRadius)
        )
    }
}
