import XCTest
import SQLite3
@testable import VibeBarCore

final class OpenAIPricingUpdateTests: XCTestCase {
    override func tearDown() {
        PricingResolver.testOverride = nil
        super.tearDown()
    }

    func testProPriceNamesPreserveLegacyAndExplicitTierIdentities() {
        for raw in ["prolite", "pro_lite", "pro5x", "pro100", "pro_100", "ChatGPT Pro 100"] {
            XCTAssertEqual(ProviderPlanDisplay.displayName(for: .codex, rawPlan: raw), "ChatGPT Pro 100")
        }
        for raw in ["pro", "pro20x", "pro200", "pro_200", "ChatGPT Pro 200"] {
            XCTAssertEqual(ProviderPlanDisplay.displayName(for: .chatgptChat, rawPlan: raw), "ChatGPT Pro 200")
        }
        for raw in ["pro500", "pro_500", "Pro 500", "ChatGPT Pro 500"] {
            XCTAssertEqual(ProviderPlanDisplay.displayName(for: .codex, rawPlan: raw), "ChatGPT Pro 500")
        }
        XCTAssertEqual(ProviderPlanDisplay.openAIPlanName("promax"), "Pro Max")
        XCTAssertEqual(ProviderPlanDisplay.openAIPlanName("pro750"), "Pro750")
        XCTAssertEqual(ProviderPlanDisplay.displayName(for: .claude, rawPlan: "pro"), "Claude Pro")
    }

    func testNewModelFloorMatchesBundleAndDoesNotGrantUnpublishedUltrafast() throws {
        let bundled = try XCTUnwrap(PricingResolver.loadBundled())
        for model in ["gpt-6.1-sol", "gpt-6-sol", "gpt-6-luna", "gpt-6-astra"] {
            XCTAssertEqual(bundled.providers.codex.models[model], PricingHardcoded.fallback.providers.codex.models[model])
        }
        XCTAssertNil(bundled.providers.codex.models["gpt-6.1-sol"]?.ultrafast)
        XCTAssertNil(bundled.providers.codex.models["gpt-6-sol"]?.ultrafast)
        XCTAssertNil(bundled.providers.codex.models["gpt-6-luna"]?.ultrafast)
        XCTAssertEqual(bundled.providers.codex.models["gpt-5.5"]?.fastMultiplier, 2.5)
    }

    func testAstraRatesAtAndAbove272KApplyToEntireRequest() throws {
        PricingResolver.testOverride = PricingHardcoded.fallback
        func cost(_ input: Int, _ tier: String) throws -> Double {
            try XCTUnwrap(CostUsagePricing.codexCostUSD(model: "gpt-6-astra", inputTokens: input,
                                                       cachedInputTokens: 120_000, outputTokens: 10_000,
                                                       serviceTier: tier))
        }
        XCTAssertEqual(try cost(272_000, "standard"), 2.14, accuracy: 1e-9)
        XCTAssertEqual(try cost(272_000, "ultrafast"), 12.84, accuracy: 1e-9)
        XCTAssertEqual(try cost(272_001, "standard"), 4.03002, accuracy: 1e-9)
        XCTAssertEqual(try cost(272_001, "fast"), 8.06004, accuracy: 1e-9)
        XCTAssertEqual(try cost(272_001, "ultrafast"), 24.18012, accuracy: 1e-9)
    }

    func testUnknownTiersAndUnsupportedSnapshotsStayUnpriced() {
        PricingResolver.testOverride = PricingHardcoded.fallback
        for (model, tier) in [("gpt-6-astra", "turbo-future"), ("gpt-6.1-sol", "ultrafast"),
                              ("gpt-6-astra-2026-09-03", "ultrafast")] {
            XCTAssertNil(CostUsagePricing.codexCostUSD(model: model, inputTokens: 1_000,
                                                       cachedInputTokens: 0, outputTokens: 10,
                                                       serviceTier: tier))
        }
        XCTAssertNotNil(CostUsagePricing.codexCostUSD(model: "gpt-6-astra-2026-09-03", inputTokens: 1_000,
                                                       cachedInputTokens: 0, outputTokens: 10))
        let context = CostPricingContext(dataSet: PricingHardcoded.fallback)
        XCTAssertNil(context.codexEntry(for: "gpt-6-astra-2026-09-03", serviceTier: "ultrafast"))
    }

    func testPartialStandardTierFieldsKeepBaseRateFallback() throws {
        let entry = PricingDataSet.CodexEntry(input: 1e-6, output: 4e-6, cacheRead: 0.1e-6,
                                             thresholdTokens: 100, inputAboveThreshold: 2e-6)
        let cost = CostUsagePricing.codexCostUSD(pricing: entry, inputTokens: 150,
                                                cachedInputTokens: 20, outputTokens: 10, serviceTier: "standard")
        XCTAssertEqual(try XCTUnwrap(cost), 0.000302, accuracy: 1e-12)
        let shortOnlyUltra = PricingDataSet.CodexEntry(input: 1e-6, output: 4e-6, cacheRead: nil,
                                                       thresholdTokens: 100, inputAboveThreshold: 2e-6,
                                                       ultrafast: .init(input: 6e-6, output: 24e-6))
        XCTAssertNil(CostUsagePricing.codexCostUSD(pricing: shortOnlyUltra, inputTokens: 150,
                                                   cachedInputTokens: 0, outputTokens: 10, serviceTier: "ultrafast"))
    }

    static let liteLLM = #"""
    {"gpt-6-astra": {
      "input_cost_per_token": 0.00001, "output_cost_per_token": 0.00005,
      "cache_read_input_token_cost": 0.000001, "cache_creation_input_token_cost": 0.0000125,
      "input_cost_per_token_above_272k_tokens": 0.00002,
      "output_cost_per_token_above_272k_tokens": 0.000075,
      "cache_read_input_token_cost_above_272k_tokens": 0.000002,
      "cache_creation_input_token_cost_above_272k_tokens": 0.000025,
      "input_cost_per_token_priority": 0.00002, "output_cost_per_token_priority": 0.0001,
      "input_cost_per_token_ultrafast": 0.00006, "output_cost_per_token_ultrafast": 0.0003,
      "cache_read_input_token_cost_ultrafast": 0.000006,
      "cache_creation_input_token_cost_ultrafast": 0.000075,
      "input_cost_per_token_above_272k_tokens_ultrafast": 0.00012,
      "output_cost_per_token_above_272k_tokens_ultrafast": 0.00045,
      "cache_read_input_token_cost_above_272k_tokens_ultrafast": 0.000012,
      "cache_creation_input_token_cost_above_272k_tokens_ultrafast": 0.00015
    }}
    """#

    func testLiteLLMParsesPublishedUltrafastAndContextFields() throws {
        let set = try XCTUnwrap(LiteLLMPricingTransformer.transform(Data(Self.liteLLM.utf8),
                                                                  base: .empty(updatedAt: "test", calculationVersion: 5),
                                                                  updatedAt: "test"))
        XCTAssertEqual(set.providers.codex.models["gpt-6-astra"], PricingHardcoded.fallback.providers.codex.models["gpt-6-astra"])
        let row = try XCTUnwrap(set.effectiveModelPrices.first)
        XCTAssertEqual(row.ultrafast?.inputPerMillion, 60)
        XCTAssertEqual(row.ultrafast?.cacheWriteAboveThresholdPerMillion, 150)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(MCPPricingRowDTO(row: row))) as? [String: Any])
        let ultra = try XCTUnwrap(json["ultrafast"] as? [String: Any])
        XCTAssertEqual(ultra["outputPerMillion"] as? Double, 300)
        XCTAssertEqual(ultra["thresholdTokens"] as? Int, 272_000)
        XCTAssertEqual(ultra["outputAboveThresholdPerMillion"] as? Double, 450)
        XCTAssertFalse(ultra.keys.contains { $0.contains("_") })
    }

    func testOptionalUltrafastSurvivesMergeInheritanceAndUserOverrideEncoding() throws {
        let floor = PricingHardcoded.fallback
        let rates = try XCTUnwrap(floor.providers.codex.models["gpt-6-astra"]?.ultrafast)
        let withoutUltra = try XCTUnwrap(ModelsDevPricingTransformer.transform(
            Data(#"{"openai":{"models":{"gpt-6-astra":{"cost":{"input":10,"output":50,"cache_read":1}}}}}"#.utf8),
            updatedAt: "test", calculationVersion: 5))
        let merged = PricingDataSetMerger.overlay(withoutUltra, onto: floor, updatedAt: "test")
        XCTAssertEqual(merged.providers.codex.models["gpt-6-astra"]?.ultrafast, rates)
        let document = Data(#"{"schemaVersion":1,"models":[{"provider":"codex","model":"test-astra","inherits":{"provider":"codex","model":"gpt-6-astra"},"pricing":{"input":10,"output":50}}]}"#.utf8)
        let inherited = AstroQorePricingTransformer.transform(document, updatedAt: "test", calculationVersion: 5, inheritanceBase: merged)
        XCTAssertEqual(inherited?.providers.codex.models["test-astra"]?.ultrafast, rates)
        let override = ModelPricingOverride(provider: .codex, model: "gpt-6-astra", inputPerMillion: 10,
                                            outputPerMillion: 50, ultrafast: .init(rates: rates))
        let restored = try JSONDecoder().decode(ModelPricingOverride.self, from: JSONEncoder().encode(override))
        let overridden = ModelPricingOverrideApplier.apply([restored], to: floor, updatedAt: "test")
        XCTAssertEqual(overridden.providers.codex.models["gpt-6-astra"]?.ultrafast, rates)
    }

    func testOldPricingCacheCannotHideNewModelAndTierFloor() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("VibeBarOldPricing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".vibebar"), withIntermediateDirectories: true)
        let old = PricingDataSet(schemaVersion: 1, updatedAt: "old", calculationVersion: 5,
                                 providers: .init(codex: .init(models: [:]), claude: .init(models: [:]),
                                                  gemini: .init(models: [:]), grok: .init(models: [:]), antigravity: .init(models: [:])))
        try JSONEncoder().encode(old).write(to: PricingResolver.cacheFileURL(homeDirectory: home.path))
        let resolved = PricingResolver.resolve(homeDirectory: home.path)
        XCTAssertEqual(resolved.schemaVersion, 2)
        XCTAssertNotNil(resolved.providers.codex.models["gpt-6.1-sol"])
        XCTAssertNotNil(resolved.providers.codex.models["gpt-6-astra"]?.ultrafast)
        XCTAssertEqual(resolved.calculationVersion, 5)
    }

    func testCodexColdAndWarmScansKeepExplicitTierAndStableConfigFallback() async throws {
        PricingResolver.testOverride = PricingHardcoded.fallback
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("VibeBarTierScan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".codex")
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try #"service_tier = "ultrafast""#.write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let now = Date(timeIntervalSince1970: 1_790_784_000)
        let timestamp = ISO8601DateFormatter().string(from: now)
        let lines = """
        {"type":"turn_context","payload":{"model":"gpt-6-astra","service_tier":"standard"}}
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"output_tokens":10}}}}
        {"type":"turn_context","payload":{"model":"gpt-6-astra"}}
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2000,"output_tokens":20}}}}
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count","service_tier":"priority","info":{"total_token_usage":{"input_tokens":3000,"output_tokens":30}}}}
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"service_tier":"future-tier","total_token_usage":{"input_tokens":4000,"output_tokens":40}}}}
        """
        try lines.write(to: sessions.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        let first = await CostUsageScanner.scan(tool: .codex, homeDirectory: home.path, now: now)
        XCTAssertEqual(try XCTUnwrap(first?.allTimeCostUSD), 0.0105 * 9, accuracy: 1e-12)
        let cached = CostUsageScanCache.load(homeDirectory: home.path, tool: .codex)
        XCTAssertEqual(cached.entries.values.first?.events.map(\.serviceTier), ["standard", "ultrafast", "priority", "future-tier"])
        try #"service_tier = "standard""#.write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let warm = await CostUsageScanner.scan(tool: .codex, homeDirectory: home.path, now: now)
        XCTAssertEqual(warm?.allTimeCostUSD, first?.allTimeCostUSD)
        let appended = lines + "\n" + """
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5000,"output_tokens":50}}}}
        """
        try appended.write(to: sessions.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        let growing = await CostUsageScanner.scan(tool: .codex, homeDirectory: home.path, now: now)
        XCTAssertEqual(try XCTUnwrap(growing?.allTimeCostUSD), 0.0105 * 10, accuracy: 1e-12)
        let reparsed = CostUsageScanCache.load(homeDirectory: home.path, tool: .codex)
        XCTAssertEqual(reparsed.entries.values.first?.events.map(\.serviceTier),
                       ["standard", "ultrafast", "priority", "future-tier", "standard"])
    }

    func testCodexTierUpgradeReingestsUnchangedFilesWithoutDeletingRows() async throws {
        let (oldLedger, directory) = try UsageLedgerFixtures.makeLedger("CodexTierMigration")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_790_784_000)
        let oldEvent = UsageLedgerFixtures.event(date: now, model: "gpt-6-astra", input: 1_000, output: 10)
        try await oldLedger.ingest(UsageLedgerFixtures.batch(events: [.init(event: oldEvent, costUSD: 0.0105)]))
        let url = directory.appendingPathComponent("usage_events.sqlite3")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "DELETE FROM ledger_meta WHERE key = 'codex_costing_tier_v1'", nil, nil, nil), SQLITE_OK)
        let upgraded = try UsageEventLedger(url: url)
        let event = UsageLedgerFixtures.event(date: now, model: "gpt-6-astra", input: 1_000, output: 10,
                                               serviceTier: "ultrafast")
        try await upgraded.ingest(UsageLedgerFixtures.batch(events: [.init(event: event, costUSD: 0.063)]))
        let filter = UsageLedgerFixtures.wideFilter(around: now)
        let summary = try await upgraded.summary(filter)
        XCTAssertEqual(summary.requests, 1)
        XCTAssertEqual(summary.costMicros, 63_000)
        // The marker prevents repeated invalidation on a later launch.
        let reopened = try UsageEventLedger(url: url)
        let changed = UsageLedgerFixtures.event(date: now, model: "gpt-6-astra", input: 1_000, output: 10,
                                                 serviceTier: "fast")
        try await reopened.ingest(UsageLedgerFixtures.batch(events: [.init(event: changed, costUSD: 0.021)]))
        let unchanged = try await reopened.summary(filter)
        XCTAssertEqual(unchanged.costMicros, 63_000)
    }

    func testUltrafastPriceRevisionLowersHistoryWithoutWipingIt() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("UltrafastRepricing")
        defer { try? FileManager.default.removeItem(at: directory) }
        PricingResolver.testOverride = PricingHardcoded.fallback
        let originalRevision = PricingResolver.activeRevision
        _ = try await ledger.repriceForPricingRevision(originalRevision)
        let now = Date(timeIntervalSince1970: 1_790_784_000)
        let event = UsageLedgerFixtures.event(date: now, model: "gpt-6-astra", input: 1_000, output: 10,
                                               serviceTier: "ultrafast")
        try await ledger.ingest(UsageLedgerFixtures.batch(events: [.init(event: event, costUSD: 0.063)]))
        let history = CostHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        let day = Calendar.current.startOfDay(for: now)
        await history.mergeSeries([.init(date: day, costUSD: 0.063, totalTokens: 1_010)], tool: .codex,
                                  retentionDays: CostDataSettings.unlimitedRetentionDays)
        let lowerRates = PricingDataSet.CodexRates(input: 30e-6, output: 150e-6, cacheRead: 3e-6)
        PricingResolver.testOverride = ModelPricingOverrideApplier.apply(
            [.init(provider: .codex, model: "gpt-6-astra", inputPerMillion: 10, outputPerMillion: 50,
                   ultrafast: .init(rates: lowerRates))], to: PricingHardcoded.fallback, updatedAt: "test")
        let newRevision = PricingResolver.activeRevision
        XCTAssertNotEqual(originalRevision, newRevision)
        let repriced = try await ledger.repriceForPricingRevision(newRevision)
        let changes = try XCTUnwrap(repriced)
        XCTAssertEqual(changes.first?.deltaUSD ?? 0, -0.0315, accuracy: 1e-9)
        _ = await history.applyPricingRevision(changes)
        let stored = await history.history(for: .codex, now: now,
                                            retentionDays: CostDataSettings.unlimitedRetentionDays)
        XCTAssertEqual(stored.days.first?.costUSD ?? -1, 0.0315, accuracy: 1e-9)
        XCTAssertEqual(stored.days.first?.totalTokens, 1_010)
        XCTAssertEqual(PricingResolver.active.calculationVersion, 5)
    }
}
