import AppKit
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
        applySavedPositionOrDefault(to: panel, settings: environment.settingsStore.settings)
        panel.orderFrontRegardless()
        markWasOpen(true)
        persistOrigin()
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
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
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
        host.sizingOptions = [.preferredContentSize]
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
