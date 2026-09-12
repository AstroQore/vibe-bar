import AppKit
import SwiftUI
import VibeBarCore

/// Everything about a custom e-ink slide a drag cannot say.
///
/// Same shape as `MiniCanvasInspector` — palette, properties, actions, layers
/// — with two additions the panel forces: every element is bound to a real
/// bucket or window through the mini window's own field sections, and the
/// checks that decide whether the layout is allowed near a device are listed
/// here rather than discovered when the push fails.
struct EInkStudioInspector: View {
    @Binding var layout: EInkCanvasLayout
    @Binding var selection: Set<UUID>
    /// The names this slide prints for its buckets, edited here as well as in
    /// the settings pane: a label is a property of the slide, not of the
    /// element, so two elements bound to one bucket cannot disagree.
    @Binding var customLabels: [String: String]
    let sections: [EInkFieldSection]
    let slide: EInkSlide
    let orientation: EInkOrientation
    let profile: EInkDeviceProfile
    let snapshot: EInkDataSnapshot?
    let report: EInkLayoutDiagnostics.Report?
    let isPushing: Bool
    var onPush: () -> Void

    private var selected: EInkCanvasElement? {
        guard selection.count == 1 else { return nil }
        return layout.elements.first { selection.contains($0.id) }
    }

    private struct Layer: Identifiable {
        let id: UUID
        let elements: [EInkCanvasElement]
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

    private var options: [MenuBarFieldOption] { sections.flatMap(\.options) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Text(L10n.Common.add).font(.headline)
            Text(L10n.Settings.Eink.Studio.modules).font(.caption).foregroundStyle(.secondary)
            modulePalette
            Text(L10n.Settings.Eink.Studio.elements).font(.caption).foregroundStyle(.secondary)
            palette(EInkStudioModules.authorPlaceable)
            Text(L10n.Settings.Eink.Studio.wholeLayouts).font(.caption).foregroundStyle(.secondary)
            presetPalette
            Divider()
            if let selected { properties(selected) }
            if !selection.isEmpty { actions }
            diagnostics
            Text(L10n.Settings.MiniCanvas.layers).font(.headline)
            ForEach(layers) { layer in layerRow(layer) }
            Text(L10n.Settings.Eink.Studio.hint).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.Settings.Eink.Studio.orientationNote).font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.Settings.Eink.panelTextNote).font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
    }

    private var header: some View {
        let size = profile.frameSize(for: orientation)
        return VStack(alignment: .leading, spacing: 6) {
            Text(L10n.Settings.Section.einkDisplays).font(.headline)
            Text(L10n.Settings.Eink.Studio.paperSize(height: size.height, width: size.width))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button(action: onPush) {
                Label(L10n.Settings.Eink.Studio.push, systemImage: "arrow.up.circle")
            }
            .disabled(isPushing)
        }
    }

    /// The primitives an author can draw.
    ///
    /// `EInkStudioModules.authorPlaceable` is a written list, not a filter
    /// over `Kind.allCases`: the filter is how `.fill` — a solid black
    /// rectangle with no binding and no controls — reached this grid under the
    /// name "Element" and ended up on the owner's panel.
    private func palette(_ kinds: [EInkCanvasElement.Kind]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], alignment: .leading) {
            ForEach(kinds, id: \.self) { kind in
                Button {
                    var next = layout
                    let id = next.add(kind, fieldID: kind.needsField ? options.first?.id : nil)
                    layout = next
                    selection = [id]
                } label: {
                    Label(EInkNaming.kind(kind), systemImage: EInkNaming.symbol(kind))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// The ready-made groups: a header bar, one quota slot, one usage slot, a
    /// footer. Each arrives bound and grouped, exactly as an exploded preset's
    /// own modules do, so Ungroup splits either one.
    private var modulePalette: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], alignment: .leading) {
            ForEach(EInkStudioModule.allCases) { module in
                Button {
                    var next = layout
                    let ids = next.insert(
                        EInkStudioModules.elements(
                            module,
                            fieldID: module == .quotaSlot ? preferredFieldID : nil,
                            width: max(48, layout.width - 2 * EInkCanvasLayout.safeMargin),
                            origin: next.nextModuleOrigin
                        )
                    )
                    layout = next
                    selection = ids
                } label: {
                    Label(EInkNaming.module(module), systemImage: EInkNaming.symbol(module))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// A whole preset, dropped as the groups it is made of rather than as one
    /// opaque block — the same explode "Edit in Studio" performs.
    private var presetPalette: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], alignment: .leading) {
            ForEach(EInkPreset.userSelectable, id: \.rawValue) { preset in
                Button {
                    guard let snapshot else { return }
                    var next = layout
                    let ids = next.insert(
                        EInkStudioModules.presetElements(
                            preset,
                            slide: slide,
                            orientation: orientation,
                            profile: profile,
                            snapshot: snapshot
                        )
                    )
                    layout = next
                    selection = ids
                } label: {
                    Label(EInkNaming.preset(preset), systemImage: "rectangle.on.rectangle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(snapshot == nil)
            }
        }
    }

    /// The bucket a new quota slot binds to: the one the slide already draws,
    /// else the first the account offers. A slot bound to nothing is a dashed
    /// placeholder, which is a worse first impression than a bound one.
    private var preferredFieldID: String? {
        slide.orderedQuotaFieldIDs.first ?? options.first?.id
    }

    // MARK: - Properties

    @ViewBuilder
    private func properties(_ e: EInkCanvasElement) -> some View {
        Text(EInkNaming.kind(e.kind)).font(.headline)
        HStack {
            number(L10n.Settings.MiniCanvas.x, binding: value(e, \.x), range: 0...layout.width)
            number(L10n.Settings.MiniCanvas.y, binding: value(e, \.y), range: 0...layout.height)
        }
        HStack {
            number(L10n.MenuBar.Composer.Space.width, binding: value(e, \.width), range: 1...layout.width)
            number(L10n.Settings.MiniCanvas.height, binding: value(e, \.height), range: 1...layout.height)
        }
        if let preset = e.kind.preset {
            presetSelection(e, preset: preset)
        } else {
            switch e.kind {
            case .text, .statTile:
                bindingPicker(e)
                fontControls(e)
                if e.kind == .text {
                    Picker(L10n.Settings.Eink.Studio.boxWidth, selection: value(e, \.autoWidth)) {
                        Text(L10n.Settings.Eink.Studio.BoxWidth.auto).tag(true)
                        Text(L10n.Settings.Eink.Studio.BoxWidth.fixed).tag(false)
                    }
                }
                if e.kind == .statTile {
                    DebouncedSettingsTextField(
                        prompt: L10n.Settings.Eink.Studio.caption,
                        value: value(e, \.text)
                    )
                    .id("caption-\(e.id)")
                    DebouncedSettingsTextField(
                        prompt: L10n.Settings.Eink.Studio.subValue,
                        value: value(e, \.subText)
                    )
                    .id("sub-\(e.id)")
                }
            case .ring:
                fieldPicker(e)
                number(L10n.Settings.MiniCanvas.thickness, binding: value(e, \.thickness), range: 1...32)
                fontControls(e)
            case .horizontalBar, .verticalBar:
                fieldPicker(e)
            case .divider:
                EmptyView()
            default:
                EmptyView()
            }
        }
        if let fieldID = e.fieldID, !fieldID.isEmpty, e.kind.preset == nil {
            customLabelField(fieldID)
        }
    }

    /// The name this slide prints for the bucket the selected element is bound
    /// to.
    ///
    /// It writes the *slide's* label map rather than anything on the element,
    /// which is what keeps a slot's name, its bar and its countdown agreeing
    /// after one of them is edited — and what makes the same field in Settings
    /// and the same field here one control.
    private func customLabelField(_ fieldID: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.Settings.Eink.slotLabel).font(.caption).foregroundStyle(.secondary)
            DebouncedSettingsTextField(
                prompt: L10n.Settings.Eink.slotLabel,
                value: Binding(
                    get: { customLabels[fieldID] ?? "" },
                    set: { value in
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        customLabels[fieldID] = trimmed.isEmpty ? nil : trimmed
                    }
                )
            )
            .id("studio-label-\(fieldID)")
            Text(L10n.Settings.Eink.slotLabelDetail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func bindingPicker(_ e: EInkCanvasElement) -> some View {
        Picker(L10n.MenuBar.Composer.Field.shows, selection: value(e, \.textBinding)) {
            Text(L10n.Settings.Eink.Studio.Binding.percent).tag(EInkCanvasElement.TextBinding.percent)
            Text(L10n.Settings.Eink.Studio.Binding.label).tag(EInkCanvasElement.TextBinding.label)
            Text(L10n.Settings.Eink.Studio.Binding.countdown).tag(EInkCanvasElement.TextBinding.countdown)
            Text(L10n.Settings.Eink.Studio.Binding.usage).tag(EInkCanvasElement.TextBinding.usageMetric)
            // A tile's big line is a figure; its fixed text is the caption
            // and the sub value below, which have their own fields.
            if e.kind != .statTile {
                Text(L10n.Settings.Eink.Studio.Binding.custom).tag(EInkCanvasElement.TextBinding.custom)
            }
        }
        switch e.textBinding {
        case .percent, .label, .countdown:
            fieldPicker(e)
        case .usageMetric:
            Picker(L10n.Settings.Eink.Studio.period, selection: value(e, \.usagePeriod)) {
                ForEach(EInkUsagePeriod.allCases, id: \.self) { period in
                    Text(EInkNaming.period(period)).tag(period)
                }
            }
            Picker(L10n.Settings.Eink.Studio.metric, selection: value(e, \.usageMetric)) {
                Text(L10n.Cost.title).tag(EInkCanvasElement.UsageMetric.cost)
                Text(L10n.Usage.Tokens.title).tag(EInkCanvasElement.UsageMetric.tokens)
                Text(L10n.Usage.Breakdown.requests).tag(EInkCanvasElement.UsageMetric.requests)
            }
        case .custom:
            if e.kind != .statTile {
                DebouncedSettingsTextField(prompt: L10n.MenuBar.Composer.Block.text, value: value(e, \.text))
                    .id("text-\(e.id)")
            }
        case .clock, .date:
            // Both draw the assembly time; there is nothing else to choose.
            EmptyView()
        }
    }

    private func fieldPicker(_ e: EInkCanvasElement) -> some View {
        Picker(L10n.Workbench.Sessions.Fact.source, selection: optionalValue(e, \.fieldID)) {
            Text(L10n.Workbench.Filter.none).tag(String?.none)
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.options) { option in
                        Text(MenuBarTokenNaming.fieldTitle(option)).tag(Optional(option.id))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func fontControls(_ e: EInkCanvasElement) -> some View {
        let isSans = e.font.isSans
        Picker(L10n.Settings.Eink.Studio.font, selection: fontFamily(e)) {
            Text(L10n.Settings.Eink.Studio.Font.pixel).tag(false)
            Text(L10n.Settings.Eink.Studio.Font.sans).tag(true)
        }
        if isSans {
            number(
                L10n.Settings.MiniCanvas.fontSize,
                binding: fontSize(e),
                range: Double(EInkFont.minimumSansSize)...Double(EInkFont.maximumSansSize)
            )
        }
        Toggle(L10n.Settings.Eink.Studio.bold, isOn: fontBold(e))
        Picker(L10n.Settings.Eink.Studio.alignment, selection: value(e, \.alignment)) {
            Text(L10n.Settings.Eink.Studio.Align.leading).tag(EInkTextAlignment.leading)
            Text(L10n.Settings.Eink.Studio.Align.center).tag(EInkTextAlignment.center)
            Text(L10n.Settings.Eink.Studio.Align.trailing).tag(EInkTextAlignment.trailing)
        }
        .pickerStyle(.segmented)
    }

    /// A whole-preset block picks its own buckets or windows; nothing ticked
    /// means "Vibe Bar's own order", exactly as on a preset slide.
    @ViewBuilder
    private func presetSelection(_ e: EInkCanvasElement, preset: EInkPreset) -> some View {
        let capacity = preset.capacity(for: orientation)
        switch preset.selectionAxis {
        case .quotaFields:
            Text(L10n.Settings.Eink.buckets).font(.caption).foregroundStyle(.secondary)
            ForEach(sections) { section in
                DisclosureGroup(section.title) {
                    ForEach(section.options) { option in
                        Toggle(MenuBarTokenNaming.fieldTitle(option), isOn: presetField(e, option.id, capacity: capacity))
                            .font(.caption)
                    }
                }
            }
            Text(L10n.Settings.Eink.Studio.presetSelection).font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        case .usagePeriods:
            Text(L10n.Settings.Eink.Studio.period).font(.caption).foregroundStyle(.secondary)
            ForEach(EInkUsagePeriod.allCases, id: \.self) { period in
                Toggle(EInkNaming.period(period), isOn: presetPeriod(e, period, capacity: capacity))
                    .font(.caption)
            }
            Text(L10n.Settings.Eink.Studio.presetSelection).font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        case .harnessRows:
            Text(L10n.Settings.Eink.noSelection).font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        case .none:
            Text(L10n.Settings.Eink.fixedContent).font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions, layers, checks

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(L10n.MenuBar.Composer.Action.duplicate) {
                    var next = layout
                    selection = next.duplicate(selection)
                    layout = next
                }
                Button(L10n.Common.remove, role: .destructive) {
                    var next = layout
                    let ids = next.expandedSelection(selection)
                    next.elements.removeAll { ids.contains($0.id) }
                    layout = next.normalized()
                    selection = []
                }
            }
            HStack {
                Button(L10n.MenuBar.Composer.Group.bind) {
                    var next = layout
                    next.group(selection)
                    layout = next
                }
                .disabled(selection.count < 2)
                Button(L10n.MenuBar.Composer.Group.unbind) {
                    var next = layout
                    next.ungroup(selection)
                    layout = next
                }
            }
            if let layer = layers.first(where: { Set($0.elements.map(\.id)) == selection }),
               let element = layer.elements.first {
                HStack {
                    Button(L10n.Settings.MiniCanvas.back) {
                        var next = layout
                        next.reorder(element.id, by: -1)
                        layout = next
                    }
                    Button(L10n.Settings.MiniCanvas.front) {
                        var next = layout
                        next.reorder(element.id, by: 1)
                        layout = next
                    }
                }
            }
        }
    }

    private func layerRow(_ layer: Layer) -> some View {
        let element = layer.elements[0]
        return Button {
            let run = layout.expandedSelection([element.id])
            if NSEvent.modifierFlags.contains(.shift) {
                if selection.contains(element.id) { selection.subtract(run) } else { selection.formUnion(run) }
            } else {
                selection = run
            }
        } label: {
            HStack {
                Image(systemName: layer.elements.count > 1
                      ? "square.stack.3d.up"
                      : EInkNaming.symbol(element.kind))
                VStack(alignment: .leading, spacing: 2) {
                    Text(layer.elements.count > 1
                         ? L10n.MenuBar.Composer.Group.bind
                         : EInkNaming.kind(element.kind))
                    Text(layer.elements.count > 1
                         ? layer.elements.map { EInkNaming.kind($0.kind) }.joined(separator: " · ")
                         : elementDetail(element))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if (report?.issues(for: element.id).isEmpty == false) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            .padding(7)
            .background(Color.accentColor.opacity(selection.contains(element.id) ? 0.16 : 0))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var diagnostics: some View {
        if let report {
            HStack(spacing: 8) {
                Text(L10n.Settings.Eink.Studio.diagnostics).font(.headline)
                Spacer(minLength: 4)
                Text(L10n.Settings.Eink.Studio.budget(count: report.elementCount, limit: report.elementLimit))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(report.elementCount > report.elementLimit ? Color.red : .secondary)
            }
            if report.isClear {
                Text(L10n.Settings.Eink.Studio.diagnosticsClear).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(report.issues) { issue in
                    Button {
                        if let id = issue.elementID { selection = layout.expandedSelection([id]) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
                            Text(issueText(issue))
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func issueText(_ issue: EInkLayoutDiagnostics.Issue) -> String {
        switch issue {
        case .textOverflow: L10n.Settings.Eink.Studio.Issue.textOverflow
        case .outOfFrame: L10n.Settings.Eink.Studio.Issue.outOfFrame
        case .presetClipped: L10n.Settings.Eink.Studio.Issue.presetClipped
        case .unbound: L10n.Settings.Eink.Studio.Issue.noField
        case let .tooManyElements(count, limit):
            L10n.Settings.Eink.Studio.Issue.tooManyElements(count: count, limit: limit)
        }
    }

    private func elementDetail(_ e: EInkCanvasElement) -> String {
        if let preset = e.kind.preset { return EInkNaming.preset(preset) }
        if e.kind == .divider { return "" }
        if e.textBinding == .custom, e.kind == .text || e.kind == .statTile { return e.text }
        if e.textBinding == .usageMetric, e.kind == .text || e.kind == .statTile {
            return EInkNaming.period(e.usagePeriod)
        }
        return options.first { $0.id == e.fieldID }.map(MenuBarTokenNaming.fieldTitle)
            ?? L10n.Settings.MiniCanvas.unavailable
    }

    // MARK: - Bindings

    private func value<Value>(
        _ e: EInkCanvasElement,
        _ key: WritableKeyPath<EInkCanvasElement, Value>
    ) -> Binding<Value> {
        Binding(
            get: { layout.elements.first { $0.id == e.id }?[keyPath: key] ?? e[keyPath: key] },
            set: { value in
                guard let index = layout.elements.firstIndex(where: { $0.id == e.id }) else { return }
                var next = layout
                next.elements[index][keyPath: key] = value
                layout = next.normalized()
            }
        )
    }

    private func optionalValue(
        _ e: EInkCanvasElement,
        _ key: WritableKeyPath<EInkCanvasElement, String?>
    ) -> Binding<String?> {
        value(e, key)
    }

    private func fontFamily(_ e: EInkCanvasElement) -> Binding<Bool> {
        let font = value(e, \.font)
        return Binding(
            get: { font.wrappedValue.isSans },
            set: { isSans in
                let bold = font.wrappedValue.isBold
                font.wrappedValue = isSans
                    ? .sans(size: max(EInkFont.minimumSansSize, font.wrappedValue.pointSize), bold: bold)
                    : .pixel12(bold: bold)
            }
        )
    }

    private func fontSize(_ e: EInkCanvasElement) -> Binding<Double> {
        let font = value(e, \.font)
        return Binding(
            get: { Double(font.wrappedValue.pointSize) },
            set: { size in
                font.wrappedValue = .sans(size: Int(size.rounded()), bold: font.wrappedValue.isBold)
            }
        )
    }

    private func fontBold(_ e: EInkCanvasElement) -> Binding<Bool> {
        let font = value(e, \.font)
        return Binding(
            get: { font.wrappedValue.isBold },
            set: { bold in
                font.wrappedValue = font.wrappedValue.isSans
                    ? .sans(size: font.wrappedValue.pointSize, bold: bold)
                    : .pixel12(bold: bold)
            }
        )
    }

    private func presetField(_ e: EInkCanvasElement, _ fieldID: String, capacity: Int) -> Binding<Bool> {
        let ids = value(e, \.fieldIDs)
        return Binding(
            get: { ids.wrappedValue.contains(fieldID) },
            set: { on in
                var next = ids.wrappedValue
                if on {
                    guard next.count < capacity, !next.contains(fieldID) else { return }
                    next.append(fieldID)
                } else {
                    next.removeAll { $0 == fieldID }
                }
                ids.wrappedValue = next
            }
        )
    }

    private func presetPeriod(_ e: EInkCanvasElement, _ period: EInkUsagePeriod, capacity: Int) -> Binding<Bool> {
        let periods = value(e, \.periods)
        return Binding(
            get: { periods.wrappedValue.contains(period) },
            set: { on in
                var next = periods.wrappedValue
                if on {
                    guard next.count < capacity, !next.contains(period) else { return }
                    next.append(period)
                } else {
                    next.removeAll { $0 == period }
                }
                periods.wrappedValue = next
            }
        )
    }

    private func number(_ title: String, binding: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField(title, value: binding, format: .number.precision(.fractionLength(0)).locale(AppLocale.current))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 48)
                Stepper(title, value: binding, in: range, step: 1).labelsHidden()
            }
        }
    }
}

// MARK: - Naming

/// One place that names an e-ink preset, window or element, so the settings
/// pane and the Studio cannot disagree about what a thing is called.
enum EInkNaming {
    static func preset(_ preset: EInkPreset) -> String {
        switch preset {
        case .quotaLedger: L10n.Settings.MiniWindow.Mode.ledger
        case .quotaRings: L10n.Settings.Eink.Preset.rings
        case .quotaRail: L10n.Settings.MiniWindow.Mode.rail
        case .usageTiles: L10n.Settings.MiniWindow.Mode.tiles
        case .usageSplit: L10n.Settings.Eink.Preset.split
        case .usageTable: L10n.Settings.Eink.Preset.table
        case .usageDual: L10n.Settings.Eink.Preset.dual
        case .usageTrend: L10n.Settings.Eink.Preset.trend
        case .briefing: L10n.Settings.Eink.Preset.briefing
        // Two of round 2's layouts are words the catalogue already had; a
        // second key saying "Forecast" is a second key to retranslate.
        case .forecast: L10n.MenuBar.Composer.Colour.forecast
        case .resets: L10n.Workbench.Page.Resets.title
        case .heatmap: L10n.Settings.Eink.Preset.heatmap
        case .topModels: L10n.Settings.Eink.Preset.topModels
        // Never in a picker — the engine places it — but it is named in a
        // slide list and in the Studio's layer list all the same.
        case .alert: L10n.Settings.Eink.alerts
        }
    }

    /// The three groups the layout picker offers, so the settings pane and the
    /// Studio palette cut the list the same way.
    static func isUsage(_ preset: EInkPreset) -> Bool {
        switch preset {
        case .usageTiles, .usageSplit, .usageTable, .usageDual, .usageTrend: true
        default: false
        }
    }

    static func isInsight(_ preset: EInkPreset) -> Bool {
        !preset.isQuotaPreset && !isUsage(preset) && preset != .alert
    }

    /// Which way the device is turned, in the words the existing catalogue
    /// already has for it.
    ///
    /// 90° reads as *turned left*: the encoder rotates the canvas clockwise
    /// into the panel, so reading it upright means turning the device the
    /// other way and the hardware's top edge ends up on the left. Round 1 had
    /// these two the wrong way round, which is visible the moment a panel is
    /// picked up — see `EInkOrientation.uprightDeviceEdge`.
    static func orientation(_ orientation: EInkOrientation) -> String {
        switch orientation {
        case .degrees0: L10n.Settings.Eink.Orientation.upright
        case .degrees90: L10n.Settings.Eink.Orientation.left
        case .degrees180: L10n.Settings.Eink.Orientation.inverted
        case .degrees270: L10n.Settings.Eink.Orientation.right
        }
    }

    static func module(_ module: EInkStudioModule) -> String {
        switch module {
        case .headerBar: L10n.Settings.Eink.header
        case .quotaSlot: L10n.Settings.Eink.Studio.Module.quotaSlot
        case .usageSlot: L10n.Settings.Eink.Studio.Module.usageSlot
        case .footer: L10n.Settings.Eink.footer
        }
    }

    static func symbol(_ module: EInkStudioModule) -> String {
        switch module {
        case .headerBar: "rectangle.topthird.inset.filled"
        case .quotaSlot: "chart.bar.xaxis"
        case .usageSlot: "square.text.square"
        case .footer: "rectangle.bottomthird.inset.filled"
        }
    }

    static func period(_ period: EInkUsagePeriod) -> String {
        switch period {
        case .today: L10n.Cost.Timeframe.today
        case .week: L10n.Cost.Timeframe.week
        case .month: L10n.Cost.Timeframe.month
        case .allTime: L10n.Cost.ModelRanking.allTime
        }
    }

    static func kind(_ kind: EInkCanvasElement.Kind) -> String {
        if let block = kind.preset { return preset(block) }
        switch kind {
        case .text: return L10n.MenuBar.Composer.Block.text
        case .ring: return L10n.Settings.MiniCanvas.ring
        case .horizontalBar: return L10n.Settings.MiniCanvas.horizontalBar
        case .verticalBar: return L10n.Settings.MiniCanvas.verticalBar
        case .statTile: return L10n.Settings.Eink.Studio.statTile
        case .divider: return L10n.Settings.Eink.Studio.divider
        // `.fill` and `.image` are never offered in the palette — they are the
        // far side of an explode — but a layout can hold them, and a layer
        // called "Element" is what let an unexplained black rectangle sit on
        // the owner's paper with nothing to click on.
        case .fill: return L10n.Settings.Eink.Studio.fill
        case .image: return L10n.Settings.Eink.Studio.image
        default: return L10n.Settings.MiniCanvas.element
        }
    }

    static func symbol(_ kind: EInkCanvasElement.Kind) -> String {
        if kind.preset != nil { return "rectangle.on.rectangle" }
        switch kind {
        case .text: return "textformat"
        case .ring: return "circle.dashed"
        case .horizontalBar: return "rectangle.split.3x1"
        case .verticalBar: return "chart.bar.fill"
        case .statTile: return "square.text.square"
        case .divider: return "minus"
        case .fill: return "square.fill"
        case .image: return "photo"
        default: return "square"
        }
    }
}

extension EInkCanvasElement.Kind {
    /// Whether a fresh element of this kind should be born bound to the first
    /// available bucket. A preset block picks its own, and a rule has none.
    var needsField: Bool {
        switch self {
        case .text, .ring, .horizontalBar, .verticalBar, .statTile: true
        default: false
        }
    }
}

extension EInkFont {
    var isSans: Bool {
        if case .sans = self { return true }
        return false
    }
}
