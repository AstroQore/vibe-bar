import Foundation

public struct CodexQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .codex

    private let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private let session: URLSession
    private let credentialResolver: @Sendable (CredentialSource, AccountIdentity) throws -> CodexCredential

    public init(
        session: URLSession = .shared,
        credentialResolver: (@Sendable (CredentialSource, AccountIdentity) throws -> CodexCredential)? = nil
    ) {
        self.session = session
        self.credentialResolver = credentialResolver ?? Self.defaultResolver
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        var firstError: Error?
        for source in sourceOrder(for: account) {
            do {
                if source == .webCookie {
                    return try await fetchWithWebCookies(for: account)
                }
                return try await fetch(for: account, source: source)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        throw firstError ?? QuotaError.noCredential
    }

    private func fetch(for account: AccountIdentity, source: CredentialSource) async throws -> AccountQuota {
        var credential: CodexCredential
        do {
            credential = try credentialResolver(source, account)
            if source == .oauthCLI, credential.needsRefresh {
                credential = try await CodexOAuthTokenRefresher.refresh(credential, session: session)
                try? CodexCredentialReader.saveOAuth(credential)
            }
        } catch let qe as QuotaError {
            throw qe
        } catch {
            throw QuotaError.noCredential
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let id = credential.accountId, !id.isEmpty {
            request.setValue(id, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            SafeLog.net("Codex quota fetch failed: \(SafeLog.sanitize(error.localizedDescription))")
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

        let buckets: [QuotaBucket]
        do {
            buckets = try CodexResponseParser.parse(data: data)
        } catch let qe as QuotaError {
            throw qe
        } catch {
            throw QuotaError.parseFailure(String(describing: error))
        }

        return AccountQuota(
            accountId: account.id,
            tool: .codex,
            buckets: buckets,
            plan: CodexResponseParser.planType(data: data) ?? credential.plan ?? account.plan,
            email: credential.email ?? account.email,
            queriedAt: Date(),
            error: nil
        )
    }

    private func fetchWithWebCookies(for account: AccountIdentity) async throws -> AccountQuota {
        let cookieHeader = try OpenAIWebCookieStore.readCookieHeader()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://chatgpt.com/codex/settings/usage", forHTTPHeaderField: "Referer")
        request.setValue("chatgpt.com", forHTTPHeaderField: "Origin")
        request.setValue("VibeBar", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            SafeLog.net("OpenAI web quota fetch failed: \(SafeLog.sanitize(error.localizedDescription))")
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

        let buckets: [QuotaBucket]
        do {
            buckets = try CodexResponseParser.parse(data: data)
        } catch let qe as QuotaError {
            throw qe
        } catch {
            throw QuotaError.parseFailure(String(describing: error))
        }

        return AccountQuota(
            accountId: account.id,
            tool: .codex,
            buckets: buckets,
            plan: CodexResponseParser.planType(data: data) ?? account.plan,
            email: account.email,
            queriedAt: Date(),
            error: nil
        )
    }

    @Sendable
    private static func defaultResolver(_ source: CredentialSource, _ account: AccountIdentity) throws -> CodexCredential {
        switch source {
        case .oauthCLI:
            return try CodexCredentialReader.loadFromOAuth()
        case .cliDetected:
            return try CodexCredentialReader.loadFromCLI()
        case .webCookie, .apiToken, .browserCookie, .manualCookie, .localProbe, .notConfigured:
            guard account.source == .cliDetected else { throw QuotaError.noCredential }
            return try CodexCredentialReader.loadFromCLI()
        }
    }

    private func sourceOrder(for account: AccountIdentity) -> [CredentialSource] {
        let raw: [CredentialSource]
        switch account.source {
        case .oauthCLI:
            raw = [.oauthCLI]
                + (account.allowsCLIFallback ? [.cliDetected] : [])
                + (account.allowsWebFallback ? [.webCookie] : [])
        case .cliDetected:
            raw = [.cliDetected]
                + (account.allowsOAuthFallback ? [.oauthCLI] : [])
                + (account.allowsWebFallback ? [.webCookie] : [])
        case .webCookie:
            raw = [.webCookie]
                + (account.allowsOAuthFallback ? [.oauthCLI] : [])
                + (account.allowsCLIFallback ? [.cliDetected] : [])
        case .apiToken, .browserCookie, .manualCookie, .localProbe, .notConfigured:
            raw = CodexSourcePlanner.resolve(mode: .auto)
        }
        var seen: Set<CredentialSource> = []
        return raw.filter { seen.insert($0).inserted }
    }
}
