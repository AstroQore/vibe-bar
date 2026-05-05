import Foundation

public enum MenuBarItemKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact
    case codex
    case claude
    case status

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .compact: return "Compact"
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
    case singleLine
    case twoRows

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .singleLine: return "Single line"
        case .twoRows: return "Two rows"
        }
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
            ?? (kind == .compact ? .twoRows : .singleLine)
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
        option(.claude, "weekly_oauth_apps", "OAuth Apps · Weekly", "OAuth wk"),
        option(.claude, "iguana_necktie", "Iguana · Weekly", "Iguana wk")
    ]

    public static let allFields: [MenuBarFieldOption] = codexFields + claudeFields

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
}
