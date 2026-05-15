import Foundation

/// Cursor (cursor.com) usage adapter.
///
/// Cursor is web-only — there's no API key path. Auth flows through
/// `MiscCookieResolver` against `cursor.com` / `cursor.sh`; the
/// resolver hands us a browser-imported cookie header containing
/// the session token (one of `WorkosCursorSessionToken`,
/// `__Secure-next-auth.session-token`, `wos-session`, etc.).
///
/// Three endpoints in priority order:
///
/// 1. `GET /api/usage-summary` — Pro / Business / Enterprise / Free.
/// 2. `GET /api/auth/me` — identity (email, plan).
/// 3. `GET /api/usage?user=<id>` — fallback for legacy "request
///    plan" accounts whose summary is partial.
///
/// Output:
/// - **Total** (primary) — combined percent across the precedence
///   chain spelled out in `parseSummary`.
/// - **Auto** (secondary) — `autoPercentUsed` if present.
/// - **API** (tertiary) — `apiPercentUsed` if present.
/// - **On-demand** (extra row) — `$used / $limit` rendered through
///   `groupTitle` so the misc card surfaces it without polluting
///   `~/.vibebar/cost_history.json`. `supportsTokenCost == false`
///   for `.cursor`, so the global cost pipeline ignores it
///   regardless.
///
/// Edge-case tests (`CursorParserEdgeCasesTests`) pin the four
/// shapes the plan called out: Pro fractional percent (no `× 100`),
/// Enterprise `overall` / pooled fallback, legacy request plan,
/// stale-cookie 401 → cache clear + needsLogin.
public struct CursorQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .cursor

    private let session: URLSession
    private let now: @Sendable () -> Date

    public static let cookieSpec = MiscCookieResolver.Spec(
        tool: .cursor,
        domains: ["cursor.com", "www.cursor.com", "cursor.sh", "authenticator.cursor.sh"],
        requiredNames: [
            "WorkosCursorSessionToken",
            "__Secure-next-auth.session-token",
            "next-auth.session-token",
            "wos-session",
            "__Secure-wos-session",
            "authjs.session-token",
            "__Secure-authjs.session-token"
        ]
    )

    private static let baseURL = URL(string: "https://cursor.com")!

    public init(
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.now = now
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        let resolutions = MiscCookieResolver.resolveAll(for: CursorQuotaAdapter.cookieSpec)
        guard !resolutions.isEmpty else { throw QuotaError.noCredential }

        let queriedAt = now()
        let results = await MiscQuotaAggregator.gatherSlotResults(resolutions) { resolution in
            try await self.fetchOneSlot(resolution, account: account, queriedAt: queriedAt)
        }
        return MiscQuotaAggregator.aggregate(
            tool: .cursor,
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
        let summaryData = try await get(path: "/api/usage-summary", cookieHeader: resolution.header)
        let summary = try CursorResponseParser.decodeUsageSummary(data: summaryData)

        let userInfoData = try? await get(path: "/api/auth/me", cookieHeader: resolution.header)
        let userInfo = userInfoData.flatMap(CursorResponseParser.decodeUserInfo)

        // Legacy request-plan fallback fires when usage-summary is
        // missing the plan block entirely. Codexbar gates the
        // additional /api/usage?user=<id> call on the same condition.
        var requestUsage: CursorRequestUsage?
        if summary.individualUsage?.plan == nil,
           let userId = userInfo?.sub ?? userInfo?.id {
            requestUsage = try? await fetchRequestUsage(userId: userId, cookieHeader: resolution.header)
        }

        let snapshot = CursorResponseParser.parseSummary(
            summary: summary,
            userInfo: userInfo,
            requestUsage: requestUsage,
            now: queriedAt
        )

        return AccountQuota(
            accountId: account.id,
            tool: .cursor,
            buckets: snapshot.buckets,
            plan: snapshot.planName,
            email: userInfo?.email ?? account.email,
            queriedAt: queriedAt,
            error: nil
        )
    }

    private func get(path: String, cookieHeader: String) async throws -> Data {
        var request = URLRequest(url: CursorQuotaAdapter.baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuotaError.network("Cursor network error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Cursor: invalid response object")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw QuotaError.needsLogin
            }
            if http.statusCode == 429 {
                throw QuotaError.rateLimited
            }
            throw QuotaError.network("Cursor \(path) returned HTTP \(http.statusCode).")
        }
        return data
    }

    private func fetchRequestUsage(userId: String, cookieHeader: String) async throws -> CursorRequestUsage {
        var components = URLComponents(url: CursorQuotaAdapter.baseURL.appendingPathComponent("/api/usage"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "user", value: userId)]
        var request = URLRequest(url: components.url!)
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(CursorRequestUsage.self, from: data)
    }
}

// MARK: - Response parsing

enum CursorResponseParser {
    struct Snapshot {
        var buckets: [QuotaBucket]
        var planName: String?
    }

    static func decodeUsageSummary(data: Data) throws -> CursorUsageSummary {
        do {
            return try JSONDecoder().decode(CursorUsageSummary.self, from: data)
        } catch {
            throw QuotaError.parseFailure("Cursor usage-summary not parseable: \(error.localizedDescription)")
        }
    }

    static func decodeUserInfo(data: Data) -> CursorUserInfo? {
        try? JSONDecoder().decode(CursorUserInfo.self, from: data)
    }

    /// Parse the assembled response into bucket form. Pulled out to
    /// its own function so unit tests can drive every edge case
    /// without faking HTTP.
    static func parseSummary(
        summary: CursorUsageSummary,
        userInfo: CursorUserInfo?,
        requestUsage: CursorRequestUsage?,
        now: Date
    ) -> Snapshot {
        let plan = summary.individualUsage?.plan
        let overall = summary.individualUsage?.overall
        let pooled = summary.teamUsage?.pooled

        // Cursor's percent fields are already in percent units even
        // when fractional (0.36 means 0.36%, not 36%). The plan
        // explicitly pins this — we feed the values through
        // `clampPercent` and don't multiply by 100.
        let autoPct = clampPercent(plan?.autoPercentUsed)
        let apiPct = clampPercent(plan?.apiPercentUsed)

        let totalPct: Double = {
            if let provided = plan?.totalPercentUsed {
                return clampPercent(provided)
            }
            if let auto = autoPct, let api = apiPct {
                return clampPercent((auto + api) / 2)
            }
            if let api = apiPct { return api }
            if let auto = autoPct { return auto }
            if let limit = plan?.limit, limit > 0, let used = plan?.used {
                return clampPercent(Double(used) / Double(limit) * 100)
            }
            if let used = overall?.used, let limit = overall?.limit, limit > 0 {
                return clampPercent(Double(used) / Double(limit) * 100)
            }
            if let used = pooled?.used, let limit = pooled?.limit, limit > 0 {
                return clampPercent(Double(used) / Double(limit) * 100)
            }
            // Legacy request plan: usage / max if present.
            if let req = requestUsage?.gpt4,
               let max = req.maxRequestUsage, max > 0 {
                let used = req.numRequestsTotal ?? req.numRequests ?? 0
                return clampPercent(Double(used) / Double(max) * 100)
            }
            return 0
        }()

        var buckets: [QuotaBucket] = [
            QuotaBucket(
                id: "cursor.total",
                title: "Total",
                shortLabel: "Total",
                usedPercent: totalPct,
                resetAt: parseBillingCycleEnd(summary.billingCycleEnd),
                rawWindowSeconds: nil
            )
        ]

        if let auto = autoPct {
            buckets.append(QuotaBucket(
                id: "cursor.auto",
                title: "Auto",
                shortLabel: "Auto",
                usedPercent: auto,
                resetAt: parseBillingCycleEnd(summary.billingCycleEnd),
                rawWindowSeconds: nil
            ))
        }
        if let api = apiPct {
            buckets.append(QuotaBucket(
                id: "cursor.api",
                title: "API",
                shortLabel: "API",
                usedPercent: api,
                resetAt: parseBillingCycleEnd(summary.billingCycleEnd),
                rawWindowSeconds: nil
            ))
        }

        // On-demand budget. Surface as a regular bucket with the
        // dollar amounts in `groupTitle` so the misc card can lift
        // them as a discrete extra row. We deliberately don't fold
        // on-demand spend into the global cost pipeline — the
        // `tool.supportsTokenCost == false` short-circuit keeps it
        // out of `cost_history.json`.
        if let onDemand = summary.individualUsage?.onDemand,
           let used = onDemand.used {
            let usedDollars = Double(used) / 100.0
            let label: String
            let percent: Double
            if let limit = onDemand.limit, limit > 0 {
                let limitDollars = Double(limit) / 100.0
                label = String(format: "On-demand: $%.2f / $%.2f", usedDollars, limitDollars)
                percent = clampPercent(Double(used) / Double(limit) * 100)
            } else {
                label = String(format: "On-demand: $%.2f / unlimited", usedDollars)
                percent = 0
            }
            var bucket = QuotaBucket(
                id: "cursor.onDemand",
                title: "On-demand",
                shortLabel: "OD",
                usedPercent: percent,
                resetAt: nil,
                rawWindowSeconds: nil
            )
            bucket.groupTitle = label
            buckets.append(bucket)
        }

        let planName = displayPlanName(
            membershipType: summary.membershipType,
            requestUsage: requestUsage
        )
        return Snapshot(buckets: buckets, planName: planName)
    }

    private static func clampPercent(_ value: Double?) -> Double? {
        guard let value else { return nil }
        return max(0, min(100, value))
    }

    private static func clampPercent(_ value: Double) -> Double {
        max(0, min(100, value))
    }

    private static func parseBillingCycleEnd(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private static func displayPlanName(
        membershipType: String?,
        requestUsage: CursorRequestUsage?
    ) -> String? {
        if let raw = membershipType?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            switch raw.lowercased() {
            case "free":            return "Free"
            case "free_trial":      return "Free Trial"
            case "pro":             return "Pro"
            case "business":        return "Business"
            case "enterprise":      return "Enterprise"
            default:                return raw.capitalized
            }
        }
        if requestUsage?.gpt4?.maxRequestUsage != nil {
            return "Legacy"
        }
        return nil
    }
}

// MARK: - Wire types

public struct CursorUsageSummary: Decodable, Sendable {
    public let individualUsage: CursorIndividualUsage?
    public let teamUsage: CursorTeamUsage?
    public let membershipType: String?
    public let billingCycleEnd: String?
}

public struct CursorIndividualUsage: Decodable, Sendable {
    public let plan: CursorPlanUsage?
    public let onDemand: CursorOnDemandUsage?
    public let overall: CursorPlanUsage?
}

public struct CursorPlanUsage: Decodable, Sendable {
    public let used: Int?
    public let limit: Int?
    public let autoPercentUsed: Double?
    public let apiPercentUsed: Double?
    public let totalPercentUsed: Double?
}

public struct CursorOnDemandUsage: Decodable, Sendable {
    public let used: Int?
    public let limit: Int?
}

public struct CursorTeamUsage: Decodable, Sendable {
    public let pooled: CursorPlanUsage?
    public let onDemand: CursorOnDemandUsage?
}

public struct CursorUserInfo: Decodable, Sendable {
    public let email: String?
    public let id: String?
    public let sub: String?
}

public struct CursorRequestUsage: Decodable, Sendable {
    public let gpt4: CursorRequestUsageEntry?

    enum CodingKeys: String, CodingKey {
        case gpt4 = "gpt-4"
    }
}

public struct CursorRequestUsageEntry: Decodable, Sendable {
    public let numRequests: Int?
    public let numRequestsTotal: Int?
    public let maxRequestUsage: Int?
}
