import SwiftUI
import VibeBarCore

/// Shared chrome for read-only detail popovers: a fixed heading and close
/// action, one content inset, and a bounded scrolling area owned by the caller.
struct DetailPopoverShell<Content: View>: View {
    let title: String
    let density: Theme.Density
    var tool: ToolType?
    var systemImage = "clock.arrow.circlepath"
    var updatedAt: Date?
    var detail: String?
    var height: CGFloat = 660
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let tool {
                    ToolBrandIconView(tool: tool, size: 18)
                } else {
                    Image(systemName: systemImage).foregroundStyle(.secondary)
                }
                Text(title).font(.system(size: density.titleFontSize, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 10)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                if let updatedAt { Text(updatedAt, style: .relative).font(.caption).foregroundStyle(.secondary) }
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help(L10n.Common.done).keyboardShortcut(.cancelAction)
            }
            Divider()
            content
        }
        .padding(density.cardPadding)
        .frame(width: max(660, density.popoverWidth * 0.70), height: height)
    }
}
