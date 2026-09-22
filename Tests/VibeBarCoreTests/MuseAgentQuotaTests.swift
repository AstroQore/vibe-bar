import XCTest
@testable import VibeBarCore

/// Muse (the personal agent at muse.ai) reads its weekly quota from the web
/// app's `fetchSubscriptionAction` server action. The action id changes with
/// every deployment, so it is discovered from the app's public chunks and
/// cached; every network exchange below goes through an injected transport.
final class MuseAgentQuotaTests: XCTestCase {
    // MARK: - Fixtures

    static let actionID = "7f3a9c0e5b2d4f6a8c1e3b5d7f9a0c2e4b6d8f1a"
    static let newActionID = "0011223344556677889900aabbccddeeff001122"

    static func subscriptionRow(
        usage: String = #"{"state":"METERED","percentUsed":1,"resetsAt":1790392306,"quotaStatus":"SUFFICIENT"}"#,
        success: String = "true",
        topup: String = #""topupBalance":0,"topupTotal":0,"topupRowLabel":"Additional tokens","topupRowValueLabel":null"#
    ) -> String {
        #"1:{"success":\#(success),"subscription":{"tier":{"tierId":"hatch_free","name":"Free","tierCode":"HATCH_FREE","isPaid":false,"rank":0},"usage":\#(usage),"statusSubtitle":"Weekly limit resets on Sep 26","usageRowLabel":"Free plan","usageRowValueLabel":"1% used","billingSubtitle":null,\#(topup),"topupEligible":false,"isEligibleToPurchase":null,"entryPointCtaLabel":"Upgrade","managementActions":{"primaryCta":null,"managementRows":[]},"agreement":null}}"#
    }

    static func rsc(_ row: String = subscriptionRow()) -> Data {
        Data(("0:{\"a\":\"$@1\",\"f\":\"\",\"q\":\"\",\"i\":false}\n" + row + "\n").utf8)
    }

    static func chunk(declaring id: String, name: String = "fetchSubscriptionAction") -> String {
        #"(self.webpackChunk=self.webpackChunk||[]).push([[42],{1:(e,t,r)=>{var n=r(7);let o=(0,n.createServerReference)("\#(id)",n.callServer,void 0,n.findSourceMapURL,"\#(name)")}}]);"#
    }

    static let cookie = "hatch_sess=synthetic-session; datr=synthetic-datr"

    // MARK: - Parsing

    func testTheSubscriptionRowBecomesTheWeeklyBucket() throws {
        let snapshot = try MuseAgentSubscriptionParser.parse(data: Self.rsc())
        XCTAssertEqual(snapshot.weekly.id, "weekly")
        XCTAssertEqual(snapshot.weekly.title, "Weekly")
        XCTAssertEqual(snapshot.weekly.usedPercent, 1)
        XCTAssertEqual(snapshot.weekly.resetAt, Date(timeIntervalSince1970: 1_790_392_306))
        XCTAssertEqual(snapshot.weekly.rawWindowSeconds, 604_800)
        XCTAssertEqual(snapshot.tierName, "Free")
        XCTAssertEqual(snapshot.isPaid, false)
        XCTAssertEqual(snapshot.planLabel, "Free")
    }

    /// The subscription is found by content, not by row number, and rows
    /// that are not JSON objects are skipped.
    func testTheRowIsFoundWhereverItIsAndOtherRowsAreSkipped() throws {
        let body = """
        0:{"a":"$@2","f":"","q":"","i":false}
        1:I["123",["static/chunks/abc.js"],"default"]
        not a row at all
        2:T4,abcd
        3:{"unrelated":true}
        4:\(Self.subscriptionRow().dropFirst(2))
        """
        let snapshot = try MuseAgentSubscriptionParser.parse(data: Data(body.utf8))
        XCTAssertEqual(snapshot.weekly.usedPercent, 1)
    }

    /// Nothing metered this week arrives as `usage: null` — 0% with no reset,
    /// the way an idle Muse Code window reads.
    func testANullUsageIsAnIdleWeek() throws {
        let snapshot = try MuseAgentSubscriptionParser.parse(data: Self.rsc(Self.subscriptionRow(usage: "null")))
        XCTAssertEqual(snapshot.weekly.usedPercent, 0)
        XCTAssertNil(snapshot.weekly.resetAt)
        XCTAssertEqual(snapshot.weekly.id, "weekly")
    }

    /// A tier that is not metered reads 0% and keeps whatever reset the
    /// server named.
    func testAnUnmeteredStateReadsAsZero() throws {
        let snapshot = try MuseAgentSubscriptionParser.parse(data: Self.rsc(Self.subscriptionRow(
            usage: #"{"state":"UNLIMITED","resetsAt":1790392306}"#
        )))
        XCTAssertEqual(snapshot.weekly.usedPercent, 0)
        XCTAssertEqual(snapshot.weekly.resetAt, Date(timeIntervalSince1970: 1_790_392_306))
    }

    /// The web app's own fallback: the share of `total` no longer in
    /// `balance`.
    func testAMeteredUsageWithoutAPercentUsesBalanceAndTotal() throws {
        let snapshot = try MuseAgentSubscriptionParser.parse(data: Self.rsc(Self.subscriptionRow(
            usage: #"{"state":"METERED","balance":750,"total":1000,"resetsAt":1790392306}"#
        )))
        XCTAssertEqual(snapshot.weekly.usedPercent, 25, accuracy: 0.0001)
    }

    func testAMeteredUsageWithNoFigureOrABooleanIsRefused() {
        for usage in [
            #"{"state":"METERED","resetsAt":1790392306}"#,
            #"{"state":"METERED","percentUsed":true}"#,
            #""METERED""#
        ] {
            XCTAssertThrowsError(
                try MuseAgentSubscriptionParser.parse(data: Self.rsc(Self.subscriptionRow(usage: usage))),
                usage
            )
        }
    }

    func testAPercentOutsideTheRangeIsClamped() throws {
        let snapshot = try MuseAgentSubscriptionParser.parse(data: Self.rsc(Self.subscriptionRow(
            usage: #"{"state":"METERED","percentUsed":140,"resetsAt":1790392306}"#
        )))
        XCTAssertEqual(snapshot.weekly.usedPercent, 100)
    }

    func testSuccessFalseIsAnError() {
        XCTAssertThrowsError(try MuseAgentSubscriptionParser.parse(data: Self.rsc(Self.subscriptionRow(success: "false"))))
        XCTAssertThrowsError(try MuseAgentSubscriptionParser.parse(
            data: Data("0:{\"a\":\"$@1\"}\n1:{\"success\":false,\"error\":\"nope\"}\n".utf8)
        ))
    }

    func testMalformedBodiesAreParseFailures() {
        for body in ["", "garbage", "0:{\"a\":\"$@1\"}\n", "1:{\"subscription\":", #"{"error":"Forbidden"}"#] {
            XCTAssertThrowsError(try MuseAgentSubscriptionParser.parse(data: Data(body.utf8)), body) { error in
                guard case QuotaError.parseFailure = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testATierWithoutANameIsNamedFromItsCode() {
        XCTAssertEqual(MuseAgentSubscriptionParser.tierName(fromCode: "HATCH_FREE"), "Free")
        XCTAssertEqual(MuseAgentSubscriptionParser.tierName(fromCode: "HATCH_PLUS_ANNUAL"), "Plus Annual")
        XCTAssertNil(MuseAgentSubscriptionParser.tierName(fromCode: nil))
    }

    /// Additional tokens ride on the plan line only while a top-up exists,
    /// in the provider's own words, and never with a localized number.
    func testATopUpIsShownOnThePlanLineOnlyWhenOneIsHeld() throws {
        let held = try MuseAgentSubscriptionParser.parse(data: Self.rsc(Self.subscriptionRow(
            topup: #""topupBalance":1200,"topupTotal":5000,"topupRowLabel":"Additional tokens","topupRowValueLabel":null"#
        )))
        XCTAssertEqual(held.planLabel, "Free · Additional tokens: 1200 / 5000")
        let labelled = try MuseAgentSubscriptionParser.parse(data: Self.rsc(Self.subscriptionRow(
            topup: ##""topupBalance":1200,"topupTotal":5000,"topupRowLabel":"Additional tokens","topupRowValueLabel":"1.2K left""##
        )))
        XCTAssertEqual(labelled.planLabel, "Free · Additional tokens: 1.2K left")
        XCTAssertEqual(try MuseAgentSubscriptionParser.parse(data: Self.rsc()).planLabel, "Free")
        XCTAssertEqual(ProviderPlanDisplay.displayName(for: .museAgent, rawPlan: "Free"), "Muse Free")
        XCTAssertEqual(
            ProviderPlanDisplay.displayName(for: .museAgent, rawPlan: "Free · Additional tokens: 1200 / 5000"),
            "Muse Free · Additional tokens: 1200 / 5000"
        )
    }

    // MARK: - Discovery helpers

    func testChunkNamesAreExtractedInOrderAndUnsafeOnesDropped() {
        let html = """
        <script src="/_next/static/chunks/0_examplechunk.js" async></script>
        <script src="/_next/static/chunks/webpack-1a2b.js"></script>
        <link rel="preload" href="/_next/static/chunks/0_examplechunk.js"/>
        "static/chunks/..%2Fsecret.js" "static/chunks/app/page-9.js" "static/chunks/main-app.js"
        <meta name="deployment" content="dpl_AbC123xyz"/>
        """
        XCTAssertEqual(
            MuseAgentActionDiscovery.chunkNames(in: html),
            ["0_examplechunk.js", "webpack-1a2b.js", "main-app.js"]
        )
        XCTAssertEqual(MuseAgentActionDiscovery.deploymentID(inHTML: html), "dpl_AbC123xyz")
        XCTAssertNil(MuseAgentActionDiscovery.deploymentID(inHTML: "<html></html>"))
        XCTAssertNil(MuseAgentActionDiscovery.chunkURL("../x.js"))
        XCTAssertEqual(
            MuseAgentActionDiscovery.chunkURL("0_examplechunk.js")?.absoluteString,
            "https://muse.ai/_next/static/chunks/0_examplechunk.js"
        )
    }

    func testTheActionIDIsTheOneRegisteredUnderTheActionsName() {
        XCTAssertEqual(MuseAgentActionDiscovery.actionID(inChunk: Self.chunk(declaring: Self.actionID)), Self.actionID)
        XCTAssertNil(MuseAgentActionDiscovery.actionID(
            inChunk: Self.chunk(declaring: Self.actionID, name: "fetchProfileAction")
        ))
        XCTAssertNil(MuseAgentActionDiscovery.actionID(inChunk: "fetchSubscriptionAction but no reference"))
        // Two actions in one chunk: only the named one is taken.
        let both = Self.chunk(declaring: Self.newActionID, name: "fetchProfileAction") + Self.chunk(declaring: Self.actionID)
        XCTAssertEqual(MuseAgentActionDiscovery.actionID(inChunk: both), Self.actionID)
    }

    // MARK: - Response mapping

    func testStatusCodesMapToTheRightStates() throws {
        func http(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
            HTTPURLResponse(url: MuseAgentQuotaAdapter.actionURL, statusCode: status, httpVersion: nil, headerFields: headers)!
        }
        XCTAssertThrowsError(try MuseAgentQuotaAdapter.classify(
            status: 403, headers: http(403), data: Data(#"{"error":"Forbidden"}"#.utf8)
        )) { XCTAssertEqual($0 as? QuotaError, .needsLogin) }
        XCTAssertThrowsError(try MuseAgentQuotaAdapter.classify(
            status: 307, headers: http(307, ["Location": "https://auth.muse.ai/aymh/x"]), data: Data()
        )) { XCTAssertEqual($0 as? QuotaError, .needsLogin) }
        guard case .actionNotFound = try MuseAgentQuotaAdapter.classify(
            status: 404, headers: http(404, ["x-nextjs-action-not-found": "1"]), data: Data()
        ) else { return XCTFail("header") }
        guard case .actionNotFound = try MuseAgentQuotaAdapter.classify(
            status: 404, headers: http(404), data: Data("Server action not found.".utf8)
        ) else { return XCTFail("body") }
        XCTAssertThrowsError(try MuseAgentQuotaAdapter.classify(status: 404, headers: http(404), data: Data("Not Found".utf8)))
        XCTAssertThrowsError(try MuseAgentQuotaAdapter.classify(status: 429, headers: http(429), data: Data())) {
            XCTAssertEqual($0 as? QuotaError, .rateLimited)
        }
        guard case .answered = try MuseAgentQuotaAdapter.classify(status: 200, headers: http(200), data: Self.rsc()) else {
            return XCTFail("200")
        }
    }

    func testTheActionRequestIsTheOneThePageSends() throws {
        let request = MuseAgentQuotaAdapter.makeActionRequest(actionID: Self.actionID, cookieHeader: Self.cookie)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://muse.ai/")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Next-Action"), Self.actionID)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/x-component")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "text/plain;charset=UTF-8")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://muse.ai")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), Self.cookie)
        XCTAssertEqual(request.httpBody, Data("[]".utf8))
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    /// The whole jar is sent, but it has to hold the session cookie.
    func testTheCookieSpecKeepsTheJarAndRequiresTheSession() {
        let spec = MuseAgentQuotaAdapter.cookieSpec
        XCTAssertEqual(spec.minimizedHeader(from: "datr=d; hatch_sess=s; ps_l=1"), "datr=d; hatch_sess=s; ps_l=1")
        XCTAssertNil(spec.minimizedHeader(from: "datr=d; ps_l=1"))
        XCTAssertNil(spec.manualPasteHeader(from: "datr=d"))
        XCTAssertEqual(spec.manualPasteHeader(from: "hatch_sess=s; hatch_gw=g"), "hatch_sess=s; hatch_gw=g")
        XCTAssertEqual(MiscCookieSpecCatalog.spec(for: .museAgent)?.tool, .museAgent)
    }

    // MARK: - Discovery, cache, rediscovery

    func testDiscoveryWalksTwoLevelsOfChunksWithoutSendingTheCookieToThem() async throws {
        let transport = FakeMuseTransport { request in
            switch request.url?.path {
            case "/":
                return (200, [:], Data(#"<script src="/_next/static/chunks/a.js"></script><script src="/_next/static/chunks/b.js"></script> dpl_Demo1"#.utf8))
            case "/_next/static/chunks/a.js":
                return (200, [:], Data(#"x "static/chunks/c.js" y"#.utf8))
            case "/_next/static/chunks/b.js":
                return (200, [:], Data("nothing here".utf8))
            case "/_next/static/chunks/c.js":
                return (200, [:], Data(Self.chunk(declaring: Self.actionID).utf8))
            default:
                return (404, [:], Data())
            }
        }
        let record = try await MuseAgentActionDiscovery(transport: transport).discover(cookieHeader: Self.cookie)
        XCTAssertEqual(record.actionID, Self.actionID)
        XCTAssertEqual(record.deploymentID, "dpl_Demo1")
        let requests = await transport.requests
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Cookie"), Self.cookie)
        for chunk in requests.dropFirst() {
            XCTAssertNil(chunk.value(forHTTPHeaderField: "Cookie"), chunk.url?.path ?? "")
            XCTAssertEqual(chunk.httpMethod, "GET")
        }
    }

    func testDiscoveryIsBoundedAndGivesUp() async throws {
        let names = (0..<50).map { "c\($0).js" }
        let html = names.map { "\"static/chunks/\($0)\"" }.joined(separator: " ")
        let transport = FakeMuseTransport { request in
            request.url?.path == "/" ? (200, [:], Data(html.utf8)) : (200, [:], Data("no action".utf8))
        }
        let limits = MuseAgentActionDiscovery.Limits(concurrency: 20, maxDepth: 2, maxFiles: 10)
        XCTAssertEqual(limits.concurrency, 8)
        do {
            _ = try await MuseAgentActionDiscovery(transport: transport, limits: limits).discover(cookieHeader: Self.cookie)
            XCTFail("expected no action")
        } catch {
            guard case QuotaError.parseFailure = error else { return XCTFail("\(error)") }
        }
        let chunkRequests = await transport.requests.filter { $0.url?.path != "/" }
        XCTAssertLessThanOrEqual(chunkRequests.count, 10)
        let peak = await transport.peakConcurrency
        XCTAssertLessThanOrEqual(peak, 8)
    }

    func testASignedOutHomePageIsALoginError() async {
        let transport = FakeMuseTransport { _ in (307, ["Location": "https://auth.muse.ai/aymh/x"], Data()) }
        do {
            _ = try await MuseAgentActionDiscovery(transport: transport).discover(cookieHeader: Self.cookie)
            XCTFail("expected needsLogin")
        } catch {
            XCTAssertEqual(error as? QuotaError, .needsLogin)
        }
    }

    func testACachedActionIsUsedWithoutDiscovery() async throws {
        let home = try temporaryHome()
        let saved = MuseAgentActionRecord(deploymentID: "dpl_Old", actionID: Self.actionID, discoveredAt: Date(timeIntervalSince1970: 1_790_000_000))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try VibeBarLocalStore.writeData(
            try encoder.encode(saved),
            to: VibeBarLocalStore.museAgentActionURL(homeDirectory: home),
            base: VibeBarLocalStore.baseDirectory(homeDirectory: home)
        )
        let transport = FakeMuseTransport { request in
            request.httpMethod == "POST" ? (200, [:], Self.rsc()) : (500, [:], Data())
        }
        let adapter = MuseAgentQuotaAdapter(transport: transport, resolver: MuseAgentActionResolver(homeDirectory: home))
        let snapshot = try await adapter.fetchSnapshot(cookieHeader: Self.cookie)
        XCTAssertEqual(snapshot.weekly.usedPercent, 1)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Next-Action"), Self.actionID)
    }

    /// A stale id is answered "action not found"; the adapter finds the new
    /// one once, retries, and remembers it on disk.
    func testAnActionNotFoundRediscoversOnceAndRetries() async throws {
        let home = try temporaryHome()
        let transport = FakeMuseTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", _):
                if request.value(forHTTPHeaderField: "Next-Action") == Self.newActionID {
                    return (200, [:], Self.rsc())
                }
                return (404, ["x-nextjs-action-not-found": "1"], Data("Server action not found.".utf8))
            case (_, "/"):
                return (200, [:], Data(#""static/chunks/a.js" dpl_New2"#.utf8))
            case (_, "/_next/static/chunks/a.js"):
                return (200, [:], Data(Self.chunk(declaring: Self.newActionID).utf8))
            default:
                return (404, [:], Data())
            }
        }
        // An id from an older deployment is already cached.
        try seed(home: home, actionID: Self.actionID)
        let fresh = MuseAgentActionResolver(homeDirectory: home)
        let adapter = MuseAgentQuotaAdapter(transport: transport, resolver: fresh)
        let snapshot = try await adapter.fetchSnapshot(cookieHeader: Self.cookie)
        XCTAssertEqual(snapshot.weekly.usedPercent, 1)

        let posts = await transport.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.map { $0.value(forHTTPHeaderField: "Next-Action") }, [Self.actionID, Self.newActionID])
        let current = await fresh.current()
        XCTAssertEqual(current?.actionID, Self.newActionID)
        XCTAssertEqual(current?.deploymentID, "dpl_New2")

        // Persisted: a new resolver on the same home starts from the new id.
        let reloaded = await MuseAgentActionResolver(homeDirectory: home).current()
        XCTAssertEqual(reloaded?.actionID, Self.newActionID)
    }

    /// No cache and no id in the app: the search fails once, and a second
    /// refresh inside the back-off window does not scan again.
    func testAFailedDiscoveryIsThrottled() async throws {
        let home = try temporaryHome()
        let transport = FakeMuseTransport { request in
            request.url?.path == "/" ? (200, [:], Data(#""static/chunks/a.js""#.utf8)) : (200, [:], Data("none".utf8))
        }
        let adapter = MuseAgentQuotaAdapter(transport: transport, resolver: MuseAgentActionResolver(homeDirectory: home))
        do { _ = try await adapter.fetchSnapshot(cookieHeader: Self.cookie); XCTFail("first") } catch {}
        let afterFirst = await transport.requests.count
        do { _ = try await adapter.fetchSnapshot(cookieHeader: Self.cookie); XCTFail("second") } catch {
            guard case QuotaError.parseFailure = error else { return XCTFail("\(error)") }
        }
        let afterSecond = await transport.requests.count
        XCTAssertEqual(afterFirst, afterSecond, "the second refresh must not scan again")
    }

    /// A signed-out session is not the page's fault and must not hold the
    /// next attempt back.
    func testASignedOutDiscoveryIsNotThrottled() async throws {
        let home = try temporaryHome()
        let transport = FakeMuseTransport { _ in (307, ["Location": "https://auth.muse.ai/aymh/x"], Data()) }
        let adapter = MuseAgentQuotaAdapter(transport: transport, resolver: MuseAgentActionResolver(homeDirectory: home))
        for _ in 0..<2 {
            do { _ = try await adapter.fetchSnapshot(cookieHeader: Self.cookie); XCTFail("expected needsLogin") } catch {
                XCTAssertEqual(error as? QuotaError, .needsLogin)
            }
        }
        let count = await transport.requests.count
        XCTAssertEqual(count, 2)
    }

    func testAForbiddenActionIsALoginError() async throws {
        let home = try temporaryHome()
        try seed(home: home, actionID: Self.actionID)
        let transport = FakeMuseTransport { _ in (403, ["Content-Type": "application/json"], Data(#"{"error":"Forbidden"}"#.utf8)) }
        let adapter = MuseAgentQuotaAdapter(transport: transport, resolver: MuseAgentActionResolver(homeDirectory: home))
        do { _ = try await adapter.fetchSnapshot(cookieHeader: Self.cookie); XCTFail("expected needsLogin") } catch {
            XCTAssertEqual(error as? QuotaError, .needsLogin)
        }
    }

    // MARK: - Taxonomy

    func testMuseIsMetaAIsSecondSubProvider() {
        let tool = ToolType.museAgent
        XCTAssertEqual(tool.rawValue, "museAgent")
        XCTAssertEqual(tool.vendorName, "Meta AI")
        XCTAssertEqual(tool.productName, "Muse")
        XCTAssertEqual(tool.quotaSubProviderName(), "Muse")
        XCTAssertEqual(tool.coreProviderRepresentative, .muse)
        XCTAssertEqual(ToolType.muse.coreProviderMembers, [.muse, .museAgent])
        XCTAssertEqual(tool.coreProviderMembers, [.muse, .museAgent])
        XCTAssertTrue(tool.supportsDedicatedCard)
        XCTAssertTrue(tool.isPartialPrimary)
        XCTAssertFalse(tool.isMiscPageProvider)
        XCTAssertFalse(tool.supportsTokenCost)
        XCTAssertFalse(tool.supportsStatusPage)
        XCTAssertFalse(ToolType.costAwareProviders.contains(tool))
        XCTAssertFalse(ToolType.coreProviderRepresentatives.contains(tool))
        XCTAssertEqual(MenuBarFieldCatalog.museAgentFields.map(\.id), ["museAgent.weekly"])
        let weekly = MenuBarFieldCatalog.field(id: "museAgent.weekly")
        XCTAssertEqual(weekly.flatMap(MenuBarFieldCatalog.namingGroupKey(for:)), "museAgent.all-models")
        XCTAssertEqual(Harness.defaultHarness(for: .museAgent), .museAgent)
        XCTAssertEqual(Harness.museAgent.quotaTool, .museAgent)
        XCTAssertEqual(Harness.museAgent.company, .muse)
        XCTAssertEqual(PrimaryProviderRoute.routes(for: .museAgent), [.museAgentBrowserCookies])
    }

    // MARK: - Helpers

    private func temporaryHome() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-agent-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    private func seed(home: String, actionID: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try VibeBarLocalStore.writeData(
            try encoder.encode(MuseAgentActionRecord(deploymentID: nil, actionID: actionID, discoveredAt: Date())),
            to: VibeBarLocalStore.museAgentActionURL(homeDirectory: home),
            base: VibeBarLocalStore.baseDirectory(homeDirectory: home)
        )
    }
}

/// Answers every request from a closure and records what was asked, with the
/// highest number of requests it saw in flight at once.
private actor FakeMuseTransport: MuseAgentHTTPTransport {
    typealias Handler = @Sendable (URLRequest) -> (Int, [String: String], Data)

    private let handler: Handler
    private(set) var requests: [URLRequest] = []
    private var inFlight = 0
    private(set) var peakConcurrency = 0

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        inFlight += 1
        peakConcurrency = max(peakConcurrency, inFlight)
        // Let other chunk reads start, so the concurrency cap is observable.
        await Task.yield()
        inFlight -= 1
        let (status, headers, data) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        return (data, response)
    }
}
