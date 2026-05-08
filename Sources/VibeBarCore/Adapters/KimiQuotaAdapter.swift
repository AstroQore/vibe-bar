import Foundation

/// Moonshot / Kimi (kimi.com) usage adapter.
///
/// Auth: the `kimi-auth` JWT cookie. Source resolution flows through
/// `MiscCookieResolver` so the user can choose between auto-import
/// from Chrome/Edge/Brave/Arc/Safari/Firefox, manual paste, or
/// fully off.
///
/// Endpoint:
/// `POST https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages`
/// with body `{"scope":["FEATURE_CODING"]}`. Headers reproduce the
/// web app — Bearer token, kimi-auth cookie, browser User-Agent,
/// connect-protocol-version, plus session / device / traffic IDs
/// extracted from the JWT payload.
///
/// Output: weekly bucket (primary) + 5-hour rate-limit bucket
/// (secondary, when present).
public struct KimiQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .kimi

    private let session: URLSession
    private let now: @Sendable () -> Date

    public static let cookieSpec = MiscCookieResolver.Spec(
        tool: .kimi,
        domains: ["www.kimi.com", "kimi.com"],
        requiredNames: ["kimi-auth"]
    )

    private static let endpoint = URL(string:
        "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages"
    )!

    public init(
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.now = now
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        guard let resolution = MiscCookieResolver.resolve(for: KimiQuotaAdapter.cookieSpec) else {
            throw QuotaError.noCredential
        }

        // Pull the kimi-auth cookie value out of the resolved header.
        let pairs = CookieHeaderNormalizer.pairs(from: resolution.header)
        guard let authToken = pairs.first(where: { $0.name == "kimi-auth" })?.value,
              !authToken.isEmpty else {
            throw QuotaError.noCredential
        }

        let session = KimiSessionInfo.fromJWT(authToken)

        var request = URLRequest(url: KimiQuotaAdapter.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("kimi-auth=\(authToken)", forHTTPHeaderField: "Cookie")
        request.setValue("https://www.kimi.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.kimi.com/code/console", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        request.setValue("en-US", forHTTPHeaderField: "x-language")
        request.setValue("web", forHTTPHeaderField: "x-msh-platform")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "r-timezone")
        if let deviceId = session.deviceId  { request.setValue(deviceId,  forHTTPHeaderField: "x-msh-device-id") }
        if let sessionId = session.sessionId { request.setValue(sessionId, forHTTPHeaderField: "x-msh-session-id") }
        if let trafficId = session.trafficId { request.setValue(trafficId, forHTTPHeaderField: "x-traffic-id") }

        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["scope": ["FEATURE_CODING"]]
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await self.session.data(for: request)
        } catch {
            throw QuotaError.network("Kimi network error: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Kimi: invalid response object")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                // Stale cookie: clear cache so the next refresh
                // re-imports rather than retrying with the same
                // bad token.
                CookieHeaderCache.clear(for: .kimi)
                throw QuotaError.needsLogin
            }
            if http.statusCode == 429 {
                throw QuotaError.rateLimited
            }
            throw QuotaError.network("Kimi returned HTTP \(http.statusCode).")
        }

        let snapshot = try KimiResponseParser.parse(data: data, now: now())
        return AccountQuota(
            accountId: account.id,
            tool: .kimi,
            buckets: snapshot.buckets,
            plan: nil,
            email: account.email,
            queriedAt: now(),
            error: nil
        )
    }
}

// MARK: - JWT session info

struct KimiSessionInfo {
    let deviceId: String?
    let sessionId: String?
    let trafficId: String?

    static let empty = KimiSessionInfo(deviceId: nil, sessionId: nil, trafficId: nil)

    static func fromJWT(_ jwt: String) -> KimiSessionInfo {
        let parts = jwt.split(separator: ".", maxSplits: 2)
        guard parts.count == 3 else { return .empty }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .empty }
        return KimiSessionInfo(
            deviceId: json["device_id"] as? String,
            sessionId: json["ssid"] as? String,
            trafficId: json["sub"] as? String
        )
    }
}

// MARK: - Response parsing

enum KimiResponseParser {
    struct Snapshot {
        var buckets: [QuotaBucket]
    }

    static func parse(data: Data, now: Date) throws -> Snapshot {
        let response: KimiAPIResponse
        do {
            response = try JSONDecoder().decode(KimiAPIResponse.self, from: data)
        } catch {
            throw QuotaError.parseFailure("Kimi response not parseable: \(error.localizedDescription)")
        }
        guard let coding = response.usages.first(where: { $0.scope == "FEATURE_CODING" }) else {
            throw QuotaError.parseFailure("Kimi response: FEATURE_CODING scope missing.")
        }

        var buckets: [QuotaBucket] = []
        if let weekly = makeBucket(
            id: "kimi.weekly",
            title: "Weekly",
            shortLabel: "Wk",
            from: coding.detail,
            windowSeconds: 7 * 86_400
        ) {
            buckets.append(weekly)
        }
        if let rate = coding.limits?.first {
            let label = rate.window?.shortLabel ?? "5h"
            let title = rate.window?.title ?? "5 Hours"
            if let bucket = makeBucket(
                id: "kimi.rate",
                title: title,
                shortLabel: label,
                from: rate.detail,
                windowSeconds: rate.window?.windowSeconds ?? 5 * 3600
            ) {
                buckets.append(bucket)
            }
        }

        guard !buckets.isEmpty else {
            throw QuotaError.parseFailure("Kimi response had no usable usage windows.")
        }
        return Snapshot(buckets: buckets)
    }

    private static func makeBucket(
        id: String,
        title: String,
        shortLabel: String,
        from detail: KimiAPIDetail,
        windowSeconds: Int
    ) -> QuotaBucket? {
        let limit = Int(detail.limit) ?? 0
        guard limit > 0 else { return nil }
        let used: Int = {
            if let usedStr = detail.used, let n = Int(usedStr) { return n }
            if let remStr = detail.remaining, let r = Int(remStr) { return max(0, limit - r) }
            return 0
        }()
        let percent = max(0, min(100, Double(used) / Double(limit) * 100))
        let resetAt = parseResetTime(detail.resetTime)
        return QuotaBucket(
            id: id,
            title: title,
            shortLabel: shortLabel,
            usedPercent: percent,
            resetAt: resetAt,
            rawWindowSeconds: windowSeconds
        )
    }

    private static func parseResetTime(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

// MARK: - Wire types

private struct KimiAPIResponse: Decodable {
    let usages: [KimiAPIUsage]
}

private struct KimiAPIUsage: Decodable {
    let scope: String
    let detail: KimiAPIDetail
    let limits: [KimiAPILimit]?
}

private struct KimiAPILimit: Decodable {
    let window: KimiAPIWindow?
    let detail: KimiAPIDetail
}

struct KimiAPIWindow: Decodable {
    let duration: Int
    let timeUnit: String

    var windowSeconds: Int? {
        switch timeUnit.uppercased() {
        case "SECOND", "SECONDS": return duration
        case "MINUTE", "MINUTES": return duration * 60
        case "HOUR", "HOURS":     return duration * 3600
        case "DAY", "DAYS":       return duration * 86_400
        case "WEEK", "WEEKS":     return duration * 7 * 86_400
        default: return nil
        }
    }

    var title: String {
        guard let secs = windowSeconds else { return "Rate limit" }
        if secs >= 86_400 {
            let days = secs / 86_400
            return "\(days) Day\(days == 1 ? "" : "s")"
        }
        if secs >= 3600 {
            let hours = secs / 3600
            return "\(hours) Hour\(hours == 1 ? "" : "s")"
        }
        let minutes = max(1, secs / 60)
        return "\(minutes) Minute\(minutes == 1 ? "" : "s")"
    }

    var shortLabel: String {
        guard let secs = windowSeconds else { return "Rate" }
        if secs >= 86_400 { return "\(secs / 86_400)d" }
        if secs >= 3600   { return "\(secs / 3600)h" }
        return "\(max(1, secs / 60))m"
    }
}

struct KimiAPIDetail: Decodable {
    let limit: String
    let used: String?
    let remaining: String?
    let resetTime: String?
}
