import Foundation

/// xAI Grok partial-primary usage adapter.
///
/// Reads `~/.grok/auth.json` (written by `grok login`) and posts an
/// empty gRPC-web frame to
/// `https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig`
/// using the bearer token from that file. The response is a tiny
/// protobuf payload carrying the monthly used-percent and the next
/// reset timestamp; both fields surface as a single
/// `QuotaBucket(id: "monthly", ...)` on the card.
///
/// The cookie-based fallback that Codex Bar maintains is intentionally
/// deferred — `grok login` is the documented entry point for
/// SuperGrok subscribers, and the cookie path adds a sizeable
/// SweetCookieKit + browser-import surface that doesn't pay off until
/// users without `grok login` show up.
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
        let credentials: GrokCredentials
        do {
            credentials = try GrokCredentialsStore.load(homeDirectory: homeDirectory)
        } catch let error as QuotaError {
            throw error
        } catch {
            throw QuotaError.parseFailure("Could not load ~/.grok/auth.json: \(error.localizedDescription)")
        }

        if credentials.isExpired {
            throw QuotaError.needsLogin
        }

        let snapshot = try await GrokWebBillingFetcher.fetch(
            credentials: credentials,
            session: session,
            now: now
        )

        let bucket = QuotaBucket(
            id: "monthly",
            title: "Monthly",
            shortLabel: "Monthly",
            usedPercent: snapshot.usedPercent,
            resetAt: snapshot.resetsAt,
            rawWindowSeconds: nil,
            groupTitle: "Grok"
        )

        return AccountQuota(
            accountId: account.id,
            tool: .grok,
            buckets: [bucket],
            plan: credentials.planLabel,
            email: credentials.email,
            queriedAt: now(),
            error: nil
        )
    }
}
