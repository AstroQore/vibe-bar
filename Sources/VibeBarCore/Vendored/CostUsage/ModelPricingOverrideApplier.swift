import Foundation

enum ModelPricingOverrideApplier {
    static func apply(
        _ overrides: [ModelPricingOverride],
        to base: PricingDataSet,
        updatedAt: String
    ) -> PricingDataSet {
        var result = base
        for override in overrides where override.isUsable {
            let source = dataSet(for: override, base: result)
            result = PricingDataSetMerger.overlay(
                source,
                onto: result,
                updatedAt: updatedAt,
                fillMissingFromBase: false
            )
        }
        return result
    }

    private static func dataSet(
        for override: ModelPricingOverride,
        base: PricingDataSet
    ) -> PricingDataSet {
        let empty = PricingDataSet.empty(
            updatedAt: base.updatedAt,
            calculationVersion: base.calculationVersion
        )
        let id = override.normalizedModel
        let input = perToken(override.inputPerMillion)
        let output = perToken(override.outputPerMillion)
        let threshold = override.thresholdTokens.flatMap { $0 > 0 ? $0 : nil }

        switch override.provider {
        case .codex:
            return replacing(empty, codex: [id: .init(
                input: input, output: output,
                cacheRead: override.cacheReadPerMillion.map(perToken),
                cacheCreation: override.cacheWritePerMillion.map(perToken),
                thresholdTokens: threshold,
                inputAboveThreshold: override.inputAboveThresholdPerMillion.map(perToken),
                outputAboveThreshold: override.outputAboveThresholdPerMillion.map(perToken),
                cacheReadAboveThreshold: override.cacheReadAboveThresholdPerMillion.map(perToken),
                cacheCreationAboveThreshold: override.cacheWriteAboveThresholdPerMillion.map(perToken),
                fastMultiplier: override.fastMultiplier,
                displayLabel: override.displayLabel
            )])
        case .claude:
            return replacing(empty, claude: [id: .init(
                input: input, output: output,
                cacheCreation: perToken(override.cacheWritePerMillion ?? override.inputPerMillion * 1.25),
                cacheRead: perToken(override.cacheReadPerMillion ?? override.inputPerMillion * 0.1),
                thresholdTokens: threshold,
                inputAboveThreshold: override.inputAboveThresholdPerMillion.map(perToken),
                outputAboveThreshold: override.outputAboveThresholdPerMillion.map(perToken),
                cacheCreationAboveThreshold: override.cacheWriteAboveThresholdPerMillion.map(perToken),
                cacheReadAboveThreshold: override.cacheReadAboveThresholdPerMillion.map(perToken),
                fastMultiplier: override.fastMultiplier
            )])
        case .gemini:
            return replacing(empty, gemini: [id: .init(
                input: input, output: output,
                cacheRead: override.cacheReadPerMillion.map(perToken),
                thresholdTokens: threshold,
                inputAboveThreshold: override.inputAboveThresholdPerMillion.map(perToken),
                outputAboveThreshold: override.outputAboveThresholdPerMillion.map(perToken),
                cacheReadAboveThreshold: override.cacheReadAboveThresholdPerMillion.map(perToken),
                displayLabel: override.displayLabel
            )])
        case .grok:
            return replacing(empty, grok: [id: .init(
                input: input, output: output,
                cacheRead: override.cacheReadPerMillion.map(perToken),
                thresholdTokens: threshold,
                inputAboveThreshold: override.inputAboveThresholdPerMillion.map(perToken),
                outputAboveThreshold: override.outputAboveThresholdPerMillion.map(perToken),
                cacheReadAboveThreshold: override.cacheReadAboveThresholdPerMillion.map(perToken),
                displayLabel: override.displayLabel
            )])
        case .antigravity:
            return replacing(empty, antigravity: [id: .init(
                input: input, output: output,
                cacheRead: perToken(override.cacheReadPerMillion ?? 0),
                cacheCreation: perToken(override.cacheWritePerMillion ?? 0),
                displayLabel: override.displayLabel
            )])
        }
    }

    private static func replacing(
        _ dataSet: PricingDataSet,
        codex: [String: PricingDataSet.CodexEntry] = [:],
        claude: [String: PricingDataSet.ClaudeEntry] = [:],
        gemini: [String: PricingDataSet.GeminiEntry] = [:],
        grok: [String: PricingDataSet.GrokEntry] = [:],
        antigravity: [String: PricingDataSet.AntigravityEntry] = [:]
    ) -> PricingDataSet {
        PricingDataSet(
            schemaVersion: dataSet.schemaVersion,
            updatedAt: dataSet.updatedAt,
            calculationVersion: dataSet.calculationVersion,
            providers: .init(
                codex: .init(displayName: "OpenAI", models: codex),
                claude: .init(displayName: "Anthropic", models: claude),
                gemini: .init(displayName: "Google", models: gemini),
                grok: .init(displayName: "xAI", models: grok),
                antigravity: .init(displayName: "AntiGravity", models: antigravity)
            )
        )
    }

    private static func perToken(_ perMillion: Double) -> Double {
        perMillion / 1_000_000
    }
}
