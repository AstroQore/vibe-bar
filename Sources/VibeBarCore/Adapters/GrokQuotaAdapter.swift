import Foundation

/// xAI Grok partial-primary usage adapter.
///
/// Hits `https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig`
/// with one of two credentials:
///
/// 1. **`~/.grok/auth.json` bearer** (preferred). Written by
///    `grok login`. Carries the SuperGrok email and plan label so the
///    card chrome is rich.
/// 2. **grok.com browser cookies** (fallback). Imported via
///    `GrokBrowserCookieImporter` from Chrome / Safari / etc., stored
///    minimised in Keychain by `GrokWebCookieStore`. Used when the
///    user signed in to grok.com on the web but never ran
///    `grok login` — the case that Codex Bar already handles.
///
/// The response is a tiny protobuf payload carrying the monthly
/// used-percent and the next reset timestamp; both fields surface as
/// a single `QuotaBucket(id: "monthly", ...)` on the card.
public struct GrokQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .grok

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
        let credentials = (try? GrokCredentialsStore.load(homeDirectory: homeDirectory)).flatMap { creds in
            creds.isExpired ? nil : creds
        }

        if let credentials {
            return try await fetchWithBearer(credentials: credentials, account: account)
        }

        if let header = try? GrokWebCookieStore.readCookieHeader() {
            return try await fetchWithCookies(header: header, account: account)
        }

        // Neither source available. Prefer the auth.json error message
        // because it's actionable (`grok login` is the canonical
        // documented path) and tells the user exactly what to do.
        throw QuotaError.noCredential
    }

    private func fetchWithBearer(
        credentials: GrokCredentials,
        account: AccountIdentity
    ) async throws -> AccountQuota {
        let snapshot = try await GrokWebBillingFetcher.fetch(
            credentials: credentials,
            session: session,
            now: now
        )
        return makeQuota(
            snapshot: snapshot,
            account: account,
            plan: credentials.planLabel,
            email: credentials.email
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
        email: String?
    ) -> AccountQuota {
        let bucket = QuotaBucket(
            id: "monthly",
            title: "Monthly",
            shortLabel: "Monthly",
            usedPercent: snapshot.usedPercent,
            resetAt: snapshot.resetsAt,
            // Calendar-month credits window. 31 days covers the longest
            // month so `UsagePace` never rejects a fresh cycle
            // (its guard requires time-until-reset <= window); short
            // months just skew the expected line slightly early.
            rawWindowSeconds: 2_678_400
        )
        return AccountQuota(
            accountId: account.id,
            tool: .grok,
            buckets: [bucket],
            plan: plan,
            email: email,
            queriedAt: now(),
            error: nil
        )
    }
}
