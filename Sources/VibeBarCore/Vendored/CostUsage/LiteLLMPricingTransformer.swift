import Foundation

/// Transforms LiteLLM's community-maintained
/// `model_prices_and_context_window.json` into Vibe Bar's
/// `PricingDataSet`, **overlaid on a base set** so curated entries that
/// LiteLLM doesn't cover survive (AntiGravity shadow rates, models
/// LiteLLM prices as `null`, display labels). This is what lets
/// `PricingRefresher` follow upstream pricing automatically instead of
/// hand-editing `pricing.json` for every new model.
///
/// Overlay semantics: every LiteLLM model that classifies into a known
/// provider family updates (or adds) that entry; everything else in the
/// base set is left untouched. LiteLLM is therefore authoritative for
/// the models it prices, and the bundled floor covers the rest.
///
/// Only the canonical, bare model keys are kept (`gpt-…`, `claude-…`,
/// `gemini-…`, `grok-…`, plus `xai/grok-…` with the vendor prefix
/// stripped). The thousands of `vertex_ai/…`, `azure/…`, `bedrock`,
/// `openrouter/…` aliases are dropped: Codex / Claude / Gemini / Grok
/// CLIs log the bare names, and the alias explosion would blow the
/// cache size cap for no benefit.
public enum LiteLLMPricingTransformer {
    /// Fast/priority multipliers LiteLLM does not publish in
    /// `provider_specific_entry.fast` (the Codex tiers). Mirrors
    /// ccusage's `fast-multiplier-overrides.json`; looked up by the
    /// canonical model key and used only when LiteLLM omits `fast`.
    static let fastMultiplierOverrides: [String: Double] = [
        "gpt-5.5": 2.5,
        "gpt-5.4": 2.0,
        "gpt-5.3-codex": 2.0,
        "claude-opus-4-6": 6.0,
        "claude-opus-4-7": 6.0,
        "claude-opus-4-8": 2.0
    ]

    /// Decoded subset of one LiteLLM model record. Unknown keys are
    /// ignored; a record missing `input`/`output` cost is skipped by
    /// the caller.
    struct RawEntry: Decodable {
        let inputCostPerToken: Double?
        let outputCostPerToken: Double?
        let cacheCreationInputTokenCost: Double?
        let cacheReadInputTokenCost: Double?
        let inputCostPerTokenAbove200k: Double?
        let outputCostPerTokenAbove200k: Double?
        let cacheCreationInputTokenCostAbove200k: Double?
        let cacheReadInputTokenCostAbove200k: Double?
        let providerSpecificEntry: ProviderSpecific?

        struct ProviderSpecific: Decodable {
            let fast: Double?
        }

        enum CodingKeys: String, CodingKey {
            case inputCostPerToken = "input_cost_per_token"
            case outputCostPerToken = "output_cost_per_token"
            case cacheCreationInputTokenCost = "cache_creation_input_token_cost"
            case cacheReadInputTokenCost = "cache_read_input_token_cost"
            case inputCostPerTokenAbove200k = "input_cost_per_token_above_200k_tokens"
            case outputCostPerTokenAbove200k = "output_cost_per_token_above_200k_tokens"
            case cacheCreationInputTokenCostAbove200k = "cache_creation_input_token_cost_above_200k_tokens"
            case cacheReadInputTokenCostAbove200k = "cache_read_input_token_cost_above_200k_tokens"
            case providerSpecificEntry = "provider_specific_entry"
        }
    }

    private enum Family {
        case codex, claude, gemini, grok
    }

    /// Classifies a LiteLLM key into a provider family and the canonical
    /// model key Vibe Bar's normalizers expect, or `nil` to drop it.
    private static func classify(_ rawKey: String) -> (Family, String)? {
        if rawKey.contains("/") {
            // The only prefixed family Vibe Bar normalizes back to a bare
            // key is xAI Grok (`xai/grok-…`). Everything else (vertex_ai,
            // azure, bedrock, openrouter, anthropic.) is an alias we drop.
            guard rawKey.hasPrefix("xai/grok-") else { return nil }
            return (.grok, String(rawKey.dropFirst("xai/".count)))
        }
        if rawKey.hasPrefix("gpt-") { return (.codex, rawKey) }
        if rawKey.hasPrefix("claude-") { return (.claude, rawKey) }
        if rawKey.hasPrefix("gemini-") { return (.gemini, rawKey) }
        if rawKey.hasPrefix("grok-") { return (.grok, rawKey) }
        return nil
    }

    /// Parses the LiteLLM JSON and overlays it on `base`. Returns `nil`
    /// when the payload isn't a usable LiteLLM map (so the caller keeps
    /// the previous cache / bundled floor rather than caching garbage).
    public static func transform(_ data: Data, base: PricingDataSet, updatedAt: String) -> PricingDataSet? {
        guard let raw = try? JSONDecoder().decode([String: RawEntry].self, from: data) else {
            return nil
        }

        var codex = base.providers.codex.models
        var claude = base.providers.claude.models
        var gemini = base.providers.gemini.models
        var grok = base.providers.grok.models
        var loaded = 0

        for (rawKey, entry) in raw {
            guard let input = entry.inputCostPerToken,
                  let output = entry.outputCostPerToken,
                  let (family, key) = classify(rawKey)
            else { continue }

            let fast = entry.providerSpecificEntry?.fast ?? fastMultiplierOverrides[key]
            let threshold: Int? = (entry.inputCostPerTokenAbove200k != nil
                || entry.outputCostPerTokenAbove200k != nil
                || entry.cacheReadInputTokenCostAbove200k != nil) ? 200_000 : nil

            switch family {
            case .codex:
                codex[key] = PricingDataSet.CodexEntry(
                    input: input,
                    output: output,
                    cacheRead: entry.cacheReadInputTokenCost,
                    fastMultiplier: fast,
                    displayLabel: codex[key]?.displayLabel)
            case .claude:
                claude[key] = PricingDataSet.ClaudeEntry(
                    input: input,
                    output: output,
                    cacheCreation: entry.cacheCreationInputTokenCost ?? input * 1.25,
                    cacheRead: entry.cacheReadInputTokenCost ?? input * 0.1,
                    thresholdTokens: threshold,
                    inputAboveThreshold: entry.inputCostPerTokenAbove200k,
                    outputAboveThreshold: entry.outputCostPerTokenAbove200k,
                    cacheCreationAboveThreshold: entry.cacheCreationInputTokenCostAbove200k,
                    cacheReadAboveThreshold: entry.cacheReadInputTokenCostAbove200k,
                    fastMultiplier: fast)
            case .gemini:
                gemini[key] = PricingDataSet.GeminiEntry(
                    input: input,
                    output: output,
                    cacheRead: entry.cacheReadInputTokenCost,
                    thresholdTokens: threshold,
                    inputAboveThreshold: entry.inputCostPerTokenAbove200k,
                    outputAboveThreshold: entry.outputCostPerTokenAbove200k,
                    cacheReadAboveThreshold: entry.cacheReadInputTokenCostAbove200k,
                    displayLabel: gemini[key]?.displayLabel)
            case .grok:
                grok[key] = PricingDataSet.GrokEntry(
                    input: input,
                    output: output,
                    cacheRead: entry.cacheReadInputTokenCost,
                    displayLabel: grok[key]?.displayLabel)
            }
            loaded += 1
        }

        // A valid LiteLLM file always carries the frontier Claude/GPT
        // models. Zero matches means we fetched something else (an error
        // page, a renamed schema) — refuse it so the caller falls back.
        guard loaded > 0 else { return nil }

        return PricingDataSet(
            schemaVersion: PricingDataSet.currentSchemaVersion,
            updatedAt: updatedAt,
            calculationVersion: base.calculationVersion,
            providers: PricingDataSet.Providers(
                codex: .init(displayName: base.providers.codex.displayName, models: codex),
                claude: .init(displayName: base.providers.claude.displayName, models: claude),
                gemini: .init(displayName: base.providers.gemini.displayName, models: gemini),
                grok: .init(displayName: base.providers.grok.displayName, models: grok),
                antigravity: base.providers.antigravity))
    }
}
