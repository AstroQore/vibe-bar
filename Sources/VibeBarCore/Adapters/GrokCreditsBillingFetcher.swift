import Foundation

/// The credits-format billing payload the Grok CLI itself reads:
/// `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` with the
/// `grok login` bearer. It is the JSON twin of the gRPC-Web
/// `GetGrokCreditsConfig` RPC — same weekly period and used-percent — but
/// it names its fields, and it carries two things the RPC only exposes by
/// inferred field number: the per-product split of the pool and whether the
/// account is on the unified pool The X Subscription introduced (one weekly
/// allowance shared by Grok Build, Grok chat and Cursor).
///
/// Enrichment only: the RPC stays the quota's source of truth, and every
/// failure here is reported as `nil` so a schema change can never take the
/// weekly card down with it.
public struct GrokCreditsBillingSnapshot: Sendable, Equatable {
    public struct ProductUsage: Sendable, Equatable {
        /// xAI's product key: `GrokBuild`, `GrokChat`, …
        public let product: String
        /// Share of the pool this product consumed, on the pool's own scale
        /// (the products sum to `usedPercent`).
        public let usedPercent: Double

        public init(product: String, usedPercent: Double) {
            self.product = product
            self.usedPercent = usedPercent
        }
    }

    public let usedPercent: Double?
    public let periodStart: Date?
    public let periodEnd: Date?
    public let productUsage: [ProductUsage]
    public let isUnifiedBillingUser: Bool

    public init(
        usedPercent: Double?,
        periodStart: Date?,
        periodEnd: Date?,
        productUsage: [ProductUsage],
        isUnifiedBillingUser: Bool
    ) {
        self.usedPercent = usedPercent
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.productUsage = productUsage
        self.isUnifiedBillingUser = isUnifiedBillingUser
    }
}

public enum GrokCreditsBillingFetcher {
    public static let defaultEndpoint =
        URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private static let requestTimeoutSeconds: TimeInterval = 15

    /// `nil` on any failure — transport, status or shape. The caller treats
    /// the answer as optional inventory.
    public static func fetch(
        credentials: GrokCredentials,
        session: URLSession = .shared,
        endpoint: URL = Self.defaultEndpoint
    ) async -> GrokCreditsBillingSnapshot? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("VibeBar", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200
        else { return nil }
        return try? parse(data)
    }

    public static func parse(_ data: Data) throws -> GrokCreditsBillingSnapshot {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let config = payload.config
        let products = (config.productUsage ?? []).compactMap { entry -> GrokCreditsBillingSnapshot.ProductUsage? in
            guard let product = entry.product?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !product.isEmpty,
                  let percent = entry.usagePercent, percent.isFinite
            else { return nil }
            return .init(product: product, usedPercent: max(0, min(100, percent)))
        }
        return GrokCreditsBillingSnapshot(
            usedPercent: config.creditUsagePercent.flatMap { $0.isFinite ? max(0, min(100, $0)) : nil },
            periodStart: parseDate(config.currentPeriod?.start ?? config.billingPeriodStart),
            periodEnd: parseDate(config.currentPeriod?.end ?? config.billingPeriodEnd),
            productUsage: products,
            isUnifiedBillingUser: config.isUnifiedBillingUser ?? false
        )
    }

    /// xAI writes `2026-10-08T19:27:46.187121+00:00`: six fractional digits,
    /// which `ISO8601DateFormatter` rejects. Trimming to milliseconds keeps
    /// the formatter happy and loses nothing a weekly reset can show.
    static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) { return date }
        if let date = withFractional.date(from: trimmedToMilliseconds(raw)) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private static func trimmedToMilliseconds(_ raw: String) -> String {
        guard let dot = raw.firstIndex(of: "."),
              let zoneStart = raw[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" })
        else { return raw }
        let fraction = raw[raw.index(after: dot)..<zoneStart]
        let millis = fraction.prefix(3)
        guard millis.count == 3 else { return raw }
        return raw[..<dot] + "." + millis + raw[zoneStart...]
    }

    private struct Payload: Decodable {
        let config: Config
    }

    private struct Config: Decodable {
        let currentPeriod: Period?
        let creditUsagePercent: Double?
        let productUsage: [Product]?
        let isUnifiedBillingUser: Bool?
        let billingPeriodStart: String?
        let billingPeriodEnd: String?
    }

    private struct Period: Decodable {
        let type: String?
        let start: String?
        let end: String?
    }

    private struct Product: Decodable {
        let product: String?
        let usagePercent: Double?
    }
}
