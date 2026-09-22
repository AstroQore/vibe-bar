import Foundation

/// Decoder for the small, curated AstroQore supplement repository. Values in
/// that repository are USD per one million tokens.
///
/// Most entries fill gaps: they sit below every public catalog and only
/// price a model none of them lists. An entry marked `"override": true` is a
/// correction instead — the refresher applies it after Portkey, models.dev
/// and LiteLLM (and before the user's own Settings overrides), so it can fix
/// a public price that is wrong. Builds that predate the flag ignore the
/// unknown key and keep treating the entry as a gap filler.
public enum AstroQorePricingTransformer {
    /// Both layers one document produces. `supplement` holds every entry,
    /// corrections included, exactly as older builds cached it; `overrides`
    /// holds only the corrections, already resolved against the public
    /// catalogs, and is `nil` when the document marks none.
    public struct Layers: Equatable, Sendable {
        public let supplement: PricingDataSet
        public let overrides: PricingDataSet?

        public init(supplement: PricingDataSet, overrides: PricingDataSet?) {
            self.supplement = supplement
            self.overrides = overrides
        }
    }

    struct Document: Decodable {
        let schemaVersion: Int
        let models: [Model]

        private enum CodingKeys: String, CodingKey { case schemaVersion, models }

        /// An entry for a provider family this build does not know is
        /// skipped, not fatal: the supplement grows families before every
        /// installed build has them, and one such entry used to reject the
        /// whole document for everyone else's rates.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
            models = try c.decode([KnownFamilyModel].self, forKey: .models).compactMap(\.model)
        }
    }

    private struct KnownFamilyModel: Decodable {
        let model: Model?

        private enum CodingKeys: String, CodingKey { case provider }

        init(from decoder: Decoder) throws {
            let raw = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .provider)
            guard PricingProviderFamily(rawValue: raw) != nil else {
                model = nil
                return
            }
            model = try Model(from: decoder)
        }
    }

    struct Model: Decodable {
        let provider: PricingProviderFamily
        let model: String
        let displayLabel: String?
        let inherits: ModelReference?
        let pricing: Pricing
        /// `"override": true` in the document. Absent means a gap filler.
        let isOverride: Bool?

        private enum CodingKeys: String, CodingKey {
            case provider, model, displayLabel, inherits, pricing
            case isOverride = "override"
        }
    }

    struct ModelReference: Decodable {
        /// `nil` for a family this build does not know; the inheritance then
        /// simply finds nothing.
        let provider: PricingProviderFamily?
        let model: String

        private enum CodingKeys: String, CodingKey { case provider, model }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            provider = PricingProviderFamily(rawValue: try c.decode(String.self, forKey: .provider))
            model = try c.decode(String.self, forKey: .model)
        }
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
        transformLayers(
            data,
            updatedAt: updatedAt,
            calculationVersion: calculationVersion,
            inheritanceBase: inheritanceBase
        )?.supplement
    }

    /// Decodes the document into its gap-filling and correcting layers.
    /// `inheritanceBase` is the merge of the public catalogs, so an
    /// `inherits` reference — on either kind of entry — copies the rate card
    /// those catalogs agree on.
    public static func transformLayers(
        _ data: Data,
        updatedAt: String,
        calculationVersion: Int,
        inheritanceBase: PricingDataSet? = nil
    ) -> Layers? {
        guard let document = try? JSONDecoder().decode(Document.self, from: data),
              document.schemaVersion == 1
        else { return nil }

        var all = Tables()
        var corrections = Tables()
        for model in document.models {
            let id = model.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let price = model.pricing
            guard !id.isEmpty, valid(price.input), valid(price.output) else { continue }
            add(model, id: id, base: inheritanceBase, to: &all)
            if model.isOverride == true {
                add(model, id: id, base: inheritanceBase, to: &corrections)
            }
        }

        guard let supplement = all.dataSet(
            updatedAt: updatedAt, calculationVersion: calculationVersion
        ) else { return nil }
        return Layers(
            supplement: supplement,
            overrides: corrections.dataSet(
                updatedAt: updatedAt, calculationVersion: calculationVersion
            )
        )
    }

    private struct Tables {
        var codex: [String: PricingDataSet.CodexEntry] = [:]
        var claude: [String: PricingDataSet.ClaudeEntry] = [:]
        var gemini: [String: PricingDataSet.GeminiEntry] = [:]
        var grok: [String: PricingDataSet.GrokEntry] = [:]
        var antigravity: [String: PricingDataSet.AntigravityEntry] = [:]
        var muse: [String: PricingDataSet.MuseEntry] = [:]
        var mistral: [String: PricingDataSet.MistralEntry] = [:]
        var cognition: [String: PricingDataSet.CognitionEntry] = [:]

        func dataSet(updatedAt: String, calculationVersion: Int) -> PricingDataSet? {
            guard !codex.isEmpty || !claude.isEmpty || !gemini.isEmpty
                    || !grok.isEmpty || !antigravity.isEmpty || !muse.isEmpty
                    || !mistral.isEmpty || !cognition.isEmpty
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
                    antigravity: .init(displayName: "AntiGravity", models: antigravity),
                    muse: .init(displayName: "Meta AI", models: muse),
                    mistral: .init(displayName: "Mistral AI", models: mistral),
                    cognition: .init(displayName: "Cognition", models: cognition)
                )
            )
        }
    }

    private static func add(
        _ model: Model,
        id: String,
        base: PricingDataSet?,
        to tables: inout Tables
    ) {
        let price = model.pricing
        let fastMultiplier = multiplier(base: price, fast: price.fast)
        switch model.provider {
        case .codex:
            if let inherited = inheritedCodex(model.inherits, from: base) {
                tables.codex[id] = copy(inherited, displayLabel: model.displayLabel)
                return
            }
            tables.codex[id] = .init(
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
            if let inherited = inheritedClaude(model.inherits, from: base) {
                tables.claude[id] = inherited
                return
            }
            tables.claude[id] = .init(
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
            if let inherited = inheritedGemini(model.inherits, from: base) {
                tables.gemini[id] = copy(inherited, displayLabel: model.displayLabel)
                return
            }
            tables.gemini[id] = .init(
                input: perToken(price.input), output: perToken(price.output),
                cacheRead: price.cacheRead.map(perToken),
                thresholdTokens: price.threshold?.tokens,
                inputAboveThreshold: price.threshold.map { perToken($0.input) },
                outputAboveThreshold: price.threshold.map { perToken($0.output) },
                cacheReadAboveThreshold: price.threshold?.cacheRead.map(perToken),
                displayLabel: model.displayLabel
            )
        case .grok:
            if let inherited = inheritedGrok(model.inherits, from: base) {
                tables.grok[id] = copy(inherited, displayLabel: model.displayLabel)
                return
            }
            tables.grok[id] = .init(
                input: perToken(price.input), output: perToken(price.output),
                cacheRead: price.cacheRead.map(perToken),
                thresholdTokens: price.threshold?.tokens,
                inputAboveThreshold: price.threshold.map { perToken($0.input) },
                outputAboveThreshold: price.threshold.map { perToken($0.output) },
                cacheReadAboveThreshold: price.threshold?.cacheRead.map(perToken),
                displayLabel: model.displayLabel
            )
        case .cognition:
            if let inherited = inheritedCognition(model.inherits, from: base) {
                tables.cognition[id] = copy(inherited, displayLabel: model.displayLabel)
                return
            }
            tables.cognition[id] = .init(
                input: perToken(price.input), output: perToken(price.output),
                cacheRead: price.cacheRead.map(perToken),
                thresholdTokens: price.threshold?.tokens,
                inputAboveThreshold: price.threshold.map { perToken($0.input) },
                outputAboveThreshold: price.threshold.map { perToken($0.output) },
                cacheReadAboveThreshold: price.threshold?.cacheRead.map(perToken),
                displayLabel: model.displayLabel
            )
        case .mistral:
            if let inherited = inheritedMistral(model.inherits, from: base) {
                tables.mistral[id] = copy(inherited, displayLabel: model.displayLabel)
                return
            }
            tables.mistral[id] = .init(
                input: perToken(price.input), output: perToken(price.output),
                cacheRead: price.cacheRead.map(perToken),
                thresholdTokens: price.threshold?.tokens,
                inputAboveThreshold: price.threshold.map { perToken($0.input) },
                outputAboveThreshold: price.threshold.map { perToken($0.output) },
                cacheReadAboveThreshold: price.threshold?.cacheRead.map(perToken),
                displayLabel: model.displayLabel
            )
        case .muse:
            if let inherited = inheritedMuse(model.inherits, from: base) {
                tables.muse[id] = copy(inherited, displayLabel: model.displayLabel)
                return
            }
            tables.muse[id] = .init(
                input: perToken(price.input), output: perToken(price.output),
                cacheRead: price.cacheRead.map(perToken),
                thresholdTokens: price.threshold?.tokens,
                inputAboveThreshold: price.threshold.map { perToken($0.input) },
                outputAboveThreshold: price.threshold.map { perToken($0.output) },
                cacheReadAboveThreshold: price.threshold?.cacheRead.map(perToken),
                displayLabel: model.displayLabel
            )
        case .antigravity:
            if let inherited = inheritedAntigravity(model.inherits, from: base) {
                tables.antigravity[id] = .init(
                    input: inherited.input, output: inherited.output,
                    cacheRead: inherited.cacheRead,
                    cacheCreation: inherited.cacheCreation,
                    displayLabel: model.displayLabel ?? inherited.displayLabel
                )
                return
            }
            tables.antigravity[id] = .init(
                input: perToken(price.input), output: perToken(price.output),
                cacheRead: perToken(price.cacheRead ?? 0),
                cacheCreation: perToken(price.cacheWrite ?? 0),
                displayLabel: model.displayLabel
            )
        }
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

    private static func inheritedMuse(
        _ reference: ModelReference?, from base: PricingDataSet?
    ) -> PricingDataSet.MuseEntry? {
        guard reference?.provider == .muse, let id = reference?.model.lowercased() else { return nil }
        return base?.providers.muse.models[id]
    }

    private static func inheritedMistral(
        _ reference: ModelReference?, from base: PricingDataSet?
    ) -> PricingDataSet.MistralEntry? {
        guard reference?.provider == .mistral, let id = reference?.model.lowercased() else { return nil }
        return base?.providers.mistral.models[id]
    }

    private static func inheritedCognition(
        _ reference: ModelReference?, from base: PricingDataSet?
    ) -> PricingDataSet.CognitionEntry? {
        guard reference?.provider == .cognition, let id = reference?.model.lowercased() else { return nil }
        return base?.providers.cognition.models[id]
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
