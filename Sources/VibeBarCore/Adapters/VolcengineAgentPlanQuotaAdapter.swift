import Foundation

/// Volcengine / Doubao **Agent Plan** usage adapter.
///
/// Lives alongside `VolcengineQuotaAdapter` (the Coding Plan flavour).
/// Agent Plan is a separate Ark subscription, sold and metered in its
/// own "AFP" unit (Agent燃料值 / Agent Fuel Points). The console renders
/// it under a dedicated tab next to Coding Plan:
/// `console.volcengine.com/ark/region:ark+cn-beijing/openManagement?advancedActiveKey=agentPlan`.
///
/// Auth: identical to the Coding Plan card — the full `*.volcengine.com`
/// console jar with the `csrfToken` cookie mirrored into `X-Csrf-Token`.
/// Both cards therefore ride the same Volcengine login; the default
/// browser-cookie auto-import (keyed by domain) populates both at once,
/// so the user signs in once and both refresh.
///
/// Endpoint:
/// `POST .../2024-01-01/GetAgentPlanAFPUsage` returns one richer block
/// than Coding Plan's percent-only `GetCodingPlanUsage`:
///
///     Result.PlanType            "medium" / "small" / "large" / …
///     Result.AFPFiveHour         { Quota, Used, SubscribeTime, ResetTime }
///     Result.AFPWeekly           { … }
///     Result.AFPMonthly          { … }
///     Result.AFPDaily            { … }
///
/// Each window carries an absolute `Used` / `Quota` pair (so we compute
/// the percent ourselves) plus `ResetTime` in **milliseconds** — unlike
/// the Coding Plan endpoint, whose `ResetTimestamp` is in seconds.
///
/// We surface the same three windows the console shows (5-hour, weekly,
/// monthly). `AFPDaily` is returned by the API but hidden by the console
/// for the observed tiers — its quota (e.g. 50000) sits *above* the
/// weekly cap (35000), which only makes sense as a vestigial default,
/// not an enforced limit — so we mirror the console and skip it.
///
/// `PlanType` doubles as the plan badge ("Agent Plan Medium"), so unlike
/// the Coding Plan adapter there is no companion `ListSubscribeTrade`
/// call to fetch the plan name.
public struct VolcengineAgentPlanQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .volcengineAgentPlan

    private let session: URLSession
    private let now: @Sendable () -> Date

    public static let cookieSpec = MiscCookieResolver.Spec(
        tool: .volcengineAgentPlan,
        domains: [
            "console.volcengine.com",
            "volcengine.com",
            ".volcengine.com"
        ],
        // Same trade-off as the Coding Plan jar: Volcengine's BFF stitches
        // identity from HttpOnly session keys we can't enumerate from JS,
        // so we ship the entire `*.volcengine.com` jar.
        requiredNames: []
    )

    public init(
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.now = now
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        let resolutions = MiscCookieResolver.resolveAll(for: VolcengineAgentPlanQuotaAdapter.cookieSpec, account: account)
        guard !resolutions.isEmpty else { throw QuotaError.noCredential }

        let queriedAt = now()
        let results = await MiscQuotaAggregator.gatherSlotResults(resolutions) { resolution in
            try await self.fetchOneSlot(resolution, account: account, queriedAt: queriedAt)
        }
        return MiscQuotaAggregator.aggregate(
            tool: .volcengineAgentPlan,
            account: account,
            results: results,
            queriedAt: queriedAt
        )
    }

    private func fetchOneSlot(
        _ resolution: MiscCookieResolver.Resolution,
        account: AccountIdentity,
        queriedAt: Date
    ) async throws -> AccountQuota {
        let pairs = CookieHeaderNormalizer.pairs(from: resolution.header)
        guard let csrfToken = pairs.first(where: { $0.name == "csrfToken" })?.value, !csrfToken.isEmpty else {
            // No `csrfToken` means the user logged in at the
            // volcengine.com website level but never opened the console
            // (the cookie is set by the first console request).
            throw QuotaError.needsLogin
        }

        let data = try await callBFF(cookieHeader: resolution.header, csrfToken: csrfToken)
        let parsed = try VolcengineAgentPlanResponseParser.parseUsage(data: data)
        return AccountQuota(
            accountId: account.id,
            tool: .volcengineAgentPlan,
            buckets: parsed.buckets,
            plan: parsed.planName,
            email: account.email,
            queriedAt: queriedAt,
            error: nil
        )
    }

    private func callBFF(cookieHeader: String, csrfToken: String) async throws -> Data {
        var request = URLRequest(url: Self.getAgentPlanAFPUsageURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(csrfToken, forHTTPHeaderField: "X-Csrf-Token")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("zh", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://console.volcengine.com", forHTTPHeaderField: "Origin")
        request.setValue("https://console.volcengine.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: [:])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await self.session.data(for: request)
        } catch {
            throw QuotaError.network("Volcengine Agent Plan network error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Volcengine Agent Plan: invalid response object")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw QuotaError.needsLogin
            }
            if http.statusCode == 429 {
                throw QuotaError.rateLimited
            }
            throw QuotaError.network("Volcengine Agent Plan returned HTTP \(http.statusCode).")
        }
        return data
    }

    private static let getAgentPlanAFPUsageURL = URL(string:
        "https://console.volcengine.com/api/top/ark/cn-beijing/2024-01-01/GetAgentPlanAFPUsage"
    )!
}

// MARK: - Response parsing

enum VolcengineAgentPlanResponseParser {
    struct UsageSnapshot {
        var buckets: [QuotaBucket]
        var planName: String?
    }

    static func parseUsage(data: Data) throws -> UsageSnapshot {
        guard !data.isEmpty else {
            throw QuotaError.parseFailure("Volcengine Agent Plan returned an empty body.")
        }
        let envelope: AgentPlanUsageEnvelope
        do {
            envelope = try JSONDecoder().decode(AgentPlanUsageEnvelope.self, from: data)
        } catch {
            throw QuotaError.parseFailure("Volcengine Agent Plan usage response not parseable: \(error.localizedDescription)")
        }

        if let err = envelope.responseMetadata?.error {
            let code = err.code?.lowercased() ?? ""
            let message = err.message?.trimmedNonEmpty ?? "code \(err.code ?? "?")"
            if isAuthCode(code) || message.lowercased().contains("login") {
                throw QuotaError.needsLogin
            }
            if code.contains("requestlimit") || code.contains("ratelimit") {
                throw QuotaError.rateLimited
            }
            throw QuotaError.network("Volcengine Agent Plan: \(message)")
        }

        guard let result = envelope.result else {
            throw QuotaError.parseFailure("Volcengine Agent Plan response had no Result block.")
        }

        // The console shows 5-hour / weekly / monthly; `AFPDaily` is
        // returned but intentionally not surfaced (see the type doc).
        let windows: [(AgentPlanWindow?, AgentPlanBucketKind)] = [
            (result.afpFiveHour, .session),
            (result.afpWeekly, .weekly),
            (result.afpMonthly, .monthly)
        ]

        var buckets: [QuotaBucket] = []
        for (window, kind) in windows {
            guard let bucket = bucket(from: window, kind: kind) else { continue }
            buckets.append(bucket)
        }
        guard !buckets.isEmpty else {
            throw QuotaError.parseFailure("Volcengine Agent Plan response had no usable AFP windows.")
        }

        return UsageSnapshot(buckets: buckets, planName: planName(from: result.planType))
    }

    private enum AgentPlanBucketKind {
        case session, weekly, monthly

        var id: String {
            switch self {
            case .session: return "volcengineAgentPlan.session"
            case .weekly:  return "volcengineAgentPlan.weekly"
            case .monthly: return "volcengineAgentPlan.monthly"
            }
        }
        var title: String {
            switch self {
            case .session: return "5 Hours"
            case .weekly:  return "Weekly"
            case .monthly: return "Monthly"
            }
        }
        var shortLabel: String {
            switch self {
            case .session: return "5h"
            case .weekly:  return "Wk"
            case .monthly: return "Mo"
            }
        }
        var windowSeconds: Int {
            switch self {
            case .session: return 5 * 3600
            case .weekly:  return 7 * 86_400
            case .monthly: return 30 * 86_400
            }
        }
    }

    private static func bucket(from window: AgentPlanWindow?, kind: AgentPlanBucketKind) -> QuotaBucket? {
        guard let window, let quota = window.quota, quota > 0 else { return nil }
        let used = window.used ?? 0
        let percent = max(0, min(100, used / quota * 100))
        // `ResetTime` is epoch milliseconds here (Coding Plan uses seconds).
        let resetAt = window.resetTime.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        return QuotaBucket(
            id: kind.id,
            title: kind.title,
            shortLabel: kind.shortLabel,
            usedPercent: percent,
            resetAt: resetAt,
            rawWindowSeconds: kind.windowSeconds
        )
    }

    static func planName(from planType: String?) -> String? {
        guard let raw = planType?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return "Agent Plan " + raw.prefix(1).uppercased() + raw.dropFirst()
    }

    private static func isAuthCode(_ code: String) -> Bool {
        code.contains("login") ||
            code.contains("auth") ||
            code.contains("invalidstate") ||
            code.contains("unauthenticated")
    }
}

// MARK: - Wire types

private struct AgentPlanUsageEnvelope: Decodable {
    let responseMetadata: AgentPlanResponseMetadata?
    let result: AgentPlanUsageResult?

    enum CodingKeys: String, CodingKey {
        case responseMetadata = "ResponseMetadata"
        case result = "Result"
    }
}

private struct AgentPlanResponseMetadata: Decodable {
    let error: AgentPlanMetadataError?

    enum CodingKeys: String, CodingKey { case error = "Error" }
}

private struct AgentPlanMetadataError: Decodable {
    let code: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case code = "Code"
        case message = "Message"
    }
}

private struct AgentPlanUsageResult: Decodable {
    let planType: String?
    let afpFiveHour: AgentPlanWindow?
    let afpWeekly: AgentPlanWindow?
    let afpMonthly: AgentPlanWindow?
    let afpDaily: AgentPlanWindow?

    enum CodingKeys: String, CodingKey {
        case planType = "PlanType"
        case afpFiveHour = "AFPFiveHour"
        case afpWeekly = "AFPWeekly"
        case afpMonthly = "AFPMonthly"
        case afpDaily = "AFPDaily"
    }
}

struct AgentPlanWindow: Decodable {
    let quota: Double?
    let used: Double?
    let resetTime: Int?
    let subscribeTime: Int?

    enum CodingKeys: String, CodingKey {
        case quota = "Quota"
        case used = "Used"
        case resetTime = "ResetTime"
        case subscribeTime = "SubscribeTime"
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
