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
            ForEach(selectionBoxes(shown), id: \.id) { box in
                Rectangle().strokeBorder(Color.accentColor, lineWidth: 1)
                    .background(Color.accentColor.opacity(0.05))
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
                guard !cancelled else { return }
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
                    preview = next.normalized()
                } else { preview = base.moving(selection, dx: dx, dy: dy) }
            }
            .onEnded { _ in
                let result = cancelled ? nil : preview
                gestureBase = nil; preview = nil; resizing = nil; cancelled = false
                if let result, result != layout { layout = result }
            })
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
