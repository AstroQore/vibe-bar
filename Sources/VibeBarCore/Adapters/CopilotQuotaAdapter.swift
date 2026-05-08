import Foundation

/// GitHub Copilot usage adapter.
///
/// Auth: GitHub Personal Access Token pasted in Settings (or the
/// future device-flow output, which lands as a follow-up commit).
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
        let token = resolveToken()
        guard let token, !token.isEmpty else {
            throw QuotaError.noCredential
        }

        let enterpriseHost = enterpriseHostFromSettings()
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
        return MiscCredentialStore.readString(tool: .copilot, kind: .apiKey)
    }

    private func enterpriseHostFromSettings() -> String? {
        // Read settings.json directly so the adapter doesn't depend
        // on the @MainActor-bound SettingsStore. VibeBarLocalStore
        // is part of VibeBarCore and tolerates a missing file.
        guard let settings = try? VibeBarLocalStore.readJSON(
            AppSettings.self,
            from: VibeBarLocalStore.settingsURL
        ) else { return nil }
        return settings.miscProvider(.copilot).enterpriseHost?.host
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
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/copilot_internal/user"
        return components.url
    }

    static func normalizedHost(_ host: String?) -> String {
        let trimmed = host?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let trimmed, !trimmed.isEmpty else { return defaultHost }
        return trimmed
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
        // Skip placeholder rows (all-zero, no quota id).
        if snapshot.entitlement == 0,
           snapshot.remaining == 0,
           (snapshot.percentRemaining ?? 0) == 0,
           (snapshot.quotaId ?? "").isEmpty {
            return nil
        }

        let percent: Double
        if let pct = snapshot.percentRemaining {
            percent = max(0, min(100, 100 - pct))
        } else if snapshot.entitlement > 0 {
            let remaining = max(0, snapshot.remaining)
            let computed = (remaining / snapshot.entitlement) * 100
            percent = max(0, min(100, 100 - computed))
        } else {
            return nil
        }

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
    let quotaSnapshots: CopilotAPISnapshots?
    let copilotPlan: String
    let quotaResetDate: String?

    enum CodingKeys: String, CodingKey {
        case quotaSnapshots = "quota_snapshots"
        case copilotPlan = "copilot_plan"
        case quotaResetDate = "quota_reset_date"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quotaSnapshots = try c.decodeIfPresent(CopilotAPISnapshots.self, forKey: .quotaSnapshots)
        copilotPlan = try c.decodeIfPresent(String.self, forKey: .copilotPlan) ?? "unknown"
        quotaResetDate = try c.decodeIfPresent(String.self, forKey: .quotaResetDate)
    }
}

private struct CopilotAPISnapshots: Decodable {
    let premiumInteractions: CopilotAPISnapshot?
    let chat: CopilotAPISnapshot?

    enum CodingKeys: String, CodingKey {
        case premiumInteractions = "premium_interactions"
        case chat
    }
}

struct CopilotAPISnapshot: Decodable {
    let entitlement: Double
    let remaining: Double
    let percentRemaining: Double?
    let quotaId: String?

    enum CodingKeys: String, CodingKey {
        case entitlement
        case remaining
        case percentRemaining = "percent_remaining"
        case quotaId = "quota_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entitlement = (try? c.decodeIfPresent(Double.self, forKey: .entitlement)) ?? 0
        remaining = (try? c.decodeIfPresent(Double.self, forKey: .remaining)) ?? 0
        percentRemaining = try? c.decodeIfPresent(Double.self, forKey: .percentRemaining)
        quotaId = try? c.decodeIfPresent(String.self, forKey: .quotaId)
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
