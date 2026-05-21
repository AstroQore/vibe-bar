import XCTest
@testable import VibeBarCore

/// Locks the Gemini pricing table + normalization + cost calculation.
/// Rates here come from ai.google.dev/gemini-api/docs/pricing on the
/// `pricingDataUpdatedAt` date — refresh both when the upstream rates
/// change.
final class GeminiPricingTests: XCTestCase {
    // MARK: - normalizeGeminiModel

    func testNormalizeStripsDatedSuffixes() {
        XCTAssertEqual(CostUsagePricing.normalizeGeminiModel("gemini-2.5-pro-preview-04-09"), "gemini-2.5-pro")
        XCTAssertEqual(CostUsagePricing.normalizeGeminiModel("gemini-2.5-flash-001"), "gemini-2.5-flash")
        XCTAssertEqual(CostUsagePricing.normalizeGeminiModel("models/gemini-2.5-pro"), "gemini-2.5-pro")
    }

    func testNormalizeFallsBackToFamily() {
        XCTAssertEqual(CostUsagePricing.normalizeGeminiModel("gemini-2.5-pro-exp"), "gemini-2.5-pro")
        XCTAssertEqual(CostUsagePricing.normalizeGeminiModel("gemini-3-pro-beta"), "gemini-3-pro")
    }

    func testNormalizeReturnsRawWhenUnknown() {
        XCTAssertEqual(CostUsagePricing.normalizeGeminiModel("totally-unknown-model"), "totally-unknown-model")
    }

    // MARK: - geminiCostUSD

    func testFlatRateModelBelowThreshold() throws {
        // gemini-2.5-flash: input $0.30/M, output $2.50/M (flat).
        let cost = try XCTUnwrap(CostUsagePricing.geminiCostUSD(
            model: "gemini-2.5-flash",
            inputTokens: 1_000_000,
            cacheReadInputTokens: 0,
            outputTokens: 1_000_000
        ))
        XCTAssertEqual(cost, 0.30 + 2.50, accuracy: 1e-6)
    }

    func testTieredProAboveThreshold() throws {
        // gemini-2.5-pro: input $1.25/M ≤200K, $2.50/M >200K.
        // 300K input → 200K * 1.25 + 100K * 2.50 = 0.25 + 0.25 = 0.50
        let cost = try XCTUnwrap(CostUsagePricing.geminiCostUSD(
            model: "gemini-2.5-pro",
            inputTokens: 300_000,
            cacheReadInputTokens: 0,
            outputTokens: 0
        ))
        XCTAssertEqual(cost, 0.50, accuracy: 1e-6)
    }

    func testCacheReadIsCheaperThanFreshInput() throws {
        // Cache reads should never cost more than fresh input.
        let fresh = try XCTUnwrap(CostUsagePricing.geminiCostUSD(
            model: "gemini-2.5-pro",
            inputTokens: 100_000,
            cacheReadInputTokens: 0,
            outputTokens: 0
        ))
        let cached = try XCTUnwrap(CostUsagePricing.geminiCostUSD(
            model: "gemini-2.5-pro",
            inputTokens: 100_000,
            cacheReadInputTokens: 100_000,
            outputTokens: 0
        ))
        XCTAssertLessThan(cached, fresh,
                          "Cached-input call must be cheaper than the same call with no cache.")
    }

    func testUnknownModelReturnsNil() {
        XCTAssertNil(CostUsagePricing.geminiCostUSD(
            model: "gemini-99-foo",
            inputTokens: 100, cacheReadInputTokens: 0, outputTokens: 100
        ))
    }
}
