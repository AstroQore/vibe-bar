import Foundation

/// Owns the URLSession + ephemeral cookie store used to talk to
/// `console.volcengine.com`. Encapsulates the two-step
/// `encCerts` → `mixtureLogin` flow and exposes a single
/// `authedSession()` entry point that blocks until valid session
/// cookies + a `csrfToken` are present.
public actor VolcengineSessionManager {
    public static let shared = VolcengineSessionManager()

    private let urlSession: URLSession
    private let cookieStorage: HTTPCookieStorage
    private var loginInFlight: Task<Void, Error>?

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 15
        self.cookieStorage = config.httpCookieStorage ?? HTTPCookieStorage.shared
        config.httpCookieStorage = self.cookieStorage
        self.urlSession = URLSession(configuration: config)
    }

    /// Returns a `URLSession` whose cookie store carries a fresh
    /// session + `csrfToken`. Lazily runs the login flow on first call,
    /// or any time the cookies have been wiped.
    public func authedSession() async throws -> URLSession {
        if hasUsableSession() {
            return urlSession
        }
        try await ensureLoggedIn()
        return urlSession
    }

    /// Drop every cookie scoped to `*.volcengine.com`. The adapter
    /// calls this after a `needsLogin` so the next refresh re-runs the
    /// password login instead of replaying a stale session.
    public func wipeSession() {
        for cookie in cookieStorage.cookies ?? [] {
            cookieStorage.deleteCookie(cookie)
        }
    }

    /// Read the current `csrfToken` cookie value. The adapter mirrors
    /// it into the `X-Csrf-Token` header on every authed RPC.
    public func currentCsrfToken() -> String? {
        cookieValue(named: "csrfToken")
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
        // Wipe any stale cookies from a prior aborted login so we don't
        // accidentally replay a dead csrfToken.
        wipeSession()
        let client = VolcengineLoginClient(session: urlSession)
        try await client.signIn(
            mainAccountId: credentials.mainAccountId,
            subUsername: credentials.subUsername,
            password: credentials.subPassword
        )
        guard hasUsableSession() else {
            throw QuotaError.needsLogin
        }
    }

    // MARK: - Internals

    private func hasUsableSession() -> Bool {
        guard let csrf = cookieValue(named: "csrfToken"), !csrf.isEmpty else { return false }
        return true
    }

    private func cookieValue(named name: String) -> String? {
        cookieStorage.cookies?
            .first(where: { $0.name == name })?
            .value
    }

    private func readStoredCredentials() -> VolcengineSubAccountCredentials? {
        let mainId = MiscCredentialStore.readString(tool: .volcengine, kind: .mainAccountId)
        let user = MiscCredentialStore.readString(tool: .volcengine, kind: .subUsername)
        let pass = MiscCredentialStore.readString(tool: .volcengine, kind: .subPassword)
        guard let mainId, let user, let pass,
              !mainId.isEmpty, !user.isEmpty, !pass.isEmpty else {
            return nil
        }
        return VolcengineSubAccountCredentials(
            mainAccountId: mainId,
            subUsername: user,
            subPassword: pass
        )
    }
}

private struct VolcengineSubAccountCredentials {
    let mainAccountId: String
    let subUsername: String
    let subPassword: String
}
