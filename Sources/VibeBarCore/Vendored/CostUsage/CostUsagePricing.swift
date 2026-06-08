import Foundation

/// Thin facade over `PricingResolver.active`. The price tables
/// themselves live in `Resources/pricing.json` (bundled), an
/// optional cache at `~/.vibebar/pricing_cache.json` (refreshed by
/// `PricingRefresher`), and `PricingHardcoded.fallback` (used when
/// neither file is loadable — e.g. tests, or a corrupt cache).
///
/// Function signatures and return semantics are preserved verbatim
/// from the earlier hardcoded-dict implementation so every caller
/// (CostUsageScanner, the cost UI surfaces, tests) keeps working
/// without modification.
public enum CostUsagePricing {
    /// ISO date the pricing tables were last refreshed against
    /// upstream provider docs. Reflects the *currently loaded* data
    /// set (cache → bundle → hardcoded), so a stale cache is visible
    /// in Settings as a stale date.
    public static var pricingDataUpdatedAt: String {
        PricingResolver.active.updatedAt
    }

    /// Bump in `Resources/pricing.json` (and `PricingHardcoded`) when
    /// cost parsing or pricing semantics change in a way that makes
    /// persisted cost totals unsafe to max-merge with fresh scans.
    public static var calculationVersion: Int {
        PricingResolver.active.calculationVersion
    }

    /// Resolves the cost multiplier for a request: `1.0` unless it ran
    /// on the fast/priority tier, in which case the model's
    /// `fastMultiplier` applies (defaulting to `1.0` when the model has
    /// no published premium). Mirrors ccusage's `fast_multiplier`
    /// semantics so cost totals line up on fast-tier usage.
    static func fastFactor(_ isFast: Bool, _ fastMultiplier: Double?) -> Double {
        guard isFast else { return 1.0 }
        let multiplier = fastMultiplier ?? 1.0
        return multiplier > 0 ? multiplier : 1.0
    }

    // MARK: - Codex

    static func normalizeCodexModel(_ raw: String) -> String {
        let codex = PricingResolver.active.providers.codex.models
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("openai/") {
            trimmed = String(trimmed.dropFirst("openai/".count))
        }
        if codex[trimmed] != nil { return trimmed }
        if let datedSuffix = trimmed.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            let base = String(trimmed[..<datedSuffix.lowerBound])
            if codex[base] != nil { return base }
        }
        return trimmed
    }

    static func codexDisplayLabel(model: String) -> String? {
        let codex = PricingResolver.active.providers.codex.models
        return codex[normalizeCodexModel(model)]?.displayLabel
    }

    static func codexCostUSD(
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        isFast: Bool = false
    ) -> Double? {
        let codex = PricingResolver.active.providers.codex.models
        guard let pricing = codex[normalizeCodexModel(model)] else { return nil }
        let cached = min(max(0, cachedInputTokens), max(0, inputTokens))
        let nonCached = max(0, inputTokens - cached)
        let cachedRate = pricing.cacheRead ?? pricing.input
        let base = Double(nonCached) * pricing.input
            + Double(cached) * cachedRate
            + Double(max(0, outputTokens)) * pricing.output
        return base * fastFactor(isFast, pricing.fastMultiplier)
    }

    // MARK: - Claude

    static func normalizeClaudeModel(_ raw: String) -> String {
        let claude = PricingResolver.active.providers.claude.models
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
            if claude[base] != nil { return base }
        }
        return trimmed
    }

    static func claudeCostUSD(
        model: String,
        inputTokens: Int,
        cacheReadInputTokens: Int,
        cacheCreationInputTokens: Int,
        outputTokens: Int,
        isFast: Bool = false
    ) -> Double? {
        let claude = PricingResolver.active.providers.claude.models
        guard let pricing = claude[normalizeClaudeModel(model)] else { return nil }

        func tiered(_ tokens: Int, base: Double, above: Double?, threshold: Int?) -> Double {
            guard let threshold, let above else { return Double(tokens) * base }
            let below = min(tokens, threshold)
            let over = max(tokens - threshold, 0)
            return Double(below) * base + Double(over) * above
        }

        let base = tiered(
            max(0, inputTokens),
            base: pricing.input,
            above: pricing.inputAboveThreshold,
            threshold: pricing.thresholdTokens)
            + tiered(
                max(0, cacheReadInputTokens),
                base: pricing.cacheRead,
                above: pricing.cacheReadAboveThreshold,
                threshold: pricing.thresholdTokens)
            + tiered(
                max(0, cacheCreationInputTokens),
                base: pricing.cacheCreation,
                above: pricing.cacheCreationAboveThreshold,
                threshold: pricing.thresholdTokens)
            + tiered(
                max(0, outputTokens),
                base: pricing.output,
                above: pricing.outputAboveThreshold,
                threshold: pricing.thresholdTokens)
        return base * fastFactor(isFast, pricing.fastMultiplier)
    }

    // MARK: - Gemini

    static func normalizeGeminiModel(_ raw: String) -> String {
        let gemini = PricingResolver.active.providers.gemini.models
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("models/") {
            trimmed = String(trimmed.dropFirst("models/".count))
        }
        if gemini[trimmed] != nil { return trimmed }
        if let datedSuffix = trimmed.range(of: #"-(preview-)?\d{2,4}-\d{2}(-\d{2})?$"#, options: .regularExpression) {
            let base = String(trimmed[..<datedSuffix.lowerBound])
            if gemini[base] != nil { return base }
        }
        if let revSuffix = trimmed.range(of: #"-\d{3}$"#, options: .regularExpression) {
            let base = String(trimmed[..<revSuffix.lowerBound])
            if gemini[base] != nil { return base }
        }
        let segments = trimmed.split(separator: "-")
        for end in stride(from: segments.count, through: 3, by: -1) {
            let candidate = segments.prefix(end).joined(separator: "-")
            if gemini[candidate] != nil { return candidate }
        }
        return trimmed
    }

    static func geminiDisplayLabel(model: String) -> String? {
        let gemini = PricingResolver.active.providers.gemini.models
        return gemini[normalizeGeminiModel(model)]?.displayLabel
    }

    static func geminiCostUSD(
        model: String,
        inputTokens: Int,
        cacheReadInputTokens: Int,
        outputTokens: Int
    ) -> Double? {
        let gemini = PricingResolver.active.providers.gemini.models
        guard let pricing = gemini[normalizeGeminiModel(model)] else { return nil }

        let cached = min(max(0, cacheReadInputTokens), max(0, inputTokens))
        let nonCached = max(0, inputTokens - cached)
        let output = max(0, outputTokens)

        func tier(_ tokens: Int, base: Double, above: Double?, threshold: Int?) -> Double {
            guard let threshold, let above else { return Double(tokens) * base }
            let below = min(tokens, threshold)
            let over = max(tokens - threshold, 0)
            return Double(below) * base + Double(over) * above
        }

        let cachedRate = pricing.cacheRead ?? pricing.input
        let cachedRateAbove = pricing.cacheReadAboveThreshold ?? pricing.inputAboveThreshold
        return tier(nonCached,
                    base: pricing.input,
                    above: pricing.inputAboveThreshold,
                    threshold: pricing.thresholdTokens)
            + tier(cached,
                   base: cachedRate,
                   above: cachedRateAbove,
                   threshold: pricing.thresholdTokens)
            + tier(output,
                   base: pricing.output,
                   above: pricing.outputAboveThreshold,
                   threshold: pricing.thresholdTokens)
    }

    // MARK: - Grok

    static func normalizeGrokModel(_ raw: String) -> String {
        let grok = PricingResolver.active.providers.grok.models
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("xai/") {
            trimmed = String(trimmed.dropFirst("xai/".count))
        }
        if grok[trimmed] != nil { return trimmed }
        if let datedRange = trimmed.range(of: #"-(beta|preview|\d{4}-\d{2}-\d{2}|\d{4}-\d{2})$"#, options: .regularExpression) {
            let base = String(trimmed[..<datedRange.lowerBound])
            if grok[base] != nil { return base }
        }
        let segments = trimmed.split(separator: "-")
        for end in stride(from: segments.count, through: 1, by: -1) {
            let candidate = segments.prefix(end).joined(separator: "-")
            if grok[candidate] != nil { return candidate }
        }
        return trimmed
    }

    static func grokDisplayLabel(model: String) -> String? {
        let grok = PricingResolver.active.providers.grok.models
        return grok[normalizeGrokModel(model)]?.displayLabel
    }

    static func grokCostUSD(
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int
    ) -> Double? {
        let grok = PricingResolver.active.providers.grok.models
        guard let pricing = grok[normalizeGrokModel(model)] else { return nil }
        let cached = min(max(0, cachedInputTokens), max(0, inputTokens))
        let nonCached = max(0, inputTokens - cached)
        let cachedRate = pricing.cacheRead ?? pricing.input
        return Double(nonCached) * pricing.input
            + Double(cached) * cachedRate
            + Double(max(0, outputTokens)) * pricing.output
    }

    // MARK: - AntiGravity

    static func normalizeAntigravityModel(_ raw: String) -> String {
        let antigravity = PricingResolver.active.providers.antigravity.models
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if antigravity[trimmed] != nil { return trimmed }
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
        let antigravity = PricingResolver.active.providers.antigravity.models
        return antigravity[normalizeAntigravityModel(model)]?.displayLabel
    }

    static func antigravityCostUSD(
        model: String,
        inputTokens: Int,
        cacheReadInputTokens: Int,
        cacheCreationInputTokens: Int,
        outputTokens: Int
    ) -> Double? {
        let antigravity = PricingResolver.active.providers.antigravity.models
        guard let pricing = antigravity[normalizeAntigravityModel(model)] else { return nil }
        return Double(max(0, inputTokens)) * pricing.input
            + Double(max(0, cacheReadInputTokens)) * pricing.cacheRead
            + Double(max(0, cacheCreationInputTokens)) * pricing.cacheCreation
            + Double(max(0, outputTokens)) * pricing.output
    }
}
