import Foundation

/// Alibaba Qwen / Bailian Coding Plan usage adapter.
///
/// Two auth paths, tried in order:
/// 1. **API key** (DashScope `sk-…`) — pasted in Settings, hits the
///    public gateway directly. Cleanest path; only Coding Plan users
///    who explicitly minted an API key have this.
/// 2. **Console cookie** — the `*.aliyun.com` / `*.alibabacloud.com`
///    session jar. Adapter scrapes `SEC_TOKEN` from the dashboard
///    HTML, then POSTs the console RPC with `sec_token` + a
///    `cornerstoneParam` blob the same way the Bailian / ModelStudio
///    page does in the browser. This is what most Coding Plan
///    customers end up using, since they signed up via the console
///    rather than DashScope.
///
/// The user picks a region — international (`ap-southeast-1`,
/// modelstudio.console.alibabacloud.com) or china-mainland
/// (`cn-beijing`, bailian.console.aliyun.com) — or leaves it blank
/// for auto-failover.
///
/// Output: up to three `QuotaBucket`s — 5-hour (primary), weekly
/// (secondary), monthly (tertiary). Each is built from used / total
/// counts (`per5HourUsedQuota` / `per5HourTotalQuota` etc.) and the
/// matching `perXxxQuotaNextRefreshTime` reset stamp.
public struct AlibabaQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .alibaba

    private let session: URLSession
    private let now: @Sendable () -> Date

    public static let cookieSpec = MiscCookieResolver.Spec(
        tool: .alibaba,
        domains: [
            "bailian.console.aliyun.com",
            "modelstudio.console.alibabacloud.com",
            ".aliyun.com",
            ".alibabacloud.com"
        ],
        // Empty `requiredNames` ships the entire jar — Alibaba's
        // console identity stitches together `login_aliyunid_csrf`,
        // `cna`, plus a handful of HttpOnly login tickets we can't
        // enumerate from JS. Same approach as the iFlytek / Tencent
        // / Volcengine adapters.
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
        let settings = MiscProviderSettings.current(for: .alibaba)

        let preferred: [AlibabaRegion]
        switch settings.region {
        case "ap-southeast-1", "intl", "international":
            preferred = [.international]
        case "cn-beijing", "cn", "china":
            preferred = [.chinaMainland]
        default:
            preferred = [.international, .chinaMainland]
        }

        let queriedAt = now()
        let hasAPIKey = settings.allowsAPIOrOAuthAccess && {
            guard let key = MiscCredentialStore.readString(tool: .alibaba, kind: .apiKey),
                  !key.isEmpty else { return false }
            return true
        }()
        let cookieResolutions = MiscCookieResolver.resolveAll(for: AlibabaQuotaAdapter.cookieSpec)

        // Path 1: API key (preferred when present — fewer round-trips,
        // no SEC_TOKEN scrape). Fall through to the cookie path on
        // auth-style failures so a stale `sk-…` doesn't permanently
        // black-hole users who also have a console session. The API
        // key returns a single account; aggregation is a no-op there.
        if hasAPIKey,
           let apiKey = MiscCredentialStore.readString(tool: .alibaba, kind: .apiKey),
           !apiKey.isEmpty {
            do {
                return try await fetchViaAPIKey(
                    apiKey: apiKey,
                    regions: preferred,
                    account: account,
                    queriedAt: queriedAt
                )
            } catch let qe as QuotaError {
                switch qe {
                case .needsLogin, .noCredential:
                    if cookieResolutions.isEmpty { throw qe }
                    // else fall through to cookie path
                default:
                    throw qe
                }
            }
        }

        // Path 2: console cookies. Average buckets across every
        // imported cookie slot.
        guard !cookieResolutions.isEmpty else {
            throw QuotaError.noCredential
        }
        let results = await MiscQuotaAggregator.gatherSlotResults(cookieResolutions) { resolution in
            try await self.fetchViaCookieSlot(
                resolution: resolution,
                regions: preferred,
                account: account,
                queriedAt: queriedAt
            )
        }
        return MiscQuotaAggregator.aggregate(
            tool: .alibaba,
            account: account,
            results: results,
            queriedAt: queriedAt
        )
    }

    private func fetchViaAPIKey(apiKey: String,
                                regions: [AlibabaRegion],
                                account: AccountIdentity,
                                queriedAt: Date) async throws -> AccountQuota {
        var lastError: QuotaError?
        for region in regions {
            do {
                let snapshot = try await fetchOnce(apiKey: apiKey, region: region, now: queriedAt)
                return AccountQuota(
                    accountId: account.id,
                    tool: .alibaba,
                    buckets: snapshot.buckets,
                    plan: snapshot.planName,
                    email: account.email,
                    queriedAt: queriedAt,
                    error: nil
                )
            } catch let qe as QuotaError {
                lastError = qe
                // Auto-failover only on auth-style errors (401 / 403 /
                // "log in"). Real network failures shouldn't roll
                // through to the next region — they're more useful as
                // a single error message.
                switch qe {
                case .needsLogin, .noCredential:
                    continue
                default:
                    throw qe
                }
            }
        }
        throw lastError ?? QuotaError.unknown("Alibaba: no usable region.")
    }

    private func fetchViaCookieSlot(resolution: MiscCookieResolver.Resolution,
                                    regions: [AlibabaRegion],
                                    account: AccountIdentity,
                                    queriedAt: Date) async throws -> AccountQuota {
        var lastError: QuotaError?
        for region in regions {
            do {
                let secToken = try await resolveSECToken(cookieHeader: resolution.header, region: region)
                let snapshot = try await fetchConsoleOnce(
                    cookieHeader: resolution.header,
                    secToken: secToken,
                    region: region,
                    now: queriedAt
                )
                return AccountQuota(
                    accountId: account.id,
                    tool: .alibaba,
                    buckets: snapshot.buckets,
                    plan: snapshot.planName,
                    email: account.email,
                    queriedAt: queriedAt,
                    error: nil
                )
            } catch let qe as QuotaError {
                lastError = qe
                switch qe {
                case .needsLogin, .noCredential:
                    continue
                default:
                    throw qe
                }
            }
        }
        throw lastError ?? QuotaError.unknown("Alibaba: no usable region.")
    }

    private func fetchOnce(apiKey: String, region: AlibabaRegion, now referenceTime: Date) async throws -> AlibabaResponseParser.Snapshot {
        var request = URLRequest(url: region.apiKeyQuotaURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiKey, forHTTPHeaderField: "X-DashScope-API-Key")
        request.setValue(region.gatewayBaseURL.absoluteString, forHTTPHeaderField: "Origin")

        let body: [String: Any] = [
            "queryCodingPlanInstanceInfoRequest": [
                "commodityCode": region.commodityCode
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuotaError.network("Alibaba network error: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Alibaba: invalid response object")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw QuotaError.needsLogin
            }
            if http.statusCode == 429 {
                throw QuotaError.rateLimited
            }
            throw QuotaError.network("Alibaba returned HTTP \(http.statusCode).")
        }

        return try AlibabaResponseParser.parse(data: data, now: referenceTime)
    }

    // MARK: Console-cookie path

    /// GET the dashboard HTML and pull out the inline `SEC_TOKEN` JS
    /// constant that the console RPC requires alongside the cookie
    /// header. Falls back to a `sec_token` cookie if the page didn't
    /// embed one.
    private func resolveSECToken(cookieHeader: String,
                                 region: AlibabaRegion) async throws -> String {
        var request = URLRequest(url: region.dashboardURL)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(Self.safariUA, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuotaError.network("Alibaba dashboard fetch error: \(error.localizedDescription)")
        }

        if let http = response as? HTTPURLResponse,
           http.statusCode == 200,
           let html = String(data: data, encoding: .utf8) {
            let patterns = [
                #"SEC_TOKEN\s*:\s*\"([^\"]+)\""#,
                #"SEC_TOKEN\s*:\s*'([^']+)'"#,
                #"secToken\s*:\s*\"([^\"]+)\""#,
                #"sec_token\s*:\s*\"([^\"]+)\""#,
                #"\"SEC_TOKEN\"\s*:\s*\"([^\"]+)\""#,
                #"\"sec_token\"\s*:\s*\"([^\"]+)\""#
            ]
            for pattern in patterns {
                if let token = Self.matchFirstGroup(pattern: pattern, in: html), !token.isEmpty {
                    return token
                }
            }
        }

        if let cookieToken = Self.extractCookieValue(name: "sec_token", from: cookieHeader),
           !cookieToken.isEmpty {
            return cookieToken
        }

        throw QuotaError.needsLogin
    }

    /// POST the form-urlencoded console RPC body the Bailian /
    /// ModelStudio dashboard fires from the browser. Body shape:
    /// `params=<json>&region=<id>&sec_token=<sec>`. Headers carry
    /// the cookie + `x-csrf-token` / `x-xsrf-token` lifted from the
    /// `login_aliyunid_csrf` (or `csrf`) cookie value.
    private func fetchConsoleOnce(cookieHeader: String,
                                  secToken: String,
                                  region: AlibabaRegion,
                                  now referenceTime: Date) async throws -> AlibabaResponseParser.Snapshot {
        let traceID = UUID().uuidString.lowercased()
        var cornerstone: [String: Any] = [
            "feTraceId": traceID,
            "feURL": region.dashboardURL.absoluteString,
            "protocol": "V2",
            "console": "ONE_CONSOLE",
            "productCode": "p_efm",
            "domain": region.consoleDomain,
            "consoleSite": region.consoleSite,
            "userNickName": "",
            "userPrincipalName": "",
            "xsp_lang": "en-US"
        ]
        if let cna = Self.extractCookieValue(name: "cna", from: cookieHeader), !cna.isEmpty {
            cornerstone["X-Anonymous-Id"] = cna
        }

        let paramsObject: [String: Any] = [
            "Api": region.consoleQuotaAPIName,
            "V": "1.0",
            "Data": [
                "queryCodingPlanInstanceInfoRequest": [
                    "commodityCode": region.commodityCode,
                    "onlyLatestOne": true
                ],
                "cornerstoneParam": cornerstone
            ]
        ]

        guard let paramsData = try? JSONSerialization.data(withJSONObject: paramsObject),
              let paramsString = String(data: paramsData, encoding: .utf8) else {
            throw QuotaError.parseFailure("Alibaba: failed to encode console params")
        }

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "params", value: paramsString),
            URLQueryItem(name: "region", value: region.currentRegionID),
            URLQueryItem(name: "sec_token", value: secToken)
        ]
        let body = (components.percentEncodedQuery ?? "").data(using: .utf8) ?? Data()

        var request = URLRequest(url: region.consoleRPCURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        if let csrf = Self.extractCookieValue(name: "login_aliyunid_csrf", from: cookieHeader)
            ?? Self.extractCookieValue(name: "csrf", from: cookieHeader) {
            request.setValue(csrf, forHTTPHeaderField: "x-xsrf-token")
            request.setValue(csrf, forHTTPHeaderField: "x-csrf-token")
        }
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(Self.safariUA, forHTTPHeaderField: "User-Agent")
        request.setValue(region.gatewayBaseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(region.consoleRefererURL.absoluteString, forHTTPHeaderField: "Referer")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuotaError.network("Alibaba console error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Alibaba console: invalid response object")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw QuotaError.needsLogin
            }
            if http.statusCode == 429 {
                throw QuotaError.rateLimited
            }
            throw QuotaError.network("Alibaba console returned HTTP \(http.statusCode).")
        }

        return try AlibabaResponseParser.parse(data: data, now: referenceTime)
    }

    // MARK: Helpers

    nonisolated private static var safariUA: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    }

    nonisolated private static func matchFirstGroup(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        let value = String(text[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    nonisolated private static func extractCookieValue(name: String, from header: String) -> String? {
        for segment in header.split(separator: ";") {
            let part = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = String(part[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == name else { continue }
            let value = String(part[part.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

// MARK: - Region

enum AlibabaRegion: String {
    case international
    case chinaMainland

    var commodityCode: String {
        switch self {
        case .international: return "sfm_codingplan_public_intl"
        case .chinaMainland: return "sfm_codingplan_public_cn"
        }
    }

    var currentRegionID: String {
        switch self {
        case .international: return "ap-southeast-1"
        case .chinaMainland: return "cn-beijing"
        }
    }

    var gatewayBaseURL: URL {
        switch self {
        case .international: return URL(string: "https://modelstudio.console.alibabacloud.com")!
        case .chinaMainland: return URL(string: "https://bailian.console.aliyun.com")!
        }
    }

    var apiKeyQuotaURL: URL {
        var components = URLComponents(url: gatewayBaseURL, resolvingAgainstBaseURL: false)!
        components.path = "/data/api.json"
        components.queryItems = [
            URLQueryItem(name: "action",
                         value: "zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2"),
            URLQueryItem(name: "product", value: "broadscope-bailian"),
            URLQueryItem(name: "api", value: "queryCodingPlanInstanceInfoV2"),
            URLQueryItem(name: "currentRegionId", value: currentRegionID)
        ]
        return components.url!
    }

    // MARK: Console-cookie path

    var dashboardURL: URL {
        switch self {
        case .international:
            return URL(string: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=coding-plan#/efm/detail")!
        case .chinaMainland:
            return URL(string: "https://bailian.console.aliyun.com/cn-beijing/?tab=model#/efm/coding_plan")!
        }
    }

    var consoleRefererURL: URL {
        switch self {
        case .international:
            return URL(string: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=coding-plan")!
        case .chinaMainland:
            return URL(string: "https://bailian.console.aliyun.com/cn-beijing/?tab=model")!
        }
    }

    var consoleDomain: String {
        switch self {
        case .international: return "modelstudio.console.alibabacloud.com"
        case .chinaMainland: return "bailian.console.aliyun.com"
        }
    }

    var consoleSite: String {
        switch self {
        case .international: return "MODELSTUDIO_ALIBABACLOUD"
        case .chinaMainland: return "BAILIAN_ALIYUN"
        }
    }

    var consoleRPCBaseURL: URL {
        switch self {
        case .international: return URL(string: "https://bailian-singapore-cs.alibabacloud.com")!
        case .chinaMainland: return URL(string: "https://bailian-cs.console.aliyun.com")!
        }
    }

    /// Console BFF endpoint used by the cookie path. Matches what the
    /// Bailian / ModelStudio dashboard issues from the browser when
    /// loading the coding-plan widget.
    var consoleRPCURL: URL {
        var components = URLComponents(url: consoleRPCBaseURL, resolvingAgainstBaseURL: false)!
        components.path = "/data/api.json"
        components.queryItems = [
            URLQueryItem(name: "action", value: consoleRPCAction),
            URLQueryItem(name: "product", value: "sfm_bailian"),
            URLQueryItem(name: "api", value: consoleQuotaAPIName),
            URLQueryItem(name: "_v", value: "undefined")
        ]
        return components.url!
    }

    var consoleRPCAction: String {
        switch self {
        case .international: return "IntlBroadScopeAspnGateway"
        case .chinaMainland: return "BroadScopeAspnGateway"
        }
    }

    var consoleQuotaAPIName: String {
        "zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2"
    }
}

// MARK: - Response parsing

enum AlibabaResponseParser {
    struct Snapshot {
        var buckets: [QuotaBucket]
        var planName: String?
    }

    static func parse(data: Data, now: Date) throws -> Snapshot {
        guard !data.isEmpty else {
            throw QuotaError.parseFailure("Alibaba returned an empty body.")
        }
        let raw = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = expandedJSON(raw) as? [String: Any] else {
            throw QuotaError.parseFailure("Alibaba response was not a JSON object.")
        }

        // Status / error envelopes. Codexbar checks both numeric and
        // string codes; we mirror the most-actionable ones.
        if let code = findFirstInt(["statusCode", "status_code", "code"], in: dict),
           code != 0, code != 200 {
            let msg = findFirstString(
                ["statusMessage", "status_msg", "message", "msg"],
                in: dict
            ) ?? "status code \(code)"
            if code == 401 || code == 403 || msg.lowercased().contains("api key") {
                throw QuotaError.needsLogin
            }
            throw QuotaError.network("Alibaba: \(msg)")
        }

        // String-code envelope. The bailian / modelstudio console
        // endpoint returns `{"code":"ConsoleNeedLogin","message":"请登录"}`
        // when the request lacks a console session — even when an
        // API key is attached. Map the login-required variants to
        // needsLogin so the misc card shows a sign-in hint instead
        // of a generic "Response format changed" parser error.
        if let codeText = findFirstString(["code", "status", "statusCode"], in: dict) {
            let lower = codeText.lowercased()
            if lower.contains("needlogin") ||
               lower.contains("notlogin") ||
               lower.contains("unauthenticated") ||
               lower == "login" {
                throw QuotaError.needsLogin
            }
            // Some failures encode "successResponse: false" alongside
            // a non-success string code — propagate the message.
            if let success = dict["successResponse"] as? Bool, !success {
                let msg = findFirstString(["message", "msg"], in: dict)
                    ?? "Alibaba code \(codeText)"
                throw QuotaError.network("Alibaba: \(msg)")
            }
        }

        // Find the dict carrying the per-5h / per-week / per-month
        // counters. May live under `codingPlanQuotaInfo` directly or
        // be nested under `codingPlanInstanceInfos[].codingPlanQuotaInfo`.
        let quota = findFirstDictionary(["codingPlanQuotaInfo", "coding_plan_quota_info"], in: dict)
            ?? findFirstDictionary(matchingAnyKey: [
                "per5HourUsedQuota", "per5HourTotalQuota",
                "perWeekUsedQuota", "perWeekTotalQuota",
                "perBillMonthUsedQuota", "perBillMonthTotalQuota",
                "perMonthUsedQuota", "perMonthTotalQuota"
            ], in: dict)

        guard let quota else {
            throw QuotaError.parseFailure("Alibaba response had no coding-plan quota envelope.")
        }

        var buckets: [QuotaBucket] = []
        if let bucket = makeBucket(
            id: "alibaba.5h",
            title: "5 Hours",
            shortLabel: "5h",
            usedKeys: ["per5HourUsedQuota", "perFiveHourUsedQuota"],
            totalKeys: ["per5HourTotalQuota", "perFiveHourTotalQuota"],
            resetKeys: ["per5HourQuotaNextRefreshTime", "perFiveHourQuotaNextRefreshTime"],
            in: quota
        ) {
            buckets.append(bucket)
        }
        if let bucket = makeBucket(
            id: "alibaba.weekly",
            title: "Weekly",
            shortLabel: "Wk",
            usedKeys: ["perWeekUsedQuota"],
            totalKeys: ["perWeekTotalQuota"],
            resetKeys: ["perWeekQuotaNextRefreshTime"],
            in: quota
        ) {
            buckets.append(bucket)
        }
        if let bucket = makeBucket(
            id: "alibaba.monthly",
            title: "Monthly",
            shortLabel: "Mo",
            usedKeys: ["perBillMonthUsedQuota", "perMonthUsedQuota"],
            totalKeys: ["perBillMonthTotalQuota", "perMonthTotalQuota"],
            resetKeys: ["perBillMonthQuotaNextRefreshTime", "perMonthQuotaNextRefreshTime"],
            in: quota
        ) {
            buckets.append(bucket)
        }

        guard !buckets.isEmpty else {
            throw QuotaError.parseFailure("Alibaba response had no usable quota windows.")
        }

        let planName = findPlanName(in: dict)
        return Snapshot(buckets: buckets, planName: planName)
    }

    private static func makeBucket(
        id: String,
        title: String,
        shortLabel: String,
        usedKeys: [String],
        totalKeys: [String],
        resetKeys: [String],
        in dict: [String: Any]
    ) -> QuotaBucket? {
        guard let total = anyInt(usedKeys.isEmpty ? totalKeys : totalKeys, in: dict),
              total > 0 else { return nil }
        let used = anyInt(usedKeys, in: dict) ?? 0
        let percent = max(0, min(100, Double(used) / Double(total) * 100))
        let resetAt = anyDate(resetKeys, in: dict)
        return QuotaBucket(
            id: id,
            title: title,
            shortLabel: shortLabel,
            usedPercent: percent,
            resetAt: resetAt,
            rawWindowSeconds: nil
        )
    }

    private static func findPlanName(in payload: Any) -> String? {
        if let infos = findFirstArray(["codingPlanInstanceInfos", "coding_plan_instance_infos"], in: payload) {
            for raw in infos {
                guard let info = raw as? [String: Any] else { continue }
                let candidates = [
                    anyString(["planName", "plan_name"], in: info),
                    anyString(["instanceName", "instance_name"], in: info),
                    anyString(["packageName", "package_name"], in: info)
                ]
                if let name = candidates.compactMap(\.self).first(where: { !$0.isEmpty }) {
                    return name
                }
            }
        }
        return findFirstString(["planName", "plan_name", "packageName", "package_name"], in: payload)
    }

    // MARK: - Tree helpers (compact ports)

    static func expandedJSON(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict { out[k] = expandedJSON(v) }
            return out
        }
        if let arr = value as? [Any] { return arr.map { expandedJSON($0) } }
        if let s = value as? String,
           let data = s.data(using: .utf8),
           let nested = try? JSONSerialization.jsonObject(with: data),
           nested is [String: Any] || nested is [Any] {
            return expandedJSON(nested)
        }
        return value
    }

    static func findFirstDictionary(_ keys: [String], in value: Any) -> [String: Any]? {
        guard let dict = value as? [String: Any] else {
            if let arr = value as? [Any] {
                for item in arr {
                    if let found = findFirstDictionary(keys, in: item) { return found }
                }
            }
            return nil
        }
        for key in keys {
            if let nested = dict[key] as? [String: Any] { return nested }
        }
        for nested in dict.values {
            if let found = findFirstDictionary(keys, in: nested) { return found }
        }
        return nil
    }

    static func findFirstDictionary(matchingAnyKey keys: [String], in value: Any) -> [String: Any]? {
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

    static func findFirstArray(_ keys: [String], in value: Any) -> [Any]? {
        if let dict = value as? [String: Any] {
            for key in keys { if let arr = dict[key] as? [Any] { return arr } }
            for nested in dict.values {
                if let found = findFirstArray(keys, in: nested) { return found }
            }
        }
        if let arr = value as? [Any] {
            for item in arr {
                if let found = findFirstArray(keys, in: item) { return found }
            }
        }
        return nil
    }

    static func findFirstInt(_ keys: [String], in value: Any) -> Int? {
        if let dict = value as? [String: Any] {
            for key in keys { if let v = parseInt(dict[key]) { return v } }
            for nested in dict.values {
                if let v = findFirstInt(keys, in: nested) { return v }
            }
        }
        if let arr = value as? [Any] {
            for item in arr {
                if let v = findFirstInt(keys, in: item) { return v }
            }
        }
        return nil
    }

    static func findFirstString(_ keys: [String], in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            for key in keys { if let v = parseString(dict[key]) { return v } }
            for nested in dict.values {
                if let v = findFirstString(keys, in: nested) { return v }
            }
        }
        if let arr = value as? [Any] {
            for item in arr {
                if let v = findFirstString(keys, in: item) { return v }
            }
        }
        return nil
    }

    static func anyInt(_ keys: [String], in dict: [String: Any]) -> Int? {
        for key in keys { if let v = parseInt(dict[key]) { return v } }
        return nil
    }

    static func anyString(_ keys: [String], in dict: [String: Any]) -> String? {
        for key in keys { if let v = parseString(dict[key]) { return v } }
        return nil
    }

    static func anyDate(_ keys: [String], in dict: [String: Any]) -> Date? {
        for key in keys { if let v = parseDate(dict[key]) { return v } }
        return nil
    }

    static func parseInt(_ value: Any?) -> Int? {
        switch value {
        case let v as Int:    return v
        case let v as Double: return Int(v)
        case let v as String: return Int(v)
        case let v as NSNumber: return v.intValue
        default: return nil
        }
    }

    static func parseString(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return s
    }

    static func parseDate(_ value: Any?) -> Date? {
        // Alibaba returns reset times either as epoch milliseconds
        // (Number) or ISO8601 strings.
        if let ms = parseInt(value), ms > 0 {
            return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        }
        if let str = parseString(value) {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: str) { return d }
            f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: str) { return d }
        }
        return nil
    }
}
