import Foundation

/// Google Gemini partial-primary usage adapter.
///
/// `.auto` mode runs both sources **in parallel** and merges the
/// resulting buckets so the user sees CLI and Web data on one card.
/// `.oauthOnly` / `.webOnly` are explicit single-source escape hatches.
///
/// Sources:
/// - **OAuth CLI** — read `~/.gemini/oauth_creds.json`, reuse
///   `access_token`, call
///   `cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`. This is
///   the Gemini Code Assist protocol the official CLI uses.
///   `GeminiTokenRefreshHelper` shells out to `gemini` itself to refresh
///   expired tokens.
/// - **Web cookie** — use cookies imported from `gemini.google.com`
///   (Chrome Safe Storage via SweetCookieKit). Routed through
///   `GeminiWebQuotaFetcher`; the live endpoint and parser are
///   spike-pending. While the spike is incomplete this source returns
///   a parse failure and the dual-fetch merger drops it silently —
///   the OAuth half still shows up.
///
/// Output: one `QuotaBucket` per model with
/// `usedPercent = (1 - remainingFraction) * 100`. In dual-fetch mode
/// buckets from each source carry a `"CLI · "` / `"Web · "` groupTitle
/// prefix so the popover renders distinct sections.
public struct GeminiQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .gemini

    private let session: URLSession
    private let homeDirectory: String
    private let now: @Sendable () -> Date
    private let usageModeProvider: @Sendable () -> GeminiUsageMode

    public init(
        session: URLSession = .shared,
        homeDirectory: String = RealHomeDirectory.path,
        now: @escaping @Sendable () -> Date = { Date() },
        usageMode: (@Sendable () -> GeminiUsageMode)? = nil
    ) {
        self.session = session
        self.homeDirectory = homeDirectory
        self.now = now
        // Default to reading the persisted setting on every fetch. The
        // closure indirection lets tests inject a fixed mode without
        // touching disk, and keeps the public default expression free
        // of any internal references (Swift forbids those).
        self.usageModeProvider = usageMode ?? { Self.resolveUsageMode() }
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        switch usageModeProvider() {
        case .oauthOnly:
            return try await fetchWithOAuth(for: account)
        case .webOnly:
            return try await fetchWithWebCookies(for: account)
        case .auto:
            return try await fetchDual(for: account)
        }
    }

    /// Run OAuth and Web in parallel, merge their buckets. When both
    /// fail, surface the OAuth error (the Web side currently throws a
    /// spike-pending parseFailure, which is less informative). When
    /// either succeeds, the failed half is silently dropped — partial
    /// data beats a "needs login" placeholder on the dedicated card.
    private func fetchDual(for account: AccountIdentity) async throws -> AccountQuota {
        async let oauthResult = tryFetchOAuth(for: account)
        async let webResult = tryFetchWeb(for: account)
        let oauth = await oauthResult
        let web = await webResult

        if oauth.quota == nil && web.quota == nil {
            throw mapURLError(oauth.error ?? web.error ?? QuotaError.noCredential)
        }

        var buckets: [QuotaBucket] = []
        if let q = oauth.quota {
            buckets.append(contentsOf: q.buckets.map { Self.tagBucket($0, source: .oauthCLI) })
        }
        if let q = web.quota {
            buckets.append(contentsOf: q.buckets.map { Self.tagBucket($0, source: .webCookie) })
        }

        return AccountQuota(
            accountId: account.id,
            tool: .gemini,
            buckets: buckets,
            plan: oauth.quota?.plan ?? web.quota?.plan,
            email: oauth.quota?.email ?? web.quota?.email,
            queriedAt: now(),
            error: nil
        )
    }

    private func tryFetchOAuth(for account: AccountIdentity) async -> (quota: AccountQuota?, error: QuotaError?) {
        do {
            return (try await fetchWithOAuth(for: account), nil)
        } catch let error as QuotaError {
            return (nil, error)
        } catch {
            return (nil, .unknown(String(describing: error)))
        }
    }

    private func tryFetchWeb(for account: AccountIdentity) async -> (quota: AccountQuota?, error: QuotaError?) {
        do {
            return (try await fetchWithWebCookies(for: account), nil)
        } catch let error as QuotaError {
            return (nil, error)
        } catch {
            return (nil, .unknown(String(describing: error)))
        }
    }

    /// Prefix a bucket's `id` and `groupTitle` with `"CLI"` / `"Web"`
    /// so the popover card renders the two source's bucket lists as
    /// distinct sections (rather than letting them visually overlap
    /// when `groupTitle` collides — e.g. CLI's "Pro" and Web's "Pro").
    private static func tagBucket(_ bucket: QuotaBucket, source: CredentialSource) -> QuotaBucket {
        let prefix: String
        switch source {
        case .oauthCLI:  prefix = "CLI"
        case .webCookie: prefix = "Web"
        default:         return bucket
        }
        var copy = bucket
        copy.id = "\(prefix.lowercased()).\(bucket.id)"
        if let group = bucket.groupTitle, !group.isEmpty {
            copy.groupTitle = "\(prefix) · \(group)"
        } else {
            copy.groupTitle = prefix
        }
        return copy
    }

    private func fetchWithOAuth(for account: AccountIdentity) async throws -> AccountQuota {
        let credsURL = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".gemini/oauth_creds.json")

        guard FileManager.default.fileExists(atPath: credsURL.path) else {
            throw QuotaError.noCredential
        }

        var credentials: GeminiCredentials
        do {
            credentials = try GeminiCredentials.load(from: credsURL)
        } catch {
            throw QuotaError.parseFailure("Could not parse \(credsURL.path): \(error.localizedDescription)")
        }

        credentials = await GeminiTokenRefreshHelper.refreshedCredentialsIfNeeded(
            credentials,
            credentialsURL: credsURL,
            homeDirectory: homeDirectory,
            now: now()
        )

        guard let accessToken = credentials.accessToken, !accessToken.isEmpty else {
            throw QuotaError.noCredential
        }

        if let expiry = credentials.expiry, expiry < now() {
            // The keepalive in `GeminiTokenRefreshHelper` is best-effort
            // and cooldown-throttled. A stale token reaching this point
            // means the keepalive failed or is on cooldown; hint the
            // user to refresh in a terminal instead of silently failing.
            throw QuotaError.needsLogin
        }

        var request = URLRequest(url: GeminiEndpoint.retrieveUserQuota)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuotaError.network("Gemini network error: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Gemini: invalid response object")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw QuotaError.needsLogin
            }
            if http.statusCode == 429 {
                throw QuotaError.rateLimited
            }
            throw QuotaError.network("Gemini returned HTTP \(http.statusCode).")
        }

        let snapshot = try GeminiResponseParser.parse(
            data: data,
            email: GeminiCredentials.email(from: credentials.idToken),
            now: now()
        )
        return AccountQuota(
            accountId: account.id,
            tool: .gemini,
            buckets: snapshot.buckets,
            plan: snapshot.planName,
            email: snapshot.email,
            queriedAt: now(),
            error: nil
        )
    }

    private func fetchWithWebCookies(for account: AccountIdentity) async throws -> AccountQuota {
        let header: String
        do {
            header = try GeminiWebCookieStore.readCookieHeader()
        } catch {
            throw QuotaError.noCredential
        }
        let fetcher = GeminiWebQuotaFetcher(session: session, now: now)
        let snapshot = try await fetcher.fetch(cookieHeader: header)
        return AccountQuota(
            accountId: account.id,
            tool: .gemini,
            buckets: snapshot.buckets,
            plan: snapshot.planName,
            email: snapshot.email,
            queriedAt: now(),
            error: nil
        )
    }

    /// Reads the persisted `geminiUsageMode` setting from disk.
    /// Matches how the Codex / Claude adapters resolve their modes
    /// without threading `AppSettings` through every call site.
    /// Internal (not `private`) so the public init's default argument
    /// can reference it.
    static func resolveUsageMode() -> GeminiUsageMode {
        let appSettings = (try? VibeBarLocalStore.readJSON(
            AppSettings.self,
            from: VibeBarLocalStore.settingsURL
        )) ?? .default
        return appSettings.geminiUsageMode
    }
}

// MARK: - Endpoints

enum GeminiEndpoint {
    static let retrieveUserQuota = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
}

// MARK: - Credentials file

public struct GeminiCredentials {
    public let accessToken: String?
    public let idToken: String?
    public let refreshToken: String?
    public let expiry: Date?

    public init(
        accessToken: String?,
        idToken: String?,
        refreshToken: String?,
        expiry: Date?
    ) {
        self.accessToken = accessToken
        self.idToken = idToken
        self.refreshToken = refreshToken
        self.expiry = expiry
    }

    public static func load(from url: URL) throws -> GeminiCredentials {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.parseFailure("oauth_creds.json was not a JSON object")
        }
        var expiry: Date?
        if let ms = json["expiry_date"] as? Double {
            expiry = Date(timeIntervalSince1970: ms / 1000)
        } else if let ms = json["expiry_date"] as? Int {
            expiry = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        }
        return GeminiCredentials(
            accessToken: json["access_token"] as? String,
            idToken: json["id_token"] as? String,
            refreshToken: json["refresh_token"] as? String,
            expiry: expiry
        )
    }

    /// Decode the Google ID token's payload claims and return the
    /// `email` field. JWT validation is not performed — the token
    /// came from local disk so we treat it as already authoritative.
    public static func email(from idToken: String?) -> String? {
        guard let idToken else { return nil }
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = payload.count % 4
        if pad > 0 { payload += String(repeating: "=", count: 4 - pad) }
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json["email"] as? String
    }
}

// MARK: - Response parsing

enum GeminiResponseParser {
    struct Snapshot {
        var buckets: [QuotaBucket]
        var planName: String?
        var email: String?
    }

    static func parse(data: Data, email: String?, now: Date) throws -> Snapshot {
        let response: GeminiAPIResponse
        do {
            response = try JSONDecoder().decode(GeminiAPIResponse.self, from: data)
        } catch {
            throw QuotaError.parseFailure("Gemini quota response not parseable: \(error.localizedDescription)")
        }

        guard let raw = response.buckets, !raw.isEmpty else {
            throw QuotaError.parseFailure("Gemini returned no quota buckets.")
        }

        // Group by model. For each model, keep the row with the
        // lowest remainingFraction — that's typically the input-token
        // bucket and is the user's actual bottleneck.
        var byModel: [String: (fraction: Double, resetString: String?)] = [:]
        for bucket in raw {
            guard let modelId = bucket.modelId,
                  let fraction = bucket.remainingFraction else { continue }
            if let existing = byModel[modelId], existing.fraction <= fraction { continue }
            byModel[modelId] = (fraction, bucket.resetTime)
        }

        // Gemini's reset times can come in either ISO8601 with or
        // without fractional seconds. Try both formatters.
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainISO = ISO8601DateFormatter()
        plainISO.formatOptions = [.withInternetDateTime]

        let buckets = byModel
            .sorted { $0.key < $1.key }
            .map { (modelId: String, info: (fraction: Double, resetString: String?)) in
                let resetAt = info.resetString.flatMap { raw in
                    withFractional.date(from: raw) ?? plainISO.date(from: raw)
                }
                return QuotaBucket(
                    id: "gemini.\(modelId)",
                    title: prettyModelName(modelId),
                    shortLabel: shortLabel(for: modelId),
                    usedPercent: max(0, min(100, (1 - info.fraction) * 100)),
                    resetAt: resetAt,
                    rawWindowSeconds: nil,
                    groupTitle: prettyModelName(modelId)
                )
            }

        return Snapshot(buckets: buckets, planName: nil, email: email)
    }

    static func prettyModelName(_ id: String) -> String {
        let lower = id.lowercased()
        let version = extractGeminiVersion(from: lower)
        let suffix = version.isEmpty ? "" : " \(version)"
        if lower.contains("flash-lite") { return "Flash Lite\(suffix)" }
        if lower.contains("flash")      { return "Flash\(suffix)" }
        if lower.contains("pro")        { return "Pro\(suffix)" }
        if lower.contains("ultra")      { return "Ultra\(suffix)" }
        return id
    }

    static func shortLabel(for id: String) -> String {
        let lower = id.lowercased()
        let version = extractGeminiVersion(from: lower)
        let suffix = version.isEmpty ? "" : " \(version)"
        if lower.contains("flash-lite") { return "Lite\(suffix)" }
        if lower.contains("flash")      { return "Flash\(suffix)" }
        if lower.contains("pro")        { return "Pro\(suffix)" }
        if lower.contains("ultra")      { return "Ultra\(suffix)" }
        return id
    }

    /// Best-effort version extractor for Gemini model identifiers.
    /// Handles `"gemini-2.5-flash-lite"`, `"gemini-3-pro"`,
    /// `"models/gemini-3.0-pro"` → `"2.5"` / `"3"` / `"3.0"`. Returns
    /// `""` when no version segment is recognisable so callers can
    /// fall back to the plain family name.
    static func extractGeminiVersion(from id: String) -> String {
        let pattern = #"gemini[-_/]?(\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)),
              let range = Range(match.range(at: 1), in: id) else {
            return ""
        }
        return String(id[range])
    }
}

// MARK: - Wire types

private struct GeminiAPIResponse: Decodable {
    let buckets: [GeminiAPIBucket]?
}

private struct GeminiAPIBucket: Decodable {
    let remainingFraction: Double?
    let resetTime: String?
    let modelId: String?
    let tokenType: String?
}

public enum GeminiTokenRefreshHelper {
    public static let refreshLeadTime: TimeInterval = 10 * 60
    private static let attemptCooldown: TimeInterval = 5 * 60
    private static let lock = NSLock()
    private nonisolated(unsafe) static var lastAttemptAt: Date?

    public static func refreshedCredentialsIfNeeded(
        _ credentials: GeminiCredentials,
        credentialsURL: URL,
        homeDirectory: String = RealHomeDirectory.path,
        now: Date = Date()
    ) async -> GeminiCredentials {
        guard shouldRefresh(expiry: credentials.expiry, now: now, leadTime: refreshLeadTime) else {
            return credentials
        }
        guard claimAttempt(now: now) else {
            return credentials
        }
        guard let binary = resolveGeminiBinary(homeDirectory: homeDirectory) else {
            SafeLog.warn("Gemini token refresh skipped: gemini CLI not found")
            return credentials
        }

        do {
            let result = try await ProcessRunner.run(
                binary: binary,
                arguments: [
                    "--prompt",
                    "Vibe Bar token refresh keepalive. Do not use tools. Reply OK.",
                    "--output-format",
                    "json",
                    "--skip-trust"
                ],
                timeout: 90,
                label: "gemini token refresh",
                environment: refreshEnvironment(binary: binary, homeDirectory: homeDirectory)
            )
            guard result.terminationStatus == 0 else {
                SafeLog.warn("Gemini token refresh exited \(result.terminationStatus)")
                return credentials
            }
            return (try? GeminiCredentials.load(from: credentialsURL)) ?? credentials
        } catch {
            SafeLog.warn("Gemini token refresh failed: \(SafeLog.sanitize(error.localizedDescription))")
            return credentials
        }
    }

    public static func shouldRefresh(expiry: Date?, now: Date, leadTime: TimeInterval) -> Bool {
        guard let expiry else { return false }
        return expiry <= now.addingTimeInterval(leadTime)
    }

    public static func resolveGeminiBinary(
        homeDirectory: String = RealHomeDirectory.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        for candidate in geminiBinaryCandidates(homeDirectory: homeDirectory, environment: environment) {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func claimAttempt(now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < attemptCooldown {
            return false
        }
        lastAttemptAt = now
        return true
    }

    private static func refreshEnvironment(binary: String, homeDirectory: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = homeDirectory
        let binaryDir = URL(fileURLWithPath: binary).deletingLastPathComponent().path
        let existing = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        let path = unique([
            binaryDir,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ] + existing)
        env["PATH"] = path.joined(separator: ":")
        return env
    }

    private static func geminiBinaryCandidates(
        homeDirectory: String,
        environment: [String: String]
    ) -> [String] {
        var candidates: [String] = []
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/gemini" })
        }
        candidates.append(contentsOf: [
            "\(homeDirectory)/.npm-global/bin/gemini",
            "\(homeDirectory)/.bun/bin/gemini",
            "/opt/homebrew/bin/gemini",
            "/usr/local/bin/gemini"
        ])

        let nvmRoot = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(
            at: nvmRoot,
            includingPropertiesForKeys: nil
        ) {
            let sorted = versions.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending
            }
            candidates.append(contentsOf: sorted.map {
                $0.appendingPathComponent("bin/gemini").path
            })
        }

        return unique(candidates)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for value in values where seen.insert(value).inserted {
            out.append(value)
        }
        return out
    }
}
