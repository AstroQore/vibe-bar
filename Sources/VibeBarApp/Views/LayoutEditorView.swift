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
/// What is editable follows from what each mode leaves to the user:
///
/// - `manual` — two column zones, and a drag decides both column and position.
/// - `compact` — one zone per segment. Position inside a segment belongs to the
///   packer, so a drag only decides *which* segment a card is in; the header
///   controls reorder, merge and add segments.
/// - `auto` — read-only. The page arranges itself, and a drag would be
///   discarded on the next measurement.
struct LayoutEditorView: View {
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

    @State private var selectedPage: PageLayoutPageID = .overview
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
    /// it, which is what keeps a saved layout from accumulating bands nothing
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
    private static let previewColumnHeight: Double = 132

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
            pagePicker(pages: pages, selected: page)
            modeRow(page: page, mode: mode, arrangement: arrangement)
            controlRow(page: page, config: config)
            if descriptors.isEmpty {
                Text("This page has no arrangeable cards yet. Open it in the popover once so Vibe Bar can measure them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    zones(page: page, arrangement: arrangement, blocks: blocks, mode: mode)
                    preview(arrangement: arrangement, blocks: blocks)
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
                        if layoutModel.isCustomized(entry.page) {
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
                .buttonStyle(.plain)
                .focusable(false)
                .help(layoutModel.isCustomized(entry.page) ? "\(entry.title) — customized" : entry.title)
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
        arrangement: PageLayoutArrangement
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
            presetsMenu(page: page, arrangement: arrangement)
            Button {
                layoutModel.reset(for: page)
            } label: {
                Label("Restore Defaults", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 11))
            }
            .disabled(!layoutModel.isCustomized(page))
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
        .buttonStyle(.plain)
        .focusable(false)
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
        switch mode {
        case .auto: "wand.and.stars"
        case .compact: "arrow.down.forward.and.arrow.up.backward"
        case .manual: "hand.point.up.left"
        }
    }

    private func modeHelp(_ mode: PageLayoutMode, page: PageLayoutPageID) -> String {
        switch mode {
        case .auto:
            return page.isOverview
                ? "Auto — the Overview balances its columns as the cards are measured."
                : "Auto — this page's built-in arrangement."
        case .compact:
            return "Compact — pack each segment into the shortest band its cards fit in."
        case .manual:
            return "Manual — your arrangement, exactly as you dragged it."
        }
    }

    private func presetsMenu(page: PageLayoutPageID, arrangement: PageLayoutArrangement) -> some View {
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
            presetNameForm(page: page, arrangement: arrangement)
        }
    }

    private func presetNameForm(page: PageLayoutPageID, arrangement: PageLayoutArrangement) -> some View {
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
                .onSubmit { savePreset(page: page, arrangement: arrangement) }
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
                Button(replaces ? "Replace" : "Save") { savePreset(page: page, arrangement: arrangement) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!layoutModel.canSavePreset(named: presetName, for: page))
            }
        }
        .padding(13)
    }

    private func savePreset(page: PageLayoutPageID, arrangement: PageLayoutArrangement) {
        let snapshot = layoutModel.presetSnapshot(for: page, displayed: arrangement)
        guard layoutModel.savePreset(named: presetName, for: page, layout: snapshot) else { return }
        presetName = ""
        isNamingPreset = false
    }

    // MARK: - Ratio + status

    private func controlRow(page: PageLayoutPageID, config: PageLayoutConfig) -> some View {
        HStack(spacing: 10) {
            ForEach(PageColumnRatio.allCases, id: \.self) { ratio in
                ratioButton(ratio, page: page, config: config)
            }
            Spacer(minLength: 8)
            if layoutModel.isCustomized(page) {
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
        .buttonStyle(.plain)
        .focusable(false)
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

    /// The editable picture of the page. Two column zones in `manual` and
    /// `auto`, one zone per segment in `compact` — which is the only mode where
    /// segments exist, because it is the only mode that packs.
    @ViewBuilder
    private func zones(
        page: PageLayoutPageID,
        arrangement: PageLayoutArrangement,
        blocks: [PageLayoutModuleID: Block],
        mode: PageLayoutMode
    ) -> some View {
        if mode == .compact {
            segmentZones(page: page, arrangement: arrangement, blocks: blocks)
        } else {
            columnZones(page: page, config: arrangement.flattened, blocks: blocks, mode: mode)
        }
    }

    // MARK: - Column zones

    private func columnZones(
        page: PageLayoutPageID,
        config: PageLayoutConfig,
        blocks: [PageLayoutModuleID: Block],
        mode: PageLayoutMode
    ) -> some View {
        let totals = (0..<PageLayoutConfig.columnCount).map { index in
            config.column(index).reduce(0.0) { $0 + (blocks[$1]?.height ?? 0) }
        }
        let scale = min(0.4, Self.editorColumnHeight / max(1, totals.max() ?? 1))
        // `auto` shows what the page currently produces as a read-only picture,
        // so a drag cannot silently discard an arrangement the app is about to
        // recompute.
        let isEditable = mode == .manual
        let target = isEditable ? dropTarget(page: page, config: config) : nil
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(0..<PageLayoutConfig.columnCount, id: \.self) { index in
                    zone(
                        index,
                        page: page,
                        config: config,
                        blocks: blocks,
                        total: totals[index],
                        scale: scale,
                        isEditable: isEditable,
                        insertionIndex: target?.column == index ? target?.index : nil
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            if !isEditable {
                Label("Switch to Compact or Manual to arrange this page", systemImage: "hand.point.up.left")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func zone(
        _ index: Int,
        page: PageLayoutPageID,
        config: PageLayoutConfig,
        blocks: [PageLayoutModuleID: Block],
        total: Double,
        scale: Double,
        isEditable: Bool,
        insertionIndex: Int?
    ) -> some View {
        let moduleIDs = config.column(index)
        let others = moduleIDs.filter { $0 != drag?.moduleID }
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(index == 0 ? "Left column" : "Right column")
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 4)
                Text("\(moduleIDs.count) card\(moduleIDs.count == 1 ? "" : "s") · \(Int(total.rounded()))pt")
                    .font(.system(size: 10, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: Self.blockSpacing) {
                ForEach(moduleIDs, id: \.self) { moduleID in
                    if let block = blocks[moduleID] {
                        blockView(block, page: page, scale: scale, isEditable: isEditable) {
                            applyColumnDrop(block, page: page, config: config)
                        }
                        // The card stays where it is, dimmed, while its ghost
                        // floats: pulling it out of the stack would shift every
                        // block below it, moving the very frames the drop
                        // target is computed from.
                        .opacity(drag?.engaged == true && drag?.moduleID == moduleID ? 0.25 : 1)
                    }
                }
                if moduleIDs.isEmpty {
                    Text("Empty")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
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
                    insertionIndex == nil ? Color.primary.opacity(0.07) : Color.accentColor.opacity(0.45),
                    lineWidth: 0.8
                )
        )
        // Drawn as an overlay, not inserted into the stack, for the same
        // reason: an inline 2.5 pt line would nudge every block below it.
        .overlay(alignment: .top) {
            if let insertionIndex,
               let offset = insertionOffset(page: page, column: index, at: insertionIndex, others: others) {
                Capsule(style: .continuous)
                    .fill(Color.accentColor)
                    .frame(height: 2.5)
                    .padding(.horizontal, 8)
                    .offset(y: offset)
            }
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(Self.space))
        } action: { frame in
            zoneFrames[index] = frame
        }
    }

    /// Vertical position of the insertion line, measured from the top of the
    /// column zone, from the frames the blocks actually occupy.
    private func insertionOffset(
        page: PageLayoutPageID,
        column: Int,
        at index: Int,
        others: [PageLayoutModuleID]
    ) -> CGFloat? {
        guard let zone = zoneFrames[column] else { return nil }
        guard !others.isEmpty else { return 34 }
        if index >= others.count {
            guard let last = blockFrames[frameKey(page, others[others.count - 1])] else { return nil }
            return last.maxY - zone.minY + Self.blockSpacing / 2
        }
        guard let frame = blockFrames[frameKey(page, others[index])] else { return nil }
        return frame.minY - zone.minY - Self.blockSpacing / 2
    }

    // MARK: - Segment zones

    /// One bordered group per segment, each holding that segment's own packed
    /// two columns.
    ///
    /// Order *inside* a segment is the packer's answer, not intent, so there is
    /// no insertion line here and dropping a card back into its own segment does
    /// nothing. What a drag decides is membership.
    private func segmentZones(
        page: PageLayoutPageID,
        arrangement: PageLayoutArrangement,
        blocks: [PageLayoutModuleID: Block]
    ) -> some View {
        let bands = displayedBands(arrangement)
        let membership = bands.map { $0.flatMap { $0 } }
        let heights = bands.map { segmentHeight($0, blocks: blocks) }
        // Scaled against the whole page, not one segment, so a tall segment
        // still reads as the tall one.
        let scale = min(0.4, Self.editorColumnHeight / max(1, heights.reduce(0, +)))
        let target = segmentDropTarget(count: bands.count)
        return VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(bands.enumerated()), id: \.offset) { index, columns in
                segmentZone(
                    index,
                    page: page,
                    columns: columns,
                    membership: membership,
                    blocks: blocks,
                    height: heights[index],
                    scale: scale,
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
                .disabled(bands.count >= PageLayoutSegments.maximumCount)
                .help(
                    bands.count >= PageLayoutSegments.maximumCount
                        ? "A page holds at most \(PageLayoutSegments.maximumCount) segments."
                        : "Add an empty segment, then drag a card into it."
                )
                Spacer(minLength: 0)
            }
        }
    }

    /// The segments on screen: the ones the arrangement produced, plus any the
    /// user added and has not filled yet.
    private func displayedBands(_ arrangement: PageLayoutArrangement) -> [[[PageLayoutModuleID]]] {
        let empty = [[PageLayoutModuleID]](repeating: [], count: PageLayoutConfig.columnCount)
        return arrangement.segments.map(\.columns)
            + [[[PageLayoutModuleID]]](repeating: empty, count: pendingSegments)
    }

    /// What one segment contributes to the page: its taller column, the same
    /// rule `PageLayoutPacker.pageHeight` measures a packed page by.
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
        columns: [[PageLayoutModuleID]],
        membership: [[PageLayoutModuleID]],
        blocks: [PageLayoutModuleID: Block],
        height: Double,
        scale: Double,
        isTarget: Bool
    ) -> some View {
        let cards = columns.flatMap { $0 }
        // An empty segment is always one the user just added, so it is only ever
        // trailing: moving a card past it, or a segment below it, is meaningless.
        let nextIsEmpty = membership.indices.contains(index + 1) && membership[index + 1].isEmpty
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
                .disabled(index == 0 || cards.isEmpty)
                segmentButton("chevron.down", help: "Move this segment down") {
                    moveSegment(index, by: 1, page: page, membership: membership)
                }
                .disabled(index >= membership.count - 1 || cards.isEmpty || nextIsEmpty)
                if cards.isEmpty {
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
                    VStack(spacing: Self.blockSpacing) {
                        ForEach(columns.indices.contains(column) ? columns[column] : [], id: \.self) { moduleID in
                            if let block = blocks[moduleID] {
                                blockView(block, page: page, scale: scale, isEditable: true) {
                                    applySegmentDrop(block, page: page, membership: membership)
                                }
                                .opacity(drag?.engaged == true && drag?.moduleID == moduleID ? 0.25 : 1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            if cards.isEmpty {
                Text("Empty — drag a card here")
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
        .buttonStyle(.plain)
        .focusable(false)
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
        onRelease: @escaping () -> Void
    ) -> some View {
        let height = max(Self.minimumBlockHeight, CGFloat(block.height * scale))
        let body = blockBody(block, height: height, isEditable: isEditable)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(Self.space))
            } action: { frame in
                blockFrames[frameKey(page, block.id)] = frame
            }
            .help("\(block.descriptor.displayName) · \(block.heightLabel)")
        if isEditable {
            body.gesture(dragGesture(block: block, page: page, height: height, onRelease: onRelease))
        } else {
            body
        }
    }

    private func blockBody(_ block: Block, height: CGFloat, isEditable: Bool) -> some View {
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
                Text(block.heightLabel)
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
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(height: height, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(accent.opacity(0.11))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(accent.opacity(0.30), lineWidth: 0.7)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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

    /// Manual: the card takes the column and position it was dropped at.
    private func applyColumnDrop(
        _ block: Block,
        page: PageLayoutPageID,
        config: PageLayoutConfig
    ) {
        guard let target = dropTarget(page: page, config: config) else { return }
        let moved = config.moving(block.id, toColumn: target.column, at: target.index)
        guard moved.columns != config.columns || !layoutModel.isCustomized(page) else { return }
        layoutModel.apply(moved, for: page, available: availableModuleIDs(for: page))
    }

    /// Compact: the card joins the segment it was dropped on. Where it lands
    /// inside that segment is the packer's call, so a drop inside its own
    /// segment is deliberately a no-op rather than a re-order.
    private func applySegmentDrop(
        _ block: Block,
        page: PageLayoutPageID,
        membership: [[PageLayoutModuleID]]
    ) {
        guard let target = segmentDropTarget(count: membership.count),
              membership.indices.contains(target)
        else { return }
        guard !membership[target].contains(block.id) else { return }
        var next = membership
        for index in next.indices {
            next[index].removeAll { $0 == block.id }
        }
        next[target].append(block.id)
        layoutModel.applySegments(next, for: page, available: availableModuleIDs(for: page))
        // Whatever is still empty cannot be stored, so it goes back to being a
        // pending segment instead of vanishing under the user's pointer.
        pendingSegments = next.filter(\.isEmpty).count
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

    /// Where the dragged block would land if the pointer were released now.
    private func dropTarget(page: PageLayoutPageID, config: PageLayoutConfig) -> (column: Int, index: Int)? {
        guard let drag, drag.engaged else { return nil }
        let point = drag.location
        let column = nearestColumn(to: point)
        let others = config.column(column).filter { $0 != drag.moduleID }
        var index = others.count
        for (offset, moduleID) in others.enumerated() {
            guard let frame = blockFrames[frameKey(page, moduleID)] else { continue }
            if point.y < frame.midY {
                index = offset
                break
            }
        }
        return (column, index)
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
        // The same segments the popover will stack, through the same
        // arrangement call, so the preview cannot disagree with the page.
        let bands = arrangement.segments.map(\.columns)
        let pageHeight = bands.reduce(0.0) { $0 + segmentHeight($1, blocks: blocks) }
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
                ForEach(Array(bands.enumerated()), id: \.offset) { _, columns in
                    HStack(alignment: .top, spacing: gap) {
                        previewColumn(
                            columns.indices.contains(0) ? columns[0] : [],
                            blocks: blocks,
                            scale: scale
                        )
                        .frame(width: leftWidth)
                        previewColumn(
                            columns.indices.contains(1) ? columns[1] : [],
                            blocks: blocks,
                            scale: scale
                        )
                        .frame(width: max(0, width - gap - leftWidth))
                    }
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
    private func availableModuleIDs(for page: PageLayoutPageID) -> [PageLayoutModuleID] {
        PageModuleCatalog.descriptors(
            for: page,
            environment: environment,
            settings: settingsStore.settings
        )
        .map(\.id)
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
        switch mode {
        case .manual:
            return "Drag a card to reorder it or move it between columns. Cards are drawn at their measured height, so the taller column here is the taller column in the popover. A card with no measurement yet shows “—pt”."
        case .compact:
            return "Compact packs each segment on its own into whichever two columns make it shortest, and stacks the segments in the order shown. Drag a card onto another segment to move it — where it lands inside is the packer's call. It re-packs when the measured heights move enough to change the answer, and an empty segment is forgotten once you leave this screen."
        case .auto:
            if page.isOverview {
                return "The Overview balances its columns automatically, quota cards first. Blocks below show what that balance currently produces."
            }
            return "This page uses its built-in arrangement. Pick Compact or Manual, or a width split, to take it over."
        }
    }
}
