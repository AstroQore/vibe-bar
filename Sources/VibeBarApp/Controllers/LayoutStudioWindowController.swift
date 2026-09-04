import AppKit
import SwiftUI
import VibeBarCore

/// The window the layout editors hand off to when a picture is not enough.
///
/// Settings shows a skeleton: it fits the room a pane has, and structure is
/// what arranging mostly needs. Seeing the real surface needs the surface's own
/// width — a popover page and a mini window each want more than a settings
/// column has left over, and squeezing one in crowds the controls it is
/// supposed to help. So the full-size preview is a separate place rather than a
/// second thing competing for the same pane.
///
/// One window for both subjects. The two editors differ in what they arrange,
/// not in what the room is for.
@MainActor
final class LayoutStudioWindowController: NSObject {
    static let shared = LayoutStudioWindowController()
    static let frameAutosaveName = "VibeBarLayoutStudioWindow"

    /// What the studio is arranging.
    enum Subject: Hashable {
        case popoverPage(PageLayoutPageID)
        case miniWindow(UUID)
    }

    private var window: NSWindow?
    private let model = LayoutStudioModel()

    func open(subject: Subject, environment: AppEnvironment) {
        model.subject = subject

        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(
            rootView: LayoutStudioView(model: model)
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
        let initialSize = NSSize(width: 1320, height: 860)
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = L10n.Settings.layoutStudioTitle
        // The chrome gets out of the way of the surface on the stage: no
        // titlebar band, no opaque ground. The view's own materials are what
        // the window shows, and they only read as materials if something is
        // behind them.
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.isOpaque = false
        win.backgroundColor = .clear
        win.isReleasedWhenClosed = false

        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        let container = NSView(frame: NSRect(origin: .zero, size: initialSize))
        effect.frame = container.bounds
        container.addSubview(effect)
        hosting.view.frame = container.bounds
        hosting.view.autoresizingMask = [.width, .height]
        container.addSubview(hosting.view)
        let shell = NSViewController()
        shell.view = container
        shell.addChild(hosting)
        win.contentViewController = shell
        win.setContentSize(initialSize)
        win.center()
        win.minSize = NSSize(width: 1000, height: 620)
        if !DemoMode.isEnabled {
            win.setFrameAutosaveName(Self.frameAutosaveName)
        }
        self.window = win

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }
}

/// What the studio is looking at. Owned by the controller so reopening the
/// window on another subject re-points the view rather than rebuilding it.
@MainActor
final class LayoutStudioModel: ObservableObject {
    @Published var subject: LayoutStudioWindowController.Subject = .popoverPage(.overview)
}
