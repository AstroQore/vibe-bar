import XCTest
@testable import VibeBarCore

/// Validates the LiteLLM → `PricingDataSet` overlay that lets
/// `PricingRefresher` follow upstream pricing automatically.
final class LiteLLMPricingTransformerTests: XCTestCase {
    private func transform(_ json: String) -> PricingDataSet? {
        LiteLLMPricingTransformer.transform(
            Data(json.utf8),
            base: PricingHardcoded.fallback,
            updatedAt: "2026-06-08"
        )
    }

    func testRoutesEachFamilyToItsProviderWithRatesAndFastTier() throws {
        let set = try XCTUnwrap(transform("""
        {
          "claude-opus-4-8": {
            "input_cost_per_token": 5e-6, "output_cost_per_token": 2.5e-5,
            "cache_creation_input_token_cost": 6.25e-6, "cache_read_input_token_cost": 5e-7,
            "provider_specific_entry": {"fast": 2.0}
          },
          "gpt-5.5": {"input_cost_per_token": 5e-6, "output_cost_per_token": 3e-5, "cache_read_input_token_cost": 5e-7},
          "gemini-2.5-pro": {
            "input_cost_per_token": 1.25e-6, "output_cost_per_token": 1e-5, "cache_read_input_token_cost": 3.1e-7,
            "input_cost_per_token_above_200k_tokens": 2.5e-6, "output_cost_per_token_above_200k_tokens": 1.5e-5,
            "cache_read_input_token_cost_above_200k_tokens": 6.25e-7
          },
          "xai/grok-4.3": {"input_cost_per_token": 1.25e-6, "output_cost_per_token": 2.5e-6, "cache_read_input_token_cost": 3.1e-7}
        }
        """))

        let opus = try XCTUnwrap(set.providers.claude.models["claude-opus-4-8"])
        XCTAssertEqual(opus.input, 5e-6, accuracy: 1e-12)
        XCTAssertEqual(opus.fastMultiplier, 2.0)

        // gpt-5.5 carries no `fast` in LiteLLM → filled from the override table.
        XCTAssertEqual(set.providers.codex.models["gpt-5.5"]?.fastMultiplier, 2.5)

        let gemini = try XCTUnwrap(set.providers.gemini.models["gemini-2.5-pro"])
        XCTAssertEqual(gemini.thresholdTokens, 200_000)
        XCTAssertEqual(gemini.inputAboveThreshold ?? 0, 2.5e-6, accuracy: 1e-12)

        // xAI grok is stored under the bare key Vibe Bar normalizes to.
        XCTAssertEqual(set.providers.grok.models["grok-4.3"]?.input ?? 0, 1.25e-6, accuracy: 1e-12)
        XCTAssertNil(set.providers.grok.models["xai/grok-4.3"])
    }

    func testFillsClaudeCacheRatesFromInputWhenLiteLLMOmitsThem() throws {
        let set = try XCTUnwrap(transform("""
        {"claude-fictional-1": {"input_cost_per_token": 1e-5, "output_cost_per_token": 5e-5}}
        """))
        let entry = try XCTUnwrap(set.providers.claude.models["claude-fictional-1"])
        XCTAssertEqual(entry.cacheCreation, 1.25e-5, accuracy: 1e-15) // input × 1.25
        XCTAssertEqual(entry.cacheRead, 1e-6, accuracy: 1e-15)        // input × 0.10
    }

    func testDropsVendorPrefixedAliases() throws {
        let set = try XCTUnwrap(transform("""
        {
          "vertex_ai/claude-opus-4-8": {"input_cost_per_token": 9e-6, "output_cost_per_token": 9e-5},
          "openrouter/anthropic/claude-opus-4-8": {"input_cost_per_token": 9e-6, "output_cost_per_token": 9e-5},
          "claude-opus-4-8": {"input_cost_per_token": 5e-6, "output_cost_per_token": 2.5e-5}
        }
        """))
        // Only the bare key is kept; the $9 aliases never landed.
        XCTAssertEqual(set.providers.claude.models["claude-opus-4-8"]?.input ?? 0, 5e-6, accuracy: 1e-12)
        XCTAssertNil(set.providers.claude.models["vertex_ai/claude-opus-4-8"])
        XCTAssertNil(set.providers.claude.models["openrouter/anthropic/claude-opus-4-8"])
    }

    func testPreservesBaseModelsLiteLLMDoesNotPrice() throws {
        // gpt-5.5 keeps loaded > 0; gemini-3-pro is priced null upstream and
        // absent here, so the curated base entry must survive the overlay.
        let set = try XCTUnwrap(transform("""
        {
          "gpt-5.5": {"input_cost_per_token": 5e-6, "output_cost_per_token": 3e-5},
          "gemini-3-pro": {"input_cost_per_token": null, "output_cost_per_token": null}
        }
        """))
        XCTAssertEqual(set.providers.gemini.models["gemini-3-pro"]?.input ?? 0, 2e-6, accuracy: 1e-12)
        // AntiGravity shadow rates are never in LiteLLM; they must persist.
        XCTAssertNotNil(set.providers.antigravity.models["antigravity-default"])
    }

    func testAddsNewUpstreamModelWithoutEditingBundledTable() throws {
        // The whole point of the overlay: a model nobody hand-added shows up.
        let set = try XCTUnwrap(transform("""
        {"gpt-9-hypothetical": {"input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6, "cache_read_input_token_cost": 1e-7}}
        """))
        XCTAssertNil(PricingHardcoded.fallback.providers.codex.models["gpt-9-hypothetical"])
        XCTAssertEqual(set.providers.codex.models["gpt-9-hypothetical"]?.input ?? 0, 1e-6, accuracy: 1e-12)
        XCTAssertEqual(set.providers.codex.models["gpt-9-hypothetical"]?.cacheRead ?? 0, 1e-7, accuracy: 1e-13)
    }

    func testRejectsPayloadsThatAreNotLiteLLMMaps() {
        XCTAssertNil(transform("not json at all"))
        XCTAssertNil(transform(#"{"hello":"world"}"#))      // values aren't model objects
        XCTAssertNil(transform(#"{"sample_spec":{}}"#))     // no priceable models → unusable
    }

    func testCarriesSchemaAndCalculationVersionForTheLoader() throws {
        let set = try XCTUnwrap(transform("""
        {"gpt-5.5": {"input_cost_per_token": 5e-6, "output_cost_per_token": 3e-5}}
        """))
        XCTAssertEqual(set.schemaVersion, PricingDataSet.currentSchemaVersion)
        XCTAssertEqual(set.calculationVersion, PricingHardcoded.fallback.calculationVersion)
        XCTAssertEqual(set.updatedAt, "2026-06-08")
    }
}
