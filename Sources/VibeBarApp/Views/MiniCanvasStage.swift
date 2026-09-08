import AppKit
import SwiftUI
import VibeBarCore

/// A gesture keeps its baseline in local state; only releasing the mouse
/// writes settings. The preview therefore cannot resize the live panel or
/// fan out persistence notifications on every pointer movement.
struct MiniCanvasStage: View {
    let configID: UUID
    @Binding var layout: MiniCanvasLayout
    @Binding var selection: Set<UUID>
    let defaultFieldID: String?
    @State private var gestureBase: MiniCanvasLayout?
    @State private var preview: MiniCanvasLayout?
    @State private var resizing: UUID?
    @State private var cancelled = false
    @State private var hovered: UUID?
    @State private var editing: UUID?
    @State private var draft = ""
    @FocusState private var textFocused: Bool
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var quotaService: QuotaService
    @EnvironmentObject private var settingsStore: SettingsStore
    private static let snapAnimation = Animation.snappy(duration: 0.18, extraBounce: 0.06)
    @FocusState private var focused: Bool

    private var shown: MiniCanvasLayout { (preview ?? layout).normalized() }
    private let space = "vibebar.mini.freeCanvas"

    var body: some View {
        let shown = shown
        MiniQuotaWindowView(configID: configID, onClose: {}, onToggleDisplayMode: {}, canvasOverride: shown)
            .overlay(alignment: .topLeading) {
                interaction(shown)
                    .padding(.leading, 12)
                    .padding(.top, 26)
            }
            .frame(width: shown.width + 24, height: shown.height + 38)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress { key in
                guard editing == nil else { return .ignored }
                if key.key == .escape {
                    cancelled = gestureBase != nil; preview = nil; gestureBase = nil; selection = []
                    return .handled
                }
                if key.key == .delete || key.key == .deleteForward {
                    let ids = layout.expandedSelection(selection)
                    layout.elements.removeAll { ids.contains($0.id) }
                    selection = []
                    return .handled
                }
                guard key.modifiers.contains(.command) else { return .ignored }
                switch key.characters.lowercased() {
                case "a": selection = Set(layout.elements.map(\.id)); return .handled
                case "d": selection = layout.duplicate(selection); return .handled
                case "g":
                    if key.modifiers.contains(.shift) { layout.ungroup(selection) }
                    else { layout.group(selection) }
                    return .handled
                default: return .ignored
                }
            }
            .onChange(of: layout) { _, _ in
                // An external edit or Undo wins over an in-flight gesture.
                if gestureBase != nil { cancelled = true; preview = nil; gestureBase = nil }
                selection.formIntersection(layout.elements.map(\.id))
            }
    }

    private func interaction(_ shown: MiniCanvasLayout) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if shown.snapToGrid {
                Canvas { context, size in
                    var grid = Path()
                    for x in stride(from: 0.0, through: size.width, by: MiniCanvasLayout.gridSpacing) {
                        grid.move(to: CGPoint(x: x, y: 0))
                        grid.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    for y in stride(from: 0.0, through: size.height, by: MiniCanvasLayout.gridSpacing) {
                        grid.move(to: CGPoint(x: 0, y: y))
                        grid.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(grid, with: .color(.secondary.opacity(0.18)), lineWidth: 0.5)
                }
                .allowsHitTesting(false)
            }
            if let hovered, !selection.contains(hovered) {
                let ids = shown.expandedSelection([hovered])
                let rect = shown.elements.filter { ids.contains($0.id) }.reduce(CGRect.null) {
                    $0.union(CGRect(x: $1.x, y: $1.y, width: $1.width, height: $1.height))
                }
                if !rect.isNull {
                    StudioSelectionOutline(isSelected: false)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
            alignmentGuides(shown)
            ForEach(selectionBoxes(shown), id: \.id) { box in
                StudioSelectionOutline(isLifted: preview != nil)
                    .overlay(alignment: .bottomTrailing) {
                        if selection.count == 1 {
                            RoundedRectangle(cornerRadius: 2).fill(Color.accentColor)
                                .frame(width: 9, height: 9)
                        }
                    }
                    .frame(width: box.rect.width, height: box.rect.height)
                    .offset(x: box.rect.minX, y: box.rect.minY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: shown.width, height: shown.height)
        .contentShape(Rectangle())
        .coordinateSpace(name: space)
        .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { value in
                guard !cancelled, editing == nil else { return }
                if gestureBase == nil {
                    focused = true
                    let base = layout.normalized()
                    let point = value.startLocation
                    let handle = base.elements.first { e in
                        selection.count == 1 && selection.contains(e.id)
                        && CGRect(x: e.x + e.width - 14, y: e.y + e.height - 14, width: 18, height: 18).contains(point)
                    }
                    resizing = handle?.id
                    let hit = handle ?? hitAt(point, in: base)
                    if let hit {
                        let run = base.expandedSelection([hit.id])
                        if NSEvent.modifierFlags.contains(.shift) {
                            if selection.contains(hit.id) { selection.subtract(run) }
                            else { selection.formUnion(run) }
                        } else if !selection.contains(hit.id) { selection = run }
                    } else { selection = [] }
                    gestureBase = base
                }
                guard let base = gestureBase, !selection.isEmpty else { return }
                let dx = value.translation.width, dy = value.translation.height
                guard hypot(dx, dy) >= 3 else { return }
                if let resizing, let index = base.elements.firstIndex(where: { $0.id == resizing }) {
                    var next = base
                    let e = base.elements[index]
                    next.elements[index].width = min(base.width - e.x, max(16, e.width + dx))
                    next.elements[index].height = min(base.height - e.y, max(16, e.height + dy))
                    withAnimation(Self.snapAnimation) { preview = next.normalized() }
                } else {
                    let raw = base.moving(selection, dx: dx, dy: dy)
                    let snapped = base.moving(selection, dx: dx, dy: dy, magnetic: true)
                    if base.snapToGrid || raw != snapped {
                        withAnimation(Self.snapAnimation) { preview = snapped }
                    } else { preview = snapped }
                }
                NSCursor.closedHand.set()
            }
            .onEnded { _ in
                let result = cancelled ? nil : preview
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    gestureBase = nil; preview = nil; resizing = nil; cancelled = false
                    if let result, result != layout { layout = result }
                }
                NSCursor.arrow.set()
            })
        .onContinuousHover(coordinateSpace: .named(space)) { phase in
            guard gestureBase == nil else { return }
            switch phase {
            case let .active(point):
                hovered = hitAt(point, in: shown)?.id
                (hovered == nil ? NSCursor.arrow : NSCursor.openHand).set()
            case .ended:
                hovered = nil
                NSCursor.arrow.set()
            }
        }
        .simultaneousGesture(SpatialTapGesture(count: 2, coordinateSpace: .named(space)).onEnded { value in
            guard let element = shown.elements.reversed().first(where: {
                ($0.kind == .text || $0.kind.presetMode != nil)
                    && CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).contains(value.location)
            }) else { return }
            gestureBase = nil; preview = nil
            editing = element.id
            selection = shown.expandedSelection([element.id])
            draft = editableText(element)
            focused = false
            textFocused = true
        })
        .overlay(alignment: .topLeading) {
            if let editing, let element = shown.elements.first(where: { $0.id == editing }) {
                TextField("", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: min(24, element.fontSize)))
                    .frame(width: max(80, element.width), height: max(24, min(40, element.height)))
                    .offset(x: element.x, y: element.y + (element.kind.presetMode != nil ? max(0, element.height - 28) : 0))
                    .focused($textFocused)
                    .onSubmit { commitText() }
                    .onExitCommand { self.editing = nil }
                    .task { textFocused = true }
            }
        }
        .dropDestination(for: String.self) { items, location in
            guard let payload = items.first, payload.hasPrefix("vibebar-mini:"),
                  let kind = MiniCanvasElement.Kind(rawValue: String(payload.dropFirst("vibebar-mini:".count)))
            else { return false }
            var next = layout
            let id = next.add(kind, fieldID: defaultFieldID, x: location.x, y: location.y)
            layout = next; selection = [id]; focused = true
            return true
        }
    }

    private func editableText(_ element: MiniCanvasElement) -> String {
        let field = element.fieldID.flatMap { MenuBarFieldCatalog.field(id: $0, registry: quotaService.fieldRegistry) }
        let bucket = field.flatMap { environment.quota(for: $0.tool)?.bucket(id: $0.bucketId) }
        let label = field.map(MenuBarTokenNaming.fieldTitle) ?? ""
        if element.kind.presetMode != nil { return element.text.isEmpty ? (bucket?.shortLabel ?? label) : element.text }
        let percent = field.flatMap { f in bucket.map { $0.displayPercent(settingsStore.settings.displayMode, tool: f.tool) } }
        return MiniCanvasView.resolvedText(element, label: label, percent: percent, bucket: bucket, now: Date())
    }

    private func commitText() {
        guard let id = editing, let index = layout.elements.firstIndex(where: { $0.id == id }) else { return }
        editing = nil
        var next = layout
        next.elements[index].text = draft
        if next.elements[index].kind == .text { next.elements[index].textContent = .custom }
        layout = next
    }

    @ViewBuilder
    private func alignmentGuides(_ layout: MiniCanvasLayout) -> some View {
        if preview != nil, !selection.isEmpty {
            let selected = layout.elements.filter { selection.contains($0.id) }.reduce(CGRect.null) {
                $0.union(CGRect(x: $1.x, y: $1.y, width: $1.width, height: $1.height))
            }
            let others = layout.elements.filter { !selection.contains($0.id) }
            let xs = [0.0, layout.width / 2, layout.width] + others.flatMap { [$0.x, $0.x + $0.width / 2, $0.x + $0.width] }
            let ys = [0.0, layout.height / 2, layout.height] + others.flatMap { [$0.y, $0.y + $0.height / 2, $0.y + $0.height] }
            Path { path in
                for x in Set(xs) where [selected.minX, selected.midX, selected.maxX].contains(where: { abs($0 - x) < 0.5 }) {
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: layout.height))
                }
                for y in Set(ys) where [selected.minY, selected.midY, selected.maxY].contains(where: { abs($0 - y) < 0.5 }) {
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: layout.width, y: y))
                }
            }.stroke(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
                .allowsHitTesting(false)
        }
    }

    private func selectionBoxes(_ layout: MiniCanvasLayout) -> [(id: UUID, rect: CGRect)] {
        var boxes: [UUID: CGRect] = [:]
        for e in layout.elements where selection.contains(e.id) {
            let key = e.groupID ?? e.id
            let rect = CGRect(x: e.x, y: e.y, width: e.width, height: e.height)
            boxes[key] = boxes[key].map { $0.union(rect) } ?? rect
        }
        return boxes.map { (id: $0.key, rect: $0.value) }
    }

    /// A group's empty space is part of its container too.
    private func hitAt(_ point: CGPoint, in layout: MiniCanvasLayout) -> MiniCanvasElement? {
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
}
