import AppKit
import SwiftUI
import VibeBarCore

/// The immersive half of the layout editors: the surface at full size, on a
/// stage — and the stage is the editor.
///
/// In Settings the controls own the room and the preview is a skeleton. Here
/// it inverts, and then goes one step further: the real popover page or mini
/// window sits lit in the middle, and arranging it means dragging its cards
/// and cells where they are. A card lifts under the pointer, the others slide
/// to make room, the drop writes; the well below hides or removes; the tray
/// below holds what is switched off, to be clicked or dragged back. The
/// chrome is a few glass pills that float over the stage rather than a panel
/// beside it, and the full editors are one keystroke away in an inspector for
/// everything a drag cannot say — presets, names, styles' finer settings.
///
/// The surface stays inert. Nothing inside it is clickable; every gesture
/// lands on an overlay that reads the frames the surface reports
/// (`SurfaceItemFrames`) and hands back a provisional arrangement through the
/// environment. That is what keeps a chart's hover from swallowing a drag,
/// and what keeps the surface's own code ignorant of the studio.
struct LayoutStudioView: View {
    @ObservedObject var model: LayoutStudioModel

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var layoutModel: PageLayoutModel
    /// Observed for the same reason the editors observe them: the module set
    /// of a page and the field roster of a window follow these.
    @EnvironmentObject private var quotaService: QuotaService
    @EnvironmentObject private var costService: CostUsageService
    @Environment(\.colorScheme) private var scheme

    /// The stage — the scroll view the surface sits in — in studio space.
    @State private var stageFrame: CGRect = .zero
    /// The scaled surface, in studio space. Scroll moves it; zoom resizes it.
    @State private var surfaceFrame: CGRect = .zero
    /// The surface before scaling — what `fit` divides the stage by.
    @State private var naturalSize: CGSize = .zero
    /// Studio space's origin in the hosting view, for the drag image snapshot.
    @State private var rootGlobalOrigin: CGPoint = .zero
    @State private var wellFrame: CGRect = .zero
    @State private var scrollOffset: CGPoint = .zero
    @State private var scrollPosition = ScrollPosition()
    @State private var hovered: String?
    @State private var drag: StudioDrag?
    @State private var settling: StudioSettling?
    /// A cancelled drag's gesture is still down; nothing restarts it.
    @State private var isDragCancelled = false
    /// An undo writes the saved state too; that write is not a new step.
    @State private var isUndoing = false
    @State private var isHintShown = false
    @State private var hintGeneration = 0
    /// The merged field catalog, rebuilt when the registry changes rather
    /// than per render — the same reason Settings caches it.
    @State private var fieldOptions: [MenuBarFieldOption] = []
    @Namespace private var pills

    /// Every frame the studio reasons in: the root of this view.
    static let space = "vibebar.studio"
    private static let stagePadding: CGFloat = 44
    private static let dragThreshold: CGFloat = 4
    private static let zoomSteps: [CGFloat] = [0.5, 0.67, 0.8, 1, 1.25, 1.5, 2]
    private static let inspectorWidth: CGFloat = 520
    private static let reflow = Animation.snappy(duration: 0.3, extraBounce: 0.04)

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            HStack(spacing: 0) {
                stage
                if model.isInspectorShown {
                    inspector
                        .frame(width: Self.inspectorWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            dragLayer
        }
        .coordinateSpace(.named(Self.space))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            rootGlobalOrigin = $0.origin
        }
        .animation(.smooth(duration: 0.28), value: model.isInspectorShown)
        .onAppear {
            installKeys()
            rebuildFieldOptions()
            showHint()
        }
        .onDisappear { model.keyHandler = nil }
        .onChange(of: model.subject) { _, _ in
            model.frames.removeAll()
            hovered = nil
            drag = nil
            settling = nil
            showHint()
        }
        // Every write to the subject's saved state — a drop on the stage, a
        // pill, a control in the inspector — is one undo step, in the order
        // it happened. Watching the state rather than the gesture is what
        // keeps an inspector edit from being swallowed by the undo of the
        // stage edit before it.
        .onChange(of: savedState) { old, new in
            guard !isUndoing, old.subject == new.subject, old.state != new.state else { return }
            model.undoStack.append(old.state)
            if model.undoStack.count > 40 { model.undoStack.removeFirst() }
        }
        .onChange(of: quotaService.fieldRegistry) { _, _ in rebuildFieldOptions() }
        .vibeBarControlFocus()
    }

    // MARK: - Ground

    /// A spotlight rather than a flat fill: the stage reads as lit where the
    /// surface is and recedes toward the edges, with the window's material
    /// showing through — which is what keeps the eye on the thing being
    /// arranged.
    private var backdrop: some View {
        RadialGradient(
            colors: scheme == .dark
                ? [Color.black.opacity(0.08), Color.black.opacity(0.40)]
                : [Color.white.opacity(0.62), Color.white.opacity(0.14)],
            center: UnitPoint(x: 0.5, y: 0.38),
            startRadius: 60,
            endRadius: 980
        )
        .ignoresSafeArea()
    }

    // MARK: - Stage

    private var stage: some View {
        ScrollView([.vertical, .horizontal]) {
            surface
                .padding(Self.stagePadding)
                // At least the stage's own size, so a surface smaller than
                // the stage sits in the middle of it rather than in a corner.
                .frame(minWidth: stageFrame.width, minHeight: stageFrame.height)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: CGPoint.self) { $0.contentOffset } action: { _, offset in
            scrollOffset = offset
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
            stageFrame = $0
        }
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .bottom) { bottomBar }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var surface: some View {
        switch model.subject {
        case let .popoverPage(page):
            if let tab = OverviewPage.allCases.first(where: { $0.layoutPageID == page }) {
                surfaceShell(cornerRadius: 14, flat: false) {
                    PopoverRoot(
                        // The width the popover actually opens at, so the
                        // preview reflows exactly like the thing it previews.
                        width: Self.popoverWidth(for: settingsStore.settings),
                        onContentHeightChange: { _ in },
                        onToggleMiniWindow: {},
                        initialPage: tab
                    )
                }
                // `PopoverRoot` applies `initialPage` to state it owns, once,
                // so the page only follows the subject with a new identity.
                .id(tab)
            } else {
                Text(L10n.Settings.Layout.previewUnavailable)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        case let .miniWindow(id):
            let config = settingsStore.settings.miniWindow.config(id: id)
            let size = config.map {
                MiniQuotaWindowController.stableContentSize(config: $0, environment: environment)
            }
            surfaceShell(cornerRadius: Theme.miniCornerRadius, flat: true) {
                MiniQuotaWindowView(configID: id, onClose: {}, onToggleDisplayMode: {})
                    // The panel's own size, close-button reserve and all, so
                    // the window on the stage is spaced like the one on screen.
                    .frame(width: size?.width, height: size?.height)
            }
            .id(id)
        }
    }

    /// The surface, lifted off the ground and wired to the studio.
    ///
    /// A shadow and a hairline, not a frame: the point is that the thing on
    /// the stage is the real surface, so it keeps its own corners and gets
    /// only the light around it. The mini window is its own glass panel and
    /// gets the light alone.
    private func surfaceShell<Content: View>(
        cornerRadius: CGFloat,
        flat: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let scale = self.scale
        let shape = RoundedRectangle(cornerRadius: cornerRadius * scale, style: .continuous)
        return ScaledPreview(scale: scale, onNaturalSize: { naturalSize = $0 }) {
            content()
        }
        .background {
            if !flat { shape.fill(.background.secondary) }
        }
        .clipShape(shape)
        .overlay {
            if !flat { shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5) }
        }
        .overlay { interactionLayer(cornerRadius: cornerRadius * scale) }
        .shadow(
            color: .black.opacity(scheme == .dark ? 0.5 : 0.16),
            radius: 22 * max(0.6, scale),
            y: 10 * max(0.6, scale)
        )
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
            surfaceFrame = $0
        }
        .environment(\.surfaceItemFrames, model.frames)
        // Dimmed only once the drag has lifted: a press that never moves is
        // a click, and a click must not make a card flicker.
        .environment(\.liftedSurfaceItem, (drag?.engaged == true ? drag?.item : nil) ?? settling?.item)
        .environment(\.studioPageOverride, pageOverride)
        .environment(\.studioMiniOrderOverride, miniOverride)
        .animation(.smooth(duration: 0.22), value: scale)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.985, anchor: .top)),
            removal: .opacity
        ))
    }

    /// Everything the pointer does to the surface lands here, on top of it.
    private func interactionLayer(cornerRadius: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
            if drag == nil, settling == nil, let hovered, let frame = model.frames.frame(of: hovered) {
                hoverOutline(frame.scaled(by: scale), cornerRadius: cornerRadius)
                    .transition(.opacity)
            }
            if let drag, drag.engaged, case .popoverPage = model.subject {
                segmentGuides(drag)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
            switch phase {
            case let .active(point):
                guard drag == nil, settling == nil else { return }
                let item = model.frames.item(at: surfacePoint(point))
                if item != hovered {
                    hovered = item
                    (item == nil ? NSCursor.arrow : NSCursor.openHand).set()
                }
            case .ended:
                if hovered != nil { hovered = nil }
                if drag == nil { NSCursor.arrow.set() }
            }
        }
        .gesture(surfaceDrag)
    }

    /// The card under the pointer, marked as something that can be picked
    /// up: a hairline in the accent and the faintest wash, nothing that
    /// competes with the card's own content.
    private func hoverOutline(_ frame: CGRect, cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return shape
            .fill(Color.accentColor.opacity(0.06))
            .overlay(shape.strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 1.5))
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .allowsHitTesting(false)
    }

    /// While a card is in flight on a page with more than one segment, the
    /// boundaries it can cross are drawn — a dashed hairline across each
    /// column where the segment changes — so a drop lands in a group the
    /// user can see.
    @ViewBuilder
    private func segmentGuides(_ drag: StudioDrag) -> some View {
        let segments = drag.provisionalSegments ?? drag.baseSegments
        let columns = drag.provisionalColumns ?? drag.baseColumns
        if segments.count > 1 {
            let rank = PageLayoutSegments.ordering(segments)
            let ranges = columnRanges(ratio: drag.ratio)
            ForEach(Array(columns.enumerated()), id: \.offset) { column, members in
                let range = ranges.indices.contains(column) ? ranges[column] : 0...0
                ForEach(Array(zip(members, members.dropFirst()).enumerated()), id: \.offset) { _, pair in
                    if rank[pair.0] != rank[pair.1],
                       let above = model.frames.frame(of: pair.0.rawValue),
                       let below = model.frames.frame(of: pair.1.rawValue) {
                        let y = (above.maxY + below.minY) / 2 * scale
                        Path { path in
                            path.move(to: CGPoint(x: range.lowerBound * scale, y: y))
                            path.addLine(to: CGPoint(x: range.upperBound * scale, y: y))
                        }
                        .stroke(
                            Color.accentColor.opacity(0.55),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                        )
                        .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    // MARK: - Scale

    private var scale: CGFloat {
        switch model.zoom {
        case .fit:
            guard naturalSize.width > 0, stageFrame.width > 0 else { return 1 }
            let room = stageFrame.width - Self.stagePadding * 2
            return min(1, max(0.35, room / naturalSize.width))
        case let .scale(value):
            return value
        }
    }

    private func zoom(by step: Int) {
        let current = scale
        let next: CGFloat?
        if step > 0 {
            next = Self.zoomSteps.first { $0 > current + 0.001 }
        } else {
            next = Self.zoomSteps.last { $0 < current - 0.001 }
        }
        guard let next else { return }
        withAnimation(.smooth(duration: 0.22)) { model.zoom = .scale(next) }
    }

    private func zoomToFit() {
        withAnimation(.smooth(duration: 0.22)) { model.zoom = .fit }
    }

    /// A studio-space point in the surface's own, unscaled coordinates — the
    /// space the surface reports its frames in.
    private func surfacePoint(_ point: CGPoint) -> CGPoint {
        let scale = self.scale
        return CGPoint(
            x: (point.x - surfaceFrame.minX) / scale,
            y: (point.y - surfaceFrame.minY) / scale
        )
    }

    /// Where an item is on screen, in studio space.
    private func studioRect(of item: String) -> CGRect? {
        guard let frame = model.frames.frame(of: item) else { return nil }
        return frame.scaled(by: scale).offsetBy(dx: surfaceFrame.minX, dy: surfaceFrame.minY)
    }

    // MARK: - Subjects

    private var subjects: [LayoutStudioWindowController.Subject] {
        let pages = OverviewPage.allCases
            .compactMap(\.layoutPageID)
            .map(LayoutStudioWindowController.Subject.popoverPage)
        let windows = settingsStore.settings.miniWindow.windows
            .map { LayoutStudioWindowController.Subject.miniWindow($0.id) }
        return pages + windows
    }

    private func stepSubject(by offset: Int) {
        let all = subjects
        guard let index = all.firstIndex(of: model.subject) else { return }
        let target = index + offset
        guard all.indices.contains(target) else { return }
        withAnimation(.smooth(duration: 0.28)) { model.subject = all[target] }
    }

    private func title(for subject: LayoutStudioWindowController.Subject) -> String {
        switch subject {
        case let .popoverPage(page):
            return OverviewPage.allCases.first { $0.layoutPageID == page }?.label
                ?? L10n.Popover.Tab.overview
        case let .miniWindow(id):
            return settingsStore.settings.miniWindow.config(id: id)?.name ?? L10n.Popover.Header.mini
        }
    }

    private func icon(for subject: LayoutStudioWindowController.Subject) -> String {
        switch subject {
        case .popoverPage: return "rectangle.portrait.on.rectangle.portrait"
        case .miniWindow:  return "macwindow"
        }
    }

    private var density: Theme.Density {
        Theme.overviewDensity(for: settingsStore.settings.popoverDensity)
    }

    /// Same rule `StatusItemController` uses: one stable width for every tab,
    /// so a page switch never reflows.
    private static func popoverWidth(for settings: AppSettings) -> CGFloat {
        max(
            Theme.overviewDensity(for: settings.popoverDensity).popoverWidth,
            Theme.detailDensity(for: settings.popoverDensity).popoverWidth
        )
    }

    // MARK: - Page context

    private struct PageContext {
        let page: PageLayoutPageID
        let descriptors: [PageModuleDescriptor]
        let displayed: PageLayoutArrangement

        func descriptor(_ id: PageLayoutModuleID) -> PageModuleDescriptor? {
            descriptors.first { $0.id == id }
        }
    }

    /// Exactly what the popover draws for this page right now — the same
    /// call the popover makes.
    private func pageContext(_ page: PageLayoutPageID) -> PageContext {
        let descriptors = PageModuleCatalog.descriptors(
            for: page,
            environment: environment,
            settings: settingsStore.settings
        )
        let displayed = layoutModel.arrangement(
            for: page,
            descriptors: descriptors,
            spacing: Double(density.interSectionSpacing)
        )
        return PageContext(page: page, descriptors: descriptors, displayed: displayed)
    }

    private func availableModuleIDs(_ context: PageContext) -> [PageLayoutModuleID] {
        layoutModel.visibleModuleIDs(for: context.page, descriptors: context.descriptors)
    }

    /// The horizontal extent of each column, in surface coordinates: the
    /// popover's inset plus the widths the arrangement's ratio gives.
    private func columnRanges(ratio: PageColumnRatio) -> [ClosedRange<CGFloat>] {
        let density = self.density
        let widths = PageColumnWidths(density: density, ratio: ratio)
        let left = density.popoverPaddingH
        let right = left + widths.left + density.interSectionSpacing
        return [left...(left + widths.left), right...(right + widths.right)]
    }

    private func pageFrames() -> [PageLayoutModuleID: CGRect] {
        Dictionary(
            model.frames.frames.map { (PageLayoutModuleID(rawValue: $0.key), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private var pageOverride: StudioPageOverride? {
        guard case let .popoverPage(page) = model.subject else { return nil }
        var arrangement: PageLayoutArrangement?
        if let drag, let columns = drag.provisionalColumns {
            arrangement = PageLayoutArrangement(
                PageLayoutConfig(
                    ratio: drag.ratio,
                    columns: columns,
                    measuredHeights: layoutModel.measuredHeights(for: page)
                )
            )
        }
        return StudioPageOverride(page: page, arrangement: arrangement)
    }

    private var miniOverride: StudioMiniOrderOverride? {
        guard case let .miniWindow(id) = model.subject,
              let drag, let order = drag.provisionalOrder
        else { return nil }
        return StudioMiniOrderOverride(windowID: id, fieldIds: order)
    }

    // MARK: - Mini context

    private func miniConfig(_ id: UUID) -> MiniWindowConfig? {
        settingsStore.settings.miniWindow.config(id: id)
    }

    private func updateMini(_ id: UUID, _ mutate: (inout MiniWindowConfig) -> Void) {
        var settings = settingsStore.settings
        guard var config = settings.miniWindow.config(id: id) else { return }
        mutate(&config)
        settings.miniWindow.upsert(config)
        settingsStore.settings = settings
    }

    private func rebuildFieldOptions() {
        fieldOptions = MenuBarFieldCatalog.mergedFields(registry: quotaService.fieldRegistry)
    }

    private func fieldOption(_ id: String) -> MenuBarFieldOption? {
        fieldOptions.first { $0.id == id }
    }

    /// Fields the window could show and does not: every catalog field with a
    /// live bucket that is not in the window's order.
    private func notShownFields(_ config: MiniWindowConfig) -> [MenuBarFieldOption] {
        let selected = Set(config.fieldIds)
        var quotas: [ToolType: AccountQuota?] = [:]
        return fieldOptions.filter { option in
            guard !selected.contains(option.id) else { return false }
            if quotas[option.tool] == nil {
                quotas[option.tool] = .some(environment.quota(for: option.tool))
            }
            return quotas[option.tool]??.bucket(id: option.bucketId) != nil
        }
    }

    // MARK: - Drag

    private struct StudioDrag {
        enum Origin { case surface, tray }

        let item: String
        let origin: Origin
        let label: String
        let accent: Color
        let cornerRadius: CGFloat
        /// Where the press began, in studio space — the threshold is measured
        /// from here, not from the last event.
        let start: CGPoint
        var location: CGPoint
        var engaged = false
        var image: NSImage?
        /// The picture's frame relative to the pointer: where the pointer
        /// grabbed it, so it does not jump to centre itself on the cursor.
        var grabOffset: CGSize = .zero
        var imageSize: CGSize = .zero
        var isOverWell = false

        // Pages
        var baseColumns: [[PageLayoutModuleID]] = []
        var baseSegments: [[PageLayoutModuleID]] = []
        var ratio: PageColumnRatio = .equal
        var provisionalColumns: [[PageLayoutModuleID]]?
        var provisionalSegments: [[PageLayoutModuleID]]?
        var slot: StudioArranging.ColumnSlot?

        // Mini windows
        var baseOrder: [String] = []
        var axis: StudioArranging.Axis = .horizontal
        var provisionalOrder: [String]?
        var linearSlot: Int?
    }

    /// The picture of a dropped item on its way into its slot.
    private struct StudioSettling {
        let item: String
        let image: NSImage?
        let label: String
        let accent: Color
        let cornerRadius: CGFloat
        var frame: CGRect
        var opacity: Double = 1
    }

    private var surfaceDrag: some Gesture {
        // `minimumDistance: 0` so the press is captured immediately — the
        // gesture then owns the pointer until release — but nothing lifts
        // until the threshold below is crossed, so a click never moves a card.
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if drag == nil {
                    guard !isDragCancelled, settling == nil,
                          let item = model.frames.item(at: surfacePoint(value.startLocation)),
                          let started = makeDrag(item: item, origin: .surface, at: value.startLocation)
                    else { return }
                    drag = started
                }
                guard drag?.origin == .surface else { return }
                advanceDrag(to: value.location)
            }
            .onEnded { value in
                isDragCancelled = false
                guard let current = drag, current.origin == .surface else { return }
                if current.engaged {
                    finishDrag(at: value.location)
                } else {
                    drag = nil
                }
            }
    }

    private func trayDrag(_ item: TrayItem) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if drag == nil {
                    guard !isDragCancelled, settling == nil,
                          var started = makeDrag(item: item.id, origin: .tray, at: value.startLocation)
                    else { return }
                    started.engaged = true
                    started.imageSize = CGSize(width: 1, height: 1)
                    NSCursor.closedHand.set()
                    drag = started
                }
                guard drag?.origin == .tray, drag?.item == item.id else { return }
                advanceDrag(to: value.location)
            }
            .onEnded { value in
                isDragCancelled = false
                guard let current = drag, current.origin == .tray, current.item == item.id else { return }
                finishDrag(at: value.location)
            }
    }

    private func makeDrag(item: String, origin: StudioDrag.Origin, at start: CGPoint) -> StudioDrag? {
        switch model.subject {
        case let .popoverPage(page):
            let context = pageContext(page)
            let moduleID = PageLayoutModuleID(rawValue: item)
            guard let descriptor = context.descriptor(moduleID) else { return nil }
            var started = StudioDrag(
                item: item,
                origin: origin,
                label: descriptor.displayName,
                accent: descriptor.accent.color,
                cornerRadius: density.cardCornerRadius,
                start: start,
                location: start
            )
            started.baseColumns = context.displayed.flattened.columns
            started.baseSegments = context.displayed.moduleSegments
            started.ratio = context.displayed.ratio
            return started
        case let .miniWindow(id):
            guard let config = miniConfig(id), config.displayMode.supportsStageArranging else { return nil }
            let option = fieldOption(item)
            var started = StudioDrag(
                item: item,
                origin: origin,
                label: option?.displayTitle ?? item,
                accent: option.map { Theme.providerAccent(for: $0.tool) } ?? .accentColor,
                cornerRadius: 10,
                start: start,
                location: start
            )
            started.baseOrder = config.fieldIds
            started.axis = config.displayMode.stageAxis
            return started
        }
    }

    private func advanceDrag(to location: CGPoint) {
        guard var current = drag else { return }
        model.pointer.location = location
        current.location = location

        if !current.engaged {
            let fromStart = hypot(location.x - current.start.x, location.y - current.start.y)
            guard fromStart >= Self.dragThreshold else {
                drag = current
                return
            }
            current.engaged = true
            if let rect = studioRect(of: current.item) {
                current.image = LayoutStudioWindowController.shared.snapshot(
                    of: rect.offsetBy(dx: rootGlobalOrigin.x, dy: rootGlobalOrigin.y)
                )
                current.imageSize = rect.size
                current.grabOffset = CGSize(width: location.x - rect.minX, height: location.y - rect.minY)
            }
            hovered = nil
            NSCursor.closedHand.set()
        }

        let overWell = current.origin == .surface && wellFrame.contains(location)
        let overSurface = surfaceFrame.insetBy(dx: -28, dy: -28).contains(location)
        let point = surfacePoint(location)
        let removed = overWell || (current.origin == .tray && !overSurface)

        switch model.subject {
        case .popoverPage:
            let moduleID = PageLayoutModuleID(rawValue: current.item)
            var columns: [[PageLayoutModuleID]]?
            var segments: [[PageLayoutModuleID]]?
            var slot: StudioArranging.ColumnSlot?
            if removed {
                columns = StudioArranging.columnsRemoving(moduleID, from: current.baseColumns)
                segments = current.baseSegments
            } else {
                let next = StudioArranging.columnSlot(
                    at: point,
                    columnRanges: columnRanges(ratio: current.ratio),
                    columns: current.baseColumns,
                    frames: pageFrames(),
                    dragging: moduleID
                )
                slot = next
                if next != current.slot || current.provisionalColumns == nil {
                    let moved = StudioArranging.columnsMoving(moduleID, to: next, in: current.baseColumns)
                    columns = moved
                    segments = StudioArranging.segmentsAfterMove(
                        moduleID, columns: moved, segments: current.baseSegments
                    )
                }
            }
            current.slot = slot
            current.isOverWell = overWell
            if let columns, columns != current.provisionalColumns {
                current.provisionalColumns = columns
                current.provisionalSegments = segments
                withAnimation(Self.reflow) { drag = current }
            } else {
                drag = current
            }
        case .miniWindow:
            var order: [String]?
            var slot: Int?
            if removed {
                order = current.baseOrder.filter { $0 != current.item }
            } else {
                let next = StudioArranging.linearSlot(
                    at: point,
                    order: current.baseOrder,
                    frames: model.frames.frames,
                    dragging: current.item,
                    axis: current.axis
                )
                slot = next
                if next != current.linearSlot || current.provisionalOrder == nil {
                    order = StudioArranging.orderMoving(current.item, to: next, in: current.baseOrder)
                }
            }
            current.linearSlot = slot
            current.isOverWell = overWell
            if let order, order != current.provisionalOrder {
                current.provisionalOrder = order
                withAnimation(Self.reflow) { drag = current }
            } else {
                drag = current
            }
        }

        autoscroll(for: location)
    }

    /// Drag near the stage's top or bottom edge and the stage scrolls, so a
    /// card can travel further than the window is tall.
    private func autoscroll(for location: CGPoint) {
        let edge: CGFloat = 44
        let bottomReserve: CGFloat = 72
        var delta: CGFloat = 0
        if location.y < stageFrame.minY + edge {
            delta = -14
        } else if location.y > stageFrame.maxY - edge - bottomReserve {
            delta = 14
        }
        guard delta != 0 else { return }
        scrollPosition.scrollTo(y: max(0, scrollOffset.y + delta))
    }

    private func finishDrag(at location: CGPoint) {
        guard let current = drag else { return }
        defer { NSCursor.arrow.set() }

        if current.isOverWell, current.origin == .surface {
            commitRemoval(current)
            withAnimation(Self.reflow) { drag = nil }
            return
        }

        switch model.subject {
        case let .popoverPage(page):
            let placed = current.provisionalColumns.map { $0.contains { $0.contains(PageLayoutModuleID(rawValue: current.item)) } } ?? false
            guard current.origin == .surface || placed else {
                withAnimation(Self.reflow) { drag = nil }
                return
            }
            let target = studioRect(of: current.item)
            if let columns = current.provisionalColumns,
               columns != current.baseColumns || current.origin == .tray {
                commitPage(current, page: page, columns: columns,
                           segments: current.provisionalSegments ?? current.baseSegments)
            }
            settle(current, to: target)
        case let .miniWindow(id):
            let placed = current.provisionalOrder?.contains(current.item) ?? false
            guard current.origin == .surface || placed else {
                withAnimation(Self.reflow) { drag = nil }
                return
            }
            let target = studioRect(of: current.item)
            if let order = current.provisionalOrder, order != current.baseOrder {
                commitMini(current, id: id, order: order)
            }
            settle(current, to: target)
        }
    }

    private func cancelDrag() {
        guard drag != nil else { return }
        isDragCancelled = true
        withAnimation(Self.reflow) { drag = nil }
        NSCursor.arrow.set()
    }

    /// The picture under the pointer glides into the slot the card now
    /// occupies, then the real card fades back in under it.
    private func settle(_ current: StudioDrag, to target: CGRect?) {
        let origin = CGPoint(
            x: current.location.x - current.grabOffset.width,
            y: current.location.y - current.grabOffset.height
        )
        var landing = StudioSettling(
            item: current.item,
            image: current.image,
            label: current.label,
            accent: current.accent,
            cornerRadius: current.cornerRadius,
            frame: CGRect(origin: origin, size: current.imageSize)
        )
        if current.image == nil {
            landing.frame = CGRect(origin: current.location, size: .zero)
        }
        settling = landing
        drag = nil
        withAnimation(.spring(duration: 0.32, bounce: 0.12)) {
            if let target, current.image != nil {
                settling?.frame = target
            } else if let target {
                settling?.frame = CGRect(origin: CGPoint(x: target.midX, y: target.midY), size: .zero)
                settling?.opacity = 0
            } else {
                settling?.opacity = 0
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(340))
            if settling?.item == current.item { settling = nil }
        }
    }

    // MARK: - Undo

    private struct SavedState: Equatable {
        let subject: LayoutStudioWindowController.Subject
        let state: StudioUndo
    }

    /// What the subject's saved state is right now — the value undo watches.
    private var savedState: SavedState {
        switch model.subject {
        case let .popoverPage(page):
            return SavedState(subject: model.subject, state: .page(page, layoutModel.storedLayout(for: page)))
        case let .miniWindow(id):
            return SavedState(
                subject: model.subject,
                state: .miniWindow(id, miniConfig(id))
            )
        }
    }

    // MARK: - Commits

    private func commitPage(
        _ current: StudioDrag,
        page: PageLayoutPageID,
        columns: [[PageLayoutModuleID]],
        segments: [[PageLayoutModuleID]]
    ) {
        let context = pageContext(page)
        let moduleID = PageLayoutModuleID(rawValue: current.item)
        var available = availableModuleIDs(context)
        if current.origin == .tray, !available.contains(moduleID) {
            available.append(moduleID)
        }
        let config = PageLayoutConfig(
            ratio: current.ratio,
            columns: columns,
            measuredHeights: layoutModel.measuredHeights(for: page)
        )
        layoutModel.applyStudioArrangement(
            config,
            segments: segments,
            for: page,
            available: available,
            unhiding: current.origin == .tray ? moduleID : nil
        )
    }

    private func commitMini(_ current: StudioDrag, id: UUID, order: [String]) {
        guard let config = miniConfig(id) else { return }
        updateMini(id) { $0.fieldIds = order }
    }

    private func commitRemoval(_ current: StudioDrag) {
        switch model.subject {
        case let .popoverPage(page):
            layoutModel.setHidden(true, for: PageLayoutModuleID(rawValue: current.item), page: page)
        case let .miniWindow(id):
            guard let config = miniConfig(id) else { return }
            updateMini(id) { $0.fieldIds.removeAll { $0 == current.item } }
        }
    }

    private func undo() {
        guard let entry = model.undoStack.popLast() else { return }
        if entry.subject != model.subject {
            model.subject = entry.subject
        }
        isUndoing = true
        defer { isUndoing = false }
        withAnimation(Self.reflow) {
            switch entry {
            case let .page(page, stored):
                layoutModel.restoreStoredLayout(stored, for: page)
            case let .miniWindow(id, config):
                var settings = settingsStore.settings
                if let config {
                    settings.miniWindow.upsert(config)
                } else {
                    settings.miniWindow.windows.removeAll { $0.id == id }
                }
                settingsStore.settings = settings
            }
        }
    }

    // MARK: - Tray

    /// The pills whose selection slides as one shape.
    private enum PillGroup: Hashable {
        case mode, ratio, style
    }

    private struct TrayItem: Identifiable {
        let id: String
        let label: String
        let accent: Color
    }

    private var trayItems: [TrayItem] {
        switch model.subject {
        case let .popoverPage(page):
            let context = pageContext(page)
            return layoutModel.hiddenModules(for: page).compactMap { id in
                context.descriptor(id).map {
                    TrayItem(id: id.rawValue, label: $0.displayName, accent: $0.accent.color)
                }
            }
        case let .miniWindow(id):
            guard let config = miniConfig(id) else { return [] }
            return notShownFields(config).map {
                TrayItem(id: $0.id, label: $0.displayTitle, accent: Theme.providerAccent(for: $0.tool))
            }
        }
    }

    private var trayCaption: String {
        switch model.subject {
        case .popoverPage: return L10n.Settings.Layout.studioTrayHidden
        case .miniWindow:  return L10n.Settings.Layout.studioTrayNotShown
        }
    }

    private func restore(_ item: TrayItem) {
        withAnimation(Self.reflow) {
            switch model.subject {
            case let .popoverPage(page):
                layoutModel.setHidden(false, for: PageLayoutModuleID(rawValue: item.id), page: page)
            case let .miniWindow(id):
                guard let config = miniConfig(id) else { return }
                updateMini(id) { config in
                    if !config.fieldIds.contains(item.id) { config.fieldIds.append(item.id) }
                }
            }
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 10) {
            subjectMenu
            Spacer(minLength: 8)
            centreControls
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if !model.undoStack.isEmpty {
                    glassIconButton(systemImage: "arrow.uturn.backward", help: L10n.Settings.Layout.studioUndo) {
                        undo()
                    }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
                zoomPill
                glassIconButton(
                    systemImage: model.isInspectorShown ? "sidebar.trailing" : "sidebar.leading",
                    help: L10n.Settings.Layout.studioToggleInspector
                ) {
                    withAnimation(.smooth(duration: 0.28)) { model.isInspectorShown.toggle() }
                }
            }
        }
        // Clear of the traffic lights, which the transparent titlebar leaves
        // in the top-left corner of the content.
        .padding(.leading, 84)
        .padding(.trailing, 16)
        .padding(.top, 12)
        .animation(.smooth(duration: 0.2), value: model.undoStack.isEmpty)
    }

    private var subjectMenu: some View {
        Menu {
            Section(L10n.Settings.Layout.studioSubjectPages) {
                ForEach(subjects.filter { if case .popoverPage = $0 { return true } else { return false } }, id: \.self) { subject in
                    Button {
                        withAnimation(.smooth(duration: 0.28)) { model.subject = subject }
                    } label: {
                        Label(title(for: subject), systemImage: icon(for: subject))
                    }
                }
            }
            Section(L10n.Settings.Section.miniWindows) {
                ForEach(subjects.filter { if case .miniWindow = $0 { return true } else { return false } }, id: \.self) { subject in
                    Button {
                        withAnimation(.smooth(duration: 0.28)) { model.subject = subject }
                    } label: {
                        Label(title(for: subject), systemImage: icon(for: subject))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon(for: model.subject))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title(for: model.subject))
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassEffect(.regular, in: .capsule)
    }

    @ViewBuilder
    private var centreControls: some View {
        switch model.subject {
        case let .popoverPage(page):
            let context = pageContext(page)
            let mode = layoutModel.mode(for: page)
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(PageLayoutMode.allCases, id: \.self) { candidate in
                        pillButton(
                            isSelected: candidate == mode,
                            systemImage: candidate.symbolName,
                            title: modeLabel(candidate),
                            group: .mode,
                            help: modeLabel(candidate)
                        ) {
                            guard candidate != mode else { return }
                            withAnimation(Self.reflow) {
                                layoutModel.setMode(
                                    candidate, for: page,
                                    displayed: context.displayed,
                                    available: availableModuleIDs(context)
                                )
                            }
                        }
                    }
                }
                .padding(3)
                .glassEffect(.regular, in: .capsule)
                HStack(spacing: 2) {
                    ForEach(PageColumnRatio.allCases, id: \.self) { candidate in
                        let isSelected = context.displayed.ratio == candidate && mode != .auto
                        pillButton(
                            isSelected: isSelected,
                            systemImage: nil,
                            title: nil,
                            group: .ratio,
                            help: ratioLabel(candidate)
                        ) {
                            withAnimation(Self.reflow) {
                                layoutModel.setRatio(
                                    candidate, for: page,
                                    resolved: context.displayed.flattened,
                                    available: availableModuleIDs(context)
                                )
                            }
                        } custom: {
                            ratioGlyph(candidate)
                        }
                    }
                }
                .padding(3)
                .glassEffect(.regular, in: .capsule)
            }
        case let .miniWindow(id):
            if let config = miniConfig(id) {
                HStack(spacing: 2) {
                    ForEach(MiniWindowDisplayMode.allCases) { candidate in
                        pillButton(
                            isSelected: candidate == config.displayMode,
                            systemImage: candidate.symbolName,
                            title: candidate == config.displayMode ? candidate.label : nil,
                            group: .style,
                            help: candidate.label
                        ) {
                            guard candidate != config.displayMode else { return }
                            withAnimation(Self.reflow) {
                                updateMini(id) { $0.displayMode = candidate }
                            }
                        }
                    }
                }
                .padding(3)
                .glassEffect(.regular, in: .capsule)
            }
        }
    }

    private var zoomPill: some View {
        HStack(spacing: 2) {
            Button { zoom(by: -1) } label: {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.vibeBar(cornerRadius: 11))
            .help(L10n.Settings.Layout.studioZoomOut)
            Button { zoomToFit() } label: {
                Text(L10n.Common.percent(value: Int((scale * 100).rounded())))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .frame(width: 44)
                    .frame(height: 22)
            }
            .buttonStyle(.vibeBar(cornerRadius: 11))
            .help(L10n.Settings.Layout.studioZoomFitHelp)
            Button { zoom(by: 1) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.vibeBar(cornerRadius: 11))
            .help(L10n.Settings.Layout.studioZoomIn)
        }
        .foregroundStyle(.primary)
        .padding(3)
        .glassEffect(.regular, in: .capsule)
    }

    private func glassIconButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.vibeBar(cornerRadius: 15))
        .foregroundStyle(.primary)
        .glassEffect(.regular, in: .circle)
        .help(help)
    }

    /// One choice in a glass pill. The selection is a single shape that
    /// slides between choices rather than several that switch.
    private func pillButton<Custom: View>(
        isSelected: Bool,
        systemImage: String?,
        title: String?,
        group: PillGroup,
        help: String,
        action: @escaping () -> Void,
        @ViewBuilder custom: () -> Custom = { EmptyView() }
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                custom()
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10.5, weight: .semibold))
                }
                if let title {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .background {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.13))
                        .matchedGeometryEffect(id: group, in: pills)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.vibeBar(cornerRadius: 12))
        .help(help)
        .animation(.snappy(duration: 0.22), value: isSelected)
    }

    private func modeLabel(_ mode: PageLayoutMode) -> String {
        switch mode {
        case .auto:    return L10n.Common.auto
        case .compact: return L10n.MenuBar.Composer.Template.compact
        case .manual:  return L10n.Settings.Layout.studioModeManual
        }
    }

    private func ratioLabel(_ ratio: PageColumnRatio) -> String {
        switch ratio {
        case .narrowWide: return L10n.Settings.Layout.studioRatioNarrowWide
        case .equal:      return L10n.Settings.Layout.studioRatioEqual
        case .wideNarrow: return L10n.Settings.Layout.studioRatioWideNarrow
        }
    }

    private func ratioGlyph(_ ratio: PageColumnRatio) -> some View {
        let width: CGFloat = 18
        let gap: CGFloat = 2
        let left = (width - gap) * ratio.leftFraction
        return HStack(spacing: gap) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .frame(width: left, height: 10)
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .frame(width: max(0, width - gap - left), height: 10)
        }
        .frame(width: width, height: 10)
    }

    private var bottomBar: some View {
        let items = trayItems
        let hint = hintText
        return VStack(spacing: 8) {
            Group {
                if let drag, drag.engaged, drag.origin == .surface {
                    dropWell(drag)
                } else if !items.isEmpty {
                    tray(items)
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            if isHintShown, let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.bottom, 14)
        .padding(.horizontal, 16)
        .animation(.smooth(duration: 0.24), value: drag?.engaged == true && drag?.origin == .surface)
        .animation(.smooth(duration: 0.24), value: items.map(\.id))
        .animation(.smooth(duration: 0.3), value: isHintShown)
    }

    private func tray(_ items: [TrayItem]) -> some View {
        HStack(spacing: 8) {
            Text(trayCaption.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)
            ForEach(items) { item in
                chip(item)
                    .opacity(drag?.item == item.id ? 0.35 : 1)
                    .onTapGesture { restore(item) }
                    .gesture(trayDrag(item))
                    .help(trayHelp)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
    }

    private var trayHelp: String {
        switch model.subject {
        case .popoverPage: return L10n.Settings.Layout.studioTrayShowHelp
        case .miniWindow:  return L10n.Settings.Layout.studioTrayAddHelp
        }
    }

    private func chip(_ item: TrayItem) -> some View {
        StudioChip(label: item.label, accent: item.accent)
    }

    private func dropWell(_ drag: StudioDrag) -> some View {
        let isPage: Bool = { if case .popoverPage = model.subject { return true } else { return false } }()
        return HStack(spacing: 8) {
            Image(systemName: isPage ? "eye.slash" : "minus.circle")
                .font(.system(size: 12, weight: .semibold))
            Text(isPage ? L10n.Settings.Layout.studioWellHide : L10n.Common.remove)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(drag.isOverWell ? Color.white : Color.primary)
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .glassEffect(drag.isOverWell ? .regular.tint(.red) : .regular, in: .capsule)
        .scaleEffect(drag.isOverWell ? 1.06 : 1)
        .animation(.snappy(duration: 0.2), value: drag.isOverWell)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
            wellFrame = $0
        }
    }

    private var hintText: String? {
        switch model.subject {
        case .popoverPage:
            return L10n.Settings.Layout.studioHintPage
        case let .miniWindow(id):
            guard let config = miniConfig(id) else { return nil }
            return config.displayMode.supportsStageArranging
                ? L10n.Settings.Layout.studioHintMini
                : L10n.Settings.Layout.studioHintFixedStyle
        }
    }

    private func showHint() {
        hintGeneration += 1
        let generation = hintGeneration
        withAnimation { isHintShown = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            if hintGeneration == generation {
                withAnimation { isHintShown = false }
            }
        }
    }

    // MARK: - Drag image

    @ViewBuilder
    private var dragLayer: some View {
        if let drag, drag.engaged {
            DragImageLayer(pointer: model.pointer, drag: drag)
        }
        if let settling {
            settlingImage(settling)
        }
    }

    private struct DragImageLayer: View {
        @ObservedObject var pointer: StudioPointer
        let drag: StudioDrag

        var body: some View {
            let origin = CGPoint(
                x: pointer.location.x - drag.grabOffset.width,
                y: pointer.location.y - drag.grabOffset.height
            )
            Group {
                if let image = drag.image {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: drag.imageSize.width, height: drag.imageSize.height)
                        .clipShape(RoundedRectangle(cornerRadius: drag.cornerRadius, style: .continuous))
                        .shadow(color: .black.opacity(0.38), radius: 18, y: 10)
                        .scaleEffect(1.03)
                        .position(
                            x: origin.x + drag.imageSize.width / 2,
                            y: origin.y + drag.imageSize.height / 2
                        )
                } else {
                    StudioChip(label: drag.label, accent: drag.accent, prominent: true)
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                        .position(x: pointer.location.x, y: pointer.location.y)
                }
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func settlingImage(_ landing: StudioSettling) -> some View {
        Group {
            if let image = landing.image {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: landing.frame.width, height: landing.frame.height)
                    .clipShape(RoundedRectangle(cornerRadius: landing.cornerRadius, style: .continuous))
                    .shadow(color: .black.opacity(0.25 * landing.opacity), radius: 12, y: 6)
                    .position(x: landing.frame.midX, y: landing.frame.midY)
            } else {
                StudioChip(label: landing.label, accent: landing.accent, prominent: true)
                    .position(x: landing.frame.midX, y: landing.frame.midY)
            }
        }
        .opacity(landing.opacity)
        .allowsHitTesting(false)
    }

    // MARK: - Inspector

    /// The full editors, for everything a drag cannot say. The same views
    /// Settings shows: one place decides what a control does; this decides
    /// how much room it gets.
    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch model.subject {
                case let .popoverPage(page):
                    // Identity per subject: the editors keep their own
                    // selection in `@State`, so without a rebuild the controls
                    // would go on editing whatever the last one was while the
                    // stage showed something else.
                    LayoutEditorView(initialPage: page)
                        .id(page)
                case let .miniWindow(id):
                    MiniWindowsSettingsSection(initialWindowID: id)
                        .id(id)
                }
            }
            .padding(16)
            .padding(.top, 36)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.isInLayoutStudio, true)
        .background(.ultraThinMaterial)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5)
        }
    }

    // MARK: - Keys

    private func installKeys() {
        model.keyHandler = { key in
            switch key {
            case .escape:
                if drag != nil {
                    cancelDrag()
                } else {
                    LayoutStudioWindowController.shared.close()
                }
            case .close:
                LayoutStudioWindowController.shared.close()
            case .zoomIn:
                zoom(by: 1)
            case .zoomOut:
                zoom(by: -1)
            case .zoomFit:
                zoomToFit()
            case .undo:
                guard drag == nil else { return false }
                undo()
            case .nextSubject:
                guard drag == nil else { return false }
                stepSubject(by: 1)
            case .previousSubject:
                guard drag == nil else { return false }
                stepSubject(by: -1)
            case .toggleInspector:
                withAnimation(.smooth(duration: 0.28)) { model.isInspectorShown.toggle() }
            }
            return true
        }
    }
}

/// A tray entry, and the picture of one in flight: an accent dot and a name.
private struct StudioChip: View {
    let label: String
    let accent: Color
    var prominent = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(accent)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(prominent ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.primary.opacity(0.08)))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(prominent ? 0.18 : 0.06), lineWidth: 0.5)
        )
        .contentShape(Capsule())
    }
}

private extension CGRect {
    func scaled(by scale: CGFloat) -> CGRect {
        CGRect(x: minX * scale, y: minY * scale, width: width * scale, height: height * scale)
    }
}
