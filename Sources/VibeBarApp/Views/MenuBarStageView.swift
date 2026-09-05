import AppKit
import SwiftUI
import VibeBarCore

/// The menu bar strip on the Studio's stage: the strip drawn large, and the
/// gesture that arranges it.
///
/// Everything the Settings composer does with chips this does on the strip
/// itself — pick a block up and it moves, its whole group with it, the rest
/// making room live; drop it on the well below to remove it; click to select,
/// shift-click to build a run, ⌘G to bind it. The composer's inspector sits
/// beside this in the Studio and edits the block that is selected here.
///
/// Self-contained on purpose: it owns the gesture, the selection's meaning,
/// and the provisional order, and writes settings exactly once per drop. The
/// Studio hosts it, scales it, and lends it the light and dark grounds.
struct MenuBarStageView: View {
    let kind: MenuBarItemKind
    @Binding var selection: Set<UUID>
    /// The menu bar the strip is previewed on.
    let scheme: ColorScheme
    /// The Studio's scale. The strip is drawn at `baseZoom` times it, so
    /// "100 %" on the stage is a strip large enough to take hold of.
    let scale: CGFloat
    /// The stage's size at the Studio's 100 %, whenever it changes — what
    /// Fit measures against.
    var onNaturalSize: ((CGSize) -> Void)? = nil
    /// Whether a block is being carried, whenever that changes — so the
    /// Studio can tell an Escape the strip will answer from one it should.
    var onDragChange: ((Bool) -> Void)? = nil

    /// How much larger than the bar the strip is at the Studio's 100 %.
    static let baseZoom: CGFloat = 2.5

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var quotaService: QuotaService

    /// Holds the subscription to the one list of things a composed strip
    /// depends on — the same list the status item re-renders on.
    @StateObject private var inputs = MenuBarStripInputObserver()

    // Everything expensive is cached and rebuilt on a data change, never on
    // a pointer move: resolving a quota can compute a personal forecast.
    @State private var snapshots: [MenuBarQuotaSnapshot] = []
    @State private var liveFieldIds: Set<String> = []
    @State private var optionsById: [String: MenuBarFieldOption] = [:]

    @State private var frames = MenuBarStageFrames()
    @State private var drag: StageDrag?
    /// Set by Escape mid-drag: the gesture keeps reporting until the button
    /// is released, and every report after the cancel must be ignored.
    @State private var isDragCancelled = false
    /// The order the strip *would* have if the drag ended here. Local state,
    /// not settings: writing every crossing through `settingsStore` would
    /// re-render the menu bar mid-gesture.
    @State private var dragComposition: MenuBarComposition?
    /// The stage's frame in the shared space, to place the picture carried
    /// under the pointer.
    @State private var stageFrame: CGRect = .zero
    @FocusState private var isFocused: Bool

    private static let dragThreshold: CGFloat = 4
    /// How far above or below a row a drag may hover and still mean it.
    private static let reach: CGFloat = 40
    private static let reflow = Animation.snappy(duration: 0.26, extraBounce: 0.03)

    private struct StageDrag {
        /// The block pressed, nil for a press on the ground.
        let anchor: UUID?
        /// The blocks that move with it — its whole group.
        let run: [UUID]
        /// Where the press began; the threshold is measured from here.
        let start: CGPoint
        var location: CGPoint
        var engaged = false
        /// Where inside the run's box the pointer took hold, so the picture
        /// does not jump to centre itself on the cursor.
        var grabOffset: CGSize = .zero
        var target: MenuBarStageTarget?
    }

    private var zoom: CGFloat { Self.baseZoom * scale }
    private var item: MenuBarItemSettings { settingsStore.settings.menuBarItem(kind) }
    private var composition: MenuBarComposition { item.composition ?? MenuBarComposition() }
    private var naming: MenuBarTokenNaming { MenuBarTokenNaming(optionsById: optionsById) }

    /// What the stage draws: the provisional order while a drag is in
    /// flight, the committed one otherwise.
    private var displayedComposition: MenuBarComposition {
        guard drag?.engaged == true, let dragComposition else { return composition }
        return dragComposition
    }

    /// Everything the cached snapshots are derived from — see the composer's
    /// `SnapshotKey` for why the display mode and colour basis are in here.
    private struct SnapshotKey: Equatable {
        var requirements: [MenuBarQuotaRequirement]
        var displayMode: DisplayMode
        var colorBasis: MenuBarColorBasis
        var customLabels: [String: String]
    }

    private var snapshotKey: SnapshotKey {
        SnapshotKey(
            requirements: composition.quotaRequirements,
            displayMode: settingsStore.settings.displayMode,
            colorBasis: settingsStore.settings.menuBarColorBasis,
            customLabels: item.customLabels
        )
    }

    private var needsForecastClock: Bool {
        composition.needsForecastClock(colorBasis: settingsStore.settings.menuBarColorBasis)
    }

    var body: some View {
        let composition = displayedComposition
        let availability = composition.availability(liveFieldIds: liveFieldIds)
        let bound = composition.boundGroupIDs
        // Hugs the strip: the well below stretches to the strip's width
        // rather than the stage's, so the pair reads as one object.
        VStack(alignment: .center, spacing: 14) {
            // A countdown block is wrong a minute later with no new data
            // behind it. Gated on the strip actually printing one — see the
            // composer's preview for the reasoning.
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
                    canvas: MenuBarStripMetrics.twoRowCanvas()
                )
                stage(composition, plan: plan, availability: availability, bound: bound)
            }
            well
        }
        .fixedSize(horizontal: true, vertical: false)
        .coordinateSpace(.named(MenuBarStageSpace.name))
        .onChange(of: drag?.engaged == true) { _, isDragging in onDragChange?(isDragging) }
        .onAppear {
            inputs.start(environment: environment)
            rebuild()
        }
        .onReceive(inputs.$generation) { _ in rebuild() }
        .onChange(of: snapshotKey) { _, _ in rebuild() }
        // A forecast percentage, a verdict rule, or a forecast colour goes
        // stale on `QuotaService`'s five-minute grid, and none of the input
        // publishers fires in between — same pacing as the composer's.
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
                rebuild()
            }
        }
    }

    private func rebuild() {
        let merged = MenuBarFieldCatalog.mergedFields(registry: quotaService.fieldRegistry)
        optionsById = Dictionary(merged.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        snapshots = MenuBarStripResolver.snapshots(
            for: composition,
            itemSettings: item,
            settings: settingsStore.settings,
            environment: environment
        )
        liveFieldIds = MenuBarStripResolver.liveFieldIds(environment: environment)
    }

    // MARK: - Stage

    private func stage(
        _ composition: MenuBarComposition,
        plan: MenuBarRenderPlan,
        availability: MenuBarComposition.Availability,
        bound: Set<UUID>
    ) -> some View {
        let lifted: Set<UUID> = drag?.engaged == true ? Set(drag?.run ?? []) : []
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                // A stand-in for a menu bar, not a card: a light or a dark
                // ground to read the strip against.
                .fill(scheme == .dark ? Color.black.opacity(0.84) : Color.white.opacity(0.94))
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(isFocused ? 0.26 : 0.12), lineWidth: 0.5)
            if composition.segments.isEmpty {
                Text(L10n.MenuBar.Composer.Blocks.empty)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(18)
            } else {
                MenuBarStripStage(
                    composition: composition,
                    plan: plan,
                    template: composition.template,
                    quotas: snapshots,
                    displayMode: settingsStore.settings.displayMode,
                    availability: availability,
                    bound: bound,
                    selection: selection,
                    lifted: lifted,
                    scheme: scheme,
                    zoom: zoom,
                    frames: frames,
                    naming: naming,
                    tokenMenu: { token in tokenMenu(token, in: composition) },
                    segmentMenu: { segment, index in segmentMenu(segment, index: index, of: composition) }
                )
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
        }
        .fixedSize()
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(MenuBarStageSpace.name)) } action: { frame in
            stageFrame = frame
            onNaturalSize?(CGSize(width: frame.width / scale, height: frame.height / scale))
        }
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .overlay(alignment: .topLeading) {
            if let drag, drag.engaged, !drag.run.isEmpty {
                ghost(drag, composition: composition, plan: plan)
            }
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handleKey(press, composition: composition) }
        .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.16), radius: 22, y: 10)
    }

    /// The picture carried under the pointer: the run being moved, drawn as
    /// the stage draws it, over the placeholder that is making room.
    private func ghost(
        _ drag: StageDrag,
        composition: MenuBarComposition,
        plan: MenuBarRenderPlan
    ) -> some View {
        let tokens = drag.run.compactMap { composition.token($0) }
        var rendered: [UUID: MenuBarRenderedToken] = [:]
        for column in plan.columns {
            for token in column.top.tokens { rendered[token.id] = token }
            for token in column.bottom?.tokens ?? [] { rendered[token.id] = token }
        }
        return MenuBarStageRunGhost(
            tokens: tokens,
            rendered: rendered,
            template: composition.template,
            plan: plan,
            quotas: snapshots,
            displayMode: settingsStore.settings.displayMode,
            scheme: scheme,
            zoom: zoom,
            naming: naming
        )
        .scaleEffect(1.04)
        .offset(
            x: drag.location.x - drag.grabOffset.width - stageFrame.minX,
            y: drag.location.y - drag.grabOffset.height - stageFrame.minY
        )
    }

    /// The bar a block is dropped on to remove it. Lit while the pointer is
    /// over it with a block in hand.
    private var well: some View {
        let isTargeted = drag?.target == .removed
        return HStack(spacing: 6) {
            Image(systemName: "trash")
                .font(.system(size: 11, weight: .semibold))
            Text(L10n.MenuBar.Composer.removeTarget)
                .font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(isTargeted ? Color.red : Color.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.red.opacity(isTargeted ? 0.16 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    Color.red.opacity(isTargeted ? 0.55 : 0.2),
                    style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])
                )
        )
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(MenuBarStageSpace.name)) } action: { frame in
            frames.well = frame
        }
        .animation(.smooth(duration: 0.18), value: isTargeted)
    }

    // MARK: - Gesture

    private var dragGesture: some Gesture {
        // `minimumDistance: 0` so the press is captured immediately — the
        // gesture then owns the pointer until release — but nothing lifts
        // until the threshold below is crossed, so a click never moves a
        // block.
        DragGesture(minimumDistance: 0, coordinateSpace: .named(MenuBarStageSpace.name))
            .onChanged { value in
                if drag == nil {
                    guard !isDragCancelled else { return }
                    let anchor = frames.token(at: value.startLocation)
                    drag = StageDrag(
                        anchor: anchor,
                        run: anchor.map { composition.groupedRun(of: $0) } ?? [],
                        start: value.startLocation,
                        location: value.location
                    )
                }
                advance(to: value.location)
            }
            .onEnded { _ in
                isDragCancelled = false
                guard let current = drag else { return }
                drag = nil
                if current.engaged {
                    finish(current)
                } else {
                    click(current.anchor)
                }
            }
    }

    private func advance(to location: CGPoint) {
        guard var current = drag else { return }
        current.location = location
        if !current.engaged {
            let fromStart = hypot(location.x - current.start.x, location.y - current.start.y)
            guard let anchor = current.anchor, fromStart >= Self.dragThreshold else {
                drag = current
                return
            }
            _ = anchor
            current.engaged = true
            let box = current.run
                .compactMap { frames.tokens[$0] }
                .reduce(CGRect.null) { $0.union($1) }
            if !box.isNull {
                current.grabOffset = CGSize(width: current.start.x - box.minX, height: current.start.y - box.minY)
            }
            isFocused = true
            // Snapshot the committed order; every crossing rearranges this
            // copy, and only the drop writes.
            dragComposition = composition
            NSCursor.closedHand.set()
        }
        guard let anchor = current.anchor else {
            drag = current
            return
        }
        let target: MenuBarStageTarget?
        if frames.well.contains(location) {
            target = .removed
        } else {
            target = frames.target(
                at: location,
                in: dragComposition ?? composition,
                moving: Set(current.run),
                reach: Self.reach
            ) ?? current.target
        }
        if let target, target != current.target {
            current.target = target
            // From the committed order every time, so a drag that crosses
            // the strip twice ends where the pointer is, not where the
            // crossings accumulated to.
            var next = composition
            switch target {
            case let .before(id):
                next.move(anchor, before: id)
            case let .endOf(address):
                next.move(anchor, toEndOf: address)
            case .removed:
                for id in current.run { next.remove(id) }
            }
            if next != dragComposition {
                withAnimation(Self.reflow) { dragComposition = next }
            }
        }
        drag = current
    }

    private func finish(_ current: StageDrag) {
        NSCursor.arrow.set()
        if current.target == .removed {
            selection.subtract(current.run)
        }
        let reordered = dragComposition
        withAnimation(Self.reflow) { dragComposition = nil }
        if let reordered, reordered != composition {
            let segments = reordered.segments
            mutate { $0.segments = segments }
        }
    }

    private func cancel() {
        guard let current = drag, current.engaged else { return }
        isDragCancelled = true
        drag = nil
        withAnimation(Self.reflow) { dragComposition = nil }
        NSCursor.arrow.set()
    }

    /// A press that never became a drag. Shift or command extends the
    /// selection — that is how a run to group is picked — and a press on the
    /// ground clears it.
    private func click(_ anchor: UUID?) {
        isFocused = true
        guard let anchor else {
            selection = []
            return
        }
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) || flags.contains(.command) {
            if selection.contains(anchor) {
                selection.remove(anchor)
            } else {
                selection.insert(anchor)
            }
        } else {
            selection = [anchor]
        }
    }

    private func handleKey(_ press: KeyPress, composition: MenuBarComposition) -> KeyPress.Result {
        switch press.key {
        case .escape:
            if drag?.engaged == true {
                cancel()
            } else if !selection.isEmpty {
                selection = []
            } else {
                return .ignored
            }
            return .handled
        case .delete, .deleteForward:
            guard !selection.isEmpty else { return .ignored }
            remove(Array(selection))
            return .handled
        default:
            break
        }
        guard press.modifiers.contains(.command) else { return .ignored }
        switch press.characters.lowercased() {
        case "g":
            if press.modifiers.contains(.shift) {
                ungroupSelection(composition)
            } else {
                groupSelection(composition)
            }
            return .handled
        case "d":
            guard selection.count == 1 else { return .ignored }
            duplicateSelected()
            return .handled
        default:
            return .ignored
        }
    }

    // MARK: - Edits

    /// The one settings write an edit performs. An edit that changes nothing
    /// must not publish: every write fans out to every subscriber and
    /// re-renders the menu bar.
    private func mutate(_ change: (inout MenuBarComposition) -> Void) {
        var updated = item
        let before = updated.composition
        var composed = before ?? MenuBarComposition(isEnabled: true)
        change(&composed)
        guard composed != before else { return }
        updated.composition = composed
        settingsStore.settings.setMenuBarItem(updated)
    }

    func groupSelection(_ composition: MenuBarComposition) {
        let ids = Array(selection)
        guard composition.canGroup(ids) else { return }
        mutate { $0.group(ids) }
    }

    func ungroupSelection(_ composition: MenuBarComposition) {
        let grouped = selection.filter { composition.isGrouped($0) }
        guard !grouped.isEmpty else { return }
        mutate { composed in
            var done: Set<UUID> = []
            for id in grouped where !done.contains(id) {
                done.formUnion(composed.groupedRun(of: id))
                composed.ungroup(id)
            }
        }
    }

    private func duplicateSelected() {
        guard selection.count == 1, let id = selection.first else { return }
        var copy: UUID?
        mutate { copy = $0.duplicate(id) }
        if let copy { selection = [copy] }
    }

    private func remove(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        selection.subtract(ids)
        mutate { composed in
            for id in ids { composed.remove(id) }
        }
    }

    // MARK: - Menus

    @ViewBuilder
    private func tokenMenu(_ token: MenuBarToken, in composition: MenuBarComposition) -> some View {
        let ids = selection.contains(token.id) ? Array(selection) : [token.id]
        Button(L10n.MenuBar.Composer.Group.bind) {
            selection = Set(ids)
            groupSelection(composition)
        }
        .disabled(!composition.canGroup(ids))
        if composition.isGrouped(token.id) {
            Button(L10n.MenuBar.Composer.Group.unbind) { mutate { $0.ungroup(token.id) } }
        }
        Divider()
        if composition.canSplitSegment(before: token.id) {
            Button(L10n.MenuBar.Composer.Segment.splitHere) { mutate { $0.splitSegment(before: token.id) } }
        }
        Button(L10n.MenuBar.Composer.Action.duplicate) {
            var copy: UUID?
            mutate { copy = $0.duplicate(token.id) }
            if let copy { selection = [copy] }
        }
        Divider()
        Button(L10n.Common.remove, role: .destructive) { remove(ids) }
    }

    /// One segment's own actions: move it, merge it, open or close its
    /// second row, remove it. Saving it as a preset stays in the inspector,
    /// which has the name field.
    private func segmentMenu(_ segment: MenuBarSegment, index: Int, of composition: MenuBarComposition) -> some View {
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
            Button(L10n.MenuBar.Composer.Segment.remove, role: .destructive) {
                selection.subtract(segment.tokens.map(\.id))
                mutate { $0.removeSegment(segment.id) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 14)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
