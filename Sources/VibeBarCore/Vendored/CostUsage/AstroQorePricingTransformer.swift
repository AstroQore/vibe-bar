import Foundation

/// Decoder for the small, curated AstroQore supplement repository. Values in
/// that repository are USD per one million tokens.
public enum AstroQorePricingTransformer {
    struct Document: Decodable {
        let schemaVersion: Int
        let models: [Model]
    }

    struct Model: Decodable {
        let provider: PricingProviderFamily
        let model: String
        let displayLabel: String?
        let inherits: ModelReference?
        let pricing: Pricing
    }

    struct ModelReference: Decodable {
        let provider: PricingProviderFamily
        let model: String
    }

    struct Pricing: Decodable {
        let input: Double
        let output: Double
        let cacheRead: Double?
        let cacheWrite: Double?
        let threshold: Threshold?
        let fast: Rates?
    }

    struct Rates: Decodable {
        let input: Double
        let output: Double
        let cacheRead: Double?
        let cacheWrite: Double?
    }

    struct Threshold: Decodable {
        let tokens: Int
        let input: Double
        let output: Double
        let cacheRead: Double?
        let cacheWrite: Double?
    }

    public static func transform(
        _ data: Data,
        updatedAt: String,
        calculationVersion: Int,
        inheritanceBase: PricingDataSet? = nil
    ) -> PricingDataSet? {
        guard let document = try? JSONDecoder().decode(Document.self, from: data),
              document.schemaVersion == 1
        else { return nil }

        var codex: [String: PricingDataSet.CodexEntry] = [:]
        var claude: [String: PricingDataSet.ClaudeEntry] = [:]
        var gemini: [String: PricingDataSet.GeminiEntry] = [:]
        var grok: [String: PricingDataSet.GrokEntry] = [:]
        var antigravity: [String: PricingDataSet.AntigravityEntry] = [:]

        for model in document.models {
            let id = model.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let price = model.pricing
            guard !id.isEmpty, valid(price.input), valid(price.output) else { continue }
            let fastMultiplier = multiplier(base: price, fast: price.fast)

            switch model.provider {
            case .codex:
                if let inherited = inheritedCodex(model.inherits, from: inheritanceBase) {
                    codex[id] = copy(inherited, displayLabel: model.displayLabel)
                    continue
                }
                codex[id] = .init(
                    input: perToken(price.input), output: perToken(price.output),
                    cacheRead: price.cacheRead.map(perToken),
                    cacheCreation: price.cacheWrite.map(perToken),
                    thresholdTokens: price.threshold?.tokens,
                    inputAboveThreshold: price.threshold.map { perToken($0.input) },
                    outputAboveThreshold: price.threshold.map { perToken($0.output) },
                    cacheReadAboveThreshold: price.threshold?.cacheRead.map(perToken),
                    cacheCreationAboveThreshold: price.threshold?.cacheWrite.map(perToken),
                    fastMultiplier: fastMultiplier,
                    displayLabel: model.displayLabel
                )
            case .claude:
                if let inherited = inheritedClaude(model.inherits, from: inheritanceBase) {
                    claude[id] = inherited
                    continue
                }
                claude[id] = .init(
                    input: perToken(price.input), output: perToken(price.output),
                    cacheCreation: perToken(price.cacheWrite ?? price.input * 1.25),
                    cacheRead: perToken(price.cacheRead ?? price.input * 0.1),
                    thresholdTokens: price.threshold?.tokens,
                    inputAboveThreshold: price.threshold.map { perToken($0.input) },
                    outputAboveThreshold: price.threshold.map { perToken($0.output) },
                    cacheCreationAboveThreshold: price.threshold?.cacheWrite.map(perToken),
                    cacheReadAboveThreshold: price.threshold?.cacheRead.map(perToken),
                    fastMultiplier: fastMultiplier
                )
            case .gemini:
                if let inherited = inheritedGemini(model.inherits, from: inheritanceBase) {
                    gemini[id] = copy(inherited, displayLabel: model.displayLabel)
                    continue
                }
                gemini[id] = .init(
                    input: perToken(price.input), output: perToken(price.output),
                    cacheRead: price.cacheRead.map(perToken),
                    thresholdTokens: price.threshold?.tokens,
                    inputAboveThreshold: price.threshold.map { perToken($0.input) },
                    outputAboveThreshold: price.threshold.map { perToken($0.output) },
                    cacheReadAboveThreshold: price.threshold?.cacheRead.map(perToken),
                    displayLabel: model.displayLabel
                )
            case .grok:
                if let inherited = inheritedGrok(model.inherits, from: inheritanceBase) {
                    grok[id] = copy(inherited, displayLabel: model.displayLabel)
                    continue
                }
                grok[id] = .init(
                    input: perToken(price.input), output: perToken(price.output),
                    cacheRead: price.cacheRead.map(perToken),
                    thresholdTokens: price.threshold?.tokens,
                    inputAboveThreshold: price.threshold.map { perToken($0.input) },
                    outputAboveThreshold: price.threshold.map { perToken($0.output) },
                    cacheReadAboveThreshold: price.threshold?.cacheRead.map(perToken),
                    displayLabel: model.displayLabel
                )
            case .antigravity:
                if let inherited = inheritedAntigravity(model.inherits, from: inheritanceBase) {
                    antigravity[id] = .init(
                        input: inherited.input, output: inherited.output,
                        cacheRead: inherited.cacheRead,
                        cacheCreation: inherited.cacheCreation,
                        displayLabel: model.displayLabel ?? inherited.displayLabel
                    )
                    continue
                }
                antigravity[id] = .init(
                    input: perToken(price.input), output: perToken(price.output),
                    cacheRead: perToken(price.cacheRead ?? 0),
                    cacheCreation: perToken(price.cacheWrite ?? 0),
                    displayLabel: model.displayLabel
                )
            }
        }

        guard !codex.isEmpty || !claude.isEmpty || !gemini.isEmpty
                || !grok.isEmpty || !antigravity.isEmpty
        else { return nil }
        return PricingDataSet(
            schemaVersion: PricingDataSet.currentSchemaVersion,
            updatedAt: updatedAt,
            calculationVersion: calculationVersion,
            providers: .init(
                codex: .init(displayName: "OpenAI", models: codex),
                claude: .init(displayName: "Anthropic", models: claude),
                gemini: .init(displayName: "Google", models: gemini),
                grok: .init(displayName: "xAI", models: grok),
                antigravity: .init(displayName: "AntiGravity", models: antigravity)
            )
        )
    }

    private static func valid(_ value: Double) -> Bool {
        value.isFinite && value >= 0
    }

    private static func inheritedCodex(
        _ reference: ModelReference?, from base: PricingDataSet?
    ) -> PricingDataSet.CodexEntry? {
        guard reference?.provider == .codex, let id = reference?.model.lowercased() else { return nil }
        return base?.providers.codex.models[id]
    }

    private static func inheritedClaude(
        _ reference: ModelReference?, from base: PricingDataSet?
    ) -> PricingDataSet.ClaudeEntry? {
        guard reference?.provider == .claude, let id = reference?.model.lowercased() else { return nil }
        return base?.providers.claude.models[id]
    }

    private static func inheritedGemini(
        _ reference: ModelReference?, from base: PricingDataSet?
    ) -> PricingDataSet.GeminiEntry? {
        guard reference?.provider == .gemini, let id = reference?.model.lowercased() else { return nil }
        return base?.providers.gemini.models[id]
    }

    private static func inheritedGrok(
        _ reference: ModelReference?, from base: PricingDataSet?
    ) -> PricingDataSet.GrokEntry? {
        guard reference?.provider == .grok, let id = reference?.model.lowercased() else { return nil }
        return base?.providers.grok.models[id]
    }

    private static func inheritedAntigravity(
        _ reference: ModelReference?, from base: PricingDataSet?
    ) -> PricingDataSet.AntigravityEntry? {
        guard reference?.provider == .antigravity, let id = reference?.model.lowercased() else { return nil }
        return base?.providers.antigravity.models[id]
    }

    private static func copy(
        _ entry: PricingDataSet.CodexEntry,
        displayLabel: String?
    ) -> PricingDataSet.CodexEntry {
        .init(
            input: entry.input, output: entry.output,
            cacheRead: entry.cacheRead, cacheCreation: entry.cacheCreation,
            thresholdTokens: entry.thresholdTokens,
            inputAboveThreshold: entry.inputAboveThreshold,
            outputAboveThreshold: entry.outputAboveThreshold,
            cacheReadAboveThreshold: entry.cacheReadAboveThreshold,
            cacheCreationAboveThreshold: entry.cacheCreationAboveThreshold,
            fastMultiplier: entry.fastMultiplier,
            displayLabel: displayLabel ?? entry.displayLabel
        )
    }

    private static func copy(
        _ entry: PricingDataSet.GeminiEntry,
        displayLabel: String?
    ) -> PricingDataSet.GeminiEntry {
        .init(
            input: entry.input, output: entry.output, cacheRead: entry.cacheRead,
            thresholdTokens: entry.thresholdTokens,
            inputAboveThreshold: entry.inputAboveThreshold,
            outputAboveThreshold: entry.outputAboveThreshold,
            cacheReadAboveThreshold: entry.cacheReadAboveThreshold,
            displayLabel: displayLabel ?? entry.displayLabel
        )
    }

    private static func copy(
        _ entry: PricingDataSet.GrokEntry,
        displayLabel: String?
    ) -> PricingDataSet.GrokEntry {
        .init(
            input: entry.input, output: entry.output, cacheRead: entry.cacheRead,
            thresholdTokens: entry.thresholdTokens,
            inputAboveThreshold: entry.inputAboveThreshold,
            outputAboveThreshold: entry.outputAboveThreshold,
            cacheReadAboveThreshold: entry.cacheReadAboveThreshold,
            displayLabel: displayLabel ?? entry.displayLabel
        )
    }

    private static func perToken(_ perMillion: Double) -> Double {
        perMillion / 1_000_000
    }

    private static func multiplier(base: Pricing, fast: Rates?) -> Double? {
        guard let fast else { return nil }
        let ratio: Double
        if base.output > 0 {
            ratio = fast.output / base.output
        } else if base.input > 0 {
            ratio = fast.input / base.input
        } else {
            return nil
        }
        return ratio.isFinite && ratio > 0 ? ratio : nil
    }
}
