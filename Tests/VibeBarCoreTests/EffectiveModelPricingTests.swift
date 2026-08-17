import XCTest
@testable import VibeBarCore

final class EffectiveModelPricingTests: XCTestCase {
    func testFlattensResolvedRatesIntoPerMillionRows() throws {
        let data = PricingDataSet(
            schemaVersion: PricingDataSet.currentSchemaVersion,
            updatedAt: "test",
            calculationVersion: 1,
            providers: .init(
                codex: .init(models: [
                    "gpt-test": .init(
                        input: 2e-6,
                        output: 8e-6,
                        cacheRead: 0.2e-6,
                        cacheCreation: 2.5e-6,
                        thresholdTokens: 200_000,
                        inputAboveThreshold: 4e-6,
                        outputAboveThreshold: 12e-6,
                        cacheReadAboveThreshold: 0.4e-6,
                        cacheCreationAboveThreshold: 5e-6,
                        fastMultiplier: 2,
                        displayLabel: "GPT Test"
                    )
                ]),
                claude: .init(models: [:]),
                gemini: .init(models: [:]),
                grok: .init(models: [:]),
                antigravity: .init(models: [:])
            )
        )

        let row = try XCTUnwrap(data.effectiveModelPrices.first)
        XCTAssertEqual(row.id, "codex:gpt-test")
        XCTAssertEqual(row.normalizedKey, "codex:gpt-test")
        XCTAssertEqual(row.companyName, "OpenAI")
        XCTAssertEqual(row.subProviderName, "ChatGPT Agentic")
        XCTAssertEqual(row.inputPerMillion, 2, accuracy: 0.000_001)
        XCTAssertEqual(row.outputPerMillion, 8, accuracy: 0.000_001)
        XCTAssertEqual(row.cacheReadPerMillion ?? -1, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(row.cacheWritePerMillion ?? -1, 2.5, accuracy: 0.000_001)
        XCTAssertEqual(row.inputAboveThresholdPerMillion ?? -1, 4, accuracy: 0.000_001)
        XCTAssertEqual(row.fastMultiplier, 2)
    }

    func testEffectiveRowsFollowCanonicalSubProviderOrder() {
        let rows = PricingHardcoded.fallback.effectiveModelPrices
        XCTAssertFalse(rows.isEmpty)
        let providers = rows.map(\.provider)
        XCTAssertEqual(providers, providers.sorted {
            PricingProviderFamily.allCases.firstIndex(of: $0)!
                < PricingProviderFamily.allCases.firstIndex(of: $1)!
        })
    }
}
