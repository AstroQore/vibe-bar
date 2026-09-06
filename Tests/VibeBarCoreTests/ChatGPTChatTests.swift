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

    func testFirstReadGivesAnEstimatedTotalAndThreeResetsConfirmIt() {
        var learning = ChatGPTChatAllowanceLearning()
        // Day one: the remainder is the estimate, marked as one, with the
        // service's own distance to the reset as the window.
        let first = learning.observe(sample(998, at: 0, reset: 86_400 - 120))
        XCTAssertEqual(first.limit, 998)
        XCTAssertEqual(first.used, 0)
        XCTAssertTrue(first.isEstimated)
        XCTAssertEqual(first.usedPercent, 0)
        XCTAssertEqual(learning.windowSeconds(for: sample(998, at: 0, reset: 86_400 - 120)), 86_400)
        XCTAssertNil(learning.learnedWindowSeconds)
        XCTAssertTrue(cycle(1, total: 1000, learning: &learning).isEstimated)
        XCTAssertTrue(cycle(2, total: 1000, learning: &learning).isEstimated)
        let confirmed = cycle(3, total: 1000, learning: &learning)
        XCTAssertEqual(confirmed.limit, 1000)
        XCTAssertFalse(confirmed.isEstimated)
        let used = learning.observe(sample(998, at: 259_230, reset: 345_600))
        XCTAssertEqual(used.used, 2)
        XCTAssertEqual(used.usedPercent!, 0.2, accuracy: 0.0001)
        XCTAssertFalse(used.isEstimated)
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
        // The estimate never drops below a remainder that was seen.
        XCTAssertEqual(cycle(2, total: 900, learning: &learning).limit, 1000)
        XCTAssertTrue(cycle(2, total: 900, learning: &learning).isEstimated)
        XCTAssertEqual(learning.matchingResets, 1)
        XCTAssertTrue(cycle(3, total: 900, learning: &learning).isEstimated)
        let confirmed = cycle(4, total: 900, learning: &learning)
        XCTAssertEqual(confirmed.limit, 900)
        XCTAssertFalse(confirmed.isEstimated)
        XCTAssertTrue(cycle(5, total: 800, learning: &learning).isEstimated)
    }

    func testMovingUnusedResetAndRepeatedReadsNeverCreateConfidence() {
        var learning = ChatGPTChatAllowanceLearning()
        for n in 0..<200 {
            let now = Double(n) * 60
            let quantity = learning.observe(sample(1000, at: now, reset: now + 86_400))
            XCTAssertEqual(quantity.limit, 1000)
            XCTAssertTrue(quantity.isEstimated)
        }
        XCTAssertEqual(learning.matchingResets, 0)
        XCTAssertNil(learning.learnedWindowSeconds)
    }

    func testMissedBoundaryAndUnexpectedIncreaseInvalidateLearnedTotal() {
        var learning = ChatGPTChatAllowanceLearning()
        for n in 1...3 { _ = cycle(n, total: 1000, learning: &learning) }
        XCTAssertFalse(learning.isConfirmed == false)
        // More than the confirmed total: the total was larger, so the
        // confirmation goes and the larger figure becomes the estimate.
        let raised = learning.observe(sample(1200, at: 259_230, reset: 345_600))
        XCTAssertEqual(raised.limit, 1200)
        XCTAssertTrue(raised.isEstimated)
        XCTAssertFalse(learning.isConfirmed)
        for n in 4...6 { _ = cycle(n, total: 1200, learning: &learning) }
        XCTAssertTrue(learning.isConfirmed)
        // A missed boundary drops the confirmation, not the estimate.
        let missed = learning.observe(sample(1190, at: 604_801, reset: 691_200))
        XCTAssertEqual(missed.limit, 1200)
        XCTAssertTrue(missed.isEstimated)
    }

    func testProvisionalWindowRoundsToWholeDaysOrHours() {
        XCTAssertEqual(ChatGPTChatAllowanceLearning.provisionalWindow(resetAt: base.addingTimeInterval(29 * 86_400 + 23 * 3_600), observedAt: base), 30 * 86_400)
        XCTAssertEqual(ChatGPTChatAllowanceLearning.provisionalWindow(resetAt: base.addingTimeInterval(23 * 3_600 + 58 * 60), observedAt: base), 86_400)
        XCTAssertEqual(ChatGPTChatAllowanceLearning.provisionalWindow(resetAt: base.addingTimeInterval(4 * 3_600 + 50 * 60), observedAt: base), 5 * 3_600)
        XCTAssertNil(ChatGPTChatAllowanceLearning.provisionalWindow(resetAt: base.addingTimeInterval(-1), observedAt: base))
        XCTAssertNil(ChatGPTChatAllowanceLearning.provisionalWindow(resetAt: nil, observedAt: base))
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
            XCTAssertEqual(values["image_gen"]?.quantity.limit, 1000)
            XCTAssertEqual(values["image_gen"]?.quantity.isEstimated, n != 3)
        }
        // A plan change starts over: the estimate is this plan's own first read.
        for (i, plan) in ["prolite", "pro"].enumerated() {
            let result = try await store.observe(localAccount: "local", identity: identity, plan: plan, samples: [sample(500, at: 259_230 + Double(i), reset: 345_600)])
            XCTAssertEqual(result["image_gen"]?.quantity.limit, 500)
            XCTAssertEqual(result["image_gen"]?.quantity.isEstimated, true)
        }
        // A read that could not name the plan keeps what is known.
        let unnamed = try await store.observe(localAccount: "local", identity: identity, plan: nil, samples: [sample(400, at: 259_240, reset: 345_600)])
        XCTAssertEqual(unnamed["image_gen"]?.quantity.limit, 500)
        XCTAssertEqual(unnamed["image_gen"]?.quantity.used, 100)
        let text = try String(contentsOf: directory.appendingPathComponent("learning.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("synthetic-user"))
        let reloaded = ChatGPTChatAllowanceStore(url: directory.appendingPathComponent("learning.json"))
        let result = try await reloaded.observe(localAccount: "local", identity: ChatGPTChatParser.identity("another-user"), plan: "pro", samples: [sample(300, at: 259_250, reset: 345_600)])
        XCTAssertEqual(result["image_gen"]?.quantity.limit, 300)
        XCTAssertEqual(result["image_gen"]?.quantity.used, 0)
    }

    func testClientReusesPlanEndpointAndReadsHistoryOnlyWhenAsked() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = ChatFixtureTransport()
        let client = ChatGPTChatClient(transport: transport, store: ChatGPTChatAllowanceStore(url: directory.appendingPathComponent("learning.json")),
                                       historyStore: ChatGPTChatHistoryStore(url: directory.appendingPathComponent("history.json")))
        var featuresOnly = ChatGPTChatSettings()
        featuresOnly.trackProModels = false
        let quota = try await client.fetch(account: AccountIdentity(id: "local", tool: .chatgptChat, source: .webCookie), settings: featuresOnly, now: base)
        XCTAssertEqual(quota.plan, "prolite")
        XCTAssertEqual(quota.buckets.map(\.id), ["image_gen", "deep_research"])
        XCTAssertTrue(quota.buckets.allSatisfy { $0.hasPercentage && $0.quantity?.isEstimated == true },
                      "the first read already shows an estimated percentage")
        XCTAssertEqual(quota.buckets.first?.quantity?.limit, 998)
        XCTAssertNil(quota.chatGPTChat?.history)
        let calls = await transport.calls
        XCTAssertEqual(calls, ["/api/auth/session", "/backend-api/wham/usage", "/backend-api/conversation/init"])
        XCTAssertFalse(ChatGPTChatRequestPolicy.allows(path: "/backend-api/models", method: "GET"))

        // Asked to count Pro messages, the same client walks the saved list
        // and gets the plan's shared weekly allowance, complete at zero.
        let settings = ChatGPTChatSettings()
        XCTAssertTrue(settings.trackProModels, "counting Pro messages is the default")
        let counted = try await client.fetch(account: AccountIdentity(id: "local", tool: .chatgptChat, source: .webCookie), settings: settings, now: base)
        XCTAssertEqual(counted.buckets.map(\.id), ["image_gen", "deep_research", "pro_weekly"])
        let pro = try XCTUnwrap(counted.buckets.last)
        XCTAssertEqual(pro.quantity?.used, 0)
        XCTAssertEqual(pro.quantity?.remaining, 50)
        XCTAssertEqual(pro.quantity?.limit, 50)
        XCTAssertTrue(pro.hasPercentage)
        XCTAssertEqual(pro.rawWindowSeconds, 7 * 86_400)
        XCTAssertEqual(pro.groupTitle, "Pro Models")
        XCTAssertEqual(pro.title, "Weekly")
        XCTAssertEqual(counted.chatGPTChat?.history?.complete, true)
        let later = await transport.calls
        XCTAssertEqual(later.filter { $0.hasPrefix("/backend-api/conversations?") }.count, 2)
    }

    // MARK: - Pro models

    private func conversationData(id: String, origin: String? = nil, defaultModel: String? = nil, nodes: [[String: Any]]) throws -> Data {
        var mapping: [String: Any] = ["root": ["id": "root", "message": NSNull(), "parent": NSNull()]]
        for node in nodes { mapping[node["id"] as! String] = node }
        var root: [String: Any] = ["conversation_id": id, "mapping": mapping]
        if let origin { root["conversation_origin"] = origin }
        if let defaultModel { root["default_model_slug"] = defaultModel }
        return try JSONSerialization.data(withJSONObject: root)
    }

    private func node(_ id: String, parent: String, role: String, at: TimeInterval, model: String? = nil,
                      type: String = "text", recipient: String = "all", status: String = "finished_successfully") -> [String: Any] {
        var metadata: [String: Any] = ["request_id": "req-" + id]
        if let model { metadata["model_slug"] = model; metadata["resolved_model_slug"] = model }
        return ["id": id, "parent": parent, "message": [
            "id": "msg-" + id, "author": ["role": role], "create_time": base.timeIntervalSince1970 + at,
            "status": status, "recipient": recipient, "content": ["content_type": type, "parts": ["secret body " + id]],
            "metadata": metadata]]
    }

    func testConversationChargesEachUserTurnToItsFinalAnswerOnce() throws {
        let data = try conversationData(id: "c1", nodes: [
            node("u1", parent: "root", role: "user", at: 100),
            node("t1", parent: "u1", role: "tool", at: 101, model: "gpt-6-pro"),
            node("a1-thoughts", parent: "t1", role: "assistant", at: 105, model: "gpt-6-pro", type: "thoughts"),
            node("a1", parent: "a1-thoughts", role: "assistant", at: 110, model: "gpt-6-pro"),
            node("a1-retry", parent: "t1", role: "assistant", at: 120, model: "gpt-6-pro"),
            node("u2", parent: "a1", role: "user", at: 200),
            node("a2", parent: "u2", role: "assistant", at: 210, model: "gpt-5-6-thinking", type: "multimodal_text"),
            node("u-old", parent: "a2", role: "user", at: 20),
            node("a-old", parent: "u-old", role: "assistant", at: 25, model: "gpt-6-pro"),
            node("u3", parent: "a-old", role: "user", at: 300),
            node("a3", parent: "u3", role: "assistant", at: 305, model: "gpt-6-pro", status: "in_progress")
        ])
        let parsed = try ChatGPTChatParser.conversation(data, id: "c1", updatedAt: base, since: base.addingTimeInterval(60))
        XCTAssertFalse(parsed.isWork)
        XCTAssertEqual(parsed.turns.count, 2, "a retried answer and a turn before the window add nothing")
        XCTAssertEqual(Set(parsed.turns.map(\.model)), ["gpt-6-pro", "gpt-5-6-thinking"])
        XCTAssertEqual(parsed.unclassifiedTurns, 1, "an unanswered turn is reported, not guessed")
        for turn in parsed.turns {
            XCTAssertFalse(turn.id.contains("msg-"), "turn ids are hashed")
            XCTAssertFalse(turn.id.contains("secret"))
        }
        let encoded = String(decoding: try JSONEncoder().encode(parsed), as: UTF8.self)
        XCTAssertFalse(encoded.contains("secret body"), "no message text is retained")
        XCTAssertThrowsError(try ChatGPTChatParser.conversation(data, id: "other", updatedAt: base, since: base))
    }

    func testWorkConversationsAndWorkModelsAreNeverChargedToChat() throws {
        let work = try conversationData(id: "w1", origin: "tpp", nodes: [
            node("u1", parent: "root", role: "user", at: 100),
            node("a1", parent: "u1", role: "assistant", at: 110, model: "gpt-6-pro")
        ])
        let parsedWork = try ChatGPTChatParser.conversation(work, id: "w1", updatedAt: base, since: base)
        XCTAssertTrue(parsedWork.isWork)
        XCTAssertTrue(parsedWork.turns.isEmpty)

        let mixed = try conversationData(id: "m1", nodes: [
            node("u1", parent: "root", role: "user", at: 100),
            node("a1", parent: "u1", role: "assistant", at: 110, model: "gpt-6-astra-wm"),
            node("u2", parent: "a1", role: "user", at: 200),
            node("a2", parent: "u2", role: "assistant", at: 210, model: "gpt-5-6-pro")
        ])
        let parsedMixed = try ChatGPTChatParser.conversation(mixed, id: "m1", updatedAt: base, since: base)
        XCTAssertEqual(parsedMixed.turns.map(\.model), ["gpt-5-6-pro"])
        XCTAssertEqual(parsedMixed.unclassifiedTurns, 0)

        XCTAssertTrue(ChatGPTChatParser.isWork(origin: "flora", model: nil))
        XCTAssertTrue(ChatGPTChatParser.isWork(origin: nil, model: "gpt-5.6-sol-wm"))
        XCTAssertFalse(ChatGPTChatParser.isWork(origin: nil, model: "gpt-6-pro"))
    }

    func testModelLimitsFollowTheClientSchemaAndDropExpiredEntries() throws {
        let future = ISO8601DateFormatter().string(from: base.addingTimeInterval(3_600))
        let past = ISO8601DateFormatter().string(from: base.addingTimeInterval(-3_600))
        let data = Data("""
        {"model_limits":[
          {"model_slug":"gpt-6-pro","resets_after":"\(future)","using_default_model_slug":"gpt-5-6-thinking","description":null},
          {"model_slug":"gpt-5-6-pro","resets_after":"\(past)","using_default_model_slug":"gpt-5-6-thinking"},
          {"resets_after":"\(future)"}
        ],"limits_progress":[]}
        """.utf8)
        let limits = ChatGPTChatParser.modelLimits(data, now: base)
        XCTAssertEqual(limits.map(\.model), ["gpt-6-pro"])
        XCTAssertEqual(limits.first?.resetsAt, base.addingTimeInterval(3_600))
        XCTAssertEqual(limits.first?.fallbackModel, "gpt-5-6-thinking")
        XCTAssertTrue(ChatGPTChatParser.modelLimits(Data("{}".utf8), now: base).isEmpty)
    }

    func testProAllowancesFollowThePublishedPlanTable() {
        let pro = ChatGPTChatProAllowances.allowances(plan: "pro")
        XCTAssertEqual(pro.map(\.id), ["gpt6_pro_weekly", "sol_pro_daily", "pro_daily"])
        XCTAssertEqual(pro.map(\.group), ["GPT-6 Astra Pro", "GPT-5.6 Sol Pro", "Pro Models"])
        XCTAssertEqual(pro.map(\.title), ["Weekly", "Daily", "Daily"])
        XCTAssertEqual(pro.map(\.limit), [200, 170, 200])
        XCTAssertEqual(pro.map(\.windowSeconds), [7 * 86_400, 86_400, 86_400])
        XCTAssertEqual(pro[0].models, ["gpt-6-pro"])
        XCTAssertEqual(pro[1].models, ["gpt-5-6-pro"])
        XCTAssertEqual(pro[2].models, ["gpt-6-pro", "gpt-5-6-pro"])
        let lite = ChatGPTChatProAllowances.allowances(plan: "prolite")
        XCTAssertEqual(lite.map(\.id), ["pro_weekly"])
        XCTAssertEqual(lite.first?.limit, 50)
        XCTAssertEqual(lite.first?.models, ["gpt-6-pro", "gpt-5-6-pro"])
        XCTAssertTrue(ChatGPTChatProAllowances.allowances(plan: "plus").isEmpty)
        XCTAssertTrue(ChatGPTChatProAllowances.allowances(plan: nil).isEmpty)
        let ids = Set(MenuBarFieldCatalog.chatGPTChatFields.map(\.bucketId))
        for allowance in pro + lite { XCTAssertTrue(ids.contains(allowance.id), allowance.id) }
    }

    func testProBucketsCountATrailingWindowAndHonourServiceThrottles() {
        func turn(_ model: String, ago: TimeInterval) -> ChatGPTChatTurn {
            ChatGPTChatTurn(id: "\(model)-\(ago)", createdAt: base.addingTimeInterval(-ago), model: model)
        }
        let turns = [
            turn("gpt-6-pro", ago: 3_600), turn("gpt-6-pro", ago: 3 * 86_400), turn("gpt-6-pro", ago: 7 * 86_400 - 1),
            turn("gpt-6-pro", ago: 8 * 86_400),
            turn("gpt-5-6-pro", ago: 600), turn("gpt-5-6-pro", ago: 7_200), turn("gpt-5-6-pro", ago: 2 * 86_400),
            turn("gpt-5-6-thinking", ago: 60)
        ] + [turn("gpt-5-6-pro", ago: 600)]
        let pro = ChatGPTChatProAllowances.allowances(plan: "pro")
        let buckets = ChatGPTChatParser.proBuckets(allowances: pro, turns: turns, limits: [], complete: true, now: base)
        XCTAssertEqual(buckets.map(\.id), ["gpt6_pro_weekly", "sol_pro_daily", "pro_daily"])
        XCTAssertEqual(buckets.map(\.groupTitle), ["GPT-6 Astra Pro", "GPT-5.6 Sol Pro", "Pro Models"],
                       "the model is the group header, the window the row, as Codex's Spark lanes are drawn")
        XCTAssertEqual(buckets.map(\.title), ["Weekly", "Daily", "Daily"])
        XCTAssertEqual(buckets[0].quantity?.used, 3)
        XCTAssertEqual(buckets[0].quantity?.remaining, 197)
        XCTAssertEqual(buckets[0].usedPercent, 1.5)
        XCTAssertEqual(buckets[1].quantity?.used, 2, "a duplicate turn id counts once")
        XCTAssertEqual(buckets[1].quantity?.remaining, 168)
        XCTAssertEqual(buckets[2].quantity?.used, 3)
        XCTAssertNil(buckets[0].resetAt, "no window start is known, so no reset is claimed")
        XCTAssertTrue(buckets.allSatisfy { $0.quantity?.isEstimated == true && $0.hasPercentage })

        let partial = ChatGPTChatParser.proBuckets(allowances: pro, turns: turns, limits: [], complete: false, now: base)
        XCTAssertEqual(partial[0].quantity?.used, 3)
        XCTAssertNil(partial[0].quantity?.remaining)
        XCTAssertFalse(partial[0].hasPercentage, "a partial count is not a percentage")

        let reset = base.addingTimeInterval(5 * 3_600)
        let oneLimited = ChatGPTChatParser.proBuckets(allowances: pro, turns: turns,
            limits: [ChatGPTChatModelLimit(model: "gpt-6-pro", resetsAt: reset, fallbackModel: "gpt-5-6-thinking")], complete: false, now: base)
        XCTAssertEqual(oneLimited[0].quantity?.used, 200)
        XCTAssertEqual(oneLimited[0].quantity?.remaining, 0)
        XCTAssertEqual(oneLimited[0].usedPercent, 100)
        XCTAssertEqual(oneLimited[0].resetAt, reset)
        XCTAssertTrue(oneLimited[0].hasPercentage, "the service's exhausted state needs no history")
        XCTAssertEqual(oneLimited[2].quantity?.used, 3, "one throttled model does not exhaust a shared allowance")
        XCTAssertNil(oneLimited[2].resetAt)

        let bothLimited = ChatGPTChatParser.proBuckets(allowances: pro, turns: turns, limits: [
            ChatGPTChatModelLimit(model: "gpt-6-pro", resetsAt: reset, fallbackModel: nil),
            ChatGPTChatModelLimit(model: "gpt-5-6-pro", resetsAt: base.addingTimeInterval(3_600), fallbackModel: nil)
        ], complete: true, now: base)
        XCTAssertEqual(bothLimited[2].quantity?.remaining, 0)
        XCTAssertEqual(bothLimited[2].resetAt, reset)
    }

    func testRequestPolicyAdmitsOnlyTheHistoryReadsTheCounterMakes() {
        let detail = "/backend-api/conversation/00000000-0000-4000-8000-000000000000"
        XCTAssertTrue(ChatGPTChatRequestPolicy.allows(path: "/backend-api/conversations?offset=0&limit=50&order=updated&is_archived=false", method: "GET"))
        XCTAssertTrue(ChatGPTChatRequestPolicy.allows(path: "/backend-api/conversations", method: "GET"))
        XCTAssertTrue(ChatGPTChatRequestPolicy.allows(path: detail, method: "GET"))
        for path in ["/backend-api/conversations?search=secret", "/backend-api/conversations/other",
                     detail + "?x=1", "/backend-api/conversation/not-a-uuid", "/backend-api/conversation/",
                     "/backend-api/models", "/backend-api/conversation/00000000-0000-4000-8000-000000000000/share"] {
            XCTAssertFalse(ChatGPTChatRequestPolicy.allows(path: path, method: "GET"), path)
        }
        XCTAssertFalse(ChatGPTChatRequestPolicy.allows(path: "/backend-api/conversations", method: "POST"))
        XCTAssertFalse(ChatGPTChatRequestPolicy.allows(path: detail, method: "DELETE"))
    }

    func testHistoryReaderFetchesAChangedConversationOnceAndReportsCoverage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatGPTChatHistoryStore(url: directory.appendingPathComponent("history.json"))
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let chat = "11111111-1111-4111-8111-111111111111"
        let work = "22222222-2222-4222-8222-222222222222"
        let stale = "33333333-3333-4333-8333-333333333333"
        func list(chatUpdated: Date) -> Data {
            let items: [[String: Any]] = [
                ["id": chat, "update_time": iso.string(from: chatUpdated), "conversation_origin": NSNull(), "is_temporary_chat": false],
                ["id": work, "update_time": iso.string(from: base.addingTimeInterval(-7_200)), "conversation_origin": "tpp"],
                ["id": stale, "update_time": iso.string(from: base.addingTimeInterval(-9 * 86_400)), "conversation_origin": NSNull()]
            ]
            return try! JSONSerialization.data(withJSONObject: ["items": items, "total": 3, "limit": 50, "offset": 0])
        }
        let empty = Data(#"{"items":[],"total":0,"limit":50,"offset":0}"#.utf8)
        let detail = try conversationData(id: chat, nodes: [
            node("u1", parent: "root", role: "user", at: -3_600),
            node("a1", parent: "u1", role: "assistant", at: -3_500, model: "gpt-6-pro")
        ])
        let transport = HistoryFixtureTransport(responses: [
            "/backend-api/conversations?offset=0&limit=50&order=updated&is_archived=false": list(chatUpdated: base.addingTimeInterval(-3_500)),
            "/backend-api/conversations?offset=0&limit=50&order=updated&is_archived=true": empty,
            "/backend-api/conversation/" + chat: detail
        ])
        let reader = ChatGPTChatHistoryReader(transport: transport, store: store)

        let first = await reader.read(bearer: nil, identity: "acct", now: base)
        XCTAssertEqual(first.turns.map(\.model), ["gpt-6-pro"])
        XCTAssertTrue(first.summary.complete)
        XCTAssertEqual(first.summary.conversationsRead, 1)
        XCTAssertEqual(first.summary.excludedWorkConversations, 1)
        XCTAssertEqual(first.summary.failedConversations, 0)
        XCTAssertEqual(first.summary.observedFrom, base.addingTimeInterval(-7 * 86_400))
        var calls = await transport.calls
        XCTAssertEqual(calls.filter { $0.hasPrefix("/backend-api/conversation/") }, ["/backend-api/conversation/" + chat],
                       "a Work row and a row older than the window are never fetched")

        // Unchanged revision: the cache answers and the transcript is not read again.
        let second = await reader.read(bearer: nil, identity: "acct", now: base.addingTimeInterval(600))
        XCTAssertEqual(second.turns.count, 1)
        XCTAssertTrue(second.summary.complete)
        calls = await transport.calls
        XCTAssertEqual(calls.filter { $0.hasPrefix("/backend-api/conversation/") }.count, 1)

        // A new revision is fetched again; a failed fetch leaves the count marked partial.
        await transport.set("/backend-api/conversations?offset=0&limit=50&order=updated&is_archived=false", list(chatUpdated: base.addingTimeInterval(-100)))
        await transport.set("/backend-api/conversation/" + chat, nil)
        let third = await reader.read(bearer: nil, identity: "acct", now: base.addingTimeInterval(1_200))
        XCTAssertFalse(third.summary.complete)
        XCTAssertEqual(third.summary.failedConversations, 1)
        XCTAssertEqual(third.turns.count, 1, "the cached turns still count while the new revision is unread")
        calls = await transport.calls
        XCTAssertEqual(calls.filter { $0.hasPrefix("/backend-api/conversation/") }.count, 2)

        let cached = String(decoding: try Data(contentsOf: directory.appendingPathComponent("history.json")), as: UTF8.self)
        XCTAssertFalse(cached.contains("secret body"))
        XCTAssertFalse(cached.contains(chat), "conversation ids are hashed at rest")
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
        // A file from before the defaults changed takes them once — both
        // switches on — whatever it said; its old model-tracking keys are dropped.
        let legacy = try JSONDecoder().decode(ChatGPTChatSettings.self, from: Data(#"{"enabled":false,"includeHistory":false,"astraWeeklyLimit":200}"#.utf8))
        XCTAssertTrue(legacy.enabled)
        XCTAssertTrue(legacy.trackProModels)
        XCTAssertEqual(legacy.defaultsVersion, ChatGPTChatSettings.currentDefaultsVersion)
        let data = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        XCTAssertEqual(Set(data.keys), ["enabled", "trackProModels", "defaultsVersion"])
        // A choice made under the current defaults is kept.
        let chosen = try JSONDecoder().decode(ChatGPTChatSettings.self, from: Data(#"{"enabled":false,"trackProModels":false,"defaultsVersion":1}"#.utf8))
        XCTAssertFalse(chosen.enabled)
        XCTAssertFalse(chosen.trackProModels)
        XCTAssertTrue(ChatGPTChatSettings().enabled)
        XCTAssertTrue(ChatGPTChatSettings().trackProModels)
        XCTAssertEqual(MenuBarFieldCatalog.chatGPTChatFields.count, 6)
        XCTAssertEqual(ToolType.codex.coreProviderMembers.first, .chatgptChat)
    }
}

private actor HistoryFixtureTransport: ChatGPTChatTransport {
    nonisolated let name = "history-fixture"
    private(set) var calls: [String] = []
    private var responses: [String: Data]
    init(responses: [String: Data]) { self.responses = responses }
    func set(_ path: String, _ data: Data?) { responses[path] = data }
    func request(path: String, method: String, bearer: String?, body: Data?) async throws -> Data {
        calls.append(path)
        guard let data = responses[path] else { throw QuotaError.network("fixture has no \(path)") }
        return data
    }
}

private actor ChatFixtureTransport: ChatGPTChatTransport {
    nonisolated let name = "fixture"
    private(set) var calls: [String] = []
    func request(path: String, method: String, bearer: String?, body: Data?) async throws -> Data {
        calls.append(path)
        if path.hasPrefix("/backend-api/conversations?") { return Data(#"{"items":[],"total":0,"limit":50,"offset":0}"#.utf8) }
        switch path {
        case "/api/auth/session": return Data(#"{"accessToken":"synthetic-token","user":{"id":"synthetic-user"}}"#.utf8)
        case "/backend-api/wham/usage": return Data(#"{"plan_type":"prolite"}"#.utf8)
        case "/backend-api/conversation/init": return Data(#"{"limits_progress":[{"feature_name":"image_gen","remaining":998},{"feature_name":"deep_research","remaining":250}]}"#.utf8)
        default: throw QuotaError.parseFailure("Unexpected endpoint")
        }
    }
}
