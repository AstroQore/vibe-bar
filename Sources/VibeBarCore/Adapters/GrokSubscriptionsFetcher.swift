import Foundation

/// The account's plan as grok.com's own billing page sees it:
/// `GET https://grok.com/rest/subscriptions` with the `grok login` bearer.
///
/// The reply lists every subscription the account ever held, each with a
/// `tier` enum (`SUBSCRIPTION_TIER_SUPER_GROK_PRO`, …), a `status`
/// (`SUBSCRIPTION_STATUS_ACTIVE` / `_INACTIVE`) and a `billingSystem`:
/// `BILLING_SYSTEM_LEGACY` for the old Stripe plans,
/// `BILLING_SYSTEM_COMMERCE` for The X Subscription introduced on
/// 2026-10-12. A `dominantPlan.surfaceNames` map carries the names xAI uses
/// for the same plan on each surface; `SURFACE_DISPLAY` is the one the CLI
/// settings endpoint echoes.
///
/// Why it matters: the tier enum keeps its pre-bundle name after a move to
/// The X Subscription — an account on the $200 Ultra plan still reports
/// `SUPER_GROK_PRO` and a `SuperGrok Heavy` display name — so only the pair
/// of tier and billing system identifies the plan the user actually bought.
///
/// Enrichment only: `nil` on any failure, and the settings display name
/// remains the fallback label.
public struct GrokSubscriptionSnapshot: Sendable, Equatable {
    /// The active subscription's tier enum, or `nil` when none is active.
    public let tier: String?
    /// The active subscription's billing system enum.
    public let billingSystem: String?
    public let periodEnd: Date?
    /// `dominantPlan.surfaceNames.SURFACE_DISPLAY`.
    public let dominantPlanDisplay: String?

    public init(tier: String?, billingSystem: String?, periodEnd: Date?, dominantPlanDisplay: String?) {
        self.tier = tier
        self.billingSystem = billingSystem
        self.periodEnd = periodEnd
        self.dominantPlanDisplay = dominantPlanDisplay
    }

    /// True when the active subscription was bought on The X Subscription.
    public var isXSubscription: Bool {
        billingSystem == GrokSubscriptionsFetcher.commerceBillingSystem
    }

    /// The X Subscription plan name for the active subscription, or `nil`
    /// when the account is on a legacy plan or the tier has no verified
    /// mapping yet. See `ProviderPlanDisplay.grokXSubscriptionPlan`.
    public var xSubscriptionPlan: String? {
        guard isXSubscription, let tier else { return nil }
        return ProviderPlanDisplay.grokXSubscriptionPlan(tier: tier)
    }
}

public enum GrokSubscriptionsFetcher {
    public static let defaultEndpoint = URL(string: "https://grok.com/rest/subscriptions")!
    static let commerceBillingSystem = "BILLING_SYSTEM_COMMERCE"
    static let activeStatus = "SUBSCRIPTION_STATUS_ACTIVE"
    private static let requestTimeoutSeconds: TimeInterval = 15

    public static func fetch(
        credentials: GrokCredentials,
        session: URLSession = .shared,
        endpoint: URL = Self.defaultEndpoint
    ) async -> GrokSubscriptionSnapshot? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/", forHTTPHeaderField: "Referer")
        request.setValue("VibeBar", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200
        else { return nil }
        return try? parse(data)
    }

    public static func parse(_ data: Data) throws -> GrokSubscriptionSnapshot {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        // Several rows can be active during a switch (the old plan runs to
        // its period end); the newest one is the plan the user chose.
        let active = (payload.subscriptions ?? [])
            .filter { $0.status == Self.activeStatus }
            .sorted { ($0.createTime ?? "") > ($1.createTime ?? "") }
            .first
        return GrokSubscriptionSnapshot(
            tier: active?.tier,
            billingSystem: active?.billingSystem,
            periodEnd: GrokCreditsBillingFetcher.parseDate(active?.billingPeriodEnd),
            dominantPlanDisplay: payload.dominantPlan?.surfaceNames?["SURFACE_DISPLAY"]
        )
    }

    private struct Payload: Decodable {
        let subscriptions: [Subscription]?
        let dominantPlan: DominantPlan?
    }

    private struct Subscription: Decodable {
        let tier: String?
        let status: String?
        let billingSystem: String?
        let createTime: String?
        let billingPeriodEnd: String?
    }

    private struct DominantPlan: Decodable {
        let plan: String?
        let surfaceNames: [String: String]?
    }
}
