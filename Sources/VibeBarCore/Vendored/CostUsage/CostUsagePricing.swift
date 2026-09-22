import Foundation

/// Thin facade over `PricingResolver.active`. The price tables
/// themselves live in `Resources/pricing.json` (bundled), an
/// optional cache at `~/.vibebar/pricing_cache.json` (refreshed by
/// `MultiSourcePricingRefresher`), and `PricingHardcoded.fallback` (used when
/// neither file is loadable — e.g. tests, or a corrupt cache).
///
/// Function signatures and return semantics are preserved verbatim
/// from the earlier hardcoded-dict implementation so every caller
/// (CostUsageScanner, the cost UI surfaces, tests) keeps working
/// without modification.
///
/// Two shapes exist for every provider:
///
/// - the original `…CostUSD(model:…)` entry points, which resolve the
///   active table themselves — used by the UI and by tests;
/// - a `models:` / `pricing:` pair that takes the already-resolved table
///   (or the already-resolved entry) — used by the cost scanner, which
///   resolves the table once per pass and memoises model normalisation
///   through `CostPricingContext`. Reading `PricingResolver.active` per
///   event took a lock and retained five dictionaries, twice, for each of
///   millions of events.
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

    /// Whether summed daily token columns contain enough information to
    /// reproduce request-level pricing exactly. Threshold and premium-tier
    /// models require request boundaries that legacy rollups no longer keep.
    static func canRepriceAggregate(tool: ToolType, model: String) -> Bool {
        let dataSet = PricingResolver.active
        switch tool {
        case .codex:
            let models = dataSet.providers.codex.models
            guard let pricing = models[normalizeCodexModel(model, models: models)] else {
                return false
            }
            return pricing.thresholdTokens == nil
                && (pricing.fastMultiplier ?? 1.0) == 1.0
        case .claude:
            let models = dataSet.providers.claude.models
            guard let pricing = models[normalizeClaudeModel(model, models: models)] else {
                return false
            }
            return pricing.thresholdTokens == nil
                && (pricing.fastMultiplier ?? 1.0) == 1.0
        case .gemini:
            let models = dataSet.providers.gemini.models
            guard let pricing = models[normalizeGeminiModel(model, models: models)] else {
                return false
            }
            return pricing.thresholdTokens == nil
        case .grok:
            let models = dataSet.providers.grok.models
            guard let pricing = models[normalizeGrokModel(model, models: models)] else {
                return false
            }
            return pricing.thresholdTokens == nil
        case .antigravity:
            let models = dataSet.providers.antigravity.models
            return models[normalizeAntigravityModel(model, models: models)] != nil
        case .muse:
            let models = dataSet.providers.muse.models
            guard let pricing = models[normalizeMuseModel(model, models: models)] else {
                return false
            }
            return pricing.thresholdTokens == nil
        case .mistralVibe:
            let models = dataSet.providers.mistral.models
            guard let pricing = models[normalizeMistralModel(model, models: models)] else {
                return false
            }
            return pricing.thresholdTokens == nil
        case .devin:
            // Only Cognition's own rows reprice from a rollup; a model Devin
            // borrowed from another family may carry that family's tiers.
            let models = dataSet.providers.cognition.models
            guard let pricing = models[normalizeCognitionModel(model, models: models)] else {
                return false
            }
            return pricing.thresholdTokens == nil
        case .chatgptChat, .museAgent, .alibaba, .alibabaTokenPlan, .copilot, .zai, .minimax, .kimi,
             .cursor, .mimo, .iflytek, .tencentHunyuan, .tencentTokenPlan,
             .volcengine, .volcengineAgentPlan, .baiduQianfan, .openCodeGo,
             .kilo, .kiro, .ollama, .openRouter, .warp:
            return false
        }
    }

    private static func tieredCost(
        tokens: Int,
        base: Double,
        above: Double?,
        threshold: Int?
    ) -> Double {
        let tokens = max(0, tokens)
        guard let threshold, let above else { return Double(tokens) * base }
        let below = min(tokens, threshold)
        let over = max(tokens - threshold, 0)
        return Double(below) * base + Double(over) * above
    }

    // MARK: - Model-suffix patterns
    //
    // Compiled once. `String.range(of:options:.regularExpression)` builds a
    // fresh ICU matcher on every call, and model normalisation runs at least
    // once per usage event — millions of times in one cold scan.

    private enum Patterns {
        static let codexDated = regex(#"-\d{4}-\d{2}-\d{2}$"#)
        static let claudeVersioned = regex(#"-v\d+:\d+$"#)
        static let claudeDated = regex(#"-\d{8}$"#)
        static let geminiDated = regex(#"-(preview-)?\d{2,4}-\d{2}(-\d{2})?$"#)
        static let geminiRevision = regex(#"-\d{3}$"#)
        static let grokDated = regex(#"-(beta|preview|\d{4}-\d{2}-\d{2}|\d{4}-\d{2})$"#)

        private static func regex(_ pattern: String) -> NSRegularExpression? {
            try? NSRegularExpression(pattern: pattern)
        }
    }

    /// First match of `regex` in `string`, as a `String` range. Same
    /// semantics as `string.range(of: pattern, options: .regularExpression)`
    /// (both go through ICU via `NSRegularExpression`); a pattern that fails
    /// to compile degrades to "no match", exactly as the string API does.
    private static func firstMatchRange(
        _ regex: NSRegularExpression?,
        in string: String
    ) -> Range<String.Index>? {
        guard let regex else { return nil }
        let full = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = regex.firstMatch(in: string, options: [], range: full) else {
            return nil
        }
        return Range(match.range, in: string)
    }

    // MARK: - Codex

    static func normalizeCodexModel(_ raw: String) -> String {
        normalizeCodexModel(raw, models: PricingResolver.active.providers.codex.models)
    }

    static func normalizeCodexModel(
        _ raw: String,
        models codex: [String: PricingDataSet.CodexEntry]
    ) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("openai/") {
            trimmed = String(trimmed.dropFirst("openai/".count))
        }
        if codex[trimmed] != nil { return trimmed }
        if let datedSuffix = firstMatchRange(Patterns.codexDated, in: trimmed) {
            let base = String(trimmed[..<datedSuffix.lowerBound])
            if codex[base] != nil { return base }
        }
        return trimmed
    }

    static func codexDisplayLabel(model: String) -> String? {
        let codex = PricingResolver.active.providers.codex.models
        return codex[normalizeCodexModel(model, models: codex)]?.displayLabel
    }

    static func codexCostUSD(
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        isFast: Bool = false
    ) -> Double? {
        let codex = PricingResolver.active.providers.codex.models
        guard let pricing = codex[normalizeCodexModel(model, models: codex)] else { return nil }
        return codexCostUSD(
            pricing: pricing,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            isFast: isFast
        )
    }

    static func codexCostUSD(
        pricing: PricingDataSet.CodexEntry,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        isFast: Bool
    ) -> Double {
        let cached = min(max(0, cachedInputTokens), max(0, inputTokens))
        let nonCached = max(0, inputTokens - cached)
        let cachedRate = pricing.cacheRead ?? pricing.input
        let base = tieredCost(
            tokens: nonCached,
            base: pricing.input,
            above: pricing.inputAboveThreshold,
            threshold: pricing.thresholdTokens
        ) + tieredCost(
            tokens: cached,
            base: cachedRate,
            above: pricing.cacheReadAboveThreshold ?? pricing.inputAboveThreshold,
            threshold: pricing.thresholdTokens
        ) + tieredCost(
            tokens: outputTokens,
            base: pricing.output,
            above: pricing.outputAboveThreshold,
            threshold: pricing.thresholdTokens
        )
        return base * fastFactor(isFast, pricing.fastMultiplier)
    }

    // MARK: - Claude

    static func normalizeClaudeModel(_ raw: String) -> String {
        normalizeClaudeModel(raw, models: PricingResolver.active.providers.claude.models)
    }

    static func normalizeClaudeModel(
        _ raw: String,
        models claude: [String: PricingDataSet.ClaudeEntry]
    ) -> String {
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
        if let vRange = firstMatchRange(Patterns.claudeVersioned, in: trimmed) {
            trimmed.removeSubrange(vRange)
        }
        if let baseRange = firstMatchRange(Patterns.claudeDated, in: trimmed) {
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
        guard let pricing = claude[normalizeClaudeModel(model, models: claude)] else { return nil }
        return claudeCostUSD(
            pricing: pricing,
            inputTokens: inputTokens,
            cacheReadInputTokens: cacheReadInputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens,
            outputTokens: outputTokens,
            isFast: isFast
        )
    }

    static func claudeCostUSD(
        pricing: PricingDataSet.ClaudeEntry,
        inputTokens: Int,
        cacheReadInputTokens: Int,
        cacheCreationInputTokens: Int,
        outputTokens: Int,
        isFast: Bool
    ) -> Double {
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
        normalizeGeminiModel(raw, models: PricingResolver.active.providers.gemini.models)
    }

    static func normalizeGeminiModel(
        _ raw: String,
        models gemini: [String: PricingDataSet.GeminiEntry]
    ) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("models/") {
            trimmed = String(trimmed.dropFirst("models/".count))
        }
        if gemini[trimmed] != nil { return trimmed }
        if let datedSuffix = firstMatchRange(Patterns.geminiDated, in: trimmed) {
            let base = String(trimmed[..<datedSuffix.lowerBound])
            if gemini[base] != nil { return base }
        }
        if let revSuffix = firstMatchRange(Patterns.geminiRevision, in: trimmed) {
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
        return gemini[normalizeGeminiModel(model, models: gemini)]?.displayLabel
    }

    static func geminiCostUSD(
        model: String,
        inputTokens: Int,
        cacheReadInputTokens: Int,
        outputTokens: Int
    ) -> Double? {
        let gemini = PricingResolver.active.providers.gemini.models
        guard let pricing = gemini[normalizeGeminiModel(model, models: gemini)] else { return nil }
        return geminiCostUSD(
            pricing: pricing,
            inputTokens: inputTokens,
            cacheReadInputTokens: cacheReadInputTokens,
            outputTokens: outputTokens
        )
    }

    static func geminiCostUSD(
        pricing: PricingDataSet.GeminiEntry,
        inputTokens: Int,
        cacheReadInputTokens: Int,
        outputTokens: Int
    ) -> Double {
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
        normalizeGrokModel(raw, models: PricingResolver.active.providers.grok.models)
    }

    static func normalizeGrokModel(
        _ raw: String,
        models grok: [String: PricingDataSet.GrokEntry]
    ) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("xai/") {
            trimmed = String(trimmed.dropFirst("xai/".count))
        }
        if grok[trimmed] != nil { return trimmed }
        if let datedRange = firstMatchRange(Patterns.grokDated, in: trimmed) {
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
        return grok[normalizeGrokModel(model, models: grok)]?.displayLabel
    }

    static func grokCostUSD(
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int
    ) -> Double? {
        let grok = PricingResolver.active.providers.grok.models
        guard let pricing = grok[normalizeGrokModel(model, models: grok)] else { return nil }
        return grokCostUSD(
            pricing: pricing,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens
        )
    }

    static func grokCostUSD(
        pricing: PricingDataSet.GrokEntry,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int
    ) -> Double {
        let cached = min(max(0, cachedInputTokens), max(0, inputTokens))
        let nonCached = max(0, inputTokens - cached)
        let cachedRate = pricing.cacheRead ?? pricing.input
        return tieredCost(
            tokens: nonCached,
            base: pricing.input,
            above: pricing.inputAboveThreshold,
            threshold: pricing.thresholdTokens
        ) + tieredCost(
            tokens: cached,
            base: cachedRate,
            above: pricing.cacheReadAboveThreshold ?? pricing.inputAboveThreshold,
            threshold: pricing.thresholdTokens
        ) + tieredCost(
            tokens: outputTokens,
            base: pricing.output,
            above: pricing.outputAboveThreshold,
            threshold: pricing.thresholdTokens
        )
    }

    // MARK: - Muse Code

    /// Muse logs the bare API id (`muse-spark-1.3-contributor`); LiteLLM
    /// spells the same model `meta/muse-spark-1.3-contributor`. The
    /// contributor variants are separate rows — they bill at a tenth of
    /// the standard rate — so a suffix is never stripped to reach a base
    /// model's price.
    static func normalizeMuseModel(
        _ raw: String,
        models muse: [String: PricingDataSet.MuseEntry]
    ) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("meta/") {
            trimmed = String(trimmed.dropFirst("meta/".count))
        }
        return trimmed
    }

    static func museCostUSD(
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int
    ) -> Double? {
        let muse = PricingResolver.active.providers.muse.models
        guard let pricing = muse[normalizeMuseModel(model, models: muse)] else { return nil }
        return grokCostUSD(
            pricing: pricing,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens
        )
    }

    // MARK: - Devin

    /// Devin logs Cognition's ids with their reasoning effort attached
    /// (`swe-2-high`); LiteLLM lists `cognition/swe-2`. The exact id wins, then
    /// the id without its effort suffix.
    static func normalizeCognitionModel(
        _ raw: String,
        models cognition: [String: PricingDataSet.CognitionEntry]
    ) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("cognition/") {
            trimmed = String(trimmed.dropFirst("cognition/".count))
        }
        if cognition[trimmed] != nil { return trimmed }
        var candidate = trimmed
        for suffix in ["-fast", "-max", "-xhigh", "-high", "-medium", "-low", "-thinking"]
        where candidate.hasSuffix(suffix) {
            candidate = String(candidate.dropLast(suffix.count))
            if cognition[candidate] != nil { return candidate }
        }
        return trimmed
    }

    /// A Devin request priced by its model through the pipeline: Cognition's
    /// own SWE rows first, then — for a model Devin ran from another lab — the
    /// family that model belongs to. `inputTokens` excludes the cached prefix;
    /// `cacheCreationTokens` is part of `cacheTokens`.
    static func devinCostUSD(
        dataSet: PricingDataSet = PricingResolver.active,
        model rawModel: String,
        inputTokens: Int,
        cacheTokens: Int,
        cacheCreationTokens: Int,
        outputTokens: Int
    ) -> Double? {
        let fresh = max(0, inputTokens)
        let cache = max(0, cacheTokens)
        let creation = min(max(0, cacheCreationTokens), cache)
        let output = max(0, outputTokens)
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let cognition = dataSet.providers.cognition.models
        if let pricing = cognition[normalizeCognitionModel(model, models: cognition)] {
            return grokCostUSD(pricing: pricing, inputTokens: fresh + cache, cachedInputTokens: cache, outputTokens: output)
        }
        if model.hasPrefix("claude") {
            let models = dataSet.providers.claude.models
            guard let pricing = models[normalizeClaudeModel(model, models: models)] else { return nil }
            return claudeCostUSD(
                pricing: pricing, inputTokens: fresh, cacheReadInputTokens: cache - creation,
                cacheCreationInputTokens: creation, outputTokens: output, isFast: false
            )
        }
        if model.hasPrefix("gpt") || model.hasPrefix("o3") || model.hasPrefix("o4") || model.hasPrefix("codex") {
            let models = dataSet.providers.codex.models
            guard let pricing = models[normalizeCodexModel(model, models: models)] else { return nil }
            return codexCostUSD(
                pricing: pricing, inputTokens: fresh + cache, cachedInputTokens: cache,
                outputTokens: output, isFast: false
            )
        }
        if model.hasPrefix("gemini") {
            let models = dataSet.providers.gemini.models
            guard let pricing = models[normalizeGeminiModel(model, models: models)] else { return nil }
            return geminiCostUSD(
                pricing: pricing, inputTokens: fresh + cache, cacheReadInputTokens: cache, outputTokens: output
            )
        }
        if model.hasPrefix("grok") {
            let models = dataSet.providers.grok.models
            guard let pricing = models[normalizeGrokModel(model, models: models)] else { return nil }
            return grokCostUSD(pricing: pricing, inputTokens: fresh + cache, cachedInputTokens: cache, outputTokens: output)
        }
        let mistral = dataSet.providers.mistral.models
        if let pricing = mistral[normalizeMistralModel(model, models: mistral)] {
            return grokCostUSD(pricing: pricing, inputTokens: fresh + cache, cachedInputTokens: cache, outputTokens: output)
        }
        let muse = dataSet.providers.muse.models
        if let pricing = muse[normalizeMuseModel(model, models: muse)] {
            return grokCostUSD(pricing: pricing, inputTokens: fresh + cache, cachedInputTokens: cache, outputTokens: output)
        }
        return nil
    }

    // MARK: - Mistral Vibe

    /// Mistral Vibe logs the La Plateforme id its alias resolves to
    /// (`mistral-vibe-cli-latest`); LiteLLM spells the same model
    /// `mistral/mistral-vibe-cli-latest`.
    static func normalizeMistralModel(
        _ raw: String,
        models mistral: [String: PricingDataSet.MistralEntry]
    ) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("mistral/") {
            trimmed = String(trimmed.dropFirst("mistral/".count))
        }
        return trimmed
    }

    static func mistralCostUSD(
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int
    ) -> Double? {
        let mistral = PricingResolver.active.providers.mistral.models
        guard let pricing = mistral[normalizeMistralModel(model, models: mistral)] else { return nil }
        return grokCostUSD(
            pricing: pricing,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens
        )
    }

    // MARK: - AntiGravity

    static func normalizeAntigravityModel(_ raw: String) -> String {
        normalizeAntigravityModel(raw, models: PricingResolver.active.providers.antigravity.models)
    }

    static func normalizeAntigravityModel(
        _ raw: String,
        models antigravity: [String: PricingDataSet.AntigravityEntry]
    ) -> String {
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
        return antigravity[normalizeAntigravityModel(model, models: antigravity)]?.displayLabel
    }

    static func antigravityCostUSD(
        model: String,
        inputTokens: Int,
        cacheReadInputTokens: Int,
        cacheCreationInputTokens: Int,
        outputTokens: Int
    ) -> Double? {
        let antigravity = PricingResolver.active.providers.antigravity.models
        guard let pricing = antigravity[
            normalizeAntigravityModel(model, models: antigravity)
        ] else { return nil }
        return antigravityCostUSD(
            pricing: pricing,
            inputTokens: inputTokens,
            cacheReadInputTokens: cacheReadInputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens,
            outputTokens: outputTokens
        )
    }

    static func antigravityCostUSD(
        pricing: PricingDataSet.AntigravityEntry,
        inputTokens: Int,
        cacheReadInputTokens: Int,
        cacheCreationInputTokens: Int,
        outputTokens: Int
    ) -> Double {
        Double(max(0, inputTokens)) * pricing.input
            + Double(max(0, cacheReadInputTokens)) * pricing.cacheRead
            + Double(max(0, cacheCreationInputTokens)) * pricing.cacheCreation
            + Double(max(0, outputTokens)) * pricing.output
    }
}

/// One cost scan pass's view of the pricing tables.
///
/// Two jobs, both about not repeating work per event:
///
/// 1. `PricingResolver.active` is read **once**, at the top of the pass.
///    Every event in the resulting snapshot is therefore priced against
///    one consistent table (which `CostUsageService` already arranges at
///    the pass boundary), and the per-event lock + dictionary retains are
///    gone.
/// 2. Model-name normalisation is memoised per provider. A scan sees a
///    handful of distinct model strings across millions of events, and
///    normalisation trims, lowercases, and runs suffix regexes.
///
/// Deliberately *not* a shared singleton: a pass-scoped memo cannot go
/// stale when the pricing catalog is swapped, so there is no invalidation
/// to get wrong. One instance is created per `CostUsageScanner.scan` and
/// used only from that pass.
final class CostPricingContext {
    let dataSet: PricingDataSet

    private var codexNames: [String: String] = [:]
    private var claudeNames: [String: String] = [:]
    private var geminiNames: [String: String] = [:]
    private var grokNames: [String: String] = [:]
    private var antigravityNames: [String: String] = [:]
    private var museNames: [String: String] = [:]
    private var mistralNames: [String: String] = [:]

    init(dataSet: PricingDataSet = PricingResolver.active) {
        self.dataSet = dataSet
    }

    func codexEntry(for model: String) -> PricingDataSet.CodexEntry? {
        let models = dataSet.providers.codex.models
        if let hit = codexNames[model] { return models[hit] }
        let name = CostUsagePricing.normalizeCodexModel(model, models: models)
        codexNames[model] = name
        return models[name]
    }

    func claudeEntry(for model: String) -> PricingDataSet.ClaudeEntry? {
        let models = dataSet.providers.claude.models
        if let hit = claudeNames[model] { return models[hit] }
        let name = CostUsagePricing.normalizeClaudeModel(model, models: models)
        claudeNames[model] = name
        return models[name]
    }

    func geminiEntry(for model: String) -> PricingDataSet.GeminiEntry? {
        let models = dataSet.providers.gemini.models
        if let hit = geminiNames[model] { return models[hit] }
        let name = CostUsagePricing.normalizeGeminiModel(model, models: models)
        geminiNames[model] = name
        return models[name]
    }

    func grokEntry(for model: String) -> PricingDataSet.GrokEntry? {
        let models = dataSet.providers.grok.models
        if let hit = grokNames[model] { return models[hit] }
        let name = CostUsagePricing.normalizeGrokModel(model, models: models)
        grokNames[model] = name
        return models[name]
    }

    func museEntry(for model: String) -> PricingDataSet.MuseEntry? {
        let models = dataSet.providers.muse.models
        if let hit = museNames[model] { return models[hit] }
        let name = CostUsagePricing.normalizeMuseModel(model, models: models)
        museNames[model] = name
        return models[name]
    }

    func mistralEntry(for model: String) -> PricingDataSet.MistralEntry? {
        let models = dataSet.providers.mistral.models
        if let hit = mistralNames[model] { return models[hit] }
        let name = CostUsagePricing.normalizeMistralModel(model, models: models)
        mistralNames[model] = name
        return models[name]
    }

    func antigravityEntry(for model: String) -> PricingDataSet.AntigravityEntry? {
        let models = dataSet.providers.antigravity.models
        if let hit = antigravityNames[model] { return models[hit] }
        let name = CostUsagePricing.normalizeAntigravityModel(model, models: models)
        antigravityNames[model] = name
        return models[name]
    }
}
