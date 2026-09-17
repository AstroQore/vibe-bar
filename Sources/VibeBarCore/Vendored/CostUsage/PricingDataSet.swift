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
    /// Hard cap on a cached / bundled `PricingDataSet` so a corrupt
    /// file can't blow up the loader. The multi-source cache is filtered to
    /// the provider families Vibe Bar scans; 2 MB leaves headroom for catalog
    /// growth. Raw downloads are capped separately by each refresher.
    public static let maxBytes = 2 * 1024 * 1024

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
        public let muse: ProviderTable<MuseEntry>

        public init(
            codex: ProviderTable<CodexEntry>,
            claude: ProviderTable<ClaudeEntry>,
            gemini: ProviderTable<GeminiEntry>,
            grok: ProviderTable<GrokEntry>,
            antigravity: ProviderTable<AntigravityEntry>,
            muse: ProviderTable<MuseEntry> = .init(displayName: "Meta AI", models: [:])
        ) {
            self.codex = codex
            self.claude = claude
            self.gemini = gemini
            self.grok = grok
            self.antigravity = antigravity
            self.muse = muse
        }

        private enum CodingKeys: String, CodingKey {
            case codex, claude, gemini, grok, antigravity, muse
        }

        /// `muse` arrived after caches and remote tables were already on disk
        /// without it. A missing table is an empty one rather than a decoding
        /// failure — which would otherwise throw every cached source away and
        /// rebuild the pricing cache from the bundled table alone.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            codex = try c.decode(ProviderTable<CodexEntry>.self, forKey: .codex)
            claude = try c.decode(ProviderTable<ClaudeEntry>.self, forKey: .claude)
            gemini = try c.decode(ProviderTable<GeminiEntry>.self, forKey: .gemini)
            grok = try c.decode(ProviderTable<GrokEntry>.self, forKey: .grok)
            antigravity = try c.decode(ProviderTable<AntigravityEntry>.self, forKey: .antigravity)
            muse = try c.decodeIfPresent(ProviderTable<MuseEntry>.self, forKey: .muse)
                ?? .init(displayName: "Meta AI", models: [:])
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
        public let cacheCreation: Double?
        public let thresholdTokens: Int?
        public let inputAboveThreshold: Double?
        public let outputAboveThreshold: Double?
        public let cacheReadAboveThreshold: Double?
        public let cacheCreationAboveThreshold: Double?
        /// Multiplier applied to the whole cost when the request ran on
        /// the "fast"/"priority" Codex service tier (resolved once per
        /// scan from `~/.codex/config.toml`). `nil` means no premium (×1).
        public let fastMultiplier: Double?
        public let displayLabel: String?

        public init(
            input: Double,
            output: Double,
            cacheRead: Double?,
            cacheCreation: Double? = nil,
            thresholdTokens: Int? = nil,
            inputAboveThreshold: Double? = nil,
            outputAboveThreshold: Double? = nil,
            cacheReadAboveThreshold: Double? = nil,
            cacheCreationAboveThreshold: Double? = nil,
            fastMultiplier: Double? = nil,
            displayLabel: String? = nil
        ) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheCreation = cacheCreation
            self.thresholdTokens = thresholdTokens
            self.inputAboveThreshold = inputAboveThreshold
            self.outputAboveThreshold = outputAboveThreshold
            self.cacheReadAboveThreshold = cacheReadAboveThreshold
            self.cacheCreationAboveThreshold = cacheCreationAboveThreshold
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
        public let thresholdTokens: Int?
        public let inputAboveThreshold: Double?
        public let outputAboveThreshold: Double?
        public let cacheReadAboveThreshold: Double?
        public let displayLabel: String?

        public init(
            input: Double,
            output: Double,
            cacheRead: Double?,
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

    /// Meta's Muse Spark rates have exactly Grok's shape: input, output and
    /// a cached-input rate, no cache-write charge, no fast tier, and no long-
    /// context premium today (the threshold fields stay available should one
    /// appear).
    public typealias MuseEntry = GrokEntry

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

extension PricingDataSet {
    public static func empty(updatedAt: String, calculationVersion: Int) -> PricingDataSet {
        PricingDataSet(
            schemaVersion: currentSchemaVersion,
            updatedAt: updatedAt,
            calculationVersion: calculationVersion,
            providers: Providers(
                codex: .init(displayName: "OpenAI", models: [:]),
                claude: .init(displayName: "Anthropic", models: [:]),
                gemini: .init(displayName: "Google AI", models: [:]),
                grok: .init(displayName: "SpaceXAI", models: [:]),
                antigravity: .init(displayName: "Google AI", models: [:]),
                muse: .init(displayName: "Meta AI", models: [:])
            )
        )
    }

    public var modelCount: Int {
        providers.codex.models.count
            + providers.claude.models.count
            + providers.gemini.models.count
            + providers.grok.models.count
            + providers.antigravity.models.count
            + providers.muse.models.count
    }
}
