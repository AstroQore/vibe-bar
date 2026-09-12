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
    @State private var miniSelection: String?
    @State private var hovered: String?
    @State private var headerHeight: CGFloat = 0
    @State private var previewOnlyPage: OverviewPage?
    @State private var editingLabel: SurfaceItemFrames.Label?
    @State private var labelDraft = ""
    @FocusState private var isLabelFocused: Bool
    @State private var drag: StudioDrag?
    @State private var settling: StudioSettling?
    /// A cancelled drag's gesture is still down; nothing restarts it.
    @State private var isDragCancelled = false
    /// An undo writes the saved state too; that write is not a new step.
    @State private var isUndoing = false
    /// `onChange` runs after the action returns, so a transient Bool cannot
    /// identify an undo write. Consume the exact restored state once.
    @State private var undoWrite: StudioUndo?
    @State private var isHintShown = false
    /// The menu bar subject's selection — shared with the composer in the
    /// inspector, so the block picked on the stage is the block it edits.
    @State private var stripSelection: Set<UUID> = []
    @State private var canvasSelection: Set<UUID> = []
    /// The e-ink stage's selection, its last checks, and the snapshot its
    /// numbers come from. The snapshot is fetched on a task, never in `body`.
    @State private var einkSelection: Set<UUID> = []
    @State private var einkReport: EInkLayoutDiagnostics.Report?
    @State private var einkSnapshot: EInkDataSnapshot?
    @State private var einkSections: [EInkFieldSection] = []
    @State private var einkPush: Task<Void, Never>?
    @State private var isPushingEInk = false
    /// The orientation the Studio is editing, which is the device's until the
    /// toolbar's switcher moves it. A custom slide carries one layout per
    /// orientation, and editing the panel you are not holding is the normal
    /// case: you set the portrait one up while the device is still landscape.
    @State private var einkEditingOrientation: EInkOrientation?
    @State private var isConfirmingRelayout = false
    @State private var cardSelection: Set<String> = []
    /// The menu bar the strip is previewed on; the window's own until picked.
    @State private var stripScheme: ColorScheme?
    /// Whether the strip has a block in hand — what decides who answers
    /// Escape.
    @State private var stripIsDragging = false
    /// The block the inspector's palette has in flight, shared with the
    /// stage so it can be dropped there.
    @State private var stripPendingBlock: PendingPaletteBlock?
    @State private var hintGeneration = 0
    /// The merged field catalog, rebuilt when the registry changes rather
    /// than per render — the same reason Settings caches it.
    @State private var fieldOptions: [MenuBarFieldOption] = []
    @Namespace private var pills

    /// Non-empty only while an e-ink slide is on the stage; changing it
    /// re-reads the snapshot for the new device.
    private var einkSubjectKey: String {
        guard case let .einkSlide(deviceID, slideID) = model.subject else { return "" }
        // The buckets are part of the key: binding an element to a bucket the
        // snapshot was not assembled for would otherwise leave that element
        // blank on the stage for the rest of the session, while the device
        // drew it fine.
        let orientation = einkOrientation(deviceID)
        let buckets = (einkLayout(deviceID: deviceID, slideID: slideID)?.elements ?? [])
            .flatMap(\.quotaFieldIDs)
            .sorted()
            .joined(separator: ",")
        return [deviceID, slideID, String(orientation.rawValue), buckets].joined(separator: "|")
    }

    /// Every frame the studio reasons in: the root of this view.
    static let space = "vibebar.studio"
    private static let stagePadding: CGFloat = 44
    /// What the top and bottom bars float over: a fitted surface should sit
    /// between them, not under them.
    private static let fitBarReserve: CGFloat = 72
    private static let dragThreshold: CGFloat = 4
    private static let zoomSteps: [CGFloat] = [0.5, 0.67, 0.8, 1, 1.25, 1.5, 2]
    private static let inspectorWidth: CGFloat = 520
    private static let reflow = Animation.snappy(duration: 0.3, extraBounce: 0.04)

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            HStack(spacing: 0) {
                stage
                if model.isInspectorShown && previewOnlyPage == nil {
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
        .task(id: einkSubjectKey) {
            guard !einkSubjectKey.isEmpty else { return }
            await refreshEInkSnapshot()
        }
        .onDisappear { model.keyHandler = nil }
        .onChange(of: model.subject) { old, new in
            // Arriving at a panel from another subject brings the paper's own
            // zoom with it; leaving one puts 1:1 back.
            if case .einkSlide = new {
                if case .einkSlide = old {} else { model.zoom = .scale(EInkStudioStage.defaultZoom) }
            } else if case .einkSlide = old {
                model.zoom = .scale(1)
            }
            previewOnlyPage = nil
            editingLabel = nil
            headerHeight = 0
            hovered = nil
            miniSelection = nil
            drag = nil
            settling = nil
            canvasSelection = []
            cardSelection = []
            einkSelection = []
            einkReport = nil
            einkEditingOrientation = nil
            // A page is drawn whole now, so the stage may be scrolled deep
            // into one when the subject changes; the next surface starts
            // at its top, not partway down where the last one was left.
            scrollPosition.scrollTo(x: 0, y: 0)
            showHint()
        }
        // Every write to the subject's saved state — a drop on the stage, a
        // pill, a control in the inspector — is one undo step, in the order
        // it happened. Watching the state rather than the gesture is what
        // keeps an inspector edit from being swallowed by the undo of the
        // stage edit before it.
        .onChange(of: savedState) { old, new in
            if let restored = undoWrite {
                undoWrite = nil
                if new.state == restored { return }
            }
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
        if let page = previewOnlyPage {
            popoverSurface(page)
        } else {
        switch model.subject {
        case let .popoverPage(page):
            if let tab = OverviewPage.allCases.first(where: { $0.layoutPageID == page }) {
                popoverSurface(tab)
            } else {
                Text(L10n.Settings.Layout.previewUnavailable)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        case let .miniWindow(id):
            let config = settingsStore.settings.miniWindow.config(id: id)
            if config?.displayMode == .custom {
                ScaledPreview(scale: scale, onNaturalSize: { naturalSize = $0 }, isInteractive: true) {
                    MiniCanvasStage(configID: id, layout: canvasBinding(id), selection: $canvasSelection,
                                    defaultFieldID: fieldOptions.first?.id)
                }
                .id(id)
            } else {
                let size = config.map {
                    MiniQuotaWindowController.stableContentSize(config: $0, environment: environment)
                }
                surfaceShell(cornerRadius: Theme.miniCornerRadius, flat: true) {
                    MiniQuotaWindowView(configID: id, onClose: {}, onToggleDisplayMode: {})
                        // The panel's own size, close-button reserve and all.
                        .frame(width: size?.width, height: size?.height)
                }
                .id(id)
            }
        case let .einkSlide(deviceID, slideID):
            // Paper is its own shell: no card, no shadow, no corner radius —
            // see `EInkStudioStage`.
            ScaledPreview(scale: scale, onNaturalSize: { naturalSize = $0 }, isInteractive: true) {
                EInkStudioStage(
                    layout: einkLayoutBinding(deviceID: deviceID, slideID: slideID),
                    selection: $einkSelection,
                    slide: einkSlide(deviceID: deviceID, slideID: slideID)
                        ?? EInkSlide(id: slideID, kind: .custom(layoutID: slideID)),
                    orientation: einkOrientation(deviceID),
                    profile: einkProfile(deviceID),
                    snapshot: einkSnapshot,
                    scale: scale,
                    onReport: { einkReport = $0 }
                )
            }
            .overlay { einkStageNotice(deviceID: deviceID, slideID: slideID) }
            .id("\(slideID)/\(einkOrientation(deviceID).rawValue)")
        case let .menuBar(kind):
            // Not through `surfaceShell`: the strip is not a picture scaled
            // from outside but a live surface that draws itself at the
            // stage's zoom and owns its own gesture — see `MenuBarStageView`.
            if settingsStore.settings.menuBarItem(kind).usesComposedStrip {
                MenuBarStageView(
                    kind: kind,
                    selection: $stripSelection,
                    pendingBlock: $stripPendingBlock,
                    scheme: stripScheme ?? scheme,
                    scale: scale,
                    onNaturalSize: { naturalSize = $0 },
                    onDragChange: { stripIsDragging = $0 }
                )
                .id(kind)
            } else {
                MenuBarDefaultStage(kind: kind, scheme: stripScheme ?? scheme, scale: scale,
                                    onNaturalSize: { naturalSize = $0 })
            }
        }
        }
    }

    /// The surface, lifted off the ground and wired to the studio.
    ///
    /// A shadow and a hairline, not a frame: the point is that the thing on
    /// the stage is the real surface, so it keeps its own corners and gets
    /// only the light around it. The mini window is its own glass panel and
    /// gets the light alone.
    private func popoverSurface(_ tab: OverviewPage) -> some View {
        surfaceShell(cornerRadius: 14, flat: false, isInteractive: true) {
            PopoverRoot(
                width: Self.popoverWidth(for: settingsStore.settings),
                onContentHeightChange: { _ in },
                onToggleMiniWindow: {
                    if let id = settingsStore.settings.miniWindow.windows.first?.id { model.subject = .miniWindow(id) }
                },
                initialPage: tab,
                onPageChange: { page in
                    model.frames.removeAll()
                    cardSelection = []
                    hovered = nil
                    if let layoutPage = page.layoutPageID {
                        previewOnlyPage = nil
                        model.subject = .popoverPage(layoutPage)
                    } else {
                        previewOnlyPage = page
                    }
                    scrollPosition.scrollTo(x: 0, y: 0)
                },
                onHeaderHeightChange: { headerHeight = $0 }
            )
        }
        .id(tab)
    }

    private func surfaceShell<Content: View>(
        cornerRadius: CGFloat,
        flat: Bool,
        isInteractive: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let scale = self.scale
        let shape = RoundedRectangle(cornerRadius: cornerRadius * scale, style: .continuous)
        return ScaledPreview(scale: scale, onNaturalSize: { naturalSize = $0 }, isInteractive: isInteractive) {
            content()
        }
        .background {
            if !flat { shape.fill(.background.secondary) }
        }
        .clipShape(shape)
        .overlay {
            if !flat { shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5) }
        }
        .overlay {
            if previewOnlyPage == nil { interactionLayer(cornerRadius: cornerRadius * scale) }
        }
        .overlay(alignment: .topLeading) { inlineLabelEditor }
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
        .environment(\.liftedSurfaceItems, drag?.engaged == true ? Set(drag?.members ?? []) : Set(settling?.members ?? []))
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
            if case .miniWindow = model.subject, let selected = miniSelection, let frame = model.frames.frame(of: selected) {
                StudioSelectionOutline()
                    .frame(width: frame.width * scale, height: frame.height * scale)
                    .offset(x: frame.minX * scale, y: frame.minY * scale)
            }
            if !cardSelection.isEmpty, let frame = surfaceBounds(Array(cardSelection)) {
                hoverOutline(frame.scaled(by: scale), cornerRadius: cornerRadius)
            }
            if drag == nil, settling == nil, let hovered, let frame = surfaceBounds(cardRun(hovered)) {
                hoverOutline(frame.scaled(by: scale), cornerRadius: cornerRadius)
                    .transition(.opacity)
            }
            if let drag, drag.engaged, case .popoverPage = model.subject {
                segmentGuides(drag)
            }
        }
        .contentShape(StudioSurfaceHitShape(headerHeight: {
            if case .popoverPage = model.subject { return headerHeight * scale }
            return 0
        }()))
        .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named(Self.space)).onEnded { value in
            guard case .miniWindow = model.subject, editingLabel == nil else { return }
            miniSelection = surfaceHit(surfacePoint(value.location))
        })
        .simultaneousGesture(SpatialTapGesture(count: 2, coordinateSpace: .named(Self.space)).onEnded { value in
            guard case .miniWindow = model.subject,
                  let label = model.frames.label(at: surfacePoint(value.location)) else { return }
            drag = nil
            editingLabel = label
            labelDraft = label.text
            isLabelFocused = true
        })
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
        .highPriorityGesture(surfaceDrag)
    }

    @ViewBuilder
    private var inlineLabelEditor: some View {
        if let label = editingLabel {
            TextField("", text: $labelDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: max(12, 9 * scale)))
                .frame(width: max(100, label.frame.width * scale), height: max(24, label.frame.height * scale))
                .offset(x: label.frame.minX * scale, y: label.frame.minY * scale)
                .focused($isLabelFocused)
                .onSubmit { commitLabel() }
                .onExitCommand { editingLabel = nil }
                .task { isLabelFocused = true }
        }
    }

    private func commitLabel() {
        guard let label = editingLabel, case let .miniWindow(id) = model.subject else { return }
        let value = labelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        editingLabel = nil
        guard value != label.text else { return }
        updateMini(id) { config in
            if label.isGroup {
                config.modeGroupLabels[config.displayMode.rawValue, default: [:]][label.key] = value.isEmpty ? nil : value
            } else {
                config.modeCustomLabels[config.displayMode.rawValue, default: [:]][label.key] = value.isEmpty ? nil : value
            }
        }
    }

    /// The card under the pointer, marked as something that can be picked
    /// up: a hairline in the accent and the faintest wash, nothing that
    /// competes with the card's own content.
    private func hoverOutline(_ frame: CGRect, cornerRadius: CGFloat) -> some View {
        return StudioSelectionOutline(isSelected: !cardSelection.isEmpty)
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)

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
            // Both axes: a page is far taller than it is wide, and fitting
            // the width alone left the bottom half of it to be scrolled to —
            // which read as cut off, not as "there is more". Whole page in
            // view first; zoom in to work on a part of it.
            guard naturalSize.width > 0, naturalSize.height > 0,
                  stageFrame.width > 0, stageFrame.height > 0
            else { return 1 }
            let room = CGSize(
                width: stageFrame.width - Self.stagePadding * 2,
                height: stageFrame.height - Self.stagePadding * 2 - Self.fitBarReserve
            )
            let fit = min(room.width / naturalSize.width, room.height / naturalSize.height)
            return min(1, max(0.35, fit))
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
        let strips = MenuBarItemKind.allCases.map(LayoutStudioWindowController.Subject.menuBar)
        // Every slide, preset ones included. Round 1 listed only the custom
        // slides, so a preset slide could be reached from Settings and nowhere
        // else — and the Studio's own picker looked like it had lost them.
        // Picking a preset slide shows what it draws, with one button to break
        // it into modules.
        let slides = settingsStore.settings.einkSync.devices.flatMap { device in
            device.slides.map {
                LayoutStudioWindowController.Subject.einkSlide(deviceID: device.deviceID, slideID: $0.id)
            }
        }
        return pages + windows + strips + slides
    }

    private func stepSubject(by offset: Int) {
        let all = subjects
        guard let index = all.firstIndex(of: model.subject) else { return }
        let target = index + offset
        guard all.indices.contains(target) else { return }
        withAnimation(.smooth(duration: 0.28)) { model.subject = all[target] }
    }

    private func title(for subject: LayoutStudioWindowController.Subject) -> String {
        if subject == model.subject, let page = previewOnlyPage { return page.label }
        switch subject {
        case let .popoverPage(page):
            return OverviewPage.allCases.first { $0.layoutPageID == page }?.label
                ?? L10n.Popover.Tab.overview
        case let .miniWindow(id):
            return settingsStore.settings.miniWindow.config(id: id)?.name ?? L10n.Popover.Header.mini
        case .menuBar:
            return L10n.Settings.Section.menuBar
        case let .einkSlide(deviceID, slideID):
            guard let slide = einkSlide(deviceID: deviceID, slideID: slideID) else {
                return L10n.Settings.Eink.customLayout
            }
            // The device as well as the slide: two panels with a slide called
            // "Quote 1" each are two identical rows in the picker otherwise.
            let device = einkDevice(deviceID)
            let panel = device?.alias.isEmpty == false ? device?.alias : deviceID
            let layout = slide.kind.preset.map(EInkNaming.preset) ?? L10n.Settings.Eink.customLayout
            let name = slide.title.isEmpty ? layout : slide.title
            return [panel, name].compactMap { $0 }.joined(separator: EInkSlotLabel.separator)
        }
    }

    private func icon(for subject: LayoutStudioWindowController.Subject) -> String {
        switch subject {
        case .popoverPage: return "rectangle.portrait.on.rectangle.portrait"
        case .miniWindow:  return "macwindow"
        case .menuBar:     return "menubar.rectangle"
        case .einkSlide:   return "rectangle.dashed"
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

    private var cardGroups: [[String]] {
        guard case let .popoverPage(page) = model.subject else { return [] }
        return settingsStore.settings.studioCardGroups[page.rawValue] ?? []
    }

    private func surfaceBounds(_ ids: [String]) -> CGRect? {
        let rect = ids.compactMap { model.frames.frame(of: $0) }.reduce(CGRect.null) { $0.union($1) }
        return rect.isNull ? nil : rect
    }

    private func studioBounds(_ ids: [String]) -> CGRect? {
        surfaceBounds(ids)?.scaled(by: scale).offsetBy(dx: surfaceFrame.minX, dy: surfaceFrame.minY)
    }

    private func cardRun(_ id: String) -> [String] {
        let live = (cardGroups.first { $0.contains(id) } ?? [id]).filter { model.frames.frame(of: $0) != nil }
        return live.isEmpty ? [id] : live
    }

    private func groupCards(_ page: PageLayoutPageID) {
        let context = pageContext(page)
        let order = context.displayed.flattened.moduleIDs.map(\.rawValue)
        let groups = StudioCardGroups.grouping(cardSelection, in: cardGroups, order: order)
        let members = order.filter(StudioCardGroups.expanded(cardSelection, groups: groups).contains).map(PageLayoutModuleID.init(rawValue:))
        guard members.count > 1, let first = members.first else { return }
        let columns = StudioCardGroups.gathering(groups, columns: context.displayed.flattened.columns)
        let segments = StudioCardGroups.joiningSegment(members, anchor: first, segments: context.displayed.moduleSegments)
        layoutModel.applyStudioArrangement(
            PageLayoutConfig(ratio: context.displayed.ratio, columns: columns,
                             measuredHeights: layoutModel.measuredHeights(for: page)),
            segments: segments, for: page, available: availableModuleIDs(context), groups: groups
        )
        cardSelection = Set(members.map(\.rawValue))
    }

    private func ungroupCards(_ page: PageLayoutPageID) {
        settingsStore.settings.studioCardGroups[page.rawValue] = cardGroups.filter { Set($0).isDisjoint(with: cardSelection) }
    }

    private func hideSelectedCards(_ page: PageLayoutPageID) {
        var settings = settingsStore.settings
        var stored = layoutModel.storedLayout(for: page) ?? StoredPageLayout(pageContext(page).displayed.flattened)
        for id in StudioCardGroups.expanded(cardSelection, groups: cardGroups) {
            stored = stored.settingHidden(PageLayoutModuleID(rawValue: id), true)
        }
        settings.pageLayouts[page] = stored
        settingsStore.settings = settings
        cardSelection = []
    }

    private func pageGroupControls(_ page: PageLayoutPageID) -> some View {
        let context = pageContext(page)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(L10n.MenuBar.Composer.Group.bind) { groupCards(page) }.disabled(cardSelection.count < 2)
                Button(L10n.MenuBar.Composer.Group.unbind) { ungroupCards(page) }.disabled(cardSelection.isEmpty)
                Button(L10n.Common.remove) { hideSelectedCards(page) }.disabled(cardSelection.isEmpty)
            }
            if !cardSelection.isEmpty {
                Text(L10n.MenuBar.Composer.Group.selected(count: cardSelection.count)).font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup(L10n.MenuBar.Composer.Group.bind) {
                ForEach(context.displayed.flattened.moduleIDs, id: \.self) { id in
                    Toggle(context.descriptor(id)?.displayName ?? id.rawValue, isOn: Binding(
                        get: { cardSelection.contains(id.rawValue) },
                        set: { selected in
                            let run = Set(cardRun(id.rawValue))
                            if selected { cardSelection.formUnion(run) } else { cardSelection.subtract(run) }
                        }
                    ))
                    .font(.caption)
                }
            }
            ForEach(Array(cardGroups.enumerated()), id: \.offset) { _, group in
                Button { cardSelection = Set(group.filter { model.frames.frame(of: $0) != nil }) } label: {
                    Label(group.compactMap { context.descriptor(PageLayoutModuleID(rawValue: $0))?.displayName }.joined(separator: " · "),
                          systemImage: "square.stack.3d.up")
                        .font(.caption).lineLimit(2)
                }
            }
        }
    }

    private func surfaceHit(_ point: CGPoint) -> String? {
        model.frames.item(at: point) ?? cardGroups.first { surfaceBounds($0)?.contains(point) == true }?.first
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

    private func canvasBinding(_ id: UUID) -> Binding<MiniCanvasLayout> {
        Binding(
            get: { (settingsStore.settings.miniCanvasLayouts[id.uuidString] ?? MiniCanvasLayout()).normalized() },
            set: { settingsStore.settings.miniCanvasLayouts[id.uuidString] = $0.normalized() }
        )
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
        einkSections = EInkFieldSection.sections(registry: quotaService.fieldRegistry)
    }

    // MARK: - E-ink context

    /// What the stage says when there is nothing to drag yet.
    ///
    /// Two cases, and both used to be silent. A preset slide drew its panel
    /// with every gesture doing nothing, because the Studio only edits a
    /// custom layout; and an orientation nobody had authored opened as blank
    /// paper with no hint that "Re-layout" is what fills it.
    @ViewBuilder
    private func einkStageNotice(deviceID: String, slideID: String) -> some View {
        let slide = einkSlide(deviceID: deviceID, slideID: slideID)
        if slide?.kind.preset != nil {
            einkNoticeCard(
                message: L10n.Settings.Eink.Studio.presetSubject,
                action: L10n.Settings.Eink.Studio.open,
                systemImage: "rectangle.dashed"
            ) {
                explodeEInk(deviceID: deviceID, slideID: slideID)
            }
        } else if einkLayout(deviceID: deviceID, slideID: slideID) == nil {
            einkNoticeCard(
                message: L10n.Settings.Eink.Studio.relayoutMissing,
                action: L10n.Settings.Eink.Studio.relayout,
                systemImage: "arrow.triangle.2.circlepath"
            ) {
                relayoutEInk(deviceID: deviceID, slideID: slideID)
            }
        }
    }

    private func einkNoticeCard(
        message: String,
        action: String,
        systemImage: String,
        perform: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: perform) {
                Label(action, systemImage: systemImage)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .frame(maxWidth: 320)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
    }

    private func einkDevice(_ deviceID: String) -> EInkDeviceConfig? {
        settingsStore.settings.einkSync.device(id: deviceID)
    }

    private func einkSlide(deviceID: String, slideID: String) -> EInkSlide? {
        einkDevice(deviceID)?.slide(id: slideID)
    }

    /// The key the slide's layout is actually stored under.
    ///
    /// A slide the Studio created keys its layout by its own id, but the
    /// slide is the one that says so: a settings file written by hand or by
    /// the desktop client can point somewhere else, and editing
    /// `einkCanvasLayouts[slide.id]` would then write a layout nothing draws
    /// while the panel kept rendering the one the slide names.
    private func einkLayoutID(deviceID: String, slideID: String) -> String {
        einkSlide(deviceID: deviceID, slideID: slideID)?.kind.layoutID.flatMap { $0.isEmpty ? nil : $0 }
            ?? slideID
    }

    /// The orientation being edited: the toolbar's choice, else the one the
    /// device is actually on.
    private func einkOrientation(_ deviceID: String) -> EInkOrientation {
        einkEditingOrientation ?? einkDevice(deviceID)?.orientation ?? .degrees0
    }

    private func einkProfile(_ deviceID: String) -> EInkDeviceProfile {
        einkDevice(deviceID)?.profile ?? .quote0
    }

    /// The stored layout for the orientation on the stage, or `nil` when
    /// nobody has authored that one yet.
    ///
    /// Through `EInkRenderer.layout`, which falls back to round 1's bare key —
    /// the renderer reads it, and a Studio that did not would call an existing
    /// design unauthored and offer to replace it.
    private func einkLayout(deviceID: String, slideID: String) -> EInkCanvasLayout? {
        EInkRenderer.layout(
            einkLayoutID(deviceID: deviceID, slideID: slideID),
            orientation: einkOrientation(deviceID),
            layouts: settingsStore.settings.einkCanvasLayouts
        )
    }

    /// The layout, always shaped to the panel it is going to.
    ///
    /// Keyed per orientation: a custom slide carries up to four, and round 1's
    /// single key is what made a rotated device show a landscape design turned
    /// on its side. Refitting on read rather than on write is what makes
    /// turning a device safe — the Studio shows the slide on the panel it will
    /// be pushed to from the moment it opens, and the refit is only persisted
    /// once the author edits something.
    private func einkLayoutBinding(deviceID: String, slideID: String) -> Binding<EInkCanvasLayout> {
        let profile = einkProfile(deviceID)
        let orientation = einkOrientation(deviceID)
        let key = EInkRenderer.layoutKey(
            einkLayoutID(deviceID: deviceID, slideID: slideID),
            orientation: orientation
        )
        let layoutID = einkLayoutID(deviceID: deviceID, slideID: slideID)
        let deviceOrientation = einkDevice(deviceID)?.orientation ?? orientation
        return Binding(
            get: {
                let stored = einkLayout(deviceID: deviceID, slideID: slideID)
                    ?? EInkCanvasLayout(profile: profile, orientation: orientation)
                return stored.fitted(profile: profile, orientation: orientation)
            },
            set: { value in
                var settings = settingsStore.settings
                // Finish part A's migration on the first write rather than
                // leaving a bare round 1 key beside the new ones, where the
                // service's own migration would later overwrite whichever
                // orientation the device happened to be on.
                if let legacy = settings.einkCanvasLayouts[layoutID] {
                    let deviceKey = EInkRenderer.layoutKey(layoutID, orientation: deviceOrientation)
                    if settings.einkCanvasLayouts[deviceKey] == nil {
                        settings.einkCanvasLayouts[deviceKey] = legacy
                    }
                    settings.einkCanvasLayouts[layoutID] = nil
                }
                settings.einkCanvasLayouts[key] = value.normalized()
                settingsStore.settings = settings
            }
        )
    }

    /// "Re-layout": this orientation, arranged from the slide's preset again.
    ///
    /// A slide that is already custom remembers which preset it came from
    /// through its exploded modules, but not as data — so the re-layout goes
    /// through the preset the slide names, and a slide with none falls back to
    /// the ledger, which is what a brand new slide draws.
    private func relayoutEInk(deviceID: String, slideID: String) {
        guard let snapshot = einkSnapshot,
              let slide = einkSlide(deviceID: deviceID, slideID: slideID) else { return }
        let orientation = einkOrientation(deviceID)
        var source = slide
        if source.kind.preset == nil {
            source.kind = .preset(slide.options.sourcePreset ?? .quotaLedger)
        }
        let layout = EInkPresetExploder.explode(
            slide: source.fitted(to: orientation),
            orientation: orientation,
            profile: einkProfile(deviceID),
            snapshot: snapshot
        )
        einkLayoutBinding(deviceID: deviceID, slideID: slideID).wrappedValue = layout
        einkSelection = []
    }

    /// Turns a preset slide into the layout it already draws, so the Studio
    /// has something to edit. The settings pane does the same thing behind its
    /// own "Edit in Studio" — this is the way in for somebody who reached the
    /// Studio from the Layout section instead.
    private func explodeEInk(deviceID: String, slideID: String) {
        guard let snapshot = einkSnapshot,
              let slide = einkSlide(deviceID: deviceID, slideID: slideID),
              slide.kind.preset != nil else { return }
        var settings = settingsStore.settings
        guard let index = settings.einkSync.devices.firstIndex(where: { $0.deviceID == deviceID }),
              let position = settings.einkSync.devices[index].slides.firstIndex(where: { $0.id == slideID })
        else { return }
        let orientation = einkOrientation(deviceID)
        let layout = EInkPresetExploder.explode(
            slide: slide,
            orientation: orientation,
            profile: einkProfile(deviceID),
            snapshot: snapshot
        )
        settings.einkCanvasLayouts[EInkRenderer.layoutKey(slideID, orientation: orientation)] = layout
        settings.einkSync.devices[index].slides[position].kind = .custom(layoutID: slideID)
        settings.einkSync.devices[index].slides[position].options.sourcePreset = slide.kind.preset
        settingsStore.settings = settings
        einkSelection = []
    }

    /// Whether a drag on this orientation's layout snaps to the 8 px grid.
    ///
    /// Stored on the layout rather than in the window so it survives closing
    /// the Studio, and per orientation because that is where the layout lives.
    private func einkSnapBinding(deviceID: String, slideID: String) -> Binding<Bool> {
        let layout = einkLayoutBinding(deviceID: deviceID, slideID: slideID)
        return Binding(
            get: { layout.wrappedValue.snapToGrid },
            set: { value in
                // Belt and braces with the disabled control above: a gesture
                // aid must never be the thing that first writes a layout.
                guard einkLayout(deviceID: deviceID, slideID: slideID) != nil else { return }
                var next = layout.wrappedValue
                next.snapToGrid = value
                layout.wrappedValue = next
            }
        )
    }

    /// The slide's custom labels, edited in the inspector.
    private func einkLabelsBinding(deviceID: String, slideID: String) -> Binding<[String: String]> {
        Binding(
            get: { einkSlide(deviceID: deviceID, slideID: slideID)?.options.customLabels ?? [:] },
            set: { labels in
                var settings = settingsStore.settings
                guard let index = settings.einkSync.devices.firstIndex(where: { $0.deviceID == deviceID }),
                      let position = settings.einkSync.devices[index].slides.firstIndex(where: { $0.id == slideID })
                else { return }
                settings.einkSync.devices[index].slides[position].options.customLabels = labels
                // The same sanitize the settings pane's own writes go through.
                // Without it a 400-character name, or one carrying the Canvas
                // API's `{{` marker, is stored and previewed as typed while
                // `EInkSyncService.apply` trims its own copy on the way to the
                // panel — a preview that disagrees with the device.
                settings.einkSync.devices[index] = settings.einkSync.devices[index].sanitized
                settingsStore.settings = settings
            }
        )
    }

    /// Reads the same preview snapshot the settings pane draws from, so the
    /// Studio's numbers are the ones that would be pushed right now.
    private func refreshEInkSnapshot() async {
        guard let service = environment.einkSyncService else { return }
        await service.refreshPreviewSnapshot(
            includingFieldIDs: settingsStore.settings.einkSync.selectedQuotaFieldIDs(
                layouts: settingsStore.settings.einkCanvasLayouts
            )
        )
        einkSnapshot = service.previewSnapshot
    }

    /// The stage's "Push to device": one forced pass for this slide's panel.
    private func pushEInk(deviceID: String) {
        guard let service = environment.einkSyncService, !isPushingEInk else { return }
        isPushingEInk = true
        einkPush?.cancel()
        einkPush = Task { @MainActor in
            defer { isPushingEInk = false }
            _ = await service.pushNow(
                deviceID: deviceID,
                applying: settingsStore.settings.einkSync,
                layouts: settingsStore.settings.einkCanvasLayouts
            )
        }
    }

    /// Arrow-key nudging for the e-ink stage.
    private func nudgeEInk(deviceID: String, slideID: String, dx: Int, dy: Int, major: Bool) -> Bool {
        guard !einkSelection.isEmpty else { return false }
        let binding = einkLayoutBinding(deviceID: deviceID, slideID: slideID)
        binding.wrappedValue = EInkStudioStage.nudged(
            binding.wrappedValue,
            selection: einkSelection,
            dx: dx,
            dy: dy,
            major: major
        )
        return true
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
        var members: [String] = []
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
        let members: [String]
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
                          let item = surfaceHit(surfacePoint(value.startLocation)),
                          var started = makeDrag(item: item, origin: .surface, at: value.startLocation)
                    else { return }
                    if case .popoverPage = model.subject {
                        let run = Set(cardRun(item))
                        if NSEvent.modifierFlags.contains(.shift) {
                            if cardSelection.contains(item) { cardSelection.subtract(run) }
                            else { cardSelection.formUnion(run) }
                        } else if !cardSelection.contains(item) { cardSelection = run }
                        let order = started.baseColumns.flatMap { $0 }.map(\.rawValue)
                        started.members = order.filter(cardSelection.contains)
                        if started.members.isEmpty { started.members = [item] }
                    }
                    if case .miniWindow = model.subject { miniSelection = item }
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
            started.members = cardRun(item)
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
            started.members = [item]
            started.axis = config.displayMode.stageAxis
            return started
        case .menuBar, .einkSlide:
            // Both stages own their own gesture.
            return nil
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
            if let rect = studioBounds(current.members.isEmpty ? [current.item] : current.members) {
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
            let members = current.members.map(PageLayoutModuleID.init(rawValue:))
            let moving = Set(members)
            var columns: [[PageLayoutModuleID]]?
            var segments: [[PageLayoutModuleID]]?
            var slot: StudioArranging.ColumnSlot?
            if removed {
                columns = current.baseColumns.map { $0.filter { !moving.contains($0) } }
                segments = current.baseSegments
            } else {
                let next = StudioArranging.columnSlot(
                    at: point,
                    columnRanges: columnRanges(ratio: current.ratio),
                    columns: current.baseColumns.map { $0.filter { $0 == moduleID || !moving.contains($0) } },
                    frames: pageFrames(),
                    dragging: moduleID
                )
                slot = next
                if next != current.slot || current.provisionalColumns == nil {
                    let moved = StudioCardGroups.moving(members, to: next, columns: current.baseColumns)
                    columns = moved
                    let placement = StudioArranging.segmentsAfterMove(
                        moduleID, columns: moved, segments: current.baseSegments
                    )
                    segments = StudioCardGroups.joiningSegment(members, anchor: moduleID, segments: placement)
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
        case .menuBar, .einkSlide:
            drag = current
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
            let target = studioBounds(current.members)
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
        case .menuBar, .einkSlide:
            withAnimation(Self.reflow) { drag = nil }
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
            members: current.members,
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
            return SavedState(subject: model.subject, state: .page(page, layoutModel.storedLayout(for: page), cardGroups))
        case let .miniWindow(id):
            return SavedState(
                subject: model.subject,
                state: .miniWindow(id, miniConfig(id), settingsStore.settings.miniCanvasLayouts[id.uuidString])
            )
        case let .menuBar(kind):
            return SavedState(
                subject: model.subject,
                state: .menuBar(kind, settingsStore.settings.menuBarItem(kind))
            )
        case let .einkSlide(deviceID, slideID):
            return SavedState(
                subject: model.subject,
                state: .einkSlide(
                    deviceID: deviceID,
                    slideID: slideID,
                    orientation: einkOrientation(deviceID),
                    einkSlide(deviceID: deviceID, slideID: slideID),
                    einkLayout(deviceID: deviceID, slideID: slideID)
                )
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
            var settings = settingsStore.settings
            var stored = layoutModel.storedLayout(for: page) ?? StoredPageLayout(pageContext(page).displayed.flattened)
            for id in current.members { stored = stored.settingHidden(PageLayoutModuleID(rawValue: id), true) }
            settings.pageLayouts[page] = stored
            settingsStore.settings = settings
            cardSelection = []
        case let .miniWindow(id):
            guard let config = miniConfig(id) else { return }
            updateMini(id) { $0.fieldIds.removeAll { $0 == current.item } }
        case .menuBar, .einkSlide:
            break
        }
    }

    private func undo() {
        guard let entry = model.undoStack.popLast() else { return }
        undoWrite = entry
        if entry.subject != model.subject {
            model.subject = entry.subject
        }
        isUndoing = true
        defer { isUndoing = false }
        withAnimation(Self.reflow) {
            switch entry {
            case let .page(page, stored, groups):
                var settings = settingsStore.settings
                settings.pageLayouts[page] = stored
                settings.studioCardGroups[page.rawValue] = groups
                settingsStore.settings = settings
            case let .miniWindow(id, config, canvas):
                var settings = settingsStore.settings
                settings.miniCanvasLayouts[id.uuidString] = canvas
                if let config {
                    settings.miniWindow.upsert(config)
                } else {
                    settings.miniWindow.windows.removeAll { $0.id == id }
                }
                settingsStore.settings = settings
            case let .menuBar(_, item):
                settingsStore.settings.setMenuBarItem(item)
            case let .einkSlide(deviceID, slideID, orientation, slide, layout):
                var settings = settingsStore.settings
                // Through the slide's own key, not its id — see
                // `einkLayoutID`. The slide is restored first so the key is
                // the one the restored slide names.
                let layoutID = slide?.kind.layoutID.flatMap { $0.isEmpty ? nil : $0 }
                    ?? einkLayoutID(deviceID: deviceID, slideID: slideID)
                settings.einkCanvasLayouts[
                    EInkRenderer.layoutKey(layoutID, orientation: orientation)
                ] = layout
                if let slide, let index = settings.einkSync.devices.firstIndex(where: { $0.deviceID == deviceID }) {
                    var device = settings.einkSync.devices[index]
                    if let position = device.slides.firstIndex(where: { $0.id == slideID }) {
                        device.slides[position] = slide
                        settings.einkSync.devices[index] = device
                    }
                }
                settingsStore.settings = settings
                einkSelection = []
                // Put the stage back on the orientation the restored layout
                // belongs to, so the undo is visible rather than silent.
                einkEditingOrientation = orientation
            }
        }
    }

    // MARK: - Tray

    /// The pills whose selection slides as one shape.
    private enum PillGroup: Hashable {
        case mode, ratio, style, appearance
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
        case .menuBar, .einkSlide:
            // The palette in the inspector is the tray for both.
            return []
        }
    }

    private var trayCaption: String {
        switch model.subject {
        case .popoverPage: return L10n.Settings.Layout.studioTrayHidden
        case .miniWindow, .menuBar, .einkSlide: return L10n.Settings.Layout.studioTrayNotShown
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
            case .menuBar, .einkSlide:
                break
            }
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 10) {
            subjectMenu
            // Beside the subject, not centred: on a notched Mac a notch
            // companion keeps an invisible window over the top centre of the
            // screen, and a pill under it never sees the click. The corners
            // are the one part of the top edge nothing else claims.
            if previewOnlyPage == nil { subjectControls }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if !model.undoStack.isEmpty {
                    glassIconButton(systemImage: "arrow.uturn.backward", help: L10n.Settings.Layout.studioUndo) {
                        undo()
                    }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
                // Only where it changes the surface on the stage: a mini
                // window has a strip density of its own and never reads the
                // popover's.
                if case .popoverPage = model.subject {
                    densityPill
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
            Section(L10n.Settings.Section.menuBar) {
                ForEach(subjects.filter { if case .menuBar = $0 { return true } else { return false } }, id: \.self) { subject in
                    Button {
                        withAnimation(.smooth(duration: 0.28)) { model.subject = subject }
                    } label: {
                        Label(title(for: subject), systemImage: icon(for: subject))
                    }
                }
            }
            let slides = subjects.filter { if case .einkSlide = $0 { return true } else { return false } }
            if !slides.isEmpty {
                Section(L10n.Settings.Section.einkDisplays) {
                    ForEach(slides, id: \.self) { subject in
                        Button {
                            withAnimation(.smooth(duration: 0.28)) { model.subject = subject }
                        } label: {
                            Label(title(for: subject), systemImage: icon(for: subject))
                        }
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
    private var subjectControls: some View {
        switch model.subject {
        // Turning the *device* is still a Settings decision — it refits every
        // slide on that panel. What lives here is which of a custom slide's
        // four layouts is on the stage, whether a drag snaps, and the one
        // button that fills an orientation in from the preset.
        case let .einkSlide(deviceID, slideID):
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(EInkOrientation.allCases, id: \.rawValue) { candidate in
                        pillButton(
                            isSelected: candidate == einkOrientation(deviceID),
                            systemImage: nil,
                            title: nil,
                            group: .mode,
                            help: EInkNaming.orientation(candidate)
                        ) {
                            einkEditingOrientation = candidate
                            einkSelection = []
                        } custom: {
                            EInkOrientationGlyph(orientation: candidate)
                        }
                        // The glyph is four rectangles; without this the pill
                        // has no name for a screen reader to say.
                        .accessibilityLabel(EInkNaming.orientation(candidate))
                        .accessibilityAddTraits(
                            candidate == einkOrientation(deviceID) ? [.isSelected] : []
                        )
                    }
                }
                .padding(3)
                .glassEffect(.regular, in: .capsule)

                glassIconButton(
                    systemImage: einkSnapBinding(deviceID: deviceID, slideID: slideID).wrappedValue
                        ? "grid" : "grid.circle",
                    help: L10n.Settings.Eink.Studio.snapHelp
                ) {
                    let binding = einkSnapBinding(deviceID: deviceID, slideID: slideID)
                    binding.wrappedValue.toggle()
                }
                // Nothing to snap yet, and pressing it would *create* the
                // missing layout: the binding synthesizes an empty one to read
                // from, and writing that back stores a layout with no elements
                // — which stops the stage offering Re-layout and, at the
                // device's own orientation, pushes a blank panel.
                .disabled(einkLayout(deviceID: deviceID, slideID: slideID) == nil)

                glassIconButton(
                    systemImage: "arrow.triangle.2.circlepath",
                    help: L10n.Settings.Eink.Studio.relayout
                ) {
                    // A layout nobody has touched has nothing to lose, so the
                    // confirmation is only in the way when there is something
                    // to discard.
                    if einkLayout(deviceID: deviceID, slideID: slideID)?.elements.isEmpty ?? true {
                        relayoutEInk(deviceID: deviceID, slideID: slideID)
                    } else {
                        isConfirmingRelayout = true
                    }
                }
                .confirmationDialog(
                    L10n.Settings.Eink.Studio.relayout,
                    isPresented: $isConfirmingRelayout
                ) {
                    Button(L10n.Settings.Eink.Studio.relayout, role: .destructive) {
                        relayoutEInk(deviceID: deviceID, slideID: slideID)
                    }
                    Button(L10n.Common.cancel, role: .cancel) {}
                } message: {
                    Text(L10n.Settings.Eink.Studio.relayoutConfirm)
                }
            }
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
                                if candidate == .custom { model.isInspectorShown = true }
                            }
                        }
                    }
                }
                .padding(3)
                .glassEffect(.regular, in: .capsule)
            }
        case .menuBar:
            // The one thing a strip has to be checked against that a page
            // does not: both menu bars. A fixed colour can read on one and
            // vanish on the other.
            let current = stripScheme ?? scheme
            HStack(spacing: 2) {
                ForEach([ColorScheme.light, ColorScheme.dark], id: \.self) { candidate in
                    let label = candidate == .dark
                        ? L10n.MenuBar.Composer.Canvas.dark
                        : L10n.MenuBar.Composer.Canvas.light
                    pillButton(
                        isSelected: candidate == current,
                        systemImage: candidate == .dark ? "moon" : "sun.max",
                        title: candidate == current ? label : nil,
                        group: .appearance,
                        help: label
                    ) {
                        withAnimation(.smooth(duration: 0.22)) { stripScheme = candidate }
                    }
                }
            }
            .padding(3)
            .glassEffect(.regular, in: .capsule)
        }
    }

    /// The popover's density, changeable from the stage: the surface being
    /// arranged re-lays itself out at the new spacing as soon as it is picked.
    private var densityPill: some View {
        Menu {
            ForEach(PopoverDensity.allCases) { candidate in
                Button {
                    guard candidate != settingsStore.settings.popoverDensity else { return }
                    withAnimation(Self.reflow) { settingsStore.settings.popoverDensity = candidate }
                } label: {
                    if candidate == settingsStore.settings.popoverDensity {
                        Label(candidate.label, systemImage: "checkmark")
                    } else {
                        Text(candidate.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "textformat.size")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(settingsStore.settings.popoverDensity.label)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.Platform.Macos.MenuBar.displayDensity)
        .foregroundStyle(.primary)
        .padding(3)
        .glassEffect(.regular, in: .capsule)
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

    /// The glass is on a container around the button, as the zoom pill does
    /// it — applied to the button itself it sat above the button in hit
    /// testing, and the undo and inspector controls stopped taking clicks.
    private func glassIconButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.vibeBar(cornerRadius: 15))
            .help(help)
        }
        .foregroundStyle(.primary)
        .glassEffect(.regular, in: .circle)
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
        case .miniWindow, .menuBar, .einkSlide: return L10n.Settings.Layout.studioTrayAddHelp
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
            if config.displayMode == .custom { return L10n.Platform.Macos.MiniCanvas.hint }
            return config.displayMode.supportsStageArranging
                ? L10n.Settings.Layout.studioHintMini
                : L10n.Settings.Layout.studioHintFixedStyle
        case let .menuBar(kind):
            guard settingsStore.settings.menuBarItem(kind).usesComposedStrip else { return nil }
            return L10n.Platform.Macos.MenuBar.composerCanvasHint
        case .einkSlide:
            return L10n.Settings.Eink.Studio.hint
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
                    pageGroupControls(page)
                    // Identity per subject: the editors keep their own
                    // selection in `@State`, so without a rebuild the controls
                    // would go on editing whatever the last one was while the
                    // stage showed something else.
                    LayoutEditorView(initialPage: page)
                        .id(page)
                case let .miniWindow(id):
                    if miniConfig(id)?.displayMode == .custom {
                        MiniCanvasInspector(layout: canvasBinding(id), selection: $canvasSelection, fields: fieldOptions)
                            .id(id)
                    } else {
                        MiniWindowsSettingsSection(initialWindowID: id)
                            .id(id)
                    }
                case let .menuBar(kind):
                    menuBarInspector(kind)
                        .id(kind)
                case let .einkSlide(deviceID, slideID):
                    EInkStudioInspector(
                        layout: einkLayoutBinding(deviceID: deviceID, slideID: slideID),
                        selection: $einkSelection,
                        customLabels: einkLabelsBinding(deviceID: deviceID, slideID: slideID),
                        sections: einkSections,
                        slide: einkSlide(deviceID: deviceID, slideID: slideID)
                            ?? EInkSlide(id: slideID, kind: .custom(layoutID: slideID)),
                        orientation: einkOrientation(deviceID),
                        profile: einkProfile(deviceID),
                        snapshot: einkSnapshot,
                        report: einkReport,
                        isPushing: isPushingEInk,
                        // The engine renders the device's *own* orientation,
                        // so pushing while the stage shows another one would
                        // send a panel nobody is looking at.
                        canPush: einkOrientation(deviceID) == einkDevice(deviceID)?.orientation,
                        onPush: { pushEInk(deviceID: deviceID) }
                    )
                    .id(slideID)
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

    /// The composer, as Settings shows it, editing the block picked on the
    /// stage; above it the switch that makes the strip a composed one at all.
    private func menuBarInspector(_ kind: MenuBarItemKind) -> some View {
        let item = settingsStore.settings.menuBarItem(kind)
        return VStack(alignment: .leading, spacing: 12) {
            Picker(
                L10n.MenuBar.Composer.Mode.label,
                selection: Binding(
                    get: { item.usesComposedStrip },
                    set: { enabled in
                        var updated = settingsStore.settings.menuBarItem(kind)
                        updated.setComposedStripEnabled(
                            enabled,
                            template: .matching(updated.layout),
                            registry: quotaService.fieldRegistry,
                            groupCatalogLabel: MiniWindowGroupLabelCatalog.defaultLabel(for:)
                        )
                        settingsStore.settings.setMenuBarItem(updated)
                    }
                )
            ) {
                Text(L10n.MenuBar.Composer.Mode.default).tag(false)
                Text(L10n.MenuBar.Composer.Mode.custom).tag(true)
            }
            .pickerStyle(.segmented)
            if item.usesComposedStrip {
                MenuBarComposerEditor(
                    kind: kind,
                    density: density,
                    externalSelection: $stripSelection,
                    externalPendingBlock: $stripPendingBlock
                )
            } else {
                Text(L10n.MenuBar.Composer.Mode.defaultCaption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Keys

    private func installKeys() {
        model.keyHandler = { key in
            guard editingLabel == nil, previewOnlyPage == nil else { return false }
            switch key {
            case let .nudge(dx, dy, major):
                if case let .einkSlide(deviceID, slideID) = model.subject {
                    return nudgeEInk(deviceID: deviceID, slideID: slideID, dx: dx, dy: dy, major: major)
                }
                // Everywhere else the horizontal arrows still step subjects,
                // which is what they have always done.
                guard dy == 0, drag == nil else { return false }
                stepSubject(by: dx)
            case .selectAll:
                guard case let .popoverPage(page) = model.subject else { return false }
                cardSelection = Set(pageContext(page).displayed.flattened.moduleIDs.map(\.rawValue))
            case .group:
                guard case let .popoverPage(page) = model.subject else { return false }
                groupCards(page)
            case .ungroup:
                guard case let .popoverPage(page) = model.subject else { return false }
                ungroupCards(page)
            case .removeSelection:
                switch model.subject {
                case let .popoverPage(page):
                    guard !cardSelection.isEmpty else { return false }
                    hideSelectedCards(page)
                case let .miniWindow(id):
                    guard miniConfig(id)?.displayMode == .custom, !canvasSelection.isEmpty else { return false }
                    var layout = canvasBinding(id).wrappedValue
                    let members = layout.expandedSelection(canvasSelection)
                    layout.elements.removeAll { members.contains($0.id) }
                    canvasBinding(id).wrappedValue = layout
                    canvasSelection = []
                case let .einkSlide(deviceID, slideID):
                    guard !einkSelection.isEmpty else { return false }
                    let binding = einkLayoutBinding(deviceID: deviceID, slideID: slideID)
                    var layout = binding.wrappedValue
                    let members = layout.expandedSelection(einkSelection)
                    layout.elements.removeAll { members.contains($0.id) }
                    binding.wrappedValue = layout
                    einkSelection = []
                case let .menuBar(kind):
                    guard !stripSelection.isEmpty else { return false }
                    var item = settingsStore.settings.menuBarItem(kind)
                    guard var composition = item.composition else { return false }
                    for id in stripSelection { composition.remove(id) }
                    item.composition = composition
                    settingsStore.settings.setMenuBarItem(item)
                    stripSelection = []
                }
            case .escape:
                if !cardSelection.isEmpty, drag == nil { cardSelection = []; return true }
                // The strip answers Escape itself — a drag to cancel, a
                // selection to clear — through the key press the window
                // passes on when this returns false. With neither, Escape
                // closes the Studio as it does for every other subject.
                if case .menuBar = model.subject, stripIsDragging || !stripSelection.isEmpty {
                    return false
                }
                if case let .miniWindow(id) = model.subject,
                   miniConfig(id)?.displayMode == .custom, !canvasSelection.isEmpty {
                    return false
                }
                // The e-ink stage clears its own selection first, the same
                // way the free mini canvas does.
                if case .einkSlide = model.subject, !einkSelection.isEmpty { return false }
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
