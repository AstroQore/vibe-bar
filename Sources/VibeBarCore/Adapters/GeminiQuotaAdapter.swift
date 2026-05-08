import Foundation

/// Google Gemini (Code Assist) usage adapter.
///
/// Auth flow vs. codexbar's reference:
///
/// - **Read** the user's Gemini CLI OAuth file at
///   `~/.gemini/oauth_creds.json` and reuse `access_token`. We
///   surface a friendly "re-run `gemini`" error when the token is
///   expired rather than re-implementing codexbar's
///   binary-discovery + npm-package-walk + Google OAuth refresh
///   pipeline. That's a meaningful simplification — codexbar's
///   refresh path is ~600 lines because Google distributes the
///   OAuth client credentials inside the Gemini CLI npm package
///   itself; reading them requires resolving the binary, walking
///   `node_modules`, and parsing source files. Vibe Bar's first
///   port pushes that complexity to a follow-up.
/// - **Skip** `loadCodeAssist` and the project-ID discovery hop.
///   `retrieveUserQuota` accepts an empty body and returns the
///   per-model buckets we render. Tier detection (Free / Workspace
///   / Paid / Legacy) is dropped for now — same follow-up.
///
/// Output: one `QuotaBucket` per model (Pro / Flash / Flash-Lite).
/// `usedPercent = (1 - remainingFraction) * 100`. The bucket
/// `groupTitle` carries the model id so the misc card can group
/// related models if they ever land.
public struct GeminiQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .gemini

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
        guard MiscProviderSettings.current(for: .gemini).allowsAPIOrOAuthAccess else {
            throw QuotaError.noCredential
        }

        let credsURL = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".gemini/oauth_creds.json")

        guard FileManager.default.fileExists(atPath: credsURL.path) else {
            throw QuotaError.noCredential
        }

        let credentials: GeminiCredentials
        do {
            credentials = try GeminiCredentials.load(from: credsURL)
        } catch {
            throw QuotaError.parseFailure("Could not parse \(credsURL.path): \(error.localizedDescription)")
        }

        guard let accessToken = credentials.accessToken, !accessToken.isEmpty else {
            throw QuotaError.noCredential
        }

        if let expiry = credentials.expiry, expiry < now() {
            // Vibe Bar's first port doesn't refresh tokens. The user
            // can run any `gemini` command to refresh in-place; we
            // surface a clear hint instead of silently failing.
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

    private static func prettyModelName(_ id: String) -> String {
        let lower = id.lowercased()
        if lower.contains("flash-lite") { return "Flash Lite" }
        if lower.contains("flash")      { return "Flash" }
        if lower.contains("pro")        { return "Pro" }
        if lower.contains("ultra")      { return "Ultra" }
        return id
    }

    private static func shortLabel(for id: String) -> String {
        let lower = id.lowercased()
        if lower.contains("flash-lite") { return "Lite" }
        if lower.contains("flash")      { return "Flash" }
        if lower.contains("pro")        { return "Pro" }
        if lower.contains("ultra")      { return "Ultra" }
        return id
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
