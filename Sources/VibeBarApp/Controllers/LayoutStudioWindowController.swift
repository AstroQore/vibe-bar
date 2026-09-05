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
/// second thing competing for the same pane — and in that place the surface is
/// not a picture but the editor: cards and cells are dragged where they are.
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
        /// The composed menu bar strip of one status item.
        case menuBar(MenuBarItemKind)
    }

    private var window: NSWindow?
    private var hostingView: NSView?
    private var keyMonitor: Any?
    let model = LayoutStudioModel()

    func open(subject: Subject, environment: AppEnvironment) {
        model.subject = subject
        // Before the window exists: switching activation policy reorders the
        // app's windows, and doing it afterwards can drop the new one behind.
        DockActivationController.shared.acquire(.layoutStudio)

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
        let initialSize = NSSize(width: 1240, height: 860)
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = L10n.Settings.Layout.studioTitle
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
        win.minSize = NSSize(width: 880, height: 600)
        if !DemoMode.isEnabled {
            win.setFrameAutosaveName(Self.frameAutosaveName)
        }
        self.window = win
        self.hostingView = hosting.view
        installKeyMonitor()

        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    /// A picture of one region of the studio, in the hosting view's
    /// coordinates (origin top-left, as SwiftUI's `.global` space reports).
    ///
    /// This is the drag image: when a card lifts off the stage the Studio
    /// carries the pixels the card was just drawn with, the way Finder carries
    /// an icon, and leaves a dimmed placeholder in the layout to make room.
    /// Rendering the card a second time would need every environment object
    /// the popover has, for a picture that only lasts a drag.
    func snapshot(of rect: CGRect) -> NSImage? {
        guard let view = hostingView, rect.width >= 1, rect.height >= 1 else { return nil }
        var region = rect.integral
        if !view.isFlipped {
            region.origin.y = view.bounds.height - region.maxY
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: region) else { return nil }
        view.cacheDisplay(in: region, to: rep)
        let image = NSImage(size: region.size)
        image.addRepresentation(rep)
        return image
    }

    /// Keys the studio answers, caught before AppKit routes them: the window
    /// is SwiftUI hosted in a menu-bar app with no menu of its own, so ⌘W and
    /// Escape would otherwise do nothing.
    ///
    /// Typing is left alone. A text field in the inspector gets every key it
    /// would in Settings; the monitor only looks at events whose first
    /// responder is not a text view.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            if let responder = window.firstResponder, responder is NSText || responder is NSTextView {
                return event
            }
            return self.model.handle(event) ? nil : event
        }
    }
}

extension LayoutStudioWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // The undo history is per studio session. The window and its model
        // are kept for the next opening, so the history has to be dropped
        // here: an entry that survived a close could put back a layout the
        // user has since changed in Settings.
        model.undoStack.removeAll()
        DockActivationController.shared.release(.layoutStudio)
    }
}

/// What the studio is looking at, how big, and what it can take back.
///
/// Owned by the controller so reopening the window on another subject
/// re-points the view rather than rebuilding it, and so the window's key
/// monitor has something to talk to.
@MainActor
final class LayoutStudioModel: ObservableObject {
    /// How the surface is scaled on the stage. `fit` follows the stage width;
    /// a chosen scale stays put when the window is resized.
    enum Zoom: Equatable {
        case fit
        case scale(CGFloat)
    }

    /// A key the studio answers. The view installs the handler; the window's
    /// event monitor asks.
    enum Key {
        case escape
        case close
        case zoomIn
        case zoomOut
        case zoomFit
        case undo
        case nextSubject
        case previousSubject
        case toggleInspector
    }

    @Published var subject: LayoutStudioWindowController.Subject = .popoverPage(.overview)
    @Published var zoom: Zoom = .fit
    @Published var isInspectorShown = false
    /// What the last edits replaced, newest last. Per studio session: closing
    /// the window forgets it, which is also what makes each entry cheap.
    @Published var undoStack: [StudioUndo] = []

    /// Where the tagged things on the stage are — see `SurfaceItemFrames`.
    let frames = SurfaceItemFrames()
    /// The pointer while a drag is in flight. Its own object so the picture
    /// under the pointer is the only view that redraws per mouse move.
    let pointer = StudioPointer()

    var keyHandler: ((Key) -> Bool)?

    func handle(_ event: NSEvent) -> Bool {
        guard let key = Self.key(for: event) else { return false }
        return keyHandler?(key) ?? false
    }

    static func key(for event: NSEvent) -> Key? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        switch event.keyCode {
        case 53:  return command || option ? nil : .escape
        case 123: return command || option ? nil : .previousSubject
        case 124: return command || option ? nil : .nextSubject
        default: break
        }
        guard command, let characters = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        switch characters {
        case "w": return option || shift ? nil : .close
        case "=", "+": return .zoomIn
        case "-": return .zoomOut
        case "0": return .zoomFit
        case "z": return shift || option ? nil : .undo
        case "]": return .nextSubject
        case "[": return .previousSubject
        case "i": return option ? .toggleInspector : nil
        default: return nil
        }
    }
}

/// The pointer, published on its own — see `LayoutStudioModel.pointer`.
@MainActor
final class StudioPointer: ObservableObject {
    @Published var location: CGPoint = .zero
}

/// One edit the studio can take back: what the subject's saved state was
/// just before. `nil` is a real state — a page never arranged, a window
/// that did not exist.
enum StudioUndo: Equatable {
    case page(PageLayoutPageID, StoredPageLayout?)
    case miniWindow(UUID, MiniWindowConfig?)
    case menuBar(MenuBarItemKind, MenuBarItemSettings)

    var subject: LayoutStudioWindowController.Subject {
        switch self {
        case let .page(page, _): return .popoverPage(page)
        case let .miniWindow(id, _): return .miniWindow(id)
        case let .menuBar(kind, _): return .menuBar(kind)
        }
    }
}
