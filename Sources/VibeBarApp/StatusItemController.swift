import AppKit
import SwiftUI
import Combine
import VibeBarCore

private enum MenuBarStatusMetrics {
    static let twoRowContentIdentifier = NSUserInterfaceItemIdentifier("VibeBarTwoRowStatusContent")
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
    /// One-shot, minute-aligned tick that keeps a composed countdown honest.
    /// Nil whenever no visible item shows a time-based block — see
    /// `updateCountdownClock`.
    private var countdownTimer: Timer?
    /// The cadence `countdownTimer` was armed at, so a strip that changes what
    /// it needs re-arms instead of keeping the old one.
    private var countdownInterval: TimeInterval?

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
                .appLanguageLocale()
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
        button.toolTip = L10n.MenuBar.Spoken.title(kind: kind.label)
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

        // Coalesce every input a composed or field strip reads into one
        // throttled pipeline, so a burst of quota, settings, account, and
        // status updates only redraws once. The list itself lives with the
        // resolver that reads those inputs — see
        // `MenuBarStripResolver.inputPublishers`, which the Settings preview
        // subscribes to as well.
        let renderTriggers = MenuBarStripResolver.inputPublishers(environment: environment)
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
        menu.addItem(densityMenuItem())
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

    /// The popover's density, from the bar itself: the one layout choice a
    /// user makes often enough — a big display at the desk, the laptop's own
    /// on the train — to deserve a place that is not two windows away.
    private func densityMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: L10n.Platform.Macos.MenuBar.displayDensity, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: L10n.Platform.Macos.MenuBar.displayDensity)
        submenu.autoenablesItems = false
        let current = environment.settingsStore.settings.popoverDensity
        for density in PopoverDensity.allCases {
            let choice = actionMenuItem(density.label, action: #selector(setDensityFromContextMenu(_:)))
            choice.representedObject = density.rawValue
            choice.state = density == current ? .on : .off
            submenu.addItem(choice)
        }
        item.submenu = submenu
        return item
    }

    @objc private func setDensityFromContextMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let density = PopoverDensity(rawValue: raw),
              density != environment.settingsStore.settings.popoverDensity
        else { return }
        environment.settingsStore.settings.popoverDensity = density
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
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownInterval = nil
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
        // Set while walking the items, so the clock decision uses the same
        // effective visibility the drawing does rather than a second copy of
        // the rule.
        var stripClockInterval: TimeInterval?
        defer { updateStripClock(interval: stripClockInterval) }
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
            if !itemSettings.usesComposedStrip && itemSettings.layout == .iconOnly {
                installIconOnlyContent(in: button, item: item, kind: kind)
                continue
            }
            let composition = MenuBarNativeRenderer.composition(for: itemSettings, registry: environment.quotaService.fieldRegistry,
                                                                quota: { environment.quota(for: $0) })
            if item.isVisible, let interval = composition.clockInterval(colorBasis: settings.menuBarColorBasis) {
                stripClockInterval = min(stripClockInterval ?? interval, interval)
            }
            installComposedContent(composition, in: button, item: item, kind: kind,
                                   itemSettings: itemSettings, settings: settings)
        }
    }

    /// Keeps a composed strip honest between refreshes.
    ///
    /// The render pipeline is driven by settings, quota, account, cost and
    /// status publishers — none of which is a clock. A strip printing
    /// `resets in 12m` sat unchanged until the next refresh, which on a
    /// 30-minute interval means the number is wrong for most of its life; a
    /// forecast percentage, a verdict rule, or a forecast colour goes stale
    /// the same way, just on the forecast's own five-minute grid.
    ///
    /// Armed only while a *visible* item needs it, at the interval that item
    /// asks for, so a strip of plain percentages costs no wakeups at all
    /// (`AGENTS.md` § 7's idle-CPU budget). One shot at a time rather than a
    /// repeating timer, and phased on the same process-wide anchor the
    /// popover's clocks use — a menu bar drifting a few seconds from the
    /// popover would show two different countdowns for one quota.
    private func updateStripClock(interval: TimeInterval?) {
        guard let interval else {
            countdownTimer?.invalidate()
            countdownTimer = nil
            countdownInterval = nil
            return
        }
        // Already armed for a future tick at this cadence. Re-arming here
        // would let a burst of quota publishes push the tick out indefinitely.
        if let existing = countdownTimer,
           existing.isValid,
           existing.fireDate > Date(),
           countdownInterval == interval {
            return
        }
        countdownTimer?.invalidate()
        countdownInterval = interval
        let timer = Timer(
            fire: MenuBarCountdownClock.nextTick(
                after: Date(),
                anchor: QuotaClockSchedule.anchor,
                interval: interval
            ),
            interval: 0,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.renderMenuBar() }
        }
        // A minute-granularity number does not need sub-second accuracy; let
        // the system coalesce the wakeup with whatever else it has queued.
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func percentText(_ percent: Double) -> String {
        L10n.Common.percent(value: Int(percent.rounded()))
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
        let drawing = MenuBarNativeRenderer.render(
            plan: strip.plan, quotas: strip.quotas, template: composition.template,
            displayMode: settings.displayMode, appearance: button.effectiveAppearance
        )
        button.attributedTitle = NSAttributedString(string: "")
        button.image = drawing.image
        button.imagePosition = .imageOnly
        item.length = max(24, ceil(drawing.size.width + 2))
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
                now: now,
                // The real bar's height, not the nominal one: how much a block
                // may grow depends on how tall this Mac's menu bar actually
                // is, and the preview asks for the same canvas.
                canvas: MenuBarStripMetrics.twoRowCanvas()
            ),
            quotas: quotas
        )
    }

    private func applyStatusDescription(
        body: String,
        to button: NSStatusBarButton,
        kind: MenuBarItemKind
    ) {
        let description = body.isEmpty
            ? L10n.MenuBar.Spoken.title(kind: kind.label)
            : L10n.MenuBar.Spoken.titleBody(kind: kind.label, body: body)
        button.setAccessibilityLabel(description)
        if button.toolTip != description { button.toolTip = description }
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
        let idleToolTip = L10n.MenuBar.Spoken.title(kind: kind.label)
        if button.toolTip != idleToolTip { button.toolTip = idleToolTip }
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
}
