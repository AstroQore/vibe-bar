import Foundation

/// Everything the in-app preview needs to draw one slide, resolved once.
///
/// The panel is always the same 296 × 152 physical rectangle. A portrait
/// orientation is a layout *authored* at 152 × 296 and then turned, which is
/// exactly what the device does with the encoder's root `rotate()` — so the
/// preview rotates the same authored canvas rather than laying it out twice.
/// Getting that wrong is invisible on a Mac and obvious on a desk.
public struct EInkPreviewPlan: Sendable, Equatable {
    /// Absolutely positioned boxes in the authored frame's coordinates.
    public var boxes: [EInkDrawBox]
    /// The frame the boxes were laid out in — 296 × 152, or 152 × 296 when
    /// the orientation is portrait.
    public var authoredWidth: Int
    public var authoredHeight: Int
    /// The physical panel, which the authored frame is rotated into.
    public var panelWidth: Int
    public var panelHeight: Int
    public var orientation: EInkOrientation
    /// Set when the slide could not be drawn at all; `boxes` is then empty.
    public var failure: EInkRenderError?

    public init(
        boxes: [EInkDrawBox],
        authoredWidth: Int,
        authoredHeight: Int,
        panelWidth: Int,
        panelHeight: Int,
        orientation: EInkOrientation,
        failure: EInkRenderError? = nil
    ) {
        self.boxes = boxes
        self.authoredWidth = authoredWidth
        self.authoredHeight = authoredHeight
        self.panelWidth = panelWidth
        self.panelHeight = panelHeight
        self.orientation = orientation
        self.failure = failure
    }

    /// Clockwise degrees the authored canvas is turned by to reach the panel.
    public var rotationDegrees: Double { Double(orientation.rawValue) }
}

/// Resolves a slide into preview boxes.
///
/// Pure and in Core so the geometry the preview draws is the same geometry the
/// encoder sends, proven by tests rather than by looking at two screenshots.
/// The work is deliberately *not* done in a SwiftUI `body`: a settings pane
/// that re-lays-out a box tree on every render is the hitch CLAUDE.md rule 0
/// exists to prevent.
public enum EInkPreviewPlanner {
    public static func plan(
        slide: EInkSlide,
        orientation: EInkOrientation,
        profile: EInkDeviceProfile = .quote0,
        snapshot: EInkDataSnapshot,
        layouts: [String: EInkCanvasLayout] = [:]
    ) -> EInkPreviewPlan {
        let authored = profile.frameSize(for: orientation)
        let frame = EInkRect(x: 0, y: 0, width: authored.width, height: authored.height)
        do {
            let tree = try EInkRenderer.tree(
                slide: slide,
                orientation: orientation,
                profile: profile,
                snapshot: snapshot,
                layouts: layouts
            )
            return EInkPreviewPlan(
                boxes: EInkBoxLayout.resolve(tree, in: frame),
                authoredWidth: authored.width,
                authoredHeight: authored.height,
                panelWidth: profile.width,
                panelHeight: profile.height,
                orientation: orientation
            )
        } catch {
            return EInkPreviewPlan(
                boxes: [],
                authoredWidth: authored.width,
                authoredHeight: authored.height,
                panelWidth: profile.width,
                panelHeight: profile.height,
                orientation: orientation,
                failure: error as? EInkRenderError
            )
        }
    }
}
