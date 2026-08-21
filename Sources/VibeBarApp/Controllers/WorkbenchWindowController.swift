import AppKit
import SwiftUI
import VibeBarCore

/// Hosts the Workbench in a standalone window.
///
/// The popover is transient and Settings is a place users pass through; the
/// Workbench is where they stay. It is therefore a first-class window: it
/// remembers its frame, and it holds a Dock token for as long as it is open so
/// the agent-only app can be reached from the Dock and the app switcher.
@MainActor
final class WorkbenchWindowController: NSObject {
    static let frameAutosaveName = "VibeBarWorkbenchWindow"

    private var window: NSWindow?
    private weak var environment: AppEnvironment?
    private let navigation = WorkbenchNavigation()

    func show(environment: AppEnvironment, page: WorkbenchPage? = nil, settingsDestination: SettingsDestination? = nil) {
        self.environment = environment
        if let settingsDestination {
            navigation.selectSettings(settingsDestination)
        } else if let page {
            navigation.select(page)
        }
        // Before the window exists: switching activation policy reorders the
        // app's windows, and doing that after `makeKeyAndOrderFront` can drop
        // the new window behind whatever was in front.
        DockActivationController.shared.acquire(.workbench)

        if let window {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(
            rootView: WorkbenchRootView(initialPage: page, navigation: navigation)
                .environmentObject(environment)
                .environmentObject(environment.accountStore)
                .environmentObject(environment.settingsStore)
                .environmentObject(environment.quotaService)
                .environmentObject(environment.serviceStatus)
                .environmentObject(environment.costService)
                .environmentObject(environment.remoteProbeService)
                .environmentObject(environment.pageLayout)
                .environmentObject(environment.workbenchServices)
        )
        let initialSize = NSSize(width: 1180, height: 820)
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Workbench"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isReleasedWhenClosed = false
        win.contentViewController = hosting
        win.setContentSize(initialSize)
        win.center()
        win.minSize = NSSize(width: 1040, height: 680)
        if DemoMode.isEnabled {
            // Autosave lives in the real account's defaults, not the demo
            // home; a capture run must neither read nor move the user's
            // Workbench. A fixed, centred frame also keeps every screenshot
            // the same size.
            win.setContentSize(NSSize(width: 1440, height: 900))
            if let screen = DemoPresenter.targetScreen {
                let visible = screen.visibleFrame
                let size = win.frame.size
                win.setFrameOrigin(NSPoint(
                    x: visible.midX - size.width / 2,
                    y: visible.midY - size.height / 2
                ))
            } else {
                win.center()
            }
        } else {
            win.setFrameAutosaveName(Self.frameAutosaveName)
        }
        win.delegate = self
        self.window = win

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Bring an already-created Workbench back to the front without building
    /// one. Reports whether there was anything to front, so a Dock reopen can
    /// stay a no-op when the user has closed the Workbench.
    @discardableResult
    func frontExistingWindow() -> Bool {
        // The cached window survives close, so visibility — not existence —
        // is what separates "re-front the open Workbench" from resurrecting
        // one the user dismissed. Re-acquiring the token is idempotent and
        // covers a reopen that arrives while another surface holds the Dock.
        guard let window, window.isVisible else { return false }
        DockActivationController.shared.acquire(.workbench)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func close() {
        window?.close()
    }
}

extension WorkbenchWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // The window itself stays cached so reopening is instant; only the
        // Dock icon goes away, which is what "the Workbench is closed" means
        // for an agent app.
        DockActivationController.shared.release(.workbench)
    }
}
