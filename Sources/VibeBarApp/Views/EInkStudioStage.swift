import AppKit
import SwiftUI
import VibeBarCore

/// The Studio's stage for one custom e-ink slide.
///
/// Paper, and nothing else: a white rectangle the exact size of the panel in
/// the slide's orientation, black ink, no shadow, no material, no rounded
/// corner. The only marks that are not the device's are the grid, the
/// selection and the diagnostics, and all three are hairlines — at 3× a 1 px
/// device rule and a 1 pt editor rule are the same weight, and an editor that
/// out-draws the panel is an editor that lies about it.
///
/// Fluency (CLAUDE.md rule 0): the box tree is resolved once per (layout,
/// snapshot) into `render` and nothing else recomputes it. Zooming re-scales
/// a finished picture, the grid is a `Canvas` over it, and a drag writes
/// `AppSettings` exactly once, on mouse-up, the way `MiniCanvasStage` does.
struct EInkStudioStage: View {
    @Binding var layout: EInkCanvasLayout
    @Binding var selection: Set<UUID>
    let slide: EInkSlide
    let orientation: EInkOrientation
    let profile: EInkDeviceProfile
    let snapshot: EInkDataSnapshot?
    /// The stage's own zoom, used only to keep the editor's lines hairline.
    let scale: CGFloat
    var onReport: (EInkLayoutDiagnostics.Report) -> Void

    @State private var render: Render?
    @State private var gestureBase: EInkCanvasLayout?
    @State private var preview: EInkCanvasLayout?
    @State private var resizing: UUID?
    @State private var cancelled = false
    @State private var hovered: UUID?
    @FocusState private var focused: Bool

    /// Paper opens at 3x: one device pixel is three points, which is the
    /// smallest zoom at which the 1 px grid is readable and a single-pixel
    /// drag is a deliberate gesture rather than a twitch.
    static let defaultZoom: CGFloat = 3

    private static let space = "vibebar.eink.studio"
    private static let snapAnimation = Animation.snappy(duration: 0.16, extraBounce: 0.05)

    /// One resolution of the layout, kept until its inputs change.
    private struct Render: Equatable {
        var layout: EInkCanvasLayout
        var generatedAtISO: String
        var orientation: Int
        var boxes: [EInkDrawBox]
        var report: EInkLayoutDiagnostics.Report
    }

    private var shown: EInkCanvasLayout { (preview ?? layout).normalized() }
    private var paperSize: CGSize {
        let size = profile.frameSize(for: orientation)
        return CGSize(width: CGFloat(size.width), height: CGFloat(size.height))
    }

    var body: some View {
        let shown = shown
        let size = paperSize
        ZStack(alignment: .topLeading) {
            Color.white
            EInkBoxCanvas(boxes: render?.boxes ?? [])
            grid
            markers(shown)
        }
        .frame(width: size.width, height: size.height)
        .overlay(Rectangle().strokeBorder(Color.black.opacity(0.55), lineWidth: 1 / max(scale, 1)))
        .contentShape(Rectangle())
        .coordinateSpace(name: Self.space)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .highPriorityGesture(drag(shown))
        .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
            guard gestureBase == nil else { return }
            switch phase {
            case let .active(point):
                hovered = hit(point, in: shown)?.id
                (hovered == nil ? NSCursor.arrow : NSCursor.openHand).set()
            case .ended:
                hovered = nil
                NSCursor.arrow.set()
            }
        }
        .onKeyPress { key in keyPress(key) }
        .onAppear { rebuild(shown) }
        .onChange(of: shown) { _, value in rebuild(value) }
        .onChange(of: snapshot?.generatedAtISO ?? "") { _, _ in rebuild(shown) }
        .onChange(of: orientation) { _, _ in rebuild(shown) }
        .onChange(of: layout) { _, _ in
            // An Undo or a Settings edit wins over a gesture still in flight.
            if gestureBase != nil { cancelled = true; preview = nil; gestureBase = nil }
            selection.formIntersection(layout.elements.map(\.id))
        }
    }

    // MARK: - Paper furniture

    /// 1 px minor, 8 px major ("main pixels"). Drawn over the ink at a
    /// hairline whatever the zoom, and skipped when the zoom is too low for
    /// the minor grid to be anything but grey.
    private var grid: some View {
        let size = paperSize
        let hairline = 1 / max(scale, 1)
        return Canvas { context, _ in
            if scale >= 3 {
                var minor = Path()
                for x in stride(from: 0.0, through: size.width, by: 1) {
                    minor.move(to: CGPoint(x: x, y: 0))
                    minor.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: 0.0, through: size.height, by: 1) {
                    minor.move(to: CGPoint(x: 0, y: y))
                    minor.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(minor, with: .color(.black.opacity(0.07)), lineWidth: hairline)
            }
            var major = Path()
            let step = EInkCanvasLayout.gridSpacing
            for x in stride(from: 0.0, through: size.width, by: step) {
                major.move(to: CGPoint(x: x, y: 0))
                major.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: 0.0, through: size.height, by: step) {
                major.move(to: CGPoint(x: 0, y: y))
                major.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(major, with: .color(.black.opacity(0.16)), lineWidth: hairline)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    /// Selection, hover, diagnostics and the outline of anything the device
    /// will not draw. Ink is black; only a real problem is red.
    @ViewBuilder
    private func markers(_ layout: EInkCanvasLayout) -> some View {
        let hairline = 1 / max(scale, 1)
        let failing = Set((render?.report.issues ?? []).compactMap(\.elementID))
        ForEach(layout.elements) { element in
            let rect = CGRect(x: element.x, y: element.y, width: element.width, height: element.height)
            if failing.contains(element.id) {
                Rectangle()
                    .strokeBorder(Color.red.opacity(0.85), lineWidth: hairline)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            } else if drawsNothing(element) {
                placeholder(element, rect: rect, hairline: hairline)
            }
            if hovered == element.id, !selection.contains(element.id) {
                Rectangle()
                    .strokeBorder(Color.black.opacity(0.3), lineWidth: hairline)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            }
        }
        ForEach(selectionBoxes(layout), id: \.id) { box in
            Rectangle()
                .strokeBorder(Color.black, style: StrokeStyle(lineWidth: hairline, dash: [3, 2]))
                .frame(width: box.rect.width, height: box.rect.height)
                .offset(x: box.rect.minX, y: box.rect.minY)
                .overlay(alignment: .bottomTrailing) {
                    if selection.count == 1 {
                        Rectangle()
                            .fill(Color.black)
                            .frame(width: 5, height: 5)
                            .offset(x: box.rect.minX + box.rect.width - 5, y: box.rect.minY + box.rect.height - 5)
                    }
                }
                .allowsHitTesting(false)
        }
    }

    /// Where an element the panel will not draw is, and what it is.
    ///
    /// A dashed hairline and the element's own name — never ink. An unbound
    /// bar used to be indistinguishable from a bound one at 100 %, and a
    /// `.fill` dropped from the palette was a solid black rectangle nobody
    /// could account for; both now read as "nothing to draw, and here is what
    /// this is". The name matters as much as the dashes: "there is something
    /// invisible here" without saying *what* is a hunt, not a diagnosis.
    private func placeholder(_ element: EInkCanvasElement, rect: CGRect, hairline: CGFloat) -> some View {
        Rectangle()
            .strokeBorder(
                Color.black.opacity(0.35),
                style: StrokeStyle(lineWidth: hairline, dash: [2, 2])
            )
            .overlay(alignment: .topLeading) {
                Text(EInkNaming.kind(element.kind))
                    .font(.system(size: 7))
                    .foregroundStyle(Color.black.opacity(0.45))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 1)
                    .help(L10n.Settings.Eink.Studio.nothingToDraw)
            }
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
    }

    /// Whether this element contributes no box at all — an unbound gauge, or
    /// text with nothing in it. The panel would show blank paper there, so the
    /// Studio shows where it is instead.
    private func drawsNothing(_ element: EInkCanvasElement) -> Bool {
        guard let snapshot else { return false }
        return EInkCustomLayoutRenderer.node(
            for: element,
            slide: slide,
            orientation: orientation,
            snapshot: snapshot
        ) == nil
    }

    private func selectionBoxes(_ layout: EInkCanvasLayout) -> [(id: UUID, rect: CGRect)] {
        var boxes: [UUID: CGRect] = [:]
        for e in layout.elements where selection.contains(e.id) {
            let key = e.groupID ?? e.id
            let rect = CGRect(x: e.x, y: e.y, width: e.width, height: e.height)
            boxes[key] = boxes[key].map { $0.union(rect) } ?? rect
        }
        return boxes.map { (id: $0.key, rect: $0.value) }
    }

    // MARK: - Rendering

    private func rebuild(_ candidate: EInkCanvasLayout) {
        guard let snapshot else {
            render = nil
            return
        }
        let key = Render(
            layout: candidate,
            generatedAtISO: snapshot.generatedAtISO,
            orientation: orientation.rawValue,
            boxes: [],
            report: EInkLayoutDiagnostics.Report(issues: [], elementCount: 0, elementLimit: 0)
        )
        if let render,
           render.layout == key.layout,
           render.generatedAtISO == key.generatedAtISO,
           render.orientation == key.orientation {
            return
        }
        let size = profile.frameSize(for: orientation)
        let boxes = EInkBoxLayout.resolve(
            EInkCustomLayoutRenderer.tree(
                layout: candidate,
                slide: slide,
                orientation: orientation,
                profile: profile,
                snapshot: snapshot
            ),
            in: EInkRect(x: 0, y: 0, width: size.width, height: size.height)
        )
        let report = EInkLayoutDiagnostics.report(
            layout: candidate,
            slide: slide,
            orientation: orientation,
            profile: profile,
            snapshot: snapshot
        )
        var next = key
        next.boxes = boxes
        next.report = report
        render = next
        onReport(report)
    }

    // MARK: - Pointer

    private func drag(_ shown: EInkCanvasLayout) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard !cancelled else { return }
                if gestureBase == nil {
                    focused = true
                    let base = layout.normalized()
                    let point = value.startLocation
                    let handle = base.elements.first { e in
                        selection.count == 1 && selection.contains(e.id)
                            && CGRect(x: e.x + e.width - 8, y: e.y + e.height - 8, width: 12, height: 12)
                                .contains(point)
                    }
                    resizing = handle?.id
                    if let target = handle ?? hit(point, in: base) {
                        let run = base.expandedSelection([target.id])
                        if NSEvent.modifierFlags.contains(.shift) {
                            if selection.contains(target.id) { selection.subtract(run) }
                            else { selection.formUnion(run) }
                        } else if !selection.contains(target.id) {
                            selection = run
                        }
                    } else {
                        selection = []
                    }
                    gestureBase = base
                }
                guard let base = gestureBase, !selection.isEmpty else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                guard hypot(dx, dy) >= 2 else { return }
                // Snapping is on by default and Option bypasses it, which is
                // the round 2 inversion: round 1 had a pixel drag with Option
                // as the *only* way to reach the grid, so a layout built by
                // hand never lined up with the presets it sat beside.
                let major = NSEvent.modifierFlags.contains(.option) != shown.snapToGrid
                if let resizing, let index = base.elements.firstIndex(where: { $0.id == resizing }) {
                    var next = base
                    let e = base.elements[index]
                    let step = major ? EInkCanvasLayout.gridSpacing : EInkCanvasLayout.pixelSpacing
                    next.elements[index].width = min(
                        base.width - e.x,
                        max(step, ((e.width + dx) / step).rounded() * step)
                    )
                    next.elements[index].height = min(
                        base.height - e.y,
                        max(step, ((e.height + dy) / step).rounded() * step)
                    )
                    withAnimation(Self.snapAnimation) { preview = next.normalized() }
                } else {
                    let moved = base.moving(selection, dx: dx, dy: dy, snapping: major)
                    if major { withAnimation(Self.snapAnimation) { preview = moved } } else { preview = moved }
                }
                NSCursor.closedHand.set()
            }
            .onEnded { _ in
                let result = cancelled ? nil : preview
                gestureBase = nil
                preview = nil
                resizing = nil
                cancelled = false
                // The one write per gesture: everything above moved a local
                // copy, so nothing published a settings change per mouse move.
                if let result, result != layout { layout = result }
                NSCursor.arrow.set()
            }
    }

    /// A group's empty space belongs to the group, as on the mini canvas.
    private func hit(_ point: CGPoint, in layout: EInkCanvasLayout) -> EInkCanvasElement? {
        var seen = Set<UUID>()
        for e in layout.elements.reversed() {
            guard let group = e.groupID else {
                if CGRect(x: e.x, y: e.y, width: e.width, height: e.height).contains(point) { return e }
                continue
            }
            guard seen.insert(group).inserted else { continue }
            let rect = layout.elements.filter { $0.groupID == group }
                .reduce(CGRect.null) { $0.union(CGRect(x: $1.x, y: $1.y, width: $1.width, height: $1.height)) }
            if rect.contains(point) { return e }
        }
        return nil
    }

    // MARK: - Keys

    /// Only the keys the window's monitor lets through: Escape, Delete and
    /// the ⌘ shortcuts `LayoutStudioView` declines for this subject. The
    /// arrows arrive through the model, because the monitor claims them for
    /// subject switching everywhere else.
    private func keyPress(_ key: KeyPress) -> KeyPress.Result {
        if key.key == .escape {
            cancelled = gestureBase != nil
            preview = nil
            gestureBase = nil
            selection = []
            return .handled
        }
        if key.key == .delete || key.key == .deleteForward {
            guard !selection.isEmpty else { return .ignored }
            var next = layout
            let members = next.expandedSelection(selection)
            next.elements.removeAll { members.contains($0.id) }
            layout = next.normalized()
            selection = []
            return .handled
        }
        guard key.modifiers.contains(.command) else { return .ignored }
        switch key.characters.lowercased() {
        case "a":
            selection = Set(layout.elements.map(\.id))
            return .handled
        case "d":
            guard !selection.isEmpty else { return .ignored }
            var next = layout
            selection = next.duplicate(selection)
            layout = next
            return .handled
        case "g":
            var next = layout
            if key.modifiers.contains(.shift) { next.ungroup(selection) } else { next.group(selection) }
            layout = next.normalized()
            return .handled
        default:
            return .ignored
        }
    }

    /// The arrow keys, handed down by `LayoutStudioView`.
    static func nudged(
        _ layout: EInkCanvasLayout,
        selection: Set<UUID>,
        dx: Int,
        dy: Int,
        major: Bool
    ) -> EInkCanvasLayout {
        // One pixel, eight with Shift, whatever the snap toggle says: an
        // arrow key is a measured nudge and the modifier is the whole control.
        let step = major ? EInkCanvasLayout.gridSpacing : EInkCanvasLayout.pixelSpacing
        return layout.moving(
            selection,
            dx: Double(dx) * step,
            dy: Double(dy) * step,
            snapping: major
        )
    }
}
