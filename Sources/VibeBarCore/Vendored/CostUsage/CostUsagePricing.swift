import Foundation

// Vendored pricing data — pure data, no external dependencies.
// USD per token. Update `pricingDataUpdatedAt` whenever the rate tables change
// so users can see freshness in Settings.
public enum CostUsagePricing {
    /// ISO date the pricing tables were last refreshed against upstream provider docs.
    public static let pricingDataUpdatedAt: String = "2026-05-22"

    /// Bump when local cost parsing or pricing semantics change in a way that
    /// makes persisted cost totals unsafe to max-merge with fresh scans.
    /// v5: add Grok + AntiGravity adapters with their own pricing tables;
    /// existing Codex / Claude / Gemini totals stay byte-identical.
    public static let calculationVersion: Int = 5

    struct CodexPricing {
        let inputCostPerToken: Double
        let outputCostPerToken: Double
        let cacheReadInputCostPerToken: Double?
        let displayLabel: String?
    }

    struct GeminiPricing {
        let inputCostPerToken: Double
        let outputCostPerToken: Double
        let cacheReadInputCostPerToken: Double?
        /// Tiered: when total input tokens exceed `thresholdTokens`, rates
        /// flip to the `*AboveThreshold` values. Gemini 2.5 Pro & Pro
        /// Preview have a 200K threshold; smaller / earlier models are flat.
        let thresholdTokens: Int?
        let inputCostPerTokenAboveThreshold: Double?
        let outputCostPerTokenAboveThreshold: Double?
        let cacheReadInputCostPerTokenAboveThreshold: Double?
        let displayLabel: String?
    }

    struct GrokPricing {
        let inputCostPerToken: Double
        let outputCostPerToken: Double
        let cacheReadInputCostPerToken: Double?
        let displayLabel: String?
    }

    struct AntigravityPricing {
        let inputCostPerToken: Double
        let outputCostPerToken: Double
        /// AntiGravity bills by plan quota, not per-token. These rates
        /// shadow the corresponding upstream model (Sonnet, Opus,
        /// Gemini Pro, etc.) so the dollar number is interpretable as
        /// "the API-equivalent of this session would have cost ~$X".
        let cacheReadInputCostPerToken: Double
        let cacheCreationInputCostPerToken: Double
        let displayLabel: String?
    }

    struct ClaudePricing {
        let inputCostPerToken: Double
        let outputCostPerToken: Double
        let cacheCreationInputCostPerToken: Double
        let cacheReadInputCostPerToken: Double

        let thresholdTokens: Int?
        let inputCostPerTokenAboveThreshold: Double?
        let outputCostPerTokenAboveThreshold: Double?
        let cacheCreationInputCostPerTokenAboveThreshold: Double?
        let cacheReadInputCostPerTokenAboveThreshold: Double?
    }

    private static let codex: [String: CodexPricing] = [
        "gpt-5": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: nil),
        "gpt-5-codex": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: nil),
        "gpt-5-mini": CodexPricing(
            inputCostPerToken: 2.5e-7,
            outputCostPerToken: 2e-6,
            cacheReadInputCostPerToken: 2.5e-8,
            displayLabel: nil),
        "gpt-5-nano": CodexPricing(
            inputCostPerToken: 5e-8,
            outputCostPerToken: 4e-7,
            cacheReadInputCostPerToken: 5e-9,
            displayLabel: nil),
        "gpt-5-pro": CodexPricing(
            inputCostPerToken: 1.5e-5,
            outputCostPerToken: 1.2e-4,
            cacheReadInputCostPerToken: nil,
            displayLabel: nil),
        "gpt-5.1": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: nil),
        "gpt-5.1-codex": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: nil),
        "gpt-5.1-codex-max": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: nil),
        "gpt-5.1-codex-mini": CodexPricing(
            inputCostPerToken: 2.5e-7,
            outputCostPerToken: 2e-6,
            cacheReadInputCostPerToken: 2.5e-8,
            displayLabel: nil),
        "gpt-5.2": CodexPricing(
            inputCostPerToken: 1.75e-6,
            outputCostPerToken: 1.4e-5,
            cacheReadInputCostPerToken: 1.75e-7,
            displayLabel: nil),
        "gpt-5.2-codex": CodexPricing(
            inputCostPerToken: 1.75e-6,
            outputCostPerToken: 1.4e-5,
            cacheReadInputCostPerToken: 1.75e-7,
            displayLabel: nil),
        "gpt-5.2-pro": CodexPricing(
            inputCostPerToken: 2.1e-5,
            outputCostPerToken: 1.68e-4,
            cacheReadInputCostPerToken: nil,
            displayLabel: nil),
        "gpt-5.3-codex": CodexPricing(
            inputCostPerToken: 1.75e-6,
            outputCostPerToken: 1.4e-5,
            cacheReadInputCostPerToken: 1.75e-7,
            displayLabel: nil),
        "gpt-5.3-codex-spark": CodexPricing(
            inputCostPerToken: 0,
            outputCostPerToken: 0,
            cacheReadInputCostPerToken: 0,
            displayLabel: "Research Preview"),
        "gpt-5.4": CodexPricing(
            inputCostPerToken: 2.5e-6,
            outputCostPerToken: 1.5e-5,
            cacheReadInputCostPerToken: 2.5e-7,
            displayLabel: nil),
        "gpt-5.4-mini": CodexPricing(
            inputCostPerToken: 7.5e-7,
            outputCostPerToken: 4.5e-6,
            cacheReadInputCostPerToken: 7.5e-8,
            displayLabel: nil),
        "gpt-5.4-nano": CodexPricing(
            inputCostPerToken: 2e-7,
            outputCostPerToken: 1.25e-6,
            cacheReadInputCostPerToken: 2e-8,
            displayLabel: nil),
        "gpt-5.4-pro": CodexPricing(
            inputCostPerToken: 3e-5,
            outputCostPerToken: 1.8e-4,
            cacheReadInputCostPerToken: nil,
            displayLabel: nil),
        "gpt-5.5": CodexPricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 3e-5,
            cacheReadInputCostPerToken: 5e-7,
            displayLabel: nil),
        "gpt-5.5-pro": CodexPricing(
            inputCostPerToken: 3e-5,
            outputCostPerToken: 1.8e-4,
            cacheReadInputCostPerToken: nil,
            displayLabel: nil),
    ]

    private static let claude: [String: ClaudePricing] = [
        "claude-haiku-4-5-20251001": ClaudePricing(
            inputCostPerToken: 1e-6,
            outputCostPerToken: 5e-6,
            cacheCreationInputCostPerToken: 1.25e-6,
            cacheReadInputCostPerToken: 1e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-haiku-4-5": ClaudePricing(
            inputCostPerToken: 1e-6,
            outputCostPerToken: 5e-6,
            cacheCreationInputCostPerToken: 1.25e-6,
            cacheReadInputCostPerToken: 1e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-5-20251101": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-5": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-6-20260205": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-6": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-7": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-sonnet-4-5": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 6e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 7.5e-6,
            cacheReadInputCostPerTokenAboveThreshold: 6e-7),
        "claude-sonnet-4-6": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-sonnet-4-5-20250929": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 6e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 7.5e-6,
            cacheReadInputCostPerTokenAboveThreshold: 6e-7),
        "claude-opus-4-20250514": ClaudePricing(
            inputCostPerToken: 1.5e-5,
            outputCostPerToken: 7.5e-5,
            cacheCreationInputCostPerToken: 1.875e-5,
            cacheReadInputCostPerToken: 1.5e-6,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-1": ClaudePricing(
            inputCostPerToken: 1.5e-5,
            outputCostPerToken: 7.5e-5,
            cacheCreationInputCostPerToken: 1.875e-5,
            cacheReadInputCostPerToken: 1.5e-6,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-sonnet-4-20250514": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 6e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 7.5e-6,
            cacheReadInputCostPerTokenAboveThreshold: 6e-7),
    ]

    /// Gemini API pricing, USD per token, as of `pricingDataUpdatedAt`.
    /// Source: ai.google.dev/gemini-api/docs/pricing. Free-tier rows
    /// have zero cost so the cost chart stays at $0 for AI-Studio-only
    /// users. Paid tier rates are tiered for Pro models (≤200K and
    /// >200K input-token prompts use different rates).
    private static let gemini: [String: GeminiPricing] = [
        // === Gemini 2.5 family ===
        "gemini-2.5-pro": GeminiPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 3.1e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 2.5e-6,
            outputCostPerTokenAboveThreshold: 1.5e-5,
            cacheReadInputCostPerTokenAboveThreshold: 6.25e-7,
            displayLabel: nil),
        "gemini-2.5-flash": GeminiPricing(
            inputCostPerToken: 3e-7,
            outputCostPerToken: 2.5e-6,
            cacheReadInputCostPerToken: 7.5e-8,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil,
            displayLabel: nil),
        "gemini-2.5-flash-lite": GeminiPricing(
            inputCostPerToken: 1e-7,
            outputCostPerToken: 4e-7,
            cacheReadInputCostPerToken: 2.5e-8,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil,
            displayLabel: nil),
        // === Gemini 3 family (post-I/O 2026) ===
        "gemini-3-pro": GeminiPricing(
            inputCostPerToken: 2e-6,
            outputCostPerToken: 1.2e-5,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 4e-6,
            outputCostPerTokenAboveThreshold: 1.8e-5,
            cacheReadInputCostPerTokenAboveThreshold: 1e-6,
            displayLabel: nil),
        "gemini-3-pro-preview": GeminiPricing(
            inputCostPerToken: 2e-6,
            outputCostPerToken: 1.2e-5,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 4e-6,
            outputCostPerTokenAboveThreshold: 1.8e-5,
            cacheReadInputCostPerTokenAboveThreshold: 1e-6,
            displayLabel: nil),
        "gemini-3-flash": GeminiPricing(
            inputCostPerToken: 3.5e-7,
            outputCostPerToken: 2.8e-6,
            cacheReadInputCostPerToken: 8.75e-8,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil,
            displayLabel: nil),
        "gemini-3-flash-lite": GeminiPricing(
            inputCostPerToken: 1.25e-7,
            outputCostPerToken: 5e-7,
            cacheReadInputCostPerToken: 3.1e-8,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil,
            displayLabel: nil)
    ]

    /// xAI Grok API pricing, USD per token, as of `pricingDataUpdatedAt`.
    /// Source: docs.x.ai/docs/models and pricepertoken.com cross-checks.
    /// Cached-input rates that aren't published explicitly stay `nil`
    /// and fall back to the regular input rate in `grokCostUSD`.
    private static let grok: [String: GrokPricing] = [
        "grok-build": GrokPricing(
            inputCostPerToken: 1e-6,
            outputCostPerToken: 2e-6,
            cacheReadInputCostPerToken: nil,
            displayLabel: nil),
        "grok-build-0.1": GrokPricing(
            inputCostPerToken: 1e-6,
            outputCostPerToken: 2e-6,
            cacheReadInputCostPerToken: nil,
            displayLabel: nil),
        "grok-4": GrokPricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheReadInputCostPerToken: 7.5e-7,
            displayLabel: nil),
        "grok-4-fast": GrokPricing(
            inputCostPerToken: 2e-7,
            outputCostPerToken: 5e-7,
            cacheReadInputCostPerToken: 5e-8,
            displayLabel: nil),
        "grok-4.1-fast": GrokPricing(
            inputCostPerToken: 2e-7,
            outputCostPerToken: 5e-7,
            cacheReadInputCostPerToken: 5e-8,
            displayLabel: nil),
        "grok-4.3": GrokPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 2.5e-6,
            cacheReadInputCostPerToken: 3.1e-7,
            displayLabel: nil),
        "grok-4.20": GrokPricing(
            inputCostPerToken: 2e-6,
            outputCostPerToken: 6e-6,
            cacheReadInputCostPerToken: 2e-7,
            displayLabel: nil),
        "grok-3": GrokPricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheReadInputCostPerToken: 7.5e-7,
            displayLabel: nil),
        "grok-3-mini": GrokPricing(
            inputCostPerToken: 3e-7,
            outputCostPerToken: 5e-7,
            cacheReadInputCostPerToken: 7.5e-8,
            displayLabel: nil),
        "grok-code-fast-1": GrokPricing(
            inputCostPerToken: 2e-7,
            outputCostPerToken: 1.5e-6,
            cacheReadInputCostPerToken: 2e-8,
            displayLabel: nil)
    ]

    /// AntiGravity is a managed product, not a pay-per-token API.
    /// These rates shadow Claude Sonnet 4.6 (the default) / Opus /
    /// Haiku / Gemini Pro / Gemini Flash so the dollar number is
    /// interpretable as "if this session had hit the API directly,
    /// it would have cost approximately $X". The `-default` key is
    /// the fallback when the scanner can't pin the underlying model.
    private static let antigravity: [String: AntigravityPricing] = [
        "antigravity-default": AntigravityPricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheReadInputCostPerToken: 3e-7,
            cacheCreationInputCostPerToken: 3.75e-6,
            displayLabel: "Sonnet-rate est."),
        "antigravity-claude-sonnet": AntigravityPricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheReadInputCostPerToken: 3e-7,
            cacheCreationInputCostPerToken: 3.75e-6,
            displayLabel: nil),
        "antigravity-claude-opus": AntigravityPricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheReadInputCostPerToken: 5e-7,
            cacheCreationInputCostPerToken: 6.25e-6,
            displayLabel: nil),
        "antigravity-claude-haiku": AntigravityPricing(
            inputCostPerToken: 1e-6,
            outputCostPerToken: 5e-6,
            cacheReadInputCostPerToken: 1e-7,
            cacheCreationInputCostPerToken: 1.25e-6,
            displayLabel: nil),
        "antigravity-gemini-pro": AntigravityPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 3.1e-7,
            cacheCreationInputCostPerToken: 0,
            displayLabel: nil),
        "antigravity-gemini-flash": AntigravityPricing(
            inputCostPerToken: 3e-7,
            outputCostPerToken: 2.5e-6,
            cacheReadInputCostPerToken: 7.5e-8,
            cacheCreationInputCostPerToken: 0,
            displayLabel: nil)
    ]

    static func normalizeGrokModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("xai/") {
            trimmed = String(trimmed.dropFirst("xai/".count))
        }
        if self.grok[trimmed] != nil { return trimmed }
        if let datedRange = trimmed.range(of: #"-(beta|preview|\d{4}-\d{2}-\d{2}|\d{4}-\d{2})$"#, options: .regularExpression) {
            let base = String(trimmed[..<datedRange.lowerBound])
            if self.grok[base] != nil { return base }
        }
        let segments = trimmed.split(separator: "-")
        for end in stride(from: segments.count, through: 1, by: -1) {
            let candidate = segments.prefix(end).joined(separator: "-")
            if self.grok[candidate] != nil { return candidate }
        }
        return trimmed
    }

    static func grokDisplayLabel(model: String) -> String? {
        self.grok[self.normalizeGrokModel(model)]?.displayLabel
    }

    static func normalizeAntigravityModel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if self.antigravity[trimmed] != nil { return trimmed }
        if trimmed.contains("opus") { return "antigravity-claude-opus" }
        if trimmed.contains("haiku") { return "antigravity-claude-haiku" }
        if trimmed.contains("sonnet") || trimmed.contains("claude") {
            return "antigravity-claude-sonnet"
        }
        if trimmed.contains("flash-lite") || trimmed.contains("flash") {
            return "antigravity-gemini-flash"
        }
        if trimmed.contains("pro") || trimmed.contains("gemini") {
            return "antigravity-gemini-pro"
        }
        return "antigravity-default"
    }

    static func antigravityDisplayLabel(model: String) -> String? {
        self.antigravity[self.normalizeAntigravityModel(model)]?.displayLabel
    }

    static func normalizeGeminiModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Drop the common `models/` prefix used by the Gemini API.
        if trimmed.hasPrefix("models/") {
            trimmed = String(trimmed.dropFirst("models/".count))
        }

        if self.gemini[trimmed] != nil {
            return trimmed
        }

        // Strip `-001`, `-002`, `-preview-04-09` style suffixes — they
        // share pricing with the bare base name.
        if let datedSuffix = trimmed.range(of: #"-(preview-)?\d{2,4}-\d{2}(-\d{2})?$"#, options: .regularExpression) {
            let base = String(trimmed[..<datedSuffix.lowerBound])
            if self.gemini[base] != nil {
                return base
            }
        }
        if let revSuffix = trimmed.range(of: #"-\d{3}$"#, options: .regularExpression) {
            let base = String(trimmed[..<revSuffix.lowerBound])
            if self.gemini[base] != nil {
                return base
            }
        }
        // Best-effort family fallback: "gemini-2.5-pro-exp" → "gemini-2.5-pro".
        let segments = trimmed.split(separator: "-")
        for end in stride(from: segments.count, through: 3, by: -1) {
            let candidate = segments.prefix(end).joined(separator: "-")
            if self.gemini[candidate] != nil {
                return candidate
            }
        }
        return trimmed
    }

    static func geminiDisplayLabel(model: String) -> String? {
        let key = self.normalizeGeminiModel(model)
        return self.gemini[key]?.displayLabel
    }

    static func normalizeCodexModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("openai/") {
            trimmed = String(trimmed.dropFirst("openai/".count))
        }

        if self.codex[trimmed] != nil {
            return trimmed
        }

        if let datedSuffix = trimmed.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            let base = String(trimmed[..<datedSuffix.lowerBound])
            if self.codex[base] != nil {
                return base
            }
        }
        return trimmed
    }

    static func codexDisplayLabel(model: String) -> String? {
        let key = self.normalizeCodexModel(model)
        return self.codex[key]?.displayLabel
    }

    static func normalizeClaudeModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("anthropic.") {
            trimmed = String(trimmed.dropFirst("anthropic.".count))
        }

        if let lastDot = trimmed.lastIndex(of: "."),
           trimmed.contains("claude-")
        {
            let tail = String(trimmed[trimmed.index(after: lastDot)...])
            if tail.hasPrefix("claude-") {
                trimmed = tail
            }
        }

        if let vRange = trimmed.range(of: #"-v\d+:\d+$"#, options: .regularExpression) {
            trimmed.removeSubrange(vRange)
        }

        if let baseRange = trimmed.range(of: #"-\d{8}$"#, options: .regularExpression) {
            let base = String(trimmed[..<baseRange.lowerBound])
            if self.claude[base] != nil {
                return base
            }
        }

        return trimmed
    }

    static func codexCostUSD(model: String, inputTokens: Int, cachedInputTokens: Int, outputTokens: Int) -> Double? {
        let key = self.normalizeCodexModel(model)
        guard let pricing = self.codex[key] else { return nil }
        let cached = min(max(0, cachedInputTokens), max(0, inputTokens))
        let nonCached = max(0, inputTokens - cached)
        let cachedRate = pricing.cacheReadInputCostPerToken ?? pricing.inputCostPerToken
        return Double(nonCached) * pricing.inputCostPerToken
            + Double(cached) * cachedRate
            + Double(max(0, outputTokens)) * pricing.outputCostPerToken
    }

    /// Compute USD cost for a Gemini API call. `cacheReadInputTokens`
    /// is the slice of `inputTokens` that hit context cache — same
    /// shape as `codexCostUSD`. Returns `nil` when the model is
    /// unknown so the scanner can skip the row instead of charging
    /// $0 (which would silently under-count cost on a new model).
    static func geminiCostUSD(
        model: String,
        inputTokens: Int,
        cacheReadInputTokens: Int,
        outputTokens: Int
    ) -> Double? {
        let key = self.normalizeGeminiModel(model)
        guard let pricing = self.gemini[key] else { return nil }

        let cached = min(max(0, cacheReadInputTokens), max(0, inputTokens))
        let nonCached = max(0, inputTokens - cached)
        let output = max(0, outputTokens)

        func tier(_ tokens: Int, base: Double, above: Double?, threshold: Int?) -> Double {
            guard let threshold, let above else { return Double(tokens) * base }
            let below = min(tokens, threshold)
            let over = max(tokens - threshold, 0)
            return Double(below) * base + Double(over) * above
        }

        let cachedRate = pricing.cacheReadInputCostPerToken ?? pricing.inputCostPerToken
        let cachedRateAbove = pricing.cacheReadInputCostPerTokenAboveThreshold ?? pricing.inputCostPerTokenAboveThreshold
        return tier(nonCached,
                    base: pricing.inputCostPerToken,
                    above: pricing.inputCostPerTokenAboveThreshold,
                    threshold: pricing.thresholdTokens)
            + tier(cached,
                   base: cachedRate,
                   above: cachedRateAbove,
                   threshold: pricing.thresholdTokens)
            + tier(output,
                   base: pricing.outputCostPerToken,
                   above: pricing.outputCostPerTokenAboveThreshold,
                   threshold: pricing.thresholdTokens)
    }

    /// Compute USD cost for a Grok call. xAI publishes per-model input
    /// and output rates; cached-input is sometimes ~10% of input on
    /// newer models. The caller passes pre-split tokens — when the
    /// upstream source only has a session-level total, the Grok
    /// scanner splits it ~70 / 30 input vs output before calling us.
    /// Returns `nil` for unknown models.
    static func grokCostUSD(
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int
    ) -> Double? {
        let key = self.normalizeGrokModel(model)
        guard let pricing = self.grok[key] else { return nil }
        let cached = min(max(0, cachedInputTokens), max(0, inputTokens))
        let nonCached = max(0, inputTokens - cached)
        let cachedRate = pricing.cacheReadInputCostPerToken ?? pricing.inputCostPerToken
        return Double(nonCached) * pricing.inputCostPerToken
            + Double(cached) * cachedRate
            + Double(max(0, outputTokens)) * pricing.outputCostPerToken
    }

    /// Compute USD cost for an AntiGravity-mediated call. AntiGravity
    /// bills by plan quota, so this number is an "if this same volume
    /// hit the underlying API directly" estimate, not a real invoice
    /// figure. Default key (`antigravity-default`) shadows Claude
    /// Sonnet 4.6 rates.
    static func antigravityCostUSD(
        model: String,
        inputTokens: Int,
        cacheReadInputTokens: Int,
        cacheCreationInputTokens: Int,
        outputTokens: Int
    ) -> Double? {
        let key = self.normalizeAntigravityModel(model)
        guard let pricing = self.antigravity[key] else { return nil }
        return Double(max(0, inputTokens)) * pricing.inputCostPerToken
            + Double(max(0, cacheReadInputTokens)) * pricing.cacheReadInputCostPerToken
            + Double(max(0, cacheCreationInputTokens)) * pricing.cacheCreationInputCostPerToken
            + Double(max(0, outputTokens)) * pricing.outputCostPerToken
    }

    static func claudeCostUSD(
        model: String,
        inputTokens: Int,
        cacheReadInputTokens: Int,
        cacheCreationInputTokens: Int,
        outputTokens: Int) -> Double?
    {
        let key = self.normalizeClaudeModel(model)
        guard let pricing = self.claude[key] else { return nil }

        func tiered(_ tokens: Int, base: Double, above: Double?, threshold: Int?) -> Double {
            guard let threshold, let above else { return Double(tokens) * base }
            let below = min(tokens, threshold)
            let over = max(tokens - threshold, 0)
            return Double(below) * base + Double(over) * above
        }

        return tiered(
            max(0, inputTokens),
            base: pricing.inputCostPerToken,
            above: pricing.inputCostPerTokenAboveThreshold,
            threshold: pricing.thresholdTokens)
            + tiered(
                max(0, cacheReadInputTokens),
                base: pricing.cacheReadInputCostPerToken,
                above: pricing.cacheReadInputCostPerTokenAboveThreshold,
                threshold: pricing.thresholdTokens)
            + tiered(
                max(0, cacheCreationInputTokens),
                base: pricing.cacheCreationInputCostPerToken,
                above: pricing.cacheCreationInputCostPerTokenAboveThreshold,
                threshold: pricing.thresholdTokens)
            + tiered(
                max(0, outputTokens),
                base: pricing.outputCostPerToken,
                above: pricing.outputCostPerTokenAboveThreshold,
                threshold: pricing.thresholdTokens)
    }
}
