import SwiftUI
import VibeBarCore

/// One selection treatment for popover cards, preset mini cells, free canvas
/// elements and menu-bar groups. Radius is independent of the window shell.
struct StudioSelectionOutline: View {
    var isSelected = true
    var isLifted = false
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.accentColor.opacity(isSelected ? 0.06 : 0.035))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(isSelected ? 0.9 : 0.6), lineWidth: 1.5)
            }
            .scaleEffect(isLifted ? 1.015 : 1)
            .allowsHitTesting(false)
    }
}

/// Card dragging leaves real header controls and an active text editor alone.
struct StudioSurfaceHitShape: Shape {
    var headerHeight: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY + headerHeight,
                    width: rect.width, height: max(0, rect.height - headerHeight)))
    }
}

/// Records the exact rendered label bounds; editing stays in the Studio's
/// interaction layer so it does not add controls to a production mini window.
struct StudioMiniLabel: View {
    let text: String
    let key: String?
    var isGroup = false
    @State private var owner = UUID()
    @Environment(\.surfaceItemFrames) private var frames

    var body: some View {
        if let frames, let key {
            Text(text)
                .help(L10n.Settings.Layout.inlineEditHint)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SurfaceCoordinates.space)) } action: { rect in
                    frames.reportLabel(.init(key: key, text: text, isGroup: isGroup, frame: rect, owner: owner))
                }
                .onChange(of: text) { _, value in
                    frames.updateLabel(key: key, text: value, isGroup: isGroup, owner: owner)
                }
                .onDisappear { frames.forgetLabel(key: key, isGroup: isGroup, owner: owner) }
        } else { Text(text) }
    }
}
