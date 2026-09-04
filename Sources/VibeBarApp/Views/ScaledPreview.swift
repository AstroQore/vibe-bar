import SwiftUI
import VibeBarCore

/// A real view, drawn at its natural size and scaled.
///
/// A mini window lays out at the width its panel opens at and a popover page
/// at the width of a window. Constraining either with `.frame(width:)` does
/// not make it narrower — it lays out at its own width and spills over
/// whatever is beside it. So it is measured at its natural size and scaled,
/// and the caller decides the scale: fit, or a zoom the user chose.
///
/// The content is inert here. It exists to be looked at and, in the Studio,
/// to be arranged from *outside* — a live second copy would let a double-click
/// cycle a style out from under the control that set it. Everything tagged
/// with `surfaceItem(_:)` inside reports its frame in `SurfaceCoordinates.space`,
/// which is the content before this scale, so the Studio maps the pointer back
/// through the same scale it asked for.
struct ScaledPreview<Content: View>: View {
    let scale: CGFloat
    /// Cut the picture off below this height; `.infinity` shows all of it.
    var maxHeight: CGFloat = .infinity
    /// The content's own size, before scaling, whenever it changes.
    var onNaturalSize: ((CGSize) -> Void)? = nil
    @ViewBuilder var content: Content

    @State private var natural: CGSize = .zero

    var body: some View {
        let height = natural.height > 0 ? min(natural.height * scale, maxHeight) : nil
        content
            .coordinateSpace(.named(SurfaceCoordinates.space))
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                natural = size
                onNaturalSize?(size)
            }
            .scaleEffect(scale, anchor: .topLeading)
            .frame(
                width: natural.width > 0 ? natural.width * scale : nil,
                height: height,
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
                L10n.Settings.Layout.openStudio,
                systemImage: "rectangle.inset.filled.on.rectangle"
            )
            .font(.caption)
        }
        .buttonStyle(.vibeBar)
        .help(L10n.Settings.Layout.openStudioHelp)
    }
}
