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
    /// The Studio's selection, when this editor is its inspector: a block
    /// picked on the stage is the block the inspector edits, and the other
    /// way round. Kept in step with the editor's own selection rather than
    /// replacing it, so the editor in Settings needs no owner.
    var externalSelection: Binding<Set<UUID>>? = nil
    /// The block in flight from the palette, when this editor is the
    /// Studio's inspector: the stage beside it is a drop target too, and it
    /// needs to know what is being carried. Kept in step the same way.
    var externalPendingBlock: Binding<PendingPaletteBlock?>? = nil

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var quotaService: QuotaService

    /// Holds the subscription to the one list of things a composed strip
    /// depends on. Without it the preview drifts a generation behind the bar.
    @StateObject private var inputs = MenuBarStripInputObserver()
    /// Holds a debounced control's last change until a moment this view can
    /// observe — see `MenuBarPendingCommit`.
    @StateObject private var pendingCommit = PendingEditQueue()
    /// The blocks the editor is acting on. More than one only while the user
    /// is picking a run to bind: the inspector edits a single block, and
    /// everything else that reads this wants the one.
    @State private var selection: Set<UUID> = []
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
    /// A block dragged straight out of the palette. It exists only in this
    /// property until the drag reaches a drop target — nothing is inserted,
    /// nothing is displayed, and a drag released over empty space simply
    /// leaves it behind.
    /// The block dragged out of the palette, and when that drag began.
    ///
    /// It outlives the 200 ms cancel window on purpose, so a drag that wanders
    /// off every target and comes back still has something to stage. The
    /// deadline is what stops an abandoned one from being staged later by an
    /// unrelated drop: the chips accept `.text`, so text dragged in from
    /// another app reaches the same branch. Guarding by payload type instead
    /// is what broke every drag in 1.6.2-dev.69 — `UTType(exportedAs:)` for a
    /// type this app does not declare matches nothing, so the targets refused
    /// their own blocks. A deadline cannot fail that way.
    @State private var draggedNewToken: PendingPaletteBlock?
    /// The quota section whose buckets are showing. Only one at a time: the
    /// palette is a strip of chips, and seven open sections is a wall.
    @State private var openQuotaSection: String?
    /// Fires shortly after the pointer leaves every drop target. SwiftUI has
    /// no "drag cancelled" callback, so a release outside the strip is
    /// inferred from the pointer leaving and not coming back.
    @State private var dragCancelTask: Task<Void, Never>?
    @State private var isOverRemoveTarget = false
    @State private var isConfirmingReseed = false
    /// The segment whose "Save as preset…" dialog is open, and the name being
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
    /// Company and SubProvider marks the quota sections wear that no tool
    /// mark already is — Google AI, SpaceXAI, Grok Bot.
    @State private var paletteBrandLogos: [MenuBarBrandLogo] = []

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
        /// What the block being dragged out of the palette asks for, if
        /// anything. The preview draws the provisional order, so a quota the
        /// committed strip never referenced has no snapshot and would be
        /// missing from the preview for the whole drag. Keyed off the token
        /// rather than the provisional order on purpose: the order changes on
        /// every chip the pointer crosses, and rebuilding there would put
        /// quota resolution on the drag path.
        var stagedRequirements: [MenuBarQuotaRequirement]
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
            stagedRequirements: stagedRequirements,
            displayMode: settingsStore.settings.displayMode,
            colorBasis: settingsStore.settings.menuBarColorBasis,
            customLabels: item.customLabels
        )
    }

    private var stagedRequirements: [MenuBarQuotaRequirement] {
        guard let pending = draggedNewToken else { return [] }
        var staged = MenuBarComposition(isEnabled: true)
        staged.append(pending.token, to: nil)
        return staged.quotaRequirements
    }

    var body: some View {
        let composition = displayedComposition
        let availability = composition.availability(liveFieldIds: liveFieldIds)
        // One walk of the strip per body pass. Asking the composition per chip
        // walked it once per chip — quadratic in a strip the user can grow.
        let bound = composition.boundGroupIDs

        VStack(alignment: .leading, spacing: density.cardSpacing + 4) {
            templateRow(composition)
            previewRow(composition)
            stripRow(composition, availability: availability, bound: bound)
            paletteRow(composition)
            inspectorRow(composition, availability: availability)
            footerRow(availability: availability)
        }
        .alert(
            L10n.MenuBar.Composer.Preset.saveTitle,
            isPresented: Binding(
                get: { savingPresetFrom != nil },
                set: { if !$0 { savingPresetFrom = nil } }
            )
        ) {
            TextField(L10n.Common.name, text: $presetDraftName)
            Button(L10n.Common.save) { savePendingPreset() }
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
        .onChange(of: selection) { _, new in
            pendingCommit.flush()
            if let external = externalSelection, external.wrappedValue != new {
                external.wrappedValue = new
            }
        }
        .onChange(of: externalSelection?.wrappedValue) { _, new in
            if let new, new != selection { selection = new }
        }
        .onChange(of: draggedNewToken) { _, new in
            if let external = externalPendingBlock, external.wrappedValue != new {
                external.wrappedValue = new
            }
        }
        .onChange(of: externalPendingBlock?.wrappedValue) { _, new in
            if let new, new != draggedNewToken { draggedNewToken = new }
        }
        .onAppear {
            if let external = externalSelection?.wrappedValue { selection = external }
        }
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
            Picker(L10n.MenuBar.Composer.template, selection: templateBinding()) {
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
            caption(L10n.MenuBar.Composer.preview)
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
                        highlighted: selectedID
                    )
                    Text(L10n.MenuBar.Composer.Preview.grounds)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if plan.rows.filter({ !$0.isEmpty }).count >= 2 {
                        Text(L10n.MenuBar.Composer.Preview.twoRowScaling)
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
        availability: MenuBarComposition.Availability,
        bound: Set<UUID>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            caption(L10n.MenuBar.Composer.blocks)
            // Keyed on the *committed* strip, not the one being drawn. With no
            // chips and no landing strips left, this placeholder is the only
            // target a palette drag can reach — and staging the block makes
            // the drawn strip non-empty at once, so switching on that would
            // pull the target out from under the pointer before the drop
            // could land, and the 200 ms rollback would undo the insertion.
            if self.composition.segments.isEmpty || composition.segments.isEmpty {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .contentShape(Rectangle())
                        .onDrop(of: [.text], delegate: chipDrop(.newStrip))
                    if composition.segments.isEmpty {
                        Text(L10n.MenuBar.Composer.Blocks.empty)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        segmentFlow(composition, availability: availability, bound: bound)
                    }
                }
            } else {
                segmentFlow(composition, availability: availability, bound: bound)
            }
            removeTarget
        }
    }

    /// The segments themselves wrap, the same way the chips inside them do — a
    /// strip can hold more columns than one line of this settings pane is wide.
    private func segmentFlow(
        _ composition: MenuBarComposition,
        availability: MenuBarComposition.Availability,
        bound: Set<UUID>
    ) -> some View {
        MenuBarChipFlow(spacing: 8, lineSpacing: 8) {
            ForEach(Array(composition.segments.enumerated()), id: \.element.id) { index, segment in
                segmentBox(segment, index: index, of: composition, availability: availability, bound: bound)
            }
        }
    }

    /// One segment: a header that can move, save or remove it, then its blocks.
    private func segmentBox(
        _ segment: MenuBarSegment,
        index: Int,
        of composition: MenuBarComposition,
        availability: MenuBarComposition.Availability,
        bound: Set<UUID>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(L10n.MenuBar.Composer.Segment.title(index: index + 1))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                Spacer(minLength: 4)
                Menu {
                    Button(L10n.MenuBar.Composer.Segment.moveLeft) {
                        mutate { $0.moveSegment(segment.id, by: -1) }
                    }
                    .disabled(index == 0)
                    Button(L10n.MenuBar.Composer.Segment.moveRight) {
                        mutate { $0.moveSegment(segment.id, by: 1) }
                    }
                    .disabled(index == composition.segments.count - 1)
                    Button(L10n.MenuBar.Composer.Segment.mergeLeft) {
                        mutate { $0.mergeSegmentIntoPrevious(segment.id) }
                    }
                    .disabled(index == 0)
                    Divider()
                    // The two row interactions, on the segment rather than in
                    // the palette: a row is a container, so opening and
                    // closing one is something you do *to a column*. Removing
                    // one says where its blocks go, which is why the label
                    // says "merge" rather than "remove" — nothing is deleted.
                    if segment.isStacked {
                        Button(L10n.MenuBar.Composer.Segment.removeRow) {
                            mutate { $0.removeRow(fromSegment: segment.id) }
                        }
                    } else {
                        Button(L10n.MenuBar.Composer.Segment.addRow) {
                            mutate { $0.addRow(toSegment: segment.id) }
                        }
                    }
                    Divider()
                    Button(L10n.MenuBar.Composer.Preset.save) {
                        presetDraftName = ""
                        savingPresetFrom = segment.id
                    }
                    .disabled(segment.isEmpty)
                    Divider()
                    Button(L10n.MenuBar.Composer.Segment.remove, role: .destructive) {
                        selection.subtract(segment.tokens.map(\.id))
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
            // drop target: dragging between the two rows of one segment and
            // dragging between segments are the same gesture.
            rowStrip(segment, row: .top, availability: availability, bound: bound)
            if segment.isStacked {
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 0.5)
                rowStrip(segment, row: .bottom, availability: availability, bound: bound)
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

    /// One row of one segment: its chips, and the empty space after them.
    @ViewBuilder
    private func rowStrip(
        _ segment: MenuBarSegment,
        row: MenuBarSegment.Row,
        availability: MenuBarComposition.Availability,
        bound: Set<UUID>
    ) -> some View {
        let address = MenuBarComposition.RowAddress(segment: segment.id, row: row)
        let tokens = segment[row]
        // The full-row target is mounted whenever the row is empty in *either*
        // arrangement, because a drag can empty one and fill the other.
        //
        // Committed-empty: staging a block fills the drawn row at once, so
        // switching on the drawn one alone would unmount this target mid-drag
        // — releasing over the part of the placeholder the new chip does not
        // cover would then roll the insertion back and add nothing.
        //
        // Drawn-empty: dragging a row's only chip away leaves the committed
        // row full and the drawn one empty, and without this the way back is
        // the 16pt landing strip alone.
        if tokens.isEmpty || committedRowIsEmpty(address) {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(minWidth: 96, minHeight: 22)
                    .contentShape(Rectangle())
                    .onDrop(of: [.text], delegate: chipDrop(.endOf(address)))
                if tokens.isEmpty {
                    // A segment with one empty row is an empty segment; an empty
                    // row inside a stacked one is a row waiting to be filled.
                    // Two sentences, because they are two different situations.
                    Text(
                        segment.isStacked
                            ? L10n.MenuBar.Composer.Row.empty
                            : L10n.MenuBar.Composer.Segment.empty
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 96, minHeight: 22, alignment: .leading)
                } else {
                    chipFlow(tokens, address: address, availability: availability, bound: bound)
                }
            }
        } else {
            chipFlow(tokens, address: address, availability: availability, bound: bound)
        }
    }

    /// Whether the row this address names holds nothing in the *committed*
    /// arrangement — what decides whether the placeholder's stable drop target
    /// is mounted, independent of anything a live drag has staged.
    private func committedRowIsEmpty(_ address: MenuBarComposition.RowAddress) -> Bool {
        guard let index = composition.segmentIndex(of: address.segment) else { return false }
        return composition.segments[index][address.row].isEmpty
    }

    private func chipFlow(
        _ tokens: [MenuBarToken],
        address: MenuBarComposition.RowAddress,
        availability: MenuBarComposition.Availability,
        bound: Set<UUID>
    ) -> some View {
        MenuBarChipFlow(spacing: 5, lineSpacing: 5) {
            ForEach(tokens) { token in
                chip(token, availability: availability, bound: bound)
                    .onDrag {
                        // A queued colour or threshold has to land first:
                        // the drop writes this snapshot back wholesale, so
                        // an edit missing from it would be undone by the
                        // drag that followed it.
                        pendingCommit.flush()
                        dragEnteredTarget()
                        draggedNewToken = nil
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

    private func chipDrop(_ target: MenuBarChipDropTarget) -> MenuBarChipDropDelegate {
        MenuBarChipDropDelegate(
            target: target,
            dragged: $draggedTokenId,
            provisional: $dragComposition,
            pendingNew: $draggedNewToken,
            committed: { composition },
            commit: { commitDrag() },
            entered: { dragEnteredTarget() },
            exited: { dragLeftTarget() }
        )
    }

    private var removeTarget: some View {
        HStack(spacing: 6) {
            Image(systemName: "trash")
                .font(.system(size: 10, weight: .semibold))
            Text(L10n.MenuBar.Composer.removeTarget)
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
        availability: MenuBarComposition.Availability,
        bound: Set<UUID>
    ) -> some View {
        let isSelected = selection.contains(token.id)
        let isSilent = availability.silentTokenIds.contains(token.id)
        let isDegraded = availability.degradedTokenIds.contains(token.id)
        let isBound = token.groupID.map(bound.contains) ?? false
        return Button {
            selection = isSelected && selection.count == 1 ? [] : [token.id]
        } label: {
            HStack(spacing: 4) {
                // A quota block wears its provider's mark, the way the
                // palette entry it came from does — the fastest way to tell
                // one "Weekly" from another.
                switch token.kind {
                case let .logo(tool):
                    ToolBrandIconView(tool: tool, size: 11)
                case let .brandLogo(logo):
                    BrandLogoIconView(logo: logo, size: 11)
                case let .quota(fieldId, _):
                    if let option = optionsById[fieldId] {
                        QuotaBrandIconView(tool: option.tool, bucketID: option.bucketId, size: 11)
                    } else {
                        Image(systemName: symbol(for: token.kind))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                default:
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
                    .fill(
                        isBound
                            ? Color.accentColor.opacity(isSelected ? 0.30 : 0.16)
                            : Color.primary.opacity(isSelected ? 0.14 : 0.06)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? Color.accentColor.opacity(0.8)
                            : (isBound
                                ? Color.accentColor.opacity(0.45)
                                : Color.primary.opacity(0.10)),
                        lineWidth: 0.5
                    )
            )
            .opacity(isSilent ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        // Shift wins over the button's own tap, which is what lets one click
        // pick a block and shift-click build the run to bind.
        .highPriorityGesture(
            TapGesture().modifiers(.shift).onEnded {
                if selection.contains(token.id) {
                    selection.remove(token.id)
                } else {
                    selection.insert(token.id)
                }
            }
        )
        .help(chipHelp(token, isSilent: isSilent, isDegraded: isDegraded))
    }

    /// The actions for a multi-block selection: bind them, or say why not.
    ///
    /// Its own row rather than a mode: the inspector edits one block, and
    /// picking several is a different thing to be doing.
    private func groupBar(_ composition: MenuBarComposition) -> some View {
        let ids = Array(selection)
        let canBind = composition.canGroup(ids)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                caption(L10n.MenuBar.Composer.Group.selected(count: selection.count))
                Spacer(minLength: 8)
                Button(L10n.MenuBar.Composer.Group.bind) {
                    mutate { $0.group(ids) }
                    selection = []
                }
                .buttonStyle(.vibeBar)
                .disabled(!canBind)
                Button(L10n.Common.clear) { selection = [] }
                    .buttonStyle(.vibeBar)
            }
            Text(canBind ? L10n.MenuBar.Composer.Group.hint : L10n.MenuBar.Composer.Group.notAdjacent)
                .font(.caption2)
                .foregroundStyle(canBind ? .tertiary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The one selected block, when there is exactly one. Multi-selection
    /// exists only to bind a run; every other control edits a single block.
    private var selectedID: UUID? {
        selection.count == 1 ? selection.first : nil
    }

    private func symbol(for kind: MenuBarToken.Kind) -> String {
        MenuBarTokenNaming.symbol(for: kind)
    }

    private func chipTitle(_ token: MenuBarToken) -> String {
        MenuBarTokenNaming(optionsById: optionsById).title(token)
    }

    /// "Grok Bot · Weekly", "ChatGPT · GPT-5.3 Codex Spark · 5 Hours" — see
    /// `MenuBarTokenNaming.fieldTitle`.
    static func fieldTitle(_ option: MenuBarFieldOption) -> String {
        MenuBarTokenNaming.fieldTitle(option)
    }

    private func chipHelp(_ token: MenuBarToken, isSilent: Bool, isDegraded: Bool) -> String {
        if isSilent {
            return L10n.MenuBar.Composer.Warning.silent
        }
        if isDegraded {
            return L10n.MenuBar.Composer.Warning.degraded
        }
        return chipTitle(token)
    }

    // MARK: - Palette

    private func paletteRow(_ composition: MenuBarComposition) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            caption(L10n.MenuBar.Composer.palette)
            paletteGroup(L10n.MenuBar.Composer.Block.logo) {
                paletteButton(title: L10n.MenuBar.Composer.Block.appIcon, icon: "menubar.rectangle") {
                    MenuBarToken.newAppIcon()
                }
                ForEach(paletteLogoTools, id: \.self) { tool in
                    paletteButton(title: tool.menuTitle, icon: nil, tool: tool) {
                        MenuBarToken.newLogo(tool)
                    }
                }
                ForEach(paletteBrandLogos, id: \.self) { logo in
                    paletteButton(title: logo.name, icon: nil, brand: logo) {
                        MenuBarToken.newBrandLogo(logo)
                    }
                }
            }
            paletteGroup(L10n.MenuBar.Composer.Block.text) {
                paletteButton(title: L10n.MenuBar.Composer.Block.text, icon: "textformat") {
                    MenuBarToken.newText()
                }
            }
            paletteQuotaGroup()
            paletteGroup(L10n.MenuBar.Composer.Block.structure) {
                paletteButton(title: L10n.MenuBar.Composer.Block.space, icon: "space") {
                    MenuBarToken.newSpace()
                }
                paletteButton(title: L10n.MenuBar.Composer.Block.separator, icon: "line.diagonal") {
                    MenuBarToken.newSeparator()
                }
                // No "New row" block here on purpose. A row is a place blocks
                // live, not a block you insert — giving a segment its second row
                // is an action on the segment, and it lives in the segment's own
                // menu beside move, merge and remove.
                paletteButton(
                    title: L10n.MenuBar.Composer.Segment.add,
                    icon: "rectangle.split.2x1"
                ) {
                    addSegment()
                }
                .help(L10n.MenuBar.Composer.Segment.addHelp)
            }
            presetsRow()
        }
    }

    /// Quota blocks, one section per L2 SubProvider.
    ///
    /// These used to be dropdown menus. A menu item cannot be dragged — it
    /// lives in an AppKit popup — so every quota block had to be added first
    /// and dragged second, which is the two-gesture problem this whole change
    /// is about, and quota blocks are most of what anyone adds. Opening a
    /// section in place costs one click and makes its buckets ordinary
    /// draggable chips.
    @ViewBuilder
    private func paletteQuotaGroup() -> some View {
        paletteGroup(L10n.MenuBar.Composer.Block.quota) {
            ForEach(paletteQuotaSections) { section in
                paletteButton(
                    title: section.title,
                    icon: nil,
                    tool: section.tool,
                    bucketID: section.options.first?.bucketId,
                    isOpen: openQuotaSection == section.id
                ) {
                    openQuotaSection = openQuotaSection == section.id ? nil : section.id
                }
            }
        }
        if let open = paletteQuotaSections.first(where: { $0.id == openQuotaSection }) {
            // No caption: the open section chip above already names it, and
            // the empty label column keeps these aligned with every other row.
            paletteGroup("") {
                ForEach(open.options) { option in
                    paletteButton(title: option.displayTitle, icon: "gauge.with.needle") {
                        MenuBarToken.newQuota(fieldId: option.id)
                    }
                }
            }
        }
    }

    /// The saved segments, if there are any. Click one to insert it at the end
    /// of the strip.
    @ViewBuilder
    private func presetsRow() -> some View {
        if !item.segmentPresets.isEmpty {
            paletteGroup(L10n.MenuBar.Composer.presets) {
                ForEach(item.segmentPresets) { preset in
                    paletteButton(title: preset.name, icon: "square.on.square") {
                        insert(preset: preset)
                    }
                    .help(L10n.MenuBar.Composer.Preset.insertHelp)
                    .contextMenu {
                        Button(L10n.MenuBar.Composer.Preset.remove, role: .destructive) {
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

    /// A palette entry for a single block: click to append it, or drag it
    /// straight where you want it.
    ///
    /// Dragging used to mean adding first and dragging second, which is two
    /// gestures for one intent and left the block at the end of the strip if
    /// you stopped after the first.
    private func paletteButton(
        title: String,
        icon: String?,
        tool: ToolType? = nil,
        brand: MenuBarBrandLogo? = nil,
        make: @escaping () -> MenuBarToken
    ) -> some View {
        paletteButton(title: title, icon: icon, tool: tool, brand: brand) { add(make()) }
            .onDrag {
                // Same flush as a chip drag: the drop writes the whole
                // snapshot back, so a queued edit missing from it would be
                // undone by this drag.
                pendingCommit.flush()
                let token = make()
                draggedTokenId = nil
                dragComposition = nil
                draggedNewToken = PendingPaletteBlock(token: token)
                return NSItemProvider(object: token.id.uuidString as NSString)
            }
    }

    private func paletteButton(
        title: String,
        icon: String?,
        tool: ToolType? = nil,
        bucketID: String? = nil,
        brand: MenuBarBrandLogo? = nil,
        isOpen: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let brand {
                    BrandLogoIconView(logo: brand, size: 11)
                } else if let tool {
                    // Bucket-aware: a quota section riding another company's
                    // account draws its own mark, not the account holder's.
                    QuotaBrandIconView(tool: tool, bucketID: bucketID, size: 11)
                } else if let icon {
                    Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                }
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(isOpen ? 0.14 : 0.06))
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
        if selection.count > 1 {
            groupBar(composition)
        } else if let id = selectedID, let token = composition.token(id) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    caption(L10n.MenuBar.Composer.selected)
                    Spacer(minLength: 8)
                    // Only where it would do something — the model's own
                    // predicate, so a visible action is never a no-op. A block
                    // that already starts its segment has none to start, a
                    // column is cut through its top row, and a cut through a
                    // bound run is refused.
                    if composition.canSplitSegment(before: id) {
                        Button(L10n.MenuBar.Composer.Segment.splitHere) {
                            mutate { $0.splitSegment(before: id) }
                        }
                        .buttonStyle(.vibeBar)
                    }
                    if composition.isGrouped(id) {
                        Button(L10n.MenuBar.Composer.Group.unbind) {
                            mutate { $0.ungroup(id) }
                        }
                        .buttonStyle(.vibeBar)
                    }
                    Button(L10n.MenuBar.Composer.Action.duplicate) { mutate { $0.duplicate(id) } }
                        .buttonStyle(.vibeBar)
                    Button(L10n.Common.remove) {
                        selection = []
                        mutate { $0.remove(id) }
                    }
                    .buttonStyle(.vibeBar)
                }
                if availability.silentTokenIds.contains(id) {
                    warning(L10n.MenuBar.Composer.Warning.silent)
                } else if availability.degradedTokenIds.contains(id) {
                    warning(L10n.MenuBar.Composer.Warning.degraded)
                }
                MenuBarTokenInspector(
                    brandLogos: paletteBrandLogos,
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
                warning(L10n.MenuBar.Composer.Warning.missing(
                    fields: availability.missingFieldIds
                        .map { optionsById[$0]?.displayTitle ?? $0 }
                        .joined(separator: ", ")
                ))
            }
            HStack(spacing: 8) {
                Button(L10n.MenuBar.Composer.startOver) { isConfirmingReseed = true }
                    .buttonStyle(.vibeBar)
                Spacer(minLength: 8)
            }
            Text(L10n.MenuBar.Composer.StartOver.detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog(
            L10n.MenuBar.Composer.StartOver.confirmTitle,
            isPresented: $isConfirmingReseed,
            titleVisibility: .visible
        ) {
            Button(L10n.MenuBar.Composer.StartOver.confirm, role: .destructive) {
                selection = []
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
            Text(L10n.MenuBar.Composer.StartOver.confirmMessage)
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
        draggedNewToken = nil
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

    /// Save the segment the dialog was opened on, under the name that was typed.
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
            draggedNewToken = nil
            return
        }
        let segments = reordered.segments
        // `mutate` clears the drag state before writing.
        mutate { $0.segments = segments }
    }

    private func removeDragged(_ id: UUID) {
        selection.remove(id)
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
        if let selectedID, let location = composition.location(of: selectedID) {
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
        selection = [token.id]
    }

    private func addSegment() {
        let segment = MenuBarSegment()
        mutate { $0.appendSegment(segment) }
        // Nothing to select — the segment is empty — but the next added block
        // has to land in it rather than in whatever was selected before.
        selection = []
    }

    private func insert(preset: MenuBarSegmentPreset) {
        mutate { $0.appendSegment(preset.segment()) }
        selection = []
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
        // Every mark the Quota row can show that the Logo row could not: the
        // companies with a mark of their own, then the SubProviders with one.
        // Deduplicated by picture, so Gemini and AntiGravity offer Google AI
        // once.
        var brandLogos: [MenuBarBrandLogo] = []
        var marks = Set<BrandMark>()
        for tool in ToolType.dedicatedCardProviders {
            let logo = MenuBarBrandLogo.company(tool)
            if let mark = logo.brandMark, marks.insert(mark).inserted {
                brandLogos.append(logo)
            }
        }
        for section in sections {
            guard let bucket = section.options.first?.bucketId else { continue }
            let logo = MenuBarBrandLogo.subProvider(section.tool, bucketId: bucket)
            if let mark = logo.brandMark, marks.insert(mark).inserted {
                brandLogos.append(logo)
            }
        }
        paletteBrandLogos = brandLogos
    }

    /// What the snapshots are resolved from: the order being drawn, plus the
    /// block still in flight from the palette.
    ///
    /// A palette drag sets `draggedNewToken` before it reaches any target, so
    /// at that moment `displayedComposition` is still the committed order. If
    /// resolution stopped there, the quota would have no snapshot — and
    /// `dropEntered` changes nothing `snapshotKey` watches, so no second
    /// rebuild would come. Nothing draws this copy; it exists to be resolved.
    private var resolvableComposition: MenuBarComposition {
        var order = displayedComposition
        if let pending = draggedNewToken, order.location(of: pending.token.id) == nil {
            order.append(pending.token, to: nil)
        }
        return order
    }

    private func rebuildSnapshots() {
        snapshots = MenuBarStripResolver.snapshots(
            for: resolvableComposition,
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
    /// The company and SubProvider marks the palette offers, so the logo
    /// picker lists the same choices as the row the block came from.
    let brandLogos: [MenuBarBrandLogo]
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
            case .automatic: return L10n.MenuBar.Composer.Colour.automatic
            case .forecast: return L10n.MenuBar.Composer.Colour.forecast
            case .followsQuota: return L10n.MenuBar.Composer.Colour.followsQuota
            case .brand: return L10n.MenuBar.Composer.Colour.brand
            case .primary: return L10n.MenuBar.Composer.Colour.primary
            case .secondary: return L10n.MenuBar.Composer.Colour.secondary
            case .tertiary: return L10n.MenuBar.Composer.Colour.tertiary
            case .fixed: return L10n.MenuBar.Composer.Colour.fixed
            }
        }
    }

    private enum RuleChoice: String, CaseIterable, Identifiable {
        case always, whenUsedAtLeast, whenRemainingAtMost, whenForecast
        var id: String { rawValue }
        var title: String {
            switch self {
            case .always: return L10n.MenuBar.Composer.Rule.always
            case .whenUsedAtLeast: return L10n.MenuBar.Composer.Rule.whenUsedAtLeast
            case .whenRemainingAtMost: return L10n.MenuBar.Composer.Rule.whenRemainingAtMost
            case .whenForecast: return L10n.MenuBar.Composer.Rule.whenForecast
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
                    Picker(L10n.MenuBar.Composer.Field.size, selection: sizeBinding) {
                        ForEach(MenuBarToken.SizeStep.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .frame(width: 150)
                    Picker(L10n.MenuBar.Composer.Field.weight, selection: weightBinding) {
                        ForEach(MenuBarToken.Weight.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .frame(width: 165)
                }
                Toggle(L10n.MenuBar.Composer.Field.monospacedDigits, isOn: monospacedBinding)
                    .help(L10n.MenuBar.Composer.Field.monospacedDigitsHelp)
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
                Text(L10n.MenuBar.Composer.Block.text).frame(width: 62, alignment: .leading)
                DebouncedSettingsTextField(
                    prompt: L10n.MenuBar.Composer.Text.placeholder,
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
                    ? L10n.MenuBar.Composer.Text.empty
                    : L10n.MenuBar.Composer.Text.limit(count: MenuBarToken.maximumTextLength)
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        case let .separator(separator):
            HStack(spacing: 8) {
                Text(L10n.MenuBar.Composer.Block.separator).frame(width: 62, alignment: .leading)
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
                Text(L10n.MenuBar.Composer.Block.quota).frame(width: 62, alignment: .leading)
                fieldPicker(selected: fieldId) { newId in
                    update { $0.kind = .quota(fieldId: newId, metric: metric) }
                }
            }
            HStack(spacing: 8) {
                Text(L10n.MenuBar.Composer.Field.shows).frame(width: 62, alignment: .leading)
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
                    Text(L10n.MenuBar.Composer.Field.resetFormat)
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
                .help(L10n.MenuBar.Composer.Field.resetFormatHelp)
            }
        case .logo, .brandLogo:
            HStack(spacing: 8) {
                Text(L10n.Common.provider).frame(width: 62, alignment: .leading)
                Picker("", selection: Binding(
                    get: { token.kind },
                    set: { value in update { $0.kind = value } }
                )) {
                    // A mark the palette no longer offers (its quota went
                    // away) still needs a row, or the picker would show a
                    // neighbour and a click would silently change the block.
                    if !logoChoices.contains(token.kind) {
                        Text(logoTitle(token.kind)).tag(token.kind)
                    }
                    ForEach(logoChoices, id: \.self) { kind in
                        Text(logoTitle(kind)).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
        case let .space(width):
            HStack(spacing: 8) {
                Text(L10n.MenuBar.Composer.Space.width).frame(width: 62, alignment: .leading)
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
            Text(L10n.MenuBar.Composer.Space.detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .appIcon:
            Text(L10n.MenuBar.Composer.AppIcon.detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .unsupported:
            Text(L10n.MenuBar.Composer.Unsupported.detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Colour

    @ViewBuilder
    private var colorControls: some View {
        HStack(spacing: 8) {
            Text(L10n.MenuBar.Composer.Field.colour).frame(width: 62, alignment: .leading)
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
            Text(L10n.MenuBar.Composer.Field.show).frame(width: 62, alignment: .leading)
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
                Text(L10n.MenuBar.Composer.Block.quota).frame(width: 62, alignment: .leading)
                fieldPicker(selected: fieldId) { newId in
                    update { $0.visibility = .whenForecast(fieldId: newId, verdicts: verdicts) }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Text(L10n.MenuBar.Composer.Field.verdicts).frame(width: 62, alignment: .leading)
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
            Text(L10n.MenuBar.Composer.Block.quota).frame(width: 62, alignment: .leading)
            fieldPicker(selected: fieldId) { setField($0) }
            DebouncedPercentStepper(
                percent: percent,
                pending: pending,
                key: "threshold.\(token.id)"
            ) { setPercent($0) }
            Spacer(minLength: 0)
        }
    }

    /// Every mark a logo block can be: the tools, then the company and
    /// SubProvider marks — the Logo row of the palette, in its order.
    private var logoChoices: [MenuBarToken.Kind] {
        ToolType.dedicatedCardProviders.map { MenuBarToken.Kind.logo($0) }
            + brandLogos.map { MenuBarToken.Kind.brandLogo($0) }
    }

    private func logoTitle(_ kind: MenuBarToken.Kind) -> String {
        switch kind {
        case let .logo(tool): return tool.menuTitle
        case let .brandLogo(logo): return logo.name
        default: return ""
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
                let title = MenuBarComposerEditor.fieldTitle(option)
                Text(liveFieldIds.contains(option.id)
                    ? title
                    : L10n.MenuBar.Composer.Field.offlineOption(title: title))
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
                        } else if case let .brandLogo(logo) = edited.kind {
                            edited.style.color = .brand(logo.accentTool)
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
            Text(L10n.MenuBar.Composer.Space.widthValue(count: draft))
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
/// segment because a stacked column has two of them, and the empty space after
/// the top row's last chip is not the same place as the empty space after the
/// bottom row's.
/// A palette block in flight, with the moment its drag began.
///
/// See `MenuBarComposerEditor.draggedNewToken` for why the deadline is here
/// rather than a payload type.
struct PendingPaletteBlock: Equatable {
    let token: MenuBarToken
    var startedAt: Date = .now

    /// Long enough for a drag that leaves the strip, hesitates and comes back;
    /// short enough that a drag abandoned over nothing is not still waiting
    /// when the next one arrives.
    static let deadline: TimeInterval = 30

    /// Identifying the payload instead was tried twice and cost the feature
    /// both times. A private `UTType` changes what the targets *match*, so
    /// they refused their own blocks — that is the dev.69 outage. Tagging the
    /// provider's `suggestedName` and checking it in `dropEntered` does not
    /// survive the drag: measured in the running app, the receiving side sees
    /// no name, so palette staging never fired. Reading the payload itself is
    /// asynchronous and `dropEntered` is not.
    ///
    /// So the window is bounded rather than the payload identified. The worst
    /// case left is narrow — abandon a palette drag over nothing, then within
    /// half a minute drag text in from another app onto a chip, and that block
    /// lands. It is one drag to the bin, and a guard that fails closed costs
    /// the whole feature.
    var isLive: Bool { Date.now.timeIntervalSince(startedAt) < Self.deadline }
}

enum MenuBarChipDropTarget {
    case before(UUID)
    case endOf(MenuBarComposition.RowAddress)
    /// The strip with no segments left in it. A block landing here opens the
    /// first one — `append(_:to: nil)`.
    case newStrip
}

/// Reorder onto a chip, or onto a row's trailing landing strip. The move
/// itself is `MenuBarComposition.move`, so the delegate decides only *where*,
/// never *how*.
private struct MenuBarChipDropDelegate: DropDelegate {
    let target: MenuBarChipDropTarget
    @Binding var dragged: UUID?
    /// Reordered in place on every crossing. Local state, not settings.
    @Binding var provisional: MenuBarComposition?
    /// A block dragged out of the palette, waiting for its first target.
    @Binding var pendingNew: PendingPaletteBlock?
    /// The committed order, to seed a provisional that does not exist yet
    /// because this drag started in the palette rather than on a chip.
    let committed: () -> MenuBarComposition
    let commit: () -> Void
    let entered: () -> Void
    let exited: () -> Void

    func dropExited(info: DropInfo) { exited() }

    func dropEntered(info: DropInfo) {
        entered()
        // First target a palette drag reaches: the block joins the
        // provisional order here, and from the next crossing on it is an
        // ordinary dragged chip. Landing it on arrival rather than at the
        // drag's start is what lets a drag released over nothing add nothing
        // — there is no speculative insertion to undo.
        if dragged == nil, let pending = pendingNew, pending.isLive {
            let new = pending.token
            var order = provisional ?? committed()
            switch target {
            case let .before(id):
                guard let at = order.location(of: id) else { return }
                // Into the target's own row first, so the move that follows
                // is a same-row reorder and cannot leave an empty segment
                // behind the way appending to a new one would.
                order.append(new, to: MenuBarComposition.RowAddress(
                    segment: order.segments[at.segment].id,
                    row: at.row
                ))
                order.move(new.id, before: id)
            case let .endOf(address):
                order.append(new, to: address)
            case .newStrip:
                order.append(new, to: nil)
            }
            provisional = order
            dragged = new.id
            // `pendingNew` deliberately survives the insertion. A drag that
            // wanders off every target long enough clears `dragged` and rolls
            // `provisional` back to the committed order; without the token
            // still here, coming back would stage nothing and the drop would
            // add nothing. The drag's end clears it — see `mutate`.
            return
        }
        guard let dragged, provisional != nil else { return }
        switch target {
        case let .before(id):
            provisional?.move(dragged, before: id)
        case let .endOf(address):
            provisional?.move(dragged, toEndOf: address)
        // Unreachable: a strip holding the chip being dragged is not empty.
        case .newStrip:
            break
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
    @Binding var selection: Set<UUID>
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
    /// one line — so a segment box measured that way came out as wide as all
    /// its chips and ran off the pane. Proposing the width available makes
    /// an inner flow wrap inside it, which is the only honest measurement
    /// when a flow holds a flow.
    private func measure(_ subview: Subviews.Element, maxWidth: CGFloat) -> CGSize {
        let intrinsic = subview.sizeThatFits(.unspecified)
        guard maxWidth.isFinite, intrinsic.width > maxWidth else { return intrinsic }
        // Only the ones that do not fit. Proposing the cap to everything
        // makes any greedy subview — a segment box, whose header holds a
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
