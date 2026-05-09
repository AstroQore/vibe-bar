import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var displayMode: DisplayMode
    public var refreshIntervalSeconds: Int
    public var launchAtLogin: Bool
    public var menuBarTextEnabled: Bool
    public var mockEnabled: Bool
    public var codexUsageMode: CodexUsageMode
    public var claudeUsageMode: ClaudeUsageMode
    public var menuBarItems: [MenuBarItemSettings]
    public var miniWindow: MiniWindowSettings
    /// Per-popover density. Each menu bar item kind has its own density so the
    /// user can keep one popover roomy and another tight.
    public var popoverDensities: [MenuBarItemKind: PopoverDensity]
    /// Optional user-visible plan badge overrides. Empty means "Auto".
    public var providerPlanLabels: [ToolType: String]
    /// Per-misc-provider non-sensitive config (source mode, region,
    /// enterprise host, etc.). Sensitive credentials live in Keychain
    /// (`MiscCredentialStore` / `CookieHeaderCache`), never in this map. The
    /// lossy `init(from:)` strips any sensitive-looking keys on
    /// decode — see `MiscProviderSettings.sanitize`.
    public var miscProviders: [ToolType: MiscProviderSettings]
    public var costData: CostDataSettings

    public static let `default` = AppSettings(
        displayMode: .remaining,
        refreshIntervalSeconds: 600,
        launchAtLogin: false,
        menuBarTextEnabled: true,
        mockEnabled: false,
        codexUsageMode: .auto,
        claudeUsageMode: .auto,
        menuBarItems: Self.defaultMenuBarItems,
        miniWindow: Self.defaultMiniWindow,
        popoverDensities: Self.defaultPopoverDensities,
        providerPlanLabels: Self.defaultProviderPlanLabels,
        miscProviders: Self.defaultMiscProviders,
        costData: .default
    )

    public static let defaultMenuBarItems: [MenuBarItemSettings] = [
        MenuBarItemSettings(
            kind: .compact,
            isVisible: true,
            showTitle: false,
            layout: .iconOnly,
            selectedFieldIds: [
                "codex.five_hour",
                "codex.weekly",
                "claude.five_hour",
                "claude.weekly"
            ],
            customLabels: [:]
        ),
        MenuBarItemSettings(
            kind: .codex,
            isVisible: false,
            showTitle: true,
            layout: .singleLine,
            selectedFieldIds: MenuBarFieldCatalog.codexFields.map(\.id)
        ),
        MenuBarItemSettings(
            kind: .claude,
            isVisible: false,
            showTitle: true,
            layout: .singleLine,
            selectedFieldIds: MenuBarFieldCatalog.claudeFields.map(\.id)
        ),
        MenuBarItemSettings(
            kind: .status,
            isVisible: false,
            showTitle: false,
            layout: .iconOnly,
            selectedFieldIds: []
        )
    ]

    public static let defaultMiniWindow = MiniWindowSettings(
        selectedFieldIds: MenuBarFieldCatalog.allFields.map(\.id),
        compactSelectedFieldIds: MenuBarFieldCatalog.allFields.map(\.id),
        customLabels: [:]
    )

    /// New defaults: Overview is roomy (it shows 2 providers stacked), individual
    /// provider popovers are also roomy (only one provider per popover now).
    public static let defaultPopoverDensities: [MenuBarItemKind: PopoverDensity] = [
        .compact: .regular,
        .codex: .regular,
        .claude: .regular,
        .status: .regular
    ]

    public static let defaultProviderPlanLabels: [ToolType: String] = [:]

    /// Default `MiscProviderSettings` for every misc provider. Source
    /// selection is intentionally automatic and not exposed in the UI;
    /// region / enterprise host remain as provider-specific knobs.
    public static var defaultMiscProviders: [ToolType: MiscProviderSettings] {
        var out: [ToolType: MiscProviderSettings] = [:]
        for tool in ToolType.miscProviders {
            out[tool] = .default
        }
        return out
    }

    public init(
        displayMode: DisplayMode,
        refreshIntervalSeconds: Int,
        launchAtLogin: Bool,
        menuBarTextEnabled: Bool,
        mockEnabled: Bool,
        codexUsageMode: CodexUsageMode = .auto,
        claudeUsageMode: ClaudeUsageMode = .auto,
        menuBarItems: [MenuBarItemSettings] = AppSettings.defaultMenuBarItems,
        miniWindow: MiniWindowSettings = AppSettings.defaultMiniWindow,
        popoverDensities: [MenuBarItemKind: PopoverDensity] = AppSettings.defaultPopoverDensities,
        providerPlanLabels: [ToolType: String] = AppSettings.defaultProviderPlanLabels,
        miscProviders: [ToolType: MiscProviderSettings] = AppSettings.defaultMiscProviders,
        costData: CostDataSettings = .default
    ) {
        self.displayMode = displayMode
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.launchAtLogin = launchAtLogin
        self.menuBarTextEnabled = menuBarTextEnabled
        self.mockEnabled = false
        self.codexUsageMode = codexUsageMode
        self.claudeUsageMode = claudeUsageMode
        self.menuBarItems = Self.normalizedMenuBarItems(menuBarItems)
        self.miniWindow = miniWindow
        self.popoverDensities = popoverDensities
        self.providerPlanLabels = Self.normalizedProviderPlanLabels(providerPlanLabels)
        self.miscProviders = Self.normalizedMiscProviders(miscProviders)
        self.costData = costData
    }

    private enum CodingKeys: String, CodingKey {
        case displayMode
        case refreshIntervalSeconds
        case launchAtLogin
        case menuBarTextEnabled
        case mockEnabled
        case codexUsageMode
        case claudeUsageMode
        case menuBarItems
        case miniWindow
        case popoverDensities
        case popoverDensity   // legacy single-value form
        case providerPlanLabels
        case miscProviders
        case costData
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.displayMode = try c.decodeIfPresent(DisplayMode.self, forKey: .displayMode) ?? Self.default.displayMode
        self.refreshIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .refreshIntervalSeconds) ?? Self.default.refreshIntervalSeconds
        self.launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? Self.default.launchAtLogin
        self.menuBarTextEnabled = try c.decodeIfPresent(Bool.self, forKey: .menuBarTextEnabled) ?? Self.default.menuBarTextEnabled
        self.mockEnabled = false
        self.codexUsageMode = try c.decodeIfPresent(CodexUsageMode.self, forKey: .codexUsageMode) ?? Self.default.codexUsageMode
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

        if let labels = try c.decodeIfPresent([String: String].self, forKey: .providerPlanLabels) {
            var map: [ToolType: String] = [:]
            for (raw, value) in labels {
                if let tool = ToolType(rawValue: raw) { map[tool] = value }
            }
            self.providerPlanLabels = Self.normalizedProviderPlanLabels(map)
        } else {
            self.providerPlanLabels = Self.defaultProviderPlanLabels
        }

        // Misc providers: lossy decode keyed by ToolType raw value.
        // Unknown ToolType keys (typo, removed provider) are silently
        // dropped. `MiscProviderSettings`' own decoder rejects fields
        // whose names look like secrets — together they keep
        // settings.json minimal and credential-free.
        if let raw = try c.decodeIfPresent([String: MiscProviderSettings].self, forKey: .miscProviders) {
            var map: [ToolType: MiscProviderSettings] = [:]
            for (key, value) in raw {
                if let tool = ToolType(rawValue: key), tool.isMisc { map[tool] = value }
            }
            self.miscProviders = Self.normalizedMiscProviders(map)
        } else {
            self.miscProviders = Self.defaultMiscProviders
        }

        self.costData = try c.decodeIfPresent(CostDataSettings.self, forKey: .costData) ?? .default
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(displayMode, forKey: .displayMode)
        try c.encode(refreshIntervalSeconds, forKey: .refreshIntervalSeconds)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(menuBarTextEnabled, forKey: .menuBarTextEnabled)
        try c.encode(mockEnabled, forKey: .mockEnabled)
        try c.encode(codexUsageMode, forKey: .codexUsageMode)
        try c.encode(claudeUsageMode, forKey: .claudeUsageMode)
        try c.encode(menuBarItems, forKey: .menuBarItems)
        try c.encode(miniWindow, forKey: .miniWindow)
        let stringKeyed = Dictionary(uniqueKeysWithValues: popoverDensities.map { ($0.key.rawValue, $0.value) })
        try c.encode(stringKeyed, forKey: .popoverDensities)
        let planLabels = Dictionary(uniqueKeysWithValues: providerPlanLabels.map { ($0.key.rawValue, $0.value) })
        try c.encode(planLabels, forKey: .providerPlanLabels)
        let miscRaw = Dictionary(uniqueKeysWithValues: miscProviders.map { ($0.key.rawValue, $0.value) })
        try c.encode(miscRaw, forKey: .miscProviders)
        try c.encode(costData, forKey: .costData)
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

    public func planBadgeLabel(
        for tool: ToolType,
        quotaPlan: String? = nil,
        accountPlan: String? = nil
    ) -> String? {
        if let override = Self.normalizedProviderPlanLabels(providerPlanLabels)[tool] {
            return override
        }
        if let label = ProviderPlanDisplay.displayName(for: tool, rawPlan: quotaPlan) {
            return label
        }
        return ProviderPlanDisplay.displayName(for: tool, rawPlan: accountPlan)
    }

    public mutating func setProviderPlanLabel(_ label: String?, for tool: ToolType) {
        var labels = providerPlanLabels
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            labels.removeValue(forKey: tool)
        } else {
            labels[tool] = trimmed
        }
        providerPlanLabels = Self.normalizedProviderPlanLabels(labels)
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

    private static func normalizedProviderPlanLabels(_ labels: [ToolType: String]) -> [ToolType: String] {
        var out: [ToolType: String] = [:]
        for (tool, label) in labels {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out[tool] = trimmed }
        }
        return out
    }

    /// Fill in defaults for any misc provider missing from the
    /// incoming map, and drop entries for non-misc tools.
    private static func normalizedMiscProviders(_ map: [ToolType: MiscProviderSettings]) -> [ToolType: MiscProviderSettings] {
        var out: [ToolType: MiscProviderSettings] = [:]
        for tool in ToolType.miscProviders {
            out[tool] = (map[tool] ?? .default).automaticSourceSelection
        }
        return out
    }

    public func miscProvider(_ tool: ToolType) -> MiscProviderSettings {
        precondition(tool.isMisc, "miscProvider lookup requested for primary tool: \(tool)")
        return miscProviders[tool] ?? .default
    }

    public mutating func setMiscProvider(_ settings: MiscProviderSettings, for tool: ToolType) {
        precondition(tool.isMisc, "setMiscProvider lookup requested for primary tool: \(tool)")
        miscProviders[tool] = settings
        miscProviders = Self.normalizedMiscProviders(miscProviders)
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
    case auto
    case oauthThenCliThenWeb
    case cliThenWeb
    case webThenCli
    case oauthOnly
    case cliOnly
    case webOnly

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto: return "Auto"
        case .oauthThenCliThenWeb: return "OAuth, then Claude Code, then Web"
        case .cliThenWeb: return "Claude Code, then Web"
        case .webThenCli: return "Claude Web, then Claude Code"
        case .oauthOnly: return "OAuth only"
        case .cliOnly: return "Claude Code only"
        case .webOnly: return "Claude Web only"
        }
    }

    public var detail: String {
        switch self {
        case .auto: return "Use saved claude.ai cookies first; fall back to Claude OAuth and Claude Code."
        case .oauthThenCliThenWeb: return "Use Claude OAuth first; fall back to Claude Code and saved claude.ai cookies."
        case .cliThenWeb: return "Use Claude Code first; fall back to saved claude.ai cookies."
        case .webThenCli: return "Use saved claude.ai cookies first; fall back to Claude Code and OAuth."
        case .oauthOnly: return "Use only Claude OAuth credentials."
        case .cliOnly: return "Use only local Claude Code OAuth credentials."
        case .webOnly: return "Use only saved claude.ai cookies."
        }
    }
}

public struct CostDataSettings: Codable, Equatable, Sendable {
    public static let unlimitedRetentionDays = 0
    public static let defaultRetentionDays = unlimitedRetentionDays
    public static let maximumRetentionDays = 365 * 3
    public static let retentionOptions = [unlimitedRetentionDays, 30, 90, 365, 365 * 3]
    public static let `default` = CostDataSettings()

    public var retentionDays: Int
    public var privacyModeEnabled: Bool

    public init(
        retentionDays: Int = Self.defaultRetentionDays,
        privacyModeEnabled: Bool = false
    ) {
        self.retentionDays = Self.normalizedRetentionDays(retentionDays)
        self.privacyModeEnabled = privacyModeEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case retentionDays, privacyModeEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? Self.defaultRetentionDays
        self.retentionDays = Self.normalizedRetentionDays(retentionDays)
        self.privacyModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .privacyModeEnabled) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.normalizedRetentionDays(retentionDays), forKey: .retentionDays)
        try c.encode(privacyModeEnabled, forKey: .privacyModeEnabled)
    }

    public static func normalizedRetentionDays(_ raw: Int) -> Int {
        if raw <= 0 { return unlimitedRetentionDays }
        return min(max(1, raw), maximumRetentionDays)
    }

    public static func isUnlimitedRetention(_ days: Int) -> Bool {
        normalizedRetentionDays(days) == unlimitedRetentionDays
    }
}
