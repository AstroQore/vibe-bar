import XCTest
@testable import VibeBarCore

/// `QuotaLimitsCatalog` against the published `limits.json` and the ways a
/// published document can go wrong. Every file lives in a temporary home.
final class QuotaLimitsCatalogTests: XCTestCase {
    /// A verbatim copy of AstroQore/vibebar-quota-limits `limits.json` as
    /// published on 2026-09-23.
    static let published = #"""
{
  "$schema": "./schema.json",
  "schemaVersion": 1,
  "updatedAt": "2026-09-23",
  "allowances": [
    {
      "provider": "chatgptChat",
      "plan": "pro",
      "id": "gpt6_pro_weekly",
      "group": "GPT-6 Astra Pro",
      "title": "Weekly",
      "models": ["gpt-6-pro"],
      "limit": 200,
      "unit": "messages",
      "windowSeconds": 604800,
      "source": "https://help.openai.com/en/articles/20001354",
      "verifiedAt": "2026-09-23"
    },
    {
      "provider": "chatgptChat",
      "plan": "pro",
      "id": "sol_pro_daily",
      "group": "GPT-5.6 Sol Pro",
      "title": "Daily",
      "models": ["gpt-5-6-pro"],
      "limit": 170,
      "unit": "messages",
      "windowSeconds": 86400,
      "source": "https://help.openai.com/en/articles/20001354",
      "verifiedAt": "2026-09-23"
    },
    {
      "provider": "chatgptChat",
      "plan": "pro",
      "id": "pro_daily",
      "group": "Pro Models",
      "title": "Daily",
      "models": ["gpt-6-pro", "gpt-5-6-pro"],
      "limit": 200,
      "unit": "messages",
      "windowSeconds": 86400,
      "source": "https://help.openai.com/en/articles/20001354",
      "verifiedAt": "2026-09-23"
    },
    {
      "provider": "chatgptChat",
      "plan": "prolite",
      "id": "pro_weekly",
      "group": "Pro Models",
      "title": "Weekly",
      "models": ["gpt-6-pro", "gpt-5-6-pro"],
      "limit": 50,
      "unit": "messages",
      "windowSeconds": 604800,
      "source": "https://help.openai.com/en/articles/20001354",
      "verifiedAt": "2026-09-23"
    }
  ]
}
"""#

    private final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> (HTTPURLResponse, Data?))?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let responder = StubURLProtocol.responder else {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let (response, data) = responder(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarQuotaLimitsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        StubURLProtocol.responder = nil
        // Leave the process-wide snapshot unloaded, as a fresh launch has it.
        QuotaLimitsCatalog.resetSnapshot()
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func document(_ rows: [[String: Any]], schemaVersion: Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": schemaVersion, "updatedAt": "2026-09-23", "allowances": rows])
    }

    private func row(provider: String = "chatgptChat", plan: String = "pro", id: String = "extra_daily",
                     models: Any = ["gpt-6-pro"], limit: Any = 10, window: Any = 86_400,
                     unit: String = "messages", group: Any = "Extra", title: Any = "Daily") -> [String: Any] {
        ["provider": provider, "plan": plan, "id": id, "group": group, "title": title, "models": models,
         "limit": limit, "unit": unit, "windowSeconds": window,
         "source": "https://example.com/limits", "verifiedAt": "2026-09-23"]
    }

    func testThePublishedDocumentDecodesToTheBundledTable() throws {
        let table = try XCTUnwrap(QuotaLimitsCatalog.parse(Data(Self.published.utf8)))
        XCTAssertEqual(table.updatedAt, "2026-09-23")
        XCTAssertEqual(table.rowCount, 4)
        XCTAssertEqual(Set(table.chatGPTChat.keys), ["pro", "prolite"])
        for plan in ["pro", "prolite"] {
            XCTAssertEqual(table.chatGPTChat[plan], ChatGPTChatProAllowances.bundled(plan: plan),
                           "the published \(plan) rows are the bundled floor today")
            XCTAssertEqual(ChatGPTChatProAllowances.allowances(plan: plan, table: table),
                           ChatGPTChatProAllowances.bundled(plan: plan))
        }
        XCTAssertTrue(ChatGPTChatProAllowances.allowances(plan: "plus", table: table).isEmpty)
    }

    func testRowsForUnknownProvidersAndMalformedRowsAreSkippedAlone() throws {
        let rows: [[String: Any]] = [
            row(),
            row(provider: "claude", id: "claude_weekly"),
            row(provider: "somethingNew", plan: "team", id: "future_row"),
            row(id: "zero_limit", limit: 0),
            row(id: "string_limit", limit: "200"),
            row(id: "fractional_limit", limit: 1.5),
            row(id: "short_window", window: 600),
            row(id: "bad_slug", models: ["gpt 6 pro"]),
            row(id: "one_bad_slug", models: ["gpt-6-pro", "../pro"]),
            row(id: "no_models", models: [String]()),
            row(id: "tokens", unit: "tokens"),
            row(id: "Bad-Id"),
            row(id: "no_group", group: NSNull()),
            row(id: "blank_title", title: "  "),
            row(plan: "", id: "no_plan"),
            row(id: "extra_daily", limit: 99)
        ]
        var data = try document(rows)
        // A bare value in the list is skipped too.
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        root["allowances"] = (root["allowances"] as! [Any]) + ["not a row", 42]
        data = try JSONSerialization.data(withJSONObject: root)
        let table = try XCTUnwrap(QuotaLimitsCatalog.parse(data))
        XCTAssertEqual(table.rowCount, 1)
        XCTAssertEqual(table.chatGPTChat["pro"]?.map(\.id), ["extra_daily"])
        XCTAssertEqual(table.chatGPTChat["pro"]?.first?.limit, 10, "the first row for an id wins")
    }

    func testABadDocumentFallsBackToTheBundledTable() throws {
        for bad in [Data("not json".utf8), Data("[]".utf8), try document([row()], schemaVersion: 2),
                    Data(#"{"schemaVersion":1,"allowances":{}}"#.utf8), Data(#"{"allowances":[]}"#.utf8), Data()] {
            XCTAssertNil(QuotaLimitsCatalog.parse(bad))
        }
        XCTAssertEqual(ChatGPTChatProAllowances.allowances(plan: "pro", table: nil),
                       ChatGPTChatProAllowances.bundled(plan: "pro"))
        // A plan the published table has no rows for keeps the bundled ones;
        // a plan it does have rows for takes them, whatever the case.
        let table = try XCTUnwrap(QuotaLimitsCatalog.parse(document([row(plan: "prolite", id: "pro_weekly", limit: 60, window: 604_800)])))
        XCTAssertEqual(ChatGPTChatProAllowances.allowances(plan: "ProLite", table: table).map(\.limit), [60])
        XCTAssertEqual(ChatGPTChatProAllowances.allowances(plan: "pro", table: table),
                       ChatGPTChatProAllowances.bundled(plan: "pro"))
        let empty = try XCTUnwrap(QuotaLimitsCatalog.parse(document([])))
        XCTAssertEqual(ChatGPTChatProAllowances.allowances(plan: "pro", table: empty),
                       ChatGPTChatProAllowances.bundled(plan: "pro"))
    }

    func testAFetchedTableIsCachedAndTheCacheServesOffline() async throws {
        var published = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.published.utf8)) as? [String: Any])
        var rows = published["allowances"] as! [[String: Any]]
        rows[0]["limit"] = 250
        published["allowances"] = rows
        let changed = try JSONSerialization.data(withJSONObject: published)
        StubURLProtocol.responder = { request in
            XCTAssertEqual(request.url, QuotaLimitsCatalog.remoteURL)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, changed)
        }
        let first = await QuotaLimitsCatalog.refresh(homeDirectory: home.path, session: session())
        XCTAssertEqual(first, .fetched)
        XCTAssertEqual(QuotaLimitsCatalog.snapshot(homeDirectory: home.path)?.chatGPTChat["pro"]?.first?.limit, 250,
                       "adopted in memory at once")
        let status = QuotaLimitsCatalog.loadStatus(homeDirectory: home.path)
        XCTAssertEqual(status.outcome, .fetched)
        XCTAssertEqual(status.rowCount, 4)
        let again = await QuotaLimitsCatalog.refresh(homeDirectory: home.path, session: session())
        XCTAssertEqual(again, .unchanged)
        let lastGood = QuotaLimitsCatalog.loadStatus(homeDirectory: home.path).lastSuccessAt
        XCTAssertNotNil(lastGood)

        // Offline, and a later launch: the cache answers.
        StubURLProtocol.responder = nil
        let offline = await QuotaLimitsCatalog.refresh(homeDirectory: home.path, session: session())
        XCTAssertEqual(offline, .networkFailure)
        QuotaLimitsCatalog.resetSnapshot()
        let reloaded = QuotaLimitsCatalog.snapshot(homeDirectory: home.path)
        XCTAssertEqual(ChatGPTChatProAllowances.allowances(plan: "pro", table: reloaded).first?.limit, 250)
        XCTAssertEqual(QuotaLimitsCatalog.loadStatus(homeDirectory: home.path).lastSuccessAt, lastGood,
                       "a failed attempt keeps the last success")

        // A broken or oversized publication never replaces the good copy.
        StubURLProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"schemaVersion":9}"#.utf8))
        }
        let broken = await QuotaLimitsCatalog.refresh(homeDirectory: home.path, session: session())
        XCTAssertEqual(broken, .invalidDocument)
        StubURLProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(repeating: 32, count: QuotaLimitsCatalog.maxFetchBytes + 1))
        }
        let oversized = await QuotaLimitsCatalog.refresh(homeDirectory: home.path, session: session())
        XCTAssertEqual(oversized, .oversized)
        StubURLProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        let missing = await QuotaLimitsCatalog.refresh(homeDirectory: home.path, session: session())
        XCTAssertEqual(missing, .networkFailure)
        XCTAssertEqual(QuotaLimitsCatalog.loadCache(homeDirectory: home.path)?.chatGPTChat["pro"]?.first?.limit, 250)
        XCTAssertEqual(QuotaLimitsCatalog.snapshot(homeDirectory: home.path)?.chatGPTChat["pro"]?.first?.limit, 250)
        let attributes = try FileManager.default.attributesOfItem(atPath: QuotaLimitsCatalog.cacheURL(homeDirectory: home.path).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testOnlyHTTPSIsFetched() async {
        StubURLProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(Self.published.utf8))
        }
        let outcome = await QuotaLimitsCatalog.refresh(homeDirectory: home.path, session: session(),
                                                      endpoint: URL(string: "http://example.com/limits.json")!)
        XCTAssertEqual(outcome, .networkFailure)
        XCTAssertNil(QuotaLimitsCatalog.loadCache(homeDirectory: home.path))
    }
}
