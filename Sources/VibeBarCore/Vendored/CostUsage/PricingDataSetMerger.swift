import Foundation

enum PricingDataSetMerger {
    /// Overlay every model from `higherPriority` onto `base`. Call this from
    /// lowest to highest priority. Required input/output prices come from the
    /// higher source; optional cache/tier/fast fields fall through only when
    /// that source omits them. User overrides disable that fallthrough.
    static func overlay(
        _ higherPriority: PricingDataSet,
        onto base: PricingDataSet,
        updatedAt: String,
        fillMissingFromBase: Bool = true
    ) -> PricingDataSet {
        var codex = base.providers.codex.models
        var claude = base.providers.claude.models
        var gemini = base.providers.gemini.models
        var grok = base.providers.grok.models
        var antigravity = base.providers.antigravity.models

        codex.merge(higherPriority.providers.codex.models) { old, new in
            fillMissingFromBase ? merge(new, over: old) : new
        }
        claude.merge(higherPriority.providers.claude.models) { old, new in
            fillMissingFromBase ? merge(new, over: old) : new
        }
        gemini.merge(higherPriority.providers.gemini.models) { old, new in
            fillMissingFromBase ? merge(new, over: old) : new
        }
        grok.merge(higherPriority.providers.grok.models) { old, new in
            fillMissingFromBase ? merge(new, over: old) : new
        }
        antigravity.merge(higherPriority.providers.antigravity.models) { old, new in
            fillMissingFromBase ? merge(new, over: old) : new
        }

        return PricingDataSet(
            schemaVersion: PricingDataSet.currentSchemaVersion,
            updatedAt: updatedAt,
            calculationVersion: base.calculationVersion,
            providers: .init(
                codex: .init(displayName: base.providers.codex.displayName, models: codex),
                claude: .init(displayName: base.providers.claude.displayName, models: claude),
                gemini: .init(displayName: base.providers.gemini.displayName, models: gemini),
                grok: .init(displayName: base.providers.grok.displayName, models: grok),
                antigravity: .init(
                    displayName: base.providers.antigravity.displayName,
                    models: antigravity
                )
            )
        )
    }

    private static func merge(
        _ high: PricingDataSet.CodexEntry,
        over low: PricingDataSet.CodexEntry
    ) -> PricingDataSet.CodexEntry {
        let canFillTier = high.thresholdTokens == nil || high.thresholdTokens == low.thresholdTokens
        return .init(
            input: high.input, output: high.output,
            cacheRead: high.cacheRead ?? low.cacheRead,
            cacheCreation: high.cacheCreation ?? low.cacheCreation,
            thresholdTokens: high.thresholdTokens ?? low.thresholdTokens,
            inputAboveThreshold: high.inputAboveThreshold ?? (canFillTier ? low.inputAboveThreshold : nil),
            outputAboveThreshold: high.outputAboveThreshold ?? (canFillTier ? low.outputAboveThreshold : nil),
            cacheReadAboveThreshold: high.cacheReadAboveThreshold
                ?? (canFillTier ? low.cacheReadAboveThreshold : nil),
            cacheCreationAboveThreshold: high.cacheCreationAboveThreshold
                ?? (canFillTier ? low.cacheCreationAboveThreshold : nil),
            fastMultiplier: high.fastMultiplier ?? low.fastMultiplier,
            displayLabel: high.displayLabel ?? low.displayLabel
        )
    }

    private static func merge(
        _ high: PricingDataSet.ClaudeEntry,
        over low: PricingDataSet.ClaudeEntry
    ) -> PricingDataSet.ClaudeEntry {
        let canFillTier = high.thresholdTokens == nil || high.thresholdTokens == low.thresholdTokens
        return .init(
            input: high.input, output: high.output,
            cacheCreation: high.cacheCreation, cacheRead: high.cacheRead,
            thresholdTokens: high.thresholdTokens ?? low.thresholdTokens,
            inputAboveThreshold: high.inputAboveThreshold ?? (canFillTier ? low.inputAboveThreshold : nil),
            outputAboveThreshold: high.outputAboveThreshold ?? (canFillTier ? low.outputAboveThreshold : nil),
            cacheCreationAboveThreshold: high.cacheCreationAboveThreshold
                ?? (canFillTier ? low.cacheCreationAboveThreshold : nil),
            cacheReadAboveThreshold: high.cacheReadAboveThreshold
                ?? (canFillTier ? low.cacheReadAboveThreshold : nil),
            fastMultiplier: high.fastMultiplier ?? low.fastMultiplier
        )
    }

    private static func merge(
        _ high: PricingDataSet.GeminiEntry,
        over low: PricingDataSet.GeminiEntry
    ) -> PricingDataSet.GeminiEntry {
        let canFillTier = high.thresholdTokens == nil || high.thresholdTokens == low.thresholdTokens
        return .init(
            input: high.input, output: high.output,
            cacheRead: high.cacheRead ?? low.cacheRead,
            thresholdTokens: high.thresholdTokens ?? low.thresholdTokens,
            inputAboveThreshold: high.inputAboveThreshold ?? (canFillTier ? low.inputAboveThreshold : nil),
            outputAboveThreshold: high.outputAboveThreshold ?? (canFillTier ? low.outputAboveThreshold : nil),
            cacheReadAboveThreshold: high.cacheReadAboveThreshold
                ?? (canFillTier ? low.cacheReadAboveThreshold : nil),
            displayLabel: high.displayLabel ?? low.displayLabel
        )
    }

    private static func merge(
        _ high: PricingDataSet.GrokEntry,
        over low: PricingDataSet.GrokEntry
    ) -> PricingDataSet.GrokEntry {
        let canFillTier = high.thresholdTokens == nil || high.thresholdTokens == low.thresholdTokens
        return .init(
            input: high.input, output: high.output,
            cacheRead: high.cacheRead ?? low.cacheRead,
            thresholdTokens: high.thresholdTokens ?? low.thresholdTokens,
            inputAboveThreshold: high.inputAboveThreshold ?? (canFillTier ? low.inputAboveThreshold : nil),
            outputAboveThreshold: high.outputAboveThreshold ?? (canFillTier ? low.outputAboveThreshold : nil),
            cacheReadAboveThreshold: high.cacheReadAboveThreshold
                ?? (canFillTier ? low.cacheReadAboveThreshold : nil),
            displayLabel: high.displayLabel ?? low.displayLabel
        )
    }

    private static func merge(
        _ high: PricingDataSet.AntigravityEntry,
        over low: PricingDataSet.AntigravityEntry
    ) -> PricingDataSet.AntigravityEntry {
        .init(
            input: high.input, output: high.output,
            cacheRead: high.cacheRead, cacheCreation: high.cacheCreation,
            displayLabel: high.displayLabel ?? low.displayLabel
        )
    }
}
