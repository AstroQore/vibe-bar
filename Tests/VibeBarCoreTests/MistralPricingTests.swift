import XCTest
@testable import VibeBarCore

/// Mistral Vibe logs the La Plateforme id its model alias resolves to and is
/// priced at Mistral's API rates, fed by LiteLLM's `mistral/…` rows and
/// models.dev's `mistral` provider.
final class MistralPricingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PricingResolver.testOverride = PricingHardcoded.fallback
    }

    override func tearDown() {
        PricingResolver.testOverride = nil
        super.tearDown()
    }

    func testVibeCLIRatesMatchLaPlateforme() throws {
        let latest = try XCTUnwrap(CostUsagePricing.mistralCostUSD(
            model: "mistral-vibe-cli-latest", inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 1_000_000
        ))
        XCTAssertEqual(latest, 1.5 + 7.5, accuracy: 1e-9)
        let cached = try XCTUnwrap(CostUsagePricing.mistralCostUSD(
            model: "mistral/Mistral-Vibe-CLI-Latest", inputTokens: 1_000_000, cachedInputTokens: 1_000_000, outputTokens: 0
        ))
        XCTAssertEqual(cached, 0.15, accuracy: 1e-9)
        let fast = try XCTUnwrap(CostUsagePricing.mistralCostUSD(
            model: "mistral-vibe-cli-fast", inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 1_000_000
        ))
        XCTAssertEqual(fast, 0.15 + 0.6, accuracy: 1e-9)
        XCTAssertNil(CostUsagePricing.mistralCostUSD(model: "devstral-unknown", inputTokens: 1, cachedInputTokens: 0, outputTokens: 1))
        XCTAssertTrue(CostUsagePricing.canRepriceAggregate(tool: .mistralVibe, model: "mistral-vibe-cli-latest"))
        XCTAssertFalse(CostUsagePricing.canRepriceAggregate(tool: .devin, model: "swe-2-high"))
    }

    func testLiteLLMRoutesFirstPartyMistralRowsOnly() throws {
        let set = try XCTUnwrap(LiteLLMPricingTransformer.transform(
            Data("""
            {
              "mistral/mistral-vibe-cli-with-tools": {"input_cost_per_token": 1.5e-6, "output_cost_per_token": 7.5e-6, "cache_read_input_token_cost": 1.5e-7},
              "mistral/codestral-2508": {"input_cost_per_token": 3e-7, "output_cost_per_token": 9e-7},
              "openrouter/mistralai/devstral-small": {"input_cost_per_token": 9e-6, "output_cost_per_token": 9e-6},
              "mistral/nested/re-listing": {"input_cost_per_token": 9e-6, "output_cost_per_token": 9e-6}
            }
            """.utf8),
            base: PricingHardcoded.fallback,
            updatedAt: "2026-09-17"
        ))
        XCTAssertEqual(set.providers.mistral.models["mistral-vibe-cli-with-tools"]?.cacheRead ?? 0, 1.5e-7, accuracy: 1e-15)
        XCTAssertEqual(set.providers.mistral.models["codestral-2508"]?.input ?? 0, 3e-7, accuracy: 1e-15)
        XCTAssertNil(set.providers.mistral.models["mistral/codestral-2508"])
        XCTAssertFalse(set.providers.mistral.models.keys.contains { $0.contains("/") })
    }

    func testModelsDevReadsTheMistralProvider() throws {
        let set = try XCTUnwrap(ModelsDevPricingTransformer.transform(
            Data(#"""
            {
              "mistral": {"models": {"devstral-2512": {"cost": {"input": 0.4, "output": 2}}}},
              "openrouter": {"models": {"mistralai/devstral-2512": {"cost": {"input": 9, "output": 9}}}}
            }
            """#.utf8),
            updatedAt: "2026-09-17",
            calculationVersion: 1
        ))
        XCTAssertEqual(set.providers.mistral.models["devstral-2512"]?.input ?? 0, 0.4e-6, accuracy: 1e-12)
        XCTAssertEqual(set.providers.mistral.models.count, 1)
    }

    /// A cache written before the `mistral` table existed still decodes.
    func testACacheWithoutTheMistralTableDecodes() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(PricingHardcoded.fallback)
        ) as? [String: Any])
        var providers = try XCTUnwrap(object["providers"] as? [String: Any])
        providers["mistral"] = nil
        object["providers"] = providers
        let decoded = try JSONDecoder().decode(PricingDataSet.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(decoded.providers.mistral.models.isEmpty)
        XCTAssertEqual(PricingProviderFamily.mistral.tool, .mistralVibe)
    }
}

/// Devin's requests are priced by model through the same pipeline: Cognition's
/// SWE rows (LiteLLM `cognition/…`), or the family of a model Devin borrowed.
final class DevinPricingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PricingResolver.testOverride = PricingHardcoded.fallback
    }

    override func tearDown() {
        PricingResolver.testOverride = nil
        super.tearDown()
    }

    func testCognitionRowsPriceWithTheEffortSuffixDropped() throws {
        let exact = try XCTUnwrap(CostUsagePricing.devinCostUSD(
            model: "swe-1.7", inputTokens: 1_000_000, cacheTokens: 0, cacheCreationTokens: 0, outputTokens: 1_000_000
        ))
        XCTAssertEqual(exact, 0.5 + 2.5, accuracy: 1e-9)
        let suffixed = try XCTUnwrap(CostUsagePricing.devinCostUSD(
            model: "swe-1.7-high", inputTokens: 0, cacheTokens: 1_000_000, cacheCreationTokens: 0, outputTokens: 0
        ))
        XCTAssertEqual(suffixed, 0.2, accuracy: 1e-9)
        XCTAssertEqual(CostUsagePricing.normalizeCognitionModel("cognition/SWE-1.7-Lightning", models: PricingHardcoded.fallback.providers.cognition.models), "swe-1.7-lightning")
    }

    func testAModelNoPriceListKnowsStaysUnpriced() {
        XCTAssertNil(CostUsagePricing.devinCostUSD(
            model: "swe-2-high", inputTokens: 1, cacheTokens: 0, cacheCreationTokens: 0, outputTokens: 1
        ))
    }

    func testABorrowedModelPricesAtItsOwnFamily() throws {
        let fallback = PricingHardcoded.fallback
        guard let (claudeModel, claudeEntry) = fallback.providers.claude.models.first else {
            throw XCTSkip("no bundled Claude rows")
        }
        let cost = try XCTUnwrap(CostUsagePricing.devinCostUSD(
            model: claudeModel, inputTokens: 1_000_000, cacheTokens: 0, cacheCreationTokens: 0, outputTokens: 0
        ))
        XCTAssertEqual(cost, claudeEntry.input * 1_000_000, accuracy: 1e-6)
    }

    func testLiteLLMRoutesCognitionRows() throws {
        let set = try XCTUnwrap(LiteLLMPricingTransformer.transform(
            Data(#"{"cognition/swe-2": {"input_cost_per_token": 1e-6, "output_cost_per_token": 4e-6, "cache_read_input_token_cost": 1e-7}}"#.utf8),
            base: PricingHardcoded.fallback,
            updatedAt: "2026-09-17"
        ))
        XCTAssertEqual(set.providers.cognition.models["swe-2"]?.input ?? 0, 1e-6, accuracy: 1e-15)
        let priced = CostUsagePricing.devinCostUSD(
            dataSet: set, model: "swe-2-high", inputTokens: 1_000_000, cacheTokens: 0, cacheCreationTokens: 0, outputTokens: 0
        )
        XCTAssertEqual(priced ?? 0, 1.0, accuracy: 1e-9, "a newly listed SWE model prices without a code change")
        XCTAssertEqual(PricingProviderFamily.cognition.tool, .devin)
    }
}
