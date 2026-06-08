import XCTest
@testable import VibeBarCore

final class CostUsagePricingTests: XCTestCase {
    func testCodexGPT5StraightInput() {
        // gpt-5: input $1.25/MTok, cache $0.125/MTok, output $10/MTok
        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-5",
            inputTokens: 1_000_000,
            cachedInputTokens: 0,
            outputTokens: 0
        )
        XCTAssertEqual(cost ?? -1, 1.25, accuracy: 0.001)
    }

    func testCodexGPT5MixedCacheAndOutput() {
        // 1M input (200k cached) + 500k output
        // = (800k * 1.25e-6) + (200k * 0.125e-6) + (500k * 10e-6)
        // = 1.0 + 0.025 + 5.0 = 6.025
        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-5",
            inputTokens: 1_000_000,
            cachedInputTokens: 200_000,
            outputTokens: 500_000
        )
        XCTAssertEqual(cost ?? -1, 6.025, accuracy: 0.001)
    }

    func testCodexNormalizesDatedSuffix() {
        // gpt-5-2025-01-15 should map to gpt-5
        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-5-2025-01-15",
            inputTokens: 1_000_000,
            cachedInputTokens: 0,
            outputTokens: 0
        )
        XCTAssertNotNil(cost)
    }

    func testCodexNormalizesOpenAIPrefix() {
        // openai/gpt-5 should map to gpt-5
        let cost = CostUsagePricing.codexCostUSD(
            model: "openai/gpt-5",
            inputTokens: 1_000_000,
            cachedInputTokens: 0,
            outputTokens: 0
        )
        XCTAssertNotNil(cost)
    }

    func testUnknownCodexModelReturnsNil() {
        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-bigfoot-experimental",
            inputTokens: 1_000_000,
            cachedInputTokens: 0,
            outputTokens: 0
        )
        XCTAssertNil(cost)
    }

    func testClaudeOpus4_1Cost() {
        // claude-opus-4-1: input $15/MTok, output $75/MTok
        // 1M input + 100k output = 15 + 7.5 = 22.5
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-opus-4-1",
            inputTokens: 1_000_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 100_000
        )
        XCTAssertEqual(cost ?? -1, 22.5, accuracy: 0.01)
    }

    func testClaudeSonnet4TieredPricing() {
        // claude-sonnet-4-20250514: input $3/MTok up to 200k threshold, $6/MTok above
        // 300k input → 200k * 3e-6 + 100k * 6e-6 = 0.6 + 0.6 = 1.2
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-20250514",
            inputTokens: 300_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0
        )
        XCTAssertEqual(cost ?? -1, 1.2, accuracy: 0.01)
    }

    func testClaudeSonnet46UsesStandardPricingAcrossLongContext() {
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 300_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0
        )

        XCTAssertEqual(cost ?? -1, 0.9, accuracy: 0.01)
    }

    func testClaudeOpus48CostNormalizesDatedSnapshot() {
        // Pin the in-code table so the assertion validates the data we
        // ship, not a stale ~/.vibebar/pricing_cache.json that may
        // predate this model on the developer's machine.
        PricingResolver.testOverride = PricingHardcoded.fallback
        defer { PricingResolver.testOverride = nil }

        // claude-opus-4-8: input $5/MTok, cache write $6.25/MTok,
        // cache read $0.50/MTok, output $25/MTok. The dated snapshot
        // must normalize down to the undated entry.
        // 1M input + 200k cache read + 100k cache write + 50k output
        // = 5.0 + 0.1 + 0.625 + 1.25 = 6.975
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-opus-4-8-20260515",
            inputTokens: 1_000_000,
            cacheReadInputTokens: 200_000,
            cacheCreationInputTokens: 100_000,
            outputTokens: 50_000
        )
        XCTAssertEqual(cost ?? -1, 6.975, accuracy: 0.001)
    }

    func testClaudeNormalizesAnthropicPrefix() {
        let cost = CostUsagePricing.claudeCostUSD(
            model: "anthropic.claude-opus-4-1",
            inputTokens: 1_000_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0
        )
        XCTAssertEqual(cost ?? -1, 15.0, accuracy: 0.01)
    }

    func testPricingDataDateAvailable() {
        XCTAssertFalse(CostUsagePricing.pricingDataUpdatedAt.isEmpty)
    }

    // MARK: - Fast / priority service-tier multiplier

    func testCodexFastTierMultipliesWholeCost() {
        PricingResolver.testOverride = PricingHardcoded.fallback
        defer { PricingResolver.testOverride = nil }

        // gpt-5.5: input $5/MTok, output $30/MTok, fast multiplier ×2.5.
        // 1M input + 100k output = 5.0 + 3.0 = 8.0 base; ×2.5 = 20.0 fast.
        let base = CostUsagePricing.codexCostUSD(
            model: "gpt-5.5", inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 100_000)
        let fast = CostUsagePricing.codexCostUSD(
            model: "gpt-5.5", inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 100_000, isFast: true)
        XCTAssertEqual(base ?? -1, 8.0, accuracy: 0.001)
        XCTAssertEqual(fast ?? -1, 20.0, accuracy: 0.001)
    }

    func testClaudeFastTierMultipliesWholeCost() {
        PricingResolver.testOverride = PricingHardcoded.fallback
        defer { PricingResolver.testOverride = nil }

        // base = 1M input + 100k output = 5.0 + 2.5 = 7.5.
        // opus-4-7 fast ×6 = 45.0; opus-4-8 fast ×2 = 15.0.
        let opus47 = CostUsagePricing.claudeCostUSD(
            model: "claude-opus-4-7", inputTokens: 1_000_000, cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0, outputTokens: 100_000, isFast: true)
        let opus48 = CostUsagePricing.claudeCostUSD(
            model: "claude-opus-4-8", inputTokens: 1_000_000, cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0, outputTokens: 100_000, isFast: true)
        XCTAssertEqual(opus47 ?? -1, 45.0, accuracy: 0.001)
        XCTAssertEqual(opus48 ?? -1, 15.0, accuracy: 0.001)
    }

    func testFastTierDefaultsOffSoStandardUsageIsUnchanged() {
        PricingResolver.testOverride = PricingHardcoded.fallback
        defer { PricingResolver.testOverride = nil }

        // Regression guard: the new `isFast` parameter defaults to false,
        // so every existing call site keeps standard-tier pricing.
        let opus47 = CostUsagePricing.claudeCostUSD(
            model: "claude-opus-4-7", inputTokens: 1_000_000, cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0, outputTokens: 100_000)
        XCTAssertEqual(opus47 ?? -1, 7.5, accuracy: 0.001)
    }

    func testFastTierIsNoOpForModelWithoutPublishedPremium() {
        PricingResolver.testOverride = PricingHardcoded.fallback
        defer { PricingResolver.testOverride = nil }

        // gpt-5 has no fast multiplier, so the fast flag must not change
        // its cost (multiplier resolves to ×1).
        let base = CostUsagePricing.codexCostUSD(
            model: "gpt-5", inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 100_000)
        let fast = CostUsagePricing.codexCostUSD(
            model: "gpt-5", inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 100_000, isFast: true)
        XCTAssertEqual(fast ?? -1, base ?? -2, accuracy: 0.0001)
    }
}
