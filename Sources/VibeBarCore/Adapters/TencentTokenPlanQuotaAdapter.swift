import Foundation

/// Tencent Cloud TokenHub **Token Plan** usage adapter.
///
/// Lives alongside `TencentHunyuanQuotaAdapter` (the Coding Plan
/// flavour). Token Plan is a separate commercial product under the
/// TokenHub umbrella — credit-based instead of 5h / weekly / monthly
/// windows. It ships in two console variants:
///
/// - **Generic Token Plan** (`/tokenhub/tokenplan`) — the
///   cross-model "Personal Edition" credit bundle. BFF body carries
///   `Edition: "personal"`.
/// - **HY3 Token Plan** (`/tokenhub/tokenplan/hy`) — the
///   Hunyuan 3 credit bundle. BFF body carries `Edition: "hunyuan"`.
///
/// Both pages share one BFF endpoint
/// (`POST cgi/capi?cmd=DescribeTokenPlanUsage&serviceType=hunyuan`)
/// and the same response envelope; the page partitions purely by the
/// `Edition` field. Captured live (2026-05) — the SPA on either page
/// actually fires both Edition variants concurrently so the dashboard
/// can render whichever subscription the user owns.
///
/// Each Vibe Bar misc instance pins one variant via the `region`
/// field on `MiscProviderSettings` (`"generic"` or `"hunyuan"`; empty
/// defaults to `"generic"`). To track both at once, the user clones
/// the misc instance and sets the clone to the other variant — the
/// existing instance-clone path already gives each copy its own
/// Keychain slot, quota cache, and visibility toggle. The misc card
/// shows one variant per instance, mirroring the way the Tencent
/// console renders the two pages.
///
/// Auth: same `*.cloud.tencent.com` console session jar as the Coding
/// Plan adapter (`skey` + `uin` + HttpOnly login tickets). The
/// `csrfCode` URL parameter is computed locally from `skey` via
/// `TencentCsrfCode` — same algorithm Tencent's console JS uses.
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
            "?cmd=DescribeTokenPlanUsage&action=delegate&serviceType=hunyuan" +
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

        // Body shape captured from the live TokenHub SPA. `Edition` is
        // the partition key — `personal` returns the generic Token
        // Plan (`tp_standard`), `hunyuan` returns the HY3 Token Plan
        // (`tp_hy_standard`). Any unrecognized data key triggers
        // `UnknownParameter` from the BFF, so we ship only what the
        // SPA itself sends.
        let body: [String: Any] = [
            "regionId": 1,
            "serviceType": "hunyuan",
            "cmd": "DescribeTokenPlanUsage",
            "data": [
                "Version": "2023-09-01",
                "Edition": variant.editionParam,
                "Language": "zh-CN"
            ]
        ]
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
    /// "Personal Edition" credit bundle. Default when no setting is
    /// stored. Maps to `Edition: "personal"` on the BFF.
    case generic
    /// `console.cloud.tencent.com/tokenhub/tokenplan/hy` — the
    /// Hunyuan 3 credit bundle. Maps to `Edition: "hunyuan"` on the
    /// BFF.
    case hunyuan

    public static func from(settingsRegion raw: String?) -> Self {
        switch raw?.lowercased() {
        case "hunyuan", "hy", "hy3", "personal-hy", "hunyuan3":
            return .hunyuan
        case "generic", "general", "personal", "all", nil, "":
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

    /// BFF body `data.Edition` value — `personal` for the generic
    /// Personal Edition, `hunyuan` for the HY3 variant.
    var editionParam: String {
        switch self {
        case .generic: return "personal"
        case .hunyuan: return "hunyuan"
        }
    }

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

        guard let usageList = response["TokenPlanUsageList"] as? [[String: Any]] else {
            // The BFF returned a 0/0 envelope but no usage list — this
            // means the user is signed in but doesn't own a Token Plan
            // for this edition. Surface as `needsLogin`-style empty
            // state via parseFailure so the card shows a "set up"
            // CTA instead of a hard error.
            throw QuotaError.parseFailure("Tencent Token Plan response had no TokenPlanUsageList.")
        }

        guard !usageList.isEmpty else {
            throw QuotaError.parseFailure(
                "Tencent Token Plan returned an empty TokenPlanUsageList for the \(variant.displayLabel)."
            )
        }

        var buckets: [QuotaBucket] = []
        var planName: String?
        for (index, item) in usageList.enumerated() {
            guard let bucket = bucket(for: item, variant: variant, index: index) else { continue }
            buckets.append(bucket)
            if planName == nil,
               let pkg = item["TokenPlanPackage"] as? [String: Any],
               let plan = pkg["Plan"] as? String, !plan.isEmpty {
                planName = humanPlanName(plan)
            }
        }

        guard !buckets.isEmpty else {
            throw QuotaError.parseFailure("Tencent Token Plan response had no usable credit data.")
        }

        return Snapshot(buckets: buckets, planName: planName ?? variant.displayLabel)
    }

    // MARK: - Per-usage bucket

    private static func bucket(
        for item: [String: Any],
        variant: TencentTokenPlanVariant,
        index: Int
    ) -> QuotaBucket? {
        guard let resource = item["TokenPlanResource"] as? [String: Any] else { return nil }
        let pkg = item["TokenPlanPackage"] as? [String: Any]
        let plan = (pkg?["Plan"] as? String) ?? "tp"

        // Token Plan counters arrive as strings (`"100000000"`); take
        // the safe path through `parseDouble` so we don't truncate
        // hundred-million scale values via Int.
        let capacity = parseDouble(resource["CycleCapacity"]) ?? 0
        guard capacity > 0 else { return nil }

        let used = parseDouble(resource["CycleTotalUsage"])
        let remain = parseDouble(resource["CycleRemain"])
        let usedValue: Double
        if let used {
            usedValue = max(0, used)
        } else if let remain {
            usedValue = max(0, capacity - remain)
        } else {
            return nil
        }
        let percent = max(0, min(100, usedValue / capacity * 100))

        let resetAt = parseShanghaiDate(pkg?["ExpireTime"] as? String)
            ?? parseShanghaiDate(resource["ExpireTime"] as? String)

        // Use the plan code (`tp_standard`, `tp_hy_standard`, ...) as
        // the stable bucket id suffix so caches survive multi-plan
        // upgrades cleanly; fall back to the array index when Tencent
        // ever ships a plan without a Plan key.
        let stableSuffix = plan.isEmpty ? "row\(index)" : plan
        let displayLabel = humanPlanName(plan)
        return QuotaBucket(
            id: "tencentTokenPlan.\(variant.rawValue).\(stableSuffix)",
            title: "Monthly",
            shortLabel: "Month",
            usedPercent: percent,
            resetAt: resetAt,
            rawWindowSeconds: 30 * 86_400,
            groupTitle: displayLabel
        )
    }

    /// `tp_standard` → "Standard", `tp_hy_standard` → "HY Standard",
    /// `tp_hy_pro` → "HY Pro". Leaves unknown shapes alone.
    private static func humanPlanName(_ raw: String) -> String {
        let parts = raw.split(separator: "_").map(String.init)
        guard parts.first == "tp", parts.count > 1 else { return raw }
        let rest = parts.dropFirst().map { piece -> String in
            switch piece.lowercased() {
            case "hy", "hy3": return "HY"
            case "tokenplan": return "Token Plan"
            default:
                return piece.prefix(1).uppercased() + piece.dropFirst()
            }
        }
        return rest.joined(separator: " ")
    }

    // MARK: - CGI router unwrap

    private static func unwrapCgiBffEnvelope(_ data: Data) throws -> Data {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.parseFailure("Tencent Token Plan response not parseable.")
        }
        // Legacy direct shape: pass through.
        if root["Response"] != nil { return data }
        // Recognise the CGI router wrapper. The outer code may serialise
        // as either a number or a string ("UnknownParameter" arrives as
        // a string when the inner Response itself signals the failure).
        let outerCodeInt = (root["code"] as? NSNumber)?.intValue
        let outerCodeString = (root["code"] as? String)
        guard outerCodeInt != nil || outerCodeString != nil else {
            return data
        }
        if let outerCodeInt, outerCodeInt != 0 {
            throw cgiBffError(code: outerCodeInt, layer: "outer", payload: root)
        }
        if let outerCodeString, outerCodeString != "0", outerCodeString.lowercased() != "success" {
            // Try to peel anyway — the inner Response.Error carries the
            // actionable message and the parser dispatches from there.
            // If there's no inner data block, surface the outer code.
            if root["data"] == nil {
                throw QuotaError.network("Tencent Token Plan CGI BFF outer error: \(outerCodeString)")
            }
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

    private static func parseDouble(_ value: Any?) -> Double? {
        switch value {
        case let v as Double: return v
        case let v as Int: return Double(v)
        case let v as NSNumber: return v.doubleValue
        case let v as String:
            return Double(v.trimmingCharacters(in: .whitespacesAndNewlines))
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
}
