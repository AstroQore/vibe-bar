import Foundation

/// Owns the per-app `URLSession` + `HTTPCookieStorage` used to talk
/// to Tencent's console BFF. Encapsulates the sub-account password
/// login flow and exposes a single `authedSession()` entry point that
/// blocks until valid `skey` / `uin` cookies are present.
///
/// All mutation runs through the actor's mailbox so concurrent quota
/// refreshes can't double-login.
public actor TencentSessionManager {
    public static let shared = TencentSessionManager()

    private let urlSession: URLSession
    private let cookieStorage: HTTPCookieStorage
    private var loginInFlight: Task<Void, Error>?

    public init() {
        // `.ephemeral` gives us an in-memory cookie store that isn't
        // shared with the rest of the app or written to disk — exactly
        // what we want for short-lived `skey` cookies. The store stays
        // usable for reads after the session is created (see
        // `currentCookies`).
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 15
        self.cookieStorage = config.httpCookieStorage ?? HTTPCookieStorage.shared
        config.httpCookieStorage = self.cookieStorage
        self.urlSession = URLSession(configuration: config)
    }

    /// Returns a `URLSession` whose cookie store carries a fresh `skey`
    /// + `uin`. Runs the sub-account password login flow lazily on the
    /// first call (and again whenever the session has been wiped).
    public func authedSession() async throws -> URLSession {
        if hasUsableSession() {
            return urlSession
        }
        try await ensureLoggedIn()
        return urlSession
    }

    /// Discard every cookie scoped to `*.cloud.tencent.com`. Call this
    /// from the adapter on `needsLogin` so the next refresh re-runs the
    /// password login instead of replaying a stale `skey`.
    public func wipeSession() {
        for cookie in cookieStorage.cookies ?? [] {
            cookieStorage.deleteCookie(cookie)
        }
    }

    /// Read the current `skey` cookie (if any). The adapter feeds this
    /// into `TencentCsrfCode` to derive the URL `csrfCode` parameter.
    public func currentSkey() -> String? {
        cookieValue(named: "skey")
    }

    /// Read the current sub-account `uin` cookie. The Tencent BFF wants
    /// the SUB-account UID on the URL, NOT the `ownerUin`.
    public func currentSubUin() -> String? {
        cookieValue(named: "uin")
    }

    // MARK: - Login flow

    private func ensureLoggedIn() async throws {
        if let inFlight = loginInFlight {
            try await inFlight.value
            return
        }
        let task = Task { try await performLogin() }
        loginInFlight = task
        defer { loginInFlight = nil }
        try await task.value
    }

    private func performLogin() async throws {
        guard let credentials = readStoredCredentials() else {
            throw QuotaError.noCredential
        }

        // Fresh login — toss any stale cookies from a previous attempt
        // so we don't accidentally replay a dead `skey`.
        wipeSession()

        let endpoint = URL(string:
            "https://cloud.tencent.com/auth-api/login/submit?t=\(Self.epochMillis())"
        )!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("https://cloud.tencent.com", forHTTPHeaderField: "Origin")
        request.setValue("https://cloud.tencent.com/login", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let body: [String: String] = [
            "loginType": "subaccount",
            "ownerUin":  credentials.mainAccountId,
            "username":  credentials.subUsername,
            "password":  credentials.subPassword
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw QuotaError.network("Tencent login network error: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Tencent login: invalid response object")
        }
        let bodySnippet = String(data: data.prefix(300), encoding: .utf8) ?? "<non-utf8>"
        SafeLog.warn("diag TencentSessionManager.performLogin → status=\(http.statusCode) bodyLen=\(data.count) bodySnippet=\(bodySnippet)")
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw QuotaError.needsLogin
            }
            throw QuotaError.network("Tencent login returned HTTP \(http.statusCode).")
        }

        // Tencent's login endpoint returns 200 even for hard failures
        // (wrong password, MFA required, blocked sub-user, etc.) —
        // either as `{"code": <non-zero>, "msg": "..."}` or a richer
        // envelope. The reliable success signal is "did the response
        // set a usable `skey` cookie?" because `URLSession` populates
        // `cookieStorage` during `data` before this `await` returns.
        if hasUsableSession() {
            return
        }
        try Self.surfaceLoginError(data: data)
        throw QuotaError.needsLogin
    }

    /// Best-effort decode of the login envelope. If we can extract a
    /// machine-readable error code or human message, throw a network
    /// error carrying it so the misc card surfaces something
    /// actionable instead of the generic "Needs re-login". Session-
    /// expiry codes still flip to `needsLogin` so the retry-once
    /// path can recover.
    nonisolated private static func surfaceLoginError(data: Data) throws {
        guard !data.isEmpty,
              let envelope = try? JSONDecoder().decode(TencentLoginEnvelope.self, from: data) else {
            return
        }
        let codeRaw = envelope.codeString.trimmingCharacters(in: .whitespacesAndNewlines)
        let codeLower = codeRaw.lowercased()
        let message = (envelope.msg ?? envelope.message)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !codeRaw.isEmpty || !message.isEmpty else { return }

        // Recoverable session-expiry: retry-once path will pick this up.
        if codeLower.contains("authfailure") ||
            codeLower.contains("session") ||
            codeRaw == "401" || codeRaw == "403" {
            throw QuotaError.needsLogin
        }
        // Everything else (wrong password, account locked, MFA required,
        // risk control, …) — surface the server's own message verbatim
        // so the misc card tells the user WHY login failed rather than
        // just "Needs re-login".
        let detail = message.isEmpty ? "code \(codeRaw)" : message
        throw QuotaError.network("Tencent login: \(detail)")
    }

    // MARK: - Internals

    private func hasUsableSession() -> Bool {
        guard let skey = cookieValue(named: "skey"), !skey.isEmpty else { return false }
        guard let uin = cookieValue(named: "uin"), !uin.isEmpty else { return false }
        return true
    }

    private func cookieValue(named name: String) -> String? {
        cookieStorage.cookies?
            .first(where: { $0.name == name })?
            .value
    }

    private func readStoredCredentials() -> TencentSubAccountCredentials? {
        let mainId = MiscCredentialStore.readString(tool: .tencentHunyuan, kind: .mainAccountId)
        let user = MiscCredentialStore.readString(tool: .tencentHunyuan, kind: .subUsername)
        let pass = MiscCredentialStore.readString(tool: .tencentHunyuan, kind: .subPassword)
        guard let mainId, let user, let pass,
              !mainId.isEmpty, !user.isEmpty, !pass.isEmpty else {
            return nil
        }
        return TencentSubAccountCredentials(
            mainAccountId: mainId,
            subUsername: user,
            subPassword: pass
        )
    }

    private static func epochMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

/// Loose decoder for Tencent's `auth-api/login/submit` JSON envelope.
/// `code` can arrive as either an integer (`{"code":1234,...}`) or a
/// stringly-typed identifier (`{"code":"FailedOperation.LoginFailed"}`)
/// depending on which branch of the login flow rejected the request,
/// so we normalise both into `codeString` and let the caller match on
/// substrings.
private struct TencentLoginEnvelope: Decodable {
    let codeString: String
    let msg: String?
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case code, msg, message
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = (try? c.decodeIfPresent(String.self, forKey: .code)) ?? nil {
            codeString = s
        } else if let n = (try? c.decodeIfPresent(Int.self, forKey: .code)) ?? nil {
            codeString = String(n)
        } else {
            codeString = ""
        }
        msg = try c.decodeIfPresent(String.self, forKey: .msg)
        message = try c.decodeIfPresent(String.self, forKey: .message)
    }
}

private struct TencentSubAccountCredentials {
    let mainAccountId: String
    let subUsername: String
    let subPassword: String
}
