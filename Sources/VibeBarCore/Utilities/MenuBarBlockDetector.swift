import Foundation

/// One sample of what AppKit reports about our status item.
///
/// Kept as plain values so the verdict logic is testable without AppKit —
/// `StatusItemController` fills this in from `NSStatusItem` / `NSWindow`.
public struct MenuBarItemProbe: Equatable, Sendable {
    /// `NSStatusItem.isVisible` — what *we* asked for.
    public var isVisible: Bool
    /// Whether the status item still vends a button.
    public var hasButton: Bool
    /// Whether the button has been given a window (i.e. AppKit materialized it).
    public var hasWindow: Bool
    /// Whether the window's occlusion state contains `.visible` — what the
    /// *system* actually did with it.
    public var occlusionVisible: Bool
    /// Height of the status-item window.
    public var windowHeight: CGFloat
    /// `NSStatusBar.system.thickness` — the legacy 22pt default. A window left
    /// at exactly this height on a Mac whose bars are taller was never placed
    /// into any of them.
    public var statusBarThickness: CGFloat
    /// Menu-bar height of every screen that currently *has* a bar. Empty means
    /// no bar is on screen anywhere (full-screen app, auto-hiding bar), which
    /// makes an invisible status item unremarkable.
    public var menuBarHeights: [CGFloat]

    public init(
        isVisible: Bool,
        hasButton: Bool,
        hasWindow: Bool,
        occlusionVisible: Bool,
        windowHeight: CGFloat,
        statusBarThickness: CGFloat,
        menuBarHeights: [CGFloat]
    ) {
        self.isVisible = isVisible
        self.hasButton = hasButton
        self.hasWindow = hasWindow
        self.occlusionVisible = occlusionVisible
        self.windowHeight = windowHeight
        self.statusBarThickness = statusBarThickness
        self.menuBarHeights = menuBarHeights
    }
}

/// Verdict for a single probe.
public enum MenuBarProbeVerdict: Equatable, Sendable {
    /// The item is on screen, or nothing suggests otherwise.
    case healthy
    /// The item is hidden right now, but for a reason that is none of our
    /// business — auto-hiding menu bar, full-screen app, locked screen. Those
    /// look identical from here, so they only reset the streak.
    case inconclusive
    /// The system materialized the window but parked it at a stub height and
    /// never made it visible. On macOS 26 this is what a Control Center
    /// allow-list block looks like.
    case blocked
}

/// Detects the macOS 26 "status item silently blocked by Control Center"
/// state.
///
/// Background: Control Center keeps a per-bundle-id allow-list
/// (`trackedApplications` in the `group.com.apple.controlcenter` group
/// container). A stale cross-app entry — another app that the user hid, whose
/// `menuItemLocations` still references *our* bundle id — makes Control Center
/// apply that app's `isAllowed = false` to us. The item then never reaches the
/// menu bar even though `isVisible` is `true`, System Settings shows our
/// toggle as on, and nothing in our code is wrong.
///
/// The signature, measured on macOS 26.x with a notched built-in (39pt bar) and
/// an external display (30pt bar):
///
/// - healthy: window height matches the bar it sits in (30), occlusion contains
///   `.visible`
/// - blocked: window height stuck at `NSStatusBar.thickness` (22) — the legacy
///   default, shorter than any bar on this Mac — with occlusion *without*
///   `.visible`, persisting indefinitely
///
/// Two candidate signals were measured and rejected. `window.screen` is `nil`
/// only while an item is still being placed; a blocked window reports a screen
/// like a healthy one. And a bare "occlusion says hidden" test fires for every
/// full-screen app and auto-hiding menu bar, so hiding alone means nothing —
/// it has to come with the stub height.
public struct MenuBarBlockDetector: Sendable {
    /// Margin between the stub height and a real bar before we trust the gap.
    public static let stubHeightTolerance: CGFloat = 2
    /// Below this a bar is too short to distinguish from the 22pt stub, so we
    /// decline to guess rather than risk nagging.
    public static let minimumTrustworthyBarHeight: CGFloat = 24
    /// Consecutive `blocked` probes before we surface anything. Launch, login,
    /// and display reconfiguration all look blocked for a few seconds.
    public static let confirmationsRequired = 3

    public init() {}

    public func verdict(for probe: MenuBarItemProbe) -> MenuBarProbeVerdict {
        // We never asked for it, or AppKit hasn't built it yet: not our case.
        guard probe.isVisible, probe.hasButton, probe.hasWindow else {
            return .inconclusive
        }
        // The system is showing it. Nothing to report.
        if probe.occlusionVisible {
            return .healthy
        }
        // A missing bar on *any* screen means a full-screen app or an
        // auto-hiding bar is in play there, and an invisible status item —
        // which may well live on that very display — says nothing about a
        // block. Zero insets are kept in the sample so this can be seen.
        //
        // Compared against the *shortest* bar on purpose. A display whose bar
        // is itself 22pt would make a correctly placed item indistinguishable
        // from a stub, and taking the tallest bar would convict it — so the
        // shortest bar both picks the safe comparison and lets the guard below
        // bail out entirely on such a setup.
        guard let shortestBar = probe.menuBarHeights.min(),
              shortestBar >= Self.minimumTrustworthyBarHeight else {
            return .inconclusive
        }
        // A window that was placed into a bar is as tall as that bar, even
        // while something covers it. One still sitting at the legacy default,
        // on a Mac whose bars are all taller, was never placed at all.
        let isStub = probe.windowHeight <= probe.statusBarThickness
            && probe.windowHeight + Self.stubHeightTolerance < shortestBar
        return isStub ? .blocked : .inconclusive
    }
}

/// Accumulates verdicts so a single transient sample can't fire an alert.
///
/// `record` returns `true` exactly once per streak — on the probe that reaches
/// `confirmationsRequired` — so the caller can alert without tracking whether
/// it already did.
public struct MenuBarBlockEvaluator: Sendable {
    private let detector: MenuBarBlockDetector
    private let confirmationsRequired: Int
    private(set) public var consecutiveBlocked: Int = 0
    private(set) public var hasReported: Bool = false

    public init(
        detector: MenuBarBlockDetector = MenuBarBlockDetector(),
        confirmationsRequired: Int = MenuBarBlockDetector.confirmationsRequired
    ) {
        self.detector = detector
        self.confirmationsRequired = confirmationsRequired
    }

    /// Feeds one probe in. Returns `true` when this probe is the one that
    /// confirms a block for the first time.
    public mutating func record(_ probe: MenuBarItemProbe) -> Bool {
        switch detector.verdict(for: probe) {
        case .healthy:
            // Recovered — re-arm so a later relapse reports again. The block
            // does come back: Control Center rebuilds those mappings whenever
            // a hidden app's menu-bar items are re-registered.
            consecutiveBlocked = 0
            hasReported = false
            return false
        case .inconclusive:
            consecutiveBlocked = 0
            return false
        case .blocked:
            consecutiveBlocked += 1
            guard consecutiveBlocked >= confirmationsRequired, !hasReported else {
                return false
            }
            hasReported = true
            return true
        }
    }
}
