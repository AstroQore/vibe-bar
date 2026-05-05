import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var displayMode: DisplayMode
    public var refreshIntervalSeconds: Int
    public var launchAtLogin: Bool
    public var menuBarTextEnabled: Bool
    public var mockEnabled: Bool
    public var claudeUsageMode: ClaudeUsageMode
    public var menuBarItems: [MenuBarItemSettings]
    public var miniWindow: MiniWindowSettings
    /// Per-popover density. Each menu bar item kind has its own density so the
    /// user can keep one popover roomy and another tight.
    public var popoverDensities: [MenuBarItemKind: PopoverDensity]

    public static let `default` = AppSettings(
        displayMode: .remaining,
        refreshIntervalSeconds: 600,
        launchAtLogin: false,
        menuBarTextEnabled: true,
        mockEnabled: false,
        claudeUsageMode: .cliThenWeb,
        menuBarItems: Self.defaultMenuBarItems,
        miniWindow: Self.defaultMiniWindow,
        popoverDensities: Self.defaultPopoverDensities
    )

    public static let defaultMenuBarItems: [MenuBarItemSettings] = [
        MenuBarItemSettings(
            kind: .compact,
            isVisible: true,
            showTitle: false,
            layout: .twoRows,
            selectedFieldIds: [
                "codex.five_hour",
                "codex.weekly",
                "claude.five_hour",
                "claude.weekly"
            ],
            customLabels: [
                "codex.five_hour": "O5",
                "codex.weekly": "w",
                "claude.five_hour": "C5",
                "claude.weekly": "w"
            ]
        ),
        MenuBarItemSettings(
            kind: .codex,
            isVisible: true,
            showTitle: true,
            layout: .singleLine,
            selectedFieldIds: MenuBarFieldCatalog.codexFields.map(\.id)
        ),
        MenuBarItemSettings(
            kind: .claude,
            isVisible: true,
            showTitle: true,
            layout: .singleLine,
            selectedFieldIds: MenuBarFieldCatalog.claudeFields.map(\.id)
        ),
        MenuBarItemSettings(
            kind: .status,
            isVisible: true,
            showTitle: false,
            layout: .singleLine,
            selectedFieldIds: []
        )
    ]

    public static let defaultMiniWindow = MiniWindowSettings(
        selectedFieldIds: MenuBarFieldCatalog.allFields.map(\.id),
        compactSelectedFieldIds: MenuBarFieldCatalog.allFields.map(\.id),
        customLabels: [
            "codex.five_hour": "O5",
            "codex.weekly": "W",
            "claude.five_hour": "C5",
            "claude.weekly": "W"
        ]
    )

    /// New defaults: Overview is roomy (it shows 2 providers stacked), individual
    /// provider popovers are also roomy (only one provider per popover now).
    public static let defaultPopoverDensities: [MenuBarItemKind: PopoverDensity] = [
        .compact: .regular,
        .codex: .regular,
        .claude: .regular,
        .status: .regular
    ]

    public init(
        displayMode: DisplayMode,
        refreshIntervalSeconds: Int,
        launchAtLogin: Bool,
        menuBarTextEnabled: Bool,
        mockEnabled: Bool,
        claudeUsageMode: ClaudeUsageMode = .cliThenWeb,
        menuBarItems: [MenuBarItemSettings] = AppSettings.defaultMenuBarItems,
        miniWindow: MiniWindowSettings = AppSettings.defaultMiniWindow,
        popoverDensities: [MenuBarItemKind: PopoverDensity] = AppSettings.defaultPopoverDensities
    ) {
        self.displayMode = displayMode
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.launchAtLogin = launchAtLogin
        self.menuBarTextEnabled = menuBarTextEnabled
        self.mockEnabled = mockEnabled
        self.claudeUsageMode = claudeUsageMode
        self.menuBarItems = Self.normalizedMenuBarItems(menuBarItems)
        self.miniWindow = miniWindow
        self.popoverDensities = popoverDensities
    }

    private enum CodingKeys: String, CodingKey {
        case displayMode
        case refreshIntervalSeconds
        case launchAtLogin
        case menuBarTextEnabled
        case mockEnabled
        case claudeUsageMode
        case menuBarItems
        case miniWindow
        case popoverDensities
        case popoverDensity   // legacy single-value form
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.displayMode = try c.decodeIfPresent(DisplayMode.self, forKey: .displayMode) ?? Self.default.displayMode
        self.refreshIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .refreshIntervalSeconds) ?? Self.default.refreshIntervalSeconds
        self.launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? Self.default.launchAtLogin
        self.menuBarTextEnabled = try c.decodeIfPresent(Bool.self, forKey: .menuBarTextEnabled) ?? Self.default.menuBarTextEnabled
        self.mockEnabled = try c.decodeIfPresent(Bool.self, forKey: .mockEnabled) ?? Self.default.mockEnabled
        self.claudeUsageMode = try c.decodeIfPresent(ClaudeUsageMode.self, forKey: .claudeUsageMode) ?? Self.default.claudeUsageMode

        // Gemini support was removed; old persisted configs may contain
        // {"kind":"gemini",...} entries that no longer match a known case.
        // Decode each element through a lossy wrapper that silently drops
        // unknown kinds rather than failing the whole array.
        let lossyItems = try c.decodeIfPresent([LossyMenuBarItem].self, forKey: .menuBarItems)
        let decodedItems = lossyItems?.compactMap(\.value) ?? Self.defaultMenuBarItems
        self.menuBarItems = Self.normalizedMenuBarItems(decodedItems)
        self.miniWindow = try c.decodeIfPresent(MiniWindowSettings.self, forKey: .miniWindow) ?? Self.defaultMiniWindow

        if let perKind = try c.decodeIfPresent([String: PopoverDensity].self, forKey: .popoverDensities) {
            var map: [MenuBarItemKind: PopoverDensity] = [:]
            for (raw, value) in perKind {
                if let kind = MenuBarItemKind(rawValue: raw) { map[kind] = value }
            }
            self.popoverDensities = Self.normalizedPopoverDensities(map)
        } else if let legacy = try c.decodeIfPresent(PopoverDensity.self, forKey: .popoverDensity) {
            var map: [MenuBarItemKind: PopoverDensity] = [:]
            for kind in MenuBarItemKind.allCases { map[kind] = legacy }
            self.popoverDensities = map
        } else {
            self.popoverDensities = Self.defaultPopoverDensities
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(displayMode, forKey: .displayMode)
        try c.encode(refreshIntervalSeconds, forKey: .refreshIntervalSeconds)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(menuBarTextEnabled, forKey: .menuBarTextEnabled)
        try c.encode(mockEnabled, forKey: .mockEnabled)
        try c.encode(claudeUsageMode, forKey: .claudeUsageMode)
        try c.encode(menuBarItems, forKey: .menuBarItems)
        try c.encode(miniWindow, forKey: .miniWindow)
        let stringKeyed = Dictionary(uniqueKeysWithValues: popoverDensities.map { ($0.key.rawValue, $0.value) })
        try c.encode(stringKeyed, forKey: .popoverDensities)
    }

    public func menuBarItem(_ kind: MenuBarItemKind) -> MenuBarItemSettings {
        Self.normalizedMenuBarItems(menuBarItems).first { $0.kind == kind }
            ?? Self.defaultMenuBarItems.first { $0.kind == kind }!
    }

    public mutating func setMenuBarItem(_ item: MenuBarItemSettings) {
        var normalized = Self.normalizedMenuBarItems(menuBarItems)
        if let index = normalized.firstIndex(where: { $0.kind == item.kind }) {
            normalized[index] = item
        } else {
            normalized.append(item)
        }
        menuBarItems = Self.normalizedMenuBarItems(normalized)
    }

    public func popoverDensity(for kind: MenuBarItemKind) -> PopoverDensity {
        popoverDensities[kind] ?? Self.defaultPopoverDensities[kind] ?? .regular
    }

    public mutating func setPopoverDensity(_ density: PopoverDensity, for kind: MenuBarItemKind) {
        popoverDensities[kind] = density
    }

    private static func normalizedMenuBarItems(_ items: [MenuBarItemSettings]) -> [MenuBarItemSettings] {
        MenuBarItemKind.allCases.map { kind in
            items.first { $0.kind == kind }.map(migratedMenuBarItem)
                ?? defaultMenuBarItems.first { $0.kind == kind }!
        }
    }

    private static func normalizedPopoverDensities(_ map: [MenuBarItemKind: PopoverDensity]) -> [MenuBarItemKind: PopoverDensity] {
        var out = defaultPopoverDensities
        for (k, v) in map { out[k] = v }
        return out
    }

    private static func migratedMenuBarItem(_ item: MenuBarItemSettings) -> MenuBarItemSettings {
        guard item.kind == .compact else { return item }
        let oldDefaultFieldIds = [
            "codex.five_hour",
            "codex.weekly",
            "claude.five_hour",
            "claude.weekly"
        ]
        let oldDefaultLabels = [
            "codex.five_hour": "O5h",
            "codex.weekly": "Owk",
            "claude.five_hour": "C5h",
            "claude.weekly": "Cwk"
        ]
        if item.showTitle == true,
           item.selectedFieldIds == oldDefaultFieldIds,
           item.customLabels == oldDefaultLabels {
            return defaultMenuBarItems.first { $0.kind == .compact }!
        }
        return item
    }
}

/// Tolerant wrapper used when decoding the persisted `menuBarItems` array.
/// Unknown `kind` values (e.g. legacy "gemini" entries after Gemini support
/// was removed) decode to `nil` instead of throwing, so loading old settings
/// doesn't lose every other entry alongside the bad one.
private struct LossyMenuBarItem: Decodable {
    let value: MenuBarItemSettings?

    init(from decoder: Decoder) throws {
        if let item = try? MenuBarItemSettings(from: decoder) {
            self.value = item
        } else {
            self.value = nil
        }
    }
}

public struct MiniWindowSettings: Codable, Equatable, Sendable {
    public var displayMode: MiniWindowDisplayMode
    /// Fields shown in the regular ring layout.
    public var selectedFieldIds: [String]
    /// Fields shown in the compact vertical-bar layout. Kept separate so the
    /// user can make the tiny mode denser without changing the regular mode.
    public var compactSelectedFieldIds: [String]
    public var customLabels: [String: String]
    public var groupLabels: [String: String]
    /// Whether the mini window was open last time the app quit. Restored on
    /// launch so the user doesn't have to re-toggle every session.
    public var wasOpen: Bool
    /// Saved screen position (NSPanel coordinate space). Optional; nil falls
    /// back to the top-right placement on first run.
    public var savedOriginX: Double?
    public var savedOriginY: Double?
    /// Backing-pixel coordinates recorded alongside the point coordinates for
    /// visual debugging and exact future restoration on the same display scale.
    public var savedPixelOriginX: Double?
    public var savedPixelOriginY: Double?
    public var savedScreenScale: Double?

    public init(
        displayMode: MiniWindowDisplayMode = .regular,
        selectedFieldIds: [String],
        compactSelectedFieldIds: [String]? = nil,
        customLabels: [String: String] = [:],
        groupLabels: [String: String] = [:],
        wasOpen: Bool = false,
        savedOriginX: Double? = nil,
        savedOriginY: Double? = nil,
        savedPixelOriginX: Double? = nil,
        savedPixelOriginY: Double? = nil,
        savedScreenScale: Double? = nil
    ) {
        self.displayMode = displayMode
        self.selectedFieldIds = selectedFieldIds
        self.compactSelectedFieldIds = compactSelectedFieldIds ?? selectedFieldIds
        self.customLabels = customLabels
        self.groupLabels = groupLabels
        self.wasOpen = wasOpen
        self.savedOriginX = savedOriginX
        self.savedOriginY = savedOriginY
        self.savedPixelOriginX = savedPixelOriginX
        self.savedPixelOriginY = savedPixelOriginY
        self.savedScreenScale = savedScreenScale
    }

    private enum CodingKeys: String, CodingKey {
        case displayMode, selectedFieldIds, compactSelectedFieldIds, customLabels, groupLabels, wasOpen
        case savedOriginX, savedOriginY, savedPixelOriginX, savedPixelOriginY, savedScreenScale
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.displayMode = try c.decodeIfPresent(MiniWindowDisplayMode.self, forKey: .displayMode) ?? .regular
        self.selectedFieldIds = try c.decodeIfPresent([String].self, forKey: .selectedFieldIds) ?? []
        self.compactSelectedFieldIds = try c.decodeIfPresent([String].self, forKey: .compactSelectedFieldIds)
            ?? self.selectedFieldIds
        self.customLabels = try c.decodeIfPresent([String: String].self, forKey: .customLabels) ?? [:]
        self.groupLabels = try c.decodeIfPresent([String: String].self, forKey: .groupLabels) ?? [:]
        self.wasOpen = try c.decodeIfPresent(Bool.self, forKey: .wasOpen) ?? false
        self.savedOriginX = try c.decodeIfPresent(Double.self, forKey: .savedOriginX)
        self.savedOriginY = try c.decodeIfPresent(Double.self, forKey: .savedOriginY)
        self.savedPixelOriginX = try c.decodeIfPresent(Double.self, forKey: .savedPixelOriginX)
        self.savedPixelOriginY = try c.decodeIfPresent(Double.self, forKey: .savedPixelOriginY)
        self.savedScreenScale = try c.decodeIfPresent(Double.self, forKey: .savedScreenScale)
    }

    public func fieldIds(for mode: MiniWindowDisplayMode) -> [String] {
        switch mode {
        case .regular: return selectedFieldIds
        case .compact: return compactSelectedFieldIds
        }
    }

    public mutating func setFieldIds(_ ids: [String], for mode: MiniWindowDisplayMode) {
        switch mode {
        case .regular:
            selectedFieldIds = ids
        case .compact:
            compactSelectedFieldIds = ids
        }
    }

    public mutating func toggleDisplayMode() {
        displayMode = displayMode == .regular ? .compact : .regular
    }
}

public enum MiniWindowDisplayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case regular
    case compact

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .regular: return "Regular"
        case .compact: return "Compact"
        }
    }
}

public enum PopoverDensity: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact
    case regular
    case spacious

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .compact:  return "Compact"
        case .regular:  return "Regular"
        case .spacious: return "Spacious"
        }
    }

    public var detail: String {
        switch self {
        case .compact:  return "Tightest spacing, narrowest popover."
        case .regular:  return "Balanced spacing — default."
        case .spacious: return "Roomy spacing for big displays."
        }
    }
}

public enum ClaudeUsageMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case cliThenWeb
    case webThenCli
    case cliOnly
    case webOnly

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .cliThenWeb: return "Claude Code, then Web"
        case .webThenCli: return "Claude Web, then Claude Code"
        case .cliOnly: return "Claude Code only"
        case .webOnly: return "Claude Web only"
        }
    }

    public var detail: String {
        switch self {
        case .cliThenWeb: return "Use Claude Code first; fall back to saved claude.ai cookies."
        case .webThenCli: return "Use saved claude.ai cookies first; fall back to local Claude Code credentials."
        case .cliOnly: return "Use only local Claude Code OAuth credentials."
        case .webOnly: return "Use only saved claude.ai cookies."
        }
    }
}
