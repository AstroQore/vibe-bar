import Foundation

/// Baidu Qianfan (`console.bce.baidu.com`) Coding Plan usage adapter.
///
/// Auth: console session cookies from `*.bce.baidu.com` plus the
/// Baidu Passport SSO jar on `*.baidu.com`. The user signs in once
/// via `MiscWebLoginController` (or pastes a Cookie header in
/// Settings); we ship the full jar to the console BFF since the
/// authoritative login tickets are HttpOnly and can't be enumerated
/// from JS.
///
/// Endpoint:
/// `GET https://console.bce.baidu.com/api/qianfan/charge/codingPlan/resourceList`
/// returns every Coding Plan resource attached to the account. The
/// dashboard at `https://console.bce.baidu.com/qianfan/resource/subscribe`
/// uses exactly this call to render the 5h / weekly / monthly tiles
/// and the plan-name pill — no CSRF token, no extra header, just the
/// console cookie jar.
///
/// Output: up to three buckets per active resource — 5-hour, weekly,
/// monthly — each built from `quota.fiveHour|week|month.{used,limit,resetAt}`.
/// Only the first `resourceStatus == "Running"` row is surfaced so a
/// recently-expired plan still in the list doesn't drown out the live
/// one.
public struct BaiduQianfanQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .baiduQianfan

    private let session: URLSession
    private let now: @Sendable () -> Date

    public static let cookieSpec = MiscCookieResolver.Spec(
        tool: .baiduQianfan,
        domains: [
            "console.bce.baidu.com",
            ".bce.baidu.com",
            "bce.baidu.com",
            ".baidu.com",
            "passport.baidu.com",
            "login.bce.baidu.com"
        ],
        // Empty `requiredNames` ships the full jar. Baidu's console
        // identity is stitched together from Passport (`BAIDUID`,
        // `BDUSS`, `STOKEN`, …) plus BCE-specific HttpOnly login
        // tickets we can't see from JS. The iFlytek / Tencent /
        // Volcengine / Alibaba adapters all take the same approach.
        requiredNames: []
    )

    private static let endpoint = URL(string:
        "https://console.bce.baidu.com/api/qianfan/charge/codingPlan/resourceList"
    )!

    public init(
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.now = now
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        let resolutions = MiscCookieResolver.resolveAll(for: BaiduQianfanQuotaAdapter.cookieSpec, account: account)
        guard !resolutions.isEmpty else { throw QuotaError.noCredential }

        let queriedAt = now()
        let results = await MiscQuotaAggregator.gatherSlotResults(resolutions) { resolution in
            try await self.fetchOneSlot(resolution, account: account, queriedAt: queriedAt)
        }
        return MiscQuotaAggregator.aggregate(
            tool: .baiduQianfan,
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
        var request = URLRequest(url: BaiduQianfanQuotaAdapter.endpoint)
        request.httpMethod = "GET"
        request.setValue(resolution.header, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://console.bce.baidu.com", forHTTPHeaderField: "Origin")
        request.setValue("https://console.bce.baidu.com/qianfan/resource/subscribe",
                         forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await self.session.data(for: request)
        } catch {
            throw QuotaError.network("Baidu Qianfan network error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Baidu Qianfan: invalid response object")
        }
        guard http.statusCode == 200 else {
            // BCE routes most auth failures back as HTTP 200 with a
            // `success: false` envelope, but a stale Passport ticket
            // can still surface as a 302 -> redirect-to-login that
            // URLSession reports as the final non-200 status. Treat
            // 401/403/redirects as needsLogin so the card flips to a
            // sign-in CTA rather than a generic network error.
            if http.statusCode == 401 || http.statusCode == 403 || (300..<400).contains(http.statusCode) {
                throw QuotaError.needsLogin
            }
            if http.statusCode == 429 {
                throw QuotaError.rateLimited
            }
            throw QuotaError.network("Baidu Qianfan returned HTTP \(http.statusCode).")
        }

        let snapshot = try BaiduQianfanResponseParser.parse(data: data, now: queriedAt)
        return AccountQuota(
            accountId: account.id,
            tool: .baiduQianfan,
            buckets: snapshot.buckets,
            plan: snapshot.planName,
            email: account.email,
            queriedAt: queriedAt,
            error: nil
        )
    }
}

// MARK: - Response parsing

enum BaiduQianfanResponseParser {
    struct Snapshot {
        var buckets: [QuotaBucket]
        var planName: String?
    }

    static func parse(data: Data, now: Date) throws -> Snapshot {
        guard !data.isEmpty else {
            throw QuotaError.parseFailure("Baidu Qianfan returned an empty body.")
        }
        let response: BaiduQianfanAPIResponse
        do {
            response = try JSONDecoder().decode(BaiduQianfanAPIResponse.self, from: data)
        } catch {
            throw QuotaError.parseFailure(
                "Baidu Qianfan response not parseable: \(error.localizedDescription)"
            )
        }

        // BCE auth-style failures: `success: false` with a `code` /
        // `message` envelope at the top level. Stale `BDUSS`/`STOKEN`
        // typically comes back as `code: "Forbidden"` /
        // `"NoPermission"` / `"NeedLogin"` here.
        if response.success == false {
            let codeLower = (response.code ?? "").lowercased()
            if codeLower.contains("needlogin") ||
               codeLower.contains("notlogin") ||
               codeLower.contains("unauthorized") ||
               codeLower.contains("unauthenticated") ||
               codeLower.contains("forbidden") ||
               codeLower.contains("nopermission") {
                throw QuotaError.needsLogin
            }
            let message = response.message?.trimmed
                ?? response.code?.trimmed
                ?? "request failed"
            throw QuotaError.network("Baidu Qianfan: \(message)")
        }

        guard let items = response.result?.items else {
            throw QuotaError.parseFailure("Baidu Qianfan response had no items array.")
        }

        // Prefer a `Running` resource. If none, fall back to the first
        // row that has a non-empty quota block — the dashboard renders
        // expired plans too (greyed out), but if the user has only one
        // we still want to surface it so they can see "0 left" rather
        // than the generic "no usable plan" state.
        let active = items.first(where: { $0.resourceStatus?.lowercased() == "running" })
            ?? items.first(where: { $0.quota?.hasAnyLimit == true })

        guard let row = active else {
            throw QuotaError.parseFailure("Baidu Qianfan response had no active Coding Plan rows.")
        }

        var buckets: [QuotaBucket] = []
        if let bucket = makeBucket(
            id: "baiduQianfan.5h",
            title: "5 Hours",
            shortLabel: "5h",
            window: row.quota?.fiveHour,
            windowSeconds: 5 * 3600
        ) {
            buckets.append(bucket)
        }
        if let bucket = makeBucket(
            id: "baiduQianfan.weekly",
            title: "Weekly",
            shortLabel: "Wk",
            window: row.quota?.week,
            windowSeconds: 7 * 86_400
        ) {
            buckets.append(bucket)
        }
        if let bucket = makeBucket(
            id: "baiduQianfan.monthly",
            title: "Monthly",
            shortLabel: "Mo",
            window: row.quota?.month,
            windowSeconds: nil,
            fallbackResetAt: parseISO8601(row.expiresAt)
        ) {
            buckets.append(bucket)
        }

        guard !buckets.isEmpty else {
            throw QuotaError.parseFailure("Baidu Qianfan active row had no usable quota windows.")
        }

        return Snapshot(buckets: buckets, planName: planLabel(for: row.planType))
    }

    private static func makeBucket(
        id: String,
        title: String,
        shortLabel: String,
        window: BaiduQianfanQuotaWindow?,
        windowSeconds: Int?,
        fallbackResetAt: Date? = nil
    ) -> QuotaBucket? {
        guard let window, let limit = window.limit, limit > 0 else { return nil }
        let used = max(0, window.used ?? 0)
        let percent = max(0, min(100, Double(used) / Double(limit) * 100))
        let resetAt = parseISO8601(window.resetAt) ?? fallbackResetAt
        return QuotaBucket(
            id: id,
            title: title,
            shortLabel: shortLabel,
            usedPercent: percent,
            resetAt: resetAt,
            rawWindowSeconds: windowSeconds
        )
    }

    /// `PRO` → `Pro`. Falls back to the raw value when the API ships
    /// an unexpected enum (e.g. `BASIC` or a marketing-only tier name).
    private static func planLabel(for raw: String?) -> String? {
        guard let raw = raw?.trimmed else { return nil }
        let upper = raw.uppercased()
        switch upper {
        case "PRO":   return "Pro"
        case "BASIC": return "Basic"
        case "FREE":  return "Free"
        case "TRIAL": return "Trial"
        default:
            // Title-case anything else so we don't surface raw enum
            // names like `ENTERPRISE_V2`.
            return upper
                .split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }
    }

    private static func parseISO8601(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmed else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: raw) { return date }
        return nil
    }
}

// MARK: - Wire types

private struct BaiduQianfanAPIResponse: Decodable {
    let success: Bool?
    let code: String?
    let message: String?
    let result: BaiduQianfanAPIResult?
}

private struct BaiduQianfanAPIResult: Decodable {
    let totalCount: Int?
    let items: [BaiduQianfanAPIItem]?
}

struct BaiduQianfanAPIItem: Decodable {
    let resourceId: String?
    let planType: String?
    let resourceStatus: String?
    let effectiveAt: String?
    let expiresAt: String?
    let quota: BaiduQianfanAPIQuota?
}

struct BaiduQianfanAPIQuota: Decodable {
    let fiveHour: BaiduQianfanQuotaWindow?
    let week: BaiduQianfanQuotaWindow?
    let month: BaiduQianfanQuotaWindow?

    var hasAnyLimit: Bool {
        ((fiveHour?.limit ?? 0) > 0) ||
        ((week?.limit ?? 0) > 0) ||
        ((month?.limit ?? 0) > 0)
    }
}

struct BaiduQianfanQuotaWindow: Decodable {
    let used: Int?
    let limit: Int?
    let resetAt: String?
}

private extension String {
    var trimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
