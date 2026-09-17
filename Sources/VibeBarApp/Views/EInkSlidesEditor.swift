import AppKit
import SwiftUI
import VibeBarCore

/// What a group hands the editor so its pages can be edited by the very same
/// controls a single screen's slides are.
///
/// The editor stays one editor: the page list is the group's pages, the
/// editor under it is the page's template on the screens the Screens control
/// picks, and every write goes back out through these closures instead of
/// straight into `AppSettings.einkSync.devices`.
struct EInkSlidesGroupContext {
    /// One region of the selected page — one screen, or the run of screens a
    /// merged region covers.
    struct Screen: Identifiable, Equatable {
        let id: String
        let name: String
    }

    var screens: [Screen]
    var activeScreenID: String?
    var mode: EInkScreenMode
    /// Custom is a three-screen-and-up shape, and a page already in it.
    var allowsCustom: Bool
    var canSplitActive: Bool
    var mergeTargets: [Screen]
    var setMode: (EInkScreenMode) -> Void
    var selectScreen: (String) -> Void
    var splitActive: () -> Void
    var mergeActive: (String) -> Void
    /// Page id, and the template that page now draws on the active screens.
    var updateSlide: (String, EInkSlide) -> Void
    var addPage: () -> Void
    var removePage: (String) -> Void
    var reorderPages: ([String]) -> Void
    var selectPage: (String) -> Void
    var openStudio: (String) -> Void
    /// The group's own preview: every screen in its arrangement, with the
    /// page arrows for derived pages. Built above, never in this `body`.
    var preview: AnyView
}

/// The slides half of Settings › E-ink Displays: the list on the left, the
/// selected slide's editor on the right, and the panel it makes at 2x.
///
/// Split out of `EInkDisplaysSettingsSection` because round 2 gave one slide
/// far more to say — composition, slot order, per-slot names, the Studio — and
/// one view holding a device's cadence *and* a slide's header bar is a view
/// nobody can read.
///
/// One editor serves a screen and a group. A group arrives as an
/// `EInkSlidesGroupContext` whose page list stands in for the device's
/// slides; without one, every path is the standalone path it has always been.
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
    /// The preview snapshot, for the live percentage beside each slot. `nil`
    /// before the first assembly, and the rows simply say nothing then.
    let snapshot: EInkDataSnapshot?
    /// `nil` for a screen on its own.
    var group: EInkSlidesGroupContext?
    @State private var contentRequest: EInkContentPicker.Request?
    @State private var previewPages: [EInkPreviewPlan] = []
    @State private var previewPage = 0
    @State private var confirmingStudioPages = false
    @State private var studioSlide: EInkSlide?

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var quotaService: QuotaService

    @State private var slideDrag: Drag?
    @State private var slideFrames: [String: CGRect] = [:]
    @State private var isConfirmingReset = false
    /// The shown slots as one company → SubProvider → group tree, and the
    /// live percentage for each of them.
    ///
    /// Both are rebuilt when the selection, the registry or the snapshot
    /// moves — never in `body`. Every settings write republishes into this
    /// view, and walking the catalog per pass is exactly the hitch `AGENTS.md`
    /// § 7 forbids on an interactive surface.
    @State private var companies: [SlotCompany] = []
    @State private var percentByField: [String: Int] = [:]

    private static let slideSpace = "vibebar.eink.slides"
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
        // A device is twice as long as its panel, so even at device pixels the
        // preview is about 630 pt. Beside an editor column whose pickers and
        // fields need several hundred more, that does not fit the Settings
        // pane at the Workbench's default width — and the paper may not be
        // shrunk to make it (`docs/DESIGN.md`: whole pixels). So the preview
        // goes under the editor instead of beside it.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                editorColumn
                previewColumn
            }
            VStack(alignment: .leading, spacing: 16) {
                editorColumn
                previewColumn
            }
        }
        .onAppear { rebuildCaches() }
        // The *resolved* order, so a slot moved with the arrows rebuilds the
        // tree too: `slotOrder` is what an up / down click writes, and
        // watching the selection alone left the list in its old order until
        // something unrelated happened to invalidate it.
        .onChange(of: selectedSlide?.orderedQuotaFieldIDs ?? []) { _, _ in rebuildCaches() }
        .onChange(of: selectedSlide?.id) { _, _ in rebuildCaches() }
        .onChange(of: quotaService.fieldRegistry) { _, _ in rebuildCaches() }
        .onChange(of: snapshot) { _, _ in rebuildCaches() }
        .onChange(of: selectedSlide) { _, _ in rebuildCaches() }
        .onChange(of: device.orientation) { _, _ in rebuildCaches() }
        .onChange(of: device.profile) { _, _ in rebuildCaches() }
        .onChange(of: settingsStore.settings.einkCanvasLayouts) { _, _ in rebuildCaches() }
        .confirmationDialog(L10n.Settings.Eink.Workflow.editPages, isPresented: $confirmingStudioPages, titleVisibility: .visible, presenting: studioSlide) { slide in
            Button(L10n.Settings.Eink.Workflow.materializePages) { materializeAndEdit(slide) }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: { _ in Text(L10n.Settings.Eink.Workflow.editPagesDetail) }
        .sheet(item: $contentRequest) { request in
            EInkContentPicker(request: request, onSave: { fields in
                updateSlide(request.slideID) { $0.quotaFieldIDs = fields; $0.options.slotOrder = fields }
                contentRequest = nil
            }, onCancel: { contentRequest = nil })
            .vibeBarNoInitialFocus()
        }
    }

    private func rebuildCaches() {
        companies = SlotCompany.tree(
            fieldIDs: selectedSlide?.orderedQuotaFieldIDs ?? [],
            registry: quotaService.fieldRegistry
        )
        rebuildPercentages()
        if let slide = selectedSlide, let snapshot {
            previewPages = EInkPagination.pages(slide, orientation: device.orientation, profile: device.profile, snapshot: snapshot).map {
                EInkPreviewPlanner.plan(slide: $0, orientation: device.orientation, profile: device.profile,
                    snapshot: snapshot, layouts: settingsStore.settings.einkCanvasLayouts)
            }
            previewPage = min(previewPage, max(0, previewPages.count - 1))
        }
    }

    private func rebuildPercentages() {
        percentByField = Dictionary(
            (snapshot?.quota ?? []).map { ($0.fieldID, $0.remainingPercent) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The slide list and the selected slide's editor.
    ///
    /// `minWidth` is what makes the side-by-side arrangement report an honest
    /// width: a column that only says "as wide as you like" always fits, and
    /// `ViewThatFits` would never reach for the stacked form.
    @ViewBuilder
    private var editorColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            slideList
            if let group {
                Divider().padding(.vertical, 2)
                screensControl(group)
            }
            if let slide = selectedSlide {
                Divider().padding(.vertical, 2)
                slideEditor(slide)
            }
        }
        .frame(minWidth: 440, maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Screens

    /// Which screens this page uses, and — when they are not one canvas —
    /// which of them the editor below is editing.
    ///
    /// The three shapes are read from the page itself (`screenMode`), so this
    /// control never holds state of its own: switching merges or splits the
    /// page's regions and the reading changes with it.
    private func screensControl(_ group: EInkSlidesGroupContext) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L10n.Settings.Eink.ScreenGroups.screens)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Picker(
                    L10n.Settings.Eink.ScreenGroups.screens,
                    selection: Binding(get: { group.mode }, set: { group.setMode($0) })
                ) {
                    Text(L10n.Settings.Eink.Screens.combined).tag(EInkScreenMode.combined)
                    Text(L10n.Settings.Eink.Screens.separate).tag(EInkScreenMode.separate)
                    if group.allowsCustom {
                        Text(L10n.Settings.Eink.Screens.custom).tag(EInkScreenMode.custom)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: group.allowsCustom ? 300 : 220)
                Spacer(minLength: 0)
            }

            if group.mode != .combined {
                HStack(spacing: 6) {
                    // Tabs, not a row of buttons: exactly one screen's
                    // template is in the editor below at a time, and the
                    // control has to say which.
                    Picker(
                        L10n.Settings.Eink.ScreenGroups.screens,
                        selection: Binding(get: { group.activeScreenID ?? "" }, set: { group.selectScreen($0) })
                    ) {
                        ForEach(group.screens) { screen in
                            Text(screen.name).tag(screen.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    if group.mode == .custom {
                        Button(L10n.Settings.Eink.Workflow.splitSlides) { group.splitActive() }
                            .buttonStyle(.vibeBar)
                            .disabled(!group.canSplitActive)
                        Menu(L10n.Settings.Eink.Workflow.mergeSlides) {
                            ForEach(group.mergeTargets) { target in
                                Button(target.name) { group.mergeActive(target.id) }
                            }
                        }
                        .frame(width: 130)
                        .disabled(group.mergeTargets.isEmpty)
                    }
                    Spacer(minLength: 0)
                }
            }

            Text(screensDetail(group.mode))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func screensDetail(_ mode: EInkScreenMode) -> String {
        switch mode {
        case .combined: L10n.Settings.Eink.Screens.combinedDetail
        case .separate: L10n.Settings.Eink.Screens.separateDetail
        case .custom: L10n.Settings.Eink.Screens.customDetail
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
                if let group {
                    group.selectPage(slide.id)
                } else {
                    selectedSlideID = slide.id
                    // On a single-slide device the row *is* the active-slide
                    // control: there is no other one, and picking a row that
                    // the panel then ignores is a switch that does nothing.
                    if device.playbackMode == .single {
                        updateDevice { $0.singleSlideID = slide.id }
                    }
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
                slotArrangement(slide, capacity: capacity)
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

    // MARK: - Slot arrangement

    /// The slide's quota slots, arranged the way the menu bar arranges its
    /// fields: what is shown, as one ordered tree of company → SubProvider →
    /// group with an editable name at each level, and a candidate list under
    /// it.
    ///
    /// Round 2 shipped a checkbox list of every bucket the app knows plus a
    /// separate "Order" list, which the owner's review called out: two
    /// controls for one decision, in a shape nothing else in Vibe Bar uses,
    /// and no way to rename a whole provider without renaming five slots.
    private func slotArrangement(_ slide: EInkSlide, capacity: Int) -> some View {
        let ids = slide.orderedQuotaFieldIDs
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L10n.Settings.Eink.buckets)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(L10n.Settings.Eink.Workflow.selectionSummary(items: ids.count, pages: max(1, previewPages.count)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                if slide.kind.preset?.isQuotaPreset == true {
                    Text(L10n.Settings.Eink.labelStyle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Picker(L10n.Settings.Eink.labelStyle, selection: labelStyleBinding(slide)) {
                        ForEach(EInkSlotLabelStyle.allCases, id: \.self) { style in
                            Text(EInkNaming.labelStyle(style)).tag(style)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .help(L10n.Settings.Eink.LabelStyle.detail)
                }
            }

            if ids.isEmpty {
                Text(L10n.Settings.Eink.noSelection)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                shownTree(slide, ids: ids)
            }

            Text(L10n.Settings.Eink.slotLabelDetail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            candidateList(slide, shown: ids, capacity: capacity)
        }
    }

    private func shownTree(_ slide: EInkSlide, ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(companies) { company in
                if company.showsHeader {
                    HStack(spacing: 6) {
                        CompanyBrandIconView(tool: company.accentTool, size: 12)
                            .opacity(0.85)
                        Text(company.name)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.4)
                    }
                    .padding(.top, company.isFirst ? 0 : 5)
                }
                ForEach(company.subProviders) { subProvider in
                    levelRow(
                        slide,
                        title: subProvider.name,
                        key: subProvider.key,
                        indent: 14,
                        weight: .bold,
                        size: 9
                    )
                    ForEach(subProvider.groups) { group in
                        if let key = group.key {
                            levelRow(
                                slide,
                                title: group.title,
                                key: key,
                                indent: 28,
                                weight: .semibold,
                                size: 8.5
                            )
                        }
                        ForEach(group.fieldIDs, id: \.self) { fieldID in
                            slotRow(slide, fieldID: fieldID, ids: ids)
                        }
                    }
                }
            }
        }
    }

    /// One level heading with the name the panel prints for it.
    ///
    /// Empty inherits, exactly as a slot's own name does: the field's prompt
    /// is the default, so an untouched level says what it will print without
    /// anybody having to type it back in.
    private func levelRow(
        _ slide: EInkSlide,
        title: String,
        key: String,
        indent: CGFloat,
        weight: Font.Weight,
        size: CGFloat
    ) -> some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: size, weight: weight, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(1.0)
                .lineLimit(1)
            Spacer(minLength: 8)
            DebouncedSettingsTextField(
                prompt: title,
                value: levelLabelBinding(slide, key: key)
            )
            .frame(width: 150)
            .id("level-\(slide.id)-\(key)")
        }
        .padding(.leading, indent)
        .padding(.top, 2)
    }

    private func slotRow(_ slide: EInkSlide, fieldID: String, ids: [String]) -> some View {
        let index = ids.firstIndex(of: fieldID) ?? 0
        let tool = EInkDataAssembler.selector(fieldID: fieldID)?.tool
        return HStack(spacing: 6) {
            Circle()
                .fill(tool.map { Theme.providerAccent(for: $0) } ?? Color.secondary)
                .frame(width: 6, height: 6)
            // The row has to say which bucket it is before it says anything
            // else, so the name outranks the controls beside it: without the
            // priority the fixed-width picker and field take the row and the
            // name is squeezed to nothing.
            Text(slotRowName(fieldID))
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .layoutPriority(2)
            if let percent = percentByField[fieldID] {
                // `AppLocale.percent` takes a fraction, and a row that read
                // "6,400%" would be a number nobody could trust.
                Text(AppLocale.percent(Double(percent) / 100))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(2)
            }
            Spacer(minLength: 4)
            Picker(L10n.Settings.Eink.labelStyle, selection: slotLabelStyleBinding(slide, fieldID: fieldID)) {
                Text(L10n.Settings.Eink.LabelStyle.slideDefault).tag(EInkSlotLabelStyle?.none)
                ForEach(EInkSlotLabelStyle.allCases, id: \.self) { style in
                    Text(EInkNaming.labelStyle(style)).tag(EInkSlotLabelStyle?.some(style))
                }
            }
            .labelsHidden()
            .frame(width: 112)
            .id("label-style-\(slide.id)-\(fieldID)")

            DebouncedSettingsTextField(
                prompt: L10n.Settings.Eink.slotLabel,
                value: slotLabelBinding(slide, fieldID: fieldID)
            )
            .frame(minWidth: 84, maxWidth: 150)
            .id("label-\(slide.id)-\(fieldID)")

            BorderlessIconButton(systemImage: "chevron.up", help: L10n.Settings.Eink.slotOrder) {
                moveSlot(slide, fieldID: fieldID, by: -1, order: ids)
            }
            .disabled(index == 0)
            BorderlessIconButton(systemImage: "chevron.down", help: L10n.Settings.Eink.slotOrder) {
                moveSlot(slide, fieldID: fieldID, by: 1, order: ids)
            }
            .disabled(index >= ids.count - 1)
            BorderlessIconButton(systemImage: "xmark", help: L10n.Common.remove) {
                setBucket(slide, fieldID: fieldID, selected: false, capacity: 0)
            }
            .disabled(ids.count <= 1)
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .padding(.leading, 20)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .padding(.leading, 20)
        )
        .help(fieldID)
    }

    /// The buckets this account returns that the slide is not already showing,
    /// grouped the way the shown list is.
    ///
    /// Only what the account actually exposes: round 2 offered the whole
    /// static catalog, so a Gemini-only Mac could tick five Claude rows that
    /// never drew.
    private func candidateList(_ slide: EInkSlide, shown: [String], capacity: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(L10n.Settings.Eink.Workflow.chooseContent) {
                let groups = candidateSections(shown: []).map { section in
                    EInkContentPicker.Section(id: section.id, title: section.title,
                        choices: section.fieldIDs.map { EInkContentPicker.Choice(id: $0, title: candidateName($0)) })
                }
                contentRequest = EInkContentPicker.Request(slideID: slide.id, initial: slide.orderedQuotaFieldIDs, sections: groups)
            }
            Text(L10n.Settings.Eink.Workflow.automaticPages)
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func periodPicker(_ slide: EInkSlide, capacity: Int) -> some View {
        let selected = slide.usagePeriods
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(L10n.Usage.Breakdown.periods)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(L10n.Settings.Eink.Workflow.selectionSummary(items: selected.count, pages: max(1, previewPages.count)))
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
                    selected.count == 1 && selected.contains(period)
                )
            }
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private var previewColumn: some View {
        if let group {
            // A group's picture is every screen in its arrangement, which only
            // the section above can resolve — it owns the group's plans and
            // rebuilds them on a change, never in a `body`.
            group.preview
        } else {
            devicePreviewColumn
        }
    }

    private var devicePreviewColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Settings.Eink.uprightPreview)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if previewPages.count > 1 {
                HStack {
                    Button { previewPage = max(0, previewPage - 1) } label: { Image(systemName: "chevron.left") }.disabled(previewPage == 0)
                    Text("\(previewPage + 1) / \(previewPages.count)").monospacedDigit()
                    Button { previewPage = min(previewPages.count - 1, previewPage + 1) } label: { Image(systemName: "chevron.right") }.disabled(previewPage == previewPages.count - 1)
                }
            }
            if let plan = (previewPages.indices.contains(previewPage) ? previewPages[previewPage] : plan) {
                let size = device.orientation.physicalFrame(device.profile)
                // 2x of a landscape device is about 1,260 pt, which a narrow
                // window cannot hold; fall back to device pixels rather than
                // clipping. Whole pixels only — `docs/DESIGN.md` — so there is
                // no third step: a preview smaller than the panel would be a
                // downsampled 1-bit canvas, which lies about the ink.
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
                // Picking a preset on a custom slide is a reset, so it drops
                // the layouts the same way the button does. Leaving them
                // behind is worse than it sounds: the next Edit in Studio
                // writes only the orientation it is on, and rotating the
                // device would then find an old design under another key and
                // draw it instead of the preset just chosen.
                if slide.kind.preset == nil {
                    resetToPreset(slide, preset: preset)
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

    /// Adding or removing one bucket.
    ///
    /// An empty list means "Vibe Bar's own order" to the renderer, so removing
    /// the last slot would put back the very buckets the user just took off.
    /// One always stays, as with the usage periods.
    private func setBucket(_ slide: EInkSlide, fieldID: String, selected: Bool, capacity: Int) {
        updateSlide(slide.id) { current in
            if selected {
                guard !current.quotaFieldIDs.contains(fieldID) else { return }
                current.quotaFieldIDs.append(fieldID)
            } else {
                guard current.quotaFieldIDs.count > 1 else { return }
                current.quotaFieldIDs.removeAll { $0 == fieldID }
                current.options.slotOrder.removeAll { $0 == fieldID }
                current.options.customLabels[fieldID] = nil
                current.options.labelStyles[fieldID] = nil
            }
        }
    }

    /// One step up or down the shown list.
    ///
    /// The order is one flat list even though it is drawn as a tree, which is
    /// what the panel actually prints; a slot moved past its SubProvider's
    /// last bucket simply lands under the next heading.
    private func moveSlot(_ slide: EInkSlide, fieldID: String, by offset: Int, order: [String]) {
        guard let index = order.firstIndex(of: fieldID) else { return }
        let target = index + offset
        guard order.indices.contains(target) else { return }
        var next = order
        next.swapAt(index, target)
        updateSlide(slide.id) { $0.options.slotOrder = next }
    }

    /// The name this slide prints for one level of the tree. Empty inherits.
    private func levelLabelBinding(_ slide: EInkSlide, key: String) -> Binding<String> {
        Binding(
            get: { slide.options.levelLabels[key] ?? "" },
            set: { [slideID = slide.id] value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                updateSlide(slideID) { current in
                    current.options.levelLabels[key] = trimmed.isEmpty ? nil : trimmed
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
                        guard !current.usagePeriods.contains(period) else { return }
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
                    // The field commits on an idle timer and again on its way
                    // out of the view tree, so a keystroke followed quickly by
                    // Clock or Nothing would land after the picker and put the
                    // side back to fixed text.
                    let side = isLeft ? current.options.header?.left : current.options.header?.right
                    guard case .text = side else { return }
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
                updateSlide(slideID) { current in
                    guard case .text = current.options.footer?.content else { return }
                    current.options.footer = EInkFooterConfig(content: .text(value))
                }
            }
        )
    }

    private func labelStyleBinding(_ slide: EInkSlide) -> Binding<EInkSlotLabelStyle> {
        Binding(
            get: { slide.options.labelStyle },
            set: { [slideID = slide.id] value in
                updateSlide(slideID) { $0.options.labelStyle = value }
            }
        )
    }

    /// `nil` means "whatever the slide says", which is the default and the
    /// only way back to it once a slot has been given its own.
    private func slotLabelStyleBinding(
        _ slide: EInkSlide,
        fieldID: String
    ) -> Binding<EInkSlotLabelStyle?> {
        Binding(
            get: { slide.options.labelStyles[fieldID] },
            set: { [slideID = slide.id] value in
                updateSlide(slideID) { current in
                    current.options.labelStyles[fieldID] = value
                }
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
        if let group { group.addPage(); return }
        let slide = EInkSlide.defaultQuotaSlide(
            orientation: device.orientation,
            available: availableQuotaFieldIDs
        )
        updateDevice { $0.slides.append(slide) }
        selectedSlideID = slide.id
    }

    private func removeSlide(_ slideID: String) {
        if let group { group.removePage(slideID); return }
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
        // A group's page is authored on the region's own canvas, and turning a
        // paginated page into pages is a group-shaped edit; the section owns
        // both, so it opens the Studio for one.
        if let group { group.openStudio(slide.id); return }
        if let snapshot, EInkPagination.pages(slide, orientation: device.orientation, profile: device.profile, snapshot: snapshot).count > 1 {
            studioSlide = slide; confirmingStudioPages = true; return
        }
        if slide.kind.preset != nil { explode(slide) }
        LayoutStudioWindowController.shared.open(
            subject: .einkSlide(deviceID: device.deviceID, slideID: slide.id),
            environment: environment
        )
    }

    private func materializeAndEdit(_ original: EInkSlide) {
        guard let snapshot else { return }
        var settings = settingsStore.settings
        guard settings.einkSync.owningGroup(for: device.id) == nil,
              let di = settings.einkSync.devices.firstIndex(where: { $0.id == device.id }),
              let si = settings.einkSync.devices[di].slides.firstIndex(where: { $0.id == original.id }) else { return }
        var pages = EInkPagination.materializedPages(original, orientation: device.orientation, profile: device.profile, snapshot: snapshot)
        let index = min(previewPage, pages.count - 1)
        for i in pages.indices {
            pages[i].title = original.title.isEmpty ? L10n.Settings.Eink.Workflow.slideNumber(number: i + 1) : original.title + " · " + String(i + 1)
        }
        settings.einkSync.devices[di].slides.replaceSubrange(si...si, with: pages)
        if settings.einkSync.devices[di].playbackMode == .single { settings.einkSync.devices[di].singleSlideID = pages[index].id }
        settingsStore.settings = settings
        selectedSlideID = pages[index].id
        explode(pages[index], snapshot: snapshot)
        LayoutStudioWindowController.shared.open(subject: .einkSlide(deviceID: device.id, slideID: pages[index].id), environment: environment)
    }

    private func explode(_ slide: EInkSlide, snapshot supplied: EInkDataSnapshot? = nil) {
        guard let snapshot = supplied ?? environment.einkSyncService?.previewSnapshot else { return }
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
        // Remembered so "Reset to preset" restores the one it came from. A
        // Briefing exploded and reset came back a ledger without it.
        settings.einkSync.devices[index].slides[position].options.sourcePreset = slide.kind.preset
        settingsStore.settings = settings
    }

    /// Back to the preset, and the hand-made layouts go with it.
    ///
    /// Keeping them would leave a slide that draws a preset while four
    /// orientations' worth of edits sat invisibly in `settings.json`, ready to
    /// reappear the next time somebody pressed Edit in Studio.
    private func resetToPreset(_ slide: EInkSlide, preset: EInkPreset? = nil) {
        if group != nil {
            updateSlide(slide.id) { $0.kind = .preset(preset ?? slide.options.sourcePreset ?? .quotaLedger) }
            return
        }
        var settings = settingsStore.settings
        guard let index = settings.einkSync.devices.firstIndex(where: { $0.deviceID == device.deviceID }),
              let position = settings.einkSync.devices[index].slides.firstIndex(where: { $0.id == slide.id })
        else { return }
        let layoutID = slide.kind.layoutID ?? slide.id
        settings.einkCanvasLayouts = settings.einkCanvasLayouts.filter {
            $0.key != layoutID && !$0.key.hasPrefix(layoutID + "/")
        }
        // The preset it was exploded from, or the ledger for a slide that was
        // custom before this existed — which is also what a new slide draws.
        settings.einkSync.devices[index].slides[position].kind =
            .preset(preset ?? slide.options.sourcePreset ?? .quotaLedger)
        settings.einkSync.devices[index].slides[position].options.sourcePreset = nil
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

    /// One page's template, edited in place.
    ///
    /// For a group the "slide" is whatever the active screens draw, and the
    /// section puts it back into that region — the editor never has to know
    /// which region it is or where the group keeps it.
    private func updateSlide(_ slideID: String, _ mutate: (inout EInkSlide) -> Void) {
        if let group {
            guard var slide = device.slide(id: slideID) else { return }
            mutate(&slide)
            group.updateSlide(slideID, slide)
            return
        }
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
        if let group { group.reorderPages(order); return }
        updateDevice { device in
            let byID = Dictionary(device.slides.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            device.slides = order.compactMap { byID[$0] }
        }
    }

    // MARK: - Naming

    private func slideDisplayName(_ slide: EInkSlide) -> String {
        slide.title.isEmpty ? layoutName(for: slide.kind) : slide.title
    }

    private func layoutName(for kind: EInkSlide.Kind) -> String {
        guard let preset = kind.preset else { return L10n.Settings.Eink.customSlide }
        return EInkNaming.preset(preset)
    }

    /// What one shown row calls its bucket.
    ///
    /// The window tier alone — the SubProvider and the group already stand as
    /// the headings above it, and repeating them in every row is the noise the
    /// tree exists to remove. The whole name is still one hover away.
    private func slotRowName(_ fieldID: String) -> String {
        let parts = EInkSlotLabel.parts(for: fieldID, registry: quotaService.fieldRegistry)
        return QuotaGroupLabelLocalizer.display(parts.last ?? fieldID)
    }

    /// What one candidate row calls its bucket: the whole name, because there
    /// is no heading above it saying which group it belongs to.
    private func candidateName(_ fieldID: String) -> String {
        let parts = EInkSlotLabel.parts(for: fieldID, registry: quotaService.fieldRegistry)
        let detail = parts.dropFirst().joined(separator: EInkSlotLabel.separator)
        let fallback = MenuBarFieldCatalog.field(id: fieldID, registry: quotaService.fieldRegistry)?.title
            ?? parts.joined(separator: EInkSlotLabel.separator)
        return QuotaGroupLabelLocalizer.display(detail.isEmpty ? (fallback.isEmpty ? fieldID : fallback) : detail)
    }

    /// One provider's worth of buckets the slide could still add.
    private struct CandidateSection: Identifiable {
        let tool: ToolType
        let bucketID: String?
        let title: String
        var fieldIDs: [String]
        var id: String { "\(tool.rawValue)/\(title)" }
    }

    /// The buckets this account returns that the slide is not showing,
    /// grouped by SubProvider in the order the account offered them.
    private func candidateSections(shown: [String]) -> [CandidateSection] {
        let taken = Set(shown)
        var sections: [CandidateSection] = []
        var index: [String: Int] = [:]
        for fieldID in availableQuotaFieldIDs where !taken.contains(fieldID) {
            guard let selector = EInkDataAssembler.selector(fieldID: fieldID) else { continue }
            let name = selector.tool.quotaSubProviderName(bucketID: selector.bucketID)
            let key = "\(selector.tool.rawValue)/\(name)"
            if let position = index[key] {
                sections[position].fieldIDs.append(fieldID)
                continue
            }
            index[key] = sections.count
            sections.append(
                CandidateSection(
                    tool: selector.tool,
                    bucketID: selector.bucketID,
                    title: name,
                    fieldIDs: [fieldID]
                )
            )
        }
        return sections
    }
}

// MARK: - The shown tree

/// One company's worth of shown slots, as the editor draws them.
///
/// Built from `MenuBarFieldCatalog.orderedSubProviderGroups`, which is what
/// the mini windows and the menu bar already group by — so a bucket sits under
/// the same two headings wherever it is arranged.
struct SlotCompany: Identifiable {
    struct Group: Identifiable {
        /// `nil` for a bucket that sits directly under its SubProvider: there
        /// is no group tier on the panel, so there is no name to rename.
        let key: String?
        let title: String
        var fieldIDs: [String]
        // The first slot in the run, because a run can repeat: two Codex
        // sections either side of a Claude one are two rows, not one.
        var id: String { fieldIDs.first ?? title }
    }

    struct SubProvider: Identifiable {
        let tool: ToolType
        let name: String
        let key: String
        var groups: [Group]
        var id: String { groups.first?.id ?? key }
    }

    let name: String
    let accentTool: ToolType
    /// A company heading repeated from the row above says nothing, exactly as
    /// in the menu bar's own field editor.
    let showsHeader: Bool
    let isFirst: Bool
    var subProviders: [SubProvider]
    var id: String { subProviders.first?.id ?? name }

    /// The flat order, cut into runs.
    ///
    /// Runs, not a grouping: the panel prints one flat list, so a heading
    /// starts wherever the SubProvider changes and starts again if that
    /// SubProvider comes back later. Coalescing every Codex bucket under the
    /// first Codex heading would show an order the panel does not draw, and
    /// would make a slot moved past a heading appear not to move at all.
    /// `MenuBarFieldsEditor` cuts its own list the same way.
    static func tree(fieldIDs: [String], registry: QuotaFieldRegistry) -> [SlotCompany] {
        var companies: [SlotCompany] = []
        var previousCompany: String?
        for fieldID in fieldIDs {
            guard let field = MenuBarFieldCatalog.field(id: fieldID, registry: registry) else { continue }
            let name = field.tool.quotaSubProviderName(bucketID: field.bucketId)
            let key = MenuBarFieldCatalog.subProviderLabelKey(tool: field.tool, name: name)
            let vendor = field.tool.vendorName
            let groupKey = EInkSlotLabel.groupLevelKey(for: fieldID, registry: registry)
            let parts = EInkSlotLabel.parts(for: fieldID, registry: registry)
            // Three tiers means the middle one is the group; two means the
            // bucket sits directly under its SubProvider.
            let groupTitle = QuotaGroupLabelLocalizer.display(parts.count > 2 ? parts[1] : "")

            if var company = companies.last,
               var subProvider = company.subProviders.last,
               subProvider.key == key
            {
                if var group = subProvider.groups.last, group.key == groupKey, groupKey != nil {
                    group.fieldIDs.append(fieldID)
                    subProvider.groups[subProvider.groups.count - 1] = group
                } else {
                    subProvider.groups.append(Group(key: groupKey, title: groupTitle, fieldIDs: [fieldID]))
                }
                company.subProviders[company.subProviders.count - 1] = subProvider
                companies[companies.count - 1] = company
                continue
            }

            let subProvider = SubProvider(
                tool: field.tool,
                name: name,
                key: key,
                groups: [Group(key: groupKey, title: groupTitle, fieldIDs: [fieldID])]
            )
            if var company = companies.last, company.name == vendor {
                company.subProviders.append(subProvider)
                companies[companies.count - 1] = company
            } else {
                companies.append(
                    SlotCompany(
                        name: vendor,
                        accentTool: field.tool == .chatgptChat ? .codex : field.tool,
                        showsHeader: vendor != previousCompany,
                        isFirst: companies.isEmpty,
                        subProviders: [subProvider]
                    )
                )
                previousCompany = vendor
            }
        }
        return companies
    }

}
