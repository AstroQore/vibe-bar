import SwiftUI
import VibeBarCore

/// Settings → Layout: choose how each popover page arranges its cards, and
/// arrange them by hand when that is what you want.
///
/// The blocks are drawn at the cards' *measured* heights, scaled down. A list
/// of equal-sized rows would make the two columns look balanced when the real
/// page is not, which is the one question this screen exists to answer.
///
/// Modules and their names come from `PageModuleCatalog` — the same registry
/// the popover pages render from — so a card that appears in the popover
/// appears here, with the same identity, without a second list to maintain.
///
/// The three modes are not three editors. `PageLayoutModel.arrangement` hands
/// back whatever the selected mode currently produces, and this screen draws
/// that. So what the editor shows is what the popover shows, including a
/// `compact` packing that will move again the next time the cards are measured.
///
/// One editor for all three modes, laid out as the page's segments, because
/// segments belong to all three. The header controls — reorder, merge, add,
/// hide — work the same everywhere; what a *drag* decides is the only thing
/// that follows from the mode:
///
/// - `manual` — segment, column and position.
/// - `compact` / `auto` — segment only. Position inside a segment belongs to the
///   packer or the balancer, and a drag deciding it would be discarded on the
///   next measurement.
struct LayoutEditorView: View {
    @Environment(\.isInLayoutStudio) private var isInLayoutStudio
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var layoutModel: PageLayoutModel
    /// Observed, not merely read: `PageModuleCatalog.descriptors` asks these
    /// two which quota groups and which cost cards exist. Reaching them only
    /// through `environment` would leave the editor showing a stale module
    /// list until some unrelated redraw — a group that appears on the first
    /// refresh, or the cost cards after the first log scan, would not show up
    /// while the Layout tab is open.
    @EnvironmentObject private var quotaService: QuotaService
    @EnvironmentObject private var costService: CostUsageService

    /// Which page this editor opens on. Settings leaves it alone and the
    /// editor remembers its own; the studio names one, because the controls
    /// and the surface on the stage have to be the same page.
    var initialPage: PageLayoutPageID?
    @State private var selectedPage: PageLayoutPageID = .overview
    @State private var hasAppliedInitialPage = false
    @State private var drag: DragState?
    /// Live frames of every block, keyed by page *and* module: switching pages
    /// must not let a module that exists on both (Service Status, say) keep the
    /// other page's position.
    @State private var blockFrames: [String: CGRect] = [:]
    @State private var zoneFrames: [Int: CGRect] = [:]
    @State private var segmentFrames: [Int: CGRect] = [:]
    /// Segments the user has added but not dragged anything into yet.
    ///
    /// An empty segment is never stored — `PageLayoutSegments.normalized` drops
    /// it, which is what keeps a saved layout from accumulating groups nothing
    /// renders. So "add a segment, then drag a card into it" only works if the
    /// empty one lives in view state until it has a card, which is what this is.
    @State private var pendingSegments = 0
    @State private var isNamingPreset = false
    @State private var presetName = ""

    private static let space = "vibebar.layout.editor"
    /// A card is never shorter than this in the editor, however short it is on
    /// the page — below it the label stops being readable and the block stops
    /// being a drag target.
    private static let minimumBlockHeight: CGFloat = 30
    /// Movement, in points, before a press turns into a drag. Without it every
    /// click on a block would nudge the arrangement.
    private static let dragThreshold: CGFloat = 5
    private static let blockSpacing: CGFloat = 5
    /// Height the taller column is scaled to fit.
    private static let editorColumnHeight: Double = 430
    /// How tall the scaled preview may get before it is cut off at the
    /// top of the page, which is the part being arranged.
    private static let previewColumnHeight: CGFloat = 300

    private struct DragState {
        let moduleID: PageLayoutModuleID
        let displayName: String
        let accent: Color
        let size: CGSize
        var location: CGPoint
        var engaged: Bool
    }

    /// One arranged card: its identity, what to call it, and how tall it
    /// actually rendered.
    private struct Block: Identifiable {
        let descriptor: PageModuleDescriptor
        let measured: Double?

        var id: PageLayoutModuleID { descriptor.id }
        /// Measured height, or the module family's stand-in until this page has
        /// been opened once.
        var height: Double { measured ?? descriptor.fallbackHeight }
        var heightLabel: String {
            guard let measured else { return "—pt" }
            return "\(Int(measured.rounded()))pt"
        }
    }

    var body: some View {
        let pages = PageModuleCatalog.editablePages(settings: settingsStore.settings)
        let _ = applyInitialPageIfNeeded()
        let page = pages.contains { $0.page == selectedPage } ? selectedPage : .overview
        let descriptors = PageModuleCatalog.descriptors(
            for: page,
            environment: environment,
            settings: settingsStore.settings
        )
        let mode = layoutModel.mode(for: page)
        let arrangement = displayedArrangement(for: page, descriptors: descriptors)
        let config = arrangement.flattened
        let blocks = Dictionary(
            descriptors.map { descriptor in
                (descriptor.id, Block(descriptor: descriptor, measured: config.measuredHeight(for: descriptor.id)))
            },
            uniquingKeysWith: { first, _ in first }
        )

        VStack(alignment: .leading, spacing: 12) {
            densityRow
            pagePicker(pages: pages, selected: page)
            modeRow(page: page, mode: mode, arrangement: arrangement, descriptors: descriptors)
            controlRow(page: page, config: config, descriptors: descriptors)
            if descriptors.isEmpty {
                Text("This page has no arrangeable cards yet. Open it in the popover once so Vibe Bar can measure them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    zones(
                        page: page,
                        arrangement: arrangement,
                        blocks: blocks,
                        mode: mode,
                        descriptors: descriptors
                    )
                    previewColumnStack(page: page, arrangement: arrangement, blocks: blocks)
                }
            }
            Text(footnote(page: page, mode: mode))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Overlay rather than a ZStack sibling: the floating ghost is
        // positioned absolutely, and a `.position` sibling would accept the
        // full proposed height and make the whole section jump while dragging.
        .overlay(alignment: .topLeading) {
            if let drag, drag.engaged {
                ghost(drag)
            }
        }
        .coordinateSpace(.named(Self.space))
        // The editor sits inside the Settings pane, which restores the
        // system focus ring for its native controls — but everything in here
        // is hand-drawn pills and icon buttons, so the ring goes off again
        // and `VibeBarButtonStyle` marks keyboard focus instead.
        .vibeBarControlFocus()
        .onChange(of: page) { _, newValue in
            // A provider hidden from the popover takes its page with it.
            if selectedPage != newValue { selectedPage = newValue }
            drag = nil
            // The name sheet belongs to the page it was opened from; carrying
            // it across would save the new page's arrangement under it.
            isNamingPreset = false
            // Same for a half-finished segment: it is this page's edit.
            pendingSegments = 0
        }
        .onChange(of: mode) { _, _ in
            drag = nil
            pendingSegments = 0
        }
    }

    /// Once, and only when a caller named one — a later pick inside the
    /// editor must not be snapped back.
    private func applyInitialPageIfNeeded() {
        guard let initialPage, !hasAppliedInitialPage else { return }
        hasAppliedInitialPage = true
        selectedPage = initialPage
    }

    // MARK: - Density

    /// How much room every popover page gives its cards. It lives with the
    /// layout rather than with the menu bar because it is a property of the
    /// surfaces being arranged here — the Studio's inspector is this same
    /// view, so the control is in both places without being two controls.
    private var densityRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(
                L10n.Platform.Macos.MenuBar.displayDensity,
                selection: Binding(
                    get: { settingsStore.settings.popoverDensity },
                    set: { settingsStore.settings.popoverDensity = $0 }
                )
            ) {
                ForEach(PopoverDensity.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(settingsStore.settings.popoverDensity.detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Page picker

    private func pagePicker(
        pages: [(page: PageLayoutPageID, title: String)],
        selected: PageLayoutPageID
    ) -> some View {
        HStack(spacing: 4) {
            ForEach(pages, id: \.page.rawValue) { entry in
                let isSelected = entry.page == selected
                Button {
                    selectedPage = entry.page
                } label: {
                    HStack(spacing: 5) {
                        Text(entry.title)
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        if layoutModel.hasSavedIntent(entry.page) {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 5, height: 5)
                        }
                    }
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .padding(.horizontal, 11)
                    .frame(height: 24)
                    .background {
                        if isSelected {
                            Capsule(style: .continuous)
                                .fill(Color.accentColor.opacity(0.20))
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(Color.accentColor.opacity(0.34), lineWidth: 0.7)
                                )
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                // The ring radius matches the 24 pt capsule the label draws.
                .buttonStyle(.vibeBar(cornerRadius: 12))
                .help(layoutModel.hasSavedIntent(entry.page) ? "\(entry.title) — customized" : entry.title)
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    // MARK: - Mode + presets

    private func modeRow(
        page: PageLayoutPageID,
        mode: PageLayoutMode,
        arrangement: PageLayoutArrangement,
        descriptors: [PageModuleDescriptor]
    ) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(PageLayoutMode.allCases, id: \.self) { candidate in
                    modeButton(candidate, page: page, selected: mode, arrangement: arrangement)
                }
            }
            .padding(3)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            Spacer(minLength: 8)
            presetsMenu(page: page, arrangement: arrangement, descriptors: descriptors)
            Button {
                layoutModel.reset(for: page)
            } label: {
                Label("Restore Defaults", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 11))
            }
            .disabled(!layoutModel.hasSavedIntent(page))
        }
    }

    private func modeButton(
        _ mode: PageLayoutMode,
        page: PageLayoutPageID,
        selected: PageLayoutMode,
        arrangement: PageLayoutArrangement
    ) -> some View {
        let isSelected = mode == selected
        return Button {
            layoutModel.setMode(
                mode,
                for: page,
                displayed: arrangement,
                available: availableModuleIDs(for: page)
            )
        } label: {
            HStack(spacing: 5) {
                Image(systemName: modeIcon(mode))
                    .font(.system(size: 10, weight: .medium))
                Text(modeLabel(mode))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(Color.accentColor.opacity(0.20))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.accentColor.opacity(0.34), lineWidth: 0.7)
                        )
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.vibeBar(cornerRadius: 12))
        .help(modeHelp(mode, page: page))
    }

    private func modeLabel(_ mode: PageLayoutMode) -> String {
        switch mode {
        case .auto: "Auto"
        case .compact: "Compact"
        case .manual: "Manual"
        }
    }

    private func modeIcon(_ mode: PageLayoutMode) -> String {
        mode.symbolName
    }

    private func modeHelp(_ mode: PageLayoutMode, page: PageLayoutPageID) -> String {
        switch mode {
        case .auto:
            return page.isOverview
                ? "Auto — the Overview balances its columns as the cards are measured."
                : "Auto — this page's built-in arrangement."
        case .compact:
            return "Compact — pack each segment into the shortest arrangement its cards fit in."
        case .manual:
            return "Manual — your arrangement, exactly as you dragged it."
        }
    }

    private func presetsMenu(page: PageLayoutPageID, arrangement: PageLayoutArrangement, descriptors: [PageModuleDescriptor]) -> some View {
        let presets = layoutModel.presets(for: page)
        return Menu {
            // Reachable even on a full page: replacing a preset by name costs
            // no slot, and the form below is where that is explained.
            Button("Save Current…") {
                presetName = ""
                isNamingPreset = true
            }
            if presets.isEmpty {
                Text("No saved arrangements")
            } else {
                Divider()
                ForEach(presets, id: \.name) { preset in
                    Menu(preset.name) {
                        Button("Apply") {
                            layoutModel.applyPreset(preset, to: page)
                        }
                        Button("Delete", role: .destructive) {
                            layoutModel.deletePreset(named: preset.name, for: page)
                        }
                    }
                }
            }
        } label: {
            Label("Presets", systemImage: "square.stack.3d.up")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(
            layoutModel.canAddPreset(for: page)
                ? "Save this arrangement under a name, or put a saved one back."
                : "This page is holding all \(AppSettings.maximumPresetsPerPage) saved arrangements — save over one by reusing its name."
        )
        .popover(isPresented: $isNamingPreset, arrowEdge: .bottom) {
            presetNameForm(page: page, arrangement: arrangement, descriptors: descriptors)
                // A native form: no initial selection, but the system focus
                // ring comes back for its text field and buttons.
                .vibeBarNoInitialFocus()
                .vibeBarSystemControlFocus()
        }
    }

    private func presetNameForm(page: PageLayoutPageID, arrangement: PageLayoutArrangement, descriptors: [PageModuleDescriptor]) -> some View {
        let trimmed = StoredPageLayoutPreset.normalizedName(presetName)
        let replaces = layoutModel.presetWouldReplace(named: trimmed, for: page)
        // Only a genuinely new name is blocked by the cap; reusing an existing
        // one overwrites it and leaves the count where it was.
        let blockedByLimit = !trimmed.isEmpty && !replaces && !layoutModel.canAddPreset(for: page)
        return VStack(alignment: .leading, spacing: 9) {
            Text("Save arrangement")
                .font(.system(size: 12, weight: .semibold))
            Text("Saving “\(modeLabel(layoutModel.mode(for: page)))” as it stands now. Applying it later puts the page back into that mode — a Manual preset restores its exact columns, a Compact one its segments.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 230, alignment: .leading)
            TextField("Name", text: $presetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 230)
                .onSubmit { savePreset(page: page, arrangement: arrangement, descriptors: descriptors) }
            if blockedByLimit {
                Label(
                    "Preset limit reached — use an existing name to replace.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 230, alignment: .leading)
            } else if replaces {
                Label("Replaces “\(trimmed)”.", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 230, alignment: .leading)
            }
            HStack {
                Spacer(minLength: 0)
                Button("Cancel") { isNamingPreset = false }
                Button(replaces ? "Replace" : "Save") { savePreset(page: page, arrangement: arrangement, descriptors: descriptors) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!layoutModel.canSavePreset(named: presetName, for: page))
            }
        }
        .padding(13)
    }

    private func savePreset(page: PageLayoutPageID, arrangement: PageLayoutArrangement, descriptors: [PageModuleDescriptor]) {
        let snapshot = layoutModel.presetSnapshot(for: page, displayed: arrangement, descriptors: descriptors)
        guard layoutModel.savePreset(named: presetName, for: page, layout: snapshot) else { return }
        presetName = ""
        isNamingPreset = false
    }

    // MARK: - Ratio + status

    private func controlRow(
        page: PageLayoutPageID,
        config: PageLayoutConfig,
        descriptors: [PageModuleDescriptor]
    ) -> some View {
        HStack(spacing: 10) {
            ForEach(PageColumnRatio.allCases, id: \.self) { ratio in
                ratioButton(ratio, page: page, config: config)
            }
            Spacer(minLength: 8)
            visibilityMenu(page: page, descriptors: descriptors)
            if layoutModel.hasSavedIntent(page) {
                Text("Customized")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            } else {
                Text("Default")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func visibilityMenu(
        page: PageLayoutPageID,
        descriptors: [PageModuleDescriptor]
    ) -> some View {
        let visibleCount = descriptors.count { !layoutModel.isHidden($0.id, on: page) }
        return Menu {
            Button("Show All") {
                for descriptor in descriptors {
                    layoutModel.setHidden(false, for: descriptor.id, page: page)
                }
            }
            .disabled(visibleCount == descriptors.count)
            Button("Hide All") {
                for descriptor in descriptors {
                    layoutModel.setHidden(true, for: descriptor.id, page: page)
                }
            }
            .disabled(visibleCount == 0)
            Divider()
            ForEach(descriptors) { descriptor in
                Toggle(
                    descriptor.displayName,
                    isOn: Binding(
                        get: { !layoutModel.isHidden(descriptor.id, on: page) },
                        set: { layoutModel.setHidden(!$0, for: descriptor.id, page: page) }
                    )
                )
            }
        } label: {
            Label("Visibility \(visibleCount)/\(descriptors.count)", systemImage: "eye")
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Show or hide every card on this page. The eye on each card provides the same control.")
    }

    private func ratioButton(
        _ ratio: PageColumnRatio,
        page: PageLayoutPageID,
        config: PageLayoutConfig
    ) -> some View {
        let isSelected = config.ratio == ratio
        return Button {
            layoutModel.setRatio(
                ratio,
                for: page,
                resolved: config,
                available: availableModuleIDs(for: page)
            )
        } label: {
            HStack(spacing: 6) {
                ratioIcon(ratio)
                Text(ratioLabel(ratio))
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.34) : Color.primary.opacity(0.08),
                        lineWidth: 0.7
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.vibeBar(cornerRadius: 7))
    }

    private func ratioIcon(_ ratio: PageColumnRatio) -> some View {
        let width: CGFloat = 20
        let gap: CGFloat = 2
        let left = (width - gap) * ratio.leftFraction
        return HStack(spacing: gap) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .frame(width: left, height: 12)
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .frame(width: max(0, width - gap - left), height: 12)
        }
        .foregroundStyle(.secondary)
        .frame(width: width, height: 12)
    }

    private func ratioLabel(_ ratio: PageColumnRatio) -> String {
        switch ratio {
        case .narrowWide: "Narrow · Wide"
        case .equal: "Equal"
        case .wideNarrow: "Wide · Narrow"
        }
    }

    // MARK: - Zones

    /// The editable picture of the page: one bordered group per segment, each
    /// holding that segment's slice of the two columns.
    ///
    /// One editor for all three modes, because segments now belong to all three.
    /// What a drag decides is the only thing that differs:
    ///
    /// - `manual` — segment, column and position, with an insertion line.
    /// - `compact` / `auto` — segment only. Where the card lands inside it is
    ///   the packer's or the balancer's answer, so a drop into its own segment
    ///   is deliberately a no-op rather than a re-order that would be discarded
    ///   on the next measurement.
    ///
    /// The groups are drawn as boxes; the popover draws no boundary at all. That
    /// is the point of the picture — the boxes say what the ordering constraint
    /// is, and the preview beside them says what it produces.
    private func zones(
        page: PageLayoutPageID,
        arrangement: PageLayoutArrangement,
        blocks: [PageLayoutModuleID: Block],
        mode: PageLayoutMode,
        descriptors: [PageModuleDescriptor]
    ) -> some View {
        let structure = segmentStructure(page: page, arrangement: arrangement, descriptors: descriptors)
        let heights = structure.map { segmentHeight($0.columns, blocks: blocks) }
        // Scaled against the whole page, not one segment, so a tall segment
        // still reads as the tall one.
        let scale = min(0.4, Self.editorColumnHeight / max(1, heights.reduce(0, +)))
        let target = segmentDropTarget(count: structure.count)
        return VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(structure.enumerated()), id: \.offset) { index, segment in
                segmentZone(
                    index,
                    page: page,
                    segment: segment,
                    structure: structure,
                    blocks: blocks,
                    height: heights[index],
                    scale: scale,
                    mode: mode,
                    isTarget: target == index
                )
            }
            HStack(spacing: 8) {
                Button {
                    pendingSegments += 1
                } label: {
                    Label("Add Segment", systemImage: "plus.rectangle.on.rectangle")
                        .font(.system(size: 11))
                }
                .disabled(structure.count >= PageLayoutSegments.maximumCount)
                .help(
                    structure.count >= PageLayoutSegments.maximumCount
                        ? "A page holds at most \(PageLayoutSegments.maximumCount) segments."
                        : "Add an empty segment, then drag a card into it."
                )
                Spacer(minLength: 0)
            }
        }
    }

    /// One segment as the editor draws it.
    private struct SegmentSlice {
        /// Everything the segment holds, switched-off cards included — this is
        /// what an edit persists, so a hidden card keeps its group.
        let members: [PageLayoutModuleID]
        /// The visible cards, split the way the page will actually render them.
        let columns: [[PageLayoutModuleID]]
        /// Cards the user switched off, shown dimmed so they can be found and
        /// switched back on.
        let hidden: [PageLayoutModuleID]
    }

    /// The segments on screen: the page's resolved grouping — including cards
    /// switched off, which is the only place they can be found — with each
    /// segment's visible cards placed in the columns the arrangement gave them,
    /// plus any empty segment the user added and has not filled yet.
    private func segmentStructure(
        page: PageLayoutPageID,
        arrangement: PageLayoutArrangement,
        descriptors: [PageModuleDescriptor]
    ) -> [SegmentSlice] {
        let groups = layoutModel.resolvedSegments(
            for: page,
            descriptors: descriptors,
            includingHidden: true
        )
        let flowed = arrangement.flattened
        var placement: [PageLayoutModuleID: (column: Int, rank: Int)] = [:]
        for index in 0..<PageLayoutConfig.columnCount {
            for (rank, moduleID) in flowed.column(index).enumerated() {
                placement[moduleID] = (index, rank)
            }
        }
        var slices = groups.map { members -> SegmentSlice in
            var columns = [[PageLayoutModuleID]](
                repeating: [],
                count: PageLayoutConfig.columnCount
            )
            var hidden: [PageLayoutModuleID] = []
            for moduleID in members {
                // Classified by what the user chose, not by what happens to be
                // missing from the arrangement: the eye has to toggle the same
                // flag it is drawn from, or a card could get stuck showing
                // "hidden" with no way back. Anything else the arrangement did
                // not place is still shown, at the end of the left column.
                guard !layoutModel.isHidden(moduleID, on: page) else {
                    hidden.append(moduleID)
                    continue
                }
                columns[placement[moduleID]?.column ?? 0].append(moduleID)
            }
            // The arrangement's own order down each column, not the segment's
            // membership order, so the editor stacks the blocks the way the page
            // stacks the cards.
            columns = columns.map { column in
                column.sorted {
                    (placement[$0]?.rank ?? .max) < (placement[$1]?.rank ?? .max)
                }
            }
            return SegmentSlice(members: members, columns: columns, hidden: hidden)
        }
        slices.append(
            contentsOf: (0..<pendingSegments).map { _ in
                SegmentSlice(
                    members: [],
                    columns: [[PageLayoutModuleID]](
                        repeating: [],
                        count: PageLayoutConfig.columnCount
                    ),
                    hidden: []
                )
            }
        )
        return slices
    }

    /// What one segment contributes to the page: its taller column. Cards the
    /// user switched off contribute nothing, because the popover will not draw
    /// them.
    private func segmentHeight(
        _ columns: [[PageLayoutModuleID]],
        blocks: [PageLayoutModuleID: Block]
    ) -> Double {
        columns
            .map { column in column.reduce(0.0) { $0 + (blocks[$1]?.height ?? 0) } }
            .max() ?? 0
    }

    private func segmentZone(
        _ index: Int,
        page: PageLayoutPageID,
        segment: SegmentSlice,
        structure: [SegmentSlice],
        blocks: [PageLayoutModuleID: Block],
        height: Double,
        scale: Double,
        mode: PageLayoutMode,
        isTarget: Bool
    ) -> some View {
        let membership = structure.map(\.members)
        let cards = segment.columns.flatMap { $0 }
        let isEmpty = segment.members.isEmpty
        // An empty segment is always one the user just added, so it is only ever
        // trailing: moving a card past it, or a segment below it, is meaningless.
        let nextIsEmpty = membership.indices.contains(index + 1) && membership[index + 1].isEmpty
        let target = mode == .manual
            ? manualDropTarget(page: page, segment: segment, at: index, count: structure.count)
            : nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Segment \(index + 1)")
                    .font(.system(size: 11, weight: .semibold))
                Text("· \(cards.count) card\(cards.count == 1 ? "" : "s") · \(Int(height.rounded()))pt")
                    .font(.system(size: 10, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                segmentButton("chevron.up", help: "Move this segment up") {
                    moveSegment(index, by: -1, page: page, membership: membership)
                }
                .disabled(index == 0 || isEmpty)
                segmentButton("chevron.down", help: "Move this segment down") {
                    moveSegment(index, by: 1, page: page, membership: membership)
                }
                .disabled(index >= membership.count - 1 || isEmpty || nextIsEmpty)
                if isEmpty {
                    segmentButton("xmark", help: "Remove this empty segment") {
                        pendingSegments = max(0, pendingSegments - 1)
                    }
                } else {
                    segmentButton(
                        "arrow.triangle.merge",
                        help: "Merge these cards into the segment above"
                    ) {
                        mergeSegmentUp(index, page: page, membership: membership)
                    }
                    .disabled(index == 0)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                ForEach(0..<PageLayoutConfig.columnCount, id: \.self) { column in
                    segmentColumn(
                        column,
                        page: page,
                        segment: segment,
                        structure: structure,
                        blocks: blocks,
                        scale: scale,
                        mode: mode,
                        insertionIndex: target?.column == column ? target?.index : nil
                    )
                }
            }
            if !segment.hidden.isEmpty {
                hiddenStrip(segment.hidden, page: page, blocks: blocks)
            }
            if cards.isEmpty {
                Text(isEmpty ? "Empty — drag a card here" : "Every card here is hidden")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 38)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(
                    isTarget ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.07),
                    lineWidth: 0.8
                )
        )
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(Self.space))
        } action: { frame in
            segmentFrames[index] = frame
        }
    }

    private func segmentColumn(
        _ column: Int,
        page: PageLayoutPageID,
        segment: SegmentSlice,
        structure: [SegmentSlice],
        blocks: [PageLayoutModuleID: Block],
        scale: Double,
        mode: PageLayoutMode,
        insertionIndex: Int?
    ) -> some View {
        let moduleIDs = segment.columns.indices.contains(column) ? segment.columns[column] : []
        let others = moduleIDs.filter { $0 != drag?.moduleID }
        return VStack(spacing: Self.blockSpacing) {
            ForEach(moduleIDs, id: \.self) { moduleID in
                if let block = blocks[moduleID] {
                    blockView(block, page: page, scale: scale, isEditable: true, isHidden: false) {
                        applyDrop(block, page: page, mode: mode, structure: structure)
                    }
                    // The card stays where it is, dimmed, while its ghost
                    // floats: pulling it out of the stack would shift every
                    // block below it, moving the very frames the drop target
                    // is computed from.
                    .opacity(drag?.engaged == true && drag?.moduleID == moduleID ? 0.25 : 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        // Drawn as an overlay, not inserted into the stack, for the same
        // reason: an inline 2.5 pt line would nudge every block below it.
        .overlay(alignment: .top) {
            if let insertionIndex,
               let offset = insertionOffset(page: page, at: insertionIndex, others: others) {
                Capsule(style: .continuous)
                    .fill(Color.accentColor)
                    .frame(height: 2.5)
                    .offset(y: offset)
            }
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(Self.space))
        } action: { frame in
            // Every segment reports the same two x ranges, so the last writer
            // wins harmlessly: the column hit test only reads `x`.
            zoneFrames[column] = frame
        }
    }

    /// Cards switched off in this segment, kept on screen so they can be found
    /// and switched back on. They are not draggable — a card that renders
    /// nowhere has no position to choose — and they carry no height.
    private func hiddenStrip(
        _ moduleIDs: [PageLayoutModuleID],
        page: PageLayoutPageID,
        blocks: [PageLayoutModuleID: Block]
    ) -> some View {
        VStack(alignment: .leading, spacing: Self.blockSpacing) {
            Text("Hidden")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            ForEach(moduleIDs, id: \.self) { moduleID in
                if let block = blocks[moduleID] {
                    blockView(block, page: page, scale: 0, isEditable: false, isHidden: true) {}
                }
            }
        }
        .padding(.top, 4)
    }

    /// Vertical position of the insertion line, measured from the top of the
    /// segment's column stack, from the frames the blocks actually occupy.
    private func insertionOffset(
        page: PageLayoutPageID,
        at index: Int,
        others: [PageLayoutModuleID]
    ) -> CGFloat? {
        guard !others.isEmpty else { return 0 }
        if index >= others.count {
            guard let last = blockFrames[frameKey(page, others[others.count - 1])],
                  let first = blockFrames[frameKey(page, others[0])]
            else { return nil }
            return last.maxY - first.minY + Self.blockSpacing / 2
        }
        guard let frame = blockFrames[frameKey(page, others[index])],
              let first = blockFrames[frameKey(page, others[0])]
        else { return nil }
        return frame.minY - first.minY - Self.blockSpacing / 2
    }

    private func segmentButton(
        _ systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.vibeBar)
        .foregroundStyle(.secondary)
        .help(help)
    }

    // MARK: - Blocks

    @ViewBuilder
    private func blockView(
        _ block: Block,
        page: PageLayoutPageID,
        scale: Double,
        isEditable: Bool,
        isHidden: Bool,
        onRelease: @escaping () -> Void
    ) -> some View {
        // A hidden card is drawn at the minimum height whatever it measures: it
        // contributes nothing to the page, so drawing it proportionally would
        // make a switched-off chart dominate the picture of a page it is not on.
        let height = isHidden
            ? Self.minimumBlockHeight
            : max(Self.minimumBlockHeight, CGFloat(block.height * scale))
        let body = blockBody(block, height: height, isEditable: isEditable, isHidden: isHidden)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(Self.space))
            } action: { frame in
                blockFrames[frameKey(page, block.id)] = frame
            }
            .help("\(block.descriptor.displayName) · \(block.heightLabel)")
        Group {
            if isEditable {
                body.gesture(dragGesture(block: block, page: page, height: height, onRelease: onRelease))
            } else {
                body
            }
        }
        // On top of the block rather than beside it, so the eye is inside the
        // card's own bounds and — being the topmost view — takes the click that
        // the drag gesture underneath would otherwise capture.
        .overlay(alignment: .topTrailing) {
            visibilityToggle(block, page: page, isHidden: isHidden)
        }
    }

    private func visibilityToggle(
        _ block: Block,
        page: PageLayoutPageID,
        isHidden: Bool
    ) -> some View {
        Button {
            layoutModel.setHidden(!isHidden, for: block.id, page: page)
        } label: {
            Image(systemName: isHidden ? "eye.slash" : "eye")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.vibeBar)
        .help(
            isHidden
                ? "Show “\(block.descriptor.displayName)” on this page"
                : "Hide “\(block.descriptor.displayName)” from this page"
        )
    }

    private func blockBody(
        _ block: Block,
        height: CGFloat,
        isEditable: Bool,
        isHidden: Bool
    ) -> some View {
        let accent = block.descriptor.accent.color
        return HStack(alignment: .top, spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(accent.opacity(0.85))
                .frame(width: 3)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 1) {
                Text(block.descriptor.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(isHidden ? "hidden" : block.heightLabel)
                    .font(.system(size: 9, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            // The grip is the affordance, so it appears only where dragging
            // actually does something.
            if isEditable {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 7)
        // Room for the eye, which floats over the block's trailing edge.
        .padding(.trailing, 22)
        .padding(.vertical, 5)
        .frame(height: height, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(accent.opacity(isHidden ? 0.05 : 0.11))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(
                    accent.opacity(isHidden ? 0.14 : 0.30),
                    style: StrokeStyle(lineWidth: 0.7, dash: isHidden ? [3, 2] : [])
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .opacity(isHidden ? 0.5 : 1)
    }

    // MARK: - Dragging

    private func dragGesture(
        block: Block,
        page: PageLayoutPageID,
        height: CGFloat,
        onRelease: @escaping () -> Void
    ) -> some Gesture {
        // `minimumDistance: 0` so the press is captured immediately — the
        // gesture then owns the pointer until release, the way a pointer
        // capture would — but nothing moves until the 5 pt threshold below is
        // crossed, so a plain click can never reorder the page.
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let width = blockFrames[frameKey(page, block.id)]?.width ?? 180
                var state = drag ?? DragState(
                    moduleID: block.id,
                    displayName: block.descriptor.displayName,
                    accent: block.descriptor.accent.color,
                    size: CGSize(width: width, height: height),
                    location: value.location,
                    engaged: false
                )
                guard state.moduleID == block.id else { return }
                state.location = value.location
                if !state.engaged,
                   hypot(value.translation.width, value.translation.height) >= Self.dragThreshold {
                    state.engaged = true
                }
                drag = state
            }
            .onEnded { _ in
                // The drop reads `drag`, so it runs before the `defer` clears
                // it.
                defer { drag = nil }
                guard let state = drag, state.moduleID == block.id, state.engaged else { return }
                onRelease()
            }
    }

    /// The card joins the segment it was dropped on — and, in `manual`, the
    /// column and position too.
    ///
    /// In the computed modes a drop inside the card's own segment is
    /// deliberately a no-op: where it sits inside is the packer's or the
    /// balancer's answer, and a re-order would be discarded on the next pass.
    private func applyDrop(
        _ block: Block,
        page: PageLayoutPageID,
        mode: PageLayoutMode,
        structure: [SegmentSlice]
    ) {
        let membership = structure.map(\.members)
        guard let target = segmentDropTarget(count: structure.count),
              structure.indices.contains(target)
        else { return }

        var next = membership
        for index in next.indices {
            next[index].removeAll { $0 == block.id }
        }
        next[target].append(block.id)

        guard mode == .manual else {
            guard !membership[target].contains(block.id) else { return }
            layoutModel.applySegments(next, for: page, available: availableModuleIDs(for: page))
            // Whatever is still empty cannot be stored, so it goes back to being
            // a pending segment instead of vanishing under the user's pointer.
            pendingSegments = next.filter(\.isEmpty).count
            return
        }

        let movedColumns = manualDropTarget(
            page: page,
            segment: structure[target],
            at: target,
            count: structure.count
        )
        .flatMap { spot in
            manualColumns(
                moving: block.id,
                to: spot,
                inSegment: target,
                structure: structure,
                membership: next,
                ratio: layoutModel.ratio(for: page)
            )
        }
        // The two halves of a manual drop change independently: a card can
        // change segment without changing its place in the column (the segment
        // below starts exactly where it already sat), and it can move within its
        // own segment without changing group. Either one alone is an edit; a
        // click-sized drag that does neither must not write the settings file.
        let changedSegment = !membership[target].contains(block.id)
        guard changedSegment || movedColumns != nil else { return }
        layoutModel.applySegments(
            next,
            columns: movedColumns,
            for: page,
            available: availableModuleIDs(for: page)
        )
        pendingSegments = next.filter(\.isEmpty).count
    }

    /// Where the dragged block would land inside the segment it is over — the
    /// column, and the index among that segment's cards in it.
    ///
    /// `nil` unless the pointer is actually over this segment, so only the
    /// segment being targeted draws an insertion line.
    private func manualDropTarget(
        page: PageLayoutPageID,
        segment: SegmentSlice,
        at index: Int,
        count: Int
    ) -> (column: Int, index: Int)? {
        guard let drag, drag.engaged, segmentDropTarget(count: count) == index else { return nil }
        let column = nearestColumn(to: drag.location)
        let others = (segment.columns.indices.contains(column) ? segment.columns[column] : [])
            .filter { $0 != drag.moduleID }
        var position = others.count
        for (offset, moduleID) in others.enumerated() {
            guard let frame = blockFrames[frameKey(page, moduleID)] else { continue }
            if drag.location.y < frame.midY {
                position = offset
                break
            }
        }
        return (column, position)
    }

    /// The page's two columns with `moduleID` moved to `spot` inside segment
    /// `index` — the absolute position that local drop implies once the earlier
    /// segments' share of the column is counted.
    ///
    /// `nil` when nothing actually moved, so a click-sized drag does not write
    /// the settings file.
    private func manualColumns(
        moving moduleID: PageLayoutModuleID,
        to spot: (column: Int, index: Int),
        inSegment index: Int,
        structure: [SegmentSlice],
        membership: [[PageLayoutModuleID]],
        ratio: PageColumnRatio
    ) -> PageLayoutConfig? {
        var columns = [[PageLayoutModuleID]](repeating: [], count: PageLayoutConfig.columnCount)
        for segment in structure {
            for column in columns.indices where segment.columns.indices.contains(column) {
                columns[column].append(contentsOf: segment.columns[column])
            }
        }
        let before = columns
        let rank = PageLayoutSegments.ordering(membership)
        let preceding = columns[spot.column]
            .filter { $0 != moduleID && (rank[$0] ?? index) < index }
            .count
        let moved = PageLayoutConfig(ratio: ratio, columns: columns)
            .moving(moduleID, toColumn: spot.column, at: preceding + spot.index)
        guard moved.columns != before else { return nil }
        return moved
    }

    private func moveSegment(
        _ index: Int,
        by offset: Int,
        page: PageLayoutPageID,
        membership: [[PageLayoutModuleID]]
    ) {
        var next = membership
        let target = index + offset
        guard next.indices.contains(index), next.indices.contains(target) else { return }
        next.swapAt(index, target)
        layoutModel.applySegments(next, for: page, available: availableModuleIDs(for: page))
        pendingSegments = next.filter(\.isEmpty).count
    }

    private func mergeSegmentUp(
        _ index: Int,
        page: PageLayoutPageID,
        membership: [[PageLayoutModuleID]]
    ) {
        guard index > 0, membership.indices.contains(index) else { return }
        var next = membership
        next[index - 1].append(contentsOf: next.remove(at: index))
        layoutModel.applySegments(next, for: page, available: availableModuleIDs(for: page))
        pendingSegments = next.filter(\.isEmpty).count
    }

    /// Which segment the pointer is over. Segments stack vertically, so this is
    /// a `y` hit test — the mirror of `nearestColumn`'s `x` one.
    ///
    /// - Parameter count: segments on screen right now. `segmentFrames` can
    ///   still hold the frame of one that has just been removed, and the nearest
    ///   match must not be an index that no longer exists.
    private func segmentDropTarget(count: Int) -> Int? {
        guard let drag, drag.engaged else { return nil }
        let point = drag.location
        var best: Int?
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, frame) in segmentFrames where index < count {
            if frame.minY <= point.y, point.y <= frame.maxY { return index }
            let distance = Double(min(abs(point.y - frame.minY), abs(point.y - frame.maxY)))
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    private func frameKey(_ page: PageLayoutPageID, _ moduleID: PageLayoutModuleID) -> String {
        "\(page.rawValue)|\(moduleID.rawValue)"
    }

    private func nearestColumn(to point: CGPoint) -> Int {
        var best = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for index in 0..<PageLayoutConfig.columnCount {
            guard let frame = zoneFrames[index] else { continue }
            if frame.minX <= point.x, point.x <= frame.maxX { return index }
            let distance = Double(min(abs(point.x - frame.minX), abs(point.x - frame.maxX)))
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    private func ghost(_ state: DragState) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(state.accent)
                .frame(width: 3, height: 16)
            Text(state.displayName)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(width: max(120, state.size.width), height: max(28, min(state.size.height, 60)), alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.background.secondary)
                .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(state.accent.opacity(0.6), lineWidth: 1)
        )
        .position(x: state.location.x, y: state.location.y)
        .allowsHitTesting(false)
    }

    // MARK: - Preview

    private func preview(
        arrangement: PageLayoutArrangement,
        blocks: [PageLayoutModuleID: Block]
    ) -> some View {
        // Exactly what the popover will draw: the two continuous columns, from
        // the same arrangement call the popover makes. The zones beside this
        // show the segment boxes; this shows what they produce, which is a page
        // with no boundary in it at all.
        let flowed = arrangement.flattened
        let pageHeight = (0..<PageLayoutConfig.columnCount)
            .map { index in flowed.column(index).reduce(0.0) { $0 + (blocks[$1]?.height ?? 0) } }
            .max() ?? 0
        let scale = min(0.12, Self.previewColumnHeight / max(1, pageHeight))
        let width: CGFloat = 150
        let gap: CGFloat = 4
        let leftWidth = (width - gap) * ratioFraction(arrangement.ratio)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Preview")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                // Stand-in for the popover's title band, so the preview reads
                // as the popover rather than as two loose stacks.
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.primary.opacity(0.14))
                    .frame(height: 7)
                HStack(alignment: .top, spacing: gap) {
                    previewColumn(flowed.column(0), blocks: blocks, scale: scale)
                        .frame(width: leftWidth)
                    previewColumn(flowed.column(1), blocks: blocks, scale: scale)
                        .frame(width: max(0, width - gap - leftWidth))
                }
            }
            .padding(7)
            .frame(width: width + 14, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 0.7)
            )
        }
    }

    /// The schematic, and the way out to the full-size one.
    ///
    /// The skeleton is what belongs here: it fits the space a settings pane
    /// has, and reading structure is what arranging needs. Seeing the real
    /// thing needs room this pane does not have — that is the studio's job.
    private func previewColumnStack(
        page: PageLayoutPageID,
        arrangement: PageLayoutArrangement,
        blocks: [PageLayoutModuleID: Block]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            preview(arrangement: arrangement, blocks: blocks)
            if !isInLayoutStudio {
                LayoutStudioButton {
                    LayoutStudioWindowController.shared.open(
                        subject: .popoverPage(page),
                        environment: environment
                    )
                }
            }
        }
    }

    private func previewColumn(
        _ moduleIDs: [PageLayoutModuleID],
        blocks: [PageLayoutModuleID: Block],
        scale: Double
    ) -> some View {
        VStack(spacing: 2) {
            ForEach(moduleIDs, id: \.self) { moduleID in
                if let block = blocks[moduleID] {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(block.descriptor.accent.color.opacity(0.55))
                        .frame(height: max(3, CGFloat(block.height * scale)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func ratioFraction(_ ratio: PageColumnRatio) -> CGFloat {
        CGFloat(ratio.leftFraction)
    }

    // MARK: - Helpers

    /// Modules the page can draw right now. The saved layout may name more;
    /// `PageLayoutResolver.mergingEdit` needs this set to tell "the user moved
    /// this away" from "this is not on screen at the moment".
    ///
    /// Cards the user switched off count as not on screen, which is what makes
    /// switching one back on return it to the column and segment it left.
    private func availableModuleIDs(for page: PageLayoutPageID) -> [PageLayoutModuleID] {
        layoutModel.visibleModuleIDs(
            for: page,
            descriptors: PageModuleCatalog.descriptors(
                for: page,
                environment: environment,
                settings: settingsStore.settings
            )
        )
    }

    /// Exactly what the popover would draw for this page right now — the same
    /// call the popover itself makes, so the two cannot disagree.
    private func displayedArrangement(
        for page: PageLayoutPageID,
        descriptors: [PageModuleDescriptor]
    ) -> PageLayoutArrangement {
        layoutModel.arrangement(
            for: page,
            descriptors: descriptors,
            // The popover's own card gap, so the arrangement the editor shows
            // is the one the popover's spacing produces.
            spacing: Double(
                Theme.overviewDensity(for: settingsStore.settings.popoverDensity).interSectionSpacing
            )
        )
    }

    private func footnote(page: PageLayoutPageID, mode: PageLayoutMode) -> String {
        let shared = "Segments are a reading order, not a row: a segment's cards sit above the next segment's inside each column, and the columns never wait for each other, so the page has no gap at a boundary. The eye on a card hides it from this page — it keeps its place and comes back where it was. An empty segment is forgotten once you leave this screen."
        switch mode {
        case .manual:
            return "Drag a card to reorder it, move it between columns, or move it into another segment. Cards are drawn at their measured height, so the taller column here is the taller column in the popover; a card with no measurement yet shows “—pt”. \(shared)"
        case .compact:
            return "Compact packs each segment into whichever two columns make the page shortest, starting each one from the heights the segment above left behind. Drag a card onto another segment to move it — where it lands inside is the packer's call. It re-packs when the measured heights move enough to change the answer. \(shared)"
        case .auto:
            let intro = page.isOverview
                ? "The Overview balances its columns automatically, quota cards first, inside the segments shown."
                : "This page uses its built-in split, ordered by the segments shown. Pick Compact or Manual, or a width split, to take the columns over too."
            return "\(intro) Drag a card onto another segment to re-group it; which column it lands in stays automatic. \(shared)"
        }
    }
}
