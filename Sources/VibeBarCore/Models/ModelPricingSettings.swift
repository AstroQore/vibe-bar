import Foundation

public enum PricingProviderFamily: String, Codable, CaseIterable, Sendable, Identifiable {
    case codex
    case claude
    case gemini
    case antigravity
    case grok
    case muse
    case mistral
    case cognition

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .codex: "OpenAI · ChatGPT Agentic"
        case .claude: "Anthropic · Claude"
        case .gemini: "Google AI · Gemini Web"
        case .grok: "SpaceXAI · Grok"
        case .antigravity: "Google AI · AntiGravity"
        case .muse: "Meta AI · Muse Code"
        case .mistral: "Mistral AI · Mistral Vibe"
        case .cognition: "Cognition · Devin"
        }
    }
}

/// A user-owned rate card that takes precedence over every remote source.
/// Values are intentionally stored in the unit shown in Settings — USD per
/// one million tokens — and converted to per-token rates only when the
/// resolver builds its runtime table.
public struct ModelPricingOverride: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var provider: PricingProviderFamily
    public var model: String
    public var inputPerMillion: Double
    public var outputPerMillion: Double
    public var cacheReadPerMillion: Double?
    public var cacheWritePerMillion: Double?
    public var thresholdTokens: Int?
    public var inputAboveThresholdPerMillion: Double?
    public var outputAboveThresholdPerMillion: Double?
    public var cacheReadAboveThresholdPerMillion: Double?
    public var cacheWriteAboveThresholdPerMillion: Double?
    public var fastMultiplier: Double?
    public var displayLabel: String?

    public init(
        id: UUID = UUID(),
        provider: PricingProviderFamily = .codex,
        model: String = "",
        inputPerMillion: Double = 0,
        outputPerMillion: Double = 0,
        cacheReadPerMillion: Double? = nil,
        cacheWritePerMillion: Double? = nil,
        thresholdTokens: Int? = nil,
        inputAboveThresholdPerMillion: Double? = nil,
        outputAboveThresholdPerMillion: Double? = nil,
        cacheReadAboveThresholdPerMillion: Double? = nil,
        cacheWriteAboveThresholdPerMillion: Double? = nil,
        fastMultiplier: Double? = nil,
        displayLabel: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.model = model
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
        self.displayLabel = displayLabel
    }

    public var normalizedModel: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public var isUsable: Bool {
        !normalizedModel.isEmpty
            && inputPerMillion >= 0
            && outputPerMillion >= 0
            && (inputPerMillion > 0 || outputPerMillion > 0)
    }
}

public enum PricingSourceID: String, Codable, CaseIterable, Sendable, Identifiable {
    case liteLLM = "litellm"
    case modelsDev = "models.dev"
    case portkey = "portkey"
    case astroQore = "astroqore"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .liteLLM: "LiteLLM"
        case .modelsDev: "models.dev"
        case .portkey: "Portkey models"
        case .astroQore: "AstroQore supplements"
        }
    }

    /// Name of the correcting layer a source can publish, which ranks above
    /// every public catalog and below local overrides. Only the AstroQore
    /// supplement has one (its `"override": true` entries).
    public var overrideLayerLabel: String? {
        switch self {
        case .astroQore: "AstroQore corrections"
        case .liteLLM, .modelsDev, .portkey: nil
        }
    }
}

public enum PricingSourceRefreshResult: String, Codable, Sendable {
    case ready
    case unchanged
    case failed
    case never
}

public struct PricingSourceStatus: Codable, Equatable, Sendable, Identifiable {
    public var source: PricingSourceID
    public var result: PricingSourceRefreshResult
    public var modelCount: Int
    public var lastAttemptAt: Date?
    public var lastSuccessAt: Date?
    public var detail: String?
    /// Models this source applies above the public catalogs (see
    /// `PricingSourceID.overrideLayerLabel`); already counted in
    /// `modelCount`. `nil` on status files written before the layer existed.
    public var overrideModelCount: Int?

    public var id: PricingSourceID { source }

    public init(
        source: PricingSourceID,
        result: PricingSourceRefreshResult = .never,
        modelCount: Int = 0,
        lastAttemptAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        detail: String? = nil,
        overrideModelCount: Int? = nil
    ) {
        self.source = source
        self.result = result
        self.modelCount = modelCount
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.detail = detail
        self.overrideModelCount = overrideModelCount
    }
}

public struct PricingRefreshStatus: Codable, Equatable, Sendable {
    public var mergedAt: Date?
    public var mergedModelCount: Int
    public var sources: [PricingSourceStatus]

    public init(
        mergedAt: Date? = nil,
        mergedModelCount: Int = 0,
        sources: [PricingSourceStatus] = PricingSourceID.allCases.map {
            PricingSourceStatus(source: $0)
        }
    ) {
        self.mergedAt = mergedAt
        self.mergedModelCount = mergedModelCount
        self.sources = sources
    }

    public static let empty = PricingRefreshStatus()
}
