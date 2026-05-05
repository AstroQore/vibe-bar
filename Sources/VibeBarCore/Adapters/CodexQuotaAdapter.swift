import Foundation

public struct CodexQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .codex

    private let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private let session: URLSession
    private let credentialResolver: @Sendable (AccountIdentity) throws -> CodexCredential

    public init(
        session: URLSession = .shared,
        credentialResolver: (@Sendable (AccountIdentity) throws -> CodexCredential)? = nil
    ) {
        self.session = session
        self.credentialResolver = credentialResolver ?? Self.defaultResolver
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        let credential: CodexCredential
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
            plan: account.plan,
            email: account.email,
            queriedAt: Date(),
            error: nil
        )
    }

    @Sendable
    private static func defaultResolver(_ account: AccountIdentity) throws -> CodexCredential {
        guard account.source == .cliDetected else { throw QuotaError.noCredential }
        return try CodexCredentialReader.loadFromCLI()
    }
}
