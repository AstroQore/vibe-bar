import Foundation

public struct ClaudeQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .claude

    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let session: URLSession
    private let credentialResolver: @Sendable (AccountIdentity) throws -> ClaudeCredential

    public init(
        session: URLSession = .shared,
        credentialResolver: (@Sendable (AccountIdentity) throws -> ClaudeCredential)? = nil
    ) {
        self.session = session
        self.credentialResolver = credentialResolver ?? Self.defaultResolver
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        if account.source == .webCookie {
            do {
                return try await fetchWithWebCookies(for: account)
            } catch let qe as QuotaError {
                return try await fetchWithCLIOrThrow(original: qe, account: account)
            } catch {
                return try await fetchWithCLIOrThrow(
                    original: QuotaError.unknown(SafeLog.sanitize(error.localizedDescription)),
                    account: account
                )
            }
        }

        do {
            return try await fetchWithCLI(for: account)
        } catch let qe as QuotaError {
            return try await fetchWithWebCookiesOrThrow(original: qe, account: account)
        } catch {
            return try await fetchWithWebCookiesOrThrow(
                original: QuotaError.unknown(SafeLog.sanitize(error.localizedDescription)),
                account: account
            )
        }
    }

    private func fetchWithCLI(for account: AccountIdentity) async throws -> AccountQuota {
        let credential: ClaudeCredential
        do {
            credential = try credentialResolver(account)
        } catch let qe as QuotaError {
            throw qe
        } catch {
            throw QuotaError.noCredential
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            SafeLog.net("Claude quota fetch failed: \(SafeLog.sanitize(error.localizedDescription))")
            throw mapURLError(error)
        }

        let http = response as? HTTPURLResponse
        switch http?.statusCode {
        case .some(200), .none:
            break
        case .some(401), .some(403):
            throw QuotaError.needsLogin
        case .some(429):
            throw QuotaError.rateLimited
        case .some(let code) where code >= 500:
            throw QuotaError.network("server \(code)")
        case .some(let code):
            throw QuotaError.unknown("HTTP \(code)")
        }

        var buckets: [QuotaBucket]
        do {
            buckets = try ClaudeResponseParser.parse(data: data)
        } catch let qe as QuotaError {
            throw qe
        } catch {
            throw QuotaError.parseFailure(String(describing: error))
        }
        // Daily Routines lives on a different endpoint (claude.ai web cookie).
        // Fold it in opportunistically. If the call fails or no cookies work,
        // keep a visible placeholder so the Claude card still exposes the
        // Daily Routines slot.
        if let routines = await ClaudeRoutinesFetcher.fetch(session: session) {
            replaceRoutinesBucket(in: &buckets, with: routinesBucket(from: routines))
        }
        ensureRoutinesBucketVisible(in: &buckets)
        let extras = ClaudeResponseParser.parseExtraUsage(data: data)

        return AccountQuota(
            accountId: account.id,
            tool: .claude,
            buckets: buckets,
            plan: account.plan,
            email: account.email,
            queriedAt: Date(),
            error: nil,
            providerExtras: extras
        )
    }

    private func fetchWithCLIOrThrow(original: QuotaError, account: AccountIdentity) async throws -> AccountQuota {
        guard account.allowsCLIFallback else { throw original }
        do {
            return try await fetchWithCLI(for: account)
        } catch {
            throw original
        }
    }

    private func fetchWithWebCookiesOrThrow(original: QuotaError, account: AccountIdentity) async throws -> AccountQuota {
        guard account.allowsWebFallback else { throw original }
        do {
            return try await fetchWithWebCookies(for: account)
        } catch {
            throw original
        }
    }

    /// Build a QuotaBucket from a Daily Routines budget snapshot. The slot is
    /// labeled "Today X / 15" (used count / limit) so the user can see the
    /// raw count instead of just the percentage.
    private func routinesBucket(from result: ClaudeRoutinesFetcher.Result) -> QuotaBucket {
        QuotaBucket(
            id: "daily_routines",
            title: "Today · \(result.used) / \(result.limit)",
            shortLabel: "\(result.used)/\(result.limit)",
            usedPercent: result.usedPercent,
            resetAt: Self.nextRoutineResetDate(),
            rawWindowSeconds: 86_400,
            groupTitle: "Daily Routines"
        )
    }

    private func replaceRoutinesBucket(in buckets: inout [QuotaBucket], with bucket: QuotaBucket) {
        buckets.removeAll { $0.id == "daily_routines" }
        buckets.append(bucket)
    }

    private func ensureRoutinesBucketVisible(in buckets: inout [QuotaBucket]) {
        guard !buckets.contains(where: { $0.id == "daily_routines" }) else { return }
        buckets.append(QuotaBucket(
            id: "daily_routines",
            title: "Today · -- / --",
            shortLabel: "Routine",
            usedPercent: 0,
            resetAt: Self.nextRoutineResetDate(),
            rawWindowSeconds: 86_400,
            groupTitle: "Daily Routines"
        ))
    }

    private func fetchWithWebCookies(for account: AccountIdentity) async throws -> AccountQuota {
        let cookieHeader = try ClaudeWebCookieStore.readCookieHeader()
        let organization = try await organizationID(cookieHeader: cookieHeader)

        var data: Data
        var response: URLResponse
        (data, response) = try await fetchWebUsage(organizationID: organization.id, cookieHeader: cookieHeader)
        if organization.fromCache, !isSuccessfulClaudeWebResponse(response) {
            let freshID = try await ClaudeOrganizationIDFetcher.fetch(cookieHeader: cookieHeader, session: session)
            (data, response) = try await fetchWebUsage(organizationID: freshID, cookieHeader: cookieHeader)
        }
        try validateClaudeWebResponse(response)

        var buckets: [QuotaBucket]
        do {
            buckets = try ClaudeResponseParser.parse(data: data)
        } catch let qe as QuotaError {
            throw qe
        } catch {
            throw QuotaError.parseFailure(String(describing: error))
        }
        // Web path already has the cookie header in hand — pass it directly to
        // the routines fetcher to avoid a redundant keychain read.
        var routines = await ClaudeRoutinesFetcher.fetch(cookieHeader: cookieHeader, session: session)
        if routines == nil {
            routines = await ClaudeRoutinesFetcher.fetch(session: session)
        }
        if let routines {
            replaceRoutinesBucket(in: &buckets, with: routinesBucket(from: routines))
        }
        ensureRoutinesBucketVisible(in: &buckets)
        let extras = ClaudeResponseParser.parseExtraUsage(data: data)

        return AccountQuota(
            accountId: account.id,
            tool: .claude,
            buckets: buckets,
            plan: account.plan,
            email: account.email,
            queriedAt: Date(),
            error: nil,
            providerExtras: extras
        )
    }

    private func fetchWebUsage(organizationID: String, cookieHeader: String) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: usageEndpoint(organizationID: organizationID))
        request.httpMethod = "GET"
        configureClaudeWebHeaders(&request, cookieHeader: cookieHeader)
        request.timeoutInterval = 15

        do {
            return try await session.data(for: request)
        } catch {
            SafeLog.net("Claude web quota fetch failed: \(SafeLog.sanitize(error.localizedDescription))")
            throw mapURLError(error)
        }
    }

    private func organizationID(cookieHeader: String) async throws -> (id: String, fromCache: Bool) {
        if let cached = ClaudeWebCookieStore.readOrganizationID() {
            return (cached, true)
        }
        let fetched = try await ClaudeOrganizationIDFetcher.fetch(cookieHeader: cookieHeader, session: session)
        return (fetched, false)
    }

    private func usageEndpoint(organizationID: String) -> URL {
        URL(string: "https://claude.ai/api/organizations/\(organizationID)/usage")!
    }

    private func configureClaudeWebHeaders(_ request: inout URLRequest, cookieHeader: String) {
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://claude.ai/", forHTTPHeaderField: "Referer")
        request.setValue("claude.ai", forHTTPHeaderField: "Origin")
    }

    private func validateClaudeWebResponse(_ response: URLResponse) throws {
        guard !isSuccessfulClaudeWebResponse(response) else { return }
        let http = response as? HTTPURLResponse
        switch http?.statusCode {
        case .some(401), .some(403):
            throw QuotaError.needsLogin
        case .some(429):
            throw QuotaError.rateLimited
        case .some(let code) where code >= 500:
            throw QuotaError.network("server \(code)")
        case .some(let code):
            throw QuotaError.unknown("HTTP \(code)")
        case .none:
            throw QuotaError.unknown("non-http response")
        }
    }

    private func isSuccessfulClaudeWebResponse(_ response: URLResponse) -> Bool {
        let http = response as? HTTPURLResponse
        return http?.statusCode == 200 || http == nil
    }

    static func parseOrganizationID(data: Data) throws -> String {
        try ClaudeOrganizationIDFetcher.parse(data: data)
    }

    @Sendable
    private static func defaultResolver(_ account: AccountIdentity) throws -> ClaudeCredential {
        guard account.source == .cliDetected || account.allowsCLIFallback else { throw QuotaError.noCredential }
        return try ClaudeCredentialReader.loadFromCLI()
    }

    private static func nextRoutineResetDate(now: Date = Date()) -> Date? {
        Calendar.current.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        )
    }
}
