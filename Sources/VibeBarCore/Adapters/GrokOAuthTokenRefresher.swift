import Foundation

/// Renews the `~/.grok/auth.json` OIDC bearer through the refresh-token
/// grant, the way the Grok CLI does it silently when its six-hour bearer
/// runs out.
///
/// The CLI does not promise to write the renewed pair back to disk, so a
/// Vibe Bar that only ever read the file would see an expired bearer and
/// report "needs re-login" while the CLI kept working. This refresher
/// closes that gap and writes the result back (see
/// `GrokCredentialsStore.writeRefreshed`), because the file is the one
/// source of truth both clients share and a rotated refresh token that
/// only one of them holds strands the other.
///
/// Request: `POST https://auth.x.ai/oauth2/token`,
/// `application/x-www-form-urlencoded`, `grant_type=refresh_token`,
/// `refresh_token`, `client_id` (the entry's `oidc_client_id`; a public
/// client, so no secret). `scope` and the CLI's `x-grok-client-*` headers
/// are optional and off by default — see `RequestOptions`.
///
/// Refreshes are single-flight per refresh token: a scheduled refresh and
/// a "check connection" that race each other share one exchange, and a
/// caller still holding the pre-rotation token gets the result of the
/// exchange that already spent it instead of a second, doomed one.
public actor GrokOAuthTokenRefresher {
    public static let shared = GrokOAuthTokenRefresher()

    public static let tokenEndpoint = URL(string: "https://auth.x.ai/oauth2/token")!

    /// Extras the Grok CLI sends with its refresh. Whether xAI requires
    /// any of them is not established; the default sends none.
    public struct RequestOptions: Sendable, Equatable {
        public var scope: String?
        public var clientVersion: String?
        public var clientSurface: String?

        public init(scope: String? = nil, clientVersion: String? = nil, clientSurface: String? = nil) {
            self.scope = scope
            self.clientVersion = clientVersion
            self.clientSurface = clientSurface
        }

        /// Plain OAuth 2.0 public-client refresh.
        public static let standard = RequestOptions()
        /// What the Grok CLI 1.0.41 appears to send.
        public static let grokCLI = RequestOptions(
            scope: "grok-build",
            clientVersion: "1.0.41",
            clientSurface: "grok-build"
        )
    }

    public enum RefreshError: Error, Equatable, Sendable {
        /// The entry has no refresh token / client id, or an issuer
        /// other than xAI's.
        case notRefreshable
        /// The IdP refused the refresh token (401 / 403 / `invalid_grant`).
        /// Only a new `grok login` recovers from this.
        case rejected
        /// The exchange did not complete (transport failure, 429, 5xx).
        case network(String)
        /// A response that could not be used (no `access_token`, an
        /// unexpected status or OAuth error code).
        case invalidResponse(String)
    }

    private let options: RequestOptions
    private var inFlight: [String: Task<GrokCredentials, Error>] = [:]
    /// The last completed exchange, keyed by the refresh token it spent.
    private var lastExchange: (spentRefreshToken: String, result: GrokCredentials)?

    public init(options: RequestOptions = .standard) {
        self.options = options
    }

    /// The default configuration (so the system proxy still applies) with a
    /// hard ceiling on the exchange's total time, not only on silence: the
    /// refresh runs in a shared, unstructured task that the quota refresh's
    /// own timeout cannot cancel, so a trickling token endpoint must end
    /// here rather than keep the account marked timed out.
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    /// Exchanges `credentials.refreshToken` for a new bearer and, when
    /// `persist` is true, writes it back to `auth.json` under
    /// `homeDirectory`. A write failure is logged and does not fail the
    /// refresh.
    public func refresh(
        _ credentials: GrokCredentials,
        session: URLSession = GrokOAuthTokenRefresher.defaultSession,
        homeDirectory: String = RealHomeDirectory.path,
        persist: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() },
        onDiskRefreshToken: String? = nil
    ) async throws -> GrokCredentials {
        guard credentials.canRefresh,
              let refreshToken = credentials.refreshToken,
              let clientID = credentials.oidcClientID
        else { throw RefreshError.notRefreshable }

        if let lastExchange,
           lastExchange.spentRefreshToken == refreshToken,
           lastExchange.result.accessToken != credentials.accessToken {
            if !lastExchange.result.expiresSoon(at: now()) {
                return lastExchange.result
            }
            // The caller still holds the spent token — the write-back must
            // have failed — but the rotated pair from that exchange is the
            // one xAI now honours. Renew from it, and try the write-back
            // again against the token the file still holds.
            if let rotated = lastExchange.result.refreshToken, rotated != refreshToken {
                return try await refresh(
                    lastExchange.result,
                    session: session,
                    homeDirectory: homeDirectory,
                    persist: persist,
                    now: now,
                    onDiskRefreshToken: onDiskRefreshToken ?? refreshToken
                )
            }
        }
        if let running = inFlight[refreshToken] {
            return try await running.value
        }

        let options = self.options
        let task = Task<GrokCredentials, Error> {
            let refreshed = try await Self.exchange(
                credentials: credentials,
                refreshToken: refreshToken,
                clientID: clientID,
                options: options,
                session: session,
                now: now()
            )
            if persist {
                do {
                    let outcome = try GrokCredentialsStore.writeRefreshed(
                        refreshed,
                        previousRefreshToken: onDiskRefreshToken ?? refreshToken,
                        now: now(),
                        homeDirectory: homeDirectory
                    )
                    if outcome == .superseded {
                        SafeLog.info("Grok auth.json changed during refresh; left the newer login in place.")
                    }
                } catch {
                    SafeLog.warn("Grok auth.json write-back failed: \(SafeLog.sanitize(String(describing: error)))")
                }
            }
            return refreshed
        }
        inFlight[refreshToken] = task
        defer { inFlight[refreshToken] = nil }
        let result = try await task.value
        lastExchange = (refreshToken, result)
        return result
    }

    static func exchange(
        credentials: GrokCredentials,
        refreshToken: String,
        clientID: String,
        options: RequestOptions,
        session: URLSession,
        now: Date
    ) async throws -> GrokCredentials {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("VibeBar", forHTTPHeaderField: "User-Agent")
        if let version = options.clientVersion {
            request.setValue(version, forHTTPHeaderField: "x-grok-client-version")
        }
        if let surface = options.clientSurface {
            request.setValue(surface, forHTTPHeaderField: "x-grok-client-surface")
        }
        var fields: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID),
        ]
        if let scope = options.scope {
            fields.append(("scope", scope))
        }
        request.httpBody = Data(formEncode(fields).utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RefreshError.network(mapURLError(error).userFacingMessage)
        }
        guard let http = response as? HTTPURLResponse else {
            throw RefreshError.invalidResponse("no HTTP response")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw RefreshError.rejected
        case 400:
            let code = (json?["error"] as? String) ?? "unknown"
            if code == "invalid_grant" { throw RefreshError.rejected }
            throw RefreshError.invalidResponse("HTTP 400 \(SafeLog.sanitize(code))")
        case 429:
            throw RefreshError.network("rate limited")
        case let code where code >= 500:
            throw RefreshError.network("server \(code)")
        case let code:
            throw RefreshError.invalidResponse("HTTP \(code)")
        }

        guard let json,
              let accessToken = (json["access_token"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty
        else { throw RefreshError.invalidResponse("no access_token") }

        let rotated = (json["refresh_token"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expiresAt = expiry(expiresIn: json["expires_in"], accessToken: accessToken, now: now)
        return credentials.refreshed(
            accessToken: accessToken,
            refreshToken: (rotated?.isEmpty == false) ? rotated : nil,
            expiresAt: expiresAt
        )
    }

    /// `expires_in` when the response carries it, else the bearer's own
    /// `exp` claim, else a conservative hour.
    static func expiry(expiresIn raw: Any?, accessToken: String, now: Date) -> Date {
        if let seconds = (raw as? NSNumber)?.doubleValue ?? (raw as? String).flatMap(Double.init),
           seconds > 0 {
            return now.addingTimeInterval(seconds)
        }
        if let exp = jwtExpiry(accessToken) { return exp }
        return now.addingTimeInterval(3_600)
    }

    private static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let exp = (object["exp"] as? NSNumber)?.doubleValue
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private static func formEncode(_ fields: [(String, String)]) -> String {
        // RFC 3986 unreserved set, ASCII only.
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
}
