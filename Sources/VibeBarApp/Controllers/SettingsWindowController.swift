import AppKit
import SwiftUI
import VibeBarCore

/// Hosts SettingsView in a standalone resizable, draggable NSWindow.
/// The popover is transient; this window persists so users can keep it
/// open while inspecting menu bar state.
@MainActor
final class SettingsWindowController: NSObject {
    private var window: NSWindow?
    private weak var environment: AppEnvironment?

    func show(environment: AppEnvironment) {
        self.environment = environment
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(
            rootView: SettingsView(dismiss: { [weak self] in self?.close() })
                .environmentObject(environment)
                .environmentObject(environment.accountStore)
                .environmentObject(environment.settingsStore)
                .environmentObject(environment.quotaService)
                .environmentObject(environment.serviceStatus)
        )
        let initialSize = NSSize(width: 640, height: 720)
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Vibe Bar Settings"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .visible
        win.isReleasedWhenClosed = false
        win.contentViewController = hosting
        win.center()
        win.minSize = NSSize(width: 560, height: 540)
        win.delegate = self
        self.window = win

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }
}

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Keep window cached so settings re-open is instant; just clear ref if user really wanted to dispose.
        // Not destroying for now — fast reopen.
    }
}
