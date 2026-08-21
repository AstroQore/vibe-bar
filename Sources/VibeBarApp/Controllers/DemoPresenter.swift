import AppKit
import VibeBarCore

/// Opens the one surface a demo launch was asked to show, over a flat
/// backdrop, once the stores have had a moment to hydrate.
///
/// The README's screenshots are captured from windows this class puts on
/// screen, so it does as little as possible beyond choosing the surface: the
/// popover is the real popover anchored to the real status item, the mini
/// window is the real panel, the Workbench is the real window. The backdrop
/// exists because two of those surfaces are translucent — captured over a
/// desktop they would pick up whatever was behind them, and over one solid
/// colour they look the same in every capture.
@MainActor
final class DemoPresenter {
    private let configuration: DemoMode.Configuration
    private let environment: AppEnvironment
    private let statusItem: StatusItemController
    private var backdrop: NSWindow?

    /// Quota caches are read synchronously, but cost snapshots, subscription
    /// history and the usage ledger hydrate on the main actor a beat later.
    /// Presenting after this delay means the first frame is the populated one.
    private static let presentationDelay: TimeInterval = 1.2

    init(configuration: DemoMode.Configuration, environment: AppEnvironment, statusItem: StatusItemController) {
        self.configuration = configuration
        self.environment = environment
        self.statusItem = statusItem
    }

    /// The display every surface is put on: the sharpest one attached, so a
    /// capture comes out at 2× wherever the user happens to have their
    /// pointer. Ties go to the primary display.
    static var targetScreen: NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            if lhs.backingScaleFactor != rhs.backingScaleFactor {
                return lhs.backingScaleFactor < rhs.backingScaleFactor
            }
            // `max` keeps the later element on ties; prefer the earlier one.
            return lhs !== NSScreen.screens.first && rhs === NSScreen.screens.first
        }
    }

    func present() {
        if configuration.showsBackdrop {
            showBackdrop()
        }
        guard let surface = configuration.surface else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.presentationDelay) { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.open(surface)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self?.tuckBackdropBehindSurfaces()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.reportDelay) {
                self?.tuckBackdropBehindSurfaces()
                self?.reportPresentedWindows()
            }
        }
    }

    /// Every visible Vibe Bar window except the backdrop and the menu bar
    /// items — the surfaces a capture is of.
    private var presentedWindows: [NSWindow] {
        NSApp.windows.filter { window in
            window.isVisible
                && window !== backdrop
                && window.frame.width > 1 && window.frame.height > 1
                // Menu bar items have windows too; they are not a surface.
                && !String(describing: type(of: window)).contains("StatusBar")
        }
    }

    /// The backdrop shares the normal window level with other apps' windows,
    /// so it covers them while Vibe Bar is active — and it has to sit just
    /// under our own surfaces rather than at the back of the level, where an
    /// `orderBack` would put it behind those other apps again.
    private func tuckBackdropBehindSurfaces() {
        guard let backdrop, let surface = presentedWindows.first else { return }
        backdrop.order(.below, relativeTo: surface.windowNumber)
        // Controls draw in their inactive style unless the window is key,
        // and key status needs the app active — which the system may have
        // refused once already if the user was mid-click elsewhere.
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        if !surface.isKeyWindow, surface.canBecomeKey { surface.makeKey() }
    }

    /// The popover resizes to its content a few hundred milliseconds after
    /// it opens, and the Workbench pages fill in their first query; report
    /// only once both have happened.
    private static let reportDelay: TimeInterval = 2.0

    /// One JSON line on stdout naming every visible window but the backdrop,
    /// in Core Graphics screen coordinates (origin top-left of the primary
    /// display, points) — the frame `screencapture -R` wants. The capture
    /// script reads it instead of guessing where a surface landed.
    private func reportPresentedWindows() {
        guard let primary = NSScreen.screens.first else { return }
        let primaryHeight = primary.frame.maxY
        let windows = presentedWindows
        let scale = Self.targetScreen?.backingScaleFactor ?? 2
        let entries: [[String: Any]] = windows.map { window in
            let frame = window.frame
            return [
                "number": window.windowNumber,
                "title": window.title,
                "x": frame.minX,
                "y": primaryHeight - frame.maxY,
                "width": frame.width,
                "height": frame.height,
            ]
        }
        var report: [String: Any] = [
            "scale": scale,
            "windows": entries,
            "active": NSApp.isActive,
            "pid": ProcessInfo.processInfo.processIdentifier,
        ]
        if let screen = Self.targetScreen {
            // The visible frame: a capture must stop short of the menu bar,
            // which is the real one with the real status items on it.
            let frame = screen.visibleFrame
            report["screen"] = [
                "x": frame.minX,
                "y": primaryHeight - frame.maxY,
                "width": frame.width,
                "height": frame.height,
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: report),
              let line = String(data: data, encoding: .utf8)
        else { return }
        FileHandle.standardOutput.write(Data(("VIBEBAR_DEMO_WINDOWS " + line + "\n").utf8))
    }

    /// Where the popover's arrow points: the top edge of the backdrop, under
    /// the menu bar, horizontally centred. A status item would sit further
    /// right, but that corner is where notification banners land, and a
    /// banner over the popover is a ruined capture. Nil without a backdrop,
    /// in which case the popover anchors to the real status item.
    private var popoverAnchor: (view: NSView, rect: NSRect)? {
        guard let backdrop, let content = backdrop.contentView, let screen = backdrop.screen else { return nil }
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let x = content.bounds.midX
        let y = content.bounds.maxY - menuBarHeight
        return (content, NSRect(x: x, y: y, width: 1, height: 1))
    }

    private func open(_ surface: DemoMode.Surface) {
        switch surface {
        case let .popover(page):
            let resolved = page.isEmpty ? .overview : OverviewPage(rawValue: page)
            guard let resolved else { return warnUnknown(surface) }
            statusItem.presentPopoverForDemo(page: resolved, anchor: popoverAnchor)
        case let .miniWindow(mode):
            let resolved = mode.isEmpty ? .regular : MiniWindowDisplayMode(rawValue: mode)
            guard let resolved else { return warnUnknown(surface) }
            statusItem.presentMiniWindowForDemo(mode: resolved)
        case let .workbench(page):
            let resolved = page.isEmpty ? .usageStats : WorkbenchPage(rawValue: page)
            guard let resolved else { return warnUnknown(surface) }
            environment.showWorkbench(page: resolved)
        case let .settings(section):
            guard let destination = Self.settingsDestination(for: section) else { return warnUnknown(surface) }
            environment.showSettings(destination)
        }
    }

    /// `system`, `layout`, … name a section; `provider:<tool>` names a core
    /// or misc provider page by `ToolType` raw value.
    private static func settingsDestination(for identifier: String) -> SettingsDestination? {
        if identifier.isEmpty { return .page(.system) }
        if let section = SettingsSectionID(rawValue: identifier) { return .page(section) }
        guard identifier.hasPrefix("provider:") else { return nil }
        let rawTool = String(identifier.dropFirst("provider:".count))
        guard let tool = ToolType(rawValue: rawTool) else { return nil }
        return tool.isMisc ? .miscProvider(tool.rawValue) : .coreProvider(tool)
    }

    private func warnUnknown(_ surface: DemoMode.Surface) {
        SafeLog.warn("demo surface not recognised: \(surface)")
    }

    /// One borderless window covering the target screen at the normal level:
    /// above every other app while Vibe Bar is active, and tucked just below
    /// whichever surface demo mode opens (`tuckBackdropBehindSurfaces`).
    private func showBackdrop() {
        guard let screen = Self.targetScreen else { return }
        let window = BackdropWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.backgroundColor = Self.backdropColor(for: configuration.appearance)
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        backdrop = window
    }

    /// Flat, slightly cooler than the surfaces it sits under, so the popover's
    /// material reads as a card on a ground rather than vanishing into it.
    private static func backdropColor(for appearance: DemoMode.Appearance?) -> NSColor {
        let isDark: Bool
        if let appearance {
            isDark = appearance == .dark
        } else {
            isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        return isDark
            ? NSColor(srgbRed: 0.094, green: 0.098, blue: 0.114, alpha: 1)
            : NSColor(srgbRed: 0.886, green: 0.894, blue: 0.914, alpha: 1)
    }
}

/// A borderless window cannot become key, which is what the backdrop wants:
/// it is a ground, never a surface. Subclassed so the popover it anchors can
/// still be positioned relative to its content view.
private final class BackdropWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension NSScreen {
    /// The screen Vibe Bar sizes its surfaces against. `NSScreen.main` in
    /// production; in demo mode the display the presenter chose, so the
    /// popover's height and the mini window's default position agree with
    /// where the capture actually lands.
    @MainActor
    static var vibeBarPresentationScreen: NSScreen? {
        if DemoMode.isEnabled, let target = DemoPresenter.targetScreen { return target }
        return NSScreen.main
    }
}
