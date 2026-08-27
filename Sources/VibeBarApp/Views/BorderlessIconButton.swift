import SwiftUI

/// Borderless icon button without focus chrome.
///
/// A real `Button`, not a tap gesture: a gesture-based lookalike can never be
/// activated from the key-view loop or by VoiceOver, however many traits it
/// declares. Plain `Button { … }.buttonStyle(.plain)` on macOS can still
/// render a rounded blue selection background after click, which is why the
/// style here is ``VibeBarButtonStyle`` — it draws no background at all,
/// only the app's own accent hairline when keyboard focus actually reaches
/// the control.
///
/// Optional `rotation` lets callers animate the glyph (used by the header's
/// refresh button).
struct BorderlessIconButton: View {
    let systemImage: String
    let help: String
    var rotation: Double = 0
    var size: CGFloat = 11
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .rotationEffect(.degrees(rotation))
                .foregroundStyle(isEnabled ? .secondary : .tertiary)
                .padding(4)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.vibeBar)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct BorderlessRowButton<Content: View>: View {
    let action: () -> Void
    let content: () -> Content

    init(action: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.action = action
        self.content = content
    }

    var body: some View {
        Button(action: action) {
            content()
                .contentShape(Rectangle())
        }
        .buttonStyle(.vibeBar)
    }
}
