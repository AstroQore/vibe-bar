import Foundation

/// Xiaomi MiMo (`platform.xiaomimimo.com`) Token Plan usage adapter.
///
/// Auth: three same-domain cookies set by Xiaomi's `/sts` callback after a
/// Xiaomi-account SSO login — `userId`, `api-platform_slh`, `api-platform_ph`.
/// Source resolution flows through `MiscCookieResolver`. Xiaomi SSO runs a
/// miVerify slider captcha so headless username/password login is not viable;
/// users sign in once in their browser and Vibe Bar imports the cookies.
///
/// Endpoint:
/// `GET https://platform.xiaomimimo.com/api/v1/tokenPlan/usage`
/// returns the monthly Token Plan counter the console renders on its
/// Subscription page. The `monthUsage.items[name=month_total_token]` entry is
/// preferred over the alternative `usage.items[name=plan_total_token]` because
/// it matches the headline number on the console exactly.
///
/// Output: a single QuotaBucket carrying the month's used / limit tokens.
public struct MimoQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .mimo

    private let session: URLSession
    private let now: @Sendable () -> Date

    public static let cookieSpec = MiscCookieResolver.Spec(
        tool: .mimo,
        domains: [
            "platform.xiaomimimo.com",
            ".xiaomimimo.com",
            "xiaomimimo.com"
        ],
        // Four cookies, not three. The provider research doc spelled out
        // `userId` + `api-platform_slh` + `api-platform_ph` as the only
        // names needed, but live MiMo also rejects requests that omit
        // `api-platform_serviceToken` (set by `/sts` alongside the others)
        // — verified against status=401 + JSON body redirecting to the
        // Xiaomi SSO loginUrl when the token is missing. Browsers send
        // it implicitly with `credentials: 'include'` because it's
        // HttpOnly; we have to list it so our minimised header doesn't
        // drop it.
        requiredNames: ["userId", "api-platform_slh", "api-platform_ph", "api-platform_serviceToken"]
    )

    private static let endpoint = URL(string:
        "https://platform.xiaomimimo.com/api/v1/tokenPlan/usage"
    )!

    public init(
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.now = now
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        guard let resolution = MiscCookieResolver.resolve(for: MimoQuotaAdapter.cookieSpec) else {
            throw QuotaError.noCredential
        }

        var request = URLRequest(url: MimoQuotaAdapter.endpoint)
        request.httpMethod = "GET"
        request.setValue(resolution.header, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://platform.xiaomimimo.com", forHTTPHeaderField: "Origin")
        request.setValue("https://platform.xiaomimimo.com/console/plan-manage",
                         forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await self.session.data(for: request)
        } catch {
            throw QuotaError.network("MiMo network error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("MiMo: invalid response object")
        }
        guard http.statusCode == 200 else {
            // Removing any one of the three required cookies returns HTTP 401
            // with body `{"code":401,...}`. Drop the cached header so the next
            // refresh re-imports rather than retrying with the stale cookies.
            if http.statusCode == 401 || http.statusCode == 403 {
                CookieHeaderCache.clear(for: .mimo)
                throw QuotaError.needsLogin
            }
            if http.statusCode == 429 {
                throw QuotaError.rateLimited
            }
            throw QuotaError.network("MiMo returned HTTP \(http.statusCode).")
        }

        let snapshot = try MimoResponseParser.parse(data: data, now: now())
        return AccountQuota(
            accountId: account.id,
            tool: .mimo,
            buckets: snapshot.buckets,
            plan: snapshot.planName,
            email: account.email,
            queriedAt: now(),
            error: nil
        )
    }
}

// MARK: - Response parsing

enum MimoResponseParser {
    struct Snapshot {
        var buckets: [QuotaBucket]
        var planName: String?
    }

    static func parse(data: Data, now: Date) throws -> Snapshot {
        guard !data.isEmpty else {
            throw QuotaError.parseFailure("MiMo returned an empty body.")
        }
        let response: MimoAPIResponse
        do {
            response = try JSONDecoder().decode(MimoAPIResponse.self, from: data)
        } catch {
            throw QuotaError.parseFailure("MiMo response not parseable: \(error.localizedDescription)")
        }

        if let code = response.code, code != 0 {
            // Cookie-stale mirrors the HTTP status (`code == 401`); flag that
            // through `needsLogin` instead of `network` so the misc card shows
            // a "Sign in" CTA.
            if code == 401 || code == 403 {
                throw QuotaError.needsLogin
            }
            let message = response.message?.trimmed ?? "code \(code)"
            throw QuotaError.network("MiMo: \(message)")
        }

        guard let dataField = response.data else {
            throw QuotaError.parseFailure("MiMo response had no data field.")
        }

        // Prefer the headline `monthUsage.month_total_token` row; fall back to
        // `usage.plan_total_token` for accounts that only expose the legacy
        // shape. `compensation_total_token` is bonus credits — its limit can
        // be 0 even on healthy accounts, so it never wins.
        let primary = pickItem(in: dataField.monthUsage?.items, name: "month_total_token")
            ?? pickItem(in: dataField.usage?.items, name: "plan_total_token")

        guard let item = primary else {
            throw QuotaError.parseFailure("MiMo response had no usable token bucket.")
        }

        let limit = item.intLimit
        let used = item.intUsed
        let percent: Double
        if limit > 0 {
            percent = max(0, min(100, Double(used) / Double(limit) * 100))
        } else if let p = item.percent {
            // `percent` is a 0..1 fraction in the Xiaomi response; convert.
            percent = max(0, min(100, p * 100))
        } else {
            percent = 0
        }

        let bucket = QuotaBucket(
            id: "mimo.month",
            title: "Monthly",
            shortLabel: "Month",
            usedPercent: percent,
            resetAt: nil,
            rawWindowSeconds: 30 * 86_400
        )

        return Snapshot(buckets: [bucket], planName: nil)
    }

    private static func pickItem(in items: [MimoAPIItem]?, name: String) -> MimoAPIItem? {
        items?.first(where: { $0.name == name })
    }
}

// MARK: - Wire types

private struct MimoAPIResponse: Decodable {
    let code: Int?
    let message: String?
    let data: MimoAPIData?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = MimoQuotaDecoding.int(c, forKey: .code)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        data = try c.decodeIfPresent(MimoAPIData.self, forKey: .data)
    }

    enum CodingKeys: String, CodingKey { case code, message, data }
}

private struct MimoAPIData: Decodable {
    let monthUsage: MimoAPIBucket?
    let usage: MimoAPIBucket?
}

private struct MimoAPIBucket: Decodable {
    let percent: Double?
    let items: [MimoAPIItem]?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        percent = try c.decodeIfPresent(Double.self, forKey: .percent)
        items = try c.decodeIfPresent([MimoAPIItem].self, forKey: .items)
    }

    enum CodingKeys: String, CodingKey { case percent, items }
}

struct MimoAPIItem: Decodable {
    let name: String?
    let used: MimoNumeric?
    let limit: MimoNumeric?
    let percent: Double?

    var intUsed: Int { used?.value ?? 0 }
    var intLimit: Int { limit?.value ?? 0 }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        used = try c.decodeIfPresent(MimoNumeric.self, forKey: .used)
        limit = try c.decodeIfPresent(MimoNumeric.self, forKey: .limit)
        percent = try c.decodeIfPresent(Double.self, forKey: .percent)
    }

    enum CodingKeys: String, CodingKey { case name, used, limit, percent }
}

/// Big-number counter that arrives as either an integer or a stringified
/// integer depending on which Xiaomi backend serialized it.
struct MimoNumeric: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) { self.value = n; return }
        if let n = try? c.decode(Int64.self) { self.value = Int(n); return }
        if let d = try? c.decode(Double.self) { self.value = Int(d); return }
        if let s = try? c.decode(String.self),
           let n = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            self.value = n
            return
        }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "Unrecognized MiMo numeric value"
        )
    }
}

private enum MimoQuotaDecoding {
    static func int<K: CodingKey>(_ c: KeyedDecodingContainer<K>, forKey key: K) -> Int? {
        if let v = try? c.decodeIfPresent(Int.self, forKey: key) { return v }
        if let v = try? c.decodeIfPresent(Int64.self, forKey: key) { return Int(v) }
        if let v = try? c.decodeIfPresent(Double.self, forKey: key) { return Int(v) }
        if let v = try? c.decodeIfPresent(String.self, forKey: key),
           let n = Int(v.trimmingCharacters(in: .whitespacesAndNewlines)) { return n }
        return nil
    }
}

private extension String {
    var trimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
