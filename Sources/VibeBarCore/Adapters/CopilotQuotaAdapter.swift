import Foundation

/// GitHub Copilot usage adapter.
///
/// Auth: GitHub OAuth device flow. Legacy pasted PATs are still read
/// as a migration fallback, but Settings now writes the device-flow
/// access token into Keychain.
/// Endpoint: `GET https://api.github.com/copilot_internal/user`
/// (or the configured GitHub Enterprise host).
///
/// Output: up to two `QuotaBucket`s — Premium Interactions
/// (primary) and Chat (secondary). Plan name carries the
/// `copilot_plan` field ("pro", "business", "enterprise") and is
/// title-cased before reaching the badge.
public struct CopilotQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .copilot

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
        let providerSettings = MiscProviderSettings.current(for: .copilot)
        guard providerSettings.allowsAPIOrOAuthAccess else {
            throw QuotaError.noCredential
        }
        let token = resolveToken()
        guard let token, !token.isEmpty else {
            throw QuotaError.noCredential
        }

        let enterpriseHost = enterpriseHost(from: providerSettings)
        guard let url = CopilotEndpoint.usageURL(enterpriseHost: enterpriseHost) else {
            throw QuotaError.network("Copilot enterprise host invalid: \(enterpriseHost ?? "<nil>")")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // GitHub's `/copilot_internal/user` endpoint requires the
        // editor-version pretender headers — codexbar pins these to
        // the same VS Code build.
        request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
        request.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuotaError.network("Copilot network error: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Copilot: invalid response object")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw QuotaError.needsLogin
            }
            if http.statusCode == 429 {
                throw QuotaError.rateLimited
            }
            throw QuotaError.network("Copilot returned HTTP \(http.statusCode).")
        }

        let snapshot = try CopilotResponseParser.parse(data: data, now: now())
        return AccountQuota(
            accountId: account.id,
            tool: .copilot,
            buckets: snapshot.buckets,
            plan: snapshot.planName,
            email: account.email,
            queriedAt: now(),
            error: nil
        )
    }

    private func resolveToken() -> String? {
        if let env = environment["COPILOT_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        if let deviceToken = MiscCredentialStore.readString(tool: .copilot, kind: .oauthAccessToken),
           !deviceToken.isEmpty {
            return deviceToken
        }
        return MiscCredentialStore.readString(tool: .copilot, kind: .apiKey)
    }

    private func enterpriseHost(from settings: MiscProviderSettings) -> String? {
        guard let url = settings.enterpriseHost,
              let host = url.host else {
            return nil
        }
        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }
}

// MARK: - Endpoint resolution

enum CopilotEndpoint {
    static let defaultHost = "github.com"

    static func apiHost(enterpriseHost: String?) -> String {
        let host = normalizedHost(enterpriseHost)
        if host == defaultHost { return "api.github.com" }
        if host.hasPrefix("api.") { return host }
        return "api.\(host)"
    }

    static func usageURL(enterpriseHost: String?) -> URL? {
        let host = apiHost(enterpriseHost: enterpriseHost)
        return CopilotDeviceFlow.makeRequestURL(host: host, path: "/copilot_internal/user")
    }

    static func normalizedHost(_ host: String?) -> String {
        CopilotDeviceFlow.normalizedHost(host)
    }
}

// MARK: - Response parsing

enum CopilotResponseParser {
    struct Snapshot {
        var buckets: [QuotaBucket]
        var planName: String?
    }

    static func parse(data: Data, now: Date) throws -> Snapshot {
        let response: CopilotAPIResponse
        do {
            response = try JSONDecoder().decode(CopilotAPIResponse.self, from: data)
        } catch {
            throw QuotaError.parseFailure("Copilot response not parseable: \(error.localizedDescription)")
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let resetAt: Date? = response.quotaResetDate.flatMap {
            isoFormatter.date(from: $0)
                ?? ISO8601DateFormatter.dateOnly(from: $0)
        }

        var buckets: [QuotaBucket] = []
        if let premium = response.quotaSnapshots?.premiumInteractions,
           let bucket = makeBucket(
               id: "copilot.premium",
               title: "Premium",
               shortLabel: "Premium",
               from: premium,
               resetAt: resetAt
           ) {
            buckets.append(bucket)
        }
        if let chat = response.quotaSnapshots?.chat,
           let bucket = makeBucket(
               id: "copilot.chat",
               title: "Chat",
               shortLabel: "Chat",
               from: chat,
               resetAt: resetAt
           ) {
            buckets.append(bucket)
        }
        guard !buckets.isEmpty else {
            throw QuotaError.parseFailure("Copilot response had no usable quota snapshots.")
        }

        let planLower = response.copilotPlan.lowercased()
        let planName: String?
        switch planLower {
        case "free":               planName = "Free"
        case "individual", "pro":  planName = "Pro"
        case "business":           planName = "Business"
        case "enterprise":         planName = "Enterprise"
        case "unknown", "":        planName = nil
        default:                   planName = response.copilotPlan.capitalized
        }

        return Snapshot(buckets: buckets, planName: planName)
    }

    private static func makeBucket(
        id: String,
        title: String,
        shortLabel: String,
        from snapshot: CopilotAPISnapshot,
        resetAt: Date?
    ) -> QuotaBucket? {
        guard !snapshot.isPlaceholder, snapshot.hasPercentRemaining else { return nil }
        let percent = max(0, min(100, 100 - snapshot.percentRemaining))

        return QuotaBucket(
            id: id,
            title: title,
            shortLabel: shortLabel,
            usedPercent: percent,
            resetAt: resetAt,
            rawWindowSeconds: nil
        )
    }
}

// MARK: - Wire types

private struct CopilotAPIResponse: Decodable {
    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    let quotaSnapshots: CopilotAPISnapshots?
    let copilotPlan: String
    let quotaResetDate: String?

    enum CodingKeys: String, CodingKey {
        case quotaSnapshots = "quota_snapshots"
        case copilotPlan = "copilot_plan"
        case quotaResetDate = "quota_reset_date"
        case monthlyQuotas = "monthly_quotas"
        case limitedUserQuotas = "limited_user_quotas"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let direct = try c.decodeIfPresent(CopilotAPISnapshots.self, forKey: .quotaSnapshots)
        let monthly = try c.decodeIfPresent(CopilotQuotaCounts.self, forKey: .monthlyQuotas)
        let limited = try c.decodeIfPresent(CopilotQuotaCounts.self, forKey: .limitedUserQuotas)
        let monthlyLimited = Self.makeQuotaSnapshots(monthly: monthly, limited: limited)
        let premium = Self.usableQuotaSnapshot(from: direct?.premiumInteractions)
            ?? Self.usableQuotaSnapshot(from: monthlyLimited?.premiumInteractions)
        let chat = Self.usableQuotaSnapshot(from: direct?.chat)
            ?? Self.usableQuotaSnapshot(from: monthlyLimited?.chat)
        if premium != nil || chat != nil {
            quotaSnapshots = CopilotAPISnapshots(premiumInteractions: premium, chat: chat)
        } else {
            quotaSnapshots = direct ?? CopilotAPISnapshots(premiumInteractions: nil, chat: nil)
        }
        copilotPlan = try c.decodeIfPresent(String.self, forKey: .copilotPlan) ?? "unknown"
        quotaResetDate = try c.decodeIfPresent(String.self, forKey: .quotaResetDate)
    }

    private static func makeQuotaSnapshots(
        monthly: CopilotQuotaCounts?,
        limited: CopilotQuotaCounts?
    ) -> CopilotAPISnapshots? {
        let premium = makeQuotaSnapshot(
            monthly: monthly?.completions,
            limited: limited?.completions,
            quotaID: "completions"
        )
        let chat = makeQuotaSnapshot(
            monthly: monthly?.chat,
            limited: limited?.chat,
            quotaID: "chat"
        )
        guard premium != nil || chat != nil else { return nil }
        return CopilotAPISnapshots(premiumInteractions: premium, chat: chat)
    }

    private static func makeQuotaSnapshot(
        monthly: Double?,
        limited: Double?,
        quotaID: String
    ) -> CopilotAPISnapshot? {
        guard let monthly, let limited else { return nil }
        let entitlement = max(0, monthly)
        guard entitlement > 0 else { return nil }
        let remaining = max(0, limited)
        let percentRemaining = max(0, min(100, (remaining / entitlement) * 100))
        return CopilotAPISnapshot(
            entitlement: entitlement,
            remaining: remaining,
            percentRemaining: percentRemaining,
            quotaId: quotaID,
            hasPercentRemaining: true
        )
    }

    private static func usableQuotaSnapshot(from snapshot: CopilotAPISnapshot?) -> CopilotAPISnapshot? {
        guard let snapshot, !snapshot.isPlaceholder, snapshot.hasPercentRemaining else { return nil }
        return snapshot
    }
}

private struct CopilotAPISnapshots: Decodable {
    let premiumInteractions: CopilotAPISnapshot?
    let chat: CopilotAPISnapshot?

    enum CodingKeys: String, CodingKey {
        case premiumInteractions = "premium_interactions"
        case chat
    }

    init(premiumInteractions: CopilotAPISnapshot?, chat: CopilotAPISnapshot?) {
        self.premiumInteractions = premiumInteractions
        self.chat = chat
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var premium = try c.decodeIfPresent(CopilotAPISnapshot.self, forKey: .premiumInteractions)
        var chat = try c.decodeIfPresent(CopilotAPISnapshot.self, forKey: .chat)
        if premium?.isPlaceholder == true { premium = nil }
        if chat?.isPlaceholder == true { chat = nil }

        if premium == nil || chat == nil {
            let dynamic = try decoder.container(keyedBy: CopilotAnyCodingKey.self)
            var fallbackPremium: CopilotAPISnapshot?
            var fallbackChat: CopilotAPISnapshot?
            var firstUsable: CopilotAPISnapshot?

            for key in dynamic.allKeys {
                guard let decoded = try? dynamic.decodeIfPresent(CopilotAPISnapshot.self, forKey: key),
                      !decoded.isPlaceholder,
                      decoded.hasPercentRemaining else {
                    continue
                }

                let name = key.stringValue.lowercased()
                if firstUsable == nil { firstUsable = decoded }
                if fallbackChat == nil, name.contains("chat") {
                    fallbackChat = decoded
                    continue
                }
                if fallbackPremium == nil,
                   name.contains("premium") || name.contains("completion") || name.contains("code") {
                    fallbackPremium = decoded
                }
            }

            if premium == nil { premium = fallbackPremium }
            if chat == nil { chat = fallbackChat }
            if premium == nil, chat == nil {
                chat = firstUsable
            }
        }

        self.premiumInteractions = premium
        self.chat = chat
    }
}

private struct CopilotAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private struct CopilotQuotaCounts: Decodable {
    let chat: Double?
    let completions: Double?

    enum CodingKeys: String, CodingKey {
        case chat
        case completions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chat = Self.decodeNumberIfPresent(container: c, key: .chat)
        completions = Self.decodeNumberIfPresent(container: c, key: .completions)
    }

    private static func decodeNumberIfPresent(
        container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Double(value)
        }
        return nil
    }
}

struct CopilotAPISnapshot: Decodable {
    let entitlement: Double
    let remaining: Double
    let percentRemaining: Double
    let quotaId: String
    let hasPercentRemaining: Bool

    var isPlaceholder: Bool {
        entitlement == 0 && remaining == 0 && percentRemaining == 0 && quotaId.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case entitlement
        case remaining
        case percentRemaining = "percent_remaining"
        case quotaId = "quota_id"
    }

    init(
        entitlement: Double,
        remaining: Double,
        percentRemaining: Double,
        quotaId: String,
        hasPercentRemaining: Bool
    ) {
        self.entitlement = entitlement
        self.remaining = remaining
        self.percentRemaining = percentRemaining
        self.quotaId = quotaId
        self.hasPercentRemaining = hasPercentRemaining
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedEntitlement = Self.decodeNumberIfPresent(container: c, key: .entitlement)
        let decodedRemaining = Self.decodeNumberIfPresent(container: c, key: .remaining)
        entitlement = decodedEntitlement ?? 0
        remaining = decodedRemaining ?? 0
        let decodedPercent = Self.decodeNumberIfPresent(container: c, key: .percentRemaining)
        if let decodedPercent {
            percentRemaining = max(0, min(100, decodedPercent))
            hasPercentRemaining = true
        } else if let entitlement = decodedEntitlement,
                  entitlement > 0,
                  let remaining = decodedRemaining {
            percentRemaining = max(0, min(100, (remaining / entitlement) * 100))
            hasPercentRemaining = true
        } else {
            percentRemaining = 0
            hasPercentRemaining = false
        }
        quotaId = (try? c.decodeIfPresent(String.self, forKey: .quotaId)) ?? ""
    }

    private static func decodeNumberIfPresent(
        container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Double(value)
        }
        return nil
    }
}

// MARK: - ISO date helper

private extension ISO8601DateFormatter {
    static func dateOnly(from string: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: string)
    }
}
