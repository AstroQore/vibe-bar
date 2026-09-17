import Foundation

/// Mistral AI · Mistral Vibe quota adapter.
///
/// Mistral Vibe's monthly plan allowance is only published to the signed-in
/// Mistral console, so the credential is the console's own browser session:
/// the `ory_session_*` cookie plus `csrftoken`, imported from a browser the
/// user is signed in with (or pasted) through the shared cookie slots, exactly
/// as the Misc providers do. The request is the console's own
/// `billing.vibeUsage` tRPC query, which answers
/// `[{"result":{"data":{"json":{"usage_percentage": 12.5, "reset_at": "…"}}}}]`.
///
/// Only those two cookies are ever sent, and only to `console.mistral.ai`.
/// The plan name comes from the CLI's own `~/.vibe/whoami_cache.json`, read
/// locally.
public struct MistralVibeQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .mistralVibe

    static let sessionCookiePrefix = "ory_session_"
    static let csrfCookieName = "csrftoken"

    public static let cookieSpec = MiscCookieResolver.Spec(
        tool: .mistralVibe,
        domains: ["mistral.ai", "console.mistral.ai", "admin.mistral.ai", "auth.mistral.ai"],
        requiredNames: [csrfCookieName],
        credentialNames: [csrfCookieName],
        requiredNamePrefixes: [sessionCookiePrefix],
        credentialNamePrefixes: [sessionCookiePrefix]
    )

    /// The console's tRPC batch call with its one `null` input, spelled the
    /// way the console itself sends it.
    public static let usageURL = URL(string:
        "https://console.mistral.ai/api-ui/trpc/billing.vibeUsage?batch=1&input=%7B%220%22%3A%7B%22json%22%3Anull%2C%22meta%22%3A%7B%22values%22%3A%5B%22undefined%22%5D%2C%22v%22%3A1%7D%7D%7D"
    )!

    private let session: URLSession
    private let homeDirectory: String
    private let now: @Sendable () -> Date

    public init(
        session: URLSession = .shared,
        homeDirectory: String = RealHomeDirectory.path,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.homeDirectory = homeDirectory
        self.now = now
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        let resolutions = MiscCookieResolver.resolveAll(for: Self.cookieSpec, account: account)
        let queriedAt = now()
        let plan = MistralVibeWhoAmICache.planTitle(homeDirectory: homeDirectory)
        let results = await MiscCookieAutoImporter.shared.gatherSlotResults(
            spec: Self.cookieSpec,
            account: account,
            resolutions: resolutions
        ) { resolution in
            try await self.fetchOneSlot(resolution, account: account, plan: plan, queriedAt: queriedAt)
        }
        return MiscQuotaAggregator.aggregate(
            tool: .mistralVibe,
            account: account,
            results: results,
            queriedAt: queriedAt
        )
    }

    private func fetchOneSlot(
        _ resolution: MiscCookieResolver.Resolution,
        account: AccountIdentity,
        plan: String?,
        queriedAt: Date
    ) async throws -> AccountQuota {
        guard let request = Self.makeRequest(cookieHeader: resolution.header) else {
            throw QuotaError.noCredential
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            SafeLog.net("Mistral Vibe usage request failed: \(SafeLog.sanitize(error.localizedDescription))")
            throw mapURLError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.unknown("no HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw QuotaError.needsLogin
        case 429:
            throw QuotaError.rateLimited
        case 500...599:
            throw QuotaError.network("server \(http.statusCode)")
        default:
            throw QuotaError.unknown("HTTP \(http.statusCode)")
        }
        return AccountQuota(
            accountId: account.id,
            tool: .mistralVibe,
            buckets: [try MistralVibeResponseParser.parse(data: data)],
            plan: plan ?? account.plan,
            email: account.email,
            queriedAt: queriedAt
        )
    }

    /// Builds the console request from a stored cookie header, keeping only
    /// the session and CSRF cookies. `nil` when either is missing.
    static func makeRequest(cookieHeader: String) -> URLRequest? {
        let pairs = CookieHeaderNormalizer.pairs(from: cookieHeader)
        let forbidden = CharacterSet(charactersIn: ";,\r\n")
        guard let csrf = pairs.first(where: { $0.name == csrfCookieName })?.value
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !csrf.isEmpty, csrf.rangeOfCharacter(from: forbidden) == nil
        else { return nil }
        let sessions = pairs.filter { $0.name.hasPrefix(sessionCookiePrefix) && !$0.value.isEmpty }
        guard !sessions.isEmpty else { return nil }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(
            (["\(csrfCookieName)=\(csrf)"] + sessions.map { "\($0.name)=\($0.value)" }).joined(separator: "; "),
            forHTTPHeaderField: "Cookie"
        )
        request.setValue(csrf, forHTTPHeaderField: "X-CSRFToken")
        request.setValue("VibeBar", forHTTPHeaderField: "User-Agent")
        return request
    }
}

/// Decodes the console's `billing.vibeUsage` answer into the one Monthly
/// window it describes. `usage_percentage` is already a 0–100 percent.
public enum MistralVibeResponseParser {
    static let monthSeconds = 30 * 86_400

    public static func parse(data: Data) throws -> QuotaBucket {
        guard let batch = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
              let first = batch.first as? [String: Any],
              let result = first["result"] as? [String: Any],
              let payload = result["data"] as? [String: Any],
              let json = payload["json"] as? [String: Any]
        else { throw QuotaError.parseFailure("Mistral Vibe usage response is not a tRPC result") }
        guard let number = json["usage_percentage"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, (0...100).contains(number.doubleValue)
        else { throw QuotaError.parseFailure("Mistral Vibe usage percentage is missing") }
        let reset = (json["reset_at"] as? String).flatMap(ServiceStatusClient.flexibleDate(from:))
        return QuotaBucket(
            id: "monthly",
            title: "Monthly",
            shortLabel: "Monthly",
            usedPercent: number.doubleValue,
            resetAt: reset,
            rawWindowSeconds: monthSeconds
        )
    }
}

/// `~/.vibe/whoami_cache.json`, where the Vibe CLI caches the account's plan
/// for six hours, keyed by a hash of its API key:
/// `{"<hash>": {"stored_at_timestamp": …, "payload": {"plan_type": "chat",
/// "plan_name": "INDIVIDUAL", …}}}`. Only the plan fields are read.
public enum MistralVibeWhoAmICache {
    static let relativePath = ".vibe/whoami_cache.json"

    public static func exists(homeDirectory: String = RealHomeDirectory.path) -> Bool {
        FileManager.default.fileExists(atPath: url(homeDirectory: homeDirectory).path)
    }

    static func url(homeDirectory: String) -> URL {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".vibe", isDirectory: true)
            .appendingPathComponent("whoami_cache.json")
    }

    public static func planTitle(homeDirectory: String = RealHomeDirectory.path) -> String? {
        guard let data = try? Data(contentsOf: url(homeDirectory: homeDirectory)) else { return nil }
        return planTitle(cacheData: data)
    }

    static func planTitle(cacheData: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: cacheData)) as? [String: Any] else {
            return nil
        }
        let newest = root.values
            .compactMap { $0 as? [String: Any] }
            .max { timestamp($0) < timestamp($1) }
        guard let payload = newest?["payload"] as? [String: Any],
              let type = (payload["plan_type"] as? String)?.lowercased(),
              let name = (payload["plan_name"] as? String)?.trimmingCharacters(in: .whitespaces).uppercased()
        else { return nil }
        return planTitle(type: type, name: name)
    }

    /// The CLI's own naming (`vibe/app_server/_account.py`), without its
    /// `[Subscription]` / `[API]` decorations.
    static func planTitle(type: String, name: String) -> String? {
        switch type {
        case "chat":
            if name == "FREE" { return "Free" }
            return ["INDIVIDUAL", "EDU", "TEAM"].contains(name) ? "Pro" : nil
        case "api":
            return name.contains("FREE") ? "Free" : "Scale"
        case "mistral_code":
            return ["F": "Mistral Code Free", "E": "Mistral Code Enterprise"][name]
        default:
            return nil
        }
    }

    private static func timestamp(_ entry: [String: Any]) -> Double {
        (entry["stored_at_timestamp"] as? NSNumber)?.doubleValue ?? 0
    }
}
