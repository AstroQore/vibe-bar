import Foundation

public enum ModelsDevPricingTransformer {
    struct RawProvider: Decodable {
        let models: [String: RawModel]
    }

    struct RawModel: Decodable {
        let cost: RawCost?
        let experimental: RawExperimental?
    }

    struct RawExperimental: Decodable {
        let modes: [String: RawMode]?
    }

    struct RawMode: Decodable {
        let cost: RawRates?
    }

    struct RawCost: Decodable {
        let input: Double
        let output: Double
        let cacheRead: Double?
        let cacheWrite: Double?
        let contextOver200k: RawRates?
        let tiers: [RawTier]?

        enum CodingKeys: String, CodingKey {
            case input, output, tiers
            case cacheRead = "cache_read"
            case cacheWrite = "cache_write"
            case contextOver200k = "context_over_200k"
        }
    }

    struct RawRates: Decodable {
        let input: Double
        let output: Double
        let cacheRead: Double?
        let cacheWrite: Double?

        enum CodingKeys: String, CodingKey {
            case input, output
            case cacheRead = "cache_read"
            case cacheWrite = "cache_write"
        }
    }

    struct RawTier: Decodable {
        let tier: TierSpec
        let input: Double
        let output: Double
        let cacheRead: Double?
        let cacheWrite: Double?

        struct TierSpec: Decodable {
            let size: Int
        }

        enum CodingKeys: String, CodingKey {
            case tier, input, output
            case cacheRead = "cache_read"
            case cacheWrite = "cache_write"
        }
    }

    public static func transform(
        _ data: Data,
        updatedAt: String,
        calculationVersion: Int
    ) -> PricingDataSet? {
        guard let providers = decodeProviders(data)
        else { return nil }

        var codex: [String: PricingDataSet.CodexEntry] = [:]
        var claude: [String: PricingDataSet.ClaudeEntry] = [:]
        var gemini: [String: PricingDataSet.GeminiEntry] = [:]
        var grok: [String: PricingDataSet.GrokEntry] = [:]

        for (providerID, provider) in providers {
            for (rawID, model) in provider.models {
                guard let cost = model.cost, cost.input >= 0, cost.output >= 0 else { continue }
                let id = rawID.lowercased()
                let tier = modelTier(cost)
                let fastMultiplier = multiplier(
                    base: cost,
                    fast: model.experimental?.modes?["fast"]?.cost
                )
                switch providerID.lowercased() {
                case "openai":
                    codex[id] = .init(
                        input: perToken(cost.input),
                        output: perToken(cost.output),
                        cacheRead: cost.cacheRead.map(perToken),
                        cacheCreation: cost.cacheWrite.map(perToken),
                        thresholdTokens: tier?.tokens,
                        inputAboveThreshold: tier.map { perToken($0.input) },
                        outputAboveThreshold: tier.map { perToken($0.output) },
                        cacheReadAboveThreshold: tier?.cacheRead.map(perToken),
                        cacheCreationAboveThreshold: tier?.cacheWrite.map(perToken),
                        fastMultiplier: fastMultiplier
                    )
                case "anthropic" where id.hasPrefix("claude-"):
                    claude[id] = .init(
                        input: perToken(cost.input),
                        output: perToken(cost.output),
                        cacheCreation: perToken(cost.cacheWrite ?? cost.input * 1.25),
                        cacheRead: perToken(cost.cacheRead ?? cost.input * 0.1),
                        thresholdTokens: tier?.tokens,
                        inputAboveThreshold: tier.map { perToken($0.input) },
                        outputAboveThreshold: tier.map { perToken($0.output) },
                        cacheCreationAboveThreshold: tier?.cacheWrite.map(perToken),
                        cacheReadAboveThreshold: tier?.cacheRead.map(perToken),
                        fastMultiplier: fastMultiplier
                    )
                case "google" where id.hasPrefix("gemini-"):
                    gemini[id] = .init(
                        input: perToken(cost.input),
                        output: perToken(cost.output),
                        cacheRead: cost.cacheRead.map(perToken),
                        thresholdTokens: tier?.tokens,
                        inputAboveThreshold: tier.map { perToken($0.input) },
                        outputAboveThreshold: tier.map { perToken($0.output) },
                        cacheReadAboveThreshold: tier?.cacheRead.map(perToken)
                    )
                case "xai" where id.hasPrefix("grok-"):
                    grok[id] = .init(
                        input: perToken(cost.input),
                        output: perToken(cost.output),
                        cacheRead: cost.cacheRead.map(perToken),
                        thresholdTokens: tier?.tokens,
                        inputAboveThreshold: tier.map { perToken($0.input) },
                        outputAboveThreshold: tier.map { perToken($0.output) },
                        cacheReadAboveThreshold: tier?.cacheRead.map(perToken)
                    )
                default:
                    continue
                }
            }
        }

        guard !codex.isEmpty || !claude.isEmpty || !gemini.isEmpty || !grok.isEmpty else {
            return nil
        }
        return PricingDataSet(
            schemaVersion: PricingDataSet.currentSchemaVersion,
            updatedAt: updatedAt,
            calculationVersion: calculationVersion,
            providers: .init(
                codex: .init(displayName: "OpenAI", models: codex),
                claude: .init(displayName: "Anthropic", models: claude),
                gemini: .init(displayName: "Google", models: gemini),
                grok: .init(displayName: "xAI", models: grok),
                antigravity: .init(displayName: "AntiGravity", models: [:])
            )
        )
    }

    private struct Tier {
        let tokens: Int
        let input: Double
        let output: Double
        let cacheRead: Double?
        let cacheWrite: Double?
    }

    private static func modelTier(_ cost: RawCost) -> Tier? {
        if let first = cost.tiers?.min(by: { $0.tier.size < $1.tier.size }) {
            return Tier(
                tokens: first.tier.size,
                input: first.input,
                output: first.output,
                cacheRead: first.cacheRead,
                cacheWrite: first.cacheWrite
            )
        }
        if let legacy = cost.contextOver200k {
            return Tier(
                tokens: 200_000,
                input: legacy.input,
                output: legacy.output,
                cacheRead: legacy.cacheRead,
                cacheWrite: legacy.cacheWrite
            )
        }
        return nil
    }

    private static func multiplier(base: RawCost, fast: RawRates?) -> Double? {
        guard let fast else { return nil }
        let ratio = base.output > 0 ? fast.output / base.output : fast.input / base.input
        return ratio.isFinite && ratio > 0 ? ratio : nil
    }

    private static func perToken(_ perMillion: Double) -> Double {
        perMillion / 1_000_000
    }

    private static func decodeProviders(_ data: Data) -> [String: RawProvider]? {
        if let direct = decodeCatalogJSON(data) { return direct }
        guard let json = embeddedJSONParseString(in: data),
              let decoded = json.data(using: .utf8),
              let wrapped = decodeCatalogJSON(decoded)
        else { return nil }
        return wrapped
    }

    private static func decodeCatalogJSON(_ data: Data) -> [String: RawProvider]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let catalog = (root["providers"] as? [String: Any]) ?? root
        let wanted = ["openai", "anthropic", "google", "xai"]
        let filtered = Dictionary(uniqueKeysWithValues: wanted.compactMap { key in
            catalog[key].map { (key, $0) }
        })
        guard !filtered.isEmpty,
              let filteredData = try? JSONSerialization.data(withJSONObject: filtered)
        else { return nil }
        return try? JSONDecoder().decode([String: RawProvider].self, from: filteredData)
    }

    /// The official `@opencode-ai/models` package ships a generated fallback
    /// as `JSON.parse("…")`. Decode the JavaScript string literal with
    /// `JSONDecoder` instead of evaluating JavaScript.
    private static func embeddedJSONParseString(in data: Data) -> String? {
        guard let source = String(data: data, encoding: .utf8),
              let marker = source.range(of: "JSON.parse(")
        else { return nil }
        let tail = source[marker.upperBound...]
        guard let opening = tail.firstIndex(of: "\"") else { return nil }

        var index = tail.index(after: opening)
        var escaped = false
        while index < tail.endIndex {
            let character = tail[index]
            if character == "\"" && !escaped {
                let literal = String(tail[opening...index])
                guard let literalData = literal.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(String.self, from: literalData)
            }
            if character == "\\" {
                escaped.toggle()
            } else {
                escaped = false
            }
            index = tail.index(after: index)
        }
        return nil
    }
}
