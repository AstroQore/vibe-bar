import XCTest
@testable import VibeBarCore

/// The X Subscription surfaces on the Grok card: the credits-format billing
/// JSON (pool split + unified flag), grok.com's subscription list (the plan
/// actually bought) and the adapter's composition of both into buckets and
/// a plan label. Every payload is synthetic; nothing leaves the process.
final class GrokXSubscriptionTests: XCTestCase {
    // MARK: - Credits billing JSON

    private static let creditsPayload = #"""
    {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-10-08T19:27:46.187121+00:00","end":"2026-10-15T19:27:46.187121+00:00"},"creditUsagePercent":61.0,"onDemandCap":{"val":0},"onDemandUsed":{"val":0},"productUsage":[{"product":"GrokBuild","usagePercent":60.0},{"product":"GrokChat","usagePercent":1.0}],"isUnifiedBillingUser":true,"prepaidBalance":{"val":0},"topUpMethod":"TOP_UP_METHOD_SAVED_PAYMENT_METHOD","billingPeriodStart":"2026-10-08T19:27:46.187121+00:00","billingPeriodEnd":"2026-10-15T19:27:46.187121+00:00"}}
    """#

    func testCreditsBillingParsesPoolSplitAndUnifiedFlag() throws {
        let snapshot = try GrokCreditsBillingFetcher.parse(Data(Self.creditsPayload.utf8))
        XCTAssertEqual(snapshot.usedPercent, 61)
        XCTAssertTrue(snapshot.isUnifiedBillingUser)
        XCTAssertEqual(snapshot.productUsage, [
            .init(product: "GrokBuild", usedPercent: 60),
            .init(product: "GrokChat", usedPercent: 1)
        ])
        // Six fractional digits are trimmed, not rejected.
        XCTAssertEqual(try XCTUnwrap(snapshot.periodStart).timeIntervalSince1970, 1_791_487_666.187, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.periodEnd).timeIntervalSince1970, 1_792_092_466.187, accuracy: 0.001)
    }

    func testCreditsBillingTreatsLegacyMonthlyShapeAsEmptyEnrichment() throws {
        // Without `format=credits` the endpoint answers the pre-bundle
        // monthly shape; it must decode to "nothing to add", not throw.
        let legacy = #"{"config":{"monthlyLimit":{"val":0},"used":{"val":0},"billingPeriodStart":"2026-10-01T00:00:00+00:00","billingPeriodEnd":"2026-11-01T00:00:00+00:00","history":[]}}"#
        let snapshot = try GrokCreditsBillingFetcher.parse(Data(legacy.utf8))
        XCTAssertNil(snapshot.usedPercent)
        XCTAssertTrue(snapshot.productUsage.isEmpty)
        XCTAssertFalse(snapshot.isUnifiedBillingUser)
        XCTAssertNotNil(snapshot.periodEnd)
    }

    func testCreditsBillingFetchSendsBearerAndIsSilentOnRefusal() async throws {
        let session = Self.stubSession()
        let endpoint = URL(string: "https://grok-proxy.test/v1/billing?format=credits")!

        GrokXStubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.query, "format=credits")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer xai-test-token")
            XCTAssertEqual(request.httpShouldHandleCookies, false)
            return (Self.response(request, status: 200, type: "application/json"), Data(Self.creditsPayload.utf8))
        }
        let snapshot = await GrokCreditsBillingFetcher.fetch(
            credentials: Self.credentials(), session: session, endpoint: endpoint)
        XCTAssertEqual(snapshot?.productUsage.count, 2)

        GrokXStubURLProtocol.handler = { request in
            (Self.response(request, status: 401, type: "text/plain"), Data("unauthorized".utf8))
        }
        let refused = await GrokCreditsBillingFetcher.fetch(
            credentials: Self.credentials(), session: session, endpoint: endpoint)
        XCTAssertNil(refused, "A refused enrichment call answers nil, never throws")
    }

    // MARK: - Subscriptions

    private static let subscriptionsPayload = #"""
    {"subscriptions":[
      {"xaiUserId":"00000000-0000-4000-8000-000000000001","tier":"SUBSCRIPTION_TIER_SUPER_GROK_PRO","status":"SUBSCRIPTION_STATUS_ACTIVE","createTime":"2026-10-14T06:47:23.984030Z","billingInterval":"BILLING_INTERVAL_MONTHLY","billingPeriodEnd":"2026-11-14T06:42:19.668067Z","cancelAtPeriodEnd":false,"futureOffers":[],"billingSystem":"BILLING_SYSTEM_COMMERCE"},
      {"xaiUserId":"00000000-0000-4000-8000-000000000001","tier":"SUBSCRIPTION_TIER_SUPER_GROK_PRO","status":"SUBSCRIPTION_STATUS_INACTIVE","createTime":"2026-09-17T06:36:00.000000Z","billingInterval":"BILLING_INTERVAL_MONTHLY","billingPeriodEnd":"2026-10-17T06:35:00.000000Z","cancelAtPeriodEnd":false,"futureOffers":[],"billingSystem":"BILLING_SYSTEM_LEGACY"}
    ],"dominantPlan":{"plan":"supergrok.heavy","surfaceNames":{"SURFACE_DISPLAY":"SuperGrok Heavy","SURFACE_JWT":"SUBSCRIPTION_TIER_SUPER_GROK_PRO","SURFACE_ANALYTICS":"SuperGrokPro"}}}
    """#

    func testSubscriptionsPickTheActiveCommerceRowAndNameTheXPlan() throws {
        let snapshot = try GrokSubscriptionsFetcher.parse(Data(Self.subscriptionsPayload.utf8))
        XCTAssertEqual(snapshot.tier, "SUBSCRIPTION_TIER_SUPER_GROK_PRO")
        XCTAssertEqual(snapshot.billingSystem, "BILLING_SYSTEM_COMMERCE")
        XCTAssertTrue(snapshot.isXSubscription)
        XCTAssertEqual(snapshot.dominantPlanDisplay, "SuperGrok Heavy")
        XCTAssertEqual(snapshot.xSubscriptionPlan, "X Ultra")
        XCTAssertEqual(try XCTUnwrap(snapshot.periodEnd).timeIntervalSince1970, 1_794_638_539.668, accuracy: 0.001)
    }

    func testLegacyActiveSubscriptionKeepsTheDisplayName() throws {
        let legacy = Self.subscriptionsPayload
            .replacingOccurrences(of: "\"BILLING_SYSTEM_COMMERCE\"", with: "\"BILLING_SYSTEM_LEGACY\"")
        let snapshot = try GrokSubscriptionsFetcher.parse(Data(legacy.utf8))
        XCTAssertFalse(snapshot.isXSubscription)
        XCTAssertNil(snapshot.xSubscriptionPlan, "The same tier on legacy billing is still SuperGrok Heavy")
        XCTAssertEqual(
            GrokQuotaAdapter.planLabel(subscription: snapshot, settingsDisplay: "SuperGrok Heavy", credentialsLabel: "SuperGrok"),
            "SuperGrok Heavy"
        )
    }

    func testUnverifiedCommerceTierFallsBackToSettingsDisplay() throws {
        let unknown = Self.subscriptionsPayload
            .replacingOccurrences(of: "\"tier\":\"SUBSCRIPTION_TIER_SUPER_GROK_PRO\",\"status\":\"SUBSCRIPTION_STATUS_ACTIVE\"",
                                  with: "\"tier\":\"SUBSCRIPTION_TIER_SUPER_GROK_PLUS\",\"status\":\"SUBSCRIPTION_STATUS_ACTIVE\"")
        let snapshot = try GrokSubscriptionsFetcher.parse(Data(unknown.utf8))
        XCTAssertTrue(snapshot.isXSubscription)
        XCTAssertNil(snapshot.xSubscriptionPlan, "An unmapped tier must not be guessed")
        XCTAssertEqual(
            GrokQuotaAdapter.planLabel(subscription: snapshot, settingsDisplay: "SuperGrok Plus", credentialsLabel: nil),
            "SuperGrok Plus"
        )
    }

    func testNoActiveSubscriptionYieldsNoPlan() throws {
        let inactive = Self.subscriptionsPayload
            .replacingOccurrences(of: "SUBSCRIPTION_STATUS_ACTIVE", with: "SUBSCRIPTION_STATUS_INACTIVE")
        let snapshot = try GrokSubscriptionsFetcher.parse(Data(inactive.utf8))
        XCTAssertNil(snapshot.tier)
        XCTAssertNil(snapshot.xSubscriptionPlan)
        XCTAssertEqual(snapshot.dominantPlanDisplay, "SuperGrok Heavy")
    }

    func testSubscriptionsFetchSendsBearerWithGrokOrigin() async throws {
        let session = Self.stubSession()
        let endpoint = URL(string: "https://grok.test/rest/subscriptions")!
        GrokXStubURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer xai-test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://grok.com")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            return (Self.response(request, status: 200, type: "application/json"), Data(Self.subscriptionsPayload.utf8))
        }
        let snapshot = await GrokSubscriptionsFetcher.fetch(
            credentials: Self.credentials(), session: session, endpoint: endpoint)
        XCTAssertEqual(snapshot?.xSubscriptionPlan, "X Ultra")
    }

    // MARK: - Plan display

    func testXSubscriptionPlanNamesRenderUnderTheXBrand() {
        XCTAssertEqual(ProviderPlanDisplay.grokXSubscriptionPlan(tier: "SUBSCRIPTION_TIER_SUPER_GROK_PRO"), "X Ultra")
        XCTAssertEqual(ProviderPlanDisplay.grokXSubscriptionPlan(tier: "super_grok_pro"), "X Ultra")
        XCTAssertNil(ProviderPlanDisplay.grokXSubscriptionPlan(tier: "SUBSCRIPTION_TIER_GROK_PRO"))

        let expected: [SubscriptionNameFormat: String] = [
            .full: "X Ultra", .name: "X Ultra", .tier: "Ultra", .tierWithMultiplier: "Ultra", .multiplier: "Ultra"
        ]
        for (format, name) in expected {
            XCTAssertEqual(ProviderPlanDisplay.displayName(for: .grok, rawPlan: "X Ultra", format: format), name, "\(format)")
        }
        XCTAssertEqual(ProviderPlanDisplay.displayName(for: .grok, rawPlan: "x_premium"), "X Premium")
        // Legacy names are untouched.
        XCTAssertEqual(ProviderPlanDisplay.displayName(for: .grok, rawPlan: "supergrok_heavy", format: .full), "SuperGrok Heavy")
    }

    // MARK: - Adapter composition

    func testAdapterCarriesThePoolSplitAsSharesOnWeekly() throws {
        let now = Date(timeIntervalSince1970: 1_791_950_000)
        let reset = Date(timeIntervalSince1970: 1_792_092_466)
        let credits = try GrokCreditsBillingFetcher.parse(Data(Self.creditsPayload.utf8))
        let quota = GrokQuotaAdapter.makeQuota(
            snapshot: GrokWebBillingSnapshot(usedPercent: 61, resetsAt: reset),
            account: Self.account,
            plan: "X Ultra",
            email: "user@example.com",
            credits: credits,
            now: now
        )
        XCTAssertEqual(quota.buckets.map(\.id), ["weekly"], "A share is a decomposition, never a bucket of its own")
        XCTAssertEqual(quota.plan, "X Ultra")
        let weekly = try XCTUnwrap(quota.weeklyBucket)
        XCTAssertEqual(weekly.usedPercent, 61)
        XCTAssertEqual(weekly.resetAt, reset)
        XCTAssertEqual(weekly.shares, [
            QuotaBucketShare(label: "Grok Build", usedPercent: 60),
            QuotaBucketShare(label: "Chat", usedPercent: 1)
        ])
        XCTAssertTrue(weekly.supportsForecast, "The pool itself still forecasts")

        let dto = MCPQuotaBucketDTO(bucket: weekly, forecast: nil)
        XCTAssertEqual(dto.shares?.map(\.label), ["Grok Build", "Chat"])
        XCTAssertEqual(dto.usedPercent, 61)
    }

    func testSharesRoundTripThroughTheQuotaCacheAndStayOptional() throws {
        let bucket = QuotaBucket(
            id: "weekly", title: "Weekly", shortLabel: "Weekly", usedPercent: 61,
            resetAt: Date(timeIntervalSince1970: 1_792_092_466), rawWindowSeconds: 604_800,
            shares: [QuotaBucketShare(label: "Grok Build", usedPercent: 60)]
        )
        let data = try JSONEncoder().encode(bucket)
        XCTAssertEqual(try JSONDecoder().decode(QuotaBucket.self, from: data), bucket)

        // A cache written before shares existed, and a bucket without any.
        let legacy = #"{"id":"weekly","title":"Weekly","shortLabel":"Weekly","usedPercent":42}"#
        XCTAssertNil(try JSONDecoder().decode(QuotaBucket.self, from: Data(legacy.utf8)).shares)
        let plain = QuotaBucket(id: "weekly", title: "Weekly", shortLabel: "Weekly", usedPercent: 1, shares: [])
        XCTAssertNil(plain.shares, "An empty split is no split")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("shares"))
    }

    func testAdapterWithoutEnrichmentKeepsAPlainWeeklyBucket() {
        let quota = GrokQuotaAdapter.makeQuota(
            snapshot: GrokWebBillingSnapshot(usedPercent: 42, resetsAt: nil),
            account: Self.account,
            plan: "SuperGrok Heavy",
            email: nil,
            credits: nil,
            now: Date()
        )
        XCTAssertEqual(quota.buckets.map(\.id), ["weekly"])
        XCTAssertNil(quota.weeklyBucket?.shares)
    }

    func testPoolSharesOnlyExistForTheUnifiedPool() {
        let snapshot = GrokWebBillingSnapshot(usedPercent: 13, resetsAt: nil)
        let legacy = GrokCreditsBillingSnapshot(
            usedPercent: 13, periodStart: nil, periodEnd: nil,
            productUsage: [.init(product: "GrokChat", usedPercent: 13)],
            isUnifiedBillingUser: false
        )
        XCTAssertNil(GrokQuotaAdapter.poolShares(from: legacy, matching: snapshot), "A legacy account's Weekly carries no split")

        let unified = GrokCreditsBillingSnapshot(
            usedPercent: 13, periodStart: nil, periodEnd: nil,
            productUsage: [.init(product: "GrokChat", usedPercent: 10), .init(product: "GrokImagine", usedPercent: 3)],
            isUnifiedBillingUser: true
        )
        XCTAssertEqual(GrokQuotaAdapter.poolShares(from: unified, matching: snapshot)?.map(\.label), ["Chat", "Imagine"],
                       "An unfamiliar product keeps xAI's key minus the brand prefix")
    }

    func testStaleSharesFromTheOldCycleAreNotAttached() {
        let reset = Date(timeIntervalSince1970: 1_792_092_466)
        let oldCycle = GrokCreditsBillingSnapshot(
            usedPercent: 61, periodStart: nil, periodEnd: reset,
            productUsage: [.init(product: "GrokBuild", usedPercent: 60), .init(product: "GrokChat", usedPercent: 1)],
            isUnifiedBillingUser: true
        )
        // The RPC already rolled over: 0% into the next week.
        let rolledOver = GrokWebBillingSnapshot(usedPercent: 0, resetsAt: reset.addingTimeInterval(604_800))
        XCTAssertNil(GrokQuotaAdapter.poolShares(from: oldCycle, matching: rolledOver),
                     "A split that sums to 61% must not decorate a 0% week")

        // Same cycle, same numbers within float noise: attached.
        let live = GrokWebBillingSnapshot(usedPercent: 61.4, resetsAt: reset.addingTimeInterval(0.2))
        XCTAssertEqual(GrokQuotaAdapter.poolShares(from: oldCycle, matching: live)?.count, 2)

        // Same percent but the JSON names another period end: not attached.
        let otherPeriod = GrokWebBillingSnapshot(usedPercent: 61, resetsAt: reset.addingTimeInterval(3_600))
        XCTAssertNil(GrokQuotaAdapter.poolShares(from: oldCycle, matching: otherPeriod))
    }

    // MARK: - gRPC fallback for the split

    /// A config message like the live one on 2026-10-16: 2% used, products
    /// 9 and 10 at 1% each, unified flag set.
    private static func grpcConfig(percent: Float, products: [(UInt64, Float)], unified: Bool) -> Data {
        func varint(_ v: UInt64) -> [UInt8] {
            var r = v; var out: [UInt8] = []
            repeat { var b = UInt8(r & 0x7F); r >>= 7; if r != 0 { b |= 0x80 }; out.append(b) } while r != 0
            return out
        }
        func fixed32(_ f: Float) -> [UInt8] { var bits = f.bitPattern.littleEndian; return withUnsafeBytes(of: &bits) { Array($0) } }
        var config: [UInt8] = [0x0D] + fixed32(percent)
        for (code, pct) in products {
            let entry: [UInt8] = [0x08] + varint(code) + [0x15] + fixed32(pct)
            config += [0x3A] + varint(UInt64(entry.count)) + entry
        }
        if unified { config += [0x58, 0x01] }
        let message: [UInt8] = [0x0A] + varint(UInt64(config.count)) + config
        var frame = Data([0x00, 0x00, 0x00, 0x00, UInt8(message.count)])
        frame.append(contentsOf: message)
        return frame
    }

    func testGRPCCarriesTheSplitAndTheUnifiedFlag() throws {
        let frame = Self.grpcConfig(percent: 2, products: [(9, 1), (10, 1)], unified: true)
        let snapshot = try GrokWebBillingFetcher.parseGRPCWebResponse(frame, now: Date(timeIntervalSince1970: 1_792_000_000))
        XCTAssertEqual(snapshot.usedPercent, 2)
        XCTAssertEqual(snapshot.isUnified, true)
        XCTAssertEqual(snapshot.productShares, [.init(code: 9, usedPercent: 1), .init(code: 10, usedPercent: 1)])
    }

    func testGRPCSplitIsTheFallbackWhenTheJSONEndpointIsDown() throws {
        let frame = Self.grpcConfig(percent: 2, products: [(2, 0.6), (9, 1), (10, 0.4), (5, 0.2), (42, 0.1)], unified: true)
        let snapshot = try GrokWebBillingFetcher.parseGRPCWebResponse(frame, now: Date(timeIntervalSince1970: 1_792_000_000))
        let shares = try XCTUnwrap(GrokQuotaAdapter.poolShares(from: nil, matching: snapshot))
        XCTAssertEqual(shares.map(\.label), ["Grok Build", "Grok Bot", "Cursor", "Imagine", "Other"],
                       "10 is Cursor and 5 is Imagine, as grok.com's usage page lists them; an enum the table does not name is not guessed")
        XCTAssertEqual(shares.last?.usedPercent ?? 0, 0.1, accuracy: 0.0001)

        let legacy = try GrokWebBillingFetcher.parseGRPCWebResponse(
            Self.grpcConfig(percent: 2, products: [(2, 2)], unified: false), now: Date(timeIntervalSince1970: 1_792_000_000))
        XCTAssertNil(GrokQuotaAdapter.poolShares(from: nil, matching: legacy), "No split for a legacy pool")
    }

    func testEnrichmentDeadlineDropsATricklingAnswer() async {
        let fast = await GrokQuotaAdapter.bounded(seconds: 5) { "answer" }
        XCTAssertEqual(fast, "answer")

        let started = Date()
        let slow: String? = await GrokQuotaAdapter.bounded(seconds: 0.2) {
            try? await Task.sleep(for: .seconds(30))
            return "too late"
        }
        XCTAssertNil(slow, "The deadline wins over a trickling answer")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "The loser is cancelled, not awaited")
    }

    // MARK: - Helpers

    private static let account = AccountIdentity(
        id: "oauth-grok", tool: .grok, email: "user@example.com", alias: "Grok", plan: nil,
        source: .oauthCLI, allowsWebFallback: false, allowsCLIFallback: false, allowsOAuthFallback: true,
        createdAt: Date(), updatedAt: Date()
    )

    private static func credentials() -> GrokCredentials {
        GrokCredentials(
            accessToken: "xai-test-token", scope: "https://auth.x.ai::test-client", authMode: "oidc",
            email: "user@example.com", firstName: nil, lastName: nil, teamId: nil,
            subscriptionTier: nil, expiresAt: nil
        )
    }

    private static func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GrokXStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func response(_ request: URLRequest, status: Int, type: String) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type])!
    }

    override func tearDown() {
        GrokXStubURLProtocol.handler = nil
    }
}

private final class GrokXStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
