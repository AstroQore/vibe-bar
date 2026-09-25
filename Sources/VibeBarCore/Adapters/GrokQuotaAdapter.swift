import Foundation

/// xAI Grok partial-primary usage adapter.
///
/// Hits `https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig`
/// with one of two credentials:
///
/// 1. **`~/.grok/auth.json` bearer** (preferred). Written by
///    `grok login`. Carries the SuperGrok email and plan label so the
///    card chrome is rich. The OIDC bearer lives six hours; an expired
///    one is renewed with the entry's refresh token through
///    `GrokOAuthTokenRefresher` and written back to the file.
/// 2. **grok.com browser cookies** (fallback). Imported via
///    `GrokBrowserCookieImporter` from Chrome / Safari / etc., stored
///    minimised in Keychain by `GrokWebCookieStore`. Used when the
///    user signed in to grok.com on the web but never ran
///    `grok login` — the case that Codex Bar already handles.
///
/// The response is a tiny protobuf payload carrying the weekly
/// used-percent and the next reset timestamp; both fields surface as
/// a single `QuotaBucket(id: "weekly", ...)` on the card.
public struct GrokQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .grok

    private let session: URLSession
    private let homeDirectory: String
    private let now: @Sendable () -> Date
    private let cookieHeader: @Sendable () -> String?
    private let refresher: GrokOAuthTokenRefresher

    /// A bearer this close to `expires_at` is refreshed before use.
    static let refreshLeeway: TimeInterval = 60

    public init(
        session: URLSession = .shared,
        homeDirectory: String = RealHomeDirectory.path,
        now: @escaping @Sendable () -> Date = { Date() },
        cookieHeader: @escaping @Sendable () -> String? = { try? GrokWebCookieStore.readCookieHeader() },
        refresher: GrokOAuthTokenRefresher = .shared
    ) {
        self.session = session
        self.homeDirectory = homeDirectory
        self.now = now
        self.cookieHeader = cookieHeader
        self.refresher = refresher
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        let loaded = try? GrokCredentialsStore.load(homeDirectory: homeDirectory)
        var credentials: GrokCredentials?
        var refreshedThisFetch = false
        var refreshFailure: QuotaError?

        if let loaded {
            if loaded.canRefresh, loaded.expiresSoon(at: now(), leeway: Self.refreshLeeway) {
                // The CLI renews its six-hour bearer silently and may not
                // write it back, so an expired entry with a refresh token
                // is renewed here instead of being treated as a logout.
                do {
                    credentials = try await refresh(loaded)
                    refreshedThisFetch = true
                } catch {
                    refreshFailure = Self.quotaError(for: error)
                }
            } else if !loaded.isExpired(at: now()) {
                credentials = loaded
            }
        }

        if let credentials {
            do {
                return try await fetchWithBearer(credentials: credentials, account: account)
            } catch let error as QuotaError where error == .needsLogin || error == .noCredential {
                // A bearer refused before its expiry (revoked, or the
                // clock is off) gets one refresh and one retry — unless
                // it was minted by this very fetch.
                var lastError = error
                if credentials.canRefresh, !refreshedThisFetch {
                    do {
                        let renewed = try await refresh(credentials)
                        return try await fetchWithBearer(credentials: renewed, account: account)
                    } catch let retryError as QuotaError {
                        lastError = retryError
                    } catch {
                        lastError = Self.quotaError(for: error)
                    }
                }
                // A web session, when there is one, reads the same
                // billing — the fallback AccountStore promises for this
                // account — so it is tried before the refusal is reported.
                guard let header = cookieHeader() else { throw lastError }
                return try await fetchWithCookies(header: header, account: account)
            }
        }

        if let header = cookieHeader() {
            do {
                return try await fetchWithCookies(header: header, account: account)
            } catch {
                // A refresh that could not reach xAI says more about the
                // outage than the cookie's own failure does.
                if let refreshFailure, case .network = refreshFailure { throw refreshFailure }
                throw error
            }
        }

        // Neither source available. A refused refresh means the CLI login
        // itself is gone; otherwise prefer the auth.json error message
        // because it's actionable (`grok login` is the canonical
        // documented path) and tells the user exactly what to do.
        throw refreshFailure ?? QuotaError.noCredential
    }

    private func refresh(_ credentials: GrokCredentials) async throws -> GrokCredentials {
        try await refresher.refresh(
            credentials,
            session: session,
            homeDirectory: homeDirectory,
            now: now
        )
    }

    /// `.rejected` is the one refresh outcome that means "log in again";
    /// the rest are transient and must not tell the user their login is
    /// gone.
    static func quotaError(for error: Error) -> QuotaError {
        switch error as? GrokOAuthTokenRefresher.RefreshError {
        case .rejected?:
            return .needsLogin
        case .notRefreshable?:
            return .noCredential
        case .network(let message)?:
            return .network("Grok token refresh: \(message)")
        case .invalidResponse(let message)?:
            return .network("Grok token refresh: \(message)")
        case nil:
            return mapURLError(error)
        }
    }

    private func fetchWithBearer(
        credentials: GrokCredentials,
        account: AccountIdentity
    ) async throws -> AccountQuota {
        async let billingSnapshot = GrokWebBillingFetcher.fetch(
            credentials: credentials,
            session: session,
            now: now
        )
        async let accountSettings = GrokAccountSettingsFetcher.fetch(
            credentials: credentials,
            session: session
        )
        // Reset tokens are extra inventory: a failure leaves them nil and
        // never touches the weekly quota.
        async let remainingResets = GrokRemainingResetsFetcher.fetch(
            credentials: credentials,
            session: session,
            now: now()
        )

        // Billing remains the required source of quota truth. Account
        // settings only enriches the badge, so a settings outage or schema
        // change must never make the weekly quota refresh fail.
        let snapshot = try await billingSnapshot
        let detectedTier = try? await accountSettings
        let plan = detectedTier?.subscriptionTierDisplay ?? credentials.planLabel

        return makeQuota(
            snapshot: snapshot,
            account: account,
            plan: plan,
            email: credentials.email,
            resetCredits: await remainingResets
        )
    }

    private func fetchWithCookies(
        header: String,
        account: AccountIdentity
    ) async throws -> AccountQuota {
        let snapshot = try await GrokWebBillingFetcher.fetch(
            cookieHeader: header,
            session: session,
            now: now
        )
        return makeQuota(
            snapshot: snapshot,
            account: account,
            // Cookie-only sessions don't carry email / plan metadata —
            // grok.com's billing payload only reports the percent +
            // reset. Re-use whatever the account identity already
            // knows so the card chrome doesn't flicker between
            // "Grok" and "user@example.com" on each refresh.
            plan: account.plan,
            email: account.email
        )
    }

    private func makeQuota(
        snapshot: GrokWebBillingSnapshot,
        account: AccountIdentity,
        plan: String?,
        email: String?,
        resetCredits: ResetCredits? = nil
    ) -> AccountQuota {
        let bucket = QuotaBucket(
            id: "weekly",
            title: "Weekly",
            shortLabel: "Weekly",
            usedPercent: snapshot.usedPercent,
            resetAt: snapshot.resetsAt,
            // Seven-day credits window. Matches xAI's weekly reset cadence
            // and keeps `UsagePace` from rejecting a fresh cycle (its guard
            // requires time-until-reset <= window).
            rawWindowSeconds: 604_800
        )
        return AccountQuota(
            accountId: account.id,
            tool: .grok,
            buckets: [bucket],
            plan: plan,
            email: email,
            queriedAt: now(),
            error: nil,
            resetCredits: resetCredits
        )
    }
}
