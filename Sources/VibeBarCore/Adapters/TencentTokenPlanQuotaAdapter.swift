import Foundation

/// Tencent Cloud TokenHub **Token Plan** usage adapter.
///
/// Lives alongside `TencentHunyuanQuotaAdapter` (the Coding Plan
/// flavour). Token Plan is a different commercial product under the
/// TokenHub umbrella — credit-based instead of 5h/weekly/monthly
/// windows. It comes in two console variants:
///
/// - **Generic Token Plan** — `console.cloud.tencent.com/tokenhub/tokenplan`,
///   covers the cross-model credit bundle.
/// - **Hunyuan 3 Token Plan** — `console.cloud.tencent.com/tokenhub/tokenplan/hy`,
///   the HY3-only credit bundle. Tencent ships it under the same
///   TokenHub shell but it lives on a separate quota counter so we
///   can't fold the two into one BFF call.
///
/// Each Vibe Bar misc instance picks one variant via the `region`
/// field on `MiscProviderSettings` (`"generic"` or `"hunyuan"`; empty
/// defaults to `"generic"`). To track both at once, the user clones
/// the misc instance and sets the clone to the other variant — the
/// existing instance-clone path already gives each copy its own
/// credentials slot, quota cache, and visibility toggle. The misc
/// card shows one variant per instance, which matches the way the
/// Tencent console renders the two pages.
///
/// Auth: same `*.cloud.tencent.com` console session jar as the Coding
/// Plan adapter (`skey` + `uin` + HttpOnly login tickets). The
/// `csrfCode` URL parameter is computed locally from `skey` via
/// `TencentCsrfCode` — same algorithm Tencent's own console JS uses.
///
/// BFF: `POST https://console.cloud.tencent.com/cgi/capi`. The router
/// dispatches on `cmd` + `serviceType`. The exact values shipped here
/// were extrapolated from the Coding Plan capture in
/// `TencentHunyuanQuotaAdapter` — if Tencent ships a different cmd or
/// serviceType for Token Plan, swap `Variant.cgiCommand` /
/// `Variant.cgiServiceType` once a live capture is available. The
/// parser is intentionally tolerant of both the Coding Plan-style
/// `PerFiveHour/PerWeek/PerMonth` envelope and a credit-style
/// `TotalCredits/UsedCredits/RemainingCredits` envelope so either
/// shape lands a non-empty bucket on the card.
public struct TencentTokenPlanQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .tencentTokenPlan

    private let session: URLSession
    private let now: @Sendable () -> Date

    public static let cookieSpec = MiscCookieResolver.Spec(
        tool: .tencentTokenPlan,
        domains: [
            "console.cloud.tencent.com",
            "cloud.tencent.com",
            ".cloud.tencent.com"
        ],
        // Same trade-off as the Hunyuan Coding Plan jar: identity is
        // stitched from `skey` (HttpOnly) + `uin` + a handful of other
        // session keys we can't enumerate from JS, so ship the entire
        // jar matching the Tencent Cloud console domain set.
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
        let instanceID = AccountStore.miscInstanceID(fromAccountID: account.id, fallbackTool: .tencentTokenPlan)
        let settings = MiscProviderSettings.current(for: .tencentTokenPlan, instanceID: instanceID)
        let variant = Variant.from(settingsRegion: settings.region)

        let resolutions = MiscCookieResolver.resolveAll(for: TencentTokenPlanQuotaAdapter.cookieSpec, account: account)
        guard !resolutions.isEmpty else { throw QuotaError.noCredential }

        let queriedAt = now()
        let results = await MiscQuotaAggregator.gatherSlotResults(resolutions) { resolution in
            try await self.fetchOneSlot(resolution, variant: variant, account: account, queriedAt: queriedAt)
        }
        return MiscQuotaAggregator.aggregate(
            tool: .tencentTokenPlan,
            account: account,
            results: results,
            queriedAt: queriedAt
        )
    }

    private func fetchOneSlot(
        _ resolution: MiscCookieResolver.Resolution,
        variant: Variant,
        account: AccountIdentity,
        queriedAt: Date
    ) async throws -> AccountQuota {
        let snapshot = try await fetchSnapshot(using: resolution, variant: variant)
        return AccountQuota(
            accountId: account.id,
            tool: .tencentTokenPlan,
            buckets: snapshot.buckets,
            plan: snapshot.planName,
            email: account.email,
            queriedAt: queriedAt,
            error: nil
        )
    }

    private func fetchSnapshot(
        using resolution: MiscCookieResolver.Resolution,
        variant: Variant
    ) async throws -> TencentTokenPlanResponseParser.Snapshot {
        let pairs = CookieHeaderNormalizer.pairs(from: resolution.header)
        guard let skey = pairs.first(where: { $0.name == "skey" })?.value, !skey.isEmpty else {
            throw QuotaError.needsLogin
        }
        guard let rawUin = pairs.first(where: { $0.name == "uin" })?.value, !rawUin.isEmpty else {
            throw QuotaError.needsLogin
        }
        let uin = String(rawUin.drop(while: { !$0.isNumber }))
        guard !uin.isEmpty else {
            throw QuotaError.needsLogin
        }

        let csrfCode = TencentCsrfCode.compute(from: skey)
        let urlString = "https://console.cloud.tencent.com/cgi/capi" +
            "?cmd=\(variant.cgiCommand)&action=delegate&serviceType=\(variant.cgiServiceType)" +
            "&t=\(Self.epochMillis())&uin=\(uin)&csrfCode=\(csrfCode)"
        guard let url = URL(string: urlString) else {
            throw QuotaError.network("Tencent Token Plan: could not build BFF URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(resolution.header, forHTTPHeaderField: "Cookie")
        request.setValue("https://console.cloud.tencent.com", forHTTPHeaderField: "Origin")
        request.setValue(variant.refererURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        // The body mirrors the Hunyuan Coding Plan body — the same
        // `data: {Version: ...}` shape the CGI router expects for
        // `DescribePkg`-family commands. Variant-specific overrides
        // (e.g. a sub-model identifier) live on `Variant.bodyOverrides`.
        var body: [String: Any] = [
            "serviceType": variant.cgiServiceType,
            "cmd": variant.cgiCommand,
            "regionId": 1,
            "data": variant.requestData
        ]
        for (k, v) in variant.bodyOverrides { body[k] = v }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await self.session.data(for: request)
        } catch {
            throw QuotaError.network("Tencent Token Plan network error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Tencent Token Plan: invalid response object")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw QuotaError.needsLogin
            }
            if http.statusCode == 429 {
                throw QuotaError.rateLimited
            }
            throw QuotaError.network("Tencent Token Plan returned HTTP \(http.statusCode).")
        }

        return try TencentTokenPlanResponseParser.parse(data: data, variant: variant)
    }

    private static func epochMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

// MARK: - Variant

/// Which TokenHub Token Plan page the adapter targets for a given
/// instance. The user-facing setting is stored on
/// `MiscProviderSettings.region` so the existing settings UI / Codable
/// surface stays unchanged.
public enum TencentTokenPlanVariant: String, CaseIterable, Sendable {
    /// `console.cloud.tencent.com/tokenhub/tokenplan` — the cross-model
    /// credit bundle. Default when no setting is stored.
    case generic
    /// `console.cloud.tencent.com/tokenhub/tokenplan/hy` — the
    /// Hunyuan 3 credit bundle.
    case hunyuan

    public static func from(settingsRegion raw: String?) -> Self {
        switch raw?.lowercased() {
        case "hunyuan", "hy", "hy3":
            return .hunyuan
        case "generic", "general", "all", nil, "":
            return .generic
        default:
            return .generic
        }
    }

    public var settingsRegionID: String {
        switch self {
        case .generic: return "generic"
        case .hunyuan: return "hunyuan"
        }
    }

    public var displayLabel: String {
        switch self {
        case .generic: return "Generic Token Plan"
        case .hunyuan: return "Hunyuan 3 Token Plan"
        }
    }

    /// CGI BFF `cmd` parameter. Both variants use `DescribePkg` until a
    /// live capture proves Tencent ships a Token Plan-specific cmd —
    /// edit here when that lands.
    var cgiCommand: String { "DescribePkg" }

    /// CGI BFF `serviceType` parameter.
    ///
    /// - Generic Token Plan routes through TokenHub's own service
    ///   identifier (`tokenhub`). Captured from the live console.
    /// - HY3 Token Plan still routes through `hunyuan` because the
    ///   page lives under the Hunyuan product tree on the BFF side
    ///   even though the front-end URL is nested under TokenHub.
    var cgiServiceType: String {
        switch self {
        case .generic: return "tokenhub"
        case .hunyuan: return "hunyuan"
        }
    }

    /// Body payload posted under `data`. Both variants currently send
    /// `Version: "2023-09-01"` (matches the Coding Plan body); a
    /// `PkgType` selector is sent for HY3 so the router can pick the
    /// Token Plan counter rather than the Coding Plan one when the
    /// service shares both products. Update when a live capture
    /// clarifies the exact selector keys.
    var requestData: [String: Any] {
        switch self {
        case .generic:
            return ["Version": "2023-09-01"]
        case .hunyuan:
            return [
                "Version": "2023-09-01",
                "PkgType": "tokenplan"
            ]
        }
    }

    /// Optional extra top-level body fields. Empty by default; reserve
    /// for variant-specific overrides if the BFF eventually requires
    /// them.
    var bodyOverrides: [String: Any] { [:] }

    var refererURL: URL {
        switch self {
        case .generic:
            return URL(string: "https://console.cloud.tencent.com/tokenhub/tokenplan")!
        case .hunyuan:
            return URL(string: "https://console.cloud.tencent.com/tokenhub/tokenplan/hy")!
        }
    }
}

private typealias Variant = TencentTokenPlanVariant

// MARK: - Response parsing

enum TencentTokenPlanResponseParser {
    struct Snapshot {
        var buckets: [QuotaBucket]
        var planName: String?
    }

    static func parse(data: Data, variant: TencentTokenPlanVariant) throws -> Snapshot {
        guard !data.isEmpty else {
            throw QuotaError.parseFailure("Tencent Token Plan returned an empty body.")
        }

        // Peel the CGI router envelope identically to the Coding Plan
        // adapter (see `TencentHunyuanResponseParser`). Anything that
        // looks like the legacy `{Response: ...}` shape is left alone.
        let inner = try Self.unwrapCgiBffEnvelope(data)
        guard let root = try? JSONSerialization.jsonObject(with: inner) as? [String: Any] else {
            throw QuotaError.parseFailure("Tencent Token Plan inner payload was not a JSON object.")
        }

        let response = (root["Response"] as? [String: Any]) ?? root
        if let errorDict = response["Error"] as? [String: Any] {
            if Self.isAuthError(errorDict) { throw QuotaError.needsLogin }
            if Self.isRateLimitError(errorDict) { throw QuotaError.rateLimited }
            let msg = (errorDict["Message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "code \(errorDict["Code"] ?? "?")"
            throw QuotaError.network("Tencent Token Plan: \(msg)")
        }

        var buckets: [QuotaBucket] = []
        var planName: String?

        // Shape 1 — `PkgList[].UsageDetail.PerFiveHour/PerWeek/PerMonth`.
        // If Tencent ships Token Plan in the same envelope as the
        // Coding Plan, the existing time-window buckets light up.
        if let pkgList = response["PkgList"] as? [[String: Any]], let firstPkg = pkgList.first {
            planName = (firstPkg["PkgName"] as? String)?.trimmed
            if let detail = firstPkg["UsageDetail"] as? [String: Any] {
                buckets.append(contentsOf: parseTimeWindows(detail, variant: variant))
            }
        }

        // Shape 2 — flat credit envelope. Walk the response tree for
        // any dictionary that carries the recognised credit keys, then
        // surface a single aggregate "Credits" bucket. Matches the
        // pattern used by the Alibaba Token Plan parser for its
        // `TotalValue / SurplusValue` fallback.
        if buckets.isEmpty {
            if let creditDict = findFirstDictionary(
                matchingAnyKey: [
                    "TotalCredits", "TotalCreditValue", "TotalValue",
                    "UsedCredits", "UsedValue",
                    "RemainingCredits", "SurplusCredits", "RemainingValue", "SurplusValue"
                ],
                in: response
            ) {
                if let bucket = parseCreditEnvelope(creditDict, variant: variant) {
                    buckets.append(bucket)
                }
            }
        }

        // Shape 3 — `TokenInfo` / `TokenUsageDetail` nested under the
        // Response, as some Tencent BFFs ship for token-style plans.
        if buckets.isEmpty,
           let tokenInfo = findFirstDictionary(
               matchingAnyKey: ["TokenInfo", "TokenUsageDetail", "TokenPkg"],
               in: response
           ) {
            if let bucket = parseCreditEnvelope(tokenInfo, variant: variant) {
                buckets.append(bucket)
            }
        }

        guard !buckets.isEmpty else {
            throw QuotaError.parseFailure("Tencent Token Plan response had no usable usage envelope.")
        }

        return Snapshot(buckets: buckets, planName: planName ?? variant.displayLabel)
    }

    // MARK: - Wire-shape variants

    private static func parseTimeWindows(_ detail: [String: Any], variant: TencentTokenPlanVariant) -> [QuotaBucket] {
        var buckets: [QuotaBucket] = []
        let windows: [(id: String, title: String, shortLabel: String, key: String, seconds: Int)] = [
            (
                "tencentTokenPlan.\(variant.rawValue).fiveHour",
                "5 Hours",
                "5h",
                "PerFiveHour",
                5 * 3600
            ),
            (
                "tencentTokenPlan.\(variant.rawValue).weekly",
                "Weekly",
                "Wk",
                "PerWeek",
                7 * 86_400
            ),
            (
                "tencentTokenPlan.\(variant.rawValue).monthly",
                "Monthly",
                "Mo",
                "PerMonth",
                30 * 86_400
            )
        ]
        for spec in windows {
            guard let window = detail[spec.key] as? [String: Any] else { continue }
            let total = parseInt(window["Total"]) ?? 0
            let used = parseInt(window["Used"]) ?? 0
            let explicitPct = parseDouble(window["UsagePercent"])
            let percent: Double
            if let explicitPct {
                percent = max(0, min(100, explicitPct))
            } else if total > 0 {
                percent = max(0, min(100, Double(used) / Double(total) * 100))
            } else {
                continue
            }
            buckets.append(QuotaBucket(
                id: spec.id,
                title: spec.title,
                shortLabel: spec.shortLabel,
                usedPercent: percent,
                resetAt: parseShanghaiDate(window["EndTime"] as? String),
                rawWindowSeconds: spec.seconds
            ))
        }
        return buckets
    }

    private static func parseCreditEnvelope(
        _ dict: [String: Any],
        variant: TencentTokenPlanVariant
    ) -> QuotaBucket? {
        let total = parseDouble(
            dict["TotalCredits"]
                ?? dict["TotalCreditValue"]
                ?? dict["TotalValue"]
                ?? dict["Total"]
        ) ?? 0
        let used = parseDouble(
            dict["UsedCredits"]
                ?? dict["UsedValue"]
                ?? dict["Used"]
        )
        let remaining = parseDouble(
            dict["RemainingCredits"]
                ?? dict["SurplusCredits"]
                ?? dict["RemainingValue"]
                ?? dict["SurplusValue"]
                ?? dict["Remaining"]
        )

        guard total > 0 else { return nil }
        let usedValue: Double
        if let used {
            usedValue = max(0, used)
        } else if let remaining {
            usedValue = max(0, total - remaining)
        } else {
            return nil
        }
        let percent = max(0, min(100, usedValue / total * 100))

        let resetAt = parseShanghaiDate(dict["EndTime"] as? String)
            ?? parseShanghaiDate(dict["NextResetTime"] as? String)
            ?? parseShanghaiDate(dict["ExpireTime"] as? String)

        return QuotaBucket(
            id: "tencentTokenPlan.\(variant.rawValue).credits",
            title: "Credits",
            shortLabel: "Credits",
            usedPercent: percent,
            resetAt: resetAt,
            rawWindowSeconds: nil,
            groupTitle: variant.displayLabel
        )
    }

    // MARK: - CGI router unwrap

    private static func unwrapCgiBffEnvelope(_ data: Data) throws -> Data {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.parseFailure("Tencent Token Plan response not parseable.")
        }
        // Legacy direct shape: pass through.
        if root["Response"] != nil { return data }
        // Recognise the CGI router wrapper.
        guard let outerCode = (root["code"] as? NSNumber)?.intValue else {
            return data
        }
        if outerCode != 0 {
            throw cgiBffError(code: outerCode, layer: "outer", payload: root)
        }
        guard let middle = root["data"] as? [String: Any] else {
            throw QuotaError.parseFailure("Tencent Token Plan CGI envelope had no middle data block.")
        }
        if let middleCode = (middle["code"] as? NSNumber)?.intValue, middleCode != 0 {
            throw cgiBffError(code: middleCode, layer: "middle", payload: middle)
        }
        guard let inner = middle["data"] as? [String: Any] else {
            throw QuotaError.parseFailure("Tencent Token Plan CGI envelope had no inner data block.")
        }
        return try JSONSerialization.data(withJSONObject: inner)
    }

    private static func cgiBffError(code: Int, layer: String, payload: [String: Any]) -> Error {
        if code == 401 || code == 403 { return QuotaError.needsLogin }
        if code == 429 { return QuotaError.rateLimited }
        let message = (payload["message"] as? String)
            ?? (payload["msg"] as? String)
            ?? "code \(code)"
        return QuotaError.network("Tencent Token Plan CGI BFF \(layer) error: \(message)")
    }

    // MARK: - Error classification

    private static func isAuthError(_ error: [String: Any]) -> Bool {
        if let code = error["Code"] as? NSNumber, code.intValue == 401 || code.intValue == 403 {
            return true
        }
        if let codeStr = (error["Code"] as? String)?.lowercased() {
            if codeStr.contains("authfailure") || codeStr.contains("login") {
                return true
            }
        }
        if let msg = (error["Message"] as? String)?.lowercased() {
            if msg.contains("请登录") || msg.contains("not logged in") ||
               msg.contains("session invalid") || msg.contains("authentication") {
                return true
            }
        }
        return false
    }

    private static func isRateLimitError(_ error: [String: Any]) -> Bool {
        if let code = error["Code"] as? NSNumber, code.intValue == 429 {
            return true
        }
        if let codeStr = (error["Code"] as? String)?.lowercased(),
           codeStr.contains("requestlimit") || codeStr.contains("ratelimit") {
            return true
        }
        return false
    }

    // MARK: - Helpers

    private static func parseInt(_ value: Any?) -> Int? {
        switch value {
        case let v as Int: return v
        case let v as Double: return Int(v)
        case let v as NSNumber: return v.intValue
        case let v as String: return Int(v)
        default: return nil
        }
    }

    private static func parseDouble(_ value: Any?) -> Double? {
        switch value {
        case let v as Double: return v
        case let v as Int: return Double(v)
        case let v as NSNumber: return v.doubleValue
        case let v as String: return Double(v)
        default: return nil
        }
    }

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

    private static func findFirstDictionary(matchingAnyKey keys: [String], in value: Any) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if keys.contains(where: { dict[$0] != nil }) { return dict }
            for nested in dict.values {
                if let found = findFirstDictionary(matchingAnyKey: keys, in: nested) { return found }
            }
            return nil
        }
        if let arr = value as? [Any] {
            for item in arr {
                if let found = findFirstDictionary(matchingAnyKey: keys, in: item) { return found }
            }
        }
        return nil
    }
}

private extension String {
    var trimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
