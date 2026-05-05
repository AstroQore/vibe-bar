import Foundation

/// Adding a new case requires updating these switch sites:
/// - ToolType.swift (5 vars below)
/// - MenuBarSettings.swift: MenuBarFieldCatalog.fields(for:)
/// - QuotaService.swift: makeDefault adapter map
/// - MockDataProvider.swift: sampleQuota
/// - ServiceStatusClient.swift: fetch (or short-circuit to .unknown)
/// - AccountStore.swift: autoDetect helper
/// - PopoverRoot.swift: emptyMessage / sections
/// - SettingsView.swift: menuItemIcon
/// - StatusItemController.swift: status item tag mapping
/// - MiniQuotaWindowView.swift: providerAccent / providerTitle
public enum ToolType: String, Codable, CaseIterable, Hashable, Sendable {
    case codex
    case claude

    public var displayName: String {
        switch self {
        case .codex:  return "OpenAI - ChatGPT"
        case .claude: return "Anthropic - Claude"
        }
    }

    public var subtitle: String {
        switch self {
        case .codex:  return "CodeX"
        case .claude: return "Claude Code"
        }
    }

    public var menuTitle: String {
        switch self {
        case .codex:  return "OpenAI"
        case .claude: return "Claude"
        }
    }

    public var statusProviderName: String {
        switch self {
        case .codex:  return "OpenAI"
        case .claude: return "Anthropic"
        }
    }

    public var statusPageURL: URL {
        switch self {
        case .codex:  return URL(string: "https://status.openai.com/")!
        case .claude: return URL(string: "https://status.claude.com/")!
        }
    }

    public var statusSummaryAPI: URL {
        URL(string: statusPageURL.absoluteString + "api/v2/summary.json")!
    }

    public var statusIncidentsAPI: URL {
        URL(string: statusPageURL.absoluteString + "api/v2/incidents.json")!
    }

    public var statusComponentsAPI: URL {
        URL(string: statusPageURL.absoluteString + "api/v2/components.json")!
    }

    /// Whether ServiceStatusClient supports fetching live status for this tool.
    public var supportsStatusPage: Bool {
        switch self {
        case .codex, .claude: return true
        }
    }

    /// Whether the local CLI logs include enough data for cost computation.
    public var supportsTokenCost: Bool {
        switch self {
        case .codex, .claude: return true
        }
    }
}
