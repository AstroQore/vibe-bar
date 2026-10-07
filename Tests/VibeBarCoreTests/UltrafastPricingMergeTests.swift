import XCTest
@testable import VibeBarCore

final class UltrafastPricingMergeTests: XCTestCase {
    func testModelsDevBaseOnlyUltrafastKeepsBundledLongContextPricing() throws {
        let floor = try XCTUnwrap(PricingResolver.loadBundled())
        let source = try XCTUnwrap(ModelsDevPricingTransformer.transform(
            Data(#"""
            {"openai":{"models":{"gpt-6-astra":{
              "cost":{"input":11,"output":55},
              "experimental":{"modes":{"ultrafast":{"cost":{"input":61,"output":310}}}}
            }}}}
            """#.utf8), updatedAt: "test", calculationVersion: floor.calculationVersion
        ))
        let partial = try XCTUnwrap(source.providers.codex.models["gpt-6-astra"])
        XCTAssertNil(partial.ultrafast?.thresholdTokens)

        let merged = PricingDataSetMerger.overlay(source, onto: floor, updatedAt: "test")
        let entry = try XCTUnwrap(merged.providers.codex.models["gpt-6-astra"])
        let rates = try XCTUnwrap(entry.ultrafast)
        XCTAssertEqual(rates.input, 61e-6, accuracy: 1e-12)
        XCTAssertEqual(rates.output, 310e-6, accuracy: 1e-12)
        XCTAssertEqual(rates.thresholdTokens, 272_000)
        XCTAssertEqual(rates.cacheRead, 6e-6)
        XCTAssertEqual(rates.cacheCreation, 75e-6)
        XCTAssertEqual(rates.inputAboveThreshold, 120e-6)
        XCTAssertEqual(rates.outputAboveThreshold, 450e-6)
        XCTAssertEqual(rates.cacheReadAboveThreshold, 12e-6)
        XCTAssertEqual(rates.cacheCreationAboveThreshold, 150e-6)
        XCTAssertEqual(try cost(entry, input: 272_000), 13.092, accuracy: 1e-9)
        XCTAssertEqual(try cost(entry, input: 272_001), 24.18012, accuracy: 1e-9)

        // The same merged card is cached and projected through MCP pricing.
        let restored = try JSONDecoder().decode(PricingDataSet.self, from: JSONEncoder().encode(merged))
        XCTAssertEqual(restored, merged)
        XCTAssertEqual(try cost(XCTUnwrap(restored.providers.codex.models["gpt-6-astra"]),
                                input: 272_001), 24.18012, accuracy: 1e-9)
        let row = try XCTUnwrap(restored.effectiveModelPrices.first { $0.model == "gpt-6-astra" })
        let dto = MCPPricingRowDTO(row: row)
        let dtoRestored = try JSONDecoder().decode(MCPPricingRowDTO.self, from: JSONEncoder().encode(dto))
        XCTAssertEqual(dtoRestored, dto)
        let projected = try XCTUnwrap(dtoRestored.ultrafast)
        XCTAssertEqual(projected.inputPerMillion, 61, accuracy: 1e-9)
        XCTAssertEqual(projected.thresholdTokens, 272_000)
        XCTAssertEqual(projected.cacheReadPerMillion, 6)
        XCTAssertEqual(projected.cacheWriteAboveThresholdPerMillion, 150)
    }

    func testMatchingUltrafastThresholdFillsOnlyMissingFields() throws {
        let high = PricingDataSet.CodexRates(
            input: 61e-6, output: 310e-6, cacheRead: 7e-6,
            thresholdTokens: 272_000, inputAboveThreshold: 125e-6,
            cacheCreationAboveThreshold: 155e-6
        )
        let merged = PricingDataSetMerger.overlay(
            dataSet(ultrafast: high), onto: PricingHardcoded.fallback, updatedAt: "test"
        )
        let entry = try XCTUnwrap(merged.providers.codex.models["gpt-6-astra"])
        let rates = try XCTUnwrap(entry.ultrafast)
        XCTAssertEqual(rates, .init(
            input: 61e-6, output: 310e-6, cacheRead: 7e-6, cacheCreation: 75e-6,
            thresholdTokens: 272_000, inputAboveThreshold: 125e-6,
            outputAboveThreshold: 450e-6, cacheReadAboveThreshold: 12e-6,
            cacheCreationAboveThreshold: 155e-6
        ))
        XCTAssertEqual(try cost(entry, input: 272_001), 24.940125, accuracy: 1e-9)
    }

    func testDifferentUltrafastThresholdDoesNotInheritLowerTierRates() throws {
        let high = PricingDataSet.CodexRates(
            input: 61e-6, output: 310e-6, thresholdTokens: 300_000,
            inputAboveThreshold: 125e-6
        )
        let merged = PricingDataSetMerger.overlay(
            dataSet(ultrafast: high), onto: PricingHardcoded.fallback, updatedAt: "test"
        )
        let entry = try XCTUnwrap(merged.providers.codex.models["gpt-6-astra"])
        let rates = try XCTUnwrap(entry.ultrafast)
        XCTAssertEqual(rates.thresholdTokens, 300_000)
        XCTAssertEqual(rates.inputAboveThreshold, 125e-6)
        XCTAssertEqual(rates.cacheRead, 6e-6)
        XCTAssertEqual(rates.cacheCreation, 75e-6)
        XCTAssertNil(rates.outputAboveThreshold)
        XCTAssertNil(rates.cacheReadAboveThreshold)
        XCTAssertNil(rates.cacheCreationAboveThreshold)
        XCTAssertEqual(try cost(entry, input: 300_000), 14.8, accuracy: 1e-9)
        XCTAssertNil(CostUsagePricing.codexCostUSD(
            pricing: entry, inputTokens: 300_001, cachedInputTokens: 120_000,
            outputTokens: 10_000, serviceTier: "ultrafast"
        ))
    }

    func testUltrafastCardIsInheritedOnlyForTheSameModel() throws {
        let merged = PricingDataSetMerger.overlay(
            dataSet(ultrafast: nil), onto: PricingHardcoded.fallback, updatedAt: "test"
        )
        XCTAssertEqual(merged.providers.codex.models["gpt-6-astra"]?.ultrafast,
                       PricingHardcoded.fallback.providers.codex.models["gpt-6-astra"]?.ultrafast)
        let context = CostPricingContext(dataSet: merged)
        XCTAssertNil(context.codexEntry(for: "gpt-6.1-sol", serviceTier: "ultrafast"))
        XCTAssertNil(context.codexEntry(for: "gpt-6-astra-2026-09-03", serviceTier: "ultrafast"))

        let independent = PricingDataSetMerger.overlay(
            dataSet(ultrafast: .init(input: 61e-6, output: 310e-6), model: "gpt-future"),
            onto: merged, updatedAt: "test"
        )
        let rates = try XCTUnwrap(independent.providers.codex.models["gpt-future"]?.ultrafast)
        XCTAssertNil(rates.cacheRead)
        XCTAssertNil(rates.thresholdTokens)
        XCTAssertNil(rates.inputAboveThreshold)
    }

    func testUserOverridesCanRemoveOrReplaceUltrafastWithoutFallthrough() throws {
        let floor = PricingHardcoded.fallback
        let removed = ModelPricingOverrideApplier.apply([
            .init(provider: .codex, model: "gpt-6-astra", inputPerMillion: 11, outputPerMillion: 55)
        ], to: floor, updatedAt: "test")
        XCTAssertNil(removed.providers.codex.models["gpt-6-astra"]?.ultrafast)

        let replacement = PricingDataSet.CodexRates(input: 61e-6, output: 310e-6)
        let replaced = ModelPricingOverrideApplier.apply([
            .init(provider: .codex, model: "gpt-6-astra", inputPerMillion: 11,
                  outputPerMillion: 55, ultrafast: .init(rates: replacement))
        ], to: floor, updatedAt: "test")
        XCTAssertEqual(replaced.providers.codex.models["gpt-6-astra"]?.ultrafast, replacement)

        let direct = PricingDataSetMerger.overlay(
            dataSet(ultrafast: replacement), onto: floor, updatedAt: "test", fillMissingFromBase: false
        )
        XCTAssertEqual(direct.providers.codex.models["gpt-6-astra"]?.ultrafast, replacement)
    }

    private func cost(_ entry: PricingDataSet.CodexEntry, input: Int) throws -> Double {
        try XCTUnwrap(CostUsagePricing.codexCostUSD(
            pricing: entry, inputTokens: input, cachedInputTokens: 120_000,
            outputTokens: 10_000, serviceTier: "ultrafast"
        ))
    }

    private func dataSet(ultrafast: PricingDataSet.CodexRates?, model: String = "gpt-6-astra") -> PricingDataSet {
        .init(schemaVersion: PricingDataSet.currentSchemaVersion, updatedAt: "test", calculationVersion: 5,
              providers: .init(codex: .init(models: [model: .init(input: 11e-6, output: 55e-6,
                                                               cacheRead: nil, ultrafast: ultrafast)]),
                               claude: .init(models: [:]), gemini: .init(models: [:]),
                               grok: .init(models: [:]), antigravity: .init(models: [:])))
    }
}
