import Foundation

/// Tencent Cloud Hunyuan Coding Plan usage adapter.
///
/// Auth: a permission-restricted CAM **sub-user** under the user's main
/// Tencent Cloud account. The adapter logs in with username + password
/// over HTTPS to obtain the short-lived `skey` session cookie via
/// `TencentSessionManager`, then derives the per-request `csrfCode`
/// URL parameter locally with `TencentCsrfCode`. `skey` typically
/// expires within a day; on 401/403/"Session Invalid" the adapter
/// wipes the cookie store and surfaces `needsLogin` so the next
/// refresh re-runs the login.
///
/// Endpoint: `POST https://console-hc.cloud.tencent.com/_api/hunyuan/DescribePkg`
/// with the standard Tencent console BFF envelope. Returns the
/// PerFiveHour / PerWeek / PerMonth windows for the user's plan.
public struct TencentHunyuanQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .tencentHunyuan

    private let sessionManager: TencentSessionManager
    private let now: @Sendable () -> Date

    public init(
        sessionManager: TencentSessionManager = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sessionManager = sessionManager
        self.now = now
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        let snapshot = try await fetchSnapshot()
        return AccountQuota(
            accountId: account.id,
            tool: .tencentHunyuan,
            buckets: snapshot.buckets,
            plan: snapshot.planName,
            email: account.email,
            queriedAt: now(),
            error: nil
        )
    }

    private func fetchSnapshot() async throws -> TencentHunyuanResponseParser.Snapshot {
        do {
            return try await fetchOnce()
        } catch QuotaError.needsLogin {
            // Single retry: drop the stale cookies and try one fresh
            // login + DescribePkg cycle. If THAT also says "needsLogin",
            // surface it so the misc card shows a Sign-in CTA.
            await sessionManager.wipeSession()
            return try await fetchOnce()
        }
    }

    private func fetchOnce() async throws -> TencentHunyuanResponseParser.Snapshot {
        let session = try await sessionManager.authedSession()
        guard let skey = await sessionManager.currentSkey(),
              let uin = await sessionManager.currentSubUin() else {
            throw QuotaError.needsLogin
        }
        let csrfCode = TencentCsrfCode.compute(from: skey)
        let urlString = "https://console-hc.cloud.tencent.com/_api/hunyuan/DescribePkg" +
            "?t=\(Self.epochMillis())&uin=\(uin)&csrfCode=\(csrfCode)"
        guard let url = URL(string: urlString) else {
            throw QuotaError.network("Tencent Hunyuan: could not build BFF URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://hunyuan.cloud.tencent.com", forHTTPHeaderField: "Origin")
        request.setValue("https://hunyuan.cloud.tencent.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        // The Version field is mandatory — empty data triggers "参数不能为空".
        let body: [String: Any] = [
            "serviceType": "hunyuan",
            "cmd": "DescribePkg",
            "regionId": 1,
            "data": ["Version": "2023-09-01"]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuotaError.network("Tencent Hunyuan network error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Tencent Hunyuan: invalid response object")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw QuotaError.needsLogin
            }
            if http.statusCode == 429 {
                throw QuotaError.rateLimited
            }
            throw QuotaError.network("Tencent Hunyuan returned HTTP \(http.statusCode).")
        }

        return try TencentHunyuanResponseParser.parse(data: data)
    }

    private static func epochMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

// MARK: - Response parsing

enum TencentHunyuanResponseParser {
    struct Snapshot {
        var buckets: [QuotaBucket]
        var planName: String?
    }

    static func parse(data: Data) throws -> Snapshot {
        guard !data.isEmpty else {
            throw QuotaError.parseFailure("Tencent Hunyuan returned an empty body.")
        }
        let envelope: TencentHunyuanEnvelope
        do {
            envelope = try JSONDecoder().decode(TencentHunyuanEnvelope.self, from: data)
        } catch {
            throw QuotaError.parseFailure(
                "Tencent Hunyuan response not parseable: \(error.localizedDescription)"
            )
        }

        if let error = envelope.response?.error {
            // Tencent's "please log in" envelope wears multiple disguises:
            // numeric `Code 4` plus a Chinese message, or just a string
            // `Code` of "AuthFailure". Map any of those to needsLogin so
            // the adapter retries the login.
            if Self.isAuthError(error) {
                throw QuotaError.needsLogin
            }
            if Self.isRateLimitError(error) {
                throw QuotaError.rateLimited
            }
            let message = error.message?.trimmed ?? "code \(error.code?.rawValue ?? "?")"
            throw QuotaError.network("Tencent Hunyuan: \(message)")
        }

        guard let pkgList = envelope.response?.pkgList, !pkgList.isEmpty else {
            throw QuotaError.parseFailure("Tencent Hunyuan response had no PkgList.")
        }
        // The console always renders the first plan; multi-plan accounts
        // are rare and we mirror the console's behaviour rather than
        // synthesising a roll-up.
        let pkg = pkgList[0]

        guard let detail = pkg.usageDetail else {
            throw QuotaError.parseFailure("Tencent Hunyuan plan had no UsageDetail block.")
        }

        var buckets: [QuotaBucket] = []
        if let bucket = makeBucket(
            id: "tencentHunyuan.fiveHour",
            title: "5 Hours",
            shortLabel: "5h",
            window: detail.perFiveHour,
            windowSeconds: 5 * 3600
        ) {
            buckets.append(bucket)
        }
        if let bucket = makeBucket(
            id: "tencentHunyuan.weekly",
            title: "Weekly",
            shortLabel: "Wk",
            window: detail.perWeek,
            windowSeconds: 7 * 86_400
        ) {
            buckets.append(bucket)
        }
        if let bucket = makeBucket(
            id: "tencentHunyuan.monthly",
            title: "Monthly",
            shortLabel: "Mo",
            window: detail.perMonth,
            windowSeconds: 30 * 86_400
        ) {
            buckets.append(bucket)
        }

        guard !buckets.isEmpty else {
            throw QuotaError.parseFailure("Tencent Hunyuan UsageDetail had no usable windows.")
        }
        return Snapshot(buckets: buckets, planName: pkg.pkgName?.trimmed)
    }

    private static func makeBucket(
        id: String,
        title: String,
        shortLabel: String,
        window: TencentHunyuanWindow?,
        windowSeconds: Int
    ) -> QuotaBucket? {
        guard let window else { return nil }
        let used = window.used ?? 0
        let total = window.total ?? 0
        let percent: Double
        if let p = window.usagePercent {
            percent = max(0, min(100, p))
        } else if total > 0 {
            percent = max(0, min(100, Double(used) / Double(total) * 100))
        } else {
            // No usage information at all — nothing meaningful to render.
            return nil
        }
        return QuotaBucket(
            id: id,
            title: title,
            shortLabel: shortLabel,
            usedPercent: percent,
            resetAt: parseShanghaiDate(window.endTime),
            rawWindowSeconds: windowSeconds
        )
    }

    private static func isAuthError(_ error: TencentHunyuanError) -> Bool {
        if let codeNumber = error.code?.intValue {
            if codeNumber == 401 || codeNumber == 403 { return true }
        }
        if let codeString = error.code?.stringValue?.lowercased() {
            if codeString.contains("authfailure") || codeString.contains("login") {
                return true
            }
        }
        if let message = error.message?.lowercased() {
            if message.contains("请登录") ||
               message.contains("session invalid") ||
               message.contains("not logged in") ||
               message.contains("authentication") {
                return true
            }
        }
        return false
    }

    private static func isRateLimitError(_ error: TencentHunyuanError) -> Bool {
        if let codeNumber = error.code?.intValue, codeNumber == 429 {
            return true
        }
        if let codeString = error.code?.stringValue?.lowercased(),
           codeString.contains("requestlimit") || codeString.contains("ratelimit") {
            return true
        }
        return false
    }

    /// `yyyy-MM-dd HH:mm:ss` in implicit Asia/Shanghai.
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

private struct TencentHunyuanEnvelope: Decodable {
    let response: TencentHunyuanResponse?

    enum CodingKeys: String, CodingKey { case response = "Response" }
}

private struct TencentHunyuanResponse: Decodable {
    let pkgList: [TencentHunyuanPkg]?
    let error: TencentHunyuanError?

    enum CodingKeys: String, CodingKey {
        case pkgList = "PkgList"
        case error = "Error"
    }
}

struct TencentHunyuanPkg: Decodable {
    let pkgName: String?
    let usageDetail: TencentHunyuanUsageDetail?

    enum CodingKeys: String, CodingKey {
        case pkgName = "PkgName"
        case usageDetail = "UsageDetail"
    }
}

struct TencentHunyuanUsageDetail: Decodable {
    let perFiveHour: TencentHunyuanWindow?
    let perWeek: TencentHunyuanWindow?
    let perMonth: TencentHunyuanWindow?

    enum CodingKeys: String, CodingKey {
        case perFiveHour = "PerFiveHour"
        case perWeek = "PerWeek"
        case perMonth = "PerMonth"
    }
}

struct TencentHunyuanWindow: Decodable {
    let total: Int?
    let used: Int?
    let usagePercent: Double?
    let endTime: String?

    enum CodingKeys: String, CodingKey {
        case total = "Total"
        case used = "Used"
        case usagePercent = "UsagePercent"
        case endTime = "EndTime"
    }
}

struct TencentHunyuanError: Decodable {
    let code: TencentCodeValue?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case code = "Code"
        case message = "Message"
    }
}

/// Tencent serializes `Error.Code` as either a number or a string
/// (e.g. `4` vs `"AuthFailure"`). Decode either shape.
struct TencentCodeValue: Decodable {
    let rawValue: String

    var intValue: Int? { Int(rawValue) }
    var stringValue: String? { Int(rawValue) == nil ? rawValue : nil }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) {
            self.rawValue = String(n)
            return
        }
        if let s = try? c.decode(String.self) {
            self.rawValue = s
            return
        }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "Unrecognized Tencent Error.Code value"
        )
    }
}

private extension String {
    var trimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
