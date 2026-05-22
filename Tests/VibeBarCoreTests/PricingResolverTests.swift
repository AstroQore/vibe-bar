import XCTest
@testable import VibeBarCore

/// Locks the three-tier resolution chain:
///   cache (~/.vibebar/pricing_cache.json)
///     → bundled (Resources/pricing.json via Bundle.module)
///       → hardcoded (PricingHardcoded.fallback)
final class PricingResolverTests: XCTestCase {
    private func makeTempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarPricingResolverTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func writeCache(to home: URL, dataSet: PricingDataSet) throws {
        let cacheDir = home.appendingPathComponent(".vibebar", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cacheFile = cacheDir.appendingPathComponent("pricing_cache.json")
        let data = try JSONEncoder().encode(dataSet)
        try data.write(to: cacheFile)
    }

    func testBundledResourceLoads() {
        // No cache present, so resolver must hit the bundled JSON
        // and return a valid data set with all five providers.
        let bundled = try? XCTUnwrap(PricingResolver.loadBundled())
        XCTAssertNotNil(bundled)
        XCTAssertEqual(bundled?.schemaVersion, PricingDataSet.currentSchemaVersion)
        XCTAssertGreaterThan(bundled?.providers.codex.models.count ?? 0, 0)
        XCTAssertGreaterThan(bundled?.providers.claude.models.count ?? 0, 0)
        XCTAssertGreaterThan(bundled?.providers.gemini.models.count ?? 0, 0)
        XCTAssertGreaterThan(bundled?.providers.grok.models.count ?? 0, 0)
        XCTAssertGreaterThan(bundled?.providers.antigravity.models.count ?? 0, 0)
    }

    func testCacheOverridesBundle() throws {
        let home = try makeTempHome()
        defer { cleanup(home) }

        let cacheDataSet = PricingDataSet(
            schemaVersion: 1,
            updatedAt: "2099-01-01",
            calculationVersion: 99,
            providers: PricingDataSet.Providers(
                codex: PricingHardcoded.fallback.providers.codex,
                claude: PricingHardcoded.fallback.providers.claude,
                gemini: PricingHardcoded.fallback.providers.gemini,
                grok: PricingHardcoded.fallback.providers.grok,
                antigravity: PricingHardcoded.fallback.providers.antigravity
            )
        )
        try writeCache(to: home, dataSet: cacheDataSet)

        let resolved = PricingResolver.resolve(homeDirectory: home.path)
        XCTAssertEqual(resolved.updatedAt, "2099-01-01")
        XCTAssertEqual(resolved.calculationVersion, 99)
    }

    func testCorruptCacheFallsBackToBundle() throws {
        let home = try makeTempHome()
        defer { cleanup(home) }
        let cacheDir = home.appendingPathComponent(".vibebar", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: cacheDir.appendingPathComponent("pricing_cache.json"))

        let resolved = PricingResolver.resolve(homeDirectory: home.path)
        XCTAssertEqual(resolved.schemaVersion, PricingDataSet.currentSchemaVersion)
        // Bundle ships a real updatedAt, not the corrupt placeholder.
        XCTAssertFalse(resolved.updatedAt.isEmpty)
    }

    func testSchemaMismatchCacheIgnored() throws {
        let home = try makeTempHome()
        defer { cleanup(home) }

        let wrongSchema = PricingDataSet(
            schemaVersion: 99,
            updatedAt: "future-format",
            calculationVersion: 0,
            providers: PricingHardcoded.fallback.providers
        )
        try writeCache(to: home, dataSet: wrongSchema)

        let resolved = PricingResolver.resolve(homeDirectory: home.path)
        XCTAssertEqual(resolved.schemaVersion, PricingDataSet.currentSchemaVersion)
        XCTAssertNotEqual(resolved.updatedAt, "future-format")
    }

    func testBundledMatchesHardcodedForSentinelModels() throws {
        // The bundled JSON is generated alongside `PricingHardcoded`
        // and must stay in lockstep. Drift between the two would
        // produce different cost numbers depending on whether the
        // bundle resource is loadable at runtime — never acceptable
        // for a production install. Sample a few sentinel models per
        // provider; if any of these miss, audit the full table.
        let bundled = try XCTUnwrap(PricingResolver.loadBundled())
        let hardcoded = PricingHardcoded.fallback

        XCTAssertEqual(bundled.calculationVersion, hardcoded.calculationVersion)

        let claudeSentinel = "claude-opus-4-7"
        XCTAssertEqual(
            bundled.providers.claude.models[claudeSentinel],
            hardcoded.providers.claude.models[claudeSentinel],
            "Claude \(claudeSentinel) drift between bundled JSON and hardcoded fallback"
        )

        let codexSentinel = "gpt-5"
        XCTAssertEqual(
            bundled.providers.codex.models[codexSentinel],
            hardcoded.providers.codex.models[codexSentinel],
            "Codex \(codexSentinel) drift between bundled JSON and hardcoded fallback"
        )

        let geminiSentinel = "gemini-2.5-pro"
        XCTAssertEqual(
            bundled.providers.gemini.models[geminiSentinel],
            hardcoded.providers.gemini.models[geminiSentinel],
            "Gemini \(geminiSentinel) drift between bundled JSON and hardcoded fallback"
        )

        let grokSentinel = "grok-build"
        XCTAssertEqual(
            bundled.providers.grok.models[grokSentinel],
            hardcoded.providers.grok.models[grokSentinel],
            "Grok \(grokSentinel) drift between bundled JSON and hardcoded fallback"
        )

        let antigravitySentinel = "antigravity-default"
        XCTAssertEqual(
            bundled.providers.antigravity.models[antigravitySentinel],
            hardcoded.providers.antigravity.models[antigravitySentinel],
            "AntiGravity \(antigravitySentinel) drift between bundled JSON and hardcoded fallback"
        )
    }

    func testTestOverrideTakesPrecedence() {
        let override = PricingDataSet(
            schemaVersion: 1,
            updatedAt: "test-override",
            calculationVersion: 1,
            providers: PricingHardcoded.fallback.providers
        )
        PricingResolver.testOverride = override
        defer { PricingResolver.testOverride = nil }
        XCTAssertEqual(PricingResolver.active.updatedAt, "test-override")
    }
}
