import Foundation

/// Alibaba Qwen / Bailian **Token Plan** usage adapter.
///
/// Lives alongside `AlibabaQuotaAdapter` (the Coding Plan flavour).
/// Token Plan is a different commercial product sold separately from
/// Coding Plan. It currently has two editions with independent console
/// contracts:
///
/// - **Team** — the original credit-based BSS summary, available on the
///   China-mainland and international consoles.
/// - **Personal** — rolling 5-hour and 7-day utilization windows, only
///   available in `cn-beijing` at launch.
///
/// Auth: console cookies only (`*.aliyun.com` / `*.alibabacloud.com`).
/// DashScope API keys are not used for the Token Plan BFF — that
/// endpoints authenticate the user via the regular Aliyun console
/// session jar, just like the buy / renew flow in the browser.
///
/// Request shape captured from the live console:
///
///     POST https://bailian.console.aliyun.com/data/api.json
///        ?action=GetSeatSubscriptionSummary
///        &product=BssOpenAPI-V3
///        &_tag=
///     Body (form-urlencoded):
///        product=BssOpenAPI-V3
///        action=GetSeatSubscriptionSummary
///        params={"ProductCode":"sfm_tokenplanteams_dp_cn"}
///        sec_token=<scraped>
///        region=cn-qingdao
///
/// The Team response contains `SubscriptionGroupList[]` with one entry
/// per seat tier (standard / advanced / exclusive). Each entry carries
/// an `EquityList[]` with the `credit_value` totals and surplus, plus a
/// `NextCycleFlushTime` reset stamp. We surface one quota bucket per
/// non-empty seat tier. Personal uses two BroadScope endpoints: one for
/// subscription metadata and one for the rolling utilization values.
public struct AlibabaTokenPlanQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .alibabaTokenPlan

    private let session: URLSession
    private let now: @Sendable () -> Date

    public static let cookieSpec = MiscCookieResolver.Spec(
        tool: .alibabaTokenPlan,
        domains: [
            "bailian.console.aliyun.com",
            "modelstudio.console.alibabacloud.com",
            ".aliyun.com",
            ".alibabacloud.com"
        ],
        // Same trade-off as the Coding Plan jar: console identity is
        // stitched together from `login_aliyunid_csrf`, `cna`, plus
        // HttpOnly login tickets we can't enumerate from JS, so we
        // ship the full jar.
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
        let instanceID = AccountStore.miscInstanceID(fromAccountID: account.id, fallbackTool: .alibabaTokenPlan)
        let settings = MiscProviderSettings.current(for: .alibabaTokenPlan, instanceID: instanceID)
        let variant = AlibabaTokenPlanVariant.from(settingsValue: settings.planVariant)

        let preferred: [AlibabaTokenPlanRegion]
        switch settings.region {
        case "ap-southeast-1", "intl", "international":
            preferred = [.international]
        case "cn-beijing", "cn", "china":
            preferred = [.chinaMainland]
        default:
            preferred = [.chinaMainland, .international]
        }

        let queriedAt = now()
        let cookieResolutions = MiscCookieResolver.resolveAll(for: AlibabaTokenPlanQuotaAdapter.cookieSpec, account: account)
        guard !cookieResolutions.isEmpty else {
            throw QuotaError.noCredential
        }

        let results = await MiscQuotaAggregator.gatherSlotResults(cookieResolutions) { resolution in
            try await self.fetchViaCookieSlot(
                resolution: resolution,
                variant: variant,
                regions: preferred,
                account: account,
                queriedAt: queriedAt
            )
        }
        return MiscQuotaAggregator.aggregate(
            tool: .alibabaTokenPlan,
            account: account,
            results: results,
            queriedAt: queriedAt
        )
    }

    private func fetchViaCookieSlot(resolution: MiscCookieResolver.Resolution,
                                    variant: AlibabaTokenPlanVariant,
                                    regions: [AlibabaTokenPlanRegion],
                                    account: AccountIdentity,
                                    queriedAt: Date) async throws -> AccountQuota {
        if variant == .personal {
            let secToken = try await resolveSECToken(
                cookieHeader: resolution.header,
                dashboardURL: variant.dashboardURL
            )
            let snapshot = try await fetchPersonalSummary(
                cookieHeader: resolution.header,
                secToken: secToken,
                now: queriedAt
            )
            return AccountQuota(
                accountId: account.id,
                tool: .alibabaTokenPlan,
                buckets: snapshot.buckets,
                plan: snapshot.planName,
                email: account.email,
                queriedAt: queriedAt,
                error: nil
            )
        }

        var lastError: QuotaError?
        for region in regions {
            do {
                let secToken = try await resolveSECToken(
                    cookieHeader: resolution.header,
                    dashboardURL: region.dashboardURL
                )
                let snapshot = try await fetchSeatSummary(
                    cookieHeader: resolution.header,
                    secToken: secToken,
                    region: region,
                    now: queriedAt
                )
                return AccountQuota(
                    accountId: account.id,
                    tool: .alibabaTokenPlan,
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
        throw lastError ?? QuotaError.unknown("Alibaba Token Plan: no usable region.")
    }

    /// GET the Token Plan dashboard HTML and pull the inline
    /// `SEC_TOKEN` constant. Same scrape pattern as the Coding Plan
    /// adapter (the page reuses the Bailian console shell), with a
    /// `sec_token` cookie fallback for layouts that hoist the token
    /// onto the jar instead of the inline JS.
    private func resolveSECToken(cookieHeader: String,
                                 dashboardURL: URL) async throws -> String {
        var request = URLRequest(url: dashboardURL)
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
            throw QuotaError.network("Alibaba Token Plan dashboard fetch error: \(error.localizedDescription)")
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

    /// POST the form-urlencoded BSS RPC body the Token Plan dashboard
    /// fires from the browser. Body layout:
    ///   `product=…&action=…&params=<json>&sec_token=…&region=cn-qingdao`
    /// The `region` body parameter is the BSS-backend region
    /// (`cn-qingdao` for the China site, `ap-southeast-1` for intl)
    /// and is not derived from the user-facing region setting.
    private func fetchSeatSummary(cookieHeader: String,
                                  secToken: String,
                                  region: AlibabaTokenPlanRegion,
                                  now referenceTime: Date) async throws -> AlibabaTokenPlanResponseParser.Snapshot {
        let paramsObject: [String: Any] = [
            "ProductCode": region.productCode
        ]

        guard let paramsData = try? JSONSerialization.data(withJSONObject: paramsObject),
              let paramsString = String(data: paramsData, encoding: .utf8) else {
            throw QuotaError.parseFailure("Alibaba Token Plan: failed to encode params")
        }

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "product", value: "BssOpenAPI-V3"),
            URLQueryItem(name: "action", value: "GetSeatSubscriptionSummary"),
            URLQueryItem(name: "params", value: paramsString),
            URLQueryItem(name: "sec_token", value: secToken),
            URLQueryItem(name: "region", value: region.bssRegion)
        ]
        let body = (components.percentEncodedQuery ?? "").data(using: .utf8) ?? Data()

        var request = URLRequest(url: region.consoleRPCURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        if let csrf = Self.extractCookieValue(name: "login_aliyunid_csrf", from: cookieHeader)
            ?? Self.extractCookieValue(name: "csrf", from: cookieHeader) {
            request.setValue(csrf, forHTTPHeaderField: "x-xsrf-token")
            request.setValue(csrf, forHTTPHeaderField: "x-csrf-token")
        }
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(Self.safariUA, forHTTPHeaderField: "User-Agent")
        request.setValue(region.consoleBaseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(region.dashboardURL.absoluteString, forHTTPHeaderField: "Referer")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuotaError.network("Alibaba Token Plan console error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Alibaba Token Plan: invalid response object")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw QuotaError.needsLogin
            }
            if http.statusCode == 429 {
                throw QuotaError.rateLimited
            }
            throw QuotaError.network("Alibaba Token Plan returned HTTP \(http.statusCode).")
        }

        return try AlibabaTokenPlanResponseParser.parse(data: data, productCode: region.productCode, now: referenceTime)
    }

    /// Fetch the two requests emitted by the Personal Token Plan page:
    /// subscription metadata identifies the tier, while usage carries
    /// the independent rolling 5-hour and 7-day utilization values.
    private func fetchPersonalSummary(
        cookieHeader: String,
        secToken: String,
        now referenceTime: Date
    ) async throws -> AlibabaTokenPlanResponseParser.Snapshot {
        let traceID = UUID().uuidString.lowercased()
        var cornerstone: [String: Any] = [
            "feTraceId": traceID,
            "feURL": AlibabaTokenPlanVariant.personal.dashboardURL.absoluteString,
            "protocol": "V2",
            "console": "ONE_CONSOLE",
            "productCode": "p_efm",
            "domain": "bailian.console.aliyun.com",
            "consoleSite": "BAILIAN_ALIYUN",
            "switchAgent": 10_087_432,
            "switchUserType": 3,
            "userNickName": "",
            "userPrincipalName": "",
            "xsp_lang": "en-US"
        ]
        if let cna = Self.extractCookieValue(name: "cna", from: cookieHeader), !cna.isEmpty {
            cornerstone["X-Anonymous-Id"] = cna
        }

        let subscriptionData = try await fetchPersonalData(
            endpoint: .subscription,
            dataObject: [
                "queryInstanceInfoRequest": [
                    "commodityCode": "sfm_tokenplansolo_public_cn"
                ],
                "cornerstoneParam": cornerstone
            ],
            cookieHeader: cookieHeader,
            secToken: secToken
        )
        let usageData = try await fetchPersonalData(
            endpoint: .usage,
            dataObject: ["cornerstoneParam": cornerstone],
            cookieHeader: cookieHeader,
            secToken: secToken
        )

        return try AlibabaTokenPlanPersonalResponseParser.parse(
            subscriptionData: subscriptionData,
            usageData: usageData,
            now: referenceTime
        )
    }

    private func fetchPersonalData(
        endpoint: AlibabaTokenPlanPersonalEndpoint,
        dataObject: [String: Any],
        cookieHeader: String,
        secToken: String
    ) async throws -> Data {
        let paramsObject: [String: Any] = [
            "Api": endpoint.apiName,
            "V": "1.0",
            "Data": dataObject
        ]
        guard let paramsData = try? JSONSerialization.data(withJSONObject: paramsObject),
              let paramsString = String(data: paramsData, encoding: .utf8) else {
            throw QuotaError.parseFailure("Alibaba Personal Token Plan: failed to encode params")
        }

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "params", value: paramsString),
            URLQueryItem(name: "region", value: "cn-beijing"),
            URLQueryItem(name: "sec_token", value: secToken)
        ]

        var request = URLRequest(url: endpoint.consoleRPCURL)
        request.httpMethod = "POST"
        request.httpBody = (components.percentEncodedQuery ?? "").data(using: .utf8) ?? Data()
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
        request.setValue("https://bailian.console.aliyun.com", forHTTPHeaderField: "Origin")
        request.setValue(
            AlibabaTokenPlanVariant.personal.dashboardURL.absoluteString,
            forHTTPHeaderField: "Referer"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuotaError.network("Alibaba Personal Token Plan console error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Alibaba Personal Token Plan: invalid response object")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 { throw QuotaError.needsLogin }
            if http.statusCode == 429 { throw QuotaError.rateLimited }
            throw QuotaError.network("Alibaba Personal Token Plan returned HTTP \(http.statusCode).")
        }
        return data
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

// MARK: - Plan variant

/// Commercial edition selected for one Alibaba Token Plan misc card.
/// Missing settings deliberately map to Team so existing installations
/// keep monitoring the same product after Personal support is added.
public enum AlibabaTokenPlanVariant: String, CaseIterable, Sendable {
    case team
    case personal

    public static func from(settingsValue raw: String?) -> Self {
        switch raw?.lowercased() {
        case "personal", "individual", "solo": return .personal
        default: return .team
        }
    }

    public var displayLabel: String {
        switch self {
        case .team: return "Team"
        case .personal: return "Personal"
        }
    }

    var dashboardURL: URL {
        switch self {
        case .team:
            return AlibabaTokenPlanRegion.chinaMainland.dashboardURL
        case .personal:
            return URL(string: "https://bailian.console.aliyun.com/cn-beijing/?tab=plan#/efm/subscription/token-plan/personal")!
        }
    }
}

enum AlibabaTokenPlanPersonalEndpoint: CaseIterable {
    case subscription
    case usage

    var apiName: String {
        switch self {
        case .subscription: return "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription"
        case .usage: return "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"
        }
    }

    var consoleRPCURL: URL {
        var components = URLComponents(string: "https://bailian-cs.console.aliyun.com/data/api.json")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "BroadScopeAspnGateway"),
            URLQueryItem(name: "product", value: "sfm_bailian"),
            URLQueryItem(name: "api", value: apiName),
            URLQueryItem(name: "_v", value: "undefined")
        ]
        return components.url!
    }
}

// MARK: - Region

enum AlibabaTokenPlanRegion: String {
    case international
    case chinaMainland

    /// User-visible region IDs in `MiscProviderSettings.region`.
    var settingsRegionID: String {
        switch self {
        case .international: return "ap-southeast-1"
        case .chinaMainland: return "cn-beijing"
        }
    }

    /// BSS calls live in the China-wide billing region (`cn-qingdao`)
    /// or its international counterpart, regardless of which console
    /// site the page is loaded under.
    var bssRegion: String {
        switch self {
        case .international: return "ap-southeast-1"
        case .chinaMainland: return "cn-qingdao"
        }
    }

    /// `sfm_tokenplanteams_dp_cn` was captured live; `_dp_intl` is
    /// the standard Aliyun pattern for the international BSS variant
    /// and matches the Coding Plan naming (`_public_cn` /
    /// `_public_intl`). If a future expansion adds an individual
    /// Token Plan we'll layer another `try-per-product` loop in.
    var productCode: String {
        switch self {
        case .international: return "sfm_tokenplanteams_dp_intl"
        case .chinaMainland: return "sfm_tokenplanteams_dp_cn"
        }
    }

    var consoleBaseURL: URL {
        switch self {
        case .international: return URL(string: "https://modelstudio.console.alibabacloud.com")!
        case .chinaMainland: return URL(string: "https://bailian.console.aliyun.com")!
        }
    }

    /// Dashboard URL the console shell uses to bootstrap the Token
    /// Plan page. Visiting this URL with a valid session embeds
    /// `SEC_TOKEN` inline.
    var dashboardURL: URL {
        switch self {
        case .international:
            return URL(string: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=plan#/efm/subscription/token-plan")!
        case .chinaMainland:
            return URL(string: "https://bailian.console.aliyun.com/cn-beijing/?tab=plan#/efm/subscription/token-plan")!
        }
    }

    /// BSS RPC endpoint. Token Plan rides on the regular console BFF
    /// (`bailian.console.aliyun.com/data/api.json`), not the BroadScope
    /// `bailian-cs.console.aliyun.com` BFF the Coding Plan uses.
    var consoleRPCURL: URL {
        var components = URLComponents(url: consoleBaseURL, resolvingAgainstBaseURL: false)!
        components.path = "/data/api.json"
        components.queryItems = [
            URLQueryItem(name: "action", value: "GetSeatSubscriptionSummary"),
            URLQueryItem(name: "product", value: "BssOpenAPI-V3"),
            URLQueryItem(name: "_tag", value: "")
        ]
        return components.url!
    }
}

// MARK: - Response parsing

enum AlibabaTokenPlanResponseParser {
    struct Snapshot {
        var buckets: [QuotaBucket]
        var planName: String?
    }

    static func parse(data: Data, productCode: String, now: Date) throws -> Snapshot {
        guard !data.isEmpty else {
            throw QuotaError.parseFailure("Alibaba Token Plan returned an empty body.")
        }
        let raw = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = expandedJSON(raw) as? [String: Any] else {
            throw QuotaError.parseFailure("Alibaba Token Plan response was not a JSON object.")
        }

        // String-coded login failures (mirrors the Coding Plan parser).
        if let codeText = findFirstString(["code", "status", "statusCode", "Code"], in: dict) {
            let lower = codeText.lowercased()
            if lower.contains("needlogin") ||
               lower.contains("notlogin") ||
               lower.contains("unauthenticated") ||
               lower == "login" {
                throw QuotaError.needsLogin
            }
        }
        if let success = dict["successResponse"] as? Bool, !success {
            let msg = findFirstString(["message", "msg", "Message"], in: dict) ?? "Alibaba Token Plan request failed."
            throw QuotaError.network("Alibaba Token Plan: \(msg)")
        }

        // Numeric error envelope (rare on this BFF — most failures
        // come through as `Code: "ConsoleNeedLogin"`).
        if let numeric = findFirstInt(["statusCode", "status_code", "httpStatusCode"], in: dict),
           numeric != 0, numeric != 200 {
            let msg = findFirstString(["statusMessage", "status_msg", "message", "msg", "Message"], in: dict)
                ?? "status code \(numeric)"
            if numeric == 401 || numeric == 403 {
                throw QuotaError.needsLogin
            }
            throw QuotaError.network("Alibaba Token Plan: \(msg)")
        }

        // `SubscriptionGroupList` is the canonical shape. Some BFF
        // variants nest the payload under `data.Data` / `Data`; the
        // recursive helpers below let us pull from either.
        var buckets: [QuotaBucket] = []

        if let groups = findFirstArray(["SubscriptionGroupList", "subscriptionGroupList"], in: dict) {
            for raw in groups {
                guard let group = raw as? [String: Any] else { continue }
                guard let bucket = bucketForGroup(group, productCode: productCode) else { continue }
                buckets.append(bucket)
            }
        }

        // Fallback: some responses (the simpler `GetSubscriptionSummary`
        // variant) collapse the equity into top-level
        // `TotalValue`/`TotalSurplusValue` without a group list. We
        // still surface a single aggregate bucket so the card shows
        // *something* instead of failing.
        if buckets.isEmpty {
            if let summary = findFirstDictionary(matchingAnyKey: [
                "TotalValue", "TotalSurplusValue"
            ], in: dict),
               let bucket = bucketForFlatSummary(summary, productCode: productCode) {
                buckets.append(bucket)
            }
        }

        guard !buckets.isEmpty else {
            throw QuotaError.parseFailure("Alibaba Token Plan response had no usable subscription data.")
        }

        // Plan name: combine the human label (Team / Individual based
        // on the product code) with the spec tier if all buckets share
        // one, otherwise stick to the family name.
        let familyName = familyDisplayName(for: productCode)
        let planName: String
        if buckets.count == 1, let group = bucketGroupName(for: productCode, suffix: buckets[0].groupTitle) {
            planName = group
        } else {
            planName = familyName
        }

        return Snapshot(buckets: buckets, planName: planName)
    }

    private static func bucketForGroup(_ group: [String: Any], productCode: String) -> QuotaBucket? {
        let specType = (anyString(["SpecType", "specType"], in: group) ?? "standard").lowercased()
        let equityList = (group["EquityList"] as? [Any])
            ?? (group["equityList"] as? [Any])
            ?? []

        // Pick the credit_value equity — that's the "总额度" / "用量
        // 消耗" bar the dashboard renders for the seat tier. Other
        // equity codes can be added later if Aliyun expands the
        // schema (e.g. a separate "cache" or "tool-call" equity).
        let credit = equityList.compactMap { $0 as? [String: Any] }.first {
            let code = (anyString(["EquityCode", "equityCode"], in: $0) ?? "").lowercased()
            return code == "credit_value" || code.contains("credit")
        }

        let total = parseDouble(credit?["TotalValue"] ?? credit?["totalValue"]) ?? 0
        let surplus = parseDouble(credit?["SurplusValue"] ?? credit?["surplusValue"]) ?? 0
        guard total > 0 else { return nil }
        let used = max(0, total - surplus)
        let percent = max(0, min(100, used / total * 100))

        let nextFlush = parseDate(group["NextCycleFlushTime"] ?? group["nextCycleFlushTime"])

        let specLabel = displaySpecLabel(specType)
        return QuotaBucket(
            id: "alibabaTokenPlan.\(productCode).\(specType)",
            title: "\(specLabel) Credits",
            shortLabel: "\(specLabel) credits",
            usedPercent: percent,
            resetAt: nextFlush,
            rawWindowSeconds: nil,
            groupTitle: specLabel
        )
    }

    private static func bucketForFlatSummary(_ summary: [String: Any], productCode: String) -> QuotaBucket? {
        let total = parseDouble(summary["TotalValue"] ?? summary["totalValue"]) ?? 0
        let surplus = parseDouble(summary["TotalSurplusValue"] ?? summary["totalSurplusValue"]) ?? 0
        guard total > 0 else { return nil }
        let used = max(0, total - surplus)
        let percent = max(0, min(100, used / total * 100))
        let reset = parseDate(summary["NearestExpireDate"] ?? summary["nearestExpireDate"])
        return QuotaBucket(
            id: "alibabaTokenPlan.\(productCode).summary",
            title: "Token Plan Credits",
            shortLabel: "Credits",
            usedPercent: percent,
            resetAt: reset,
            rawWindowSeconds: nil
        )
    }

    private static func displaySpecLabel(_ specType: String) -> String {
        switch specType {
        case "standard": return "Standard"
        case "advanced": return "Advanced"
        case "exclusive": return "Exclusive"
        default:
            // Title-case anything else so we don't surface the raw
            // `enterprise_v2` style strings.
            return specType
                .split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    private static func familyDisplayName(for productCode: String) -> String {
        if productCode.contains("teams") { return "Token Plan · Team" }
        return "Token Plan"
    }

    private static func bucketGroupName(for productCode: String, suffix: String?) -> String? {
        guard let suffix, !suffix.isEmpty else { return nil }
        return "\(familyDisplayName(for: productCode)) · \(suffix)"
    }

    // MARK: - Tree helpers

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

    static func anyString(_ keys: [String], in dict: [String: Any]) -> String? {
        for key in keys { if let v = parseString(dict[key]) { return v } }
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

    static func parseDouble(_ value: Any?) -> Double? {
        switch value {
        case let v as Double: return v
        case let v as Int:    return Double(v)
        case let v as NSNumber: return v.doubleValue
        case let v as String: return Double(v)
        default: return nil
        }
    }

    static func parseString(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return s
    }

    static func parseDate(_ value: Any?) -> Date? {
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

/// Parser for the Personal Token Plan's split subscription + usage
/// response. Both BroadScope responses may contain JSON serialized as
/// strings under `DataV2`; the Team parser's tree expansion keeps the
/// extraction tolerant of that console envelope.
enum AlibabaTokenPlanPersonalResponseParser {
    static func parse(
        subscriptionData: Data,
        usageData: Data,
        now _: Date
    ) throws -> AlibabaTokenPlanResponseParser.Snapshot {
        let subscription = try root(from: subscriptionData, responseName: "subscription")
        let usage = try root(from: usageData, responseName: "usage")
        try validateEnvelope(subscription)
        try validateEnvelope(usage)

        var buckets: [QuotaBucket] = []
        if let fiveHour = findFirstDouble(["per5HourPercentage"], in: usage) {
            buckets.append(QuotaBucket(
                id: "alibabaTokenPlan.personal.fiveHour",
                title: "5 Hours",
                shortLabel: "5h",
                usedPercent: normalizedPercentage(fiveHour),
                resetAt: nil,
                rawWindowSeconds: 5 * 3_600,
                groupTitle: "Personal"
            ))
        }
        if let weekly = findFirstDouble(["per1WeekPercentage"], in: usage) {
            buckets.append(QuotaBucket(
                id: "alibabaTokenPlan.personal.weekly",
                title: "Weekly",
                shortLabel: "Wk",
                usedPercent: normalizedPercentage(weekly),
                resetAt: nil,
                rawWindowSeconds: 7 * 86_400,
                groupTitle: "Personal"
            ))
        }

        guard !buckets.isEmpty else {
            throw QuotaError.parseFailure(
                "Alibaba Personal Token Plan response had no usable utilization windows."
            )
        }

        let specCode = AlibabaTokenPlanResponseParser.findFirstString(["specCode"], in: subscription)
        let tier = tierDisplayName(from: specCode)
        let planName = tier.map { "Token Plan · Personal · \($0)" } ?? "Token Plan · Personal"
        return AlibabaTokenPlanResponseParser.Snapshot(buckets: buckets, planName: planName)
    }

    private static func root(from data: Data, responseName: String) throws -> [String: Any] {
        guard !data.isEmpty else {
            throw QuotaError.parseFailure(
                "Alibaba Personal Token Plan returned an empty \(responseName) body."
            )
        }
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw QuotaError.parseFailure(
                "Alibaba Personal Token Plan \(responseName) response was not parseable."
            )
        }
        guard let dict = AlibabaTokenPlanResponseParser.expandedJSON(raw) as? [String: Any] else {
            throw QuotaError.parseFailure(
                "Alibaba Personal Token Plan \(responseName) response was not a JSON object."
            )
        }
        return dict
    }

    private static func validateEnvelope(_ dict: [String: Any]) throws {
        if let code = AlibabaTokenPlanResponseParser.findFirstString(
            ["code", "status", "statusCode", "Code"],
            in: dict
        ) {
            let lower = code.lowercased()
            if lower.contains("needlogin") || lower.contains("notlogin") ||
                lower.contains("unauthenticated") || lower == "login" {
                throw QuotaError.needsLogin
            }
        }
        if let success = dict["successResponse"] as? Bool, !success {
            let message = AlibabaTokenPlanResponseParser.findFirstString(
                ["message", "msg", "Message"],
                in: dict
            ) ?? "request failed"
            throw QuotaError.network("Alibaba Personal Token Plan: \(message)")
        }
        if let status = AlibabaTokenPlanResponseParser.findFirstInt(
            ["httpStatusCode", "statusCode", "status_code"],
            in: dict
        ), status != 0, status != 200 {
            if status == 401 || status == 403 { throw QuotaError.needsLogin }
            throw QuotaError.network("Alibaba Personal Token Plan returned status \(status).")
        }
    }

    private static func findFirstDouble(_ keys: [String], in value: Any) -> Double? {
        if let dict = value as? [String: Any] {
            for key in keys {
                if let parsed = AlibabaTokenPlanResponseParser.parseDouble(dict[key]) { return parsed }
            }
            for nested in dict.values {
                if let parsed = findFirstDouble(keys, in: nested) { return parsed }
            }
        }
        if let array = value as? [Any] {
            for nested in array {
                if let parsed = findFirstDouble(keys, in: nested) { return parsed }
            }
        }
        return nil
    }

    /// The live account currently reports zero, which cannot reveal
    /// whether a non-zero deployment serializes 0...1 or 0...100.
    /// Accept both shapes without misreading a whole-number 1% value,
    /// then clamp malformed data to the UI's supported range.
    private static func normalizedPercentage(_ raw: Double) -> Double {
        let scaled: Double
        if raw > 0, raw < 1, raw.rounded(.towardZero) != raw {
            scaled = raw * 100
        } else {
            scaled = raw
        }
        return max(0, min(100, scaled))
    }

    private static func tierDisplayName(from specCode: String?) -> String? {
        guard let lower = specCode?.lowercased() else { return nil }
        if lower.contains("standard") { return "Standard" }
        if lower.contains("pro") { return "Pro" }
        if lower.contains("lite") { return "Lite" }
        return nil
    }
}
