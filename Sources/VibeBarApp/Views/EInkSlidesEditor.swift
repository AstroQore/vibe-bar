import AppKit
import SwiftUI
import VibeBarCore

/// The slides half of Settings › E-ink Displays: the list on the left, the
/// selected slide's editor on the right, and the panel it makes at 2x.
///
/// Split out of `EInkDisplaysSettingsSection` because round 2 gave one slide
/// far more to say — composition, slot order, per-slot names, the Studio — and
/// one view holding a device's cadence *and* a slide's header bar is a view
/// nobody can read.
///
/// Nothing here computes a layout. The preview plan arrives already resolved
/// from the section above, which rebuilds it on a change rather than in
/// `body`.
struct EInkSlidesEditor: View {
    let device: EInkDeviceConfig
    @Binding var selectedSlideID: String?
    let sections: [EInkFieldSection]
    let plan: EInkPreviewPlan?
    let availableQuotaFieldIDs: [String]

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var slideDrag: Drag?
    @State private var slideFrames: [String: CGRect] = [:]
    @State private var slotDrag: Drag?
    @State private var slotFrames: [String: CGRect] = [:]
    @State private var isConfirmingReset = false

    private static let slideSpace = "vibebar.eink.slides"
    private static let slotSpace = "vibebar.eink.slots"
    private static let dragThreshold: CGFloat = 5

    /// One row being dragged in one of the two reorderable lists.
    private struct Drag {
        let id: String
        var location: CGPoint
        var engaged: Bool
    }

    private var selectedSlide: EInkSlide? {
        if let selectedSlideID, let match = device.slide(id: selectedSlideID) { return match }
        return device.slides.first
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                slideList
                if let slide = selectedSlide {
                    Divider().padding(.vertical, 2)
                    slideEditor(slide)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            previewColumn
        }
    }

    // MARK: - The list

    private var slideList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(device.slides) { slide in
                slideRow(slide)
            }
            HStack(spacing: 8) {
                Button(action: addSlide) {
                    Label(L10n.Settings.Eink.addSlide, systemImage: "plus")
                }
                .buttonStyle(.vibeBar)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .coordinateSpace(.named(Self.slideSpace))
        .overlay(alignment: .topLeading) {
            if let insertion = insertionIndex(slideDrag, ids: device.slides.map(\.id), frames: slideFrames),
               let offset = insertionOffset(device.slides.map(\.id), frames: slideFrames, at: insertion) {
                caret.offset(y: offset)
            }
        }
    }

    private var caret: some View {
        Capsule(style: .continuous)
            .fill(Color.accentColor)
            .frame(height: 2.5)
            .allowsHitTesting(false)
    }

    private func slideRow(_ slide: EInkSlide) -> some View {
        let isSelected = selectedSlide?.id == slide.id
        return HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 20)
                .contentShape(Rectangle())
                .gesture(
                    reorderGesture(
                        id: slide.id,
                        space: Self.slideSpace,
                        state: $slideDrag,
                        ids: device.slides.map(\.id),
                        frames: slideFrames,
                        apply: applySlideMove
                    )
                )
                .help(L10n.Common.dragToReorder)

            Button {
                selectedSlideID = slide.id
                // On a single-slide device the row *is* the active-slide
                // control: there is no other one, and picking a row that the
                // panel then ignores is a switch that does nothing.
                if device.playbackMode == .single {
                    updateDevice { $0.singleSlideID = slide.id }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(slideDisplayName(slide))
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(layoutName(for: slide.kind))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.vibeBar(cornerRadius: 6))

            BorderlessIconButton(
                systemImage: "xmark",
                help: device.slides.count > 1 ? L10n.Settings.Eink.removeSlide : L10n.Settings.Eink.lastSlide
            ) {
                removeSlide(slide.id)
            }
            .disabled(device.slides.count <= 1)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .opacity(slideDrag?.engaged == true && slideDrag?.id == slide.id ? 0.3 : 1)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(Self.slideSpace))
        } action: { frame in
            slideFrames[slide.id] = frame
        }
    }

    // MARK: - The editor

    @ViewBuilder
    private func slideEditor(_ slide: EInkSlide) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L10n.Common.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                DebouncedSettingsTextField(
                    prompt: L10n.Settings.Eink.slideName,
                    value: Binding(
                        get: { slide.title },
                        set: { [slideID = slide.id] value in
                            updateSlide(slideID) { $0.title = value }
                        }
                    )
                )
                .frame(width: 160)
                .id("title-\(slide.id)")

                layoutPicker(slide)
                Spacer(minLength: 0)
            }

            studioRow(slide)

            Divider().padding(.vertical, 2)
            compositionEditor(slide)

            Divider().padding(.vertical, 2)
            selectionEditor(slide)
        }
    }

    /// Only the layouts a person can put on a slide: the engine's alert panel
    /// names the bucket that has just tripped, which is not something anyone
    /// can place in advance.
    private func layoutPicker(_ slide: EInkSlide) -> some View {
        Picker(L10n.Settings.Eink.layout, selection: layoutBinding(slide)) {
            Section(L10n.Settings.Eink.Group.quota) {
                ForEach(EInkPreset.userSelectable.filter(\.isQuotaPreset), id: \.rawValue) { preset in
                    Text(EInkNaming.preset(preset)).tag(preset.rawValue)
                }
            }
            Section(L10n.Settings.Eink.Group.usage) {
                ForEach(EInkPreset.userSelectable.filter { EInkNaming.isUsage($0) }, id: \.rawValue) { preset in
                    Text(EInkNaming.preset(preset)).tag(preset.rawValue)
                }
            }
            Section(L10n.Settings.Eink.Group.insight) {
                ForEach(EInkPreset.userSelectable.filter { EInkNaming.isInsight($0) }, id: \.rawValue) { preset in
                    Text(EInkNaming.preset(preset)).tag(preset.rawValue)
                }
            }
            Text(L10n.Settings.Eink.customLayout).tag(Self.customTag)
        }
        .labelsHidden()
        .frame(maxWidth: 240, alignment: .leading)
    }

    /// Sentinel tag for the Studio option in the layout picker.
    private static let customTag = "\u{0}custom"

    /// "Edit in Studio", always enabled.
    ///
    /// Round 1 only offered it once a slide was already custom, which left the
    /// Studio with no way in from a preset — the owner's "Studio has no
    /// obvious entry". Pressing it on a preset slide explodes that preset into
    /// its modules for the orientation the device is on and switches the slide
    /// to the layout it just made, so the first thing the Studio shows is the
    /// panel that was already there.
    private func studioRow(_ slide: EInkSlide) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    openInStudio(slide)
                } label: {
                    Label(L10n.Settings.Eink.Studio.open, systemImage: "rectangle.dashed")
                }
                .buttonStyle(.vibeBar)

                if slide.kind.preset == nil {
                    Button(role: .destructive) {
                        isConfirmingReset = true
                    } label: {
                        Label(L10n.Settings.Eink.resetToPreset, systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.vibeBar)
                    .confirmationDialog(
                        L10n.Settings.Eink.resetToPreset,
                        isPresented: $isConfirmingReset
                    ) {
                        Button(L10n.Settings.Eink.resetToPreset, role: .destructive) {
                            resetToPreset(slide)
                        }
                        Button(L10n.Common.cancel, role: .cancel) {}
                    } message: {
                        Text(L10n.Settings.Eink.resetToPresetConfirm)
                    }
                }
                Spacer(minLength: 0)
            }
            Text(
                slide.kind.preset == nil
                    ? L10n.Settings.Eink.customLayoutDetail
                    : L10n.Settings.Eink.editInStudioDetail
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Composition

    /// Whether a slide has a header and a footer, and what each one prints.
    ///
    /// Hidden for a custom slide: its header is whatever element the author
    /// placed, and offering a toggle that moves nothing is worse than offering
    /// nothing.
    @ViewBuilder
    private func compositionEditor(_ slide: EInkSlide) -> some View {
        if slide.kind.preset != nil {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.Settings.Eink.composition)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Toggle(L10n.Settings.Eink.header, isOn: headerEnabledBinding(slide))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    if slide.options.header != nil {
                        Picker(L10n.Settings.Eink.headerPosition, selection: headerPositionBinding(slide)) {
                            Text(L10n.Settings.Eink.Position.top).tag(EInkBarConfig.Position.top)
                            Text(L10n.Settings.Eink.Position.bottom).tag(EInkBarConfig.Position.bottom)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                    }
                    Spacer(minLength: 0)
                }

                if slide.options.header != nil {
                    barSideRow(slide, title: L10n.Settings.Eink.headerLeft, isLeft: true)
                    barSideRow(slide, title: L10n.Settings.Eink.headerRight, isLeft: false)
                }

                HStack(spacing: 8) {
                    Text(L10n.Settings.Eink.footer)
                        .font(.caption)
                        .frame(width: 96, alignment: .leading)
                    Picker(L10n.Settings.Eink.footer, selection: footerChoiceBinding(slide)) {
                        Text(L10n.Workbench.Filter.none).tag(FooterChoice.off)
                        Text(L10n.Settings.Eink.Bar.presetDefault).tag(FooterChoice.presetDefault)
                        Text(L10n.Settings.Eink.Footer.usage).tag(FooterChoice.usage)
                        Text(L10n.MenuBar.Composer.ResetFormat.time).tag(FooterChoice.clock)
                        Text(L10n.Settings.Eink.Studio.Binding.custom).tag(FooterChoice.text)
                    }
                    .labelsHidden()
                    .frame(width: 200, alignment: .leading)
                    if case .text = slide.options.footer?.content {
                        DebouncedSettingsTextField(
                            prompt: L10n.Settings.Eink.barTextPrompt,
                            value: footerTextBinding(slide)
                        )
                        .frame(maxWidth: 220)
                        .id("footer-text-\(slide.id)")
                    }
                    Spacer(minLength: 0)
                }

                Toggle(L10n.Settings.Eink.compact, isOn: compactBinding(slide))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(slide.options.header != nil || slide.options.footer != nil)
            }
        }
    }

    private func barSideRow(_ slide: EInkSlide, title: String, isLeft: Bool) -> some View {
        let content = isLeft ? slide.options.header?.left : slide.options.header?.right
        return HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .frame(width: 96, alignment: .leading)
            Picker(title, selection: barChoiceBinding(slide, isLeft: isLeft)) {
                Text(L10n.Settings.Eink.Bar.presetDefault).tag(BarChoice.presetDefault)
                Text(L10n.Settings.Eink.Bar.nothing).tag(BarChoice.nothing)
                Text(L10n.Settings.Eink.Studio.Binding.custom).tag(BarChoice.text)
                Text(L10n.MenuBar.Composer.ResetFormat.time).tag(BarChoice.clock)
                Text(L10n.MenuBar.Composer.ResetFormat.date).tag(BarChoice.date)
                Text(L10n.MenuBar.Composer.ResetFormat.dateTime).tag(BarChoice.dateClock)
                Text(L10n.Settings.Eink.Bar.providerStatus).tag(BarChoice.providerStatus)
            }
            .labelsHidden()
            .frame(width: 200, alignment: .leading)
            if case .text = content {
                DebouncedSettingsTextField(
                    prompt: L10n.Settings.Eink.barTextPrompt,
                    value: barTextBinding(slide, isLeft: isLeft)
                )
                .frame(maxWidth: 220)
                .id("bar-\(isLeft ? "left" : "right")-\(slide.id)")
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Selection

    @ViewBuilder
    private func selectionEditor(_ slide: EInkSlide) -> some View {
        if let preset = slide.kind.preset {
            let capacity = preset.capacity(for: device.orientation)
            switch preset.selectionAxis {
            case .quotaFields:
                bucketPicker(slide, capacity: capacity)
                slotOrderList(slide)
            case .usagePeriods:
                periodPicker(slide, capacity: capacity)
            case .harnessRows:
                Text(L10n.Settings.Eink.noSelection)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            case .none:
                Text(L10n.Settings.Eink.fixedContent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bucketPicker(_ slide: EInkSlide, capacity: Int) -> some View {
        let selected = slide.quotaFieldIDs
        let isFull = selected.count >= capacity
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(L10n.Settings.Eink.buckets)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(L10n.Quota.History.curvesSome(shown: selected.count, total: capacity))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if selected.isEmpty {
                Text(L10n.Settings.Eink.noSelection)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isFull {
                Text(L10n.Settings.Eink.capacityFull(count: capacity))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                    ForEach(section.options) { option in
                        Toggle(
                            QuotaGroupLabelLocalizer.display(option.displayTitle),
                            isOn: bucketBinding(slide, fieldID: option.id, capacity: capacity)
                        )
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .disabled(
                            (isFull && !selected.contains(option.id))
                                || (selected.count == 1 && selected.contains(option.id))
                        )
                    }
                }
            }
        }
    }

    /// The chosen buckets in the order the panel prints them, each with the
    /// name this slide gives it.
    ///
    /// Both were missing in round 1: the order was whatever order the boxes
    /// were ticked in, and a three-tier name that did not fit could only be
    /// shortened by not picking that bucket.
    @ViewBuilder
    private func slotOrderList(_ slide: EInkSlide) -> some View {
        let ids = slide.orderedQuotaFieldIDs
        if !ids.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.Settings.Eink.slotOrder)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(ids, id: \.self) { fieldID in
                    slotRow(slide, fieldID: fieldID, ids: ids)
                }
                Text(L10n.Settings.Eink.slotLabelDetail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .coordinateSpace(.named(Self.slotSpace))
            .overlay(alignment: .topLeading) {
                if let insertion = insertionIndex(slotDrag, ids: ids, frames: slotFrames),
                   let offset = insertionOffset(ids, frames: slotFrames, at: insertion) {
                    caret.offset(y: offset)
                }
            }
        }
    }

    private func slotRow(_ slide: EInkSlide, fieldID: String, ids: [String]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 20)
                .contentShape(Rectangle())
                .gesture(
                    reorderGesture(
                        id: fieldID,
                        space: Self.slotSpace,
                        state: $slotDrag,
                        ids: ids,
                        frames: slotFrames,
                        apply: { moved, index in applySlotMove(slide, fieldID: moved, to: index, order: ids) }
                    )
                )
                .help(L10n.Common.dragToReorder)

            Text(defaultSlotName(fieldID))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)

            DebouncedSettingsTextField(
                prompt: L10n.Settings.Eink.slotLabel,
                value: slotLabelBinding(slide, fieldID: fieldID)
            )
            .frame(maxWidth: 240)
            .id("label-\(slide.id)-\(fieldID)")
            Spacer(minLength: 0)
        }
        .opacity(slotDrag?.engaged == true && slotDrag?.id == fieldID ? 0.3 : 1)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(Self.slotSpace))
        } action: { frame in
            slotFrames[fieldID] = frame
        }
    }

    private func periodPicker(_ slide: EInkSlide, capacity: Int) -> some View {
        let selected = slide.usagePeriods
        let isFull = selected.count >= capacity
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(L10n.Usage.Breakdown.periods)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(L10n.Quota.History.curvesSome(shown: selected.count, total: capacity))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            ForEach(EInkUsagePeriod.allCases, id: \.rawValue) { period in
                Toggle(
                    EInkNaming.period(period),
                    isOn: periodBinding(slide, period: period, capacity: capacity)
                )
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(
                    (isFull && !selected.contains(period))
                        || (selected.count == 1 && selected.contains(period))
                )
            }
        }
    }

    // MARK: - Preview

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Settings.Eink.uprightPreview)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let plan {
                let size = device.orientation.physicalFrame(device.profile)
                // 2x of a landscape panel is 592 pt wide, which a narrow
                // window cannot hold; fall back to device pixels rather than
                // clipping the panel.
                ViewThatFits(in: .horizontal) {
                    framedPreview(plan, size: size, scale: 2)
                    framedPreview(plan, size: size, scale: 1)
                }
            } else {
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 296, height: 152)
                    .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 1))
            }
            Text(L10n.Settings.Eink.panelTextNote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 296 * 2, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func framedPreview(
        _ plan: EInkPreviewPlan,
        size: (width: Int, height: Int),
        scale: CGFloat
    ) -> some View {
        EInkDeviceFrame(
            orientation: device.orientation,
            paperWidth: CGFloat(size.width) * scale,
            paperHeight: CGFloat(size.height) * scale
        ) {
            EInkPreviewView(plan: plan, scale: scale)
        }
    }

    // MARK: - Bindings

    private func layoutBinding(_ slide: EInkSlide) -> Binding<String> {
        Binding(
            get: { slide.kind.preset?.rawValue ?? Self.customTag },
            set: { [slideID = slide.id] value in
                guard let preset = EInkPreset(rawValue: value) else {
                    guard value == Self.customTag else { return }
                    openInStudio(slide)
                    return
                }
                updateSlide(slideID) { current in
                    current.kind = .preset(preset)
                    // Only the axis the new layout actually reads is trimmed.
                    // A quota slide switched to Usage Trend still holds its
                    // buckets, and truncating them to *that* layout's capacity
                    // would quietly throw away four choices the user gets back
                    // the moment they switch the layout again.
                    current = current.fitted(to: device.orientation)
                }
            }
        )
    }

    private func bucketBinding(_ slide: EInkSlide, fieldID: String, capacity: Int) -> Binding<Bool> {
        Binding(
            get: { slide.quotaFieldIDs.contains(fieldID) },
            set: { [slideID = slide.id] value in
                updateSlide(slideID) { current in
                    if value {
                        guard current.quotaFieldIDs.count < capacity,
                              !current.quotaFieldIDs.contains(fieldID) else { return }
                        current.quotaFieldIDs.append(fieldID)
                    } else {
                        // An empty list means "Vibe Bar's own order" to the
                        // renderer, so clearing the last box would put back
                        // the very buckets the user removed. One stays on, as
                        // with the usage periods.
                        guard current.quotaFieldIDs.count > 1 else { return }
                        current.quotaFieldIDs.removeAll { $0 == fieldID }
                        current.options.slotOrder.removeAll { $0 == fieldID }
                        current.options.customLabels[fieldID] = nil
                    }
                }
            }
        )
    }

    private func periodBinding(
        _ slide: EInkSlide,
        period: EInkUsagePeriod,
        capacity: Int
    ) -> Binding<Bool> {
        Binding(
            get: { slide.usagePeriods.contains(period) },
            set: { [slideID = slide.id] value in
                updateSlide(slideID) { current in
                    if value {
                        guard current.usagePeriods.count < capacity,
                              !current.usagePeriods.contains(period) else { return }
                        current.usagePeriods.append(period)
                    } else {
                        // The renderer reads an empty selection as "all four",
                        // so clearing the last box would show every period
                        // while the picker showed none. One always stays on.
                        guard current.usagePeriods.count > 1 else { return }
                        current.usagePeriods.removeAll { $0 == period }
                    }
                }
            }
        )
    }

    private func slotLabelBinding(_ slide: EInkSlide, fieldID: String) -> Binding<String> {
        Binding(
            get: { slide.options.customLabels[fieldID] ?? "" },
            set: { [slideID = slide.id] value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                updateSlide(slideID) { current in
                    current.options.customLabels[fieldID] = trimmed.isEmpty ? nil : trimmed
                }
            }
        )
    }

    private func headerEnabledBinding(_ slide: EInkSlide) -> Binding<Bool> {
        Binding(
            get: { slide.options.header != nil },
            set: { [slideID = slide.id] value in
                updateSlide(slideID) { current in
                    current.options.header = value ? EInkBarConfig() : nil
                }
            }
        )
    }

    private func headerPositionBinding(_ slide: EInkSlide) -> Binding<EInkBarConfig.Position> {
        Binding(
            get: { slide.options.header?.position ?? .top },
            set: { [slideID = slide.id] value in
                updateSlide(slideID) { $0.options.header?.position = value }
            }
        )
    }

    /// The header sides are an enum plus a string, and a picker cannot tag
    /// with an associated value that changes as it is typed.
    enum BarChoice: Hashable { case presetDefault, nothing, text, clock, date, dateClock, providerStatus }

    private func barChoiceBinding(_ slide: EInkSlide, isLeft: Bool) -> Binding<BarChoice> {
        Binding(
            get: {
                switch isLeft ? slide.options.header?.left : slide.options.header?.right {
                case .none, .some(.presetDefault): .presetDefault
                case .some(.none): .nothing
                case .some(.text): .text
                case .some(.clock): .clock
                case .some(.date): .date
                case .some(.dateClock): .dateClock
                case .some(.providerStatus): .providerStatus
                }
            },
            set: { [slideID = slide.id] choice in
                updateSlide(slideID) { current in
                    let existing = isLeft ? current.options.header?.left : current.options.header?.right
                    let content: EInkBarContent
                    switch choice {
                    case .presetDefault: content = .presetDefault
                    case .nothing: content = .none
                    case .text:
                        if case .text = existing { return }
                        content = .text("")
                    case .clock: content = .clock
                    case .date: content = .date
                    case .dateClock: content = .dateClock
                    case .providerStatus: content = .providerStatus
                    }
                    if isLeft { current.options.header?.left = content } else { current.options.header?.right = content }
                }
            }
        )
    }

    private func barTextBinding(_ slide: EInkSlide, isLeft: Bool) -> Binding<String> {
        Binding(
            get: {
                if case let .text(value) = (isLeft ? slide.options.header?.left : slide.options.header?.right) {
                    return value
                }
                return ""
            },
            set: { [slideID = slide.id] value in
                updateSlide(slideID) { current in
                    if isLeft {
                        current.options.header?.left = .text(value)
                    } else {
                        current.options.header?.right = .text(value)
                    }
                }
            }
        )
    }

    enum FooterChoice: Hashable { case off, presetDefault, usage, clock, text }

    private func footerChoiceBinding(_ slide: EInkSlide) -> Binding<FooterChoice> {
        Binding(
            get: {
                switch slide.options.footer?.content {
                case .none: .off
                case .some(.presetDefault): .presetDefault
                case .some(.usageSummary): .usage
                case .some(.clock): .clock
                case .some(.text): .text
                }
            },
            set: { [slideID = slide.id] choice in
                updateSlide(slideID) { current in
                    switch choice {
                    case .off: current.options.footer = nil
                    case .presetDefault: current.options.footer = EInkFooterConfig(content: .presetDefault)
                    case .usage:
                        current.options.footer = EInkFooterConfig(
                            content: .usageSummary(periods: [.today, .week])
                        )
                    case .clock: current.options.footer = EInkFooterConfig(content: .clock)
                    case .text:
                        if case .text = current.options.footer?.content { return }
                        current.options.footer = EInkFooterConfig(content: .text(""))
                    }
                }
            }
        )
    }

    private func footerTextBinding(_ slide: EInkSlide) -> Binding<String> {
        Binding(
            get: {
                if case let .text(value) = slide.options.footer?.content { return value }
                return ""
            },
            set: { [slideID = slide.id] value in
                updateSlide(slideID) { $0.options.footer = EInkFooterConfig(content: .text(value)) }
            }
        )
    }

    private func compactBinding(_ slide: EInkSlide) -> Binding<Bool> {
        Binding(
            get: { slide.options.compact },
            set: { [slideID = slide.id] value in
                updateSlide(slideID) { $0.options.compact = value }
            }
        )
    }

    // MARK: - Actions

    private func addSlide() {
        let slide = EInkSlide.defaultQuotaSlide(
            orientation: device.orientation,
            available: availableQuotaFieldIDs
        )
        updateDevice { $0.slides.append(slide) }
        selectedSlideID = slide.id
    }

    private func removeSlide(_ slideID: String) {
        updateDevice { device in
            guard device.slides.count > 1 else { return }
            device.slides.removeAll { $0.id == slideID }
        }
        if selectedSlideID == slideID { selectedSlideID = device.slides.first?.id }
    }

    /// Hands a slide to the Studio.
    ///
    /// A preset slide is exploded first — the preset's own boxes become
    /// grouped, bound elements at the orientation the device is on — so the
    /// Studio opens on the panel that was already there rather than on blank
    /// paper. A slide that is already custom just opens.
    private func openInStudio(_ slide: EInkSlide) {
        if slide.kind.preset != nil { explode(slide) }
        LayoutStudioWindowController.shared.open(
            subject: .einkSlide(deviceID: device.deviceID, slideID: slide.id),
            environment: environment
        )
    }

    private func explode(_ slide: EInkSlide) {
        guard let snapshot = environment.einkSyncService?.previewSnapshot else { return }
        var settings = settingsStore.settings
        guard let index = settings.einkSync.devices.firstIndex(where: { $0.deviceID == device.deviceID }),
              let position = settings.einkSync.devices[index].slides.firstIndex(where: { $0.id == slide.id })
        else { return }
        let profile = settings.einkSync.devices[index].profile
        let orientation = settings.einkSync.devices[index].orientation
        let layout = EInkPresetExploder.explode(
            slide: slide,
            orientation: orientation,
            profile: profile,
            snapshot: snapshot
        )
        settings.einkCanvasLayouts[EInkRenderer.layoutKey(slide.id, orientation: orientation)] = layout
        settings.einkSync.devices[index].slides[position].kind = .custom(layoutID: slide.id)
        settingsStore.settings = settings
    }

    /// Back to the preset, and the hand-made layouts go with it.
    ///
    /// Keeping them would leave a slide that draws a preset while four
    /// orientations' worth of edits sat invisibly in `settings.json`, ready to
    /// reappear the next time somebody pressed Edit in Studio.
    private func resetToPreset(_ slide: EInkSlide) {
        var settings = settingsStore.settings
        guard let index = settings.einkSync.devices.firstIndex(where: { $0.deviceID == device.deviceID }),
              let position = settings.einkSync.devices[index].slides.firstIndex(where: { $0.id == slide.id })
        else { return }
        let layoutID = slide.kind.layoutID ?? slide.id
        settings.einkCanvasLayouts = settings.einkCanvasLayouts.filter {
            $0.key != layoutID && !$0.key.hasPrefix(layoutID + "/")
        }
        settings.einkSync.devices[index].slides[position].kind = .preset(.quotaLedger)
        settings.einkSync.devices[index].slides[position] =
            settings.einkSync.devices[index].slides[position].fitted(to: device.orientation)
        settingsStore.settings = settings
    }

    // MARK: - Mutation

    private func updateDevice(_ mutate: (inout EInkDeviceConfig) -> Void) {
        var settings = settingsStore.settings
        guard let index = settings.einkSync.devices.firstIndex(where: { $0.deviceID == device.deviceID }) else {
            return
        }
        mutate(&settings.einkSync.devices[index])
        settings.einkSync.devices[index] = settings.einkSync.devices[index].sanitized
        settingsStore.settings = settings
    }

    private func updateSlide(_ slideID: String, _ mutate: (inout EInkSlide) -> Void) {
        updateDevice { device in
            guard let index = device.slides.firstIndex(where: { $0.id == slideID }) else { return }
            mutate(&device.slides[index])
        }
    }

    // MARK: - Reordering

    /// One drag gesture for both lists: rows lift, a caret shows where they
    /// will land, and the settings write happens once, on mouse-up.
    private func reorderGesture(
        id: String,
        space: String,
        state: Binding<Drag?>,
        ids: [String],
        frames: [String: CGRect],
        apply: @escaping (String, Int) -> Void
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { value in
                var current = state.wrappedValue ?? Drag(id: id, location: value.location, engaged: false)
                guard current.id == id else { return }
                current.location = value.location
                if !current.engaged,
                   hypot(value.translation.width, value.translation.height) >= Self.dragThreshold {
                    current.engaged = true
                }
                state.wrappedValue = current
            }
            .onEnded { _ in
                defer { state.wrappedValue = nil }
                guard let current = state.wrappedValue, current.id == id, current.engaged,
                      let target = insertionIndex(current, ids: ids, frames: frames)
                else { return }
                apply(id, target)
            }
    }

    private func insertionIndex(_ drag: Drag?, ids: [String], frames: [String: CGRect]) -> Int? {
        guard let drag, drag.engaged else { return nil }
        var index = 0
        for id in ids {
            guard let frame = frames[id] else { continue }
            if drag.location.y > frame.midY { index += 1 }
        }
        return min(index, ids.count)
    }

    private func insertionOffset(_ ids: [String], frames: [String: CGRect], at index: Int) -> CGFloat? {
        if index < ids.count, let frame = frames[ids[index]] { return frame.minY - 1.5 }
        if let last = ids.last, let frame = frames[last] { return frame.maxY - 1.5 }
        return nil
    }

    /// The caret index counts the dragged row, and the row is gone from the
    /// list being rebuilt. Dragging the first of three between the other two
    /// would otherwise land it at the end.
    private func reordered(_ order: [String], moving id: String, to index: Int) -> [String] {
        var result = order.filter { $0 != id }
        var target = index
        if let source = order.firstIndex(of: id), source < index { target -= 1 }
        result.insert(id, at: min(max(0, target), result.count))
        return result
    }

    private func applySlideMove(_ slideID: String, to index: Int) {
        let order = reordered(device.slides.map(\.id), moving: slideID, to: index)
        updateDevice { device in
            let byID = Dictionary(device.slides.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            device.slides = order.compactMap { byID[$0] }
        }
    }

    private func applySlotMove(_ slide: EInkSlide, fieldID: String, to index: Int, order: [String]) {
        let next = reordered(order, moving: fieldID, to: index)
        updateSlide(slide.id) { $0.options.slotOrder = next }
    }

    // MARK: - Naming

    private func slideDisplayName(_ slide: EInkSlide) -> String {
        slide.title.isEmpty ? layoutName(for: slide.kind) : slide.title
    }

    private func layoutName(for kind: EInkSlide.Kind) -> String {
        guard let preset = kind.preset else { return L10n.Settings.Eink.customSlide }
        return EInkNaming.preset(preset)
    }

    /// The name the panel prints for a bucket when the slide names nothing —
    /// shown beside the field so an empty box is not a mystery.
    private func defaultSlotName(_ fieldID: String) -> String {
        sections
            .flatMap(\.options)
            .first { $0.id == fieldID }
            .map { QuotaGroupLabelLocalizer.display($0.displayTitle) }
            ?? fieldID
    }
}
