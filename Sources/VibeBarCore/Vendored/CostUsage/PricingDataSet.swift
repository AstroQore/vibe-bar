import Foundation

/// Codable shape of the bundled / fetched `pricing.json`.
///
/// The schema version gates "is this file safe to load with this
/// build of the app"? When the loader sees a newer version it falls
/// back to the bundled copy (or the in-code fallback when the bundle
/// resource is missing — e.g. inside a test target).
///
/// Every per-model entry uses a separate struct because the provider
/// pricing shapes diverge (tiered Gemini / Claude rates, Anthropic
/// cache-creation rate, Grok / Codex flat-rate). Single-rate code
/// would either lose fidelity or force every model to model the union
/// of every other provider's quirks.
public struct PricingDataSet: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    /// Hard cap so a corrupt remote file can't blow up the loader.
    /// 64 KB is ~150× the current bundled JSON's size.
    public static let maxBytes = 64 * 1024

    public let schemaVersion: Int
    public let updatedAt: String
    public let calculationVersion: Int
    public let providers: Providers

    public init(
        schemaVersion: Int,
        updatedAt: String,
        calculationVersion: Int,
        providers: Providers
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.calculationVersion = calculationVersion
        self.providers = providers
    }

    public struct Providers: Codable, Sendable, Equatable {
        public let codex: ProviderTable<CodexEntry>
        public let claude: ProviderTable<ClaudeEntry>
        public let gemini: ProviderTable<GeminiEntry>
        public let grok: ProviderTable<GrokEntry>
        public let antigravity: ProviderTable<AntigravityEntry>

        public init(
            codex: ProviderTable<CodexEntry>,
            claude: ProviderTable<ClaudeEntry>,
            gemini: ProviderTable<GeminiEntry>,
            grok: ProviderTable<GrokEntry>,
            antigravity: ProviderTable<AntigravityEntry>
        ) {
            self.codex = codex
            self.claude = claude
            self.gemini = gemini
            self.grok = grok
            self.antigravity = antigravity
        }
    }

    public struct ProviderTable<Entry: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
        public let displayName: String?
        public let models: [String: Entry]

        public init(displayName: String? = nil, models: [String: Entry]) {
            self.displayName = displayName
            self.models = models
        }
    }

    public struct CodexEntry: Codable, Sendable, Equatable {
        public let input: Double
        public let output: Double
        public let cacheRead: Double?
        /// Multiplier applied to the whole cost when the request ran on
        /// the "fast"/"priority" Codex service tier (resolved once per
        /// scan from `~/.codex/config.toml`). `nil` means no premium (×1).
        public let fastMultiplier: Double?
        public let displayLabel: String?

        public init(input: Double, output: Double, cacheRead: Double?, fastMultiplier: Double? = nil, displayLabel: String? = nil) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.fastMultiplier = fastMultiplier
            self.displayLabel = displayLabel
        }
    }

    public struct ClaudeEntry: Codable, Sendable, Equatable {
        public let input: Double
        public let output: Double
        public let cacheCreation: Double
        public let cacheRead: Double
        public let thresholdTokens: Int?
        public let inputAboveThreshold: Double?
        public let outputAboveThreshold: Double?
        public let cacheCreationAboveThreshold: Double?
        public let cacheReadAboveThreshold: Double?
        /// Multiplier applied to the whole cost when the assistant
        /// message was billed on the "fast"/"priority" tier
        /// (`message.usage.speed == "fast"`). `nil` means no premium (×1).
        public let fastMultiplier: Double?

        public init(
            input: Double, output: Double,
            cacheCreation: Double, cacheRead: Double,
            thresholdTokens: Int? = nil,
            inputAboveThreshold: Double? = nil,
            outputAboveThreshold: Double? = nil,
            cacheCreationAboveThreshold: Double? = nil,
            cacheReadAboveThreshold: Double? = nil,
            fastMultiplier: Double? = nil
        ) {
            self.input = input
            self.output = output
            self.cacheCreation = cacheCreation
            self.cacheRead = cacheRead
            self.thresholdTokens = thresholdTokens
            self.inputAboveThreshold = inputAboveThreshold
            self.outputAboveThreshold = outputAboveThreshold
            self.cacheCreationAboveThreshold = cacheCreationAboveThreshold
            self.cacheReadAboveThreshold = cacheReadAboveThreshold
            self.fastMultiplier = fastMultiplier
        }
    }

    public struct GeminiEntry: Codable, Sendable, Equatable {
        public let input: Double
        public let output: Double
        public let cacheRead: Double?
        public let thresholdTokens: Int?
        public let inputAboveThreshold: Double?
        public let outputAboveThreshold: Double?
        public let cacheReadAboveThreshold: Double?
        public let displayLabel: String?

        public init(
            input: Double, output: Double, cacheRead: Double?,
            thresholdTokens: Int? = nil,
            inputAboveThreshold: Double? = nil,
            outputAboveThreshold: Double? = nil,
            cacheReadAboveThreshold: Double? = nil,
            displayLabel: String? = nil
        ) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.thresholdTokens = thresholdTokens
            self.inputAboveThreshold = inputAboveThreshold
            self.outputAboveThreshold = outputAboveThreshold
            self.cacheReadAboveThreshold = cacheReadAboveThreshold
            self.displayLabel = displayLabel
        }
    }

    public struct GrokEntry: Codable, Sendable, Equatable {
        public let input: Double
        public let output: Double
        public let cacheRead: Double?
        public let displayLabel: String?

        public init(input: Double, output: Double, cacheRead: Double?, displayLabel: String? = nil) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.displayLabel = displayLabel
        }
    }

    public struct AntigravityEntry: Codable, Sendable, Equatable {
        public let input: Double
        public let output: Double
        public let cacheRead: Double
        public let cacheCreation: Double
        public let displayLabel: String?

        public init(
            input: Double, output: Double,
            cacheRead: Double, cacheCreation: Double,
            displayLabel: String? = nil
        ) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheCreation = cacheCreation
            self.displayLabel = displayLabel
        }
    }
}
