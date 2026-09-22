import XCTest
@testable import VibeBarCore

/// The AstroQore supplement's `"override": true` entries: a correction layer
/// that sits above Portkey, models.dev and LiteLLM and below the user's own
/// Settings overrides. All rates here are synthetic except the published
/// supplement copy at the bottom, which mirrors vibebar-model-pricing's
/// `pricing.json`.
final class PricingOverrideLayerTests: XCTestCase {
    private final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var payloads: [String: Data] = [:]
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let url = request.url,
                  let data = StubURLProtocol.payloads[url.lastPathComponent]
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private let endpoints = MultiSourcePricingRefresher.Endpoints(
        liteLLM: URL(string: "https://pricing.example.test/litellm.json")!,
        modelsDev: URL(string: "https://pricing.example.test/models-dev.json")!,
        portkey: [.codex: URL(string: "https://pricing.example.test/portkey-openai.json")!],
        astroQore: URL(string: "https://pricing.example.test/astroqore.json")!
    )
    private let now = Date(timeIntervalSince1970: 1_790_121_600)

    override func tearDown() {
        StubURLProtocol.payloads = [:]
        PricingResolver.testOverride = nil
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeTempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarPricingOverride-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Synthetic catalogs

    /// Portkey carries the wrong standalone card for `codex-auto-review`
    /// (no cache-read rate) and a cache-read rate on `gpt-partial`.
    private let portkey = Data(#"""
    {
      "codex-auto-review": {"pricing_config": {"pay_as_you_go": {
        "request_token": {"price": 0.00025}, "response_token": {"price": 0.0015}}}},
      "gpt-partial": {"pricing_config": {"pay_as_you_go": {
        "request_token": {"price": 0.0001}, "response_token": {"price": 0.0004},
        "cache_read_input_token": {"price": 0.00005}}}},
      "gpt-conflict": {"pricing_config": {"pay_as_you_go": {
        "request_token": {"price": 0.0002}, "response_token": {"price": 0.002}}}}
    }
    """#.utf8)

    private let modelsDev = Data(#"""
    {
      "openai": {
        "models": {
          "gpt-5.6-luna": {
            "cost": {
              "input": 0.2, "output": 1.2, "cache_read": 0.02, "cache_write": 0.25,
              "tiers": [{"tier": {"size": 272000},
                         "input": 0.4, "output": 1.8, "cache_read": 0.04, "cache_write": 0.5}]
            },
            "experimental": {"modes": {"fast": {"cost": {"input": 0.4, "output": 2.4}}}}
          },
          "gpt-conflict": {"cost": {"input": 3, "output": 30}},
          "gpt-user": {"cost": {"input": 5, "output": 50}}
        }
      }
    }
    """#.utf8)

    private let liteLLM = Data(#"""
    {
      "gpt-conflict": {"input_cost_per_token": 0.000004, "output_cost_per_token": 0.00004}
    }
    """#.utf8)

    private let supplement = Data(#"""
    {
      "schemaVersion": 1,
      "models": [
        {"provider": "codex", "model": "codex-auto-review", "displayLabel": "Codex Auto Review",
         "inherits": {"provider": "codex", "model": "gpt-5.6-luna"}, "override": true,
         "pricing": {"input": 9, "output": 9}},
        {"provider": "codex", "model": "gpt-conflict", "pricing": {"input": 1, "output": 10}},
        {"provider": "codex", "model": "gpt-gap-only", "pricing": {"input": 6, "output": 60}},
        {"provider": "codex", "model": "gpt-user", "override": true, "pricing": {"input": 7, "output": 70}},
        {"provider": "codex", "model": "gpt-partial", "override": true, "pricing": {"input": 3, "output": 6}},
        {"provider": "codex", "model": "gpt-override-false", "override": false, "pricing": {"input": 8, "output": 80}}
      ]
    }
    """#.utf8)

    private var userOverrides: [ModelPricingOverride] {
        [ModelPricingOverride(
            provider: .codex, model: "gpt-user",
            inputPerMillion: 11, outputPerMillion: 110
        )]
    }

    private func serveAll() {
        StubURLProtocol.payloads = [
            "litellm.json": liteLLM,
            "models-dev.json": modelsDev,
            "portkey-openai.json": portkey,
            "astroqore.json": supplement,
        ]
    }

    private func assertCorrectedTable(
        _ merged: PricingDataSet,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let codex = merged.providers.codex.models
        let luna = try XCTUnwrap(codex["gpt-5.6-luna"], file: file, line: line)

        // An override entry beats Portkey, and `inherits` copies the public
        // Luna card in full rather than the entry's own fallback block.
        let autoReview = try XCTUnwrap(codex["codex-auto-review"], file: file, line: line)
        XCTAssertEqual(autoReview.input, luna.input, file: file, line: line)
        XCTAssertEqual(autoReview.output, luna.output, file: file, line: line)
        XCTAssertEqual(autoReview.cacheRead, luna.cacheRead, file: file, line: line)
        XCTAssertEqual(autoReview.cacheCreation, luna.cacheCreation, file: file, line: line)
        XCTAssertEqual(autoReview.thresholdTokens, 272_000, file: file, line: line)
        XCTAssertEqual(autoReview.inputAboveThreshold, luna.inputAboveThreshold, file: file, line: line)
        XCTAssertEqual(autoReview.fastMultiplier, 2, file: file, line: line)
        XCTAssertEqual(autoReview.cacheRead ?? 0, 0.02e-6, accuracy: 1e-15, file: file, line: line)
        XCTAssertEqual(autoReview.displayLabel, "Codex Auto Review", file: file, line: line)

        // A plain supplement entry still loses to the public catalogs...
        XCTAssertEqual(codex["gpt-conflict"]?.input ?? 0, 4e-6, accuracy: 1e-15, file: file, line: line)
        // ...and still fills a gap none of them covers, as does `false`.
        XCTAssertEqual(codex["gpt-gap-only"]?.input ?? 0, 6e-6, accuracy: 1e-15, file: file, line: line)
        XCTAssertEqual(codex["gpt-override-false"]?.input ?? 0, 8e-6, accuracy: 1e-15, file: file, line: line)

        // The user's Settings override beats an override entry.
        XCTAssertEqual(codex["gpt-user"]?.input ?? 0, 11e-6, accuracy: 1e-15, file: file, line: line)

        // A correction replaces the card as a whole: Portkey's cache-read
        // rate for the model being corrected does not leak through.
        let partial = try XCTUnwrap(codex["gpt-partial"], file: file, line: line)
        XCTAssertEqual(partial.input, 3e-6, accuracy: 1e-15, file: file, line: line)
        XCTAssertNil(partial.cacheRead, file: file, line: line)
    }

    // MARK: - Tests

    func testOverrideEntriesRankAbovePublicCatalogsAndBelowUserOverrides() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        serveAll()

        let result = await MultiSourcePricingRefresher.refreshAll(
            homeDirectory: home.path,
            overrides: userOverrides,
            session: makeSession(),
            endpoints: endpoints,
            now: now
        )
        for source in PricingSourceID.allCases {
            let status = try XCTUnwrap(result.status.sources.first { $0.source == source })
            XCTAssertEqual(status.result, .ready, source.rawValue)
        }
        let astro = try XCTUnwrap(result.status.sources.first { $0.source == .astroQore })
        XCTAssertEqual(astro.modelCount, 6)
        XCTAssertEqual(astro.overrideModelCount, 3)
        XCTAssertNil(result.status.sources.first { $0.source == .portkey }?.overrideModelCount)

        try assertCorrectedTable(PricingResolver.resolve(homeDirectory: home.path))

        // The supplement cache keeps every entry in the shape older builds
        // read; the corrections sit beside it.
        let sources = home.appendingPathComponent(".vibebar/pricing_sources", isDirectory: true)
        let cachedSupplement = try JSONDecoder().decode(
            PricingDataSet.self,
            from: Data(contentsOf: sources.appendingPathComponent("astroqore.json"))
        )
        XCTAssertEqual(cachedSupplement.providers.codex.models.count, 6)
        let cachedOverrides = try JSONDecoder().decode(
            PricingDataSet.self,
            from: Data(contentsOf: sources.appendingPathComponent("astroqore-overrides.json"))
        )
        XCTAssertEqual(
            Set(cachedOverrides.providers.codex.models.keys),
            ["codex-auto-review", "gpt-user", "gpt-partial"]
        )
    }

    func testOfflineRebuildAndFailedRefreshKeepTheSameOrder() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        serveAll()
        let first = await MultiSourcePricingRefresher.refreshAll(
            homeDirectory: home.path,
            overrides: userOverrides,
            session: makeSession(),
            endpoints: endpoints,
            now: now
        )
        XCTAssertTrue(first.status.sources.allSatisfy { $0.result == .ready })
        let online = PricingResolver.resolve(homeDirectory: home.path)
        try FileManager.default.removeItem(at: PricingResolver.cacheFileURL(homeDirectory: home.path))

        // Offline: only the per-source caches are left to rebuild from.
        StubURLProtocol.payloads = [:]
        let rebuilt = MultiSourcePricingRefresher.rebuildFromCaches(
            homeDirectory: home.path,
            overrides: userOverrides,
            now: now
        )
        XCTAssertEqual(rebuilt.status.sources.first { $0.source == .astroQore }?.overrideModelCount, 3)
        let offline = PricingResolver.resolve(homeDirectory: home.path)
        try assertCorrectedTable(offline)
        XCTAssertEqual(offline.providers.codex.models, online.providers.codex.models)

        // Every fetch failing falls back to the same caches, corrections too.
        let failed = await MultiSourcePricingRefresher.refreshAll(
            homeDirectory: home.path,
            overrides: userOverrides,
            session: makeSession(),
            endpoints: endpoints,
            now: now
        )
        let astro = try XCTUnwrap(failed.status.sources.first { $0.source == .astroQore })
        XCTAssertEqual(astro.result, .failed)
        XCTAssertEqual(astro.overrideModelCount, 3)
        try assertCorrectedTable(PricingResolver.resolve(homeDirectory: home.path))
    }

    func testDroppingEveryOverrideRemovesTheCorrectionLayer() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        serveAll()
        _ = await MultiSourcePricingRefresher.refreshAll(
            homeDirectory: home.path, session: makeSession(), endpoints: endpoints, now: now
        )
        StubURLProtocol.payloads["astroqore.json"] = Data(#"""
        {"schemaVersion": 1, "models": [
          {"provider": "codex", "model": "codex-auto-review", "pricing": {"input": 9, "output": 9}}
        ]}
        """#.utf8)
        let result = await MultiSourcePricingRefresher.refreshAll(
            homeDirectory: home.path, session: makeSession(), endpoints: endpoints, now: now
        )
        XCTAssertNil(result.status.sources.first { $0.source == .astroQore }?.overrideModelCount)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".vibebar/pricing_sources/astroqore-overrides.json").path
        ))
        let merged = PricingResolver.resolve(homeDirectory: home.path)
        // Back to a gap filler: Portkey's card wins again.
        XCTAssertEqual(merged.providers.codex.models["codex-auto-review"]?.input ?? 0, 2.5e-6, accuracy: 1e-15)
    }

    func testOverrideFallsBackToItsOwnCardWhenTheInheritedModelIsMissing() throws {
        let layers = try XCTUnwrap(AstroQorePricingTransformer.transformLayers(
            supplement, updatedAt: "2026-09-23", calculationVersion: 1, inheritanceBase: nil
        ))
        let overrides = try XCTUnwrap(layers.overrides)
        XCTAssertEqual(overrides.providers.codex.models["codex-auto-review"]?.input ?? 0, 9e-6, accuracy: 1e-15)
        XCTAssertNil(overrides.providers.codex.models["gpt-conflict"])
        XCTAssertEqual(layers.supplement.providers.codex.models.count, 6)
        // The single-table entry point is unchanged: every entry, one layer.
        XCTAssertEqual(
            AstroQorePricingTransformer.transform(
                supplement, updatedAt: "2026-09-23", calculationVersion: 1
            ),
            layers.supplement
        )
    }

    /// Builds released before `override` existed decode entries with a
    /// synthesized `Decodable` that has no such key. JSON decoding ignores
    /// unknown keys, so the published document still decodes there — the
    /// correction just stays a gap filler. This mirrors that decoder shape.
    func testPublishedSupplementDecodesWithThePreOverrideDecoderShape() throws {
        struct LegacyDocument: Decodable {
            let schemaVersion: Int
            let models: [LegacyModel]
        }
        struct LegacyModel: Decodable {
            let provider: PricingProviderFamily
            let model: String
            let displayLabel: String?
            let inherits: LegacyReference?
            let pricing: LegacyPricing
        }
        struct LegacyReference: Decodable {
            let provider: String
            let model: String
        }
        struct LegacyPricing: Decodable {
            let input: Double
            let output: Double
            let cacheRead: Double?
            let cacheWrite: Double?
        }
        let legacy = try JSONDecoder().decode(LegacyDocument.self, from: publishedSupplement)
        XCTAssertEqual(legacy.schemaVersion, 1)
        let autoReview = try XCTUnwrap(legacy.models.first { $0.model == "codex-auto-review" })
        XCTAssertEqual(autoReview.inherits?.model, "gpt-5.6-luna")
        XCTAssertEqual(autoReview.pricing.cacheRead, 0.02)
    }

    func testPublishedSupplementDecodesIntoBothLayers() throws {
        let luna = PricingDataSet.CodexEntry(
            input: 0.2e-6, output: 1.2e-6, cacheRead: 0.02e-6, cacheCreation: 0.25e-6,
            thresholdTokens: 272_000,
            inputAboveThreshold: 0.4e-6, outputAboveThreshold: 1.8e-6,
            cacheReadAboveThreshold: 0.04e-6, cacheCreationAboveThreshold: 0.5e-6,
            fastMultiplier: 2
        )
        var base = PricingDataSet.empty(updatedAt: "2026-09-23", calculationVersion: 1)
        base = PricingDataSetMerger.overlay(
            PricingDataSet(
                schemaVersion: PricingDataSet.currentSchemaVersion,
                updatedAt: "2026-09-23",
                calculationVersion: 1,
                providers: .init(
                    codex: .init(models: ["gpt-5.6-luna": luna]),
                    claude: .init(models: [:]), gemini: .init(models: [:]),
                    grok: .init(models: [:]), antigravity: .init(models: [:])
                )
            ),
            onto: base,
            updatedAt: "2026-09-23"
        )
        let layers = try XCTUnwrap(AstroQorePricingTransformer.transformLayers(
            publishedSupplement, updatedAt: "2026-09-23", calculationVersion: 1, inheritanceBase: base
        ))
        XCTAssertEqual(layers.supplement.modelCount, 3)
        let overrides = try XCTUnwrap(layers.overrides)
        XCTAssertEqual(Array(overrides.providers.codex.models.keys), ["codex-auto-review"])
        let inherited = try XCTUnwrap(overrides.providers.codex.models["codex-auto-review"])
        XCTAssertEqual(inherited.input, luna.input)
        XCTAssertEqual(inherited.cacheRead, luna.cacheRead)
        XCTAssertEqual(inherited.fastMultiplier, 2)

        // Offline fallback: without Luna in the public merge the entry's own
        // block is the same full card.
        let fallback = try XCTUnwrap(AstroQorePricingTransformer.transformLayers(
            publishedSupplement, updatedAt: "2026-09-23", calculationVersion: 1, inheritanceBase: nil
        )?.overrides?.providers.codex.models["codex-auto-review"])
        XCTAssertEqual(fallback.input, luna.input, accuracy: 1e-15)
        XCTAssertEqual(fallback.output, luna.output, accuracy: 1e-15)
        XCTAssertEqual(fallback.cacheRead ?? 0, luna.cacheRead ?? 0, accuracy: 1e-15)
        XCTAssertEqual(fallback.cacheCreation ?? 0, luna.cacheCreation ?? 0, accuracy: 1e-15)
        XCTAssertEqual(fallback.thresholdTokens, 272_000)
        XCTAssertEqual(fallback.outputAboveThreshold ?? 0, luna.outputAboveThreshold ?? 0, accuracy: 1e-15)
        XCTAssertEqual(fallback.fastMultiplier ?? 0, 2, accuracy: 1e-12)
    }

    /// A copy of `AstroQore/vibebar-model-pricing`'s `pricing.json` as of the
    /// change that introduced `override`.
    private let publishedSupplement = Data(#"""
    {
      "$schema": "./schema.json",
      "schemaVersion": 1,
      "updatedAt": "2026-09-23",
      "unit": "usd_per_million_tokens",
      "models": [
        {
          "provider": "codex",
          "model": "gpt-daybreak-blue-latest",
          "displayLabel": "GPT Daybreak Blue",
          "inherits": {
            "provider": "codex",
            "model": "gpt-5.6-sol"
          },
          "pricing": {
            "input": 5.0,
            "output": 30.0,
            "cacheRead": 0.5,
            "cacheWrite": 6.25,
            "threshold": {
              "tokens": 272000,
              "input": 10.0,
              "output": 45.0,
              "cacheRead": 1.0,
              "cacheWrite": 12.5
            },
            "fast": {
              "input": 10.0,
              "output": 60.0,
              "cacheRead": 1.0,
              "cacheWrite": 12.5
            }
          },
          "source": "Alias requested by AstroQore; identical to gpt-5.6-sol"
        },
        {
          "provider": "grok",
          "model": "grok-composer-2.5-fast",
          "displayLabel": "Composer 2.5 Fast",
          "pricing": {
            "input": 3.0,
            "output": 15.0
          },
          "source": "https://cursor.com/cn/docs/models/cursor-composer-2-5"
        },
        {
          "provider": "codex",
          "model": "codex-auto-review",
          "displayLabel": "Codex Auto Review",
          "inherits": {
            "provider": "codex",
            "model": "gpt-5.6-luna"
          },
          "override": true,
          "pricing": {
            "input": 0.2,
            "output": 1.2,
            "cacheRead": 0.02,
            "cacheWrite": 0.25,
            "threshold": {
              "tokens": 272000,
              "input": 0.4,
              "output": 1.8,
              "cacheRead": 0.04,
              "cacheWrite": 0.5
            },
            "fast": {
              "input": 0.4,
              "output": 2.4,
              "cacheRead": 0.04,
              "cacheWrite": 0.5
            }
          },
          "source": "OpenAI 2026-07-30: Codex Auto-review runs on GPT-5.6 Luna; Portkey's standalone price omits cache reads"
        }
      ]
    }
    """#.utf8)
}
