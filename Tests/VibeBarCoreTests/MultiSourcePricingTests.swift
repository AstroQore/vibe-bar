import XCTest
@testable import VibeBarCore

final class MultiSourcePricingTests: XCTestCase {
    func testLiveCatalogRefreshWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["VIBEBAR_RUN_LIVE_PRICING_TEST"] == "1" else {
            throw XCTSkip("Set VIBEBAR_RUN_LIVE_PRICING_TEST=1 for the live catalog smoke test.")
        }
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("VibeBarLivePricing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }

        let result = await MultiSourcePricingRefresher.refreshAll(
            homeDirectory: home.path,
            now: Date(timeIntervalSince1970: 1_786_681_800)
        )
        for source in PricingSourceID.allCases {
            let status = try XCTUnwrap(result.status.sources.first { $0.source == source })
            XCTAssertNotEqual(status.result, .failed, "\(source.rawValue): \(status.detail ?? "")")
            XCTAssertGreaterThan(status.modelCount, 0, source.rawValue)
        }

        let merged = PricingResolver.resolve(homeDirectory: home.path)
        let sol = try XCTUnwrap(merged.providers.codex.models["gpt-5.6-sol"])
        let daybreak = try XCTUnwrap(
            merged.providers.codex.models["gpt-daybreak-blue-latest"]
        )
        XCTAssertEqual(daybreak.input, sol.input)
        XCTAssertEqual(daybreak.output, sol.output)
        XCTAssertEqual(daybreak.cacheRead, sol.cacheRead)
        XCTAssertEqual(daybreak.thresholdTokens, sol.thresholdTokens)
        XCTAssertEqual(daybreak.fastMultiplier, sol.fastMultiplier)
        XCTAssertEqual(sol.thresholdTokens, 272_000)
        XCTAssertEqual(sol.fastMultiplier, 2)

        let composer = try XCTUnwrap(
            merged.providers.grok.models["grok-composer-2.5-fast"]
        )
        XCTAssertEqual(composer.input, 3e-6, accuracy: 1e-12)
        XCTAssertEqual(composer.output, 15e-6, accuracy: 1e-12)
    }

    func testModelsDevCarriesLongContextAndFastPricing() throws {
        let data = Data(#"""
        {
          "openai": {
            "models": {
              "gpt-5.6-sol": {
                "cost": {
                  "input": 5, "output": 30,
                  "cache_read": 0.5, "cache_write": 6.25,
                  "tiers": [{
                    "tier": {"size": 272000},
                    "input": 10, "output": 45,
                    "cache_read": 1, "cache_write": 12.5
                  }]
                },
                "experimental": {
                  "modes": {"fast": {"cost": {"input": 10, "output": 60}}}
                }
              }
            }
          }
        }
        """#.utf8)

        let set = try XCTUnwrap(ModelsDevPricingTransformer.transform(
            data, updatedAt: "2026-08-14", calculationVersion: 1
        ))
        let model = try XCTUnwrap(set.providers.codex.models["gpt-5.6-sol"])
        XCTAssertEqual(model.input, 5e-6, accuracy: 1e-12)
        XCTAssertEqual(model.cacheCreation ?? 0, 6.25e-6, accuracy: 1e-12)
        XCTAssertEqual(model.thresholdTokens, 272_000)
        XCTAssertEqual(model.outputAboveThreshold ?? 0, 45e-6, accuracy: 1e-12)
        XCTAssertEqual(model.fastMultiplier, 2)
    }

    func testPortkeyConvertsCentsPerTokenToDollarsPerToken() throws {
        let data = Data(#"""
        {
          "grok-4.6": {
            "pricing_config": {
              "pay_as_you_go": {
                "request_token": {"price": 0.0002},
                "response_token": {"price": 0.0006},
                "cache_read_input_token": {"price": 0.00005}
              }
            }
          }
        }
        """#.utf8)

        let set = try XCTUnwrap(PortkeyPricingTransformer.transform(
            [.grok: data], updatedAt: "2026-08-14", calculationVersion: 1
        ))
        let model = try XCTUnwrap(set.providers.grok.models["grok-4.6"])
        XCTAssertEqual(model.input, 2e-6, accuracy: 1e-12)
        XCTAssertEqual(model.output, 6e-6, accuracy: 1e-12)
        XCTAssertEqual(model.cacheRead ?? 0, 0.5e-6, accuracy: 1e-12)
    }

    func testAstroQoreSupplementCarriesRequestedModels() throws {
        let data = Data(#"""
        {
          "schemaVersion": 1,
          "models": [
            {
              "provider": "codex",
              "model": "gpt-daybreak-blue-latest",
              "displayLabel": "GPT Daybreak Blue",
              "inherits": {"provider": "codex", "model": "gpt-5.6-sol"},
              "pricing": {
                "input": 5, "output": 30, "cacheRead": 0.5,
                "cacheWrite": 6.25,
                "threshold": {
                  "tokens": 272000, "input": 10, "output": 45,
                  "cacheRead": 1, "cacheWrite": 12.5
                },
                "fast": {"input": 10, "output": 60}
              }
            },
            {
              "provider": "grok",
              "model": "grok-composer-2.5-fast",
              "displayLabel": "Composer 2.5 Fast",
              "pricing": {"input": 3, "output": 15}
            }
          ]
        }
        """#.utf8)

        let inheritanceBase = PricingDataSet(
            schemaVersion: 1,
            updatedAt: "2026-08-14",
            calculationVersion: 1,
            providers: .init(
                codex: .init(models: [
                    "gpt-5.6-sol": .init(
                        input: 7e-6, output: 70e-6, cacheRead: 0.7e-6,
                        thresholdTokens: 300_000,
                        inputAboveThreshold: 14e-6,
                        outputAboveThreshold: 105e-6,
                        fastMultiplier: 2
                    )
                ]),
                claude: .init(models: [:]), gemini: .init(models: [:]),
                grok: .init(models: [:]), antigravity: .init(models: [:])
            )
        )
        let set = try XCTUnwrap(AstroQorePricingTransformer.transform(
            data,
            updatedAt: "2026-08-14",
            calculationVersion: 1,
            inheritanceBase: inheritanceBase
        ))
        let daybreak = try XCTUnwrap(
            set.providers.codex.models["gpt-daybreak-blue-latest"]
        )
        XCTAssertEqual(daybreak.input, 7e-6, accuracy: 1e-12)
        XCTAssertEqual(daybreak.output, 70e-6, accuracy: 1e-12)
        XCTAssertEqual(daybreak.thresholdTokens, 300_000)
        XCTAssertEqual(daybreak.fastMultiplier, 2)

        let composer = try XCTUnwrap(
            set.providers.grok.models["grok-composer-2.5-fast"]
        )
        XCTAssertEqual(composer.input, 3e-6, accuracy: 1e-12)
        XCTAssertEqual(composer.output, 15e-6, accuracy: 1e-12)
        XCTAssertNil(composer.cacheRead)
    }

    func testSourceOrderAndLocalOverrideUseFirstMatchPriority() throws {
        let base = PricingDataSet.empty(updatedAt: "2026-08-14", calculationVersion: 1)
        let astro = codexSet(input: 1)
        let portkey = codexSet(input: 2)
        let modelsDev = codexSet(input: 3)
        let liteLLM = codexSet(input: 4)

        var merged = PricingDataSetMerger.overlay(astro, onto: base, updatedAt: "2026-08-14")
        merged = PricingDataSetMerger.overlay(portkey, onto: merged, updatedAt: "2026-08-14")
        merged = PricingDataSetMerger.overlay(modelsDev, onto: merged, updatedAt: "2026-08-14")
        merged = PricingDataSetMerger.overlay(liteLLM, onto: merged, updatedAt: "2026-08-14")
        XCTAssertEqual(merged.providers.codex.models["gpt-conflict"]?.input, 4e-6)

        let lowWithMetadata = PricingDataSet(
            schemaVersion: 1,
            updatedAt: "2026-08-14",
            calculationVersion: 1,
            providers: .init(
                codex: .init(models: ["gpt-conflict": .init(
                    input: 1e-6, output: 10e-6, cacheRead: 0.1e-6,
                    thresholdTokens: 272_000,
                    inputAboveThreshold: 2e-6,
                    outputAboveThreshold: 20e-6,
                    fastMultiplier: 2
                )]),
                claude: .init(models: [:]), gemini: .init(models: [:]),
                grok: .init(models: [:]), antigravity: .init(models: [:])
            )
        )
        let fieldMerged = PricingDataSetMerger.overlay(
            liteLLM, onto: lowWithMetadata, updatedAt: "2026-08-14"
        ).providers.codex.models["gpt-conflict"]
        XCTAssertEqual(fieldMerged?.input, 4e-6)
        XCTAssertEqual(fieldMerged?.cacheRead, 0.1e-6)
        XCTAssertEqual(fieldMerged?.thresholdTokens, 272_000)
        XCTAssertEqual(fieldMerged?.fastMultiplier, 2)

        merged = ModelPricingOverrideApplier.apply(
            [ModelPricingOverride(
                provider: .codex,
                model: "GPT-CONFLICT",
                inputPerMillion: 9,
                outputPerMillion: 90
            )],
            to: merged,
            updatedAt: "2026-08-14"
        )
        XCTAssertEqual(merged.providers.codex.models["gpt-conflict"]?.input, 9e-6)
        XCTAssertNil(merged.providers.codex.models["gpt-conflict"]?.cacheRead)
        XCTAssertNil(merged.providers.codex.models["gpt-conflict"]?.thresholdTokens)
    }

    private func codexSet(input: Double) -> PricingDataSet {
        PricingDataSet(
            schemaVersion: PricingDataSet.currentSchemaVersion,
            updatedAt: "2026-08-14",
            calculationVersion: 1,
            providers: .init(
                codex: .init(models: [
                    "gpt-conflict": .init(
                        input: input / 1_000_000,
                        output: input * 10 / 1_000_000,
                        cacheRead: nil
                    )
                ]),
                claude: .init(models: [:]),
                gemini: .init(models: [:]),
                grok: .init(models: [:]),
                antigravity: .init(models: [:])
            )
        )
    }
}
