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

public extension EInkPreviewPlanner {
    /// One page of a screen group, as each of its screens will show it.
    ///
    /// The boxes are `EInkScreenGroupRenderer.boxes` — the very call the sync
    /// engine encodes and pushes — wrapped per screen, so the arrangement the
    /// Settings pane draws cannot disagree with what the panels receive. An
    /// arrangement or page that cannot be drawn returns no plans at all, the
    /// same refusal the engine makes.
    static func planGroup(
        group: EInkScreenGroup,
        frame: EInkScreenFrame,
        devices: [EInkDeviceConfig],
        snapshot: EInkDataSnapshot,
        layouts: [String: EInkCanvasLayout] = [:]
    ) -> [String: EInkPreviewPlan] {
        guard let boxes = try? EInkScreenGroupRenderer.boxes(
            group: group,
            frame: frame,
            devices: devices,
            snapshot: snapshot,
            layouts: layouts
        ) else { return [:] }
        var plans: [String: EInkPreviewPlan] = [:]
        for screen in group.screens {
            guard let device = devices.first(where: { $0.deviceID == screen.deviceID }) else { continue }
            let size = device.profile.frameSize(for: device.orientation)
            plans[screen.deviceID] = EInkPreviewPlan(
                boxes: boxes[screen.deviceID] ?? [],
                authoredWidth: size.width,
                authoredHeight: size.height,
                panelWidth: device.profile.width,
                panelHeight: device.profile.height,
                orientation: device.orientation
            )
        }
        return plans
    }
}
