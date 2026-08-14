import AppKit
import VibeBarCore

/// Watches our own status item and speaks up when macOS is silently refusing to
/// show it.
///
/// On macOS 26, Control Center keeps a per-bundle-id menu-bar allow-list. A
/// stale entry belonging to *another* app the user hid — one whose
/// `menuItemLocations` still lists our bundle id — makes Control Center apply
/// that app's `isAllowed = false` to us. The symptom is maddening from the
/// user's side: the icon is simply gone, System Settings shows our Menu Bar
/// toggle as *on*, toggling it changes nothing, reinstalling and rebooting
/// change nothing, and no amount of reading our own source finds a bug —
/// because there isn't one. Without this check the only way to learn any of
/// that is to bisect it by hand.
///
/// We only diagnose. Fixing means editing a TCC-protected system plist, which
/// is not something an app should reach into behind the user's back.
@MainActor
final class MenuBarBlockWatchdog {
    /// Grace period before the first probe. AppKit needs a moment to place a
    /// freshly created item, and logging in with displays still settling can
    /// look blocked for a few seconds.
    private static let firstProbeDelay: TimeInterval = 20
    /// Probe cadence afterwards. The block can appear mid-session — Control
    /// Center rewrites those mappings when a hidden app re-registers its items
    /// — so this keeps running rather than checking once at launch.
    private static let probeInterval: TimeInterval = 120

    private weak var statusItem: NSStatusItem?
    private let settingsStore: SettingsStore
    private var evaluator = MenuBarBlockEvaluator()
    private var timer: Timer?
    /// Set after init so the handler can capture the watchdog itself — ticking
    /// "Don't check again" on the alert has to call back into `suppress()`.
    var onBlockConfirmed: (() -> Void)?

    init(statusItem: NSStatusItem, settingsStore: SettingsStore) {
        self.statusItem = statusItem
        self.settingsStore = settingsStore
    }

    func start() {
        guard !isSuppressed else { return }
        stop()
        let timer = Timer(
            timeInterval: Self.probeInterval,
            target: self,
            selector: #selector(probeFromTimer),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = Self.probeInterval / 4
        timer.fireDate = Date().addingTimeInterval(Self.firstProbeDelay)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Persisted in `AppSettings` (so under `~/.vibebar/`), not `UserDefaults`.
    var isSuppressed: Bool {
        settingsStore.settings.menuBarBlockAlertSuppressed
    }

    func suppress() {
        guard !settingsStore.settings.menuBarBlockAlertSuppressed else { return }
        settingsStore.settings.menuBarBlockAlertSuppressed = true
        stop()
    }

    @objc private func probeFromTimer() {
        probeOnce()
    }

    /// Exposed for a manual re-check; `start` drives the periodic case.
    func probeOnce() {
        // Re-read the flag on every probe rather than only when the timer was
        // created: the user can suppress from the alert itself, and the
        // evaluator re-arms after any recovery, so a still-running timer would
        // otherwise nag again on the next relapse.
        guard !isSuppressed else {
            stop()
            return
        }
        guard let statusItem, let probe = Self.sample(statusItem) else { return }
        guard evaluator.record(probe) else { return }
        SafeLog.warn(
            "Menu bar item appears blocked by the system "
                + "(height \(Int(probe.windowHeight)) vs bar \(Int(probe.menuBarHeights.min() ?? 0)), "
                + "occlusion hidden)"
        )
        onBlockConfirmed?()
    }

    private static func sample(_ item: NSStatusItem) -> MenuBarItemProbe? {
        let button = item.button
        let window = button?.window
        return MenuBarItemProbe(
            isVisible: item.isVisible,
            hasButton: button != nil,
            hasWindow: window != nil,
            occlusionVisible: window?.occlusionState.contains(.visible) ?? false,
            windowHeight: window?.frame.height ?? 0,
            statusBarThickness: NSStatusBar.system.thickness,
            menuBarHeights: menuBarHeights()
        )
    }

    /// Menu-bar height per screen, derived from the gap between each screen's
    /// full frame and its visible frame.
    ///
    /// `NSStatusBar.thickness` is one system-wide number (the legacy 22) and
    /// says nothing about the bar a given display actually draws — 39 on a
    /// notched built-in, 30 on an external here. The inset also drops to zero
    /// while a display runs a full-screen app, which is exactly the signal the
    /// detector needs to stay quiet in that case.
    private static func menuBarHeights() -> [CGFloat] {
        NSScreen.screens.compactMap { screen in
            let inset = screen.frame.maxY - screen.visibleFrame.maxY
            return inset > 0 ? inset : nil
        }
    }
}
