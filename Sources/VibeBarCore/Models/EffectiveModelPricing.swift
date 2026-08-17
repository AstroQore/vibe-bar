import Foundation

/// One row from the fully resolved runtime price table. Rates are converted to
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

    public var id: String { "\(provider.rawValue):\(model)" }
    public var normalizedKey: String {
        "\(provider.rawValue):\(model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }
    public var tool: ToolType { provider.tool }
    public var companyName: String { tool.vendorName }
    public var subProviderName: String { tool.productName }

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
        fastMultiplier: Double? = nil
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
                fastMultiplier: entry.fastMultiplier
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
        return rows.filter {
            !$0.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
