import Foundation

/// Moonshot / Kimi (kimi.com) usage adapter.
///
/// Auth: Kimi access + refresh JWTs. The shared Browser Cookies importer reads
/// both exact localStorage fields from one Chromium profile and stores them in
/// the same cookie-shaped Keychain slot used by legacy browser cookies and
/// manual headers. The adapter mirrors the website's one refresh + retry when
/// the short-lived access token expires.
///
/// `POST https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats`
/// with body `{}` is the primary source for the weekly, five-hour and
/// shared monthly balances shown on Kimi's Membership → My Quota page.
/// Older deployments fall back to
/// `POST https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages`
/// with body `{"scope":["FEATURE_CODING"]}` for weekly / five-hour data.
/// Headers reproduce the web app — Bearer token, kimi-auth cookie, browser
/// User-Agent, connect-protocol-version, plus session / device / traffic IDs
/// extracted from the JWT payload.
///
/// Output: weekly bucket (primary) + 5-hour rate-limit bucket + monthly
/// subscription bucket (when present).
public struct KimiQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .kimi

    private let session: URLSession
    private let now: @Sendable () -> Date

    fileprivate static let accessTokenCredential = ChromiumLocalStorageCredential(
        origin: "https://www.kimi.com",
        key: "access_token",
        syntheticCookieName: "kimi-auth",
        valueFormat: .jwt(segments: 3, minLength: 16, maxLength: 4_096)
    )
    fileprivate static let refreshTokenCredential = ChromiumLocalStorageCredential(
        origin: "https://www.kimi.com",
        key: "refresh_token",
        syntheticCookieName: "kimi-refresh",
        valueFormat: .jwt(segments: 3, minLength: 16, maxLength: 4_096)
    )

    public static let cookieSpec = MiscCookieResolver.Spec(
        tool: .kimi,
        domains: ["www.kimi.com", "kimi.com"],
        requiredNames: ["kimi-auth", "kimi-refresh"],
        credentialNames: ["kimi-auth"],
        browserCredentialSource: .chromiumLocalStorageFields([
            accessTokenCredential,
            refreshTokenCredential
        ])
    )

    private static let usageEndpoint = URL(string:
        "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages"
    )!
    private static let membershipStatsEndpoint = URL(string:
        "https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats"
    )!
    private static let refreshEndpoint = URL(string:
        "https://auth.kimi.com/api/account.gateway.v1.AuthService/RefreshToken"
    )!
    private static let membershipStatsWallTimeSeconds: Double = 10

    public init(
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.now = now
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        let resolutions = MiscCookieResolver.resolveAll(for: KimiQuotaAdapter.cookieSpec, account: account)
        guard !resolutions.isEmpty else { throw QuotaError.noCredential }

        let queriedAt = now()
        let results = await MiscCookieAutoImporter.shared.gatherSlotResults(
            spec: KimiQuotaAdapter.cookieSpec,
            account: account,
            resolutions: resolutions
        ) { resolution in
            try await self.fetchOneSlot(resolution, account: account, queriedAt: queriedAt)
        }
        var aggregated = MiscQuotaAggregator.aggregate(
            tool: .kimi,
            account: account,
            results: results,
            queriedAt: queriedAt
        )
        aggregated.buckets = KimiResponseParser.canonicalBucketOrder(aggregated.buckets)
        return aggregated
    }

    private func fetchOneSlot(
        _ resolution: MiscCookieResolver.Resolution,
        account: AccountIdentity,
        queriedAt: Date
    ) async throws -> AccountQuota {
        guard let credential = KimiCredential(cookieHeader: resolution.header) else {
            throw QuotaError.noCredential
        }

        let result = try await Self.fetchSnapshotRefreshingCredential(
            credential: credential,
            queriedAt: queriedAt
        ) { request in
            let (data, _) = try await self.data(for: request)
            return data
        }
        if result.didRefresh, let slotID = resolution.slotID {
            let instanceID = AccountStore.miscInstanceID(
                fromAccountID: account.id,
                fallbackTool: .kimi
            )
            let saved = MiscCookieSlotStore.updateHeader(
                slotID: slotID,
                for: .kimi,
                instanceID: instanceID,
                header: result.credential.cookieHeader,
                importedAt: queriedAt
            )
            if !saved {
                SafeLog.warn("Kimi refreshed credential could not be persisted for slot=\(slotID.uuidString.prefix(8))")
            }
        }

        return AccountQuota(
            accountId: account.id,
            tool: .kimi,
            buckets: result.snapshot.buckets,
            plan: nil,
            email: account.email,
            queriedAt: queriedAt,
            error: nil
        )
    }

    struct AuthenticatedSnapshot: Sendable {
        let snapshot: KimiResponseParser.Snapshot
        let credential: KimiCredential
        let didRefresh: Bool
    }

    /// Match the web client: try the stored access token, refresh once only on
    /// a credential-shaped failure, then retry the quota request once with the
    /// new pair. Manual access-token-only headers preserve their old behavior.
    static func fetchSnapshotRefreshingCredential(
        credential: KimiCredential,
        queriedAt: Date,
        membershipTimeoutSeconds: Double = Self.membershipStatsWallTimeSeconds,
        request: @escaping @Sendable (URLRequest) async throws -> Data
    ) async throws -> AuthenticatedSnapshot {
        do {
            let snapshot = try await fetchSnapshot(
                authToken: credential.accessToken,
                queriedAt: queriedAt,
                membershipTimeoutSeconds: membershipTimeoutSeconds,
                request: request
            )
            return AuthenticatedSnapshot(
                snapshot: snapshot,
                credential: credential,
                didRefresh: false
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch let error as QuotaError where error.isCredentialState {
            guard let refreshToken = credential.refreshToken else { throw error }
            try Task.checkCancellation()
            let refreshed = try await refreshCredential(
                accessToken: credential.accessToken,
                refreshToken: refreshToken,
                request: request
            )
            try Task.checkCancellation()
            let snapshot = try await fetchSnapshot(
                authToken: refreshed.accessToken,
                queriedAt: queriedAt,
                membershipTimeoutSeconds: membershipTimeoutSeconds,
                request: request
            )
            return AuthenticatedSnapshot(
                snapshot: snapshot,
                credential: refreshed,
                didRefresh: true
            )
        }
    }

    static func refreshCredential(
        accessToken: String,
        refreshToken: String,
        request: @escaping @Sendable (URLRequest) async throws -> Data
    ) async throws -> KimiCredential {
        let data = try await request(refreshRequest(
            accessToken: accessToken,
            refreshToken: refreshToken
        ))
        let response: KimiRefreshTokenResponse
        do {
            response = try JSONDecoder().decode(KimiRefreshTokenResponse.self, from: data)
        } catch {
            throw QuotaError.parseFailure(
                "Kimi refresh response not parseable: \(error.localizedDescription)"
            )
        }
        guard let credential = KimiCredential(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken
        ) else {
            throw QuotaError.parseFailure("Kimi refresh response had invalid tokens.")
        }
        return credential
    }

    static func fetchSnapshot(
        authToken: String,
        queriedAt: Date,
        membershipTimeoutSeconds: Double = Self.membershipStatsWallTimeSeconds,
        request: @escaping @Sendable (URLRequest) async throws -> Data
    ) async throws -> KimiResponseParser.Snapshot {
        let membershipOutcome = await AsyncTimeout.run(seconds: membershipTimeoutSeconds) {
            do {
                let data = try await request(Self.membershipStatsRequest(authToken: authToken))
                return KimiMembershipFetchOutcome.snapshot(
                    try KimiResponseParser.parseMembership(data: data)
                )
            } catch is CancellationError {
                return KimiMembershipFetchOutcome.cancelled
            } catch let error as URLError where error.code == .cancelled {
                return KimiMembershipFetchOutcome.cancelled
            } catch let error as QuotaError {
                return KimiMembershipFetchOutcome.failed(error)
            } catch {
                return KimiMembershipFetchOutcome.failed(mapURLError(error))
            }
        }
        try Task.checkCancellation()

        switch membershipOutcome {
        case let .completed(.snapshot(membership)):
            return try await supplementMembershipIfNeeded(
                membership,
                authToken: authToken,
                queriedAt: queriedAt,
                request: request
            )
        case .completed(.cancelled):
            throw CancellationError()
        case let .completed(.failed(primaryError)):
            // Older Kimi deployments expose only BillingService/GetUsages.
            // Keep that as a compatibility fallback, but never make the old
            // endpoint a prerequisite for the current Membership page data.
            // Membership non-200 responses are not authoritative credential
            // failures: Kimi's current web client can reject this optional
            // surface while the same token still works for BillingService.
            return try await legacySnapshot(
                authToken: authToken,
                queriedAt: queriedAt,
                primaryError: primaryError,
                request: request
            )
        case .timedOut:
            return try await legacySnapshot(
                authToken: authToken,
                queriedAt: queriedAt,
                primaryError: .network("timeout"),
                request: request
            )
        }
    }

    /// Membership is authoritative for every bucket it returns, but rollouts
    /// can temporarily omit one coding window. Fill only missing weekly/5h
    /// lanes from Billing; a failed supplement must not erase valid monthly or
    /// weekly Membership data.
    private static func supplementMembershipIfNeeded(
        _ membership: KimiResponseParser.Snapshot,
        authToken: String,
        queriedAt: Date,
        request: @escaping @Sendable (URLRequest) async throws -> Data
    ) async throws -> KimiResponseParser.Snapshot {
        let ids = Set(membership.buckets.map(\.id))
        guard !ids.contains("kimi.weekly") || !ids.contains("kimi.rate") else {
            return membership
        }
        try Task.checkCancellation()
        do {
            let data = try await request(Self.usageRequest(authToken: authToken))
            let legacy = try KimiResponseParser.parse(data: data, now: queriedAt)
            return KimiResponseParser.merging(preferred: membership, fallback: legacy)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return membership
        }
    }

    private static func legacySnapshot(
        authToken: String,
        queriedAt: Date,
        primaryError: QuotaError,
        request: @escaping @Sendable (URLRequest) async throws -> Data
    ) async throws -> KimiResponseParser.Snapshot {
        try Task.checkCancellation()
        do {
            let data = try await request(Self.usageRequest(authToken: authToken))
            return try KimiResponseParser.parse(data: data, now: queriedAt)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let fallbackError as QuotaError {
            throw mergedFailure(primary: primaryError, fallback: fallbackError)
        } catch {
            throw primaryError
        }
    }

    /// The Membership endpoint is optional and can reject a token that the
    /// Billing endpoint still accepts, so one credential-shaped error is not
    /// enough to tell the user to log in again. The same rule keeps a single
    /// endpoint's rate limit from hiding a more useful error from the other.
    private static func mergedFailure(primary: QuotaError, fallback: QuotaError) -> QuotaError {
        if primary.isCredentialState, fallback.isCredentialState {
            return .needsLogin
        }
        if primary.isCredentialState { return fallback }
        if fallback.isCredentialState { return primary }
        if primary == .rateLimited, fallback != .rateLimited { return fallback }
        if fallback == .rateLimited, primary != .rateLimited { return primary }
        return primary
    }

    static func usageRequest(authToken: String) -> URLRequest {
        makeRequest(
            url: usageEndpoint,
            authToken: authToken,
            referer: "https://www.kimi.com/code/console",
            body: ["scope": ["FEATURE_CODING"]]
        )
    }

    static func membershipStatsRequest(authToken: String) -> URLRequest {
        makeRequest(
            url: membershipStatsEndpoint,
            authToken: authToken,
            referer: "https://www.kimi.com/membership/subscription?tab=quota",
            body: [:]
        )
    }

    static func refreshRequest(accessToken: String, refreshToken: String) -> URLRequest {
        let session = KimiSessionInfo.fromJWT(accessToken)
        var request = URLRequest(url: refreshEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://www.kimi.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.kimi.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        request.setValue("web", forHTTPHeaderField: "x-msh-platform")
        request.setValue("2.0.0", forHTTPHeaderField: "x-msh-version")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "r-timezone")
        if let deviceId = session.deviceId {
            request.setValue(deviceId, forHTTPHeaderField: "x-msh-device-id")
        }
        if let sessionId = session.sessionId {
            request.setValue(sessionId, forHTTPHeaderField: "x-msh-session-id")
        }
        if let trafficId = session.trafficId {
            request.setValue(trafficId, forHTTPHeaderField: "x-traffic-id")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "refresh_token": refreshToken
        ])
        return request
    }

    private static func makeRequest(
        url: URL,
        authToken: String,
        referer: String,
        body: [String: Any]
    ) -> URLRequest {
        let session = KimiSessionInfo.fromJWT(authToken)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("kimi-auth=\(authToken)", forHTTPHeaderField: "Cookie")
        request.setValue("https://www.kimi.com", forHTTPHeaderField: "Origin")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        request.setValue("en-US", forHTTPHeaderField: "x-language")
        request.setValue("web", forHTTPHeaderField: "x-msh-platform")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "r-timezone")
        if let deviceId = session.deviceId  { request.setValue(deviceId,  forHTTPHeaderField: "x-msh-device-id") }
        if let sessionId = session.sessionId { request.setValue(sessionId, forHTTPHeaderField: "x-msh-session-id") }
        if let trafficId = session.trafficId { request.setValue(trafficId, forHTTPHeaderField: "x-traffic-id") }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await self.session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            throw QuotaError.network("Kimi network error: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Kimi: invalid response object")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw QuotaError.needsLogin
            }
            if http.statusCode == 429 {
                throw QuotaError.rateLimited
            }
            throw QuotaError.network("Kimi returned HTTP \(http.statusCode).")
        }
        return (data, http)
    }
}

private enum KimiMembershipFetchOutcome: Sendable {
    case snapshot(KimiResponseParser.Snapshot)
    case failed(QuotaError)
    case cancelled
}

struct KimiCredential: Sendable, Equatable {
    let accessToken: String
    let refreshToken: String?

    init?(cookieHeader: String) {
        let pairs = CookieHeaderNormalizer.pairs(from: cookieHeader)
        guard let accessToken = pairs.first(where: { $0.name == "kimi-auth" })?.value else {
            return nil
        }
        self.init(
            accessToken: accessToken,
            refreshToken: pairs.first(where: { $0.name == "kimi-refresh" })?.value
        )
    }

    init?(accessToken: String, refreshToken: String?) {
        guard let accessToken = KimiQuotaAdapter.accessTokenCredential
            .valueFormat.normalizedValue(accessToken) else {
            return nil
        }
        if let refreshToken {
            guard let normalized = KimiQuotaAdapter.refreshTokenCredential
                .valueFormat.normalizedValue(refreshToken) else {
                return nil
            }
            self.refreshToken = normalized
        } else {
            self.refreshToken = nil
        }
        self.accessToken = accessToken
    }

    var cookieHeader: String {
        var pairs = ["kimi-auth=\(accessToken)"]
        if let refreshToken {
            pairs.append("kimi-refresh=\(refreshToken)")
        }
        return pairs.joined(separator: "; ")
    }
}

private struct KimiRefreshTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
}

// MARK: - JWT session info

struct KimiSessionInfo {
    let deviceId: String?
    let sessionId: String?
    let trafficId: String?

    static let empty = KimiSessionInfo(deviceId: nil, sessionId: nil, trafficId: nil)

    static func fromJWT(_ jwt: String) -> KimiSessionInfo {
        let parts = jwt.split(separator: ".", maxSplits: 2)
        guard parts.count == 3 else { return .empty }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .empty }
        return KimiSessionInfo(
            deviceId: json["device_id"] as? String,
            sessionId: json["ssid"] as? String,
            trafficId: json["sub"] as? String
        )
    }
}

// MARK: - Response parsing

enum KimiResponseParser {
    struct Snapshot: Sendable {
        var buckets: [QuotaBucket]
    }

    static func parse(data: Data, now: Date) throws -> Snapshot {
        let response: KimiAPIResponse
        do {
            response = try JSONDecoder().decode(KimiAPIResponse.self, from: data)
        } catch {
            throw QuotaError.parseFailure("Kimi response not parseable: \(error.localizedDescription)")
        }
        guard let coding = response.usages.first(where: { $0.scope == "FEATURE_CODING" }) else {
            throw QuotaError.parseFailure("Kimi response: FEATURE_CODING scope missing.")
        }

        var buckets: [QuotaBucket] = []
        if let weekly = makeBucket(
            id: "kimi.weekly",
            title: "Weekly",
            shortLabel: "Wk",
            from: coding.detail,
            windowSeconds: 7 * 86_400
        ) {
            buckets.append(weekly)
        }
        if let rate = coding.limits?.first {
            let label = rate.window?.shortLabel ?? "5h"
            let title = rate.window?.title ?? "5 Hours"
            if let bucket = makeBucket(
                id: "kimi.rate",
                title: title,
                shortLabel: label,
                from: rate.detail,
                windowSeconds: rate.window?.windowSeconds ?? 5 * 3600
            ) {
                buckets.append(bucket)
            }
        }

        guard !buckets.isEmpty else {
            throw QuotaError.parseFailure("Kimi response had no usable usage windows.")
        }
        return Snapshot(buckets: buckets)
    }

    static func parseMonthly(data: Data) throws -> QuotaBucket? {
        makeMonthlyBucket(from: try decodeMembership(data: data).subscriptionBalance)
    }

    static func parseMembership(data: Data) throws -> Snapshot {
        let response = try decodeMembership(data: data)
        var buckets: [QuotaBucket] = []

        if let weekly = makeRateBucket(
            id: "kimi.weekly",
            title: "Weekly",
            shortLabel: "Wk",
            from: response.ratelimitCode7d,
            windowSeconds: 7 * 86_400
        ) {
            buckets.append(weekly)
        }
        if let fiveHour = makeRateBucket(
            id: "kimi.rate",
            title: "5 Hours",
            shortLabel: "5h",
            from: response.ratelimitCode5h,
            windowSeconds: 5 * 3600
        ) {
            buckets.append(fiveHour)
        }
        if let monthly = makeMonthlyBucket(from: response.subscriptionBalance) {
            buckets.append(monthly)
        }

        guard !buckets.isEmpty else {
            throw QuotaError.parseFailure("Kimi membership response had no usable usage windows.")
        }
        return Snapshot(buckets: buckets)
    }

    static func canonicalBucketOrder(_ buckets: [QuotaBucket]) -> [QuotaBucket] {
        let rank = ["kimi.weekly", "kimi.rate", "kimi.monthly"]
        return buckets.sorted { lhs, rhs in
            let left = rank.firstIndex(of: lhs.id) ?? rank.count
            let right = rank.firstIndex(of: rhs.id) ?? rank.count
            return left == right ? lhs.id < rhs.id : left < right
        }
    }

    static func merging(preferred: Snapshot, fallback: Snapshot) -> Snapshot {
        var buckets = fallback.buckets
        for bucket in preferred.buckets {
            if let index = buckets.firstIndex(where: { $0.id == bucket.id }) {
                buckets[index] = bucket
            } else {
                buckets.append(bucket)
            }
        }
        return Snapshot(buckets: canonicalBucketOrder(buckets))
    }

    private static func decodeMembership(data: Data) throws -> KimiMembershipStatsResponse {
        let response: KimiMembershipStatsResponse
        do {
            response = try JSONDecoder().decode(KimiMembershipStatsResponse.self, from: data)
        } catch {
            throw QuotaError.parseFailure("Kimi membership response not parseable: \(error.localizedDescription)")
        }
        return response
    }

    private static func makeMonthlyBucket(from balance: KimiSubscriptionBalance?) -> QuotaBucket? {
        guard let balance,
              balance.feature == "FEATURE_OMNI",
              balance.type == "SUBSCRIPTION",
              let ratio = balance.amountUsedRatio,
              ratio.isFinite else {
            return nil
        }
        return QuotaBucket(
            id: "kimi.monthly",
            title: "Monthly",
            shortLabel: "Mo",
            usedPercent: max(0, min(100, ratio * 100)),
            resetAt: parseResetTime(balance.expireTime),
            rawWindowSeconds: 30 * 86_400
        )
    }

    private static func makeRateBucket(
        id: String,
        title: String,
        shortLabel: String,
        from limit: KimiMembershipRateLimit?,
        windowSeconds: Int
    ) -> QuotaBucket? {
        guard let limit,
              limit.enabled != false,
              let ratio = limit.ratio,
              ratio.isFinite else {
            return nil
        }
        return QuotaBucket(
            id: id,
            title: title,
            shortLabel: shortLabel,
            usedPercent: max(0, min(100, ratio * 100)),
            resetAt: parseResetTime(limit.resetTime),
            rawWindowSeconds: windowSeconds
        )
    }

    private static func makeBucket(
        id: String,
        title: String,
        shortLabel: String,
        from detail: KimiAPIDetail,
        windowSeconds: Int
    ) -> QuotaBucket? {
        let limit = Int(detail.limit) ?? 0
        guard limit > 0 else { return nil }
        let used: Int = {
            if let usedStr = detail.used, let n = Int(usedStr) { return n }
            if let remStr = detail.remaining, let r = Int(remStr) { return max(0, limit - r) }
            return 0
        }()
        let percent = max(0, min(100, Double(used) / Double(limit) * 100))
        let resetAt = parseResetTime(detail.resetTime)
        return QuotaBucket(
            id: id,
            title: title,
            shortLabel: shortLabel,
            usedPercent: percent,
            resetAt: resetAt,
            rawWindowSeconds: windowSeconds
        )
    }

    private static func parseResetTime(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

// MARK: - Wire types

private struct KimiAPIResponse: Decodable {
    let usages: [KimiAPIUsage]
}

private struct KimiAPIUsage: Decodable {
    let scope: String
    let detail: KimiAPIDetail
    let limits: [KimiAPILimit]?
}

private struct KimiAPILimit: Decodable {
    let window: KimiAPIWindow?
    let detail: KimiAPIDetail
}

struct KimiAPIWindow: Decodable {
    let duration: Int
    let timeUnit: String

    var windowSeconds: Int? {
        let normalized = timeUnit.uppercased()
            .replacingOccurrences(of: "TIME_UNIT_", with: "")
        switch normalized {
        case "SECOND", "SECONDS": return duration
        case "MINUTE", "MINUTES": return duration * 60
        case "HOUR", "HOURS":     return duration * 3600
        case "DAY", "DAYS":       return duration * 86_400
        case "WEEK", "WEEKS":     return duration * 7 * 86_400
        case "SESSION", "SESSIONS": return 5 * 3600
        default: return nil
        }
    }

    var title: String {
        guard let secs = windowSeconds else { return "5 Hours" }
        if secs >= 86_400 {
            let days = secs / 86_400
            return "\(days) Day\(days == 1 ? "" : "s")"
        }
        if secs >= 3600 {
            let hours = secs / 3600
            return "\(hours) Hour\(hours == 1 ? "" : "s")"
        }
        let minutes = max(1, secs / 60)
        return "\(minutes) Minute\(minutes == 1 ? "" : "s")"
    }

    var shortLabel: String {
        guard let secs = windowSeconds else { return "5h" }
        if secs >= 86_400 { return "\(secs / 86_400)d" }
        if secs >= 3600   { return "\(secs / 3600)h" }
        return "\(max(1, secs / 60))m"
    }
}

struct KimiAPIDetail: Decodable {
    let limit: String
    let used: String?
    let remaining: String?
    let resetTime: String?
}

private struct KimiMembershipStatsResponse: Decodable {
    let ratelimitCode5h: KimiMembershipRateLimit?
    let ratelimitCode7d: KimiMembershipRateLimit?
    let subscriptionBalance: KimiSubscriptionBalance?
}

private struct KimiMembershipRateLimit: Decodable {
    let ratio: Double?
    let enabled: Bool?
    let resetTime: String?
}

private struct KimiSubscriptionBalance: Decodable {
    let feature: String?
    let type: String?
    let amountUsedRatio: Double?
    let expireTime: String?
}
