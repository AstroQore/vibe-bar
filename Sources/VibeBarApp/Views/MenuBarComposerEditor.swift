import SwiftUI
import UniformTypeIdentifiers
import VibeBarCore

/// The menu-bar strip composer.
///
/// Template, then a live preview on both menu-bar grounds, then the strip as
/// draggable chips over a remove target, then a palette of blocks to add, then
/// an inspector for whichever chip is selected.
///
/// The view owns no list logic: every insert, move, duplicate and delete is a
/// `MenuBarComposition` mutation, so what the editor does to a strip is
/// testable without a gesture. It also owns no quota resolution — the preview
/// draws `MenuBarStripView` from the same plan the status item draws, and the
/// snapshots behind it are cached per data change rather than rebuilt while
/// the user types (`AGENTS.md` § 7).
struct MenuBarComposerEditor: View {
    let kind: MenuBarItemKind
    let density: Theme.Density

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var quotaService: QuotaService

    /// Holds the subscription to the one list of things a composed strip
    /// depends on. Without it the preview drifts a generation behind the bar.
    @StateObject private var inputs = MenuBarStripInputObserver()
    /// Holds a debounced control's last change until a moment this view can
    /// observe — see `MenuBarPendingCommit`.
    @StateObject private var pendingCommit = PendingEditQueue()
    @State private var selection: UUID?
    @State private var draggedTokenId: UUID?
    /// The order the strip *would* have if the drag ended here.
    ///
    /// A drag crosses several chips, and writing each crossing through
    /// `settingsStore.settings` fanned every intermediate order out to every
    /// settings subscriber and re-rendered the menu bar mid-gesture — exactly
    /// the per-tick settings write `AGENTS.md` § 7 forbids on an interaction
    /// path. The reorder is kept here while the drag is live and committed
    /// once, on drop.
    @State private var dragComposition: MenuBarComposition?
    /// Fires shortly after the pointer leaves every drop target. SwiftUI has
    /// no "drag cancelled" callback, so a release outside the strip is
    /// inferred from the pointer leaving and not coming back.
    @State private var dragCancelTask: Task<Void, Never>?
    @State private var isOverRemoveTarget = false
    @State private var isConfirmingReseed = false
    /// The group whose "Save as preset…" dialog is open, and the name being
    /// typed into it.
    @State private var savingPresetFrom: UUID?
    @State private var presetDraftName = ""

    // Everything expensive is cached and rebuilt on a data change, never on a
    // keystroke: resolving a quota can compute a personal forecast, and this
    // editor re-renders on every character typed into a text block.
    @State private var snapshots: [MenuBarQuotaSnapshot] = []
    @State private var liveFieldIds: Set<String> = []
    @State private var optionsById: [String: MenuBarFieldOption] = [:]
    @State private var paletteQuotaSections: [PaletteQuotaSection] = []
    @State private var paletteLogoTools: [ToolType] = []

    private struct PaletteQuotaSection: Identifiable {
        let tool: ToolType
        let title: String
        let options: [MenuBarFieldOption]
        var id: String { "\(tool.rawValue).\(title)" }
    }

    private var item: MenuBarItemSettings { settingsStore.settings.menuBarItem(kind) }
    private var composition: MenuBarComposition { item.composition ?? MenuBarComposition() }

    /// What the editor draws: the provisional order while a drag is in
    /// flight, the committed one otherwise. The preview follows it too, so the
    /// user sees the arrangement they are about to get.
    private var displayedComposition: MenuBarComposition {
        guard draggedTokenId != nil, let dragComposition else { return composition }
        return dragComposition
    }

    /// Everything the cached snapshots are derived from.
    ///
    /// Keyed on the *requirements*, not the referenced field ids: switching a
    /// block from `.displayPercent` to `.pace` leaves the field set identical
    /// while changing the work the preview needs, and the stale snapshot would
    /// drop the block until the next quota publication even though the status
    /// item renders it at once. The display mode and colour basis are in here
    /// for the same reason — both change what a snapshot holds, and both are
    /// editable a few controls above this one.
    private struct SnapshotKey: Equatable {
        var requirements: [MenuBarQuotaRequirement]
        var displayMode: DisplayMode
        var colorBasis: MenuBarColorBasis
        var customLabels: [String: String]
    }

    /// Whether the preview's cached snapshot goes stale on the forecast's own
    /// clock. The `TimelineView` below only re-plans; forecast values live in
    /// the snapshot, so they need a rebuild, not a redraw.
    private var needsForecastClock: Bool {
        displayedComposition.needsForecastClock(
            colorBasis: settingsStore.settings.menuBarColorBasis
        )
    }

    private var snapshotKey: SnapshotKey {
        SnapshotKey(
            requirements: composition.quotaRequirements,
            displayMode: settingsStore.settings.displayMode,
            colorBasis: settingsStore.settings.menuBarColorBasis,
            customLabels: item.customLabels
        )
    }

    var body: some View {
        let composition = displayedComposition
        let availability = composition.availability(liveFieldIds: liveFieldIds)

        VStack(alignment: .leading, spacing: density.cardSpacing + 4) {
            templateRow(composition)
            previewRow(composition)
            stripRow(composition, availability: availability)
            paletteRow(composition)
            inspectorRow(composition, availability: availability)
            footerRow(availability: availability)
        }
        .alert(
            L10n.MenuBar.composerPresetSaveTitle,
            isPresented: Binding(
                get: { savingPresetFrom != nil },
                set: { if !$0 { savingPresetFrom = nil } }
            )
        ) {
            TextField(L10n.MenuBar.composerPresetName, text: $presetDraftName)
            Button(L10n.MenuBar.composerPresetSaveConfirm) { savePendingPreset() }
                .disabled(
                    presetDraftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            Button(L10n.Common.cancel, role: .cancel) { savingPresetFrom = nil }
        }
        .onAppear {
            inputs.start(environment: environment)
            rebuildCatalog()
            rebuildSnapshots()
        }
        // Exactly what the status item re-renders on — one list, two
        // consumers. Subscribing to a subset of it is how the preview ended up
        // a generation behind the bar for forecasts, colours and rules.
        .onReceive(inputs.$generation) { _ in
            rebuildCatalog()
            rebuildSnapshots()
        }
        // Changing what the strip asks of a quota rebuilds; editing a word
        // does not. That is what keeps a forecast off the typing path while
        // still letting a metric swap show up immediately.
        .onChange(of: snapshotKey) { _, _ in rebuildSnapshots() }
        // Selecting another block retires the inspector that queued the write,
        // so spend it first. Deterministic, unlike waiting for that view's
        // teardown to be delivered.
        .onChange(of: selection) { _, _ in pendingCommit.flush() }
        .onDisappear { pendingCommit.flush() }
        // A forecast percentage, a verdict rule, or a forecast colour goes
        // stale on `QuotaService`'s five-minute grid, and none of the input
        // publishers fires in between. Rebuild the cached snapshot on that
        // grid — gated, so a strip with no forecast in it starts nothing, and
        // paced to the forecast's own quantum rather than anything faster.
        .task(id: needsForecastClock) {
            guard needsForecastClock else { return }
            while !Task.isCancelled {
                let next = MenuBarCountdownClock.nextTick(
                    after: Date(),
                    anchor: QuotaClockSchedule.anchor,
                    interval: MenuBarCountdownClock.forecastInterval
                )
                try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                rebuildSnapshots()
            }
        }
    }

    // MARK: - Template

    private func templateRow(_ composition: MenuBarComposition) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(L10n.MenuBar.composerTemplate, selection: templateBinding()) {
                ForEach(MenuBarComposition.Template.allCases, id: \.self) { template in
                    Text(template.title).tag(template)
                }
            }
            .pickerStyle(.segmented)
            Text(composition.template.detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Preview

    private func previewRow(_ composition: MenuBarComposition) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            caption(L10n.MenuBar.composerPreview)
            // A countdown block is wrong a minute later with no new data
            // behind it, and nothing else here invalidates the view. Gated on
            // the strip actually printing one: `QuotaClockSchedule` yields a
            // single entry and starts no timer when inactive, so a strip of
            // percentages still costs nothing. Same phase anchor the popover's
            // clocks and the status item's tick use, so the preview and the
            // bar never show two different countdowns for one quota.
            TimelineView(
                QuotaClockSchedule(
                    isActive: composition.hasTimeBasedBlock,
                    interval: MenuBarCountdownClock.interval
                )
            ) { context in
                let plan = composition.plan(
                    quotas: snapshots,
                    displayMode: settingsStore.settings.displayMode,
                    colorBasis: settingsStore.settings.menuBarColorBasis,
                    now: context.date,
                    // The bar's real canvas, the same one the status item
                    // plans against. How much a block may grow depends on how
                    // tall this Mac's menu bar is, and a preview that capped
                    // against a different height would be previewing a
                    // different strip.
                    canvas: MenuBarStripMetrics.twoRowCanvas()
                )
                VStack(alignment: .leading, spacing: 4) {
                    MenuBarStripPreview(
                        plan: plan,
                        quotas: snapshots,
                        displayMode: settingsStore.settings.displayMode,
                        template: composition.template,
                        highlighted: selection
                    )
                    Text(L10n.MenuBar.composerPreviewGrounds)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if plan.rows.filter({ !$0.isEmpty }).count >= 2 {
                        Text(L10n.MenuBar.composerPreviewTwoRowScaling)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Strip

    private func stripRow(
        _ composition: MenuBarComposition,
        availability: MenuBarComposition.Availability
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            caption(L10n.MenuBar.composerBlocks)
            if composition.segments.isEmpty {
                Text(L10n.MenuBar.composerBlocksEmpty)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                // The groups themselves wrap, the same way the chips inside
                // them do — a strip can hold more columns than one line of
                // this settings pane is wide.
                MenuBarChipFlow(spacing: 8, lineSpacing: 8) {
                    ForEach(Array(composition.segments.enumerated()), id: \.element.id) { index, segment in
                        segmentBox(segment, index: index, of: composition, availability: availability)
                    }
                }
            }
            removeTarget
        }
    }

    /// One group: a header that can move, save or remove it, then its blocks.
    private func segmentBox(
        _ segment: MenuBarSegment,
        index: Int,
        of composition: MenuBarComposition,
        availability: MenuBarComposition.Availability
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(L10n.MenuBar.composerGroupTitle(index: index + 1))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                Spacer(minLength: 4)
                Menu {
                    Button(L10n.MenuBar.composerGroupMoveLeft) {
                        mutate { $0.moveSegment(segment.id, by: -1) }
                    }
                    .disabled(index == 0)
                    Button(L10n.MenuBar.composerGroupMoveRight) {
                        mutate { $0.moveSegment(segment.id, by: 1) }
                    }
                    .disabled(index == composition.segments.count - 1)
                    Button(L10n.MenuBar.composerGroupMergeLeft) {
                        mutate { $0.mergeSegmentIntoPrevious(segment.id) }
                    }
                    .disabled(index == 0)
                    Divider()
                    // The two row interactions, on the group rather than in
                    // the palette: a row is a container, so opening and
                    // closing one is something you do *to a column*. Removing
                    // one says where its blocks go, which is why the label
                    // says "merge" rather than "remove" — nothing is deleted.
                    if segment.isStacked {
                        Button(L10n.MenuBar.composerGroupRemoveRow) {
                            mutate { $0.removeRow(fromSegment: segment.id) }
                        }
                    } else {
                        Button(L10n.MenuBar.composerGroupAddRow) {
                            mutate { $0.addRow(toSegment: segment.id) }
                        }
                    }
                    Divider()
                    Button(L10n.MenuBar.composerPresetSave) {
                        presetDraftName = ""
                        savingPresetFrom = segment.id
                    }
                    .disabled(segment.isEmpty)
                    Divider()
                    Button(L10n.MenuBar.composerGroupRemove, role: .destructive) {
                        if let selection, segment.tokens.contains(where: { $0.id == selection }) {
                            self.selection = nil
                        }
                        mutate { $0.removeSegment(segment.id) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 9, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            // One list of chips per row, so a row is somewhere blocks live
            // rather than a marker sitting among them. Each row is its own
            // drop target: dragging between the two rows of one group and
            // dragging between groups are the same gesture.
            rowStrip(segment, row: .top, availability: availability)
            if segment.isStacked {
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 0.5)
                rowStrip(segment, row: .bottom, availability: availability)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
    }

    /// One row of one group: its chips, and the empty space after them.
    @ViewBuilder
    private func rowStrip(
        _ segment: MenuBarSegment,
        row: MenuBarSegment.Row,
        availability: MenuBarComposition.Availability
    ) -> some View {
        let address = MenuBarComposition.RowAddress(segment: segment.id, row: row)
        let tokens = segment[row]
        if tokens.isEmpty {
            // A group with one empty row is an empty group; an empty row
            // inside a stacked one is a row waiting to be filled. Two
            // sentences, because they are two different situations.
            Text(
                segment.isStacked
                    ? L10n.MenuBar.composerRowEmpty
                    : L10n.MenuBar.composerGroupEmpty
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(minWidth: 96, minHeight: 22, alignment: .leading)
            .contentShape(Rectangle())
            .onDrop(of: [.text], delegate: chipDrop(.endOf(address)))
        } else {
            MenuBarChipFlow(spacing: 5, lineSpacing: 5) {
                ForEach(tokens) { token in
                    chip(token, availability: availability)
                        .onDrag {
                            // A queued colour or threshold has to land first:
                            // the drop writes this snapshot back wholesale, so
                            // an edit missing from it would be undone by the
                            // drag that followed it.
                            pendingCommit.flush()
                            dragEnteredTarget()
                            draggedTokenId = token.id
                            // Snapshot the committed order; every crossing
                            // reorders this copy, and only the drop writes.
                            dragComposition = self.composition
                            return NSItemProvider(object: token.id.uuidString as NSString)
                        }
                        .onDrop(of: [.text], delegate: chipDrop(.before(token.id)))
                }
                // Trailing landing strip, so a block can be dragged to the end
                // of this row without having to hit its last chip.
                Color.clear
                    .frame(width: 16, height: 22)
                    .contentShape(Rectangle())
                    .onDrop(of: [.text], delegate: chipDrop(.endOf(address)))
            }
        }
    }

    private func chipDrop(_ target: MenuBarChipDropTarget) -> MenuBarChipDropDelegate {
        MenuBarChipDropDelegate(
            target: target,
            dragged: $draggedTokenId,
            provisional: $dragComposition,
            commit: { commitDrag() },
            entered: { dragEnteredTarget() },
            exited: { dragLeftTarget() }
        )
    }

    private var removeTarget: some View {
        HStack(spacing: 6) {
            Image(systemName: "trash")
                .font(.system(size: 10, weight: .semibold))
            Text(L10n.MenuBar.composerRemoveTarget)
                .font(.caption)
        }
        .foregroundStyle(isOverRemoveTarget ? Color.red : Color.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.red.opacity(isOverRemoveTarget ? 0.16 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    Color.red.opacity(isOverRemoveTarget ? 0.55 : 0.2),
                    style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])
                )
        )
        .onDrop(
            of: [.text],
            delegate: MenuBarChipRemoveDelegate(
                dragged: $draggedTokenId,
                isTargeted: $isOverRemoveTarget,
                selection: $selection,
                remove: { removeDragged($0) },
                entered: { dragEnteredTarget() },
                exited: { dragLeftTarget() }
            )
        )
    }

    private func chip(
        _ token: MenuBarToken,
        availability: MenuBarComposition.Availability
    ) -> some View {
        let isSelected = selection == token.id
        let isSilent = availability.silentTokenIds.contains(token.id)
        let isDegraded = availability.degradedTokenIds.contains(token.id)
        return Button {
            selection = isSelected ? nil : token.id
        } label: {
            HStack(spacing: 4) {
                if case let .logo(tool) = token.kind {
                    ToolBrandIconView(tool: tool, size: 11)
                } else {
                    Image(systemName: symbol(for: token.kind))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(chipTitle(token))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                if isSilent || isDegraded {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(isSilent ? Color.orange : Color.secondary)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.14 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.10),
                        lineWidth: 0.5
                    )
            )
            .opacity(isSilent ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .help(chipHelp(token, isSilent: isSilent, isDegraded: isDegraded))
    }

    private func symbol(for kind: MenuBarToken.Kind) -> String {
        switch kind {
        case .logo: return "app.badge"
        case .text: return "textformat"
        case .quota: return "percent"
        case .space: return "space"
        case .separator: return "line.diagonal"
        case .appIcon: return "menubar.rectangle"
        case .unsupported: return "questionmark.square.dashed"
        }
    }

    private func chipTitle(_ token: MenuBarToken) -> String {
        switch token.kind {
        case let .logo(tool):
            return tool.menuTitle
        case let .text(text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? L10n.MenuBar.composerBlockEmptyText : MenuBarToken.truncated(trimmed)
        case let .quota(fieldId, metric):
            let name = optionsById[fieldId]?.displayDefaultLabel ?? fieldId
            return "\(name) · \(metric.title)"
        case let .space(width):
            let width = MenuBarToken.clampedSpaceWidth(width)
            return width == MenuBarToken.defaultSpaceWidth
                ? L10n.MenuBar.composerBlockSpace
                : L10n.MenuBar.composerSpaceWidthValue(count: width)
        case let .separator(separator):
            let trimmed = separator.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? L10n.MenuBar.composerBlockGap : trimmed
        case .appIcon:
            return L10n.MenuBar.composerBlockAppIcon
        case .unsupported:
            return L10n.MenuBar.composerBlockUnsupported
        }
    }

    private func chipHelp(_ token: MenuBarToken, isSilent: Bool, isDegraded: Bool) -> String {
        if isSilent {
            return L10n.MenuBar.composerWarningSilent
        }
        if isDegraded {
            return L10n.MenuBar.composerWarningDegraded
        }
        return chipTitle(token)
    }

    // MARK: - Palette

    private func paletteRow(_ composition: MenuBarComposition) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            caption(L10n.MenuBar.composerPalette)
            paletteGroup(L10n.MenuBar.composerBlockLogo) {
                paletteButton(title: L10n.MenuBar.composerBlockAppIcon, icon: "menubar.rectangle") {
                    add(.newAppIcon())
                }
                ForEach(paletteLogoTools, id: \.self) { tool in
                    paletteButton(title: tool.menuTitle, icon: nil, tool: tool) {
                        add(.newLogo(tool))
                    }
                }
            }
            paletteGroup(L10n.MenuBar.composerBlockText) {
                paletteButton(title: L10n.MenuBar.composerBlockText, icon: "textformat") {
                    add(.newText())
                }
            }
            paletteGroup(L10n.MenuBar.composerBlockQuota) {
                ForEach(paletteQuotaSections) { section in
                    Menu {
                        ForEach(section.options) { option in
                            Button(option.displayTitle) {
                                add(.newQuota(fieldId: option.id))
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            ToolBrandIconView(tool: section.tool, size: 11)
                            Text(section.title).font(.system(size: 11, weight: .medium))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            paletteGroup(L10n.MenuBar.composerBlockStructure) {
                paletteButton(title: L10n.MenuBar.composerBlockSpace, icon: "space") {
                    add(.newSpace())
                }
                paletteButton(title: L10n.MenuBar.composerBlockSeparator, icon: "line.diagonal") {
                    add(.newSeparator())
                }
                // No "New row" block here on purpose. A row is a place blocks
                // live, not a block you insert — giving a group its second row
                // is an action on the group, and it lives in the group's own
                // menu beside move, merge and remove.
                paletteButton(
                    title: L10n.MenuBar.composerGroupAdd,
                    icon: "rectangle.split.2x1"
                ) {
                    addSegment()
                }
                .help(L10n.MenuBar.composerGroupAddHelp)
            }
            presetsRow()
        }
    }

    /// The saved groups, if there are any. Click one to insert it at the end
    /// of the strip.
    @ViewBuilder
    private func presetsRow() -> some View {
        if !item.segmentPresets.isEmpty {
            paletteGroup(L10n.MenuBar.composerPresets) {
                ForEach(item.segmentPresets) { preset in
                    paletteButton(title: preset.name, icon: "square.on.square") {
                        insert(preset: preset)
                    }
                    .help(L10n.MenuBar.composerPresetInsertHelp)
                    .contextMenu {
                        Button(L10n.MenuBar.composerPresetRemove, role: .destructive) {
                            mutatePresets { $0.removeAll { $0.id == preset.id } }
                        }
                    }
                }
            }
        }
    }

    private func paletteGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .leading)
                .padding(.top, 4)
            MenuBarChipFlow(spacing: 5, lineSpacing: 5) {
                content()
            }
        }
    }

    private func paletteButton(
        title: String,
        icon: String?,
        tool: ToolType? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let tool {
                    ToolBrandIconView(tool: tool, size: 11)
                } else if let icon {
                    Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                }
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Inspector

    @ViewBuilder
    private func inspectorRow(
        _ composition: MenuBarComposition,
        availability: MenuBarComposition.Availability
    ) -> some View {
        if let id = selection, let token = composition.token(id) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    caption(L10n.MenuBar.composerSelected)
                    Spacer(minLength: 8)
                    // Only where it would do something: a block that already
                    // starts its group has no group to start, and a column is
                    // cut through its top row — see `splitSegment`.
                    if let location = composition.location(of: id),
                       location.row == .top,
                       location.offset > 0 {
                        Button(L10n.MenuBar.composerGroupSplitHere) {
                            mutate { $0.splitSegment(before: id) }
                        }
                        .buttonStyle(.vibeBar)
                    }
                    Button(L10n.MenuBar.composerActionDuplicate) { mutate { $0.duplicate(id) } }
                        .buttonStyle(.vibeBar)
                    Button(L10n.MenuBar.composerActionRemove) {
                        selection = nil
                        mutate { $0.remove(id) }
                    }
                    .buttonStyle(.vibeBar)
                }
                if availability.silentTokenIds.contains(id) {
                    warning(L10n.MenuBar.composerWarningSilent)
                } else if availability.degradedTokenIds.contains(id) {
                    warning(L10n.MenuBar.composerWarningDegraded)
                }
                MenuBarTokenInspector(
                    token: token,
                    options: sortedOptions,
                    liveFieldIds: liveFieldIds,
                    pending: pendingCommit,
                    // A control hands over the field it owns, not a copy of
                    // the whole block. `mutate` flushes a queued write first,
                    // so the edit lands on the token as it is *after* that
                    // flush — a whole-token replacement built before it would
                    // carry pre-flush state and silently undo the colour or
                    // threshold the user had just set.
                    apply: { change in
                        mutate { composed in composed.updateToken(id) { change(&$0) } }
                    }
                )
                // Selecting a different chip is a different inspector, so its
                // colour-well draft starts from that block rather than from
                // whatever the last one was.
                .id(token.id)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    private func footerRow(availability: MenuBarComposition.Availability) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !availability.isFullyAvailable {
                warning(L10n.MenuBar.composerWarningMissing(
                    fields: availability.missingFieldIds
                        .map { optionsById[$0]?.displayTitle ?? $0 }
                        .joined(separator: ", ")
                ))
            }
            HStack(spacing: 8) {
                Button(L10n.MenuBar.composerStartOver) { isConfirmingReseed = true }
                    .buttonStyle(.vibeBar)
                Spacer(minLength: 8)
            }
            Text(L10n.MenuBar.composerStartOverDetail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog(
            L10n.MenuBar.composerStartOverConfirmTitle,
            isPresented: $isConfirmingReseed,
            titleVisibility: .visible
        ) {
            Button(L10n.MenuBar.composerStartOverConfirm, role: .destructive) {
                selection = nil
                var updated = item
                updated.reseedComposedStrip(
                    template: composition.template,
                    registry: quotaService.fieldRegistry,
                    groupCatalogLabel: MiniWindowGroupLabelCatalog.defaultLabel(for:)
                )
                settingsStore.settings.setMenuBarItem(updated)
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.MenuBar.composerStartOverConfirmMessage)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .tracking(0.4)
    }

    // MARK: - Mutations

    private func mutate(_ change: (inout MenuBarComposition) -> Void) {
        // Spend a queued write before making another, so the two cannot land
        // out of order or overwrite each other. Re-entrant-safe: `flush`
        // clears the queue before running it.
        pendingCommit.flush()
        // A real edit ends any drag state: the provisional order must never
        // outlive the arrangement it was based on.
        dragCancelTask?.cancel()
        dragCancelTask = nil
        dragComposition = nil
        draggedTokenId = nil
        var updated = item
        let before = updated.composition
        var composed = before ?? MenuBarComposition(isEnabled: true)
        change(&composed)
        // An edit that changes nothing must not publish settings: every write
        // fans out to every subscriber and re-renders the menu bar.
        guard composed != before else { return }
        updated.composition = composed
        settingsStore.settings.setMenuBarItem(updated)
    }

    /// Presets live on the item, not on the composition, so they survive
    /// "Start over" — see `MenuBarItemSettings.segmentPresets`.
    private func mutatePresets(_ change: (inout [MenuBarSegmentPreset]) -> Void) {
        pendingCommit.flush()
        var updated = item
        let before = updated.segmentPresets
        change(&updated.segmentPresets)
        guard updated.segmentPresets != before else { return }
        settingsStore.settings.setMenuBarItem(updated)
    }

    /// Save the group the dialog was opened on, under the name that was typed.
    ///
    /// The blocks are copied exactly as they are, quota ids and all: a preset
    /// naming a bucket this Mac stopped returning is a block the availability
    /// warning already explains, and repairing it here would be editing
    /// something the user arranged.
    private func savePendingPreset() {
        defer { savingPresetFrom = nil }
        guard let id = savingPresetFrom,
              let index = composition.segmentIndex(of: id),
              !composition.segments[index].isEmpty
        else { return }
        // No fallback name. A derived one would be a localized string in
        // `settings.json`, which reads as the wrong language the moment the
        // user switches — the same defect a seeded label had. The Save button
        // is disabled until they type something instead.
        let name = presetDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let segment = composition.segments[index]
        mutatePresets { $0.append(MenuBarSegmentPreset(name: name, segment: segment)) }
    }

    /// The pointer is over a drop target again, so the drag is still live.
    private func dragEnteredTarget() {
        dragCancelTask?.cancel()
        dragCancelTask = nil
    }

    /// The pointer left a drop target. If it does not come back, the drag was
    /// released somewhere that accepts nothing and `performDrop` will never
    /// run — so the provisional order has to go, or the strip keeps showing an
    /// arrangement no settings write ever matched.
    ///
    /// The provisional copy is reset to the committed order rather than
    /// dropped: the pointer may well come back, and `dropEntered` reorders
    /// from whatever is here.
    private func dragLeftTarget() {
        dragCancelTask?.cancel()
        dragCancelTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            dragComposition = composition
            // The identity goes with it. `displayedComposition` prefers the
            // drag snapshot while a token is being dragged, so leaving the id
            // set kept the editor and the preview showing the old blocks after
            // Start over while the status item had already changed.
            draggedTokenId = nil
            dragCancelTask = nil
        }
    }

    /// The one settings write a completed drag performs.
    private func commitDrag() {
        guard let reordered = dragComposition else {
            draggedTokenId = nil
            return
        }
        let segments = reordered.segments
        // `mutate` clears the drag state before writing.
        mutate { $0.segments = segments }
    }

    private func removeDragged(_ id: UUID) {
        if selection == id { selection = nil }
        // Start from the provisional order when there is one, so a block that
        // was dragged across the strip and then onto the bin does not
        // resurrect the intermediate order it passed through.
        var base = dragComposition ?? composition
        base.remove(id)
        let segments = base.segments
        mutate { $0.segments = segments }
    }

    /// Where a new block goes: into the row the user is working in, else at
    /// the end of the strip — which, in a stacked last column, is its bottom
    /// row rather than its top one.
    private var targetRow: MenuBarComposition.RowAddress? {
        if let selection, let location = composition.location(of: selection) {
            return MenuBarComposition.RowAddress(
                segment: composition.segments[location.segment].id,
                row: location.row
            )
        }
        guard let last = composition.segments.last else { return nil }
        return MenuBarComposition.RowAddress(
            segment: last.id,
            row: last.isStacked ? .bottom : .top
        )
    }

    private func add(_ token: MenuBarToken) {
        let row = targetRow
        mutate { $0.append(token, to: row) }
        selection = token.id
    }

    private func addSegment() {
        let segment = MenuBarSegment()
        mutate { $0.appendSegment(segment) }
        // Nothing to select — the group is empty — but the next added block
        // has to land in it rather than in whatever was selected before.
        selection = nil
    }

    private func insert(preset: MenuBarSegmentPreset) {
        mutate { $0.appendSegment(preset.segment()) }
        selection = nil
    }

    private func templateBinding() -> Binding<MenuBarComposition.Template> {
        Binding(
            get: { composition.template },
            // A template is spacing and type size — and, for "Two rows", a
            // shape. `setTemplate` takes the row structure with it, because a
            // picker whose description promises two stacked rows has to
            // produce them. It still never invents or discards content: the
            // blocks the user arranged are theirs, and "Start over" is the
            // control that rebuilds those, after asking.
            set: { template in mutate { $0.setTemplate(template) } }
        )
    }

    // MARK: - Caches

    private var sortedOptions: [MenuBarFieldOption] {
        paletteQuotaSections.flatMap(\.options)
    }

    private func rebuildCatalog() {
        let merged = MenuBarFieldCatalog.mergedFields(registry: quotaService.fieldRegistry)
        optionsById = Dictionary(merged.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        liveFieldIds = MenuBarStripResolver.liveFieldIds(environment: environment)

        var sections: [PaletteQuotaSection] = []
        for tool in ToolType.dedicatedCardProviders {
            let options = merged.filter { $0.tool == tool }
            guard !options.isEmpty else { continue }
            // One entry per L2 SubProvider, so Grok Bot is not filed under
            // Cursor — the quota axis, as `AGENTS.md` § 7.1 requires.
            var bySubProvider: [(name: String, options: [MenuBarFieldOption])] = []
            for option in options {
                let name = tool.quotaSubProviderName(bucketID: option.bucketId)
                if let index = bySubProvider.firstIndex(where: { $0.name == name }) {
                    bySubProvider[index].options.append(option)
                } else {
                    bySubProvider.append((name, [option]))
                }
            }
            for group in bySubProvider {
                sections.append(PaletteQuotaSection(
                    tool: tool,
                    title: group.name,
                    options: group.options
                ))
            }
        }
        paletteQuotaSections = sections
        paletteLogoTools = ToolType.dedicatedCardProviders
    }

    private func rebuildSnapshots() {
        snapshots = MenuBarStripResolver.snapshots(
            for: composition,
            itemSettings: item,
            settings: settingsStore.settings,
            environment: environment
        )
        liveFieldIds = MenuBarStripResolver.liveFieldIds(environment: environment)
    }
}

// MARK: - Inspector

/// Controls for one block. Split out so the editor's own body does not
/// re-evaluate every palette section and every chip when a slider moves.
private struct MenuBarTokenInspector: View {
    let token: MenuBarToken
    let options: [MenuBarFieldOption]
    let liveFieldIds: Set<String>
    let pending: PendingEditQueue
    /// Hands over *what changed*, applied to the stored token at write time.
    let apply: (@escaping (inout MenuBarToken) -> Void) -> Void

    @State private var fixedDraft: Color = .accentColor

    /// Whether this block puts anything on screen.
    private var drawsInk: Bool {
        switch token.kind {
        case .unsupported: return false
        default: return true
        }
    }

    private enum ColorChoice: String, CaseIterable, Identifiable {
        case automatic, forecast, followsQuota, brand, primary, secondary, tertiary, fixed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: return L10n.MenuBar.composerColourAutomatic
            case .forecast: return L10n.MenuBar.composerColourForecast
            case .followsQuota: return L10n.MenuBar.composerColourFollowsQuota
            case .brand: return L10n.MenuBar.composerColourBrand
            case .primary: return L10n.MenuBar.composerColourPrimary
            case .secondary: return L10n.MenuBar.composerColourSecondary
            case .tertiary: return L10n.MenuBar.composerColourTertiary
            case .fixed: return L10n.MenuBar.composerColourFixed
            }
        }
    }

    private enum RuleChoice: String, CaseIterable, Identifiable {
        case always, whenUsedAtLeast, whenRemainingAtMost, whenForecast
        var id: String { rawValue }
        var title: String {
            switch self {
            case .always: return L10n.MenuBar.composerRuleAlways
            case .whenUsedAtLeast: return L10n.MenuBar.composerRuleWhenUsedAtLeast
            case .whenRemainingAtMost: return L10n.MenuBar.composerRuleWhenRemainingAtMost
            case .whenForecast: return L10n.MenuBar.composerRuleWhenForecast
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            contentControls
            // A block this build cannot read draws no ink, so colour, size and
            // weight would be controls that quietly do nothing. Its rule is
            // still shown, because the rule is this build's to evaluate.
            if drawsInk {
                Divider().opacity(0.4)
                colorControls
                HStack(spacing: 10) {
                    Picker(L10n.MenuBar.composerFieldSize, selection: sizeBinding) {
                        ForEach(MenuBarToken.SizeStep.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .frame(width: 150)
                    Picker(L10n.MenuBar.composerFieldWeight, selection: weightBinding) {
                        ForEach(MenuBarToken.Weight.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .frame(width: 165)
                }
                Toggle(L10n.MenuBar.composerFieldMonospacedDigits, isOn: monospacedBinding)
                    .help(L10n.MenuBar.composerFieldMonospacedDigitsHelp)
            }
            Divider().opacity(0.4)
            ruleControls
        }
        .font(.system(size: 11.5))
    }

    // MARK: Content

    @ViewBuilder
    private var contentControls: some View {
        switch token.kind {
        case let .text(text):
            HStack(spacing: 8) {
                Text(L10n.MenuBar.composerBlockText).frame(width: 62, alignment: .leading)
                DebouncedSettingsTextField(
                    prompt: L10n.MenuBar.composerTextPlaceholder,
                    pending: pending,
                    pendingKey: "text.\(token.id)",
                    value: Binding(
                        get: { text },
                        set: { value in
                            // Truncation is a drawing rule, not an input rule:
                            // the block keeps what was typed and the bar shows
                            // as much of it as fits.
                            update { $0.kind = .text(value) }
                        }
                    )
                )
            }
            Text(
                text.isEmpty
                    ? L10n.MenuBar.composerTextEmpty
                    : L10n.MenuBar.composerTextLimit(count: MenuBarToken.maximumTextLength)
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        case let .separator(separator):
            HStack(spacing: 8) {
                Text(L10n.MenuBar.composerBlockSeparator).frame(width: 62, alignment: .leading)
                DebouncedSettingsTextField(
                    prompt: " · ",
                    pending: pending,
                    pendingKey: "separator.\(token.id)",
                    value: Binding(
                        get: { separator },
                        set: { value in update { $0.kind = .separator(value) } }
                    )
                )
            }
        case let .quota(fieldId, metric):
            HStack(spacing: 8) {
                Text(L10n.MenuBar.composerBlockQuota).frame(width: 62, alignment: .leading)
                fieldPicker(selected: fieldId) { newId in
                    update { $0.kind = .quota(fieldId: newId, metric: metric) }
                }
            }
            HStack(spacing: 8) {
                Text(L10n.MenuBar.composerFieldShows).frame(width: 62, alignment: .leading)
                Picker("", selection: Binding(
                    get: { metric },
                    set: { value in update { $0.kind = .quota(fieldId: fieldId, metric: value) } }
                )) {
                    ForEach(MenuBarQuotaMetric.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 220)
            }
            // Only "Resets at" prints a date, so only it gets a date format.
            // Undebounced on purpose: a picker commits one discrete value the
            // moment the menu closes, the way the metric, size and weight
            // pickers around it already do. `PendingEditQueue` is for controls
            // that fire while the user is still moving them.
            if metric == .resetAt {
                HStack(spacing: 8) {
                    Text(L10n.MenuBar.composerFieldResetFormat)
                        .frame(width: 62, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { token.style.resetFormat },
                        set: { value in update { $0.style.resetFormat = value } }
                    )) {
                        ForEach(ResetTimeFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                .help(L10n.MenuBar.composerFieldResetFormatHelp)
            }
        case let .logo(tool):
            HStack(spacing: 8) {
                Text(L10n.MenuBar.composerFieldProvider).frame(width: 62, alignment: .leading)
                Picker("", selection: Binding(
                    get: { tool },
                    set: { value in update { $0.kind = .logo(value) } }
                )) {
                    ForEach(ToolType.dedicatedCardProviders, id: \.self) {
                        Text($0.menuTitle).tag($0)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
        case let .space(width):
            HStack(spacing: 8) {
                Text(L10n.MenuBar.composerSpaceWidth).frame(width: 62, alignment: .leading)
                // Same queue as every other repeating control here: a held
                // stepper auto-repeats, and each repeat would otherwise
                // publish settings and re-render the menu bar.
                DebouncedSpaceWidthStepper(
                    width: MenuBarToken.clampedSpaceWidth(width),
                    pending: pending,
                    key: "spaceWidth.\(token.id)"
                ) { value in
                    update { $0.kind = .space(width: value) }
                }
                Spacer(minLength: 0)
            }
            Text(L10n.MenuBar.composerSpaceDetail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .appIcon:
            Text(L10n.MenuBar.composerAppIconDetail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .unsupported:
            Text(L10n.MenuBar.composerUnsupportedDetail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Colour

    @ViewBuilder
    private var colorControls: some View {
        HStack(spacing: 8) {
            Text(L10n.MenuBar.composerFieldColour).frame(width: 62, alignment: .leading)
            Picker("", selection: colorChoiceBinding) {
                ForEach(ColorChoice.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 165)
            switch token.style.color {
            case let .brand(tool):
                Picker("", selection: Binding(
                    get: { tool },
                    set: { value in update { $0.style.color = .brand(value) } }
                )) {
                    // The same table `.brand` resolves through, so a swatch
                    // here cannot promise a colour the bar will not paint.
                    ForEach(ToolType.dedicatedCardProviders, id: \.self) { candidate in
                        Label {
                            Text(candidate.menuTitle)
                        } icon: {
                            Circle().fill(Theme.providerAccent(for: candidate))
                        }
                        .tag(candidate)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            case .fixed:
                ColorPicker("", selection: $fixedDraft, supportsOpacity: false)
                    .labelsHidden()
                    // Dragging inside a colour well fires continuously, so the
                    // write is queued rather than made per frame — on the
                    // editor, which is still around when this control is not.
                    .onChange(of: fixedDraft) { _, value in
                        scheduleColorCommit(value)
                    }
            case let .followsQuota(fieldId, basis):
                fieldPicker(selected: fieldId) { newId in
                    update { $0.style.color = .followsQuota(fieldId: newId, basis: basis) }
                }
                Picker("", selection: Binding(
                    get: { basis },
                    set: { value in
                        update { $0.style.color = .followsQuota(fieldId: fieldId, basis: value) }
                    }
                )) {
                    ForEach(MenuBarColorBasis.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
            default:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
        .onAppear(perform: syncFixedDraft)
        // Switching the colour role to Custom writes a starting hex; the well
        // has to follow it, or it would show one colour while the block wears
        // another.
        .onChange(of: token.style.color) { _, _ in syncFixedDraft() }
    }

    private func syncFixedDraft() {
        guard case let .fixed(hex) = token.style.color,
              let parts = MenuBarHexColor.components(hex)
        else { return }
        fixedDraft = Color(.sRGB, red: parts.r, green: parts.g, blue: parts.b, opacity: parts.a)
    }

    /// Queue the colour the well is showing.
    ///
    /// Everything the write needs is captured as a value here — the finished
    /// token and the apply closure — so nothing reads this view's `@State`
    /// after it has gone away.
    private func scheduleColorCommit(_ color: Color) {
        guard case let .fixed(current) = token.style.color else { return }
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        let hex = String(
            format: "#%02x%02x%02x",
            Int((resolved.redComponent * 255).rounded()),
            Int((resolved.greenComponent * 255).rounded()),
            Int((resolved.blueComponent * 255).rounded())
        )
        guard current != hex else { return }
        let apply = self.apply
        // Only the colour: a queued write that carried a whole token would
        // undo whatever else the user changed while it sat in the queue.
        // Keyed on this block's colour: the threshold control beside it queues
        // under its own key and neither can drop the other.
        pending.schedule("color.\(token.id)") { apply { $0.style.color = .hex(hex) } }
    }

    // MARK: Rule

    @ViewBuilder
    private var ruleControls: some View {
        HStack(spacing: 8) {
            Text(L10n.MenuBar.composerFieldShow).frame(width: 62, alignment: .leading)
            Picker("", selection: ruleChoiceBinding) {
                ForEach(RuleChoice.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 210)
            Spacer(minLength: 0)
        }
        switch token.visibility {
        case .always:
            EmptyView()
        case let .whenUsedAtLeast(fieldId, percent):
            thresholdRow(
                fieldId: fieldId,
                percent: percent,
                setField: { newId in
                    update {
                        guard case let .whenUsedAtLeast(_, current) = $0.visibility else { return }
                        $0.visibility = .whenUsedAtLeast(fieldId: newId, percent: current)
                    }
                },
                setPercent: { newPercent in
                    update {
                        guard case let .whenUsedAtLeast(id, _) = $0.visibility else { return }
                        $0.visibility = .whenUsedAtLeast(fieldId: id, percent: newPercent)
                    }
                }
            )
        case let .whenRemainingAtMost(fieldId, percent):
            thresholdRow(
                fieldId: fieldId,
                percent: percent,
                setField: { newId in
                    update {
                        guard case let .whenRemainingAtMost(_, current) = $0.visibility else { return }
                        $0.visibility = .whenRemainingAtMost(fieldId: newId, percent: current)
                    }
                },
                setPercent: { newPercent in
                    update {
                        guard case let .whenRemainingAtMost(id, _) = $0.visibility else { return }
                        $0.visibility = .whenRemainingAtMost(fieldId: id, percent: newPercent)
                    }
                }
            )
        case let .whenForecast(fieldId, verdicts):
            HStack(spacing: 8) {
                Text(L10n.MenuBar.composerBlockQuota).frame(width: 62, alignment: .leading)
                fieldPicker(selected: fieldId) { newId in
                    update { $0.visibility = .whenForecast(fieldId: newId, verdicts: verdicts) }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Text(L10n.MenuBar.composerFieldVerdicts).frame(width: 62, alignment: .leading)
                ForEach(Self.selectableVerdicts, id: \.self) { verdict in
                    Toggle(Self.verdictTitle(verdict), isOn: Binding(
                        get: { verdicts.contains(verdict) },
                        set: { on in
                            var next = verdicts
                            if on { next.insert(verdict) } else { next.remove(verdict) }
                            // An empty set would hide the block forever, which
                            // is not a state the editor should let anyone
                            // build; it reads as "no rule" instead.
                            update {
                                $0.visibility = next.isEmpty
                                    ? .always
                                    : .whenForecast(fieldId: fieldId, verdicts: next)
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private static let selectableVerdicts: [QuotaPaceForecast.Verdict] =
        [.atRisk, .watch, .enough, .surplus]

    /// The verdict names the forecast surfaces already use, so the composer's
    /// checkboxes cannot drift from the quota bar's wording.
    private static func verdictTitle(_ verdict: QuotaPaceForecast.Verdict) -> String {
        verdict.label
    }

    /// Two setters, not one taking both values.
    ///
    /// A combined setter has to capture the value it is not changing, and the
    /// captured copy is stale the moment the parent flushes a queued edit —
    /// so picking another quota within the debounce window wrote the
    /// pre-flush threshold back over the one that had just landed. Each
    /// control changes only what it owns, which is the same rule that made
    /// whole-token replacement go away.
    private func thresholdRow(
        fieldId: String,
        percent: Double,
        setField: @escaping (String) -> Void,
        setPercent: @escaping (Double) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(L10n.MenuBar.composerBlockQuota).frame(width: 62, alignment: .leading)
            fieldPicker(selected: fieldId) { setField($0) }
            DebouncedPercentStepper(
                percent: percent,
                pending: pending,
                key: "threshold.\(token.id)"
            ) { setPercent($0) }
            Spacer(minLength: 0)
        }
    }

    private func fieldPicker(
        selected: String,
        set: @escaping (String) -> Void
    ) -> some View {
        Picker("", selection: Binding(get: { selected }, set: set)) {
            // A field the strip names but the catalog no longer lists still
            // needs a row, or selecting it would silently jump elsewhere.
            if !options.contains(where: { $0.id == selected }) {
                Text(selected).tag(selected)
            }
            ForEach(options) { option in
                Text(liveFieldIds.contains(option.id)
                    ? option.displayTitle
                    : L10n.MenuBar.composerFieldOfflineOption(title: option.displayTitle))
                    .tag(option.id)
            }
        }
        .labelsHidden()
        .frame(width: 210)
    }

    // MARK: Bindings

    private func update(_ change: @escaping (inout MenuBarToken) -> Void) {
        apply(change)
    }

    private var colorChoiceBinding: Binding<ColorChoice> {
        Binding(
            get: {
                switch token.style.color {
                case .automatic: return .automatic
                case .forecast: return .forecast
                case .followsQuota: return .followsQuota
                case .brand: return .brand
                case .primary: return .primary
                case .secondary: return .secondary
                case .tertiary: return .tertiary
                case .fixed: return .fixed
                }
            },
            set: { choice in
                let fallbackField = token.quotaFieldId ?? options.first?.id
                update { edited in
                    switch choice {
                    case .automatic: edited.style.color = .automatic
                    case .forecast: edited.style.color = .forecast
                    case .followsQuota:
                        guard let fallbackField else { return }
                        edited.style.color = .followsQuota(fieldId: fallbackField, basis: .forecast)
                    case .brand:
                        if case let .logo(tool) = edited.kind {
                            edited.style.color = .brand(tool)
                        } else {
                            edited.style.color = .brand(ToolType.dedicatedCardProviders.first ?? .claude)
                        }
                    case .primary: edited.style.color = .primary
                    case .secondary: edited.style.color = .secondary
                    case .tertiary: edited.style.color = .tertiary
                    case .fixed: edited.style.color = .hex("#7f7f7f")
                    }
                }
            }
        )
    }

    private var ruleChoiceBinding: Binding<RuleChoice> {
        Binding(
            get: {
                switch token.visibility {
                case .always: return .always
                case .whenUsedAtLeast: return .whenUsedAtLeast
                case .whenRemainingAtMost: return .whenRemainingAtMost
                case .whenForecast: return .whenForecast
                }
            },
            set: { choice in
                let field = token.visibility.fieldId ?? token.quotaFieldId ?? options.first?.id
                update { edited in
                    switch choice {
                    case .always:
                        edited.visibility = .always
                    case .whenUsedAtLeast:
                        guard let field else { return }
                        edited.visibility = .whenUsedAtLeast(fieldId: field, percent: 80)
                    case .whenRemainingAtMost:
                        guard let field else { return }
                        edited.visibility = .whenRemainingAtMost(fieldId: field, percent: 20)
                    case .whenForecast:
                        guard let field else { return }
                        edited.visibility = .whenForecast(fieldId: field, verdicts: [.atRisk, .watch])
                    }
                }
            }
        )
    }

    private var sizeBinding: Binding<MenuBarToken.SizeStep> {
        Binding(get: { token.style.size }, set: { value in update { $0.style.size = value } })
    }

    private var weightBinding: Binding<MenuBarToken.Weight> {
        Binding(get: { token.style.weight }, set: { value in update { $0.style.weight = value } })
    }

    private var monospacedBinding: Binding<Bool> {
        Binding(
            get: { token.style.monospacedDigits },
            set: { value in update { $0.style.monospacedDigits = value } }
        )
    }
}

/// A space-width stepper on the same debounce as everything else in this
/// inspector. See `DebouncedPercentStepper` for why the queue is the editor's
/// rather than this view's.
private struct DebouncedSpaceWidthStepper: View {
    let width: Int
    let pending: PendingEditQueue
    let key: String
    let commit: (Int) -> Void

    @State private var draft = MenuBarToken.defaultSpaceWidth

    var body: some View {
        Stepper(value: $draft, in: MenuBarToken.spaceWidthRange) {
            Text(L10n.MenuBar.composerSpaceWidthValue(count: draft))
                .font(.system(size: 11.5).monospacedDigit())
                .frame(width: 76, alignment: .trailing)
        }
        .onAppear { draft = width }
        .onChange(of: width) { _, updated in
            if updated != draft { draft = updated }
        }
        .onChange(of: draft) { _, value in
            guard value != width else { return }
            let commit = self.commit
            pending.schedule(key) { commit(value) }
        }
    }
}

/// A percent stepper that writes settings on an idle window rather than on
/// every repeat.
///
/// A held stepper auto-repeats, and each repeat used to publish `AppSettings`
/// — a fan-out to every subscriber, plus a menu-bar re-render, ten times a
/// second. Same discipline as `DebouncedSettingsTextField` and the colour
/// well: the control tracks its own draft and commits once the user stops.
private struct DebouncedPercentStepper: View {
    let percent: Double
    let pending: PendingEditQueue
    let key: String
    let commit: (Double) -> Void

    @State private var draft: Double = 0

    var body: some View {
        Stepper(value: $draft, in: 0...100, step: 5) {
            Text(L10n.Common.percent(value: Int(draft.rounded())))
                .font(.system(size: 11.5).monospacedDigit())
                .frame(width: 42, alignment: .trailing)
        }
        .onAppear { draft = percent }
        // An external write — selecting another block, a reset — replaces a
        // draft the user is not in the middle of changing.
        .onChange(of: percent) { _, updated in
            if updated != draft { draft = updated }
        }
        // Queued on the editor, not here: this control does not outlive a
        // selection change, and the value must. Values are captured, never
        // read back out of `@State` after teardown.
        .onChange(of: draft) { _, value in
            guard value != percent else { return }
            let commit = self.commit
            pending.schedule(key) { commit(value) }
        }
    }
}

// MARK: - Drag and drop

/// Where a drop lands: in front of a chip, or at the end of a row.
///
/// A flattened index cannot say which side of a boundary it means, and a drag
/// onto the first chip of a row has to land *in* that row or the gesture does
/// nothing — so the target names the row instead. It is a row rather than a
/// group because a stacked column has two of them, and the empty space after
/// the top row's last chip is not the same place as the empty space after the
/// bottom row's.
enum MenuBarChipDropTarget {
    case before(UUID)
    case endOf(MenuBarComposition.RowAddress)
}

/// Reorder onto a chip, or onto a row's trailing landing strip. The move
/// itself is `MenuBarComposition.move`, so the delegate decides only *where*,
/// never *how*.
private struct MenuBarChipDropDelegate: DropDelegate {
    let target: MenuBarChipDropTarget
    @Binding var dragged: UUID?
    /// Reordered in place on every crossing. Local state, not settings.
    @Binding var provisional: MenuBarComposition?
    let commit: () -> Void
    let entered: () -> Void
    let exited: () -> Void

    func dropExited(info: DropInfo) { exited() }

    func dropEntered(info: DropInfo) {
        entered()
        guard let dragged, provisional != nil else { return }
        switch target {
        case let .before(id):
            provisional?.move(dragged, before: id)
        case let .endOf(address):
            provisional?.move(dragged, toEndOf: address)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        commit()
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

private struct MenuBarChipRemoveDelegate: DropDelegate {
    @Binding var dragged: UUID?
    @Binding var isTargeted: Bool
    @Binding var selection: UUID?
    let remove: (UUID) -> Void
    let entered: () -> Void
    let exited: () -> Void

    func dropEntered(info: DropInfo) {
        entered()
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        exited()
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { isTargeted = false }
        guard let dragged else { return false }
        remove(dragged)
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - Layout

/// Left-to-right wrapping row of chips.
///
/// The strip and the palette are both "as many small things as fit, then wrap"
/// — a `LazyVGrid` would force a column width every chip has to live inside,
/// which is wrong for labels that range from "Space" to "Claude Weekly · Runs
/// out in".
struct MenuBarChipFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        // An unspecified *or* infinite proposal means "how wide do you want to
        // be" — answering `.infinity` there makes the whole settings column
        // grow without bound.
        let proposed = proposal.width
        let maxWidth = (proposed?.isFinite ?? false) ? proposed! : .infinity
        let rows = lines(subviews: subviews, maxWidth: maxWidth)
        let height = rows.reduce(0) { $0 + $1.height } +
            lineSpacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: maxWidth.isFinite ? maxWidth : widest, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        var y = bounds.minY
        for row in lines(subviews: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = measure(subviews[index], maxWidth: bounds.width)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// What a subview wants, given the room this layout actually has.
    ///
    /// `.unspecified` asks "how wide would you like to be", and a subview
    /// that is itself a flow answers with every one of its own children on
    /// one line — so a group box measured that way came out as wide as all
    /// its chips and ran off the pane. Proposing the width available makes
    /// an inner flow wrap inside it, which is the only honest measurement
    /// when a flow holds a flow.
    private func measure(_ subview: Subviews.Element, maxWidth: CGFloat) -> CGSize {
        let intrinsic = subview.sizeThatFits(.unspecified)
        guard maxWidth.isFinite, intrinsic.width > maxWidth else { return intrinsic }
        // Only the ones that do not fit. Proposing the cap to everything
        // makes any greedy subview — a group box, whose header holds a
        // Spacer — report the full width and take a line to itself, which
        // turns "wrap side by side" into "one per row" and makes the
        // composer taller for no reason.
        return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }

    private func lines(subviews: Subviews, maxWidth: CGFloat) -> [Line] {
        var rows: [Line] = []
        var current = Line()
        for index in subviews.indices {
            let size = measure(subviews[index], maxWidth: maxWidth)
            let advance = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, advance > maxWidth {
                rows.append(current)
                current = Line()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = advance
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
