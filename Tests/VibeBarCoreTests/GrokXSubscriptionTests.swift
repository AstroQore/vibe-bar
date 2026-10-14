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

    func testAdapterAddsSharedPoolBucketsBesideWeekly() throws {
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
        XCTAssertEqual(quota.buckets.map(\.id), ["weekly", "grok_build_weekly", "grok_chat_weekly"])
        XCTAssertEqual(quota.plan, "X Ultra")
        let weekly = try XCTUnwrap(quota.weeklyBucket)
        XCTAssertEqual(weekly.usedPercent, 61)
        XCTAssertNil(weekly.groupTitle, "The headline window stays directly under the SubProvider")

        let build = try XCTUnwrap(quota.bucket(id: "grok_build_weekly"))
        XCTAssertEqual(build.shortLabel, "Build")
        XCTAssertEqual(build.title, "Weekly")
        XCTAssertEqual(build.usedPercent, 60)
        XCTAssertEqual(build.groupTitle, "Shared Pool")
        XCTAssertEqual(build.resetAt, reset, "Product rows age with the RPC's reset")
        XCTAssertEqual(build.rawWindowSeconds, 604_800)
        XCTAssertEqual(quota.bucket(id: "grok_chat_weekly")?.usedPercent, 1)

        for id in ["grok_build_weekly", "grok_chat_weekly"] {
            XCTAssertEqual(MenuBarFieldCatalog.quotaGroupKey(tool: .grok, bucketId: id), "grok.shared-pool")
        }
    }

    func testAdapterWithoutEnrichmentKeepsTheSingleWeeklyBucket() {
        let quota = GrokQuotaAdapter.makeQuota(
            snapshot: GrokWebBillingSnapshot(usedPercent: 42, resetsAt: nil),
            account: Self.account,
            plan: "SuperGrok Heavy",
            email: nil,
            credits: nil,
            now: Date()
        )
        XCTAssertEqual(quota.buckets.map(\.id), ["weekly"])
    }

    func testProductBucketsOnlyExistForTheUnifiedPool() {
        let legacy = GrokCreditsBillingSnapshot(
            usedPercent: 10, periodStart: nil, periodEnd: Date(timeIntervalSince1970: 1_792_092_466),
            productUsage: [.init(product: "GrokChat", usedPercent: 10)],
            isUnifiedBillingUser: false
        )
        XCTAssertTrue(GrokQuotaAdapter.productBuckets(from: legacy, resetAt: nil).isEmpty,
                      "A legacy account must not be routed into the Shared Pool group")

        let unified = GrokCreditsBillingSnapshot(
            usedPercent: 13, periodStart: nil, periodEnd: legacy.periodEnd,
            productUsage: [.init(product: "GrokChat", usedPercent: 10), .init(product: "GrokImagine", usedPercent: 3)],
            isUnifiedBillingUser: true
        )
        let buckets = GrokQuotaAdapter.productBuckets(from: unified, resetAt: nil)
        XCTAssertEqual(buckets.map(\.id), ["grok_chat_weekly"], "Unknown products are not minted into buckets")
        XCTAssertEqual(buckets.first?.groupTitle, "Shared Pool")
        XCTAssertEqual(buckets.first?.resetAt, unified.periodEnd, "Falls back to the JSON period end")
    }

    func testRenamedSharedPoolKeepsItsFieldsThroughAnEnrichmentHiccup() {
        var registry = QuotaFieldRegistry()
        let reset = Date(timeIntervalSince1970: 1_792_092_466)
        let credits = GrokCreditsBillingSnapshot(
            usedPercent: 61, periodStart: nil, periodEnd: reset,
            productUsage: [.init(product: "GrokBuild", usedPercent: 60), .init(product: "GrokChat", usedPercent: 1)],
            isUnifiedBillingUser: true
        )
        let quota = GrokQuotaAdapter.makeQuota(
            snapshot: GrokWebBillingSnapshot(usedPercent: 61, resetsAt: reset),
            account: Self.account, plan: "X Ultra", email: nil, credits: credits, now: Date()
        )
        registry.record(tool: .grok, buckets: quota.buckets)
        let discovered = registry.fields.filter { $0.tool == .grok }.map(\.bucketId).sorted()
        XCTAssertEqual(discovered, ["grok_build_weekly", "grok_chat_weekly"])

        // The user named the group (under the key the naming UI uses) but
        // selected nothing; one refresh without the enrichment follows.
        registry.prune(tool: .grok, liveBucketIds: ["weekly"],
                       keeping: QuotaFieldKeepSet(groupKeys: ["grok.shared-pool"]))
        XCTAssertEqual(registry.fields.filter { $0.tool == .grok }.count, 2,
                       "A user-named group keeps its fields, dimmed, through a hiccup")

        registry.prune(tool: .grok, liveBucketIds: ["weekly"], keeping: QuotaFieldKeepSet())
        XCTAssertTrue(registry.fields.filter { $0.tool == .grok }.isEmpty, "Unreferenced fields are forgotten")
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
