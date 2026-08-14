import Foundation

/// Converts Portkey's provider-specific pricing maps into Vibe Bar's runtime
/// table. Portkey publishes prices as cents per token, so every rate is
/// divided by 100 before it reaches `PricingDataSet`.
public enum PortkeyPricingTransformer {
    struct RawEntry: Decodable {
        let pricingConfig: PricingConfig?

        enum CodingKeys: String, CodingKey {
            case pricingConfig = "pricing_config"
        }
    }

    struct PricingConfig: Decodable {
        let payAsYouGo: PayAsYouGo?

        enum CodingKeys: String, CodingKey {
            case payAsYouGo = "pay_as_you_go"
        }
    }

    struct PayAsYouGo: Decodable {
        let requestToken: Price?
        let responseToken: Price?
        let cacheReadInputToken: Price?
        let cacheWriteInputToken: Price?

        enum CodingKeys: String, CodingKey {
            case requestToken = "request_token"
            case responseToken = "response_token"
            case cacheReadInputToken = "cache_read_input_token"
            case cacheWriteInputToken = "cache_write_input_token"
        }
    }

    struct Price: Decodable {
        let price: Double
    }

    private struct Rates {
        let input: Double
        let output: Double
        let cacheRead: Double?
        let cacheWrite: Double?
    }

    /// Each payload is the raw `pricing.json` for one Portkey provider.
    public static func transform(
        _ payloads: [PricingProviderFamily: Data],
        updatedAt: String,
        calculationVersion: Int
    ) -> PricingDataSet? {
        var codex: [String: PricingDataSet.CodexEntry] = [:]
        var claude: [String: PricingDataSet.ClaudeEntry] = [:]
        var gemini: [String: PricingDataSet.GeminiEntry] = [:]
        var grok: [String: PricingDataSet.GrokEntry] = [:]

        for (family, data) in payloads {
            guard let raw = try? JSONDecoder().decode([String: RawEntry].self, from: data) else {
                continue
            }
            for (rawID, entry) in raw {
                guard let rates = rates(entry) else { continue }
                let id = rawID.lowercased()
                switch family {
                case .codex where isCodexModel(id):
                    codex[id] = .init(
                        input: rates.input,
                        output: rates.output,
                        cacheRead: rates.cacheRead,
                        cacheCreation: rates.cacheWrite
                    )
                case .claude where id.hasPrefix("claude-"):
                    claude[id] = .init(
                        input: rates.input,
                        output: rates.output,
                        cacheCreation: rates.cacheWrite ?? rates.input * 1.25,
                        cacheRead: rates.cacheRead ?? rates.input * 0.1
                    )
                case .gemini where id.hasPrefix("gemini-"):
                    gemini[id] = .init(
                        input: rates.input,
                        output: rates.output,
                        cacheRead: rates.cacheRead
                    )
                case .grok where id.hasPrefix("grok-"):
                    grok[id] = .init(
                        input: rates.input,
                        output: rates.output,
                        cacheRead: rates.cacheRead
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

    private static func rates(_ entry: RawEntry) -> Rates? {
        guard let payg = entry.pricingConfig?.payAsYouGo,
              let input = payg.requestToken?.price,
              let output = payg.responseToken?.price,
              input >= 0, output >= 0
        else { return nil }
        return Rates(
            input: input / 100,
            output: output / 100,
            cacheRead: payg.cacheReadInputToken.map { $0.price / 100 },
            cacheWrite: payg.cacheWriteInputToken.map { $0.price / 100 }
        )
    }

    /// Portkey's OpenAI catalog mostly uses the public `gpt-*` names, but
    /// Codex also emits this first-party internal usage category directly in
    /// session logs. Keep the allow-list narrow so embeddings, image, audio,
    /// and moderation SKUs from the same provider file do not leak into the
    /// Codex model picker.
    private static func isCodexModel(_ id: String) -> Bool {
        id.hasPrefix("gpt-") || id == "codex-auto-review"
    }
}
