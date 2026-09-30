import XCTest
@testable import VibeBarCore

final class EffectivePricingServiceTierTests: XCTestCase {
    func testAstraHasOneModelWithThreePublishedServiceTiers() throws {
        let dataSet = try XCTUnwrap(PricingResolver.loadBundled())
        let rows = dataSet.effectiveModelPrices.filter { $0.model == "gpt-6-astra" }
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.id, "codex:gpt-6-astra")
        let tiers = row.serviceTiers
        XCTAssertEqual(tiers.map(\.id), [.standard, .fast, .ultrafast])
        let expected: [[Double]] = [
            [10, 50, 1, 12.5, 20, 75, 2, 25],
            [20, 100, 2, 25, 40, 150, 4, 50],
            [60, 300, 6, 75, 120, 450, 12, 150]
        ]
        for (tier, values) in zip(tiers, expected) {
            let rates = tier.rates
            XCTAssertEqual(rates.thresholdTokens, 272_000)
            let actual: [Double?] = [
                rates.inputPerMillion, rates.outputPerMillion,
                rates.cacheReadPerMillion, rates.cacheWritePerMillion,
                rates.inputAboveThresholdPerMillion, rates.outputAboveThresholdPerMillion,
                rates.cacheReadAboveThresholdPerMillion, rates.cacheWriteAboveThresholdPerMillion
            ]
            for (price, value) in zip(actual, values) {
                XCTAssertEqual(try XCTUnwrap(price), value, accuracy: 1e-9)
            }
        }

        // Long-context price projections agree with the existing calculator,
        // including its treatment of cached input and output for the whole request.
        let entry = try XCTUnwrap(dataSet.providers.codex.models["gpt-6-astra"])
        for tier in tiers {
            let rates = tier.rates
            let projectedCost = (152_001 * (try XCTUnwrap(rates.inputAboveThresholdPerMillion))
                                 + 120_000 * (try XCTUnwrap(rates.cacheReadAboveThresholdPerMillion))
                                 + 10_000 * (try XCTUnwrap(rates.outputAboveThresholdPerMillion))) / 1_000_000
            let actualCost = try XCTUnwrap(CostUsagePricing.codexCostUSD(
                pricing: entry, inputTokens: 272_001, cachedInputTokens: 120_000,
                outputTokens: 10_000, serviceTier: tier.id.rawValue
            ))
            XCTAssertEqual(projectedCost, actualCost, accuracy: 1e-9)
        }
    }

    func testModelsWithoutPublishedTiersDoNotGainPremiumRows() throws {
        let sol = try XCTUnwrap(PricingHardcoded.fallback.effectiveModelPrices.first {
            $0.model == "gpt-6.1-sol"
        })
        XCTAssertEqual(sol.serviceTiers.map(\.id), [.standard, .fast])
        XCTAssertNil(sol.ultrafast)
        let source = try XCTUnwrap(ModelsDevPricingTransformer.transform(
            Data(#"{"openai":{"models":{"gpt-fixture":{"cost":{"input":10,"output":50}}}}}"#.utf8),
            updatedAt: "test", calculationVersion: 5
        ))
        XCTAssertEqual(source.effectiveModelPrices.count, 1)
        let row = try XCTUnwrap(source.effectiveModelPrices.first)
        XCTAssertEqual(row.model, "gpt-fixture")
        XCTAssertEqual(row.serviceTiers.map(\.id), [.standard])
        XCTAssertNil(row.serviceTiers.first?.rates.cacheReadPerMillion)
    }

    func testOverridesRetainExplicitTierAndUnknownPriceSemantics() throws {
        let removed = ModelPricingOverrideApplier.apply([
            .init(provider: .codex, model: "gpt-6-astra", inputPerMillion: 10, outputPerMillion: 50)
        ], to: PricingHardcoded.fallback, updatedAt: "test")
        let row = try XCTUnwrap(removed.effectiveModelPrices.first { $0.model == "gpt-6-astra" })
        XCTAssertEqual(row.serviceTiers.map(\.id), [.standard])

        let partial = ModelPricingOverrideApplier.apply([
            .init(provider: .codex, model: "gpt-6-astra", inputPerMillion: 10,
                  outputPerMillion: 50, thresholdTokens: 272_000, fastMultiplier: 1,
                  ultrafast: .init(rates: .init(input: 60e-6, output: 300e-6)))
        ], to: PricingHardcoded.fallback, updatedAt: "test")
        let partialRow = try XCTUnwrap(partial.effectiveModelPrices.first { $0.model == "gpt-6-astra" })
        XCTAssertEqual(partialRow.serviceTiers.map(\.id), [.standard, .fast, .ultrafast])
        let fast = try XCTUnwrap(partialRow.serviceTiers.first { $0.id == .fast })
        XCTAssertEqual(fast.rates.inputPerMillion, partialRow.inputPerMillion)
        XCTAssertNil(fast.rates.cacheReadPerMillion)
        XCTAssertNil(fast.rates.inputAboveThresholdPerMillion)
        let ultra = try XCTUnwrap(partialRow.serviceTiers.first { $0.id == .ultrafast })
        XCTAssertNil(partialRow.ultrafast?.thresholdTokens)
        XCTAssertEqual(ultra.rates.thresholdTokens, 272_000)
        XCTAssertNil(ultra.rates.cacheReadPerMillion)
        XCTAssertNil(ultra.rates.inputAboveThresholdPerMillion)
        XCTAssertNil(ultra.rates.outputAboveThresholdPerMillion)
        XCTAssertNil(CostUsagePricing.codexCostUSD(
            pricing: try XCTUnwrap(partial.providers.codex.models["gpt-6-astra"]),
            inputTokens: 272_001, cachedInputTokens: 0, outputTokens: 10_000,
            serviceTier: "ultrafast"
        ))
    }

    func testMCPPricingKeepsOneModelWithNestedUltrafastAndFastMultiplier() throws {
        let rows = PricingHardcoded.fallback.effectiveModelPrices
        let dto = MCPPricingDTO(generatedAt: Date(timeIntervalSince1970: 1_790_784_000),
                                rows: rows.map(MCPPricingRowDTO.init))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(dto)) as? [String: Any])
        let wireRows = try XCTUnwrap(encoded["rows"] as? [[String: Any]])
        XCTAssertEqual(wireRows.count, rows.count)
        let astra = wireRows.filter { $0["model"] as? String == "gpt-6-astra" }
        XCTAssertEqual(astra.count, 1)
        let model = try XCTUnwrap(astra.first)
        XCTAssertEqual(model["fastMultiplier"] as? Double, 2)
        let ultra = try XCTUnwrap(model["ultrafast"] as? [String: Any])
        XCTAssertEqual(ultra["inputPerMillion"] as? Double, 60)
        XCTAssertNil(model["serviceTiers"])
        XCTAssertFalse(wireRows.contains { ($0["model"] as? String)?.hasSuffix(".ultrafast") == true })
    }

    func testUsageAggregatesAllThreeServiceTiersUnderOneModel() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("ServiceTierModel")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_790_784_000)
        let events = ["standard", "fast", "ultrafast"].enumerated().map { index, tier in
            UsageLedgerFixtures.priced(UsageLedgerFixtures.event(
                date: now.addingTimeInterval(Double(index)), model: "gpt-6-astra",
                messageId: "message-\(index)", serviceTier: tier
            ))
        }
        try await ledger.ingest(UsageLedgerFixtures.batch(events: events))
        let filter = UsageLedgerFixtures.wideFilter(around: now)
        let models = try await ledger.modelStats(filter)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.model, "gpt-6-astra")
        XCTAssertEqual(models.first?.requests, 3)
        let available = try await ledger.availableModels()
        XCTAssertEqual(available, ["gpt-6-astra"])
        let requests = try await ledger.requestPage(filter, pageSize: 10)
        XCTAssertEqual(Set(requests.rows.compactMap(\.serviceTier)), ["standard", "fast", "ultrafast"])
    }
}
