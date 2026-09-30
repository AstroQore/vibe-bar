import Foundation

/// One model from the fully resolved runtime price table. Rates are converted to
/// the Settings unit (USD per one million tokens) at this boundary so the UI
/// never needs to know the stored per-token representation.
public struct EffectiveModelPricingRow: Sendable, Equatable, Identifiable {
    public let provider: PricingProviderFamily
    public let model: String
    public let displayLabel: String?
    public let inputPerMillion: Double
    public let outputPerMillion: Double
    public let cacheReadPerMillion: Double?
    public let cacheWritePerMillion: Double?
    public let thresholdTokens: Int?
    public let inputAboveThresholdPerMillion: Double?
    public let outputAboveThresholdPerMillion: Double?
    public let cacheReadAboveThresholdPerMillion: Double?
    public let cacheWriteAboveThresholdPerMillion: Double?
    public let fastMultiplier: Double?
    public let ultrafast: EffectiveModelPricingTier?

    public var id: String { "\(provider.rawValue):\(model)" }
    public var normalizedKey: String {
        "\(provider.rawValue):\(model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }
    public var tool: ToolType { provider.tool }
    public var companyName: String { tool.vendorName }
    public var subProviderName: String { tool.productName }

    /// Service tiers share this model's identity. Only explicitly supplied
    /// tier pricing adds a tier; the calculator's default Fast factor of one does not.
    public var serviceTiers: [EffectiveModelPricingServiceTier] {
        var tiers = [EffectiveModelPricingServiceTier(
            id: .standard, rates: .init(row: self, multiplier: 1)
        )]
        if let multiplier = fastMultiplier, multiplier.isFinite, multiplier > 0 {
            tiers.append(.init(id: .fast, rates: .init(row: self, multiplier: multiplier)))
        }
        if let ultrafast {
            tiers.append(.init(id: .ultrafast, rates: .init(
                ultrafast: ultrafast, fallbackThreshold: thresholdTokens
            )))
        }
        return tiers
    }

    public init(
        provider: PricingProviderFamily,
        model: String,
        displayLabel: String? = nil,
        inputPerMillion: Double,
        outputPerMillion: Double,
        cacheReadPerMillion: Double? = nil,
        cacheWritePerMillion: Double? = nil,
        thresholdTokens: Int? = nil,
        inputAboveThresholdPerMillion: Double? = nil,
        outputAboveThresholdPerMillion: Double? = nil,
        cacheReadAboveThresholdPerMillion: Double? = nil,
        cacheWriteAboveThresholdPerMillion: Double? = nil,
        fastMultiplier: Double? = nil,
        ultrafast: EffectiveModelPricingTier? = nil
    ) {
        self.provider = provider
        self.model = model
        self.displayLabel = displayLabel
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
        self.cacheWritePerMillion = cacheWritePerMillion
        self.thresholdTokens = thresholdTokens
        self.inputAboveThresholdPerMillion = inputAboveThresholdPerMillion
        self.outputAboveThresholdPerMillion = outputAboveThresholdPerMillion
        self.cacheReadAboveThresholdPerMillion = cacheReadAboveThresholdPerMillion
        self.cacheWriteAboveThresholdPerMillion = cacheWriteAboveThresholdPerMillion
        self.fastMultiplier = fastMultiplier
        self.ultrafast = ultrafast
    }
}

public struct EffectiveModelPricingServiceTier: Sendable, Equatable, Identifiable {
    public enum ID: String, Sendable, Hashable {
        case standard, fast, ultrafast
    }

    public let id: ID
    public let rates: EffectiveModelPricingTier
}

/// Independent tier rates, in the same Settings unit as the standard row.
public struct EffectiveModelPricingTier: Codable, Sendable, Equatable {
    public let inputPerMillion: Double
    public let outputPerMillion: Double
    public let cacheReadPerMillion: Double?
    public let cacheWritePerMillion: Double?
    public let thresholdTokens: Int?
    public let inputAboveThresholdPerMillion: Double?
    public let outputAboveThresholdPerMillion: Double?
    public let cacheReadAboveThresholdPerMillion: Double?
    public let cacheWriteAboveThresholdPerMillion: Double?

    public init(rates: PricingDataSet.CodexRates) {
        let million = 1_000_000.0
        inputPerMillion = rates.input * million; outputPerMillion = rates.output * million
        cacheReadPerMillion = rates.cacheRead.map { $0 * million }
        cacheWritePerMillion = rates.cacheCreation.map { $0 * million }
        thresholdTokens = rates.thresholdTokens
        inputAboveThresholdPerMillion = rates.inputAboveThreshold.map { $0 * million }
        outputAboveThresholdPerMillion = rates.outputAboveThreshold.map { $0 * million }
        cacheReadAboveThresholdPerMillion = rates.cacheReadAboveThreshold.map { $0 * million }
        cacheWriteAboveThresholdPerMillion = rates.cacheCreationAboveThreshold.map { $0 * million }
    }

    init(row: EffectiveModelPricingRow, multiplier: Double) {
        inputPerMillion = row.inputPerMillion * multiplier
        outputPerMillion = row.outputPerMillion * multiplier
        cacheReadPerMillion = row.cacheReadPerMillion.map { $0 * multiplier }
        cacheWritePerMillion = row.cacheWritePerMillion.map { $0 * multiplier }
        thresholdTokens = row.thresholdTokens
        inputAboveThresholdPerMillion = row.inputAboveThresholdPerMillion.map { $0 * multiplier }
        outputAboveThresholdPerMillion = row.outputAboveThresholdPerMillion.map { $0 * multiplier }
        cacheReadAboveThresholdPerMillion = row.cacheReadAboveThresholdPerMillion.map { $0 * multiplier }
        cacheWriteAboveThresholdPerMillion = row.cacheWriteAboveThresholdPerMillion.map { $0 * multiplier }
    }

    init(ultrafast: Self, fallbackThreshold: Int?) {
        inputPerMillion = ultrafast.inputPerMillion
        outputPerMillion = ultrafast.outputPerMillion
        cacheReadPerMillion = ultrafast.cacheReadPerMillion
        cacheWritePerMillion = ultrafast.cacheWritePerMillion
        // Match the calculator's context boundary without filling unknown
        // Ultrafast prices from the Standard card.
        thresholdTokens = ultrafast.thresholdTokens ?? fallbackThreshold
        inputAboveThresholdPerMillion = ultrafast.inputAboveThresholdPerMillion
        outputAboveThresholdPerMillion = ultrafast.outputAboveThresholdPerMillion
        cacheReadAboveThresholdPerMillion = ultrafast.cacheReadAboveThresholdPerMillion
        cacheWriteAboveThresholdPerMillion = ultrafast.cacheWriteAboveThresholdPerMillion
    }

    var perTokenRates: PricingDataSet.CodexRates {
        let million = 1_000_000.0
        return .init(input: inputPerMillion / million, output: outputPerMillion / million,
                     cacheRead: cacheReadPerMillion.map { $0 / million },
                     cacheCreation: cacheWritePerMillion.map { $0 / million }, thresholdTokens: thresholdTokens,
                     inputAboveThreshold: inputAboveThresholdPerMillion.map { $0 / million },
                     outputAboveThreshold: outputAboveThresholdPerMillion.map { $0 / million },
                     cacheReadAboveThreshold: cacheReadAboveThresholdPerMillion.map { $0 / million },
                     cacheCreationAboveThreshold: cacheWriteAboveThresholdPerMillion.map { $0 / million })
    }
}

extension PricingProviderFamily {
    public var tool: ToolType {
        switch self {
        case .codex: .codex
        case .claude: .claude
        case .gemini: .gemini
        case .grok: .grok
        case .antigravity: .antigravity
        case .muse: .muse
        case .mistral: .mistralVibe
        case .cognition: .devin
        }
    }
}

extension PricingDataSet {
    public var effectiveModelPrices: [EffectiveModelPricingRow] {
        let million = 1_000_000.0
        var rows: [EffectiveModelPricingRow] = []

        for (model, entry) in providers.codex.models.sorted(by: { $0.key < $1.key }) {
            rows.append(EffectiveModelPricingRow(
                provider: .codex,
                model: model,
                displayLabel: entry.displayLabel,
                inputPerMillion: entry.input * million,
                outputPerMillion: entry.output * million,
                cacheReadPerMillion: entry.cacheRead.map { $0 * million },
                cacheWritePerMillion: entry.cacheCreation.map { $0 * million },
                thresholdTokens: entry.thresholdTokens,
                inputAboveThresholdPerMillion: entry.inputAboveThreshold.map { $0 * million },
                outputAboveThresholdPerMillion: entry.outputAboveThreshold.map { $0 * million },
                cacheReadAboveThresholdPerMillion: entry.cacheReadAboveThreshold.map { $0 * million },
                cacheWriteAboveThresholdPerMillion: entry.cacheCreationAboveThreshold.map { $0 * million },
                fastMultiplier: entry.fastMultiplier,
                ultrafast: entry.ultrafast.map(EffectiveModelPricingTier.init)
            ))
        }
        for (model, entry) in providers.claude.models.sorted(by: { $0.key < $1.key }) {
            rows.append(EffectiveModelPricingRow(
                provider: .claude,
                model: model,
                inputPerMillion: entry.input * million,
                outputPerMillion: entry.output * million,
                cacheReadPerMillion: entry.cacheRead * million,
                cacheWritePerMillion: entry.cacheCreation * million,
                thresholdTokens: entry.thresholdTokens,
                inputAboveThresholdPerMillion: entry.inputAboveThreshold.map { $0 * million },
                outputAboveThresholdPerMillion: entry.outputAboveThreshold.map { $0 * million },
                cacheReadAboveThresholdPerMillion: entry.cacheReadAboveThreshold.map { $0 * million },
                cacheWriteAboveThresholdPerMillion: entry.cacheCreationAboveThreshold.map { $0 * million },
                fastMultiplier: entry.fastMultiplier
            ))
        }
        for (model, entry) in providers.gemini.models.sorted(by: { $0.key < $1.key }) {
            rows.append(EffectiveModelPricingRow(
                provider: .gemini,
                model: model,
                displayLabel: entry.displayLabel,
                inputPerMillion: entry.input * million,
                outputPerMillion: entry.output * million,
                cacheReadPerMillion: entry.cacheRead.map { $0 * million },
                thresholdTokens: entry.thresholdTokens,
                inputAboveThresholdPerMillion: entry.inputAboveThreshold.map { $0 * million },
                outputAboveThresholdPerMillion: entry.outputAboveThreshold.map { $0 * million },
                cacheReadAboveThresholdPerMillion: entry.cacheReadAboveThreshold.map { $0 * million }
            ))
        }
        for (model, entry) in providers.antigravity.models.sorted(by: { $0.key < $1.key }) {
            rows.append(EffectiveModelPricingRow(
                provider: .antigravity,
                model: model,
                displayLabel: entry.displayLabel,
                inputPerMillion: entry.input * million,
                outputPerMillion: entry.output * million,
                cacheReadPerMillion: entry.cacheRead * million,
                cacheWritePerMillion: entry.cacheCreation * million
            ))
        }
        for (model, entry) in providers.grok.models.sorted(by: { $0.key < $1.key }) {
            rows.append(EffectiveModelPricingRow(
                provider: .grok,
                model: model,
                displayLabel: entry.displayLabel,
                inputPerMillion: entry.input * million,
                outputPerMillion: entry.output * million,
                cacheReadPerMillion: entry.cacheRead.map { $0 * million },
                thresholdTokens: entry.thresholdTokens,
                inputAboveThresholdPerMillion: entry.inputAboveThreshold.map { $0 * million },
                outputAboveThresholdPerMillion: entry.outputAboveThreshold.map { $0 * million },
                cacheReadAboveThresholdPerMillion: entry.cacheReadAboveThreshold.map { $0 * million }
            ))
        }
        for (model, entry) in providers.muse.models.sorted(by: { $0.key < $1.key }) {
            rows.append(EffectiveModelPricingRow(
                provider: .muse,
                model: model,
                displayLabel: entry.displayLabel,
                inputPerMillion: entry.input * million,
                outputPerMillion: entry.output * million,
                cacheReadPerMillion: entry.cacheRead.map { $0 * million },
                thresholdTokens: entry.thresholdTokens,
                inputAboveThresholdPerMillion: entry.inputAboveThreshold.map { $0 * million },
                outputAboveThresholdPerMillion: entry.outputAboveThreshold.map { $0 * million },
                cacheReadAboveThresholdPerMillion: entry.cacheReadAboveThreshold.map { $0 * million }
            ))
        }
        for (model, entry) in providers.mistral.models.sorted(by: { $0.key < $1.key }) {
            rows.append(EffectiveModelPricingRow(
                provider: .mistral,
                model: model,
                displayLabel: entry.displayLabel,
                inputPerMillion: entry.input * million,
                outputPerMillion: entry.output * million,
                cacheReadPerMillion: entry.cacheRead.map { $0 * million },
                thresholdTokens: entry.thresholdTokens,
                inputAboveThresholdPerMillion: entry.inputAboveThreshold.map { $0 * million },
                outputAboveThresholdPerMillion: entry.outputAboveThreshold.map { $0 * million },
                cacheReadAboveThresholdPerMillion: entry.cacheReadAboveThreshold.map { $0 * million }
            ))
        }
        for (model, entry) in providers.cognition.models.sorted(by: { $0.key < $1.key }) {
            rows.append(EffectiveModelPricingRow(
                provider: .cognition,
                model: model,
                displayLabel: entry.displayLabel,
                inputPerMillion: entry.input * million,
                outputPerMillion: entry.output * million,
                cacheReadPerMillion: entry.cacheRead.map { $0 * million },
                thresholdTokens: entry.thresholdTokens,
                inputAboveThresholdPerMillion: entry.inputAboveThreshold.map { $0 * million },
                outputAboveThresholdPerMillion: entry.outputAboveThreshold.map { $0 * million },
                cacheReadAboveThresholdPerMillion: entry.cacheReadAboveThreshold.map { $0 * million }
            ))
        }
        return rows.filter {
            !$0.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
