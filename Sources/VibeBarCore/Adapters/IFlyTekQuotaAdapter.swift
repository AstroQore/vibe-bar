import Foundation

/// iFlytek (`maas.xfyun.cn`) Spark Coding Plan usage adapter.
///
/// Auth: the `atp-auth-token` HttpOnly cookie issued by passport.xfyun.cn
/// after a successful login. iFlytek SSO supports WeChat scan, phone OTP,
/// and username + password — but the password path always triggers a
/// GeeTest 9-grid CAPTCHA, so headless login from a menu-bar app is not
/// feasible. The user signs in once in their browser and Vibe Bar imports
/// the cookie via `MiscCookieResolver`.
///
/// Endpoint:
/// `GET https://maas.xfyun.cn/api/v1/gpt-finetune/coding-plan/list?page=1&size=20`
/// returns every plan attached to the account (paid + unpaid). Unpaid rows
/// have all `*Limit` fields set to `null`, so the adapter filters them out
/// before picking the first paid row to render.
///
/// Output: up to four buckets per plan — daily (optional), 5-hour, weekly,
/// and the lifetime package window. The package's `expiresAt` is the only
/// reliable reset timestamp surfaced by the API; the rolling-window buckets
/// don't carry one.
public struct IFlyTekQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .iflytek

    private let session: URLSession
    private let now: @Sendable () -> Date

    public static let cookieSpec = MiscCookieResolver.Spec(
        tool: .iflytek,
        domains: [
            "maas.xfyun.cn",
            ".maas.xfyun.cn",
            "passport.xfyun.cn",
            "xfyun.cn",
            ".xfyun.cn"
        ],
        requiredNames: ["atp-auth-token"]
    )

    private static let endpoint = URL(string:
        "https://maas.xfyun.cn/api/v1/gpt-finetune/coding-plan/list?page=1&size=20"
    )!

    public init(
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.now = now
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        guard let resolution = MiscCookieResolver.resolve(for: IFlyTekQuotaAdapter.cookieSpec) else {
            throw QuotaError.noCredential
        }

        var request = URLRequest(url: IFlyTekQuotaAdapter.endpoint)
        request.httpMethod = "GET"
        request.setValue(resolution.header, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://maas.xfyun.cn", forHTTPHeaderField: "Origin")
        request.setValue("https://maas.xfyun.cn/packageSubscription",
                         forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await self.session.data(for: request)
        } catch {
            throw QuotaError.network("iFlytek network error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("iFlytek: invalid response object")
        }
        guard http.statusCode == 200 else {
            // iFlytek normally returns 200 even for auth failures (see parser),
            // but a non-200 still happens on infrastructure errors.
            if http.statusCode == 401 || http.statusCode == 403 {
                CookieHeaderCache.clear(for: .iflytek)
                throw QuotaError.needsLogin
            }
            if http.statusCode == 429 {
                throw QuotaError.rateLimited
            }
            throw QuotaError.network("iFlytek returned HTTP \(http.statusCode).")
        }

        let snapshot: IFlyTekResponseParser.Snapshot
        do {
            snapshot = try IFlyTekResponseParser.parse(data: data, now: now())
        } catch let qe as QuotaError {
            if case .needsLogin = qe {
                CookieHeaderCache.clear(for: .iflytek)
            }
            throw qe
        }
        return AccountQuota(
            accountId: account.id,
            tool: .iflytek,
            buckets: snapshot.buckets,
            plan: snapshot.planName,
            email: account.email,
            queriedAt: now(),
            error: nil
        )
    }
}

// MARK: - Response parsing

enum IFlyTekResponseParser {
    struct Snapshot {
        var buckets: [QuotaBucket]
        var planName: String?
    }

    static func parse(data: Data, now: Date) throws -> Snapshot {
        guard !data.isEmpty else {
            throw QuotaError.parseFailure("iFlytek returned an empty body.")
        }
        let response: IFlyTekAPIResponse
        do {
            response = try JSONDecoder().decode(IFlyTekAPIResponse.self, from: data)
        } catch {
            throw QuotaError.parseFailure("iFlytek response not parseable: \(error.localizedDescription)")
        }

        // Cookie-stale comes back as HTTP 200 + `code: 4001` on this endpoint.
        if let code = response.code, code != 0 {
            if code == 4001 {
                throw QuotaError.needsLogin
            }
            let message = response.message?.trimmed ?? "code \(code)"
            throw QuotaError.network("iFlytek: \(message)")
        }

        guard let rows = response.data?.rows else {
            throw QuotaError.parseFailure("iFlytek response had no rows array.")
        }

        // Filter out unpaid rows — they show up with all `*Limit` fields set
        // to null. A row is "active" if any limit > 0.
        guard let row = rows.first(where: { $0.isActive }) else {
            throw QuotaError.parseFailure("iFlytek response had no active coding plan rows.")
        }
        guard let usage = row.codingPlanUsageDTO else {
            throw QuotaError.parseFailure("iFlytek active row had no usage block.")
        }

        var buckets: [QuotaBucket] = []
        if let bucket = makeBucket(
            id: "iflytek.daily",
            title: "Daily",
            shortLabel: "Day",
            used: usage.dailyUsage,
            limit: usage.dailyLimit,
            windowSeconds: 86_400
        ) {
            buckets.append(bucket)
        }
        if let bucket = makeBucket(
            id: "iflytek.fiveHour",
            title: "5 Hours",
            shortLabel: "5h",
            used: usage.rp5hUsage,
            limit: usage.rp5hLimit,
            windowSeconds: 5 * 3600
        ) {
            buckets.append(bucket)
        }
        if let bucket = makeBucket(
            id: "iflytek.weekly",
            title: "Weekly",
            shortLabel: "Wk",
            used: usage.rpwUsage,
            limit: usage.rpwLimit,
            windowSeconds: 7 * 86_400
        ) {
            buckets.append(bucket)
        }
        if let bucket = makeBucket(
            id: "iflytek.package",
            title: "Package",
            shortLabel: "Pkg",
            used: usage.packageUsage,
            limit: usage.packageLimit,
            windowSeconds: nil,
            resetAt: parseShanghaiDate(row.expiresAt)
        ) {
            buckets.append(bucket)
        }

        guard !buckets.isEmpty else {
            throw QuotaError.parseFailure("iFlytek active row had no usable usage windows.")
        }

        // The `list` endpoint doesn't carry the human-readable plan name —
        // surface a placeholder if we ever want to call /coding-plan/package
        // for it later. Until then leave plan=nil so the badge falls back to
        // the static subtitle ("Coding Plan").
        return Snapshot(buckets: buckets, planName: nil)
    }

    private static func makeBucket(
        id: String,
        title: String,
        shortLabel: String,
        used: Int?,
        limit: Int?,
        windowSeconds: Int?,
        resetAt: Date? = nil
    ) -> QuotaBucket? {
        guard let limit, limit > 0 else { return nil }
        let usedValue = max(0, used ?? 0)
        let percent = max(0, min(100, Double(usedValue) / Double(limit) * 100))
        return QuotaBucket(
            id: id,
            title: title,
            shortLabel: shortLabel,
            usedPercent: percent,
            resetAt: resetAt,
            rawWindowSeconds: windowSeconds
        )
    }

    /// `yyyy-MM-dd HH:mm:ss` strings on this API are implicitly Asia/Shanghai.
    private static func parseShanghaiDate(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: raw)
    }
}

// MARK: - Wire types

private struct IFlyTekAPIResponse: Decodable {
    let code: Int?
    let message: String?
    let data: IFlyTekAPIData?
}

private struct IFlyTekAPIData: Decodable {
    let rows: [IFlyTekAPIRow]?
}

struct IFlyTekAPIRow: Decodable {
    let id: Int64?
    let appId: String?
    let createTime: String?
    let expiresAt: String?
    let codingPlanUsageDTO: IFlyTekAPIUsage?

    var isActive: Bool {
        guard let usage = codingPlanUsageDTO else { return false }
        let totals: [Int?] = [usage.rp5hLimit, usage.rpwLimit, usage.packageLimit, usage.dailyLimit]
        return totals.contains(where: { ($0 ?? 0) > 0 })
    }
}

struct IFlyTekAPIUsage: Decodable {
    let dailyLimit: Int?
    let dailyUsage: Int?
    let rp5hLimit: Int?
    let rp5hUsage: Int?
    let rpwLimit: Int?
    let rpwUsage: Int?
    let packageLimit: Int?
    let packageUsage: Int?
    let packageLeft: Int?
}

private extension String {
    var trimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
