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
/// Adding a *partial-primary* case (dedicated card outside the two
/// historical primary menu-bar items) also requires:
/// - PrimaryProviderSourcePlanner.swift: a per-provider UsageMode + planner
/// - AccountStore.swift: autoDetect<Provider> helper
/// - AppSettings.swift: dedicated settings struct + lossy migration from
///   `miscProviderInstances`
///
/// Tools split into three tiers:
/// - **Primary** (`.codex`, `.claude`) — full quota + cost + service-status
///   integration, dedicated popover pages, mini-window slots.
/// - **Partial-Primary** (`.gemini`, `.antigravity`, `.grok`) — dedicated
///   popover sub-page (Google AI dual page for Gemini+Antigravity, single
///   provider page for Grok) + SettingsView panel. These can still opt into
///   token-cost scanning and status polling as provider data becomes known.
/// - **Misc** (`.alibaba`, `.alibabaTokenPlan`, `.copilot`, `.zai`,
///   `.minimax`, `.kimi`, `.cursor`, `.mimo`, `.iflytek`,
///   `.tencentHunyuan`, `.tencentTokenPlan`, `.volcengine`,
///   `.volcengineAgentPlan`, `.baiduQianfan`,
///   `.openCodeGo`, `.kilo`, `.kiro`, `.ollama`, `.openRouter`, `.warp`) —
///   usage-only cards on the Misc tab.
///
/// `supportsTokenCost` and `supportsStatusPage` short-circuit the cost
/// scanner and the status-page poller; `supportsDedicatedCard` is the
/// predicate the dedicated-card UI uses; `isMiscPageProvider` is the
/// filter the Misc tab and `defaultMiscProviderInstances` use. Note
/// `isMisc` still reports true for the partial-primary pair so legacy
/// `tool.isMisc` callers keep their original semantics — new misc-only
/// code paths should switch to `isMiscPageProvider`.
public enum ToolType: String, Codable, CaseIterable, Hashable, Sendable {
    case codex
    case claude
    // Misc — usage-only, no cost / status integration.
    case alibaba
    case alibabaTokenPlan
    case gemini
    case antigravity
    case grok
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
    case volcengineAgentPlan
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
        case .alibaba, .alibabaTokenPlan, .gemini, .antigravity, .grok, .copilot, .zai, .minimax, .kimi, .cursor, .mimo, .iflytek, .tencentHunyuan, .tencentTokenPlan, .volcengine, .volcengineAgentPlan, .baiduQianfan, .openCodeGo, .kilo, .kiro, .ollama, .openRouter, .warp:
            return false
        }
    }

    public var isMisc: Bool { !isPrimary }

    /// True for providers that get a dedicated popover card, a SettingsView
    /// panel, and multi-source credential fallback. Primary providers are a
    /// proper subset of this set; partial-primary providers (Gemini,
    /// Antigravity, Grok) live here without dedicated menu-bar item kinds.
    public var supportsDedicatedCard: Bool {
        switch self {
        case .codex, .claude, .gemini, .antigravity, .grok: return true
        case .alibaba, .alibabaTokenPlan, .copilot, .zai, .minimax, .kimi, .cursor, .mimo, .iflytek, .tencentHunyuan, .tencentTokenPlan, .volcengine, .volcengineAgentPlan, .baiduQianfan, .openCodeGo, .kilo, .kiro, .ollama, .openRouter, .warp:
            return false
        }
    }

    /// True for dedicated-card providers that do not have their own
    /// `MenuBarItemKind`.
    public var isPartialPrimary: Bool {
        supportsDedicatedCard && !isPrimary
    }

    /// True for providers that show up on the Misc settings tab and in
    /// `defaultMiscProviderInstances`. Equivalent to "no dedicated card" —
    /// narrower than `isMisc`, which still reports true for the
    /// partial-primary pair so legacy `tool.isMisc` callers keep working.
    public var isMiscPageProvider: Bool {
        !supportsDedicatedCard
    }

    public static var primaryProviders: [ToolType] {
        allCases.filter { $0.isPrimary }
    }

    public static var miscProviders: [ToolType] {
        allCases.filter { $0.isMisc }
    }

    public static var dedicatedCardProviders: [ToolType] {
        allCases.filter { $0.supportsDedicatedCard }
    }

    public static var partialPrimaryProviders: [ToolType] {
        allCases.filter { $0.isPartialPrimary }
    }

    public static var costAwareProviders: [ToolType] {
        allCases.filter { $0.supportsTokenCost }
    }

    public static var statusPageProviders: [ToolType] {
        allCases.filter { $0.supportsStatusPage }
    }

    public static var combinedStatusPageProviders: [ToolType] {
        coreProviderRepresentatives
    }

    /// One representative tool for each L1 provider shown in Overview and
    /// Settings. Google AI is represented by Gemini; AntiGravity maps back to
    /// the same provider so one visibility switch controls the combined card.
    public static var coreProviderRepresentatives: [ToolType] {
        [.codex, .claude, .gemini, .grok]
    }

    public var coreProviderRepresentative: ToolType? {
        switch self {
        case .codex, .claude, .gemini, .grok:
            return self
        case .antigravity:
            return .gemini
        case .alibaba, .alibabaTokenPlan, .copilot, .zai, .minimax, .kimi,
             .cursor, .mimo, .iflytek, .tencentHunyuan, .tencentTokenPlan,
             .volcengine, .volcengineAgentPlan, .baiduQianfan, .openCodeGo,
             .kilo, .kiro, .ollama, .openRouter, .warp:
            return nil
        }
    }

    public static var miscPageProviders: [ToolType] {
        allCases.filter { $0.isMiscPageProvider }
    }

    /// The two Google AI providers that render side-by-side in the
    /// Overview popover's "Google AI" page.
    public static var googleAIPair: [ToolType] {
        [.gemini, .antigravity]
    }

    /// True for providers we can build a per-token cost panel for.
    /// - `.gemini` reads Gemini CLI's OpenTelemetry log
    ///   (`~/.gemini/telemetry.log` / per-project OTLP collector log)
    ///   *and* the persistent chat-history JSONL files under
    ///   `~/.gemini/tmp/*/chats/session-*.jsonl` (each `type:gemini`
    ///   message carries `tokens.{input,output,cached,thoughts}`).
    /// - `.antigravity` reads the AntiGravity IDE's per-conversation
    ///   SQLite databases under `~/.gemini/antigravity/conversations/*.db`;
    ///   the `gen_metadata.data` protobuf blob exposes per-turn
    ///   input / output / cumulative cache-read counts and model id. The
    ///   `~/.gemini/antigravity-cli/conversations/*.pb` files use an
    ///   unidentified container format and are skipped — accept that
    ///   CLI-only AntiGravity usage stays dark for now.
    /// - `.grok` reads `~/.grok/sessions/**/updates.jsonl` and takes
    ///   per-session deltas of the cumulative `params._meta.totalTokens`
    ///   field. Grok exposes only a session-level total (no per-call
    ///   input / output split), so the USD figure is a blended
    ///   approximation against the published `grok-build` rate.
    public var supportsTokenCost: Bool {
        switch self {
        case .codex, .claude, .gemini, .antigravity, .grok: return true
        case .alibaba, .alibabaTokenPlan, .copilot, .zai, .minimax, .kimi, .cursor, .mimo, .iflytek, .tencentHunyuan, .tencentTokenPlan, .volcengine, .volcengineAgentPlan, .baiduQianfan, .openCodeGo, .kilo, .kiro, .ollama, .openRouter, .warp:
            return false
        }
    }

    /// True for providers we can poll a status feed for. `.gemini` and
    /// `.antigravity` share the Google Apps Status dashboard feed
    /// (`https://www.google.com/appsstatus/dashboard/incidents.json`,
    /// filtered to product id `npdyhgECDJ6tB66MxXyo` = "Gemini").
    /// Grok reads the xAI service-status HTML at `https://status.x.ai/`.
    /// Codex / Claude use their own Atlassian / incident.io feeds.
    public var supportsStatusPage: Bool {
        switch self {
        case .codex, .claude, .gemini, .antigravity, .grok: return true
        case .alibaba, .alibabaTokenPlan, .copilot, .zai, .minimax, .kimi, .cursor, .mimo, .iflytek, .tencentHunyuan, .tencentTokenPlan, .volcengine, .volcengineAgentPlan, .baiduQianfan, .openCodeGo, .kilo, .kiro, .ollama, .openRouter, .warp:
            return false
        }
    }

    // MARK: - Display
    //
    // Every UI surface that needs to identify a provider picks one of
    // three explicit levels from `hierarchy` and stays at that level:
    //
    //   L1 vendor  → who bills you (OpenAI / Anthropic / Google / xAI)
    //   L2 product → what users call the AI (ChatGPT / Claude / Gemini / Grok)
    //   L3 tool    → the specific surface Vibe Bar tracks (Codex,
    //                Claude Code, Gemini Web, AntiGravity, Grok Build)
    //
    // The catalog in `ProviderHierarchyCatalog` is the single source of
    // truth — renaming a provider is one edit there, not a hunt across
    // five `switch` statements. The legacy `displayName` / `menuTitle`
    // / `statusProviderName` accessors all derive from the same entry.
    // Misc-provider tools (Alibaba / Tencent / Volcengine / etc.) get
    // best-effort hierarchy entries too so callers don't have to
    // special-case them, but the consistency contract only applies to
    // the five primary tools (`[.codex, .claude] +
    // ToolType.partialPrimaryProviders`).

    /// The single hierarchy entry every L1/L2/L3 accessor reads from.
    public var hierarchy: ProviderHierarchy {
        switch self {
        case .codex:            return ProviderHierarchyCatalog.codex
        case .claude:           return ProviderHierarchyCatalog.claude
        case .gemini:           return ProviderHierarchyCatalog.gemini
        case .antigravity:      return ProviderHierarchyCatalog.antigravity
        case .grok:             return ProviderHierarchyCatalog.grok
        case .copilot:          return ProviderHierarchyCatalog.copilot
        case .alibaba:          return ProviderHierarchyCatalog.alibaba
        case .alibabaTokenPlan: return ProviderHierarchyCatalog.alibabaTokenPlan
        case .zai:              return ProviderHierarchyCatalog.zai
        case .minimax:          return ProviderHierarchyCatalog.minimax
        case .kimi:             return ProviderHierarchyCatalog.kimi
        case .cursor:           return ProviderHierarchyCatalog.cursor
        case .mimo:             return ProviderHierarchyCatalog.mimo
        case .iflytek:          return ProviderHierarchyCatalog.iflytek
        case .tencentHunyuan:   return ProviderHierarchyCatalog.tencentHunyuan
        case .tencentTokenPlan: return ProviderHierarchyCatalog.tencentTokenPlan
        case .volcengine:       return ProviderHierarchyCatalog.volcengine
        case .volcengineAgentPlan: return ProviderHierarchyCatalog.volcengineAgentPlan
        case .baiduQianfan:     return ProviderHierarchyCatalog.baiduQianfan
        case .openCodeGo:       return ProviderHierarchyCatalog.openCodeGo
        case .kilo:             return ProviderHierarchyCatalog.kilo
        case .kiro:             return ProviderHierarchyCatalog.kiro
        case .ollama:           return ProviderHierarchyCatalog.ollama
        case .openRouter:       return ProviderHierarchyCatalog.openRouter
        case .warp:             return ProviderHierarchyCatalog.warp
        }
    }

    /// Level 1 — the vendor that issues the plan / bills the account.
    public var vendorName: String { hierarchy.vendor }

    /// Level 2 — the product brand a user identifies with.
    public var productName: String { hierarchy.product }

    /// Level 3 — the specific surface Vibe Bar tracks usage for.
    public var toolName: String { hierarchy.tool }

    /// Long-form name used by Spotlight-y surfaces (system menu items,
    /// account-list aliases). Primary tools use the L3 tool name from
    /// `hierarchy` directly; misc tools keep their curated long form
    /// because the hierarchy can't capture distinctions like
    /// "Alibaba Bailian Coding Plan" vs "Alibaba Bailian Token Plan".
    public var displayName: String {
        switch self {
        case .codex, .claude, .gemini, .antigravity, .grok:
            return hierarchy.tool
        case .alibaba:          return "Alibaba Bailian Coding Plan"
        case .alibabaTokenPlan: return "Alibaba Bailian Token Plan"
        case .copilot:          return "GitHub - Copilot"
        case .zai:              return "Zhipu GLM Coding Plan"
        case .minimax:          return "MiniMax Token Plan"
        case .kimi:             return "Kimi Coding Plan"
        case .cursor:           return "Cursor"
        case .mimo:             return "Xiaomi MiMo Token Plan"
        case .iflytek:          return "iFlytek Spark Coding Plan"
        case .tencentHunyuan:   return "Tencent Hunyuan Coding Plan"
        case .tencentTokenPlan: return "Tencent Hunyuan Token Plan"
        case .volcengine:       return "Volcengine Coding Plan"
        case .volcengineAgentPlan: return "Volcengine Agent Plan"
        case .baiduQianfan:     return "Baidu Qianfan Coding Plan"
        case .openCodeGo:       return "OpenCode Go"
        case .kilo:             return "Kilo"
        case .kiro:             return "Kiro"
        case .ollama:           return "Ollama"
        case .openRouter:       return "OpenRouter"
        case .warp:             return "Warp"
        }
    }

    /// Card subtitle rendered under the L2 product title. For the
    /// primary five tools this is the L3 tool name from `hierarchy`
    /// so the Overview popover reads "Gemini · Gemini Web" / "Gemini ·
    /// AntiGravity" instead of the old ad-hoc "Usage" / "Local LSP"
    /// labels. Misc tools keep their plan-flavour descriptor since
    /// they distinguish multiple plans inside one product (Coding
    /// Plan vs Token Plan).
    public var subtitle: String {
        switch self {
        case .codex, .claude, .gemini, .antigravity, .grok:
            return hierarchy.tool
        case .alibaba:          return "Coding Plan"
        case .alibabaTokenPlan: return "Token Plan"
        case .copilot:          return "GitHub Copilot"
        case .zai:              return "Coding Plan"
        case .minimax:          return "Token Plan"
        case .kimi:             return "Coding Plan"
        case .cursor:           return "Cursor"
        case .mimo:             return "Token Plan"
        case .iflytek:          return "Coding Plan"
        case .tencentHunyuan:   return "Coding Plan"
        case .tencentTokenPlan: return "Token Plan"
        case .volcengine:       return "Coding Plan"
        case .volcengineAgentPlan: return "Agent Plan"
        case .baiduQianfan:     return "Coding Plan"
        case .openCodeGo:       return "Workspace"
        case .kilo:             return "Credits"
        case .kiro:             return "CLI Usage"
        case .ollama:           return "Cloud"
        case .openRouter:       return "Credits"
        case .warp:             return "Warp AI Credits"
        }
    }

    /// L2 product family — what users call the AI brand. Used by
    /// menu-bar tile titles, popover sub-page headers, and anywhere
    /// the surface should pick one consistent level across all tools.
    /// Primary tools take their L2 product directly from `hierarchy`;
    /// misc tools keep curated forms that prefix the vendor for
    /// disambiguation (e.g. "Tencent Hunyuan" rather than bare
    /// "Hunyuan", which would clash with other Tencent surfaces).
    public var menuTitle: String {
        switch self {
        case .codex, .claude, .gemini, .antigravity, .grok:
            return hierarchy.product
        case .alibaba, .alibabaTokenPlan: return "Bailian"
        case .copilot:          return "Copilot"
        case .zai:              return "Zhipu GLM"
        case .minimax:          return "MiniMax"
        case .kimi:             return "Kimi"
        case .cursor:           return "Cursor"
        case .mimo:             return "Xiaomi MiMo"
        case .iflytek:          return "iFlytek Spark"
        case .tencentHunyuan, .tencentTokenPlan: return "Tencent Hunyuan"
        case .volcengine, .volcengineAgentPlan: return "Volcengine"
        case .baiduQianfan:     return "Baidu Qianfan"
        case .openCodeGo:       return "OpenCode Go"
        case .kilo:             return "Kilo"
        case .kiro:             return "Kiro"
        case .ollama:           return "Ollama"
        case .openRouter:       return "OpenRouter"
        case .warp:             return "Warp"
        }
    }

    /// L1 vendor name — used by ServiceStatusCard and any surface
    /// that should pick one consistent level across all tools. The
    /// five primary tools all roll up to four vendors (OpenAI,
    /// Anthropic, Google, xAI); `.antigravity` shares Google's
    /// status feed with `.gemini` for the same reason.
    public var statusProviderName: String {
        switch self {
        case .codex, .claude, .gemini, .antigravity, .grok:
            return hierarchy.vendor
        case .alibaba, .alibabaTokenPlan: return "Alibaba"
        case .copilot:          return "GitHub"
        case .zai:              return "Z.ai"
        case .minimax:          return "MiniMax"
        case .kimi:             return "Moonshot"
        case .cursor:           return "Cursor"
        case .mimo:             return "Xiaomi"
        case .iflytek:          return "iFlytek"
        case .tencentHunyuan, .tencentTokenPlan: return "Tencent Cloud"
        case .volcengine, .volcengineAgentPlan: return "Volcengine"
        case .baiduQianfan:     return "Baidu Qianfan"
        case .openCodeGo:       return "OpenCode"
        case .kilo:             return "Kilo"
        case .kiro:             return "Kiro"
        case .ollama:           return "Ollama"
        case .openRouter:       return "OpenRouter"
        case .warp:             return "Warp"
        }
    }

    /// Click-through URL for the provider's status / dashboard page.
    /// The Statuspage-style API endpoints (`statusSummaryAPI` etc.) are
    /// meaningful only for providers backed by those APIs; xAI/Grok is
    /// scraped from HTML at this URL instead.
    public var statusPageURL: URL {
        switch self {
        case .codex:       return URL(string: "https://status.openai.com/")!
        case .claude:      return URL(string: "https://status.claude.com/")!
        case .alibaba:     return URL(string: "https://bailian.console.aliyun.com/")!
        case .alibabaTokenPlan: return URL(string: "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan")!
        case .gemini:      return URL(string: "https://status.cloud.google.com/")!
        case .antigravity: return URL(string: "https://antigravity.google/")!
        case .grok:        return URL(string: "https://status.x.ai/")!
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
        case .volcengineAgentPlan: return URL(string: "https://console.volcengine.com/ark/region:ark+cn-beijing/openManagement?advancedActiveKey=agentPlan")!
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
