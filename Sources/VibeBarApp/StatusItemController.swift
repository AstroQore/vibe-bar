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
}

private struct TwoRowMenuColumn {
    var top: NSAttributedString
    var bottom: NSAttributedString?
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
            self.environment.setPopoverVisible(
                self.popovers.values.contains { $0.isShown && $0 !== popover }
            )
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
            switch itemSettings.layout {
            case .iconOnly:
                installIconOnlyContent(in: button, item: item, kind: kind)
            case .singleLine:
                button.attributedTitle = singleLineMenuTitle(for: itemSettings, settings: settings)
                item.length = NSStatusItem.variableLength
            case .twoRows:
                installTwoRowImageContent(
                    in: button,
                    item: item,
                    columns: twoRowMenuColumns(for: itemSettings, settings: settings),
                    kind: kind
                )
            case .compact:
                button.attributedTitle = compactMenuTitle(for: itemSettings, settings: settings)
                item.length = NSStatusItem.variableLength
            }
        }
    }

    private func singleLineMenuTitle(for itemSettings: MenuBarItemSettings, settings: AppSettings) -> NSAttributedString {
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

        var displayed = 0
        for fieldId in itemSettings.selectedFieldIds {
            guard
                let field = MenuBarFieldCatalog.field(id: fieldId, registry: environment.quotaService.fieldRegistry),
                let bucket = environment.quota(for: field.tool)?.bucket(id: field.bucketId)
            else { continue }
            if displayed > 0 {
                attributed.append(NSAttributedString(
                    string: " · ",
                    attributes: [
                        .foregroundColor: NSColor.tertiaryLabelColor,
                        .font: NSFont.systemFont(ofSize: fontSize, weight: .regular)
                    ]
                ))
            }
            let percent = bucket.displayPercent(settings.displayMode, tool: field.tool)
            let label = label(for: field, bucket: bucket, itemSettings: itemSettings)
            attributed.append(menuPiece(
                label: label,
                percent: percent,
                color: percentColor(for: field, bucket: bucket, settings: settings),
                fontSize: fontSize
            ))
            displayed += 1
        }

        if displayed == 0 {
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

    private func compactMenuTitle(for itemSettings: MenuBarItemSettings, settings: AppSettings) -> NSAttributedString {
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

        let entries = itemSettings.selectedFieldIds.compactMap { fieldId -> NSAttributedString? in
            guard
                let field = MenuBarFieldCatalog.field(id: fieldId, registry: environment.quotaService.fieldRegistry),
                let bucket = environment.quota(for: field.tool)?.bucket(id: field.bucketId)
            else { return nil }
            let percent = bucket.displayPercent(settings.displayMode, tool: field.tool)
            return menuTextPiece(
                label: label(for: field, bucket: bucket, itemSettings: itemSettings),
                percent: percent,
                color: percentColor(for: field, bucket: bucket, settings: settings),
                fontSize: fontSize
            )
        }

        for (index, entry) in entries.enumerated() {
            if index > 0 {
                attributed.append(NSAttributedString(
                    string: " ",
                    attributes: [
                        .foregroundColor: NSColor.tertiaryLabelColor,
                        .font: NSFont.systemFont(ofSize: fontSize, weight: .regular)
                    ]
                ))
            }
            attributed.append(entry)
        }

        if entries.isEmpty {
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

    private func twoRowMenuColumns(for itemSettings: MenuBarItemSettings, settings: AppSettings) -> [TwoRowMenuColumn] {
        let entries = displayedEntries(for: itemSettings, settings: settings)
        guard !entries.isEmpty else {
            return [TwoRowMenuColumn(top: emptyMenuTitle(for: itemSettings, fontSize: MenuBarStatusMetrics.twoRowFontSize))]
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
                    top: menuTextPiece(
                        label: itemSettings.kind.title,
                        percent: nil,
                        color: NSColor.labelColor,
                        fontSize: MenuBarStatusMetrics.twoRowFontSize
                    )
                ),
                at: 0
            )
        }
        return columns
    }

    private func displayedEntries(for itemSettings: MenuBarItemSettings, settings: AppSettings) -> [NSAttributedString] {
        itemSettings.selectedFieldIds.compactMap { fieldId in
            guard
                let field = MenuBarFieldCatalog.field(id: fieldId, registry: environment.quotaService.fieldRegistry),
                let bucket = environment.quota(for: field.tool)?.bucket(id: field.bucketId)
            else { return nil }
            let percent = bucket.displayPercent(settings.displayMode, tool: field.tool)
            return menuTextPiece(
                label: label(for: field, bucket: bucket, itemSettings: itemSettings),
                percent: percent,
                color: percentColor(for: field, bucket: bucket, settings: settings),
                fontSize: MenuBarStatusMetrics.twoRowFontSize
            )
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

    private func menuPiece(label: String, percent: Double, color: NSColor, fontSize: CGFloat) -> NSAttributedString {
        menuTextPiece(label: label, percent: percent, color: color, fontSize: fontSize)
    }

    private func menuTextPiece(label: String, percent: Double?, color: NSColor, fontSize: CGFloat) -> NSAttributedString {
        let baseFont = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let chunk = NSMutableAttributedString()
        chunk.append(NSAttributedString(
            string: "\(label) ",
            attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: baseFont
            ]
        ))
        if let percent {
            chunk.append(NSAttributedString(
                string: "\(Int(percent.rounded()))%",
                attributes: [
                    .foregroundColor: color,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
                ]
            ))
        }
        return chunk
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
    }

    private func installTwoRowImageContent(
        in button: NSStatusBarButton,
        item: NSStatusItem,
        columns: [TwoRowMenuColumn],
        kind: MenuBarItemKind
    ) {
        // Keep two-row content as a static image; custom status-item subviews trigger continuous AppKit replicant redraws.
        let image = twoRowImage(for: columns, appearance: button.effectiveAppearance)
        button.attributedTitle = NSAttributedString(string: "")
        button.image = image
        button.imagePosition = .imageOnly
        item.length = max(MenuBarStatusMetrics.minimumTwoRowLength, ceil(image.size.width + 2))
        button.setAccessibilityLabel("\(kind.label) \(twoRowAccessibilityTitle(for: columns))")
    }

    private func twoRowImage(for columns: [TwoRowMenuColumn], appearance: NSAppearance) -> NSImage {
        let columnSizes = columns.map { column -> (top: NSSize, bottom: NSSize?, width: CGFloat) in
            let topSize = column.top.size()
            let bottomSize = column.bottom?.size()
            return (
                top: topSize,
                bottom: bottomSize,
                width: ceil(max(topSize.width, bottomSize?.width ?? 0))
            )
        }

        let topRowHeight = ceil(columnSizes.map(\.top.height).max() ?? 0)
        let bottomRowHeight = ceil(columnSizes.compactMap { $0.bottom?.height }.max() ?? 0)
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

            var x = MenuBarStatusMetrics.twoRowHorizontalPadding
            for (column, sizes) in zip(columns, columnSizes) {
                if let bottom = column.bottom, let bottomSize = sizes.bottom {
                    let blockHeight = topRowHeight + bottomRowHeight + MenuBarStatusMetrics.twoRowLineSpacing
                    let blockBottom = max(0, floor((imageHeight - blockHeight) / 2))
                    let topPoint = NSPoint(
                        x: x + floor((sizes.width - sizes.top.width) / 2),
                        y: blockBottom + bottomRowHeight + MenuBarStatusMetrics.twoRowLineSpacing
                    )
                    let bottomPoint = NSPoint(
                        x: x + floor((sizes.width - bottomSize.width) / 2),
                        y: blockBottom
                    )
                    bottom.draw(at: bottomPoint)
                    column.top.draw(at: topPoint)
                } else {
                    let topPoint = NSPoint(
                        x: x + floor((sizes.width - sizes.top.width) / 2),
                        y: floor((imageHeight - sizes.top.height) / 2)
                    )
                    column.top.draw(at: topPoint)
                }
                x += sizes.width + MenuBarStatusMetrics.twoRowColumnSpacing
            }
            image.unlockFocus()
        }

        return image
    }

    private func twoRowAccessibilityTitle(for columns: [TwoRowMenuColumn]) -> String {
        columns
            .map { column in
                [column.top.string, column.bottom?.string]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
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
        guard let accountId = environment.account(for: tool)?.id else { return nil }
        let snapshot = environment.costService.snapshot(for: tool)
        return environment.quotaService.paceForecast(
            accountId: accountId,
            bucket: bucket,
            activityHeatmap: snapshot?.heatmap,
            dailyActivity: snapshot?.dailyHistory ?? [],
            now: Date(),
            allowsPostResetGrace: true
        )?.verdict
    }

    /// AppKit twin of `QuotaForecastPalette`. System colors rather than the
    /// popover's literal RGB values: the menu bar has to stay legible against
    /// light, dark, and tinted wallpapers, and these are the exact colors the
    /// pre-forecast menu bar used.
    private static func nsColor(for color: MenuBarPercentColor) -> NSColor {
        switch color {
        case .healthy: return NSColor.systemGreen
        case .surplus: return NSColor.systemBlue
        case .watch: return NSColor.systemOrange
        case .risk: return NSColor.systemRed
        }
    }
}
