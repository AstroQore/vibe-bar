import Foundation

/// Adding a new case requires updating these switch sites:
/// - ToolType.swift (computed vars below)
/// - MenuBarSettings.swift: MenuBarFieldCatalog.fields(for:)
/// - QuotaService.swift: makeDefault adapter map
/// - MockDataProvider.swift: sampleQuota
/// - ServiceStatusClient.swift: fetch (or short-circuit on `!supportsStatusPage`)
/// - AccountStore.swift: autoDetect helper
/// - PopoverRoot.swift: emptyMessage / sections
/// - SettingsView.swift: menuItemIcon
/// - StatusItemController.swift: status item tag mapping
/// - MiniQuotaWindowView.swift: providerAccent / providerTitle
/// - ProviderBrandIcon.swift: SF symbol + brand SVG mapping
///
/// Tools split into two tiers:
/// - **Primary** (`.codex`, `.claude`) — full quota + cost + service-status
///   integration, dedicated popover pages, mini-window slots.
/// - **Misc** (`.alibaba`, `.alibabaTokenPlan`, `.gemini`, `.antigravity`,
///   `.copilot`, `.zai`, `.minimax`, `.kimi`, `.cursor`, `.mimo`, `.iflytek`,
///   `.tencentHunyuan`, `.tencentTokenPlan`, `.volcengine`, `.baiduQianfan`,
///   `.openCodeGo`, `.kilo`, `.kiro`, `.ollama`, `.openRouter`, `.warp`) —
///   usage-only cards on the Misc tab.
///   No token-cost scanning, no Atlassian-style status polling.
///
/// `supportsTokenCost` and `supportsStatusPage` short-circuit the cost
/// scanner and the status-page poller for misc providers; most other
/// switch sites only need to add a `default:` arm or guard with
/// `tool.isPrimary`.
public enum ToolType: String, Codable, CaseIterable, Hashable, Sendable {
    case codex
    case claude
    // Misc — usage-only, no cost / status integration.
    case alibaba
    case alibabaTokenPlan
    case gemini
    case antigravity
    case copilot
    case zai
    case minimax
    case kimi
    case cursor
    case mimo
    case iflytek
    case tencentHunyuan
    case tencentTokenPlan
    case volcengine
    case baiduQianfan
    case openCodeGo
    case kilo
    case kiro
    case ollama
    case openRouter
    case warp

    // MARK: - Tier helpers

    public var isPrimary: Bool {
        switch self {
        case .codex, .claude: return true
        case .alibaba, .alibabaTokenPlan, .gemini, .antigravity, .copilot, .zai, .minimax, .kimi, .cursor, .mimo, .iflytek, .tencentHunyuan, .tencentTokenPlan, .volcengine, .baiduQianfan, .openCodeGo, .kilo, .kiro, .ollama, .openRouter, .warp:
            return false
        }
    }

    public var isMisc: Bool { !isPrimary }

    public static var primaryProviders: [ToolType] {
        allCases.filter { $0.isPrimary }
    }

    public static var miscProviders: [ToolType] {
        allCases.filter { $0.isMisc }
    }

    public var supportsTokenCost: Bool {
        isPrimary
    }

    public var supportsStatusPage: Bool {
        isPrimary
    }

    // MARK: - Display

    public var displayName: String {
        switch self {
        case .codex:       return "OpenAI - ChatGPT"
        case .claude:      return "Anthropic - Claude"
        case .alibaba:     return "Alibaba Bailian Coding Plan"
        case .alibabaTokenPlan: return "Alibaba Bailian Token Plan"
        case .gemini:      return "Gemini"
        case .antigravity: return "Google - Antigravity"
        case .copilot:     return "GitHub - Copilot"
        case .zai:         return "Zhipu GLM Coding Plan"
        case .minimax:     return "MiniMax Token Plan"
        case .kimi:        return "Kimi Coding Plan"
        case .cursor:      return "Cursor"
        case .mimo:        return "Xiaomi MiMo Token Plan"
        case .iflytek:     return "iFlytek Spark Coding Plan"
        case .tencentHunyuan:   return "Tencent Hunyuan Coding Plan"
        case .tencentTokenPlan: return "Tencent Hunyuan Token Plan"
        case .volcengine:  return "Volcengine Coding Plan"
        case .baiduQianfan: return "Baidu Qianfan Coding Plan"
        case .openCodeGo:  return "OpenCode Go"
        case .kilo:        return "Kilo"
        case .kiro:        return "Kiro"
        case .ollama:      return "Ollama"
        case .openRouter:  return "OpenRouter"
        case .warp:        return "Warp"
        }
    }

    public var subtitle: String {
        switch self {
        case .codex:       return "CodeX"
        case .claude:      return "Claude Code"
        case .alibaba:     return "Coding Plan"
        case .alibabaTokenPlan: return "Token Plan"
        case .gemini:      return "Usage"
        case .antigravity: return "Local LSP"
        case .copilot:     return "GitHub Copilot"
        case .zai:         return "Coding Plan"
        case .minimax:     return "Token Plan"
        case .kimi:        return "Coding Plan"
        case .cursor:      return "Cursor"
        case .mimo:        return "Token Plan"
        case .iflytek:     return "Coding Plan"
        case .tencentHunyuan:   return "Coding Plan"
        case .tencentTokenPlan: return "Token Plan"
        case .volcengine:  return "Coding Plan"
        case .baiduQianfan: return "Coding Plan"
        case .openCodeGo:  return "Workspace"
        case .kilo:        return "Credits"
        case .kiro:        return "CLI Usage"
        case .ollama:      return "Cloud"
        case .openRouter:  return "Credits"
        case .warp:        return "Warp AI Credits"
        }
    }

    public var menuTitle: String {
        switch self {
        case .codex:       return "OpenAI"
        case .claude:      return "Claude"
        case .alibaba:     return "Alibaba Bailian"
        case .alibabaTokenPlan: return "Alibaba Bailian"
        case .gemini:      return "Gemini"
        case .antigravity: return "Antigravity"
        case .copilot:     return "Copilot"
        case .zai:         return "Zhipu GLM"
        case .minimax:     return "MiniMax"
        case .kimi:        return "Kimi"
        case .cursor:      return "Cursor"
        case .mimo:        return "Xiaomi MiMo"
        case .iflytek:     return "iFlytek Spark"
        case .tencentHunyuan:   return "Tencent Hunyuan"
        case .tencentTokenPlan: return "Tencent Hunyuan"
        case .volcengine:  return "Volcengine"
        case .baiduQianfan: return "Baidu Qianfan"
        case .openCodeGo:  return "OpenCode Go"
        case .kilo:        return "Kilo"
        case .kiro:        return "Kiro"
        case .ollama:      return "Ollama"
        case .openRouter:  return "OpenRouter"
        case .warp:        return "Warp"
        }
    }

    public var statusProviderName: String {
        switch self {
        case .codex:       return "OpenAI"
        case .claude:      return "Anthropic"
        case .alibaba:     return "Alibaba Bailian"
        case .alibabaTokenPlan: return "Alibaba Bailian"
        case .gemini:      return "Gemini"
        case .antigravity: return "Antigravity"
        case .copilot:     return "GitHub"
        case .zai:         return "Z.ai"
        case .minimax:     return "MiniMax"
        case .kimi:        return "Moonshot"
        case .cursor:      return "Cursor"
        case .mimo:        return "Xiaomi"
        case .iflytek:     return "iFlytek"
        case .tencentHunyuan:   return "Tencent Cloud"
        case .tencentTokenPlan: return "Tencent Cloud"
        case .volcengine:  return "Volcengine"
        case .baiduQianfan: return "Baidu Qianfan"
        case .openCodeGo:  return "OpenCode"
        case .kilo:        return "Kilo"
        case .kiro:        return "Kiro"
        case .ollama:      return "Ollama"
        case .openRouter:  return "OpenRouter"
        case .warp:        return "Warp"
        }
    }

    /// Click-through URL for the provider's status / dashboard page.
    /// The Atlassian-style API endpoints (`statusSummaryAPI` etc.) are
    /// only meaningful when `supportsStatusPage` is true.
    public var statusPageURL: URL {
        switch self {
        case .codex:       return URL(string: "https://status.openai.com/")!
        case .claude:      return URL(string: "https://status.claude.com/")!
        case .alibaba:     return URL(string: "https://bailian.console.aliyun.com/")!
        case .alibabaTokenPlan: return URL(string: "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan")!
        case .gemini:      return URL(string: "https://status.cloud.google.com/")!
        case .antigravity: return URL(string: "https://antigravity.google/")!
        case .copilot:     return URL(string: "https://www.githubstatus.com/")!
        case .zai:         return URL(string: "https://www.z.ai/")!
        case .minimax:     return URL(string: "https://platform.minimax.io/")!
        case .kimi:        return URL(string: "https://www.kimi.com/")!
        case .cursor:      return URL(string: "https://status.cursor.com/")!
        case .mimo:        return URL(string: "https://platform.xiaomimimo.com/")!
        case .iflytek:     return URL(string: "https://maas.xfyun.cn/")!
        case .tencentHunyuan:   return URL(string: "https://console.cloud.tencent.com/tokenhub/codingplan")!
        case .tencentTokenPlan: return URL(string: "https://console.cloud.tencent.com/tokenhub/tokenplan")!
        case .volcengine:  return URL(string: "https://console.volcengine.com/ark")!
        case .baiduQianfan: return URL(string: "https://console.bce.baidu.com/qianfan/resource/subscribe")!
        case .openCodeGo:  return URL(string: "https://opencode.ai/")!
        case .kilo:        return URL(string: "https://app.kilo.ai/")!
        case .kiro:        return URL(string: "https://kiro.dev/")!
        case .ollama:      return URL(string: "https://ollama.com/")!
        case .openRouter:  return URL(string: "https://openrouter.ai/")!
        case .warp:        return URL(string: "https://app.warp.dev/")!
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
}
