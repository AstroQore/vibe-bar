import Foundation

/// Three-level vendor / product / tool hierarchy used everywhere the
/// UI needs to identify a provider at a single, consistent level.
///
/// - `vendor` (L1) — the enterprise / brand owner shown by Vibe Bar
///   (OpenAI, Anthropic, Google AI, SpaceXAI).
/// - `product` (L2) — the SubProvider users consume inside that owner
///   (ChatGPT Agentic, Claude, Gemini Web, AntiGravity, Grok, Cursor).
/// - `tool` (L3) — the concrete local or web surface Vibe Bar tracks
///   (Codex, Claude Code, Gemini Web, AntiGravity, Grok, Cursor).
///
/// `ToolType` derives its `vendorName` / `productName` / `toolName`
/// from a single entry per case in `ProviderHierarchyCatalog`, so
/// every UI surface — tabs, card titles, mini-window headers,
/// service-status rows — pulls from the same source of truth.
public struct ProviderHierarchy: Sendable, Equatable, Hashable {
    public let vendor: String
    public let product: String
    public let tool: String

    public init(vendor: String, product: String, tool: String) {
        self.vendor = vendor
        self.product = product
        self.tool = tool
    }
}

/// Canonical lookup table for the dedicated/linked tools and every misc
/// provider Vibe Bar tracks. Each `ToolType` maps to exactly one
/// entry; the constants below double as the public spec — adding or
/// renaming a provider is a single edit here, not a hunt across
/// five `switch` statements.
public enum ProviderHierarchyCatalog {
    // MARK: - Dedicated and linked tool hierarchy
    //
    //   L1 vendor      : OpenAI         | Anthropic   | Google AI | Google AI   | SpaceXAI | SpaceXAI
    //   L2 SubProvider : ChatGPT Agentic| Claude      | Gemini Web| AntiGravity | Grok     | Cursor
    //   L3 tool        : Codex          | Claude Code | Gemini Web| AntiGravity | Grok     | Cursor

    public static let codex       = ProviderHierarchy(vendor: "OpenAI",    product: "ChatGPT Agentic", tool: "Codex")
    public static let claude      = ProviderHierarchy(vendor: "Anthropic", product: "Claude",          tool: "Claude Code")
    public static let gemini      = ProviderHierarchy(vendor: "Google AI", product: "Gemini Web",      tool: "Gemini Web")
    public static let antigravity = ProviderHierarchy(vendor: "Google AI", product: "AntiGravity",     tool: "AntiGravity")
    public static let grok        = ProviderHierarchy(vendor: "SpaceXAI",  product: "Grok",    tool: "Grok")
    public static let cursor      = ProviderHierarchy(vendor: "SpaceXAI",  product: "Cursor",  tool: "Cursor")

    // MARK: - Misc providers
    //
    // Misc tools don't slot cleanly into a vendor → product → tool
    // split because most of them are single-product vendors with
    // one tracked surface. Keep the same shape so callers don't have
    // to special-case the misc tab.

    public static let copilot          = ProviderHierarchy(vendor: "GitHub",     product: "Copilot",     tool: "GitHub Copilot")
    public static let alibaba          = ProviderHierarchy(vendor: "Alibaba",    product: "Bailian",     tool: "Coding Plan")
    public static let alibabaTokenPlan = ProviderHierarchy(vendor: "Alibaba",    product: "Bailian",     tool: "Token Plan")
    public static let zai              = ProviderHierarchy(vendor: "Zhipu",      product: "GLM",         tool: "GLM Coding Plan")
    public static let minimax          = ProviderHierarchy(vendor: "MiniMax",    product: "MiniMax",     tool: "MiniMax Token Plan")
    public static let kimi             = ProviderHierarchy(vendor: "Moonshot",   product: "Kimi",        tool: "Kimi Coding Plan")
    public static let mimo             = ProviderHierarchy(vendor: "Xiaomi",     product: "MiMo",        tool: "MiMo Token Plan")
    public static let iflytek          = ProviderHierarchy(vendor: "iFlytek",    product: "Spark",       tool: "Spark Coding Plan")
    public static let tencentHunyuan   = ProviderHierarchy(vendor: "Tencent",    product: "Hunyuan",     tool: "Hunyuan Coding Plan")
    public static let tencentTokenPlan = ProviderHierarchy(vendor: "Tencent",    product: "Hunyuan",     tool: "Hunyuan Token Plan")
    public static let volcengine       = ProviderHierarchy(vendor: "ByteDance",  product: "Doubao",      tool: "Doubao Coding Plan")
    public static let volcengineAgentPlan = ProviderHierarchy(vendor: "ByteDance",  product: "Doubao",   tool: "Doubao Agent Plan")
    public static let baiduQianfan     = ProviderHierarchy(vendor: "Baidu",      product: "Qianfan",     tool: "Qianfan Coding Plan")
    public static let openCodeGo       = ProviderHierarchy(vendor: "OpenCode",   product: "OpenCode Go", tool: "OpenCode Go")
    public static let kilo             = ProviderHierarchy(vendor: "Kilo",       product: "Kilo",        tool: "Kilo")
    public static let kiro             = ProviderHierarchy(vendor: "Kiro",       product: "Kiro",        tool: "Kiro")
    public static let ollama           = ProviderHierarchy(vendor: "Ollama",     product: "Ollama",      tool: "Ollama")
    public static let openRouter       = ProviderHierarchy(vendor: "OpenRouter", product: "OpenRouter",  tool: "OpenRouter")
    public static let warp             = ProviderHierarchy(vendor: "Warp",       product: "Warp",        tool: "Warp")
}
