import Foundation

/// Z.ai (智谱 / BigModel) usage adapter.
///
/// Auth is straightforward: the user pastes a Z.ai API key in
/// Settings, we GET `api/monitor/usage/quota/limit` with a Bearer
/// token, and parse the response into one to three `QuotaBucket`s
/// (token limit primary, session token limit secondary if the API
/// returns multiple TOKENS_LIMIT entries, time limit tertiary).
///
/// Region selection follows codexbar's reader:
/// 1. `Z_AI_QUOTA_URL` env var — full URL override.
/// 2. `Z_AI_API_HOST` env var — host/base URL override.
/// 3. `MiscProviderSettings.enterpriseHost` — same effect as 2.
/// 4. `MiscProviderSettings.region` — `"global"` or `"bigmodel-cn"`.
/// 5. Default — global.
public struct ZaiQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .zai

    private let session: URLSession
    private let environment: [String: String]
    private let now: @Sendable () -> Date

    public init(
        session: URLSession = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.environment = environment
        self.now = now
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        let providerSettings = MiscProviderSettings.current(for: .zai)
        guard providerSettings.allowsAPIOrOAuthAccess else {
            throw QuotaError.noCredential
        }
        let settings = ZaiSettings.resolve(
            environment: environment,
            providerSettings: providerSettings
        )

        guard let apiKey = MiscCredentialStore.readString(tool: .zai, kind: .apiKey),
              !apiKey.isEmpty
        else {
            throw QuotaError.noCredential
        }

        let url = settings.quotaURL
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuotaError.network("Z.ai network error: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Z.ai: invalid response object")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw QuotaError.needsLogin
            }
            if http.statusCode == 429 {
                throw QuotaError.rateLimited
            }
            throw QuotaError.network("Z.ai returned HTTP \(http.statusCode).")
        }
        guard !data.isEmpty else {
            throw QuotaError.parseFailure("Z.ai returned an empty body — confirm the region (Global vs BigModel CN) and the API key.")
        }

        let snapshot = try ZaiResponseParser.parse(data: data, now: now())
        return AccountQuota(
            accountId: account.id,
            tool: .zai,
            buckets: snapshot.buckets,
            plan: snapshot.planName,
            email: account.email,
            queriedAt: now(),
            error: nil
        )
    }
}

// MARK: - Region / endpoint resolution

struct ZaiSettings {
    let quotaURL: URL

    static func resolve(
        environment: [String: String],
        providerSettings: MiscProviderSettings = .default
    ) -> ZaiSettings {
        if let raw = environment["Z_AI_QUOTA_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let url = URL(string: raw),
           url.scheme != nil
        {
            return ZaiSettings(quotaURL: url)
        }

        if let host = environment["Z_AI_API_HOST"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !host.isEmpty,
           let url = quotaURL(fromHost: host)
        {
            return ZaiSettings(quotaURL: url)
        }

        if let host = providerSettings.enterpriseHost?.absoluteString,
           let url = quotaURL(fromHost: host) {
            return ZaiSettings(quotaURL: url)
        }

        if let rawRegion = providerSettings.region?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           let region = ZaiRegion(rawValue: rawRegion) {
            return ZaiSettings(quotaURL: region.quotaURL)
        }

        return ZaiSettings(quotaURL: ZaiRegion.global.quotaURL)
    }

    static func quotaURL(fromHost host: String) -> URL? {
        var trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if !trimmed.contains("://") {
            trimmed = "https://\(trimmed)"
        }
        return URL(string: trimmed)?.appendingPathComponent("api/monitor/usage/quota/limit")
    }
}

enum ZaiRegion: String {
    case global
    case bigmodelCN = "bigmodel-cn"

    var baseURL: URL {
        switch self {
        case .global:     return URL(string: "https://api.z.ai")!
        case .bigmodelCN: return URL(string: "https://open.bigmodel.cn")!
        }
    }

    var quotaURL: URL {
        baseURL.appendingPathComponent("api/monitor/usage/quota/limit")
    }
}

// MARK: - Response parsing

enum ZaiResponseParser {
    struct Snapshot {
        var buckets: [QuotaBucket]
        var planName: String?
    }

    static func parse(data: Data, now: Date) throws -> Snapshot {
        let decoder = JSONDecoder()
        let response: ZaiAPIResponse
        do {
            response = try decoder.decode(ZaiAPIResponse.self, from: data)
        } catch {
            throw QuotaError.parseFailure("Z.ai response not parseable: \(error.localizedDescription)")
        }
        guard response.success, response.code == 200 else {
            throw QuotaError.network("Z.ai API error: \(response.msg)")
        }
        guard let body = response.data else {
            throw QuotaError.parseFailure("Z.ai response missing data envelope.")
        }

        var tokenLimits: [QuotaBucket] = []
        var timeLimit: QuotaBucket?

        for raw in body.limits {
            guard let bucket = raw.toBucket(now: now) else { continue }
            switch raw.type {
            case "TOKENS_LIMIT": tokenLimits.append(bucket)
            case "TIME_LIMIT":   timeLimit = bucket
            default:             continue
            }
        }

        // Match codexbar: with two TOKENS_LIMIT entries, the shorter
        // window is the secondary "session" bucket and the longer is
        // primary. Single entry → primary only.
        let primaryAndSecondary: [QuotaBucket]
        if tokenLimits.count >= 2 {
            let sorted = tokenLimits.sorted {
                ($0.rawWindowSeconds ?? .max) > ($1.rawWindowSeconds ?? .max)
            }
            // sorted[0] = longest window (primary), sorted[1] = shortest (secondary)
            primaryAndSecondary = Array(sorted.prefix(2))
        } else {
            primaryAndSecondary = tokenLimits
        }

        var buckets = primaryAndSecondary
        if let timeLimit { buckets.append(timeLimit) }

        return Snapshot(buckets: buckets, planName: body.planName)
    }
}

// MARK: - Wire types

private struct ZaiAPIResponse: Decodable {
    let code: Int
    let msg: String
    let data: ZaiAPIData?
    let success: Bool
}

private struct ZaiAPIData: Decodable {
    let limits: [ZaiRawLimit]
    let planName: String?

    enum CodingKeys: String, CodingKey {
        case limits, planName, plan
        case planType = "plan_type"
        case packageName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        limits = try c.decodeIfPresent([ZaiRawLimit].self, forKey: .limits) ?? []
        let candidates: [String?] = [
            try c.decodeIfPresent(String.self, forKey: .planName),
            try c.decodeIfPresent(String.self, forKey: .plan),
            try c.decodeIfPresent(String.self, forKey: .planType),
            try c.decodeIfPresent(String.self, forKey: .packageName)
        ]
        let raw = candidates.compactMap(\.self).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        planName = (raw?.isEmpty ?? true) ? nil : raw
    }
}

private struct ZaiRawLimit: Decodable {
    let type: String
    let unit: Int
    let number: Int
    let usage: Int?
    let currentValue: Int?
    let remaining: Int?
    let percentage: Int
    let nextResetTime: Int?

    /// Maps the API's enum-as-int unit to seconds. Unknown values
    /// drop through to nil so the bucket renders with "Resets ..."
    /// hidden rather than crashing.
    var windowSeconds: Int? {
        switch unit {
        case 1: return number * 86_400        // days
        case 3: return number * 3_600         // hours
        case 5: return number * 60            // minutes
        case 6: return number * 7 * 86_400    // weeks
        default: return nil
        }
    }

    func toBucket(now: Date) -> QuotaBucket? {
        // Title is "5 Hours" / "Daily" / "Weekly" / "Monthly" derived
        // from window. Falls back to a generic label otherwise.
        let title: String
        let shortLabel: String
        switch unit {
        case 1:
            title = number == 1 ? "Daily" : "\(number) Days"
            shortLabel = number == 1 ? "Day" : "\(number)d"
        case 3:
            title = "\(number) Hour\(number == 1 ? "" : "s")"
            shortLabel = "\(number)h"
        case 5:
            title = "\(number) Minute\(number == 1 ? "" : "s")"
            shortLabel = "\(number)m"
        case 6:
            title = number == 1 ? "Weekly" : "\(number) Weeks"
            shortLabel = number == 1 ? "Wk" : "\(number)w"
        default:
            title = type == "TIME_LIMIT" ? "Monthly" : "Tokens"
            shortLabel = type == "TIME_LIMIT" ? "Month" : "Tok"
        }

        // Compute used percent. Codexbar prefers `(usage - remaining) / usage * 100`
        // when both are present; otherwise it falls back to the
        // server-supplied integer percentage. Mirror that.
        let computed: Double
        if let usage, usage > 0, let remaining {
            let used = max(0, usage - remaining)
            computed = (Double(used) / Double(usage)) * 100
        } else {
            computed = Double(percentage)
        }

        let resetAt = nextResetTime.map {
            Date(timeIntervalSince1970: TimeInterval($0) / 1000)
        }

        let id: String
        switch type {
        case "TIME_LIMIT":   id = "zai.time"
        case "TOKENS_LIMIT": id = "zai.tokens.\(unit).\(number)"
        default:             id = "zai.\(type.lowercased()).\(unit).\(number)"
        }

        var bucket = QuotaBucket(
            id: id,
            title: title,
            shortLabel: shortLabel,
            usedPercent: computed,
            resetAt: resetAt,
            rawWindowSeconds: windowSeconds
        )
        // Annotate token-limit buckets with a group title so the UI
        // can disambiguate primary from session-window when both are
        // present.
        if type == "TOKENS_LIMIT" {
            bucket.groupTitle = title
        }
        _ = bucket
        return bucket
    }
}
