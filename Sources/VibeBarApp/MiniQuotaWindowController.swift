import AppKit
import Combine
import SwiftUI
import VibeBarCore

/// On-disk representation of one mini window's saved screen position. Stored
/// in its own JSON file (see `VibeBarLocalStore.miniWindowGeometryURL`) so
/// dragging a panel doesn't touch the main `AppSettings` blob.
private struct MiniWindowGeometry: Codable {
    var originX: Double
    var originY: Double
    var pixelOriginX: Double?
    var pixelOriginY: Double?
    var screenScale: Double?
}

/// The geometry file: one entry per mini window, keyed by the window config's
/// UUID string. Decodes the pre-multi-window flat format too — that single
/// position belongs to whatever the first configured window is now.
private struct MiniWindowGeometryFile: Codable {
    var windows: [String: MiniWindowGeometry]

    init(windows: [String: MiniWindowGeometry] = [:]) {
        self.windows = windows
    }

    static func load(firstConfigID: UUID?) -> MiniWindowGeometryFile {
        let url = VibeBarLocalStore.miniWindowGeometryURL
        if let file = try? VibeBarLocalStore.readJSON(MiniWindowGeometryFile.self, from: url) {
            return file
        }
        if let legacy = try? VibeBarLocalStore.readJSON(MiniWindowGeometry.self, from: url),
           let firstConfigID {
            return MiniWindowGeometryFile(windows: [firstConfigID.uuidString: legacy])
        }
        return MiniWindowGeometryFile()
    }
}

@MainActor
final class MiniQuotaWindowController: NSObject, NSWindowDelegate {
    private struct PanelState {
        let panel: NSPanel
        var frameObserver: NSObjectProtocol?
        var lastSizingFingerprint: String?
    }

    private var panels: [UUID: PanelState] = [:]
    private weak var environment: AppEnvironment?
    /// Debounce repeated didMove notifications so we don't write the JSON
    /// geometry file on every pixel during a drag.
    private var originPersistWorkItem: DispatchWorkItem?
    private var isApplicationTerminating = false
    /// Re-runs the size calc for every visible panel when the user edits a
    /// window in Settings, and closes panels whose config was deleted.
    private var settingsCancellable: AnyCancellable?
    private var quotaCancellable: AnyCancellable?

    // MARK: - Public surface

    var anyVisible: Bool {
        panels.values.contains { $0.panel.isVisible }
    }

    func isVisible(configID: UUID) -> Bool {
        panels[configID]?.panel.isVisible == true
    }

    /// The menu-bar toggle: any window open → close all; none open → open all.
    func toggleAll(environment: AppEnvironment) {
        if anyVisible {
            closeAll()
        } else {
            for config in environment.settingsStore.settings.miniWindow.windows {
                show(configID: config.id, environment: environment)
            }
        }
    }

    func toggle(configID: UUID, environment: AppEnvironment) {
        if isVisible(configID: configID) {
            close(configID: configID)
        } else {
            show(configID: configID, environment: environment)
        }
    }

    /// Restore each window's previous open state on app launch.
    func restoreIfNeeded(environment: AppEnvironment) {
        // A demo launch shows exactly the surface it was asked for; windows
        // left open by the previous demo launch must not come back.
        guard !DemoMode.isEnabled else { return }
        for config in environment.settingsStore.settings.miniWindow.windows where config.wasOpen {
            show(configID: config.id, environment: environment)
        }
    }

    /// Demo mode only: open the first window regardless of `wasOpen`.
    func presentForDemo(environment: AppEnvironment) {
        guard DemoMode.isEnabled else { return }
        guard let first = environment.settingsStore.settings.miniWindow.windows.first else { return }
        show(configID: first.id, environment: environment)
    }

    func applicationWillTerminate() {
        isApplicationTerminating = true
        persistOrigins()
        guard let environment else { return }
        var settings = environment.settingsStore.settings
        var changed = false
        for (configID, state) in panels where state.panel.isVisible {
            if let index = settings.miniWindow.windows.firstIndex(where: { $0.id == configID }),
               !settings.miniWindow.windows[index].wasOpen {
                settings.miniWindow.windows[index].wasOpen = true
                changed = true
            }
        }
        if changed {
            environment.settingsStore.settings = settings
        }
    }

    // MARK: - Show / close

    private func show(configID: UUID, environment: AppEnvironment) {
        self.environment = environment
        let settings = environment.settingsStore.settings
        guard let config = settings.miniWindow.config(id: configID) else { return }
        let state = panels[configID] ?? makePanel(configID: configID, environment: environment)
        panels[configID] = state
        applyStableContentSize(to: state.panel, config: config, environment: environment, preserveTopRight: false)
        panels[configID]?.lastSizingFingerprint = Self.sizingFingerprint(config: config, environment: environment)
        applySavedPositionOrDefault(to: state.panel, configID: configID, settings: settings)
        state.panel.orderFrontRegardless()
        markWasOpen(configID: configID, true)
        persistOrigins()
        observeChanges(environment: environment)
    }

    private func close(configID: UUID) {
        panels[configID]?.panel.orderOut(nil)
        markWasOpen(configID: configID, false)
    }

    private func closeAll() {
        for configID in panels.keys {
            close(configID: configID)
        }
    }

    // MARK: - Observation

    /// Subscribe once; every event re-checks all visible panels. The
    /// per-panel `lastSizingFingerprint` guard keeps unrelated settings
    /// changes from resizing anything.
    private func observeChanges(environment: AppEnvironment) {
        guard settingsCancellable == nil else { return }
        settingsCancellable = environment.settingsStore.$settings
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak environment] settings in
                guard let self, let environment else { return }
                self.reconcile(settings: settings, environment: environment)
            }
        quotaCancellable = environment.quotaService.$lastSuccessByAccount
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak environment] _ in
                guard let self, let environment else { return }
                // `@Published` emits before the property assignment. Defer one
                // main-loop turn so `environment.quota(for:)` reads the new map.
                DispatchQueue.main.async { [weak self, weak environment] in
                    guard let self, let environment else { return }
                    self.reconcile(settings: environment.settingsStore.settings, environment: environment)
                }
            }
    }

    private func reconcile(settings: AppSettings, environment: AppEnvironment) {
        for (configID, state) in panels {
            guard let config = settings.miniWindow.config(id: configID) else {
                // The window was deleted in Settings — take its panel down.
                state.panel.orderOut(nil)
                if let observer = state.frameObserver {
                    NotificationCenter.default.removeObserver(observer)
                }
                panels.removeValue(forKey: configID)
                continue
            }
            guard state.panel.isVisible else { continue }
            let fingerprint = Self.sizingFingerprint(config: config, environment: environment)
            guard fingerprint != state.lastSizingFingerprint else { continue }
            panels[configID]?.lastSizingFingerprint = fingerprint
            applyStableContentSize(to: state.panel, config: config, environment: environment, preserveTopRight: true)
        }
    }

    /// Stable identifier for everything `stableContentSize` reads. Field
    /// order matters — it drives the company folding — so the ids are joined
    /// in order, not sorted.
    static func sizingFingerprint(config: MiniWindowConfig, environment: AppEnvironment? = nil) -> String {
        let ids = visibleOrderedFieldIDs(config: config, environment: environment).joined(separator: ",")
        return "\(config.displayMode.rawValue)|\(config.stripDensity.rawValue)|\(ids)"
    }

    // MARK: - Window delegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSPanel,
              let configID = panels.first(where: { $0.value.panel === window })?.key
        else { return }
        if !isApplicationTerminating {
            markWasOpen(configID: configID, false)
        }
        if let observer = panels[configID]?.frameObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        panels.removeValue(forKey: configID)
        if panels.isEmpty {
            settingsCancellable?.cancel()
            settingsCancellable = nil
            quotaCancellable?.cancel()
            quotaCancellable = nil
        }
    }

    /// User-initiated close ("×" button). Same effect as ⌘W: hide and remember
    /// that the window is now closed.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !isApplicationTerminating,
           let configID = panels.first(where: { $0.value.panel === sender })?.key {
            markWasOpen(configID: configID, false)
        }
        return true
    }

    // MARK: - Panel construction

    private func makePanel(configID: UUID, environment: AppEnvironment) -> PanelState {
        let settings = environment.settingsStore.settings
        let config = settings.miniWindow.config(id: configID)
        let contentSize = config.map {
            Self.stableContentSize(config: $0, environment: environment)
        } ?? NSSize(width: 240, height: 181)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = config.map { "Vibe Bar Mini — \($0.name)" } ?? "Vibe Bar Mini"
        panel.delegate = self
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false

        let host = NSHostingController(
            rootView: MiniQuotaWindowView(
                configID: configID,
                onClose: { [weak self] in self?.close(configID: configID) },
                onToggleDisplayMode: { [weak self] in self?.cycleDisplayMode(configID: configID) }
            )
                .environmentObject(environment)
                .environmentObject(environment.settingsStore)
                .environmentObject(environment.quotaService)
        )
        panel.contentViewController = host

        // Persist the panel's origin whenever the user drags it. We hook
        // NSWindowDidMoveNotification rather than NSWindowDelegate because
        // the latter only fires on willMove for some moves on macOS.
        // A 0.4s debounce keeps a long drag from hammering disk.
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleOriginPersist() }
        }
        return PanelState(panel: panel, frameObserver: observer, lastSizingFingerprint: nil)
    }

    private func applyStableContentSize(
        to panel: NSPanel,
        config: MiniWindowConfig,
        environment: AppEnvironment,
        preserveTopRight: Bool
    ) {
        let contentSize = Self.stableContentSize(config: config, environment: environment)
        let current = panel.contentView?.bounds.size ?? panel.frame.size
        guard abs(current.width - contentSize.width) > 0.5 || abs(current.height - contentSize.height) > 0.5 else {
            return
        }
        if preserveTopRight {
            let oldFrame = panel.frame
            let resized = NSRect(
                x: oldFrame.maxX - contentSize.width,
                y: oldFrame.maxY - contentSize.height,
                width: contentSize.width,
                height: contentSize.height
            )
            panel.setFrame(Self.clampedFrame(resized, preferredScreen: panel.screen), display: false)
        } else {
            panel.setContentSize(contentSize)
        }
    }

    // MARK: - Sizing

    /// Count of primary + branch groups the ring/bar layouts render for
    /// `tool` given the selected bucket ids. Mirrors `MiniBranchCell.groupKey`
    /// so a sizing decision in the AppKit controller stays in sync with the
    /// SwiftUI layout without having to query the live quota. A primary
    /// bucket (anything that doesn't match a known branch-group id) counts as
    /// one extra group.
    static func miniGroupCount(
        tool: ToolType,
        selectedBucketIds: [String],
        registry: QuotaFieldRegistry
    ) -> Int {
        var keys: Set<String> = []
        var hasPrimary = false
        for bucketId in selectedBucketIds {
            if let key = miniBranchGroupKey(tool: tool, bucketId: bucketId, registry: registry) {
                keys.insert(key)
            } else {
                hasPrimary = true
            }
        }
        return keys.count + (hasPrimary ? 1 : 0)
    }

    static func miniBranchGroupKey(
        tool: ToolType,
        bucketId: String,
        registry: QuotaFieldRegistry
    ) -> String? {
        switch bucketId {
        case "gpt_5_3_codex_spark_five_hour", "gpt_5_3_codex_spark_weekly":
            return "codex.spark"
        case "weekly_sonnet":
            return "claude.sonnet"
        case "weekly_design":
            return "claude.design"
        case "daily_routines":
            return "claude.routine"
        case "weekly_opus":
            return "claude.opus"
        case "weekly_fable":
            return "claude.fable"
        case "weekly_oauth_apps":
            return "claude.oauth"
        case "models" where tool == .cursor:
            return "cursor.models"
        case "other_models" where tool == .cursor:
            return "cursor.other-models"
        case "grok_bot_weekly" where tool == .cursor:
            return "cursor.grok-bot"
        default:
            break
        }
        if tool == .antigravity {
            let lower = bucketId.lowercased()
            if lower == "gemini_five_hour" || lower == "gemini_weekly" {
                return "antigravity.gemini-models"
            }
            if lower == "claude_gpt_five_hour" || lower == "claude_gpt_weekly" {
                return "antigravity.claude-gpt-models"
            }
            if lower.contains("gpt-oss") { return "antigravity.gpt-oss" }
            if lower.contains("claude")  { return "antigravity.claude" }
            if lower.contains("flash-lite") { return "antigravity.gemini-flash-lite" }
            if lower.contains("flash")   { return "antigravity.gemini-flash" }
            if lower.contains("pro")     { return "antigravity.gemini-pro" }
            return "antigravity.\(bucketId)"
        }
        // A discovered field is a branch group exactly when its bucket
        // carried a group title; both windows of one group share the id stem.
        let fieldId = MenuBarFieldCatalog.fieldId(tool: tool, bucketId: bucketId)
        if MenuBarFieldCatalog.field(id: fieldId) == nil,
           let discovered = registry.field(id: fieldId),
           discovered.groupTitle != nil {
            return "\(tool.rawValue).\(MenuBarFieldCatalog.bucketGroupStem(bucketId))"
        }
        return nil
    }

    static func stableContentSize(
        config: MiniWindowConfig,
        environment: AppEnvironment? = nil
    ) -> NSSize {
        let registry = environment?.quotaService.fieldRegistry ?? .empty
        switch config.displayMode {
        case .regular, .compact:
            return ringOrBarContentSize(config: config, environment: environment, registry: registry)
        case .ledger:
            let size = MiniLedgerMetrics.size(entries: entries(config: config, environment: environment))
            return NSSize(width: size.width, height: size.height)
        case .strip:
            let size = MiniStripMetrics.size(
                entries: entries(config: config, environment: environment),
                density: config.stripDensity
            )
            return NSSize(width: size.width, height: size.height)
        case .tile:
            let size = MiniTileMetrics.size(entries: entries(config: config, environment: environment))
            return NSSize(width: size.width, height: size.height)
        case .focus:
            return NSSize(width: MiniFocusMetrics.size.width, height: MiniFocusMetrics.size.height)
        case .rail:
            return NSSize(width: MiniRailMetrics.size.width, height: MiniRailMetrics.size.height)
        }
    }

    /// The same flat entry list the alternative layouts render, so their
    /// panel size follows from exactly what they will draw.
    private static func entries(
        config: MiniWindowConfig,
        environment: AppEnvironment?
    ) -> [MiniEntry] {
        guard let environment else { return [] }
        return MiniEntry.entries(
            config: config,
            settings: environment.settingsStore.settings.miniWindow,
            registry: environment.quotaService.fieldRegistry,
            quota: { environment.quota(for: $0) }
        )
    }

    private static func ringOrBarContentSize(
        config: MiniWindowConfig,
        environment: AppEnvironment?,
        registry: QuotaFieldRegistry
    ) -> NSSize {
        let displayMode = config.displayMode
        let cellWidth: CGFloat
        let cellSpacing: CGFloat
        /// Gap between quota groups inside one SubProvider — spacing only,
        /// since PR "three-tier" removed the rule at that depth.
        let groupSpacing: CGFloat
        /// Gap between two SubProviders: the stack's spacing on both sides of
        /// the `MiniGroupDivider` plus the hairline itself.
        let subProviderSpacing: CGFloat
        /// Same arithmetic for the divider between two company columns.
        let companySpacing: CGFloat
        let horizontalPadding: CGFloat
        let closeButtonReserve: CGFloat
        let minWidth: CGFloat
        let height: CGFloat
        let dividerThickness: CGFloat = 0.75
        if displayMode == .compact {
            cellWidth = 40
            cellSpacing = 4
            groupSpacing = 9
            subProviderSpacing = 2 * 6 + dividerThickness
            companySpacing = 2 * 8 + dividerThickness
            horizontalPadding = 16
            closeButtonReserve = 20
            minWidth = 156
            height = 146
        } else {
            cellWidth = 62
            cellSpacing = 8
            groupSpacing = 14
            subProviderSpacing = 2 * 10 + dividerThickness
            companySpacing = 2 * 14 + dividerThickness
            horizontalPadding = 28
            closeButtonReserve = 24
            minWidth = 240
            height = 181
        }

        // Sizing mirrors the three-tier layout in
        // `MiniWindowProviderLayout` exactly, off the same Core grouping the
        // SwiftUI side renders: one column per L1 company, one labelled
        // section per L2 SubProvider inside it, and the L3 quota groups side
        // by side within a section. Cells only take the cell spacing *inside*
        // their own group, which is why the group count is subtracted rather
        // than one.
        let companies = MenuBarFieldCatalog.orderedSubProviderGroups(
            fieldIds: visibleOrderedFieldIDs(config: config, environment: environment),
            registry: registry
        )
        var width: CGFloat = 0
        for company in companies {
            for subProvider in company.subProviders {
                let cellCount = subProvider.fields.count
                let groupCount = max(
                    1,
                    Self.miniGroupCount(
                        tool: subProvider.tool,
                        selectedBucketIds: subProvider.bucketIds,
                        registry: registry
                    )
                )
                width += CGFloat(cellCount) * cellWidth
                width += CGFloat(max(0, cellCount - groupCount)) * cellSpacing
                width += CGFloat(groupCount - 1) * groupSpacing
            }
            width += CGFloat(max(0, company.subProviders.count - 1)) * subProviderSpacing
        }
        width += CGFloat(max(0, companies.count - 1)) * companySpacing
        width += horizontalPadding + closeButtonReserve

        let screenMaxWidth = (NSScreen.vibeBarPresentationScreen?.visibleFrame.width ?? 900) - 48
        return NSSize(
            width: max(minWidth, min(width, max(screenMaxWidth, minWidth))),
            height: height
        )
    }

    /// The config's field order restricted to fields that resolve against the
    /// merged catalog and have a live bucket. Order preserved — it drives the
    /// company folding.
    private static func visibleOrderedFieldIDs(
        config: MiniWindowConfig,
        environment: AppEnvironment?
    ) -> [String] {
        guard let environment else { return config.fieldIds }
        let registry = environment.quotaService.fieldRegistry
        return config.fieldIds.filter { fieldID in
            guard let field = MenuBarFieldCatalog.field(id: fieldID, registry: registry) else { return false }
            return environment.quota(for: field.tool)?.bucket(id: field.bucketId) != nil
        }
    }

    private static func clampedFrame(_ frame: NSRect, preferredScreen: NSScreen?) -> NSRect {
        guard let visibleFrame = preferredScreen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            return frame
        }
        let margin: CGFloat = 8
        var origin = frame.origin
        let maxX = visibleFrame.maxX - margin - frame.width
        let maxY = visibleFrame.maxY - margin - frame.height
        origin.x = min(max(origin.x, visibleFrame.minX + margin), maxX)
        origin.y = min(max(origin.y, visibleFrame.minY + margin), maxY)
        return NSRect(origin: origin, size: frame.size)
    }

    // MARK: - Geometry persistence

    private func scheduleOriginPersist() {
        originPersistWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.persistOrigins() }
        }
        originPersistWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    private func applySavedPositionOrDefault(to panel: NSPanel, configID: UUID, settings: AppSettings) {
        let size = panel.frame.size
        let firstID = settings.miniWindow.windows.first?.id
        let file = MiniWindowGeometryFile.load(firstConfigID: firstID)
        // Prefer the geometry file; fall back to the legacy settings copy
        // (users upgrading from <= 0.1 builds) for the first window only.
        var savedX = file.windows[configID.uuidString]?.originX
        var savedY = file.windows[configID.uuidString]?.originY
        if savedX == nil, configID == firstID {
            savedX = settings.miniWindow.savedOriginX
            savedY = settings.miniWindow.savedOriginY
        }
        if let x = savedX, let y = savedY,
           Self.isOriginVisible(NSPoint(x: x, y: y), size: size) {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }
        guard let visibleFrame = NSScreen.vibeBarPresentationScreen?.visibleFrame else { return }
        // Stagger windows without a saved position so opening three at once
        // doesn't stack them into one pile.
        let index = settings.miniWindow.windows.firstIndex { $0.id == configID } ?? 0
        let offset = CGFloat(index) * 28
        panel.setFrameOrigin(
            NSPoint(
                x: visibleFrame.maxX - size.width - 24 - offset,
                y: visibleFrame.maxY - size.height - 48 - offset
            )
        )
    }

    private static func isOriginVisible(_ origin: NSPoint, size: NSSize) -> Bool {
        // Reject saved origins that no longer fit any current screen (e.g. user
        // unplugged an external monitor). Falls back to the default placement.
        for screen in NSScreen.screens {
            let visible = screen.visibleFrame
            let cornerOnScreen = NSPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
            if visible.contains(cornerOnScreen) { return true }
        }
        return false
    }

    private func persistOrigins() {
        guard !panels.isEmpty else { return }
        let firstID = environment?.settingsStore.settings.miniWindow.windows.first?.id
        var file = MiniWindowGeometryFile.load(firstConfigID: firstID)
        for (configID, state) in panels {
            let origin = state.panel.frame.origin
            let scale = state.panel.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
            file.windows[configID.uuidString] = MiniWindowGeometry(
                originX: Double(origin.x),
                originY: Double(origin.y),
                pixelOriginX: Double(origin.x * scale),
                pixelOriginY: Double(origin.y * scale),
                screenScale: Double(scale)
            )
        }
        // Standalone file: avoids rewriting the AppSettings JSON (and
        // fanning out to every $settings subscriber + status-item rerender)
        // on every drag-tick. See VibeBarLocalStore.miniWindowGeometryURL.
        try? VibeBarLocalStore.writeJSON(file, to: VibeBarLocalStore.miniWindowGeometryURL)
    }

    // MARK: - Per-window state

    private func cycleDisplayMode(configID: UUID) {
        guard let environment else { return }
        var settings = environment.settingsStore.settings
        guard let index = settings.miniWindow.windows.firstIndex(where: { $0.id == configID }) else { return }
        settings.miniWindow.windows[index].displayMode = settings.miniWindow.windows[index].nextDisplayMode()
        environment.settingsStore.settings = settings
        if let state = panels[configID] {
            applyStableContentSize(
                to: state.panel,
                config: settings.miniWindow.windows[index],
                environment: environment,
                preserveTopRight: true
            )
            panels[configID]?.lastSizingFingerprint = Self.sizingFingerprint(
                config: settings.miniWindow.windows[index],
                environment: environment
            )
            persistOrigins()
        }
    }

    private func markWasOpen(configID: UUID, _ open: Bool) {
        guard let environment else { return }
        var settings = environment.settingsStore.settings
        guard let index = settings.miniWindow.windows.firstIndex(where: { $0.id == configID }) else { return }
        if settings.miniWindow.windows[index].wasOpen != open {
            settings.miniWindow.windows[index].wasOpen = open
            environment.settingsStore.settings = settings
        }
    }
}
