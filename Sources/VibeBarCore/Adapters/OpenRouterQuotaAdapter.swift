import Foundation

/// OpenRouter usage adapter.
///
/// Auth: OpenRouter API key from Keychain, falling back to
/// `OPENROUTER_API_KEY`. The base API URL defaults to
/// `https://openrouter.ai/api/v1` and can be overridden by
/// `OPENROUTER_API_URL` or the misc provider host setting.
public struct OpenRouterQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .openRouter

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
        let settings = MiscProviderSettings.current(for: .openRouter)
        guard settings.allowsAPIOrOAuthAccess,
              let apiKey = Self.resolveAPIKey(environment: environment) else {
            throw QuotaError.noCredential
        }

        let baseURL = Self.resolveBaseURL(environment: environment, settings: settings)
        let credits = try await fetchCredits(baseURL: baseURL, apiKey: apiKey)
        let keyStats = try? await fetchKeyStats(baseURL: baseURL, apiKey: apiKey)
        let snapshot = OpenRouterResponseParser.snapshot(credits: credits, keyStats: keyStats)

        return AccountQuota(
            accountId: account.id,
            tool: .openRouter,
            buckets: snapshot.buckets,
            plan: snapshot.planName,
            email: account.email,
            queriedAt: now(),
            error: nil,
            providerExtras: ProviderExtras(
                tool: .openRouter,
                creditsRemainingUSD: snapshot.creditsRemainingUSD,
                creditsTopupURL: URL(string: "https://openrouter.ai/settings/credits"),
                updatedAt: now()
            )
        )
    }

    private func fetchCredits(baseURL: URL, apiKey: String) async throws -> OpenRouterCredits {
        let data = try await getJSON(baseURL.appendingPathComponent("credits"), apiKey: apiKey)
        do {
            return try OpenRouterResponseParser.parseCredits(data: data)
        } catch let error as QuotaError {
            throw error
        } catch {
            throw QuotaError.parseFailure("OpenRouter credits response not parseable: \(error.localizedDescription)")
        }
    }

    private func fetchKeyStats(baseURL: URL, apiKey: String) async throws -> OpenRouterKeyStats {
        let data = try await getJSON(baseURL.appendingPathComponent("key"), apiKey: apiKey)
        do {
            return try OpenRouterResponseParser.parseKeyStats(data: data)
        } catch let error as QuotaError {
            throw error
        } catch {
            throw QuotaError.parseFailure("OpenRouter key response not parseable: \(error.localizedDescription)")
        }
    }

    private func getJSON(_ url: URL, apiKey: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let referer = nonEmpty(environment["OPENROUTER_HTTP_REFERER"]) {
            request.setValue(referer, forHTTPHeaderField: "HTTP-Referer")
        }
        if let title = nonEmpty(environment["OPENROUTER_X_TITLE"]) {
            request.setValue(title, forHTTPHeaderField: "X-Title")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuotaError.network("OpenRouter network error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("OpenRouter: invalid response object")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw QuotaError.needsLogin
            }
            if http.statusCode == 429 {
                throw QuotaError.rateLimited
            }
            throw QuotaError.network("OpenRouter returned HTTP \(http.statusCode).")
        }
        return data
    }

    private static func resolveAPIKey(environment: [String: String]) -> String? {
        if let stored = MiscCredentialStore.readString(tool: .openRouter, kind: .apiKey),
           !stored.isEmpty {
            return stored
        }
        return nonEmpty(environment["OPENROUTER_API_KEY"])
    }

    private static func resolveBaseURL(
        environment: [String: String],
        settings: MiscProviderSettings
    ) -> URL {
        if let raw = nonEmpty(environment["OPENROUTER_API_URL"]),
           let url = URL(string: raw), url.scheme != nil {
            return url
        }
        if let host = settings.enterpriseHost {
            return host
        }
        return URL(string: "https://openrouter.ai/api/v1")!
    }
}

enum OpenRouterResponseParser {
    struct Snapshot {
        let buckets: [QuotaBucket]
        let planName: String?
        let creditsRemainingUSD: Double?
    }

    static func parseCredits(data: Data) throws -> OpenRouterCredits {
        let envelope = try JSONDecoder().decode(OpenRouterCreditsEnvelope.self, from: data)
        guard let credits = envelope.data else {
            throw QuotaError.parseFailure("OpenRouter credits response missing data.")
        }
        return credits
    }

    static func parseKeyStats(data: Data) throws -> OpenRouterKeyStats {
        let envelope = try JSONDecoder().decode(OpenRouterKeyStatsEnvelope.self, from: data)
        guard let stats = envelope.data else {
            throw QuotaError.parseFailure("OpenRouter key response missing data.")
        }
        return stats
    }

    static func snapshot(
        credits: OpenRouterCredits,
        keyStats: OpenRouterKeyStats?
    ) -> Snapshot {
        var buckets: [QuotaBucket] = []

        if let keyStats,
           let limit = keyStats.limit,
           limit > 0 {
            let usage = max(0, keyStats.usage ?? 0)
            buckets.append(QuotaBucket(
                id: "openrouter.key",
                title: "Key Limit",
                shortLabel: "Key",
                usedPercent: usage / limit * 100,
                groupTitle: "\(money(usage)) / \(money(limit))"
            ))
        }

        if credits.totalCredits > 0 {
            let used = max(0, credits.totalUsage)
            let remaining = max(0, credits.totalCredits - used)
            buckets.append(QuotaBucket(
                id: "openrouter.credits",
                title: "Credits",
                shortLabel: "Credits",
                usedPercent: used / credits.totalCredits * 100,
                groupTitle: "\(money(remaining)) left"
            ))
        }

        if buckets.isEmpty {
            buckets.append(QuotaBucket(
                id: "openrouter.credits",
                title: "Credits",
                shortLabel: "Credits",
                usedPercent: 0,
                groupTitle: "\(money(max(0, credits.totalCredits - credits.totalUsage))) left"
            ))
        }

        return Snapshot(
            buckets: buckets,
            planName: VisibleSecretRedactor.dropIfSensitive(keyStats?.label),
            creditsRemainingUSD: max(0, credits.totalCredits - credits.totalUsage)
        )
    }

    private static func money(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}

struct OpenRouterCredits: Decodable, Equatable {
    let totalCredits: Double
    let totalUsage: Double

    enum CodingKeys: String, CodingKey {
        case totalCredits = "total_credits"
        case totalUsage = "total_usage"
    }
}

private struct OpenRouterCreditsEnvelope: Decodable {
    let data: OpenRouterCredits?
}

struct OpenRouterKeyStats: Decodable, Equatable {
    let label: String?
    let limit: Double?
    let usage: Double?
    let rateLimit: OpenRouterRateLimit?

    enum CodingKeys: String, CodingKey {
        case label, limit, usage
        case rateLimit = "rate_limit"
    }
}

struct OpenRouterRateLimit: Decodable, Equatable {
    let requests: Int?
    let interval: String?
}

private struct OpenRouterKeyStatsEnvelope: Decodable {
    let data: OpenRouterKeyStats?
}

private func nonEmpty(_ raw: String?) -> String? {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}

private func trimmed(_ raw: String?) -> String? {
    nonEmpty(raw)
}
