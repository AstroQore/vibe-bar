import Foundation

/// Cursor (cursor.com) usage adapter.
///
/// Automatic auth prefers Cursor.app's read-only local session, then falls
/// back to the existing browser/manual cookie slots. Both paths resolve to a
/// first-party cursor.com cookie; Vibe Bar never refreshes Cursor's token.
///
/// Four endpoints:
///
/// 1. `GET /api/usage-summary` — Pro / Business / Enterprise / Free.
/// 2. `GET /api/auth/me` — identity (email, plan).
/// 3. `POST /api/dashboard/get-sand-usage-status` — Grok Bot weekly quota.
/// 4. `GET /api/usage?user=<id>` — fallback for legacy "request
///    plan" accounts whose summary is partial.
///
/// Output:
/// - **Cursor Models** — Cursor's first-party pool (Cursor Grok + Composer).
/// - **Other Models** — named third-party models.
/// - **Grok Bot / Weekly** — Cursor's cloud-only Bot allowance.
///
/// Edge-case tests (`CursorParserEdgeCasesTests`) pin the four
/// shapes the plan called out: Pro fractional percent (no `× 100`),
/// Enterprise `overall` / pooled fallback, legacy request plan,
/// stale-cookie 401 → cache clear + needsLogin.
public struct CursorQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .cursor

    private let session: URLSession
    private let now: @Sendable () -> Date
    private let resolutionPlanProvider: (@Sendable (AccountIdentity, Date) -> CursorSessionResolutionPlan)?

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
        self.resolutionPlanProvider = nil
    }

    init(
        session: URLSession,
        now: @escaping @Sendable () -> Date,
        resolutionPlanProvider: @escaping @Sendable (AccountIdentity, Date) -> CursorSessionResolutionPlan
    ) {
        self.session = session
        self.now = now
        self.resolutionPlanProvider = resolutionPlanProvider
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        let queriedAt = now()
        let plan = resolutionPlanProvider?(account, queriedAt)
            ?? CursorSessionResolver.plan(account: account, now: queriedAt)
        guard !plan.isEmpty else { throw QuotaError.noCredential }

        if let preferred = plan.preferred {
            do {
                return try await fetchOneSlot(preferred, account: account, queriedAt: queriedAt)
            } catch let error as QuotaError {
                guard error.isCredentialState, !plan.fallbacks.isEmpty else { throw error }
            }
        }

        guard !plan.fallbacks.isEmpty else { throw QuotaError.noCredential }
        let results = await MiscCookieAutoImporter.shared.gatherSlotResults(
            spec: CursorQuotaAdapter.cookieSpec,
            account: account,
            resolutions: plan.fallbacks
        ) { resolution in
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

        async let userInfoFetch = try? get(path: "/api/auth/me", cookieHeader: resolution.header)
        async let grokBotFetch = try? post(path: "/api/dashboard/get-sand-usage-status", cookieHeader: resolution.header)
        let userInfoData = await userInfoFetch
        let userInfo = userInfoData.flatMap(CursorResponseParser.decodeUserInfo)
        let grokBotUsage = (await grokBotFetch).flatMap(CursorResponseParser.decodeGrokBotUsage)

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
            grokBotUsage: grokBotUsage,
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

    private func post(path: String, cookieHeader: String) async throws -> Data {
        var request = URLRequest(url: CursorQuotaAdapter.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
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
            if http.statusCode == 401 || http.statusCode == 403 { throw QuotaError.needsLogin }
            if http.statusCode == 429 { throw QuotaError.rateLimited }
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

    static func decodeGrokBotUsage(data: Data) -> CursorGrokBotUsage? {
        try? JSONDecoder().decode(CursorGrokBotUsage.self, from: data)
    }

    /// Parse the assembled response into bucket form. Pulled out to
    /// its own function so unit tests can drive every edge case
    /// without faking HTTP.
    static func parseSummary(
        summary: CursorUsageSummary,
        userInfo: CursorUserInfo?,
        requestUsage: CursorRequestUsage?,
        grokBotUsage: CursorGrokBotUsage? = nil,
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

        let billingCycleStart = parseBillingCycleEnd(summary.billingCycleStart)
        let billingCycleEnd = parseBillingCycleEnd(summary.billingCycleEnd)
        let billingWindow = windowSeconds(start: billingCycleStart, end: billingCycleEnd)
        var buckets: [QuotaBucket] = []

        // Cursor renamed the old Auto/API lanes in August 2026. Preserve the
        // wire fields for compatibility, but use the product's current labels.
        if let auto = autoPct {
            buckets.append(QuotaBucket(
                id: "models",
                title: "Weekly",
                shortLabel: "Cursor",
                usedPercent: auto,
                resetAt: billingCycleEnd,
                rawWindowSeconds: billingWindow,
                groupTitle: "Cursor Models"
            ))
        }
        if let api = apiPct {
            buckets.append(QuotaBucket(
                id: "other_models",
                title: "Weekly",
                shortLabel: "Other",
                usedPercent: api,
                resetAt: billingCycleEnd,
                rawWindowSeconds: billingWindow,
                groupTitle: "Other Models"
            ))
        }

        // Older plan shapes expose one aggregate/request quota rather than the
        // two modern pools. Keep that usage visible under Cursor Models.
        if buckets.isEmpty {
            buckets.append(QuotaBucket(
                id: "models",
                title: "Weekly",
                shortLabel: "Cursor",
                usedPercent: totalPct,
                resetAt: billingCycleEnd,
                rawWindowSeconds: billingWindow,
                groupTitle: "Cursor Models"
            ))
        }

        if let bot = grokBotUsage,
           let percent = bot.usagePercent,
           bot.hasNonZeroIncludedLimit != false {
            let periodStart = parseBillingCycleEnd(bot.currentPeriodStart)
            let resetAt = parseBillingCycleEnd(bot.nextResetTimestampUtc)
            buckets.append(QuotaBucket(
                id: "grok_bot_weekly",
                title: "Weekly",
                shortLabel: "Grok Bot",
                usedPercent: clampPercent(percent),
                resetAt: resetAt,
                rawWindowSeconds: windowSeconds(start: periodStart, end: resetAt),
                groupTitle: "Grok Bot"
            ))
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

    private static func windowSeconds(start: Date?, end: Date?) -> Int? {
        guard let start, let end, end > start else { return nil }
        return Int(end.timeIntervalSince(start).rounded())
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
    public let billingCycleStart: String?
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

public struct CursorGrokBotUsage: Decodable, Sendable, Equatable {
    public let currentPeriodStart: String?
    public let nextResetTimestampUtc: String?
    public let usagePercent: Double?
    public let includedLimitZero: Bool?
    public let hasAvailableUsage: Bool?
    public let hasNonZeroIncludedLimit: Bool?
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
