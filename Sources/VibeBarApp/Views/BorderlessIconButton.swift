import SwiftUI

/// Borderless icon button without focus chrome.
///
/// Plain `Button { … }.buttonStyle(.plain)` on macOS can still render a
/// rounded blue selection background after click. This clickable icon keeps
/// the same hit area without becoming key-view focus chrome.
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
        Image(systemName: systemImage)
            .font(.system(size: size, weight: .semibold))
            .rotationEffect(.degrees(rotation))
            .foregroundStyle(isEnabled ? .secondary : .tertiary)
            .padding(4)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .onTapGesture {
                guard isEnabled else { return }
                action()
            }
            .help(help)
            .accessibilityLabel(help)
            .accessibilityAddTraits(.isButton)
    }
}

struct BorderlessRowButton<Content: View>: View {
    let action: () -> Void
    let content: () -> Content

    @Environment(\.isEnabled) private var isEnabled

    init(action: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.action = action
        self.content = content
    }

    var body: some View {
        content()
            .contentShape(Rectangle())
            .onTapGesture {
                guard isEnabled else { return }
                action()
            }
            .accessibilityAddTraits(.isButton)
    }
}
