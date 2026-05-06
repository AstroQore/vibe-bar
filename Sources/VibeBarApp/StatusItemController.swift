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
final class StatusItemController {
    private static let initialPopoverHeight: CGFloat = 720
    private static let minimumPopoverHeight: CGFloat = 460
    private static let popoverHeightPadding: CGFloat = 12

    private let compactStatusItem: NSStatusItem
    private let codexStatusItem: NSStatusItem
    private let claudeStatusItem: NSStatusItem
    private let statusStatusItem: NSStatusItem
    private var popovers: [MenuBarItemKind: NSPopover] = [:]
    private let environment: AppEnvironment
    private let miniWindowController: MiniQuotaWindowController
    private var cancellables: Set<AnyCancellable> = []
    private var lastObservedDensities: [MenuBarItemKind: PopoverDensity]

    init(environment: AppEnvironment) {
        self.environment = environment
        self.miniWindowController = MiniQuotaWindowController()
        self.lastObservedDensities = Self.snapshotDensities(environment.settingsStore.settings)
        self.compactStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.codexStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.claudeStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        configureButton(for: .compact, item: compactStatusItem)
        configureButton(for: .codex, item: codexStatusItem)
        configureButton(for: .claude, item: claudeStatusItem)
        configureButton(for: .status, item: statusStatusItem)
        observeChanges()
        renderMenuBar()
        // Restore mini window if the user had it open last session.
        miniWindowController.restoreIfNeeded(environment: environment)
        // Pre-build the popover hosting controllers at launch so the first
        // click doesn't pay the SwiftUI initial-layout cost. Deferred onto
        // the next runloop tick so app activation isn't delayed.
        DispatchQueue.main.async { [weak self] in
            self?.warmAllPopovers()
        }
    }

    /// Force-instantiate every popover's SwiftUI tree once. Subsequent shows
    /// reuse the same NSPopover/NSHostingController instances and feel
    /// instantaneous instead of laggy on first click.
    private func warmAllPopovers() {
        for kind in MenuBarItemKind.allCases {
            _ = popover(for: kind)
        }
    }

    private func currentPopoverWidth(for kind: MenuBarItemKind) -> CGFloat {
        let density = environment.settingsStore.settings.popoverDensity(for: kind)
        switch kind {
        case .compact:
            return Theme.overviewDensity(for: density).popoverWidth
        case .codex, .claude:
            return Theme.detailDensity(for: density).popoverWidth
        case .status:
            return Theme.density(for: density).popoverWidth
        }
    }

    private static func snapshotDensities(_ settings: AppSettings) -> [MenuBarItemKind: PopoverDensity] {
        var out: [MenuBarItemKind: PopoverDensity] = [:]
        for kind in MenuBarItemKind.allCases {
            out[kind] = settings.popoverDensity(for: kind)
        }
        return out
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
        popover.contentSize = NSSize(width: width, height: initialPopoverHeight)
        popover.contentViewController = NSHostingController(
            rootView: PopoverRoot(
                kind: kind,
                width: width,
                closePopover: { [weak controller] in controller?.closePopover(kind: kind) },
                onContentHeightChange: { [weak controller] height in controller?.resizePopover(kind: kind, toContentHeight: height) },
                onToggleMiniWindow: { [weak controller] in controller?.toggleMiniWindow() }
            )
                .environmentObject(environment)
                .environmentObject(environment.accountStore)
                .environmentObject(environment.settingsStore)
                .environmentObject(environment.quotaService)
                .environmentObject(environment.serviceStatus)
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
        environment.settingsStore.$settings
            .receive(on: RunLoop.main)
            .sink { [weak self] settings in
                self?.invalidatePopoversIfDensitiesChanged(Self.snapshotDensities(settings))
                self?.renderMenuBar()
            }
            .store(in: &cancellables)

        environment.quotaService.$lastSuccessByAccount
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.renderMenuBar() }
            .store(in: &cancellables)

        environment.quotaService.$lastErrorByAccount
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.renderMenuBar() }
            .store(in: &cancellables)

        environment.accountStore.$accounts
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.renderMenuBar() }
            .store(in: &cancellables)

        environment.serviceStatus.$snapshotByTool
            .receive(on: RunLoop.main)
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
        } else {
            // close any other open popover first to keep behavior consistent
            for (otherKind, other) in popovers where otherKind != kind && other.isShown {
                other.performClose(nil)
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
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

    private func closePopover(kind: MenuBarItemKind) {
        guard let popover = popovers[kind] else { return }
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    private func resizePopover(kind: MenuBarItemKind, toContentHeight height: CGFloat) {
        guard let popover = popovers[kind] else { return }
        guard height.isFinite, height > 0 else { return }
        let maxHeight = maxPopoverHeight(for: popover)
        let resolvedHeight = min(max(height + Self.popoverHeightPadding, Self.minimumPopoverHeight), maxHeight)
        let targetHeight = (resolvedHeight / 2).rounded() * 2
        let width = currentPopoverWidth(for: kind)
        let current = popover.contentSize
        guard abs(current.height - targetHeight) > 1 || abs(current.width - width) > 1 else {
            return
        }
        popover.contentSize = NSSize(width: width, height: targetHeight)
    }

    private func maxPopoverHeight(for popover: NSPopover) -> CGFloat {
        let screen = popover.contentViewController?.view.window?.screen ?? NSScreen.main
        let visibleHeight = screen?.visibleFrame.height ?? 900
        return max(Self.minimumPopoverHeight, visibleHeight - 80)
    }

    private func kindForTag(_ tag: Int) -> MenuBarItemKind {
        switch tag {
        case 1: return .compact
        case 2: return .codex
        case 3: return .claude
        case 4: return .status
        default: return .compact
        }
    }

    private func toggleMiniWindow() {
        miniWindowController.toggle(environment: environment)
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
        for tool in ToolType.allCases {
            for line in usageMenuLines(for: tool) {
                menu.addItem(disabledMenuItem(line))
            }
        }
        menu.addItem(.separator())
        menu.addItem(disabledMenuItem("Service Status"))
        for tool in ToolType.allCases {
            menu.addItem(disabledMenuItem(statusSummaryLine(for: tool)))
        }
        menu.addItem(.separator())
        menu.addItem(actionMenuItem("Refresh", action: #selector(refreshFromContextMenu(_:)), keyEquivalent: "r"))
        menu.addItem(actionMenuItem("Open Mini Window", action: #selector(toggleMiniFromContextMenu(_:))))
        menu.addItem(actionMenuItem("Open Settings", action: #selector(openSettingsFromContextMenu(_:)), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(actionMenuItem("Quit", action: #selector(quitFromContextMenu(_:)), keyEquivalent: "q"))
        return menu
    }

    private func contextTools(for kind: MenuBarItemKind) -> [ToolType] {
        ToolType.allCases
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
        if environment.serviceStatus.inFlight.contains(tool) {
            return "\(tool.statusProviderName) · Checking"
        }
        if environment.serviceStatus.errorByTool[tool] != nil {
            return "\(tool.statusProviderName) · Down"
        }
        guard let snapshot = environment.serviceStatus.snapshotByTool[tool] else {
            return "\(tool.statusProviderName) · Checking"
        }
        let label: String
        switch snapshot.indicator {
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

    @objc private func openSettingsFromContextMenu(_ sender: NSMenuItem) {
        environment.showSettingsWindow()
    }

    @objc private func quitFromContextMenu(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate() {
        miniWindowController.applicationWillTerminate()
    }

    // MARK: - Menu bar text

    private func renderMenuBar() {
        let settings = environment.settingsStore.settings
        let allHidden = MenuBarItemKind.allCases.allSatisfy { !settings.menuBarItem($0).isVisible }
        for kind in MenuBarItemKind.allCases {
            let item = statusItem(for: kind)
            let itemSettings = settings.menuBarItem(kind)
            item.isVisible = allHidden ? kind == .compact : itemSettings.isVisible
            guard let button = item.button else { continue }
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
            button.image = nil
            button.imagePosition = .noImage
            removeTwoRowStatusContent(from: button)
            if kind == .status && itemSettings.layout != .iconOnly {
                installTwoRowImageContent(
                    in: button,
                    item: item,
                    columns: serviceStatusTwoRowColumns(),
                    kind: kind
                )
                continue
            }
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

    private func serviceStatusTwoRowColumns() -> [TwoRowMenuColumn] {
        let top = providerStatusLine(tool: .codex, name: ToolType.codex.statusProviderName)
        let bottom = providerStatusLine(tool: .claude, name: ToolType.claude.statusProviderName)
        return [TwoRowMenuColumn(top: top, bottom: bottom)]
    }

    private func providerStatusLine(tool: ToolType, name: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: "\(name) ",
            attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: MenuBarStatusMetrics.twoRowFontSize, weight: .medium)
            ]
        ))
        let snapshot = environment.serviceStatus.snapshotByTool[tool]
        result.append(NSAttributedString(
            string: "●",
            attributes: [
                .foregroundColor: providerStatusColor(snapshot?.indicator),
                .font: NSFont.systemFont(ofSize: MenuBarStatusMetrics.twoRowFontSize, weight: .bold)
            ]
        ))
        return result
    }

    private func providerStatusColor(_ indicator: StatusIndicator?) -> NSColor {
        guard let indicator else { return NSColor.tertiaryLabelColor }
        switch indicator {
        case .none:         return NSColor.systemGreen
        case .maintenance:  return NSColor.systemBlue
        case .minor:        return NSColor.systemYellow
        case .major:        return NSColor.systemOrange
        case .critical:     return NSColor.systemRed
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
                let field = MenuBarFieldCatalog.field(id: fieldId),
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
            let percent = bucket.displayPercent(settings.displayMode)
            let label = label(for: field, bucket: bucket, itemSettings: itemSettings)
            attributed.append(menuPiece(
                label: label,
                percent: percent,
                color: barColor(for: percent, mode: settings.displayMode),
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
                let field = MenuBarFieldCatalog.field(id: fieldId),
                let bucket = environment.quota(for: field.tool)?.bucket(id: field.bucketId)
            else { return nil }
            let percent = bucket.displayPercent(settings.displayMode)
            return menuTextPiece(
                label: label(for: field, bucket: bucket, itemSettings: itemSettings),
                percent: percent,
                color: barColor(for: percent, mode: settings.displayMode),
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
                let field = MenuBarFieldCatalog.field(id: fieldId),
                let bucket = environment.quota(for: field.tool)?.bucket(id: field.bucketId)
            else { return nil }
            let percent = bucket.displayPercent(settings.displayMode)
            return menuTextPiece(
                label: label(for: field, bucket: bucket, itemSettings: itemSettings),
                percent: percent,
                color: barColor(for: percent, mode: settings.displayMode),
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
        switch kind {
        case .compact: return 1
        case .codex:   return 2
        case .claude:  return 3
        case .status:  return 4
        }
    }

    private func statusItem(for kind: MenuBarItemKind) -> NSStatusItem {
        switch kind {
        case .compact: return compactStatusItem
        case .codex:   return codexStatusItem
        case .claude:  return claudeStatusItem
        case .status:  return statusStatusItem
        }
    }

    private func barColor(for percent: Double, mode: DisplayMode) -> NSColor {
        switch mode {
        case .remaining:
            if percent < 10 { return NSColor.systemRed }
            if percent < 30 { return NSColor.systemOrange }
            return NSColor.systemGreen
        case .used:
            if percent >= 90 { return NSColor.systemRed }
            if percent >= 70 { return NSColor.systemOrange }
            return NSColor.systemGreen
        }
    }
}
