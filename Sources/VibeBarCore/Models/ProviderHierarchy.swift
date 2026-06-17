import Foundation

/// Three-level vendor / product / tool hierarchy used everywhere the
/// UI needs to identify a provider at a single, consistent level.
///
/// - `vendor` (L1) — who issues the plan / bills the account
///   (OpenAI, Anthropic, Google, xAI).
/// - `product` (L2) — what users call the AI brand
///   (ChatGPT, Claude, Gemini, Grok). Both Gemini Web and the
///   AntiGravity IDE share the Gemini product because that's how
///   Google brands them.
/// - `tool` (L3) — the specific surface Vibe Bar tracks
///   (Codex, Claude Code, Gemini Web, AntiGravity, Grok Build).
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

/// Canonical lookup table for the five primary tools and every misc
/// provider Vibe Bar tracks. Each `ToolType` maps to exactly one
/// entry; the constants below double as the public spec — adding or
/// renaming a provider is a single edit here, not a hunt across
/// five `switch` statements.
public enum ProviderHierarchyCatalog {
    // MARK: - Primary five-tool hierarchy
    //
    //   L1 vendor   : OpenAI    | Anthropic   | Google    | Google      | xAI
    //   L2 product  : ChatGPT   | Claude      | Gemini    | Gemini      | Grok
    //   L3 tool     : Codex     | Claude Code | Gemini Web| AntiGravity | Grok Build

    public static let codex       = ProviderHierarchy(vendor: "OpenAI",    product: "ChatGPT", tool: "Codex")
    public static let claude      = ProviderHierarchy(vendor: "Anthropic", product: "Claude",  tool: "Claude Code")
    public static let gemini      = ProviderHierarchy(vendor: "Google",    product: "Gemini",  tool: "Gemini Web")
    public static let antigravity = ProviderHierarchy(vendor: "Google",    product: "Gemini",  tool: "AntiGravity")
    public static let grok        = ProviderHierarchy(vendor: "xAI",       product: "Grok",    tool: "Grok Build")

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
    public static let cursor           = ProviderHierarchy(vendor: "Cursor",     product: "Cursor",      tool: "Cursor")
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
