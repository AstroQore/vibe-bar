import AppKit
import SwiftUI
import VibeBarCore

/// Which step the setup assistant is on. Owned by the window controller so a
/// second `showOnboarding(step:)` can move an already-open window rather than
/// build a second one.
@MainActor
final class OnboardingNavigation: ObservableObject {
    @Published var step: OnboardingStep = .welcome
}

/// Hosts the first-run setup assistant in a standalone window.
///
/// The assistant is a place users pass through once, so it is smaller than
/// the Workbench and remembers nothing about its frame. Like the Workbench it
/// holds a Dock token while open: an agent-only app has no other way to be
/// reached from the app switcher, and a first-run window that vanished behind
/// the browser the user just switched to would be a poor introduction.
@MainActor
final class OnboardingWindowController: NSObject {
    static let contentSize = NSSize(width: 720, height: 560)

    private var window: NSWindow?
    private weak var environment: AppEnvironment?
    private let navigation = OnboardingNavigation()

    func show(environment: AppEnvironment, step: OnboardingStep? = nil) {
        self.environment = environment
        if let step {
            navigation.step = step
        }
        // Before the window exists, for the same reason the Workbench does it
        // first: switching activation policy reorders the app's windows.
        DockActivationController.shared.acquire(.onboarding)

        if let window {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            InitialFocusPolicy.clearOnReopen(of: window)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(
            rootView: OnboardingView(navigation: navigation)
                .vibeBarNoInitialFocus()
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
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Vibe Bar Setup"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isReleasedWhenClosed = false
        win.contentViewController = hosting
        win.setContentSize(Self.contentSize)
        win.contentMinSize = Self.contentSize
        if DemoMode.isEnabled, let screen = DemoPresenter.targetScreen {
            // Centred on the display the capture lands on, like the Workbench.
            let visible = screen.visibleFrame
            let size = win.frame.size
            win.setFrameOrigin(NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2
            ))
        } else {
            win.center()
        }
        win.delegate = self
        self.window = win

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Bring an open (or minimised) assistant back to the front without
    /// building one. On a first launch it is the only Dock-visible window,
    /// so the Dock reopen path asks here before it asks the Workbench.
    /// Reports whether there was anything to front.
    @discardableResult
    func frontExistingWindow() -> Bool {
        // A minimised window is not "visible" but is still open: it holds
        // its Dock token, and the Dock click is how it comes back.
        guard let window, window.isVisible || window.isMiniaturized else { return false }
        DockActivationController.shared.acquire(.onboarding)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        InitialFocusPolicy.clearOnReopen(of: window)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func close() {
        window?.close()
    }
}

extension OnboardingWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        DockActivationController.shared.release(.onboarding)
        // The window is cached; the next open should start at the beginning
        // rather than on whatever step the user closed it from.
        navigation.step = .welcome
        // Closing with the red button or ⌘W is a "not now" too. Recording it
        // keeps the assistant from reappearing on every launch until the user
        // finds the Skip button; Settings → System brings it back on demand.
        if let environment, !environment.settingsStore.settings.hasCompletedOnboarding {
            environment.settingsStore.settings.hasCompletedOnboarding = true
        }
    }
}
