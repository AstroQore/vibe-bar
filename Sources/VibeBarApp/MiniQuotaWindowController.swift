import AppKit
import Combine
import SwiftUI
import VibeBarCore

/// On-disk representation of the mini-window's saved screen position. Stored
/// in its own JSON file (see `VibeBarLocalStore.miniWindowGeometryURL`) so
/// dragging the panel doesn't touch the main `AppSettings` blob.
private struct MiniWindowGeometry: Codable {
    var originX: Double
    var originY: Double
    var pixelOriginX: Double?
    var pixelOriginY: Double?
    var screenScale: Double?
}

@MainActor
final class MiniQuotaWindowController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private weak var environment: AppEnvironment?
    /// We watch `panel.frameAutosaveName` indirectly via this observer so we
    /// can persist the user's drag-positioning back into the geometry file.
    private var frameObserver: NSObjectProtocol?
    /// Debounce repeated didMove notifications so we don't write the JSON
    /// geometry file on every pixel during a drag.
    private var originPersistWorkItem: DispatchWorkItem?
    private var isApplicationTerminating = false
    /// Combine subscription that re-runs the width calc when the user
    /// toggles a field selection in Settings. Without this, the mini
    /// window's SwiftUI body re-renders (fewer cells appear) but the
    /// AppKit NSPanel keeps its old width — so unchecking a Gemini
    /// model in Settings left the window the same physical size with
    /// a lot of empty real estate on the right.
    private var settingsCancellable: AnyCancellable?
    /// Last fingerprint we applied content size for, so we can skip
    /// the resize work when an unrelated settings field changes.
    private var lastSizingFingerprint: String?

    func toggle(environment: AppEnvironment) {
        if panel?.isVisible == true {
            close()
        } else {
            show(environment: environment)
        }
    }

    /// Restore the window's previous open/position state on app launch. No-op
    /// when `miniWindow.wasOpen` is false.
    func restoreIfNeeded(environment: AppEnvironment) {
        guard environment.settingsStore.settings.miniWindow.wasOpen else { return }
        show(environment: environment)
    }

    func applicationWillTerminate() {
        isApplicationTerminating = true
        persistOrigin()
        if panel?.isVisible == true {
            markWasOpen(true)
        }
    }

    private func show(environment: AppEnvironment) {
        self.environment = environment
        let panel = panel ?? makePanel(environment: environment)
        self.panel = panel
        let settings = environment.settingsStore.settings
        applyStableContentSize(to: panel, settings: settings, preserveTopRight: false)
        lastSizingFingerprint = Self.sizingFingerprint(for: settings)
        applySavedPositionOrDefault(to: panel, settings: settings)
        panel.orderFrontRegardless()
        markWasOpen(true)
        persistOrigin()
        observeSettingsChanges(environment: environment)
    }

    /// Subscribe to settingsStore so toggling a field in the Settings
    /// page or pasting in a new MenuBarSettings JSON re-runs the
    /// width calc and resizes the floating panel. The
    /// `lastSizingFingerprint` guard skips the resize when the
    /// settings change doesn't affect sizing (e.g. the user just
    /// flipped popoverDensity for a different surface).
    private func observeSettingsChanges(environment: AppEnvironment) {
        settingsCancellable = environment.settingsStore.$settings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] settings in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                let fp = Self.sizingFingerprint(for: settings)
                guard fp != self.lastSizingFingerprint else { return }
                self.lastSizingFingerprint = fp
                self.applyStableContentSize(to: panel, settings: settings, preserveTopRight: true)
            }
    }

    /// Stable identifier for everything `stableContentSize` reads.
    /// When this string changes we know we need to re-apply the
    /// content size; otherwise the re-render is a no-op.
    static func sizingFingerprint(for settings: AppSettings) -> String {
        let mini = settings.miniWindow
        let mode = mini.displayMode.rawValue
        let ids = mini.fieldIds(for: mini.displayMode).joined(separator: ",")
        return "\(mode)|\(ids)"
    }

    private func close() {
        panel?.orderOut(nil)
        markWasOpen(false)
    }

    func windowWillClose(_ notification: Notification) {
        if !isApplicationTerminating {
            markWasOpen(false)
        }
        if let observer = frameObserver {
            NotificationCenter.default.removeObserver(observer)
            frameObserver = nil
        }
        settingsCancellable?.cancel()
        settingsCancellable = nil
        lastSizingFingerprint = nil
        panel = nil
    }

    /// User-initiated close ("×" button). Same effect as ⌘W: hide and remember
    /// that the window is now closed.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !isApplicationTerminating {
            markWasOpen(false)
        }
        return true
    }

    private func makePanel(environment: AppEnvironment) -> NSPanel {
        let contentSize = Self.stableContentSize(for: environment.settingsStore.settings)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Vibe Bar Mini"
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
                onClose: { [weak self] in self?.close() },
                onToggleDisplayMode: { [weak self] in self?.toggleDisplayMode() }
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
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleOriginPersist() }
        }
        return panel
    }

    private func applyStableContentSize(to panel: NSPanel, settings: AppSettings, preserveTopRight: Bool) {
        let contentSize = Self.stableContentSize(for: settings)
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

    private static func stableContentSize(for settings: AppSettings) -> NSSize {
        let mini = settings.miniWindow
        let displayMode = mini.displayMode
        let cellWidth: CGFloat
        let cellSpacing: CGFloat
        let groupDividerReserve: CGFloat
        let providerSpacing: CGFloat
        let horizontalPadding: CGFloat
        let closeButtonReserve: CGFloat
        let minWidth: CGFloat
        let height: CGFloat
        switch displayMode {
        case .regular:
            cellWidth = 62
            cellSpacing = 8
            groupDividerReserve = 16.5
            providerSpacing = 14.75
            horizontalPadding = 28
            closeButtonReserve = 24
            minWidth = 240
            height = 166
        case .compact:
            cellWidth = 40
            cellSpacing = 4
            groupDividerReserve = 10
            providerSpacing = 8.75
            horizontalPadding = 16
            closeButtonReserve = 20
            minWidth = 156
            height = 134
        }

        let selected = mini.fieldIds(for: displayMode)
        var countsByTool: [ToolType: Int] = [:]
        for fieldId in selected {
            guard
                let field = MenuBarFieldCatalog.field(id: fieldId),
                field.tool.supportsDedicatedCard
            else { continue }
            countsByTool[field.tool, default: 0] += 1
        }

        // Sizing now mirrors the L2-grouped layout in
        // `MiniWindowProviderLayout`: consecutive tools sharing the
        // same L2 productName (Gemini Web + AntiGravity → "Gemini")
        // share one provider column with an internal divider between
        // L3 sub-tools. The width calc treats each L2 group as one
        // visible column for `providerSpacing` accounting, then adds
        // an extra `groupDividerReserve` per intra-group L3 boundary.
        var width: CGFloat = 0
        var visibleProductGroupCount = 0
        var lastProductName: String? = nil
        var toolsInCurrentGroup = 0
        for tool in ToolType.dedicatedCardProviders {
            guard let count = countsByTool[tool], count > 0 else { continue }
            let cellCount = CGFloat(count)
            width += cellCount * cellWidth
            width += CGFloat(max(0, count - 1)) * cellSpacing
            width += CGFloat(max(0, min(count - 1, 4))) * groupDividerReserve
            if lastProductName == tool.productName {
                // Same L2 group as previous tool — count one intra-group divider.
                width += groupDividerReserve
                toolsInCurrentGroup += 1
            } else {
                visibleProductGroupCount += 1
                lastProductName = tool.productName
                toolsInCurrentGroup = 1
            }
        }
        if visibleProductGroupCount > 1 {
            width += CGFloat(visibleProductGroupCount - 1) * providerSpacing
        }
        width += horizontalPadding + closeButtonReserve

        let screenMaxWidth = (NSScreen.main?.visibleFrame.width ?? 900) - 48
        return NSSize(
            width: max(minWidth, min(width, max(screenMaxWidth, minWidth))),
            height: height
        )
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

    private func scheduleOriginPersist() {
        originPersistWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.persistOrigin() }
        }
        originPersistWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    private func applySavedPositionOrDefault(to panel: NSPanel, settings: AppSettings) {
        let size = panel.frame.size
        // Prefer the standalone geometry file; fall back to the legacy
        // settings copy for users upgrading from <= 0.1 builds.
        let savedX: Double?
        let savedY: Double?
        if let geometry = Self.loadGeometry() {
            savedX = geometry.originX
            savedY = geometry.originY
        } else {
            savedX = settings.miniWindow.savedOriginX
            savedY = settings.miniWindow.savedOriginY
        }
        if let x = savedX, let y = savedY,
           Self.isOriginVisible(NSPoint(x: x, y: y), size: size) {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }
        guard let visibleFrame = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(
            NSPoint(
                x: visibleFrame.maxX - size.width - 24,
                y: visibleFrame.maxY - size.height - 48
            )
        )
    }

    private static func loadGeometry() -> MiniWindowGeometry? {
        try? VibeBarLocalStore.readJSON(MiniWindowGeometry.self, from: VibeBarLocalStore.miniWindowGeometryURL)
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

    private func persistOrigin() {
        guard let panel else { return }
        let origin = panel.frame.origin
        let scale = panel.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let pixelOrigin = NSPoint(x: origin.x * scale, y: origin.y * scale)
        let geometry = MiniWindowGeometry(
            originX: Double(origin.x),
            originY: Double(origin.y),
            pixelOriginX: Double(pixelOrigin.x),
            pixelOriginY: Double(pixelOrigin.y),
            screenScale: Double(scale)
        )
        // Standalone file: avoids rewriting the AppSettings JSON (and
        // fanning out to every $settings subscriber + status-item rerender)
        // on every drag-tick. See VibeBarLocalStore.miniWindowGeometryURL.
        try? VibeBarLocalStore.writeJSON(geometry, to: VibeBarLocalStore.miniWindowGeometryURL)
    }

    private func toggleDisplayMode() {
        guard let environment else { return }
        var settings = environment.settingsStore.settings
        settings.miniWindow.toggleDisplayMode()
        environment.settingsStore.settings = settings
        if let panel {
            applyStableContentSize(to: panel, settings: settings, preserveTopRight: true)
            persistOrigin()
        }
    }

    private func markWasOpen(_ open: Bool) {
        guard let environment else { return }
        var settings = environment.settingsStore.settings
        if settings.miniWindow.wasOpen != open {
            settings.miniWindow.wasOpen = open
            environment.settingsStore.settings = settings
        }
    }
}
