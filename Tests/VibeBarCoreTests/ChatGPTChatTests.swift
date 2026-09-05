import XCTest
@testable import VibeBarCore

final class ChatGPTChatTests: XCTestCase {
    private let id = "00000000-0000-4000-8000-000000000001"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

    private func conversation(origin: String? = nil, model: String = "gpt-6-pro", defaultModel: String? = nil,
                              duplicate: Bool = false, unfinished: Bool = false) throws -> Data {
        let user: [String: Any] = ["id": "synthetic-message", "author": ["role": "user"],
                                  "create_time": now.timeIntervalSince1970 - 60,
                                  "metadata": ["working_turn_id": "synthetic-turn"], "content": ["content_type": "text", "parts": ["PRIVATE TEXT MUST NOT PERSIST"]]]
        let reply: [String: Any] = ["id": "synthetic-response", "author": ["role": "assistant"],
                                   "create_time": now.timeIntervalSince1970 - 30, "recipient": "all", "channel": "final",
                                   "status": unfinished ? "in_progress" : "finished_successfully",
                                   "metadata": ["model_slug": model, "thinking_effort": "max"],
                                   "content": ["content_type": "text", "parts": ["PRIVATE RESPONSE"]]]
        var mapping: [String: Any] = ["u": ["message": user, "parent": NSNull()], "a": ["message": reply, "parent": "u"]]
        if duplicate { mapping["another-a"] = ["message": reply, "parent": "u"] }
        return try json(["conversation_id": id, "conversation_origin": origin as Any? ?? NSNull(),
                         "default_model_slug": defaultModel ?? model, "mapping": mapping])
    }

    func testReportedRemaindersDoNotInventTotalsOrPercentages() throws {
        let data = try json(["model_limits": [], "limits_progress": [
            ["feature_name": "image_gen", "remaining": 998, "reset_after": "2027-01-16T08:00:00Z"],
            ["feature_name": "deep_research", "remaining": 250],
            ["feature_name": "file_upload", "remaining": 50],
            ["feature_name": "image_gen", "remaining": -1]
        ]])
        let buckets = try ChatGPTChatParser.features(data)
        XCTAssertEqual(buckets.map(\.id), ["image_gen", "deep_research"])
        XCTAssertEqual(buckets.first?.quantity?.remaining, 998)
        XCTAssertFalse(buckets[0].hasPercentage)
        XCTAssertNil(buckets[0].quantity?.limit)
        XCTAssertNil(UsagePace.compute(bucket: buckets[0], now: now))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(MCPQuotaBucketDTO(bucket: buckets[0], forecast: nil))) as! [String: Any]
        XCTAssertNil(encoded["remainingPercent"])
        XCTAssertNotNil(encoded["quantity"])
    }

    func testAllObservedWorkVariantsAreExcluded() throws {
        for origin in ["tpp", "flora", "codex"] {
            let value = try ChatGPTChatParser.conversation(conversation(origin: origin), id: id, updatedAt: now)
            XCTAssertTrue(value.isWork)
            XCTAssertTrue(value.turns.isEmpty)
        }
        for model in ["gpt-5.6-sol-wm", "gpt-6-astra-wm", "gpt-5.5-wm"] {
            let value = try ChatGPTChatParser.conversation(conversation(model: model), id: id, updatedAt: now)
            XCTAssertTrue(value.isWork)
            XCTAssertTrue(value.turns.isEmpty)
        }
    }

    func testWorkingTurnIDIsNotAWorkFlagAndAssistantNodesAreNotMessages() throws {
        let value = try ChatGPTChatParser.conversation(conversation(duplicate: true), id: id, updatedAt: now)
        XCTAssertFalse(value.isWork)
        XCTAssertEqual(value.turns.count, 1)
        XCTAssertEqual(value.turns[0].model, "gpt-6-pro")
        XCTAssertFalse(String(data: try JSONEncoder().encode(value), encoding: .utf8)!.contains("PRIVATE"))
        XCTAssertFalse(String(data: try JSONEncoder().encode(value), encoding: .utf8)!.contains("synthetic-message"))
    }

    func testActualReplyModelWinsOverCurrentConversationSelection() throws {
        let value = try ChatGPTChatParser.conversation(conversation(model: "gpt-5-4-thinking", defaultModel: "gpt-6-pro"), id: id, updatedAt: now)
        XCTAssertEqual(value.turns.first?.model, "gpt-5-4-thinking")
        let buckets = ChatGPTChatParser.modelBuckets(turns: value.turns, settings: .init(), complete: true, now: now)
        XCTAssertEqual(buckets.first?.quantity?.used, 0)
        XCTAssertEqual(buckets.last?.quantity?.used, 1)
    }

    func testUnknownSourcesAndUnfinishedTurnsDoNotBecomeConfirmedUsage() throws {
        for data in [try conversation(origin: "new-source"), try conversation(unfinished: true)] {
            let value = try ChatGPTChatParser.conversation(data, id: id, updatedAt: now)
            XCTAssertTrue(value.turns.isEmpty)
            XCTAssertEqual(value.unclassifiedTurns, 1)
        }
        XCTAssertThrowsError(try ChatGPTChatParser.conversation(conversation(), id: "different", updatedAt: now))
    }

    func testIncompleteCoverageWithholdsRemaindersEvenWithManualLimits() throws {
        var settings = ChatGPTChatSettings(); settings.astraWeeklyLimit = 200
        let turns = try ChatGPTChatParser.conversation(conversation(), id: id, updatedAt: now).turns
        let partial = ChatGPTChatParser.modelBuckets(turns: turns + turns, settings: settings, complete: false, now: now)[0]
        XCTAssertEqual(partial.quantity?.used, 1)
        XCTAssertNil(partial.quantity?.remaining)
        XCTAssertFalse(partial.hasPercentage)
        let complete = ChatGPTChatParser.modelBuckets(turns: turns, settings: settings, complete: true, now: now)[0]
        XCTAssertEqual(complete.quantity?.remaining, 199)
        XCTAssertNil(complete.resetAt)
        XCTAssertFalse(complete.supportsForecast)
    }

    func testSolThinkingMaxIsNotSilentlyChargedToSolPro() throws {
        let turns = try ChatGPTChatParser.conversation(conversation(model: "gpt-5-6-thinking"), id: id, updatedAt: now).turns
        var settings = ChatGPTChatSettings(); settings.solDailyLimit = 170
        let buckets = ChatGPTChatParser.modelBuckets(turns: turns, settings: settings, complete: true, now: now)
        XCTAssertFalse(buckets.contains { $0.id == "sol_pro_daily" })
        XCTAssertEqual(buckets.first(where: { $0.id == "model_gpt-5-6-thinking" })?.quantity?.used, 1)
    }

    func testAccountModelCatalogDistinguishesProThinkingAndWork() throws {
        let catalog = try ChatGPTChatModelCatalog.parse(json(["models": [
            ["slug": "gpt-5-6-pro", "title": "GPT-5.6 Pro", "reasoning_type": "pro", "is_work_mode_model": false],
            ["slug": "gpt-5-6-thinking", "title": "GPT-5.6 Sol", "reasoning_type": "reasoning", "is_work_mode_model": false],
            ["slug": "future-work-model", "title": "Future Work", "is_work_mode_model": true]
        ]]))
        XCTAssertEqual(catalog.models["gpt-5-6-pro"]?.isPro, true)
        XCTAssertEqual(catalog.models["gpt-5-6-thinking"]?.isPro, false)
        XCTAssertEqual(catalog.models["gpt-5-6-thinking"]?.displayTitle, "GPT-5.6 Sol · Thinking")
        let work = try ChatGPTChatParser.conversation(conversation(model: "future-work-model"), id: id, updatedAt: now, workModels: catalog.workModels)
        XCTAssertTrue(work.isWork)
        let buckets = ChatGPTChatParser.modelBuckets(turns: [], settings: .init(), complete: true, now: now, catalog: catalog)
        XCTAssertTrue(buckets.contains { $0.id == "sol_pro_daily" })
        XCTAssertNil(buckets.first(where: { $0.id == "sol_pro_daily" })?.quantity?.remaining)
    }

    func testOldTurnsDoNotBlockRecentCoverage() throws {
        let value = try ChatGPTChatParser.conversation(conversation(unfinished: true), id: id, updatedAt: now,
                                                       since: now.addingTimeInterval(-10))
        XCTAssertTrue(value.turns.isEmpty)
        XCTAssertEqual(value.unclassifiedTurns, 0)
    }

    func testProviderTaxonomyIsIndependentOfAgenticAndTokenCosts() {
        XCTAssertEqual(ToolType.chatgptChat.vendorName, "OpenAI")
        XCTAssertEqual(ToolType.chatgptChat.productName, "ChatGPT Chat")
        XCTAssertEqual(ToolType.chatgptChat.coreProviderRepresentative, .codex)
        XCTAssertFalse(ToolType.chatgptChat.supportsTokenCost)
        XCTAssertNil(Harness.defaultHarness(for: .chatgptChat))
        XCTAssertTrue(ToolType.codex.coreProviderMembers.contains(.chatgptChat))
        XCTAssertEqual(MenuBarToken.newQuota(fieldId: "chatgptChat.image_gen").kind, .quota(fieldId: "chatgptChat.image_gen", metric: .displayCount))
    }

    func testTransportAllowlistCannotSendPromptsOrFollowArbitraryURLs() {
        XCTAssertTrue(ChatGPTChatRequestPolicy.allows(path: "/backend-api/conversation/init", method: "POST"))
        XCTAssertTrue(ChatGPTChatRequestPolicy.allows(path: "/backend-api/conversation/" + id, method: "GET"))
        for path in ["https://example.com", "//example.com", "/backend-api/f/conversation", "/backend-api/conversation/WEB:bad", "/backend-api/conversation/../me"] {
            XCTAssertFalse(ChatGPTChatRequestPolicy.allows(path: path, method: "POST"))
            XCTAssertFalse(ChatGPTChatRequestPolicy.allows(path: path, method: "GET"))
        }
    }

    func testCookieTransportRefusesOversizedResponsesBeforeParsing() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OversizedChatReply.self]
        let transport = ChatGPTChatCookieTransport(cookieHeader: "synthetic=fixture", configuration: configuration)
        defer { transport.close() }
        do {
            _ = try await transport.request(path: "/api/auth/session")
            XCTFail("An oversized response must be refused")
        } catch let error as QuotaError {
            guard case .parseFailure = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testAdditiveSettingsAndQuantityRoundTrip() throws {
        let settings = try JSONDecoder().decode(ChatGPTChatSettings.self, from: Data(#"{"enabled":true,"astraWeeklyLimit":200}"#.utf8))
        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.astraWeeklyLimit, 200)
        XCTAssertEqual(settings.solDailyLimit, 0)
        var app = AppSettings.default; app.chatGPTChat = settings
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(app)).chatGPTChat, settings)
        let bucket = QuotaBucket(id: "image_gen", title: "Image Generation", shortLabel: "Image Generation", usedPercent: 0, quantity: .init(remaining: 998))
        XCTAssertEqual(try JSONDecoder().decode(QuotaBucket.self, from: JSONEncoder().encode(bucket)), bucket)
    }

    func testClientPaginatesShortPagesIncludesArchivesAndCachesOnlyMetadata() async throws {
        let second = "WEB:00000000-0000-4000-8000-000000000002"
        let archived = "00000000-0000-4000-8000-000000000003"
        let date = ISO8601DateFormatter().string(from: now)
        let feature = try json(["limits_progress": [["feature_name": "image_gen", "remaining": 998]]])
        let active1 = try json(["items": [["id": id, "update_time": date]], "total": 2])
        let active2 = try json(["items": [["id": second, "update_time": date, "conversation_origin": "flora"]], "total": 2])
        let archives = try json(["items": [["id": archived, "update_time": date]], "total": 1])
        let archivedData = try json(["conversation_id": archived, "default_model_slug": "gpt-5.5-wm", "mapping": [:]])
        let transport = FixtureTransport(responses: [
            "/api/auth/session": try json(["accessToken": "synthetic-token", "user": ["id": "synthetic-account"]]),
            "/backend-api/conversation/init": feature,
            "/backend-api/conversations?offset=0&limit=50&order=updated&is_archived=false&is_starred=false": active1,
            "/backend-api/conversations?offset=1&limit=50&order=updated&is_archived=false&is_starred=false": active2,
            "/backend-api/conversations?offset=0&limit=50&order=updated&is_archived=true&is_starred=false": archives,
            "/backend-api/conversation/" + id: try conversation(),
            "/backend-api/conversation/" + archived: archivedData
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let client = ChatGPTChatClient(transport: transport, store: ChatGPTChatHistoryStore(url: url))
        var settings = ChatGPTChatSettings(); settings.enabled = true; settings.astraWeeklyLimit = 200
        let account = AccountIdentity(id: "local-chat-account", tool: .chatgptChat, source: .webCookie)
        let result = try await client.fetch(account: account, settings: settings, now: now)
        XCTAssertEqual(result.chatGPTChat?.historyComplete, true)
        XCTAssertEqual(result.chatGPTChat?.excludedWorkConversations, 2)
        XCTAssertEqual(result.bucket(id: "astra_weekly")?.quantity?.remaining, 199)
        _ = try await client.fetch(account: account, settings: settings, now: now)
        let calls = await transport.calls
        XCTAssertEqual(calls.filter { $0 == "/backend-api/conversation/" + id }.count, 1)
        XCTAssertFalse(calls.contains("/backend-api/conversation/" + second))
        let persisted = try String(contentsOf: url, encoding: .utf8)
        for forbidden in ["PRIVATE", "synthetic-token", "synthetic-account", "synthetic-message", id] {
            XCTAssertFalse(persisted.contains(forbidden))
        }
    }

    func testClientKeepsFeatureRemaindersWhenHistoryFails() async throws {
        let transport = FixtureTransport(responses: [
            "/api/auth/session": try json(["accessToken": "synthetic-token", "user": ["id": "synthetic-account"]]),
            "/backend-api/conversation/init": try json(["limits_progress": [["feature_name": "deep_research", "remaining": 250]]])
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ChatGPTChatClient(transport: transport, store: ChatGPTChatHistoryStore(url: directory.appendingPathComponent("history.json")))
        var settings = ChatGPTChatSettings(); settings.enabled = true; settings.astraWeeklyLimit = 200
        let result = try await client.fetch(account: AccountIdentity(id: "local-chat-account", tool: .chatgptChat, source: .webCookie), settings: settings, now: now)
        XCTAssertEqual(result.bucket(id: "deep_research")?.quantity?.remaining, 250)
        XCTAssertEqual(result.chatGPTChat?.historyComplete, false)
        XCTAssertNil(result.bucket(id: "astra_weekly")?.quantity?.remaining)
    }
}

private final class OversizedChatReply: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "9000000", "Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor FixtureTransport: ChatGPTChatTransport {
    nonisolated let name = "fixture"
    let responses: [String: Data]
    private(set) var calls: [String] = []
    init(responses: [String: Data]) { self.responses = responses }
    func request(path: String, method: String, bearer: String?, body: Data?) async throws -> Data {
        calls.append(path)
        guard let response = responses[path] else { throw QuotaError.network("fixture failure") }
        return response
    }
}
