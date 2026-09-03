import AppKit
import SwiftUI
import Combine
import VibeBarCore

private enum MenuBarStatusMetrics {
    static let twoRowFontSize: CGFloat = 9
    static let twoRowColumnSpacing: CGFloat = 8
    static let twoRowLineSpacing: CGFloat = -2
    static let twoRowHorizontalPadding: CGFloat = 2
    static let twoRowVerticalPadding: CGFloat = 1
    static let minimumTwoRowLength: CGFloat = 24
    static let twoRowContentIdentifier = NSUserInterfaceItemIdentifier("VibeBarTwoRowStatusContent")
    /// Manually drawn beside the text in each ~10pt row band; see
    /// `twoRowImage` — text attachments cannot be used at this size.
    static let twoRowLogoSide: CGFloat = 8
    static let twoRowLogoGap: CGFloat = 2
}

/// One cell of the rasterized two-row status image, drawn left to right.
///
/// A composed row can put a logo anywhere — between two words, at the end —
/// so a cell is a run list rather than one optional leading logo. Logos stay
/// out of the attributed strings on purpose: the two-row canvas is about 10pt
/// per band and a text attachment inflates its line box to 14pt no matter what
/// bounds it declares, which pushes the second row out of the bar.
private struct TwoRowMenuCell {
    enum Run {
        case logo(NSImage)
        case text(NSAttributedString)
    }

    var runs: [Run]

    init(runs: [Run]) {
        self.runs = runs
    }

    init(text: NSAttributedString, logo: NSImage? = nil) {
        var runs: [Run] = []
        if let logo { runs.append(.logo(logo)) }
        runs.append(.text(text))
        self.runs = runs
    }

    var isEmpty: Bool { runs.isEmpty }
}

private struct TwoRowMenuColumn {
    var top: TwoRowMenuCell
    var bottom: TwoRowMenuCell?
}

/// One percentage the status item draws, with the color it earned on its own.
/// A merged piece carries several: the group's windows keep their individual
/// verdict colors even though they share a label.
private struct MenuBarPercentValue {
    var value: Double
    var color: NSColor
}

/// One rendered menu-bar entry, resolved once per render and consumed by
/// whichever layout is active. A merged group contributes a single piece with
/// several `percents`; every other field contributes a piece with one.
private struct MenuBarPiece {
    var label: String?
    var percents: [MenuBarPercentValue]
    var tool: ToolType
    var style: MenuBarFieldStyle
    /// Every quota window spelled out separately — never the merged
    /// `5%/100%` shorthand. Feeds the tooltip and the accessibility label.
    var spokenDescription: String
}

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private static let initialPopoverHeight: CGFloat = 720
    private static let minimumPopoverHeight: CGFloat = 460
    private static let popoverHeightPadding: CGFloat = 12
    /// How long after a popover closes we treat the next status-item click
    /// as the click that *caused* the close. NSPopover with `.transient`
    /// behavior auto-dismisses on outside clicks, and the status item button
    /// counts as outside — so without this guard a second click on the same
    /// item would close-then-reopen instead of just closing.
    private static let popoverReopenSuppressionWindow: TimeInterval = 0.2

    /// Demo mode anchors its popover to a private backdrop view and must not
    /// register a second system status item under the production bundle id —
    /// doing so makes Control Center rebuild the very cross-app mapping this
    /// app has to repair. Production always has one.
    private var compactStatusItem: NSStatusItem?
    private var popovers: [MenuBarItemKind: NSPopover] = [:]
    /// Whether any popover is on screen, published into every popover tree so
    /// its page-level clocks can stop ticking while it is hidden. The hosting
    /// controllers stay cached either way — this gates work, not lifetime.
    private let popoverPresentation = PopoverPresentation()
    private let environment: AppEnvironment
    private let miniWindowController: MiniQuotaWindowController
    private var cancellables: Set<AnyCancellable> = []
    private var lastObservedDensities: [MenuBarItemKind: PopoverDensity]
    /// Records the time each kind's popover most recently started closing.
    /// Used by `togglePopover` to ignore the click that triggered the close.
    private var popoverCloseStamps: [MenuBarItemKind: Date] = [:]
    /// Coalescing state for `resizePopover`.
    private var lastPopoverResizeAt: [MenuBarItemKind: Date] = [:]
    private var pendingPopoverHeights: [MenuBarItemKind: CGFloat] = [:]
    private var popoverResizeTasks: [MenuBarItemKind: Task<Void, Never>] = [:]
    /// Notices when macOS silently refuses to place our status item. See
    /// `MenuBarBlockWatchdog` — the failure is invisible from inside the app
    /// otherwise, and looks exactly like "the app didn't launch".
    private var blockWatchdog: MenuBarBlockWatchdog?
    /// Tab the next popover is built on. Overview outside demo mode.
    private var popoverInitialPage: OverviewPage = .overview
    /// Rendered brand-logo images keyed by tool, point size, and appearance —
    /// see `brandAttachment(for:fontSize:font:)`.
    private var brandAttachmentImages: [String: NSImage?] = [:]

    init(environment: AppEnvironment) {
        self.environment = environment
        self.miniWindowController = MiniQuotaWindowController()
        self.lastObservedDensities = Self.snapshotDensities(environment.settingsStore.settings)
        self.compactStatusItem = DemoMode.isEnabled
            ? nil
            : NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let compactStatusItem {
            configureButton(for: .compact, item: compactStatusItem)
        }
        observeChanges()
        // The menu bar's appearance flips with the system theme while the
        // app keeps running; rasterized logo tints must follow immediately,
        // not on the next quota publish.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.brandAttachmentImages.removeAll()
                self.renderMenuBar()
            }
        }
        renderMenuBar()
        // Restore mini windows the user had open last session.
        miniWindowController.restoreIfNeeded(environment: environment)
        // Settings' "Open / Close" button reaches the panels through this
        // notification — the controller is private to this object.
        NotificationCenter.default.addObserver(
            forName: .vibeBarToggleMiniWindow,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?["configID"] as? String
            Task { @MainActor in
                guard let self else { return }
                if let raw, let id = UUID(uuidString: raw) {
                    self.toggleMiniWindow(configID: id)
                } else {
                    self.toggleMiniWindow()
                }
            }
        }
        // Warm the one unified popover after launch so the first open is
        // immediate without keeping retired standalone trees alive.
        DispatchQueue.main.async { [weak self] in
            _ = self?.popover(for: .compact)
        }
        if let compactStatusItem {
            let watchdog = MenuBarBlockWatchdog(
                statusItem: compactStatusItem,
                settingsStore: environment.settingsStore
            )
            watchdog.onBlockConfirmed = { [weak watchdog, weak environment] in
                guard let environment else { return }
                if environment.settingsStore.settings.menuBarAutoRepairEnabled {
                    Task { @MainActor in
                        let outcome = await environment.repairMenuBarAllowList()
                        if outcome.succeeded {
                            SafeLog.info("Menu bar allow-list auto-repair completed")
                        } else {
                            SafeLog.warn("Menu bar allow-list auto-repair failed")
                            MenuBarBlockAlert.present { watchdog?.suppress() }
                        }
                    }
                } else {
                    MenuBarBlockAlert.present { watchdog?.suppress() }
                }
            }
            watchdog.start()
            blockWatchdog = watchdog
            environment.registerMenuBarHealth(
                watchdog: watchdog,
                reregister: { [weak self] in self?.reregisterMenuBarItem() }
            )
        } else if DemoMode.isEnabled {
            // A synthetic, non-system probe keeps the Menu Bar Health demo
            // page fully representative without creating the duplicate
            // NSStatusItem that used to corrupt the live allow-list.
            let watchdog = MenuBarBlockWatchdog(
                statusItem: nil,
                settingsStore: environment.settingsStore
            )
            watchdog.checkNow()
            blockWatchdog = watchdog
            environment.registerMenuBarHealth(watchdog: watchdog, reregister: {})
        }
    }

    private func currentPopoverWidth(for kind: MenuBarItemKind) -> CGFloat {
        let settings = environment.settingsStore.settings
        // Every tab uses the same density profile and the same stable window
        // width. Page switches therefore never reflow the popover.
        return max(
            Theme.overviewDensity(for: settings.popoverDensity).popoverWidth,
            Theme.detailDensity(for: settings.popoverDensity).popoverWidth
        )
    }

    private static func snapshotDensities(_ settings: AppSettings) -> [MenuBarItemKind: PopoverDensity] {
        [.compact: settings.popoverDensity]
    }

    private static func makePopover(
        kind: MenuBarItemKind,
        environment: AppEnvironment,
        controller: StatusItemController,
        width: CGFloat
    ) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = controller
        popover.contentSize = NSSize(width: width, height: initialPopoverHeight)
        popover.contentViewController = NSHostingController(
            rootView: PopoverRoot(
                width: width,
                onContentHeightChange: { [weak controller] height in controller?.resizePopover(kind: kind, toContentHeight: height) },
                onToggleMiniWindow: { [weak controller] in controller?.toggleMiniWindow() },
                initialPage: controller.popoverInitialPage
            )
                .vibeBarNoInitialFocus()
                // While a shrink waits out its settle window the hosting view
                // is briefly taller than the content; without an explicit top
                // anchor NSHostingView centers the shorter content and the
                // whole page appears to hop.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .environmentObject(environment)
                .environmentObject(environment.accountStore)
                .environmentObject(environment.settingsStore)
                .environmentObject(environment.quotaService)
                .environmentObject(environment.serviceStatus)
                .environmentObject(environment.costService)
                .environmentObject(environment.remoteProbeService)
                .environmentObject(environment.pageLayout)
                .environmentObject(controller.popoverPresentation)
                // Also handed over as an environment *value*: `PageClock`
                // reads it that way so a view that ends up in a non-popover
                // host (mini window, Workbench, Settings) gets the
                // always-visible default instead of trapping on a missing
                // `@EnvironmentObject`.
                .environment(\.popoverPresentation, controller.popoverPresentation)
        )
        return popover
    }

    private func configureButton(for kind: MenuBarItemKind, item: NSStatusItem) {
        guard let button = item.button else { return }
        button.action = #selector(togglePopover(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.image = nil
        button.imagePosition = .noImage
        button.alignment = .center
        button.lineBreakMode = .byClipping
        button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        button.tag = statusItemTag(for: kind)
        button.toolTip = "\(kind.label) quota"
    }

    private func observeChanges() {
        // Density changes invalidate cached popovers — keep that on its own
        // settings sink so the work happens immediately, not after the
        // throttle window.
        environment.settingsStore.$settings
            .receive(on: RunLoop.main)
            .sink { [weak self] settings in
                self?.invalidatePopoversIfDensitiesChanged(Self.snapshotDensities(settings))
            }
            .store(in: &cancellables)

        // Coalesce all render triggers into one throttled pipeline so a burst
        // of quota, settings, account, and status updates only redraws once.
        //
        // Observations, cycle history, and cost snapshots are in the set
        // because forecast coloring depends on them, and they land *after*
        // `$lastSuccessByAccount` — a refresh publishes the new quota first and
        // records the observation in a follow-up task. Without them the color
        // would always describe the previous refresh. The extra churn is
        // bounded: observations publish once per account per refresh.
        let renderTriggers: [AnyPublisher<Void, Never>] = [
            environment.settingsStore.$settings.map { _ in () }.eraseToAnyPublisher(),
            environment.quotaService.$lastSuccessByAccount.map { _ in () }.eraseToAnyPublisher(),
            environment.quotaService.$lastErrorByAccount.map { _ in () }.eraseToAnyPublisher(),
            environment.quotaService.$observationsByAccountBucket.map { _ in () }.eraseToAnyPublisher(),
            environment.quotaService.$historyByAccountBucket.map { _ in () }.eraseToAnyPublisher(),
            environment.costService.$snapshots.map { _ in () }.eraseToAnyPublisher(),
            environment.accountStore.$accounts.map { _ in () }.eraseToAnyPublisher(),
            environment.serviceStatus.$snapshotByTool.map { _ in () }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(renderTriggers)
            .throttle(for: .milliseconds(120), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.renderMenuBar() }
            .store(in: &cancellables)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = sender as? NSStatusBarButton else { return }
        let kind = kindForTag(button.tag)
        if shouldShowContextMenu(for: NSApp.currentEvent) {
            showContextMenu(for: kind, button: button)
            return
        }
        let popover = popover(for: kind)
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        // If this popover closed within the last few hundred ms, the click
        // that just landed on the status item is the same click that
        // triggered the transient close — skip the reopen so the user gets
        // proper click-to-toggle behavior.
        if let closedAt = popoverCloseStamps[kind],
           Date().timeIntervalSince(closedAt) < Self.popoverReopenSuppressionWindow {
            popoverCloseStamps.removeValue(forKey: kind)
            return
        }
        openPopover(popover, kind: kind, anchoredTo: button)
    }

    /// Open the compact popover as a click on its status item would. The
    /// setup assistant calls this on Finish, so the first thing a new user
    /// sees after setup is the readout they installed the app for.
    func presentCompactPopover() {
        guard let button = compactStatusItem?.button else { return }
        let popover = popover(for: .compact)
        guard !popover.isShown else { return }
        openPopover(popover, kind: .compact, anchoredTo: button)
    }

    private func openPopover(_ popover: NSPopover, kind: MenuBarItemKind, anchoredTo button: NSStatusBarButton) {
        // Close any other open popover first to keep behavior consistent.
        for (otherKind, other) in popovers where otherKind != kind && other.isShown {
            other.performClose(nil)
        }
        let settings = environment.settingsStore.settings
        let scheduledFullRefresh = environment.scheduler.triggerRefreshForPopoverOpenIfNeeded(
            enabled: settings.refreshOnPopoverOpen,
            cooldownSeconds: settings.popoverOpenRefreshCooldownSeconds
        )
        if !scheduledFullRefresh {
            environment.scheduler.triggerRefreshForStaleCacheIfNeeded()
        }
        // Set before `show`: the refresh above publishes into the popover's own
        // render pass, and anything that would rather not compete with it (the
        // hidden Claude budget WebView) checks this flag.
        environment.setPopoverVisible(true)
        popoverPresentation.isShown = true
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    nonisolated func popoverWillClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for (kind, candidate) in self.popovers where candidate === popover {
                self.popoverCloseStamps[kind] = Date()
                break
            }
            let anyOtherShown = self.popovers.values.contains { $0.isShown && $0 !== popover }
            self.environment.setPopoverVisible(anyOtherShown)
            self.popoverPresentation.isShown = anyOtherShown
        }
    }

    private func popover(for kind: MenuBarItemKind) -> NSPopover {
        if let popover = popovers[kind] {
            return popover
        }
        let popover = Self.makePopover(
            kind: kind,
            environment: environment,
            controller: self,
            width: currentPopoverWidth(for: kind)
        )
        popovers[kind] = popover
        return popover
    }

    private func invalidatePopoversIfDensitiesChanged(_ newDensities: [MenuBarItemKind: PopoverDensity]) {
        var changed: [MenuBarItemKind] = []
        for (kind, density) in newDensities {
            if lastObservedDensities[kind] != density {
                changed.append(kind)
            }
        }
        guard !changed.isEmpty else { return }
        lastObservedDensities = newDensities
        for kind in changed {
            if let popover = popovers[kind], popover.isShown {
                popover.performClose(nil)
            }
            popovers.removeValue(forKey: kind)
        }
    }

    /// Height reports arrive per layout pass, and a refresh relayouts the
    /// popover many times in a row — every one of which used to write
    /// `contentSize`, which itself forces another layout pass and another
    /// report. Apply the first report of a burst immediately (so opening the
    /// popover still sizes without a visible delay) and coalesce the rest into
    /// one trailing resize, which lands on the final height.
    private static let popoverResizeCoalesceWindow: TimeInterval = 0.1

    /// A *shrink* is additionally never applied while the popover is on
    /// screen until it has survived this window. Reopening the popover or
    /// switching pages makes SwiftUI's first layout pass report a transiently
    /// tiny height — the cards have not measured yet — and applying that
    /// report snapped the visible popover down to `minimumPopoverHeight`
    /// before the settled height arrived a beat later: the "page reflows to
    /// minimum height" bounce. A transient dip is superseded by its recovery
    /// report inside this window and never touches the frame; a real shrink
    /// survives it and lands once, at the settled value.
    private static let popoverShrinkSettleWindow: TimeInterval = 0.35

    /// Kinds whose pending resize task is a shrink hold (as opposed to an
    /// ordinary trailing coalesce): a growth report cancels these instead of
    /// waiting out their longer deadline.
    private var popoverShrinkHoldKinds: Set<MenuBarItemKind> = []

    private func resizePopover(kind: MenuBarItemKind, toContentHeight height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        if let popover = popovers[kind], popover.isShown {
            let target = resolvedPopoverHeight(
                forContentHeight: height,
                maxHeight: maxPopoverHeight(for: popover)
            )
            let current = popover.contentSize
            switch PopoverResizeGate.verdict(
                currentHeight: current.height,
                targetHeight: target,
                currentWidth: current.width,
                targetWidth: currentPopoverWidth(for: kind)
            ) {
            case .ignore:
                // The content walked back to the on-screen size — nothing to
                // change, and nothing a stale trailing task may restore.
                cancelPendingPopoverResize(kind: kind)
                return
            case .holdForSettle:
                cancelPendingPopoverResize(kind: kind)
                popoverShrinkHoldKinds.insert(kind)
                pendingPopoverHeights[kind] = height
                scheduleCoalescedResize(kind: kind, after: Self.popoverShrinkSettleWindow)
                return
            case .applyNow:
                // A held shrink must not outlive the growth that supersedes
                // it: left in place, its 350ms task would swallow this report
                // into its own deadline and the popover would sit undersized
                // for the rest of the hold. Cancel it so the growth goes
                // through the ordinary burst path below.
                if popoverShrinkHoldKinds.contains(kind) {
                    cancelPendingPopoverResize(kind: kind)
                }
            }
        }
        let sinceLast = lastPopoverResizeAt[kind].map { Date().timeIntervalSince($0) }
        if let sinceLast, sinceLast < Self.popoverResizeCoalesceWindow {
            pendingPopoverHeights[kind] = height
            scheduleCoalescedResize(
                kind: kind,
                after: Self.popoverResizeCoalesceWindow - sinceLast
            )
            return
        }
        // A trailing task may still be queued from the previous burst — on a
        // busy main actor it can wake after its deadline, land here *after*
        // this newer report, and resize the popover back to the stale height
        // it captured. Supersede both the task and its pending height.
        cancelPendingPopoverResize(kind: kind)
        applyPopoverResize(kind: kind, toContentHeight: height)
    }

    private func cancelPendingPopoverResize(kind: MenuBarItemKind) {
        popoverResizeTasks.removeValue(forKey: kind)?.cancel()
        pendingPopoverHeights.removeValue(forKey: kind)
        popoverShrinkHoldKinds.remove(kind)
    }

    private func scheduleCoalescedResize(kind: MenuBarItemKind, after delay: TimeInterval) {
        guard popoverResizeTasks[kind] == nil else { return }
        popoverResizeTasks[kind] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(max(10, delay * 1_000))))
            // Checked before touching shared state: an immediate resize may
            // have superseded this task and re-registered a fresh one, whose
            // bookkeeping a cancelled sleeper must not clobber.
            guard let self, !Task.isCancelled else { return }
            self.popoverResizeTasks[kind] = nil
            self.popoverShrinkHoldKinds.remove(kind)
            guard let height = self.pendingPopoverHeights.removeValue(forKey: kind) else { return }
            self.applyPopoverResize(kind: kind, toContentHeight: height)
        }
    }

    /// One resolution for both the gate and the apply, so the two can never
    /// disagree about what a content height means for the visible frame.
    private func resolvedPopoverHeight(forContentHeight height: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let resolved = min(max(height + Self.popoverHeightPadding, Self.minimumPopoverHeight), maxHeight)
        return (resolved / 2).rounded() * 2
    }

    private func applyPopoverResize(kind: MenuBarItemKind, toContentHeight height: CGFloat) {
        lastPopoverResizeAt[kind] = Date()
        guard let popover = popovers[kind] else { return }
        guard height.isFinite, height > 0 else { return }
        let targetHeight = resolvedPopoverHeight(
            forContentHeight: height,
            maxHeight: maxPopoverHeight(for: popover)
        )
        let width = currentPopoverWidth(for: kind)
        let current = popover.contentSize
        guard abs(current.height - targetHeight) > 1 || abs(current.width - width) > 1 else {
            return
        }
        popover.contentSize = NSSize(width: width, height: targetHeight)
    }

    private func maxPopoverHeight(for popover: NSPopover) -> CGFloat {
        let screen = popover.contentViewController?.view.window?.screen ?? NSScreen.vibeBarPresentationScreen
        let visibleHeight = screen?.visibleFrame.height ?? 900
        return max(Self.minimumPopoverHeight, visibleHeight - 80)
    }

    private func kindForTag(_ tag: Int) -> MenuBarItemKind {
        .compact
    }

    private func toggleMiniWindow() {
        miniWindowController.toggleAll(environment: environment)
    }

    private func toggleMiniWindow(configID: UUID) {
        miniWindowController.toggle(configID: configID, environment: environment)
    }

    // MARK: - Demo mode

    /// Open the popover on `page` without a click. Demo mode only: it skips
    /// the refresh a real open triggers, and rebuilds the cached popover so
    /// the requested tab is the one it starts on.
    ///
    /// The status item's button sits in the menu bar of whichever display
    /// the pointer last touched, which is not something a capture run can
    /// control. An `anchor` — a rect in a view on the display the presenter
    /// chose — pins the popover there instead; it is the same `NSPopover`
    /// with the same arrow, pointing at the top of the backdrop exactly
    /// where the menu bar item would be.
    func presentPopoverForDemo(page: OverviewPage, anchor: (view: NSView, rect: NSRect)? = nil) {
        guard DemoMode.isEnabled else { return }
        let target: (view: NSView, rect: NSRect)
        if let anchor {
            target = anchor
        } else if let button = compactStatusItem?.button {
            target = (button, button.bounds)
        } else {
            return
        }
        popoverInitialPage = page
        if let existing = popovers.removeValue(forKey: .compact) {
            existing.performClose(nil)
        }
        let popover = popover(for: .compact)
        // A transient popover closes the moment another app activates, and a
        // capture run cannot promise nothing else on the Mac will. This one
        // stays until the process exits.
        popover.behavior = .applicationDefined
        environment.setPopoverVisible(true)
        popoverPresentation.isShown = true
        popover.show(relativeTo: target.rect, of: target.view, preferredEdge: .minY)
        // Key status would hand keyboard focus to the first button;
        // `vibeBarNoInitialFocus()` on the popover root clears that initial
        // selection in demo and production alike.
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Show the first mini window in `mode`. Demo mode only.
    func presentMiniWindowForDemo(mode: MiniWindowDisplayMode) {
        guard DemoMode.isEnabled else { return }
        var settings = environment.settingsStore.settings
        if let index = settings.miniWindow.windows.indices.first,
           settings.miniWindow.windows[index].displayMode != mode {
            settings.miniWindow.windows[index].displayMode = mode
            environment.settingsStore.settings = settings
        }
        miniWindowController.presentForDemo(environment: environment)
    }

    private func shouldShowContextMenu(for event: NSEvent?) -> Bool {
        guard let event else { return false }
        return event.type == .rightMouseUp || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
    }

    private func showContextMenu(for kind: MenuBarItemKind, button: NSStatusBarButton) {
        for popover in popovers.values where popover.isShown {
            popover.performClose(nil)
        }
        let menu = contextMenu(for: kind)
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        } else {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
        }
    }

    private func contextMenu(for kind: MenuBarItemKind) -> NSMenu {
        let menu = NSMenu(title: "Vibe Bar")
        menu.autoenablesItems = false

        menu.addItem(disabledMenuItem("Vibe Bar - \(kind.label)"))
        if let updated = contextUpdatedLine(for: kind) {
            menu.addItem(disabledMenuItem(updated))
        }
        menu.addItem(.separator())
        menu.addItem(disabledMenuItem("Usage"))
        for tool in ToolType.dedicatedCardProviders {
            for line in usageMenuLines(for: tool) {
                menu.addItem(disabledMenuItem(line))
            }
        }
        menu.addItem(.separator())
        menu.addItem(disabledMenuItem("Service Status"))
        for tool in ToolType.combinedStatusPageProviders {
            menu.addItem(disabledMenuItem(statusSummaryLine(for: tool)))
        }
        menu.addItem(.separator())
        menu.addItem(actionMenuItem("Refresh", action: #selector(refreshFromContextMenu(_:)), keyEquivalent: "r"))
        addMiniWindowMenuItems(to: menu)
        menu.addItem(actionMenuItem("Open Workbench", action: #selector(openWorkbenchFromContextMenu(_:))))
        menu.addItem(actionMenuItem("Open Settings", action: #selector(openSettingsFromContextMenu(_:)), keyEquivalent: ","))
        let updateItem = actionMenuItem(
            "Check for Updates…",
            action: #selector(checkForUpdatesFromContextMenu(_:))
        )
        updateItem.isEnabled = environment.updateController.canCheckForUpdates
        menu.addItem(updateItem)
        menu.addItem(.separator())
        menu.addItem(actionMenuItem("Quit", action: #selector(quitFromContextMenu(_:)), keyEquivalent: "q"))
        return menu
    }

    private func contextTools(for kind: MenuBarItemKind) -> [ToolType] {
        ToolType.dedicatedCardProviders
    }

    private func contextUpdatedLine(for kind: MenuBarItemKind) -> String? {
        let dates = contextTools(for: kind)
            .compactMap { environment.account(for: $0) }
            .compactMap { environment.quotaService.lastUpdatedByAccount[$0.id] }
        guard let latest = dates.max() else { return nil }
        return ResetCountdownFormatter.updatedAgo(from: latest, now: Date())
    }

    private func usageMenuLines(for tool: ToolType) -> [String] {
        guard let quota = environment.quota(for: tool) else {
            return ["\(tool.displayName): No quota data"]
        }
        guard !quota.buckets.isEmpty else {
            return ["\(tool.displayName): No quota data"]
        }
        return quota.buckets.map { bucket in
            let percent = Int(bucket.remainingPercent.rounded())
            return "\(tool.displayName) - \(fullUsageName(for: bucket)): \(percent)% available"
        }
    }

    private func fullUsageName(for bucket: QuotaBucket) -> String {
        let title = bucket.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = bucket.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let group, !group.isEmpty else {
            return title.isEmpty ? "Usage" : title
        }
        guard !title.isEmpty else {
            return group
        }
        if title.localizedCaseInsensitiveContains(group) {
            return title
        }
        return "\(group) \(title)"
    }

    private func statusSummaryLine(for tool: ToolType) -> String {
        let projection = environment.serviceStatus.projection(for: tool)
        if projection.isRefreshing {
            return "\(tool.statusProviderName) · Checking"
        }
        if projection.error != nil {
            return "\(tool.statusProviderName) · Down"
        }
        guard let snapshot = projection.snapshot else {
            return "\(tool.statusProviderName) · Checking"
        }
        let label: String
        switch snapshot.effectiveIndicator {
        case .none:        label = "Up"
        case .maintenance: label = "Maintenance"
        case .minor,
             .major,
             .critical:    label = "Down"
        }
        if snapshot.aggregateUptimePercent > 0 {
            return "\(tool.statusProviderName) · \(label) · \(String(format: "%.2f%%", snapshot.aggregateUptimePercent))"
        }
        return "\(tool.statusProviderName) · \(label)"
    }

    private func disabledMenuItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionMenuItem(_ title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.isEnabled = true
        return item
    }

    @objc private func refreshFromContextMenu(_ sender: NSMenuItem) {
        environment.refreshAll()
    }

    @objc private func toggleMiniFromContextMenu(_ sender: NSMenuItem) {
        toggleMiniWindow()
    }

    /// One item when a single mini window is configured; a submenu listing
    /// each window (checkmarked while open) plus Toggle All when there are
    /// several.
    private func addMiniWindowMenuItems(to menu: NSMenu) {
        let windows = environment.settingsStore.settings.miniWindow.windows
        guard windows.count > 1 else {
            menu.addItem(actionMenuItem("Open Mini Window", action: #selector(toggleMiniFromContextMenu(_:))))
            return
        }
        let parent = NSMenuItem(title: "Mini Windows", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for config in windows {
            let item = NSMenuItem(
                title: "\(config.name) — \(config.displayMode.label)",
                action: #selector(toggleMiniWindowFromContextMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = config.id.uuidString
            item.state = miniWindowController.isVisible(configID: config.id) ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let all = NSMenuItem(title: "Toggle All", action: #selector(toggleMiniFromContextMenu(_:)), keyEquivalent: "")
        all.target = self
        submenu.addItem(all)
        parent.submenu = submenu
        menu.addItem(parent)
    }

    @objc private func toggleMiniWindowFromContextMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        toggleMiniWindow(configID: id)
    }

    @objc private func openWorkbenchFromContextMenu(_ sender: NSMenuItem) {
        environment.showWorkbench()
    }

    @objc private func openSettingsFromContextMenu(_ sender: NSMenuItem) {
        environment.showSettingsWindow()
    }

    @objc private func checkForUpdatesFromContextMenu(_ sender: NSMenuItem) {
        environment.updateController.checkForUpdates()
    }

    @objc private func quitFromContextMenu(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate() {
        miniWindowController.applicationWillTerminate()
        blockWatchdog?.stop()
    }

    /// Recreate only the AppKit status item after Control Center's allow-list
    /// has been repaired. The app process, MCP socket, and every stdio bridge
    /// stay alive; this is the in-process equivalent of the old quit/reopen
    /// instruction.
    private func reregisterMenuBarItem() {
        guard !DemoMode.isEnabled else { return }
        for popover in popovers.values where popover.isShown {
            popover.performClose(nil)
        }
        popovers.removeAll()
        if let compactStatusItem {
            NSStatusBar.system.removeStatusItem(compactStatusItem)
        }
        let replacement = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        compactStatusItem = replacement
        configureButton(for: .compact, item: replacement)
        renderMenuBar()
        blockWatchdog?.replaceStatusItem(replacement)
    }

    // MARK: - Menu bar text

    private func renderMenuBar() {
        let settings = environment.settingsStore.settings
        let allHidden = MenuBarItemKind.allCases.allSatisfy { !settings.menuBarItem($0).isVisible }
        for kind in MenuBarItemKind.allCases {
            guard let item = statusItem(for: kind) else { continue }
            let itemSettings = settings.menuBarItem(kind)
            item.isVisible = allHidden ? kind == .compact : itemSettings.isVisible
            guard let button = item.button else { continue }
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
            button.image = nil
            button.imagePosition = .noImage
            removeTwoRowStatusContent(from: button)
            // Custom mode replaces the field walk outright — the composition
            // owns its own rows, so it also supersedes `layout`. Everything
            // the field path stores stays untouched underneath it.
            if let composition = itemSettings.composition, composition.isEnabled {
                installComposedContent(
                    composition,
                    in: button,
                    item: item,
                    kind: kind,
                    itemSettings: itemSettings,
                    settings: settings
                )
                continue
            }
            // Resolved once and shared by every layout: the field walk, the
            // group merge, the bucket lookups, and the forecast colors all
            // happen here rather than inside each builder.
            let pieces = itemSettings.layout == .iconOnly
                ? []
                : menuBarPieces(for: itemSettings, settings: settings)
            switch itemSettings.layout {
            case .iconOnly:
                installIconOnlyContent(in: button, item: item, kind: kind)
            case .singleLine:
                button.attributedTitle = singleLineMenuTitle(pieces: pieces, itemSettings: itemSettings)
                item.length = NSStatusItem.variableLength
                applyStatusDescription(pieces, to: button, kind: kind)
            case .twoRows:
                installTwoRowImageContent(
                    in: button,
                    item: item,
                    columns: twoRowMenuColumns(pieces: pieces, itemSettings: itemSettings)
                )
                applyStatusDescription(pieces, to: button, kind: kind)
            case .compact:
                button.attributedTitle = compactMenuTitle(pieces: pieces, itemSettings: itemSettings)
                item.length = NSStatusItem.variableLength
                applyStatusDescription(pieces, to: button, kind: kind)
            }
        }
    }

    /// Everything the three text layouts need for one render.
    ///
    /// Runs inside the 120 ms render throttle on the main thread, so it stays
    /// a single forward walk of the user's selection: resolve each field and
    /// its live bucket once, collapse adjacent same-group fields into runs
    /// (only when the user asked for it — see `MenuBarItemSettings
    /// .mergesGroupWindows`), then read a percent and a color per window.
    private func menuBarPieces(
        for itemSettings: MenuBarItemSettings,
        settings: AppSettings
    ) -> [MenuBarPiece] {
        let registry = environment.quotaService.fieldRegistry
        var fields: [MenuBarFieldOption] = []
        var buckets: [QuotaBucket] = []
        fields.reserveCapacity(itemSettings.selectedFieldIds.count)
        buckets.reserveCapacity(itemSettings.selectedFieldIds.count)
        for fieldId in itemSettings.selectedFieldIds {
            guard
                let field = MenuBarFieldCatalog.field(id: fieldId, registry: registry),
                let bucket = environment.quota(for: field.tool)?.bucket(id: field.bucketId)
            else { continue }
            fields.append(field)
            buckets.append(bucket)
        }

        let runs = MenuBarFieldCatalog.runs(fields, merging: itemSettings.mergesGroupWindows)
        let modeWord = settings.displayMode == .used ? "used" : "remaining"
        var pieces: [MenuBarPiece] = []
        pieces.reserveCapacity(runs.count)
        var cursor = 0
        for run in runs {
            var percents: [MenuBarPercentValue] = []
            percents.reserveCapacity(run.fields.count)
            // Only a merged piece needs per-window words; a lone field's
            // spoken form is already its label and its one percentage.
            var windows: [String] = []
            if run.isMerged { windows.reserveCapacity(run.fields.count) }
            for offset in 0..<run.fields.count {
                let field = fields[cursor + offset]
                let bucket = buckets[cursor + offset]
                let percent = bucket.displayPercent(settings.displayMode, tool: field.tool)
                percents.append(MenuBarPercentValue(
                    value: percent,
                    color: percentColor(for: field, bucket: bucket, settings: settings)
                ))
                if run.isMerged {
                    windows.append("\(bucket.shortLabel) \(percentText(percent)) \(modeWord)")
                }
            }
            let label = run.isMerged
                ? MenuBarFieldCatalog.mergedGroupLabel(
                    for: run,
                    customLabels: itemSettings.customLabels,
                    groupCatalogLabel: MiniWindowGroupLabelCatalog.defaultLabel(for:)
                )
                : label(for: run.primary, bucket: buckets[cursor], itemSettings: itemSettings)
            pieces.append(MenuBarPiece(
                label: label,
                percents: percents,
                tool: run.primary.tool,
                style: itemSettings.style(for: run.primary.id),
                spokenDescription: run.isMerged
                    ? "\(label) \(windows.joined(separator: ", "))"
                    : "\(label) \(percentText(percents[0].value)) \(modeWord)"
            ))
            cursor += run.fields.count
        }
        return pieces
    }

    private func percentText(_ percent: Double) -> String {
        "\(Int(percent.rounded()))%"
    }

    // MARK: - Composed strip

    /// A composed strip resolved for one render: the draw plan plus the quota
    /// snapshots it was planned against, kept together because the colour
    /// roles the plan emits are resolved against those same snapshots.
    private struct ComposedStrip {
        var plan: MenuBarRenderPlan
        var quotas: [MenuBarQuotaSnapshot]
    }

    private func installComposedContent(
        _ composition: MenuBarComposition,
        in button: NSStatusBarButton,
        item: NSStatusItem,
        kind: MenuBarItemKind,
        itemSettings: MenuBarItemSettings,
        settings: AppSettings
    ) {
        let strip = composedStrip(composition, itemSettings: itemSettings, settings: settings)
        let rows = strip.plan.rows.filter { !$0.isEmpty }
        if rows.count >= 2 {
            let cells = rows.prefix(MenuBarComposition.maximumRows).map {
                composedCell(row: $0, strip: strip, settings: settings)
            }
            installTwoRowImageContent(
                in: button,
                item: item,
                columns: [TwoRowMenuColumn(top: cells[0], bottom: cells[1])]
            )
        } else {
            // Every block the user kept fell away — no quota is answering, or
            // every rule said no. Show the same "—" the field strip shows
            // rather than an empty status item nobody can find to click. No
            // title in front of it: in custom mode the title is a block the
            // user may have deleted, so reviving it here would be a surprise.
            button.attributedTitle = rows.isEmpty
                ? Self.composedPlaceholder(fontSize: NSFont.smallSystemFontSize)
                : composedAttributedRow(
                    rows[0],
                    strip: strip,
                    settings: settings,
                    baseFontSize: NSFont.smallSystemFontSize
                )
            item.length = NSStatusItem.variableLength
        }
        applyStatusDescription(body: strip.plan.spokenDescription, to: button, kind: kind)
    }

    /// Resolve the quotas the strip names, then plan it.
    ///
    /// The resolution itself lives in `MenuBarStripResolver` so the editor's
    /// live preview is looking at the same numbers under the same rules — the
    /// preview drifting from the bar it is previewing would be worse than
    /// having no preview.
    private func composedStrip(
        _ composition: MenuBarComposition,
        itemSettings: MenuBarItemSettings,
        settings: AppSettings
    ) -> ComposedStrip {
        let now = Date()
        let quotas = MenuBarStripResolver.snapshots(
            for: composition,
            itemSettings: itemSettings,
            settings: settings,
            environment: environment,
            now: now
        )
        return ComposedStrip(
            plan: composition.plan(
                quotas: quotas,
                displayMode: settings.displayMode,
                colorBasis: settings.menuBarColorBasis,
                now: now
            ),
            quotas: quotas
        )
    }

    /// One composed row as an attributed string. Used for a single-row strip,
    /// where a logo can ride along as a text attachment.
    private func composedAttributedRow(
        _ row: MenuBarRenderRow,
        strip: ComposedStrip,
        settings: AppSettings,
        baseFontSize: CGFloat
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString()
        for (index, token) in row.tokens.enumerated() {
            if index > 0, let gap = composedGap(strip.plan, baseFontSize: baseFontSize) {
                attributed.append(gap)
            }
            let size = composedFontSize(token, baseFontSize: baseFontSize)
            let font = composedFont(token, size: size)
            if let tool = token.logo {
                let paint = composedPaint(token.color, strip: strip, settings: settings)
                if let attachment = brandAttachment(
                    for: tool,
                    fontSize: size,
                    font: font,
                    tint: MenuBarStripPalette.nsColor(paint),
                    tintKey: MenuBarStripPalette.cacheKey(paint)
                ) {
                    attributed.append(attachment)
                }
                continue
            }
            guard let text = token.text, !text.isEmpty else { continue }
            attributed.append(NSAttributedString(
                string: text,
                attributes: [
                    .foregroundColor: MenuBarStripPalette.nsColor(
                        composedPaint(token.color, strip: strip, settings: settings)
                    ),
                    .font: font
                ]
            ))
        }
        return attributed
    }

    /// One composed row as a rasterizer cell. Logos break the row into runs
    /// instead of becoming attachments — see `TwoRowMenuCell`.
    private func composedCell(
        row: MenuBarRenderRow,
        strip: ComposedStrip,
        settings: AppSettings
    ) -> TwoRowMenuCell {
        let baseFontSize = MenuBarStatusMetrics.twoRowFontSize
        var runs: [TwoRowMenuCell.Run] = []
        var pending = NSMutableAttributedString()
        func flush() {
            if pending.length > 0 {
                runs.append(.text(pending))
                pending = NSMutableAttributedString()
            }
        }
        for (index, token) in row.tokens.enumerated() {
            if index > 0, let gap = composedGap(strip.plan, baseFontSize: baseFontSize) {
                pending.append(gap)
            }
            if let tool = token.logo {
                flush()
                let paint = composedPaint(token.color, strip: strip, settings: settings)
                if let image = brandLogoImage(
                    for: tool,
                    side: MenuBarStatusMetrics.twoRowLogoSide,
                    tint: MenuBarStripPalette.nsColor(paint),
                    tintKey: MenuBarStripPalette.cacheKey(paint)
                ) {
                    runs.append(.logo(image))
                }
                continue
            }
            guard let text = token.text, !text.isEmpty else { continue }
            pending.append(NSAttributedString(
                string: text,
                attributes: [
                    .foregroundColor: MenuBarStripPalette.nsColor(
                        composedPaint(token.color, strip: strip, settings: settings)
                    ),
                    .font: composedFont(token, size: composedFontSize(token, baseFontSize: baseFontSize))
                ]
            ))
        }
        flush()
        return TwoRowMenuCell(runs: runs)
    }

    /// What a composed strip shows when nothing survived.
    private static func composedPlaceholder(fontSize: CGFloat) -> NSAttributedString {
        NSAttributedString(
            string: "—",
            attributes: [
                .foregroundColor: NSColor.tertiaryLabelColor,
                .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
            ]
        )
    }

    /// The gap between two blocks, drawn as a space glyph at a scaled point
    /// size — the same idiom the logo-to-label gap has always used, and the
    /// only one that works in the two-row canvas, where an attachment would
    /// inflate the line box.
    private func composedGap(_ plan: MenuBarRenderPlan, baseFontSize: CGFloat) -> NSAttributedString? {
        let spacing = plan.tokenSpacing
        guard spacing > 0 else { return nil }
        return NSAttributedString(
            string: " ",
            attributes: [.font: NSFont.systemFont(ofSize: max(1, baseFontSize * spacing))]
        )
    }

    private func composedFontSize(_ token: MenuBarRenderedToken, baseFontSize: CGFloat) -> CGFloat {
        max(4, baseFontSize * token.fontScale)
    }

    private func composedFont(_ token: MenuBarRenderedToken, size: CGFloat) -> NSFont {
        let weight: NSFont.Weight
        switch token.weight {
        case .regular: weight = .regular
        case .medium: weight = .medium
        case .semibold: weight = .semibold
        }
        return token.monospacedDigits
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// A composed block's colour and its cache key, both from the one shared
    /// palette the editor's preview draws with. Keeping the decision in a
    /// single place is the only thing stopping the preview and the bar from
    /// disagreeing about what `.automatic` means.
    private func composedPaint(
        _ role: MenuBarTokenColorRole,
        strip: ComposedStrip,
        settings: AppSettings
    ) -> MenuBarStripPaint {
        MenuBarStripPalette.paint(
            for: role,
            quotas: strip.quotas,
            displayMode: settings.displayMode
        )
    }

    /// The status item always *speaks* one clause per quota window, even when
    /// the bar draws a merged group as `5%/100%`: "Claude 5 Hours 5% used,
    /// Weekly 100% used". The shorthand is a space-saving glyph, not a
    /// description anyone can read aloud.
    private func applyStatusDescription(
        _ pieces: [MenuBarPiece],
        to button: NSStatusBarButton,
        kind: MenuBarItemKind
    ) {
        applyStatusDescription(
            body: pieces.map(\.spokenDescription).joined(separator: " · "),
            to: button,
            kind: kind
        )
    }

    private func applyStatusDescription(
        body: String,
        to button: NSStatusBarButton,
        kind: MenuBarItemKind
    ) {
        let description = body.isEmpty
            ? "\(kind.label) quota"
            : "\(kind.label) quota: \(body)"
        button.setAccessibilityLabel(description)
        if button.toolTip != description { button.toolTip = description }
    }

    private func singleLineMenuTitle(
        pieces: [MenuBarPiece],
        itemSettings: MenuBarItemSettings
    ) -> NSAttributedString {
        let fontSize = NSFont.smallSystemFontSize
        let attributed = NSMutableAttributedString()
        if itemSettings.showTitle {
            attributed.append(NSAttributedString(
                string: "\(itemSettings.kind.title) ",
                attributes: [
                    .foregroundColor: NSColor.labelColor,
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .medium)
                ]
            ))
        }

        for (index, piece) in pieces.enumerated() {
            if index > 0 {
                attributed.append(NSAttributedString(
                    string: " · ",
                    attributes: [
                        .foregroundColor: NSColor.tertiaryLabelColor,
                        .font: NSFont.systemFont(ofSize: fontSize, weight: .regular)
                    ]
                ))
            }
            // This layout has always drawn words only — the per-field logo
            // styles belong to the compact and two-row bars.
            attributed.append(menuTextPiece(
                label: piece.label,
                percents: piece.percents,
                fontSize: fontSize
            ))
        }

        if pieces.isEmpty {
            attributed.append(NSAttributedString(
                string: "—",
                attributes: [
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
                ]
            ))
        }
        return attributed
    }

    private func compactMenuTitle(
        pieces: [MenuBarPiece],
        itemSettings: MenuBarItemSettings
    ) -> NSAttributedString {
        let fontSize = MenuBarStatusMetrics.twoRowFontSize
        let attributed = NSMutableAttributedString()
        if itemSettings.showTitle {
            attributed.append(NSAttributedString(
                string: "\(itemSettings.kind.title) ",
                attributes: [
                    .foregroundColor: NSColor.labelColor,
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .medium)
                ]
            ))
        }

        for (index, piece) in pieces.enumerated() {
            if index > 0 {
                attributed.append(NSAttributedString(
                    string: " ",
                    attributes: [
                        .foregroundColor: NSColor.tertiaryLabelColor,
                        .font: NSFont.systemFont(ofSize: fontSize, weight: .regular)
                    ]
                ))
            }
            // One brand attachment per piece, not per percentage: a merged
            // group is one quota family, so it wears one logo.
            attributed.append(menuTextPiece(
                label: piece.label,
                percents: piece.percents,
                fontSize: fontSize,
                style: piece.style,
                tool: piece.tool
            ))
        }

        if pieces.isEmpty {
            attributed.append(NSAttributedString(
                string: "—",
                attributes: [
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
                ]
            ))
        }
        return attributed
    }

    private func twoRowMenuColumns(
        pieces: [MenuBarPiece],
        itemSettings: MenuBarItemSettings
    ) -> [TwoRowMenuColumn] {
        let entries = displayedEntries(pieces: pieces)
        guard !entries.isEmpty else {
            return [TwoRowMenuColumn(top: TwoRowMenuCell(
                text: emptyMenuTitle(for: itemSettings, fontSize: MenuBarStatusMetrics.twoRowFontSize),
                logo: nil
            ))]
        }

        var columns: [TwoRowMenuColumn] = []
        var index = 0
        while index < entries.count {
            let top = entries[index]
            let bottom = index + 1 < entries.count ? entries[index + 1] : nil
            columns.append(TwoRowMenuColumn(top: top, bottom: bottom))
            index += 2
        }

        if itemSettings.showTitle {
            columns.insert(
                TwoRowMenuColumn(
                    top: TwoRowMenuCell(
                        text: menuTextPiece(
                            label: itemSettings.kind.title,
                            percent: nil,
                            color: NSColor.labelColor,
                            fontSize: MenuBarStatusMetrics.twoRowFontSize
                        ),
                        logo: nil
                    )
                ),
                at: 0
            )
        }
        return columns
    }

    private func displayedEntries(pieces: [MenuBarPiece]) -> [TwoRowMenuCell] {
        pieces.map { piece in
            // The two-row canvas is thickness - 2 with overlapping lines; a
            // text attachment inflates its line box to 14pt no matter what
            // bounds it declares, so logos never enter these strings — the
            // rasterizer draws them beside the text instead. One logo per
            // cell, so a merged group shows its brand once.
            let text = menuTextPiece(
                label: piece.style == .logoAndPercent ? nil : piece.label,
                percents: piece.percents,
                fontSize: MenuBarStatusMetrics.twoRowFontSize
            )
            let logo = piece.style == .labelAndPercent
                ? nil
                : brandLogoImage(for: piece.tool, side: MenuBarStatusMetrics.twoRowLogoSide)
            return TwoRowMenuCell(text: text, logo: logo)
        }
    }

    private func emptyMenuTitle(for itemSettings: MenuBarItemSettings, fontSize: CGFloat) -> NSAttributedString {
        let attributed = NSMutableAttributedString()
        if itemSettings.showTitle {
            attributed.append(NSAttributedString(
                string: "\(itemSettings.kind.title) ",
                attributes: [
                    .foregroundColor: NSColor.labelColor,
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .medium)
                ]
            ))
        }
        attributed.append(NSAttributedString(
            string: "—",
            attributes: [
                .foregroundColor: NSColor.tertiaryLabelColor,
                .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
            ]
        ))
        return attributed
    }

    private func label(for field: MenuBarFieldOption, bucket: QuotaBucket, itemSettings: MenuBarItemSettings) -> String {
        let custom = itemSettings.customLabels[field.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let custom, !custom.isEmpty { return custom }
        if field.defaultLabel != bucket.shortLabel { return bucket.shortLabel }
        return field.defaultLabel
    }

    private func menuTextPiece(
        label: String?,
        percent: Double?,
        color: NSColor,
        fontSize: CGFloat,
        style: MenuBarFieldStyle = .labelAndPercent,
        tool: ToolType? = nil
    ) -> NSAttributedString {
        menuTextPiece(
            label: label,
            percents: percent.map { [MenuBarPercentValue(value: $0, color: color)] } ?? [],
            fontSize: fontSize,
            style: style,
            tool: tool
        )
    }

    /// One menu-bar piece: an optional logo, an optional label, then every
    /// percentage the piece carries.
    ///
    /// A merged group passes several percentages and gets `5%/100%` — each
    /// keeping the color it would have had standing alone, joined by a
    /// tertiary slash so the divider reads as punctuation rather than
    /// competing with the numbers. The logo and the label are drawn once for
    /// the whole piece, never once per percentage.
    private func menuTextPiece(
        label: String?,
        percents: [MenuBarPercentValue],
        fontSize: CGFloat,
        style: MenuBarFieldStyle = .labelAndPercent,
        tool: ToolType? = nil
    ) -> NSAttributedString {
        let baseFont = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let chunk = NSMutableAttributedString()
        if style != .labelAndPercent, let tool,
           let attachment = brandAttachment(for: tool, fontSize: fontSize, font: baseFont) {
            chunk.append(attachment)
            chunk.append(NSAttributedString(
                string: " ",
                attributes: [.font: NSFont.systemFont(ofSize: fontSize * 0.4)]
            ))
        }
        if style != .logoAndPercent, let label {
            chunk.append(NSAttributedString(
                string: "\(label) ",
                attributes: [
                    .foregroundColor: NSColor.labelColor,
                    .font: baseFont
                ]
            ))
        }
        let percentFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        for (index, percent) in percents.enumerated() {
            if index > 0 {
                chunk.append(NSAttributedString(
                    string: "/",
                    attributes: [
                        .foregroundColor: NSColor.tertiaryLabelColor,
                        .font: percentFont
                    ]
                ))
            }
            chunk.append(NSAttributedString(
                string: percentText(percent.value),
                attributes: [
                    .foregroundColor: percent.color,
                    .font: percentFont
                ]
            ))
        }
        return chunk
    }

    /// Brand-logo run for a text piece, vertically centered on the font's
    /// cap height. Cached per (tool, point size, appearance) — the status
    /// item re-renders on every quota publish and must not rasterize icons
    /// per tick.
    ///
    /// The tint resolves against the *status button's* effective appearance,
    /// not the app's: the menu bar follows the system/wallpaper theme
    /// independently, and rasterizing labelColor under the wrong appearance
    /// painted logos invisible on the opposite menu bar. Small fonts (the
    /// two-row layout) cap the icon at 10pt — a 12pt attachment grew the
    /// line and pushed the second row out of the bar.
    private func brandAttachment(
        for tool: ToolType,
        fontSize: CGFloat,
        font: NSFont,
        tint: NSColor = .labelColor,
        tintKey: String = "label"
    ) -> NSAttributedString? {
        let side: CGFloat = (fontSize + 3).rounded()
        guard let image = brandImage(for: tool, side: side, tint: tint, tintKey: tintKey) else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = image
        let yOffset = (font.capHeight - side) / 2
        attachment.bounds = CGRect(x: 0, y: yOffset, width: side, height: side)
        return NSAttributedString(attachment: attachment)
    }

    /// Raw logo image for the two-row rasterizer's manual drawing — same
    /// cache the attachment path uses.
    private func brandLogoImage(
        for tool: ToolType,
        side: CGFloat,
        tint: NSColor = .labelColor,
        tintKey: String = "label"
    ) -> NSImage? {
        brandImage(for: tool, side: side, tint: tint, tintKey: tintKey)
    }

    /// Rasterized brand mark, cached by tool, point size, appearance, and the
    /// tint's *role* — a composed strip can paint a logo in a fixed colour or
    /// in a quota's live verdict colour, and those must not collide in the
    /// cache with the plain label-coloured one. `tintKey` is the role name
    /// rather than the `NSColor`, whose description is not a stable key for a
    /// dynamic system colour.
    private func brandImage(
        for tool: ToolType,
        side: CGFloat,
        tint: NSColor,
        tintKey: String
    ) -> NSImage? {
        let appearance = compactStatusItem?.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        let key = "\(tool.rawValue).\(side).\(appearance.name.rawValue).\(tintKey)"
        if let cached = brandAttachmentImages[key] { return cached }
        let image = ProviderBrandIcon.image(
            for: tool,
            size: NSSize(width: side, height: side),
            tint: tint,
            appearance: appearance
        )
        brandAttachmentImages[key] = image
        return image
    }

    private func installIconOnlyContent(
        in button: NSStatusBarButton,
        item: NSStatusItem,
        kind: MenuBarItemKind
    ) {
        button.attributedTitle = NSAttributedString(string: "")
        button.image = ProviderBrandIcon.image(for: kind)
        button.imagePosition = .imageOnly
        item.length = NSStatusItem.squareLength
        button.setAccessibilityLabel(kind.label)
        // This layout draws no percentages, so it skips the piece walk (and
        // its per-bucket forecasts) entirely — which also means it must clear
        // any live description a previous layout left on the button.
        let idleToolTip = "\(kind.label) quota"
        if button.toolTip != idleToolTip { button.toolTip = idleToolTip }
    }

    private func installTwoRowImageContent(
        in button: NSStatusBarButton,
        item: NSStatusItem,
        columns: [TwoRowMenuColumn]
    ) {
        // Keep two-row content as a static image; custom status-item subviews trigger continuous AppKit replicant redraws.
        let image = twoRowImage(for: columns, appearance: button.effectiveAppearance)
        button.attributedTitle = NSAttributedString(string: "")
        button.image = image
        button.imagePosition = .imageOnly
        item.length = max(MenuBarStatusMetrics.minimumTwoRowLength, ceil(image.size.width + 2))
        // The accessibility label is set from the resolved pieces by
        // `applyStatusDescription` — reading it back off the rasterized
        // columns would speak the merged `5%/100%` shorthand.
    }

    nonisolated private static func cellWidth(_ cell: TwoRowMenuCell) -> CGFloat {
        var width: CGFloat = 0
        for (index, run) in cell.runs.enumerated() {
            if index > 0 { width += MenuBarStatusMetrics.twoRowLogoGap }
            switch run {
            case .logo: width += MenuBarStatusMetrics.twoRowLogoSide
            case let .text(text): width += text.size().width
            }
        }
        return width
    }

    /// Tallest text run in the cell; a logo-only cell falls back to the logo
    /// box so its row band does not collapse to nothing.
    nonisolated private static func cellHeight(_ cell: TwoRowMenuCell) -> CGFloat {
        var height: CGFloat = 0
        var sawLogo = false
        for run in cell.runs {
            switch run {
            case .logo: sawLogo = true
            case let .text(text): height = max(height, text.size().height)
            }
        }
        if height == 0, sawLogo { return MenuBarStatusMetrics.twoRowLogoSide }
        return height
    }

    private func twoRowImage(for columns: [TwoRowMenuColumn], appearance: NSAppearance) -> NSImage {
        let columnSizes = columns.map { column -> (top: CGFloat, bottom: CGFloat?, width: CGFloat) in
            (
                top: Self.cellHeight(column.top),
                bottom: column.bottom.map(Self.cellHeight),
                width: ceil(max(Self.cellWidth(column.top), column.bottom.map(Self.cellWidth) ?? 0))
            )
        }

        let topRowHeight = ceil(columnSizes.map(\.top).max() ?? 0)
        let bottomRowHeight = ceil(columnSizes.compactMap { $0.bottom }.max() ?? 0)
        let hasBottomRow = columns.contains { $0.bottom != nil }
        let contentHeight = hasBottomRow
            ? topRowHeight + bottomRowHeight + MenuBarStatusMetrics.twoRowLineSpacing
            : topRowHeight
        let statusBarHeight = max(18, NSStatusBar.system.thickness - 2)
        let imageHeight = min(
            max(18, ceil(contentHeight + MenuBarStatusMetrics.twoRowVerticalPadding * 2)),
            statusBarHeight
        )
        var contentWidth: CGFloat = 0
        for (index, size) in columnSizes.enumerated() {
            if index > 0 {
                contentWidth += MenuBarStatusMetrics.twoRowColumnSpacing
            }
            contentWidth += size.width
        }
        let imageWidth = max(
            MenuBarStatusMetrics.minimumTwoRowLength,
            ceil(contentWidth + MenuBarStatusMetrics.twoRowHorizontalPadding * 2)
        )
        let imageSize = NSSize(width: imageWidth, height: imageHeight)
        let image = NSImage(size: imageSize)
        image.isTemplate = false

        appearance.performAsCurrentDrawingAppearance {
            image.lockFocus()
            NSColor.clear.setFill()
            NSRect(origin: .zero, size: imageSize).fill()

            func drawCell(_ cell: TwoRowMenuCell, at origin: NSPoint, rowHeight: CGFloat, columnWidth: CGFloat) {
                let width = Self.cellWidth(cell)
                var x = origin.x + floor((columnWidth - width) / 2)
                for (index, run) in cell.runs.enumerated() {
                    if index > 0 { x += MenuBarStatusMetrics.twoRowLogoGap }
                    switch run {
                    case let .logo(logo):
                        let side = MenuBarStatusMetrics.twoRowLogoSide
                        // Centered in the row's own band, clamped to the
                        // canvas — never handed to the text system, whose
                        // attachment line box would not fit two rows in this
                        // height.
                        let logoY = max(0, origin.y + floor((rowHeight - side) / 2))
                        logo.draw(
                            in: NSRect(x: x, y: logoY, width: side, height: side),
                            from: .zero,
                            operation: .sourceOver,
                            fraction: 1
                        )
                        x += side
                    case let .text(text):
                        text.draw(at: NSPoint(x: x, y: origin.y))
                        x += text.size().width
                    }
                }
            }

            var x = MenuBarStatusMetrics.twoRowHorizontalPadding
            for (column, sizes) in zip(columns, columnSizes) {
                if let bottom = column.bottom {
                    let blockHeight = topRowHeight + bottomRowHeight + MenuBarStatusMetrics.twoRowLineSpacing
                    let blockBottom = max(0, floor((imageHeight - blockHeight) / 2))
                    drawCell(
                        bottom,
                        at: NSPoint(x: x, y: blockBottom),
                        rowHeight: bottomRowHeight,
                        columnWidth: sizes.width
                    )
                    drawCell(
                        column.top,
                        at: NSPoint(x: x, y: blockBottom + bottomRowHeight + MenuBarStatusMetrics.twoRowLineSpacing),
                        rowHeight: topRowHeight,
                        columnWidth: sizes.width
                    )
                } else {
                    drawCell(
                        column.top,
                        at: NSPoint(x: x, y: floor((imageHeight - sizes.top) / 2)),
                        rowHeight: sizes.top,
                        columnWidth: sizes.width
                    )
                }
                x += sizes.width + MenuBarStatusMetrics.twoRowColumnSpacing
            }
            image.unlockFocus()
        }

        return image
    }

    private func removeTwoRowStatusContent(from button: NSStatusBarButton) {
        button.subviews
            .filter { $0.identifier == MenuBarStatusMetrics.twoRowContentIdentifier }
            .forEach { $0.removeFromSuperview() }
    }

    private func statusItemTag(for kind: MenuBarItemKind) -> Int {
        1
    }

    private func statusItem(for kind: MenuBarItemKind) -> NSStatusItem? {
        compactStatusItem
    }

    /// Color for one rendered menu-bar percentage. The thresholds and the
    /// verdict mapping live in `MenuBarPercentColor`; this only resolves the
    /// forecast input and translates the result to AppKit.
    private func percentColor(
        for field: MenuBarFieldOption,
        bucket: QuotaBucket,
        settings: AppSettings
    ) -> NSColor {
        let basis = settings.menuBarColorBasis
        let verdict = basis == .forecast ? forecastVerdict(for: field.tool, bucket: bucket) : nil
        return Self.nsColor(
            for: MenuBarPercentColor.resolve(
                basis: basis,
                verdict: verdict,
                percent: bucket.displayPercent(settings.displayMode, tool: field.tool),
                displayMode: settings.displayMode
            )
        )
    }

    /// Forecast verdict for one menu-bar bucket, computed at render time.
    ///
    /// Affordable here because every input is already in memory — cached quota
    /// observations, cached cycle history, and a rebased cost snapshot — and
    /// only the handful of buckets the user put in the menu bar are asked for.
    private func forecastVerdict(for tool: ToolType, bucket: QuotaBucket) -> QuotaPaceForecast.Verdict? {
        paceForecast(for: tool, bucket: bucket)?.verdict
    }

    /// The whole forecast, not just its verdict: a composed strip can print
    /// the projection and the run-out ETA, which the field path never needed.
    private func paceForecast(for tool: ToolType, bucket: QuotaBucket) -> QuotaPaceForecast? {
        MenuBarStripResolver.paceForecast(for: tool, bucket: bucket, environment: environment)
    }

    /// AppKit twin of `QuotaForecastPalette`, via the one palette the composed
    /// strip and its preview also read — the field path and the composer must
    /// paint an identical percentage identically.
    private static func nsColor(for color: MenuBarPercentColor) -> NSColor {
        MenuBarStripPalette.nsColor(.quota(color))
    }
}
