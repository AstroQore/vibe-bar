import XCTest
@testable import VibeBarCore

final class ChatGPTChatTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private func sample(_ remaining: Int, at: TimeInterval, reset: TimeInterval?) -> ChatGPTChatAllowanceSample {
        .init(id: "image_gen", remaining: remaining, resetAt: reset.map { base.addingTimeInterval($0) }, observedAt: base.addingTimeInterval(at))
    }
    private func cycle(_ number: Int, total: Int, learning: inout ChatGPTChatAllowanceLearning) -> QuotaQuantity {
        let boundary = Double(number) * 86_400
        _ = learning.observe(sample(2, at: boundary - 60, reset: boundary))
        return learning.observe(sample(total, at: boundary + 10, reset: boundary + 86_400))
    }

    func testRequiresThreeIndependentConsistentResetsAndNeverCountsInitialValue() {
        var learning = ChatGPTChatAllowanceLearning()
        XCTAssertNil(learning.observe(sample(1000, at: 0, reset: 86_400)).limit)
        XCTAssertNil(cycle(1, total: 1000, learning: &learning).usedPercent)
        XCTAssertNil(cycle(2, total: 1000, learning: &learning).usedPercent)
        XCTAssertEqual(cycle(3, total: 1000, learning: &learning).limit, 1000)
        let used = learning.observe(sample(998, at: 259_230, reset: 345_600))
        XCTAssertEqual(used.used, 2)
        XCTAssertEqual(used.usedPercent!, 0.2, accuracy: 0.0001)
        XCTAssertEqual(learning.matchingResets, 3)
        XCTAssertEqual(learning.learnedWindowSeconds, 86_400)
        let bucket = QuotaBucket(id: "image_gen", title: "Image Generation", shortLabel: "Image Generation", usedPercent: 0,
            resetAt: base.addingTimeInterval(345_600), rawWindowSeconds: learning.learnedWindowSeconds, quantity: used)
        XCTAssertTrue(bucket.supportsForecast)
        XCTAssertNotNil(UsagePace.compute(bucket: bucket, now: base.addingTimeInterval(259_230)))
        let forecast = QuotaPaceForecast.compute(bucket: bucket, observations: [], cycles: [], now: base.addingTimeInterval(259_230))
        XCTAssertNotNil(forecast)
        XCTAssertNotNil(MCPQuotaBucketDTO(bucket: bucket, forecast: forecast).forecast)
    }

    func testDifferentTotalsRestartConfidenceWithoutAveraging() {
        var learning = ChatGPTChatAllowanceLearning()
        _ = cycle(1, total: 1000, learning: &learning)
        XCTAssertNil(cycle(2, total: 900, learning: &learning).limit)
        XCTAssertEqual(learning.matchingResets, 1)
        XCTAssertNil(cycle(3, total: 900, learning: &learning).limit)
        XCTAssertEqual(cycle(4, total: 900, learning: &learning).limit, 900)
        XCTAssertNil(cycle(5, total: 800, learning: &learning).limit)
    }

    func testMovingUnusedResetAndRepeatedReadsNeverCreateConfidence() {
        var learning = ChatGPTChatAllowanceLearning()
        for n in 0..<200 {
            let now = Double(n) * 60
            XCTAssertNil(learning.observe(sample(1000, at: now, reset: now + 86_400)).limit)
        }
        XCTAssertEqual(learning.matchingResets, 0)
    }

    func testMissedBoundaryAndUnexpectedIncreaseInvalidateLearnedTotal() {
        var learning = ChatGPTChatAllowanceLearning()
        for n in 1...3 { _ = cycle(n, total: 1000, learning: &learning) }
        XCTAssertNil(learning.observe(sample(1200, at: 259_230, reset: 345_600)).limit)
        for n in 4...6 { _ = cycle(n, total: 1200, learning: &learning) }
        XCTAssertNil(learning.observe(sample(1190, at: 604_801, reset: 691_200)).limit)
    }

    func testOnlyTwoFeaturesAreParsedAndMalformedCountsDoNotBecomeZero() throws {
        let data = Data(#"{"limits_progress":[{"feature_name":"image_gen","remaining":998},{"feature_name":"deep_research","remaining":250},{"feature_name":"gpt-6-pro","remaining":100},{"feature_name":"file_upload","remaining":5}]}"#.utf8)
        let values = try ChatGPTChatParser.samples(data, now: base)
        XCTAssertEqual(values.map(\.id), ["image_gen", "deep_research"])
        for invalid in ["true", "-1", "0.5", "\"100\""] {
            let data = Data("{\"limits_progress\":[{\"feature_name\":\"image_gen\",\"remaining\":\(invalid)}]}".utf8)
            XCTAssertTrue(try ChatGPTChatParser.samples(data, now: base).isEmpty)
        }
    }

    func testPlanAndAccountChangesDiscardLearningIncludingWhenSwitchingBack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatGPTChatAllowanceStore(url: directory.appendingPathComponent("learning.json"))
        let identity = ChatGPTChatParser.identity("synthetic-user")
        for n in 1...3 {
            let boundary = Double(n) * 86_400
            _ = try await store.observe(localAccount: "local", identity: identity, plan: "pro", samples: [sample(5, at: boundary-60, reset: boundary)])
            let values = try await store.observe(localAccount: "local", identity: identity, plan: "pro", samples: [sample(1000, at: boundary+10, reset: boundary+86_400)])
            XCTAssertEqual(values["image_gen"]?.quantity.limit, n == 3 ? 1000 : nil)
        }
        for (i, plan) in ["prolite", "pro"].enumerated() {
            let result = try await store.observe(localAccount: "local", identity: identity, plan: plan, samples: [sample(500, at: 259_230 + Double(i), reset: 345_600)])
            XCTAssertNil(result["image_gen"]?.quantity.limit)
        }
        let text = try String(contentsOf: directory.appendingPathComponent("learning.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("synthetic-user"))
        let reloaded = ChatGPTChatAllowanceStore(url: directory.appendingPathComponent("learning.json"))
        let result = try await reloaded.observe(localAccount: "local", identity: ChatGPTChatParser.identity("another-user"), plan: "pro", samples: [sample(500, at: 259_240, reset: 345_600)])
        XCTAssertNil(result["image_gen"]?.quantity.limit)
    }

    func testClientReusesPlanEndpointAndDoesNotReadModelsOrConversations() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = ChatFixtureTransport()
        let client = ChatGPTChatClient(transport: transport, store: ChatGPTChatAllowanceStore(url: directory.appendingPathComponent("learning.json")))
        let quota = try await client.fetch(account: AccountIdentity(id: "local", tool: .chatgptChat, source: .webCookie), settings: .init(), now: base)
        XCTAssertEqual(quota.plan, "prolite")
        XCTAssertEqual(quota.buckets.map(\.id), ["image_gen", "deep_research"])
        XCTAssertTrue(quota.buckets.allSatisfy { !$0.hasPercentage })
        let calls = await transport.calls
        XCTAssertEqual(calls, ["/api/auth/session", "/backend-api/wham/usage", "/backend-api/conversation/init"])
        for path in ["/backend-api/conversations", "/backend-api/models", "/backend-api/conversation/00000000-0000-4000-8000-000000000000"] {
            XCTAssertFalse(ChatGPTChatRequestPolicy.allows(path: path, method: "GET"))
        }
    }

    func testMenuBarDefaultSwitchesFromEstimatedCountToPercentage() {
        var value = MenuBarQuotaSnapshot(fieldId: "chatgptChat.image_gen", tool: .chatgptChat,
            label: "Image Generation", usedPercent: 0, displayPercent: 100,
            quantity: .init(remaining: 998, isEstimated: true))
        XCTAssertEqual(MenuBarToken.newQuota(fieldId: value.fieldId).kind, .quota(fieldId: value.fieldId, metric: .displayPercent))
        XCTAssertEqual(MenuBarComposition.value(of: .displayPercent, in: value, displayMode: .remaining, resetFormat: .default, now: base), "≈998")
        value.quantity = .init(used: 260, remaining: 740, limit: 1000, isEstimated: true)
        value.usedPercent = 26; value.displayPercent = 74
        XCTAssertEqual(MenuBarComposition.value(of: .displayPercent, in: value, displayMode: .remaining, resetFormat: .default, now: base), "74%")
    }

    func testLegacySettingsDecodeWithoutRestoringModelTracking() throws {
        let settings = try JSONDecoder().decode(ChatGPTChatSettings.self, from: Data(#"{"enabled":true,"includeHistory":true,"astraWeeklyLimit":200}"#.utf8))
        XCTAssertTrue(settings.enabled)
        let data = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        XCTAssertEqual(Set(data.keys), ["enabled"])
        XCTAssertEqual(MenuBarFieldCatalog.chatGPTChatFields.count, 2)
        XCTAssertEqual(ToolType.codex.coreProviderMembers.first, .chatgptChat)
    }
}

private actor ChatFixtureTransport: ChatGPTChatTransport {
    nonisolated let name = "fixture"
    private(set) var calls: [String] = []
    func request(path: String, method: String, bearer: String?, body: Data?) async throws -> Data {
        calls.append(path)
        switch path {
        case "/api/auth/session": return Data(#"{"accessToken":"synthetic-token","user":{"id":"synthetic-user"}}"#.utf8)
        case "/backend-api/wham/usage": return Data(#"{"plan_type":"prolite"}"#.utf8)
        case "/backend-api/conversation/init": return Data(#"{"limits_progress":[{"feature_name":"image_gen","remaining":998},{"feature_name":"deep_research","remaining":250}]}"#.utf8)
        default: throw QuotaError.parseFailure("Unexpected endpoint")
        }
    }
}
