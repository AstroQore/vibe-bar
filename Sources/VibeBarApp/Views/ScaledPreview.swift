import SwiftUI
import VibeBarCore

/// A real view, drawn at its natural size and shrunk to fit a width.
///
/// Settings has room for a picture of a surface, not for the surface itself:
/// a mini window lays out at the width its panel opens at and a Workbench page
/// at the width of a window. Constraining either with `.frame(width:)` does not
/// make it narrower — it lays out at its own width and spills over whatever is
/// beside it. So it is measured at its natural size and scaled.
///
/// The content is inert here. These previews exist to be looked at while the
/// controls beside them are used; a live second copy would let a double-click
/// cycle a style out from under the picker that set it.
struct ScaledPreview<Content: View>: View {
    let width: CGFloat
    /// Nothing taller than this is worth showing in a settings pane; a page
    /// that runs longer is shown from the top, which is the part being
    /// arranged.
    var maxHeight: CGFloat = 420
    @ViewBuilder var content: Content

    @State private var natural: CGSize = .zero

    private var scale: CGFloat {
        guard natural.width > 0 else { return 1 }
        return min(1, width / natural.width)
    }

    var body: some View {
        content
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { natural = $0 }
            .scaleEffect(scale, anchor: .topLeading)
            .frame(
                width: natural.width > 0 ? natural.width * scale : width,
                height: natural.height > 0 ? min(natural.height * scale, maxHeight) : nil,
                alignment: .topLeading
            )
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct LayoutStudioKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the editor being drawn is already inside the studio.
    ///
    /// The door out of Settings is the same view, so without this it offers
    /// to open the room it is standing in.
    var isInLayoutStudio: Bool {
        get { self[LayoutStudioKey.self] }
        set { self[LayoutStudioKey.self] = newValue }
    }
}

/// The door from a settings pane to the full-size editor.
struct LayoutStudioButton: View {
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Label(
                L10n.Settings.layoutOpenStudio,
                systemImage: "rectangle.inset.filled.on.rectangle"
            )
            .font(.caption)
        }
        .buttonStyle(.vibeBar)
        .help(L10n.Settings.layoutOpenStudioHelp)
    }
}
