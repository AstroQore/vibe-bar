import AppKit
import SwiftUI
import VibeBarCore

struct MiniCanvasInspector: View {
    @Binding var layout: MiniCanvasLayout
    @Binding var selection: Set<UUID>
    let fields: [MenuBarFieldOption]

    private var selected: MiniCanvasElement? {
        guard selection.count == 1 else { return nil }
        return layout.elements.first { selection.contains($0.id) }
    }

    private struct Layer: Identifiable {
        let id: UUID
        let elements: [MiniCanvasElement]
    }

    private var layers: [Layer] {
        var seen = Set<UUID>()
        return layout.elements.reversed().compactMap { element in
            let id = element.groupID ?? element.id
            guard seen.insert(id).inserted else { return nil }
            let members = element.groupID.map { group in layout.elements.filter { $0.groupID == group } } ?? [element]
            return Layer(id: id, elements: members)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.Settings.MiniCanvas.canvas).font(.headline)
            Picker(L10n.Settings.Section.layout, selection: $layout.snapToGrid) {
                Text(L10n.Settings.MiniCanvas.grid).tag(true)
                Text(L10n.Settings.MiniCanvas.free).tag(false)
            }
            .pickerStyle(.segmented)
            HStack {
                if layout.snapToGrid {
                    number(L10n.Settings.MiniCanvas.columns, binding: canvasNumber(\.width, divisor: MiniCanvasLayout.gridSpacing), range: 4...48)
                    number(L10n.Settings.MiniCanvas.rows, binding: canvasNumber(\.height, divisor: MiniCanvasLayout.gridSpacing), range: 4...36)
                } else {
                    number(L10n.MenuBar.Composer.Space.width, binding: canvasNumber(\.width), range: 160...1200)
                    number(L10n.Settings.MiniCanvas.height, binding: canvasNumber(\.height), range: 100...900)
                }
            }
            Text(L10n.Common.add).font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], alignment: .leading) {
                ForEach(MiniCanvasElement.Kind.allCases, id: \.self) { kind in
                    Button {
                        var next = layout
                        let id = next.add(kind, fieldID: fields.first?.id)
                        layout = next; selection = [id]
                    } label: {
                        Label(kind.title, systemImage: kind.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .draggable("vibebar-mini:\(kind.rawValue)")
                }
            }
            Divider()
            if let selected { properties(selected) }
            if !selection.isEmpty { actions }
            Text(L10n.Settings.MiniCanvas.layers).font(.headline)
            ForEach(layers) { layer in
                let element = layer.elements[0]
                Button {
                    let run = layout.expandedSelection([element.id])
                    if NSEvent.modifierFlags.contains(.shift) {
                        if selection.contains(element.id) { selection.subtract(run) }
                        else { selection.formUnion(run) }
                    } else { selection = run }
                } label: {
                    HStack {
                        Image(systemName: layer.elements.count > 1 ? "square.stack.3d.up" : element.kind.symbol)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(layer.elements.count > 1 ? L10n.MenuBar.Composer.Group.bind : element.kind.title)
                            Text(layer.elements.count > 1 ? layer.elements.map { $0.kind.title }.joined(separator: " · ") : elementTitle(element))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if layer.elements.count > 1 { Text(AppLocale.number(layer.elements.count)).foregroundStyle(.secondary) }
                    }
                    .padding(7)
                    .background(Color.accentColor.opacity(selection.contains(element.id) ? 0.16 : 0))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            Text(L10n.Platform.Macos.MiniCanvas.hint).font(.caption).foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
    }

    private func elementTitle(_ e: MiniCanvasElement) -> String {
        if e.kind == .text && e.textContent == .custom { return e.text }
        return fields.first { $0.id == e.fieldID }.map(MenuBarTokenNaming.fieldTitle)
            ?? L10n.Settings.MiniCanvas.unavailable
    }

    @ViewBuilder
    private func properties(_ e: MiniCanvasElement) -> some View {
        Text(e.kind.title).font(.headline)
        Picker(L10n.Workbench.Sessions.Fact.source, selection: elementBinding(e, \.fieldID, fallback: nil)) {
            Text(L10n.Workbench.Filter.none).tag(String?.none)
            ForEach(fields) { field in Text(MenuBarTokenNaming.fieldTitle(field)).tag(Optional(field.id)) }
        }
        if layout.snapToGrid {
            HStack {
                number(L10n.Settings.MiniCanvas.column, binding: cellPosition(e, \.x), range: 1...(layout.width / MiniCanvasLayout.gridSpacing))
                number(L10n.Settings.MiniCanvas.row, binding: cellPosition(e, \.y), range: 1...(layout.height / MiniCanvasLayout.gridSpacing))
            }
            spanPicker(e)
        } else {
        HStack {
            number(L10n.Settings.MiniCanvas.x, binding: elementBinding(e, \.x, fallback: 0), range: 0...layout.width)
            number(L10n.Settings.MiniCanvas.y, binding: elementBinding(e, \.y, fallback: 0), range: 0...layout.height)
        }
        HStack {
            number(L10n.MenuBar.Composer.Space.width, binding: elementBinding(e, \.width, fallback: 80), range: 16...layout.width)
            number(L10n.Settings.MiniCanvas.height, binding: elementBinding(e, \.height, fallback: 80), range: 16...layout.height)
        }
        }
        if e.kind == .ring {
            number(L10n.Settings.MiniCanvas.thickness, binding: elementBinding(e, \.thickness, fallback: 8), range: 1...40)
        }
        if e.kind == .text {
            Picker(L10n.Settings.MiniCanvas.content, selection: elementBinding(e, \.textContent, fallback: .percent)) {
                Text(L10n.MenuBar.Composer.Metric.displayPercent).tag(MiniCanvasElement.TextContent.percent)
                Text(L10n.MenuBar.Composer.Text.placeholder).tag(MiniCanvasElement.TextContent.label)
                Text(L10n.MenuBar.Composer.Metric.resetsIn).tag(MiniCanvasElement.TextContent.countdown)
                Text(L10n.MenuBar.Composer.Mode.custom).tag(MiniCanvasElement.TextContent.custom)
            }
            if e.textContent == .custom {
                DebouncedSettingsTextField(prompt: L10n.MenuBar.Composer.Block.text,
                                           value: elementBinding(e, \.text, fallback: ""))
                    .id(e.id)
            }
            number(L10n.Settings.MiniCanvas.fontSize, binding: elementBinding(e, \.fontSize, fallback: 18), range: 8...96)
        }
        Picker(L10n.MenuBar.Composer.Field.colour, selection: elementBinding(e, \.colour, fallback: .quota)) {
            Text(L10n.Settings.MiniCanvas.quotaColor).tag(MiniCanvasElement.Colour.quota)
            Text(L10n.Settings.MiniCanvas.providerColor).tag(MiniCanvasElement.Colour.provider)
            Text(L10n.MenuBar.Composer.Colour.primary).tag(MiniCanvasElement.Colour.primary)
            Text(L10n.MenuBar.Composer.Colour.fixed).tag(MiniCanvasElement.Colour.custom)
        }
        if e.colour == .custom {
            ColorPicker(L10n.MenuBar.Composer.Field.colour, selection: Binding(
                get: {
                    let hex = layout.elements.first { $0.id == e.id }?.hexColour ?? e.hexColour
                    guard let c = MenuBarHexColor.components(hex) else { return Color.accentColor }
                    return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
                },
                set: { color in
                    guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
                    elementBinding(e, \.hexColour, fallback: "#4d9fff").wrappedValue = String(
                        format: "#%02x%02x%02x", Int((c.redComponent * 255).rounded()),
                        Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
                }
            ), supportsOpacity: false)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(L10n.MenuBar.Composer.Action.duplicate) { selection = layout.duplicate(selection) }
                Button(L10n.Common.remove, role: .destructive) {
                    let ids = layout.expandedSelection(selection)
                    layout.elements.removeAll { ids.contains($0.id) }; selection = []
                }
            }
            HStack {
                Button(L10n.MenuBar.Composer.Group.bind) { layout.group(selection) }.disabled(selection.count < 2)
                Button(L10n.MenuBar.Composer.Group.unbind) { layout.ungroup(selection) }
            }
            if let selected {
                HStack {
                    Button(L10n.Settings.MiniCanvas.back) { reorder(selected.id, delta: -1) }
                    Button(L10n.Settings.MiniCanvas.front) { reorder(selected.id, delta: 1) }
                }
            }
        }
    }

    private func reorder(_ id: UUID, delta: Int) {
        guard let i = layout.elements.firstIndex(where: { $0.id == id }) else { return }
        let target = i + delta
        guard layout.elements.indices.contains(target) else { return }
        layout.elements.swapAt(i, target)
    }

    private func canvasNumber(_ key: WritableKeyPath<MiniCanvasLayout, Double>, divisor: Double = 1) -> Binding<Double> {
        Binding(get: { layout[keyPath: key] / divisor }, set: { value in
            var next = layout; next[keyPath: key] = value * divisor; layout = next.normalized()
        })
    }

    private func cellPosition(_ e: MiniCanvasElement, _ key: WritableKeyPath<MiniCanvasElement, Double>) -> Binding<Double> {
        let value = elementBinding(e, key, fallback: 0)
        return Binding(get: { value.wrappedValue / MiniCanvasLayout.gridSpacing + 1 },
                       set: { value.wrappedValue = ($0 - 1) * MiniCanvasLayout.gridSpacing })
    }

    private func spanPicker(_ e: MiniCanvasElement) -> some View {
        let current = MiniCanvasLayout.Span(Int((e.width / MiniCanvasLayout.gridSpacing).rounded()), Int((e.height / MiniCanvasLayout.gridSpacing).rounded()))
        var spans = MiniCanvasLayout.Span.presets
        if e.kind == .horizontalBar || e.kind == .text { spans += [.init(2, 1), .init(3, 1)] }
        if e.kind == .verticalBar { spans += [.init(1, 2), .init(1, 3)] }
        if !spans.contains(current) { spans.append(current) }
        return VStack(alignment: .leading, spacing: 6) {
            Text(L10n.Settings.MiniCanvas.span).font(.caption).foregroundStyle(.secondary)
            HStack {
                number(L10n.Settings.MiniCanvas.columns, binding: cellSize(e, \.width), range: 1...(layout.width / MiniCanvasLayout.gridSpacing))
                number(L10n.Settings.MiniCanvas.rows, binding: cellSize(e, \.height), range: 1...(layout.height / MiniCanvasLayout.gridSpacing))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))], spacing: 6) {
                ForEach(spans, id: \.self) { span in
                    Button {
                        withAnimation(.snappy(duration: 0.18)) { layout.resize(e.id, to: span) }
                    } label: {
                        VStack(spacing: 5) {
                            Canvas { context, size in
                                let unit = min(size.width / Double(max(span.columns, 3)), size.height / Double(max(span.rows, 3)))
                                let origin = CGPoint(x: (size.width - Double(span.columns) * unit) / 2,
                                                     y: (size.height - Double(span.rows) * unit) / 2)
                                for row in 0..<span.rows {
                                    for column in 0..<span.columns {
                                        let cell = CGRect(x: origin.x + Double(column) * unit, y: origin.y + Double(row) * unit,
                                                          width: unit - 2, height: unit - 2)
                                        context.fill(Path(roundedRect: cell, cornerRadius: 1), with: .color(current == span ? .accentColor : .secondary))
                                    }
                                }
                            }
                            .frame(height: 22)
                            Text("\(span.columns) × \(span.rows)").monospacedDigit()
                        }
                        .padding(7)
                        .frame(maxWidth: .infinity)
                        .background(Color.accentColor.opacity(current == span ? 0.14 : 0.035))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.vibeBar(cornerRadius: 7))
                    .disabled(Double(span.columns) * MiniCanvasLayout.gridSpacing > layout.width
                              || Double(span.rows) * MiniCanvasLayout.gridSpacing > layout.height)
                }
            }
        }
    }

    private func cellSize(_ e: MiniCanvasElement, _ key: WritableKeyPath<MiniCanvasElement, Double>) -> Binding<Double> {
        let value = elementBinding(e, key, fallback: MiniCanvasLayout.gridSpacing)
        return Binding(get: { value.wrappedValue / MiniCanvasLayout.gridSpacing },
                       set: { value.wrappedValue = $0 * MiniCanvasLayout.gridSpacing })
    }

    private func elementBinding<Value>(_ e: MiniCanvasElement, _ key: WritableKeyPath<MiniCanvasElement, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { layout.elements.first { $0.id == e.id }?[keyPath: key] ?? fallback }, set: { value in
            guard let index = layout.elements.firstIndex(where: { $0.id == e.id }) else { return }
            var next = layout; next.elements[index][keyPath: key] = value; layout = next.normalized()
        })
    }

    private func number(_ title: String, binding: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField(title, value: binding, format: .number.precision(.fractionLength(0)).locale(AppLocale.current))
                    .textFieldStyle(.roundedBorder).frame(minWidth: 48)
                Stepper(title, value: binding, in: range, step: 1).labelsHidden()
            }
        }
    }
}
