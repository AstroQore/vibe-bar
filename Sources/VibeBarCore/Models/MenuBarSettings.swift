import Foundation

public enum MenuBarItemKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact
    case codex
    case claude
    case status

    public var id: String { rawValue }

    /// Cases that the Settings page is allowed to surface as
    /// independently togglable menu bar items. The other cases
    /// (`.codex` / `.claude` / `.status`) remain in the enum for
    /// stored-settings backward compatibility and for sub-page
    /// routing inside the Overview popover, but the standalone
    /// menu-bar entry is intentionally retired in favour of the
    /// single Overview tile.
    public static let userVisibleCases: [MenuBarItemKind] = [.compact]

    public var isUserVisibleStandalone: Bool {
        Self.userVisibleCases.contains(self)
    }

    public var label: String {
        switch self {
        case .compact: return "Overview"
        case .codex:   return "OpenAI"
        case .claude:  return "Claude"
        case .status:  return "Status"
        }
    }

    public var title: String {
        switch self {
        case .compact: return "VB"
        case .codex:   return "OpenAI"
        case .claude:  return "Claude"
        case .status:  return "●"
        }
    }
}

public enum MenuBarLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case iconOnly
    case singleLine
    case twoRows
    case compact

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .iconOnly: return "Icon Only"
        case .singleLine: return "Single line"
        case .twoRows: return "Two rows"
        case .compact: return "Compact"
        }
    }

    public var showsMenuBarIcon: Bool {
        self == .iconOnly
    }
}

public struct MenuBarItemSettings: Codable, Equatable, Identifiable, Sendable {
    public var kind: MenuBarItemKind
    public var isVisible: Bool
    public var showTitle: Bool
    public var layout: MenuBarLayout
    public var selectedFieldIds: [String]
    public var customLabels: [String: String]

    public var id: MenuBarItemKind { kind }

    public init(
        kind: MenuBarItemKind,
        isVisible: Bool,
        showTitle: Bool,
        layout: MenuBarLayout = .singleLine,
        selectedFieldIds: [String],
        customLabels: [String: String] = [:]
    ) {
        self.kind = kind
        self.isVisible = isVisible
        self.showTitle = showTitle
        self.layout = layout
        self.selectedFieldIds = selectedFieldIds
        self.customLabels = customLabels
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case isVisible
        case showTitle
        case layout
        case selectedFieldIds
        case customLabels
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try c.decode(MenuBarItemKind.self, forKey: .kind)
        self.isVisible = try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        self.showTitle = try c.decodeIfPresent(Bool.self, forKey: .showTitle) ?? true
        self.layout = try c.decodeIfPresent(MenuBarLayout.self, forKey: .layout)
            ?? (kind == .compact ? .iconOnly : .singleLine)
        self.selectedFieldIds = try c.decodeIfPresent([String].self, forKey: .selectedFieldIds) ?? []
        self.customLabels = try c.decodeIfPresent([String: String].self, forKey: .customLabels) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(isVisible, forKey: .isVisible)
        try c.encode(showTitle, forKey: .showTitle)
        try c.encode(layout, forKey: .layout)
        try c.encode(selectedFieldIds, forKey: .selectedFieldIds)
        try c.encode(customLabels, forKey: .customLabels)
    }
}

public struct MenuBarFieldOption: Identifiable, Hashable, Sendable {
    public var id: String
    public var tool: ToolType
    public var bucketId: String
    public var title: String
    public var defaultLabel: String

    public init(
        id: String,
        tool: ToolType,
        bucketId: String,
        title: String,
        defaultLabel: String
    ) {
        self.id = id
        self.tool = tool
        self.bucketId = bucketId
        self.title = title
        self.defaultLabel = defaultLabel
    }
}

public enum MenuBarFieldCatalog {
    public static let codexFields: [MenuBarFieldOption] = [
        option(.codex, "five_hour", "5 Hours", "5h"),
        option(.codex, "weekly", "Weekly", "wk"),
        option(.codex, "gpt_5_3_codex_spark_five_hour", "GPT-5.3 Codex Spark · 5 Hours", "Spark 5h"),
        option(.codex, "gpt_5_3_codex_spark_weekly", "GPT-5.3 Codex Spark · Weekly", "Spark wk")
    ]

    public static let claudeFields: [MenuBarFieldOption] = [
        option(.claude, "five_hour", "5 Hours", "5h"),
        option(.claude, "weekly", "All Models · Weekly", "All wk"),
        option(.claude, "weekly_sonnet", "Sonnet · Weekly", "Sonnet wk"),
        option(.claude, "weekly_design", "Designs · Weekly", "Design wk"),
        option(.claude, "daily_routines", "Daily Routines", "Routines"),
        option(.claude, "weekly_opus", "Opus · Weekly", "Opus wk"),
        option(.claude, "weekly_fable", "Fable · Weekly", "Fable wk"),
        option(.claude, "weekly_oauth_apps", "OAuth Apps · Weekly", "OAuth wk")
    ]

    // Gemini Web (`gemini.google.com`) exposes a 5-hour rolling
    // window and a weekly bucket — that's the entire quota surface
    // the jSf9Qc parser returns, regardless of model. Earlier
    // entries here were per-model CLI ids (Gemini 2.5 Pro / Flash /
    // Lite, Gemini 3 Pro / Flash) from the pre-PR-#45 telemetry
    // adapter the Web parser no longer produces; those ids get
    // migrated to the new pair in `fieldIdMigrations` below.
    public static let geminiFields: [MenuBarFieldOption] = [
        option(.gemini, "five_hour", "5 Hours", "5h"),
        option(.gemini, "weekly", "Weekly", "wk")
    ]

    public static let antigravityFields: [MenuBarFieldOption] = [
        option(.antigravity, "gemini_five_hour", "Gemini Models · 5 Hours", "G 5h"),
        option(.antigravity, "gemini_weekly", "Gemini Models · Weekly", "G wk"),
        option(.antigravity, "claude_gpt_five_hour", "Claude and GPT Models · 5 Hours", "C+G 5h"),
        option(.antigravity, "claude_gpt_weekly", "Claude and GPT Models · Weekly", "C+G wk")
    ]

    public static let grokFields: [MenuBarFieldOption] = [
        option(.grok, "weekly", "Weekly Credits", "wk")
    ]

    public static let allFields: [MenuBarFieldOption] =
        codexFields + claudeFields + geminiFields + antigravityFields + grokFields

    public static func fields(for kind: MenuBarItemKind) -> [MenuBarFieldOption] {
        switch kind {
        case .compact: return allFields
        case .codex:   return codexFields
        case .claude:  return claudeFields
        case .status:  return []
        }
    }

    public static func field(id: String) -> MenuBarFieldOption? {
        allFields.first { $0.id == id }
    }

    public static func fieldId(tool: ToolType, bucketId: String) -> String {
        "\(tool.rawValue).\(bucketId)"
    }

    public static func migratedFieldIds(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for id in ids {
            let resolved = fieldIdMigrations[id] ?? [id]
            for candidate in resolved where seen.insert(candidate).inserted {
                out.append(candidate)
            }
        }
        return out
    }

    public static func migratedCustomLabels(_ labels: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (id, label) in labels {
            let resolved = fieldIdMigrations[id] ?? [id]
            guard resolved.count == 1, let migratedId = resolved.first else { continue }
            out[migratedId] = label
        }
        return out
    }

    private static func option(
        _ tool: ToolType,
        _ bucketId: String,
        _ title: String,
        _ defaultLabel: String
    ) -> MenuBarFieldOption {
        MenuBarFieldOption(
            id: fieldId(tool: tool, bucketId: bucketId),
            tool: tool,
            bucketId: bucketId,
            title: title,
            defaultLabel: defaultLabel
        )
    }

    private static let fieldIdMigrations: [String: [String]] = [
        // Old Gemini CLI per-model fields all roll up to the Web
        // parser's two-bucket pair. We collapse them to a single
        // `gemini.five_hour` since users selecting one model
        // generally cared about a primary quota indicator; the
        // Weekly bucket is right next to it in the catalog.
        "gemini.gemini_pro":             ["gemini.five_hour"],
        "gemini.gemini_flash":           ["gemini.five_hour"],
        "gemini.gemini_flash_lite":      ["gemini.five_hour"],
        "gemini.gemini-2.5-pro":         ["gemini.five_hour"],
        "gemini.gemini-2.5-flash":       ["gemini.five_hour"],
        "gemini.gemini-2.5-flash-lite":  ["gemini.five_hour"],
        "gemini.gemini-3-pro":           ["gemini.five_hour"],
        "gemini.gemini-3-flash":         ["gemini.five_hour"],
        // Antigravity 2.x reports two shared pools, each with a 5-hour
        // and weekly lane. Every legacy per-model selection therefore
        // migrates to the matching pool's 5-hour lane; the weekly lane
        // remains independently selectable beside it.
        "antigravity.claude-sonnet-4-20250514": ["antigravity.claude_gpt_five_hour"],
        "antigravity.claude-sonnet-4-5": ["antigravity.claude_gpt_five_hour"],
        "antigravity.claude-sonnet-4.6-thinking": ["antigravity.claude_gpt_five_hour"],
        "antigravity.claude-opus-4.6-thinking": ["antigravity.claude_gpt_five_hour"],
        "antigravity.gpt-oss-120b-medium": ["antigravity.claude_gpt_five_hour"],
        "antigravity.gemini-2.5-pro": ["antigravity.gemini_five_hour"],
        "antigravity.gemini-3-pro": ["antigravity.gemini_five_hour"],
        "antigravity.gemini-3.1-pro-high": ["antigravity.gemini_five_hour"],
        "antigravity.gemini-3.1-pro-low": ["antigravity.gemini_five_hour"],
        "antigravity.gemini-2.5-flash": ["antigravity.gemini_five_hour"],
        "antigravity.gemini-3-flash": ["antigravity.gemini_five_hour"],
        "antigravity.gemini-3.5-flash-high": ["antigravity.gemini_five_hour"],
        "antigravity.gemini-3.5-flash-medium": ["antigravity.gemini_five_hour"],
        "antigravity.gemini-2.5-flash-lite": ["antigravity.gemini_five_hour"],
        "grok.monthly": ["grok.weekly"]
    ]
}
