import Foundation

/// Meta AI · Muse Code quota adapter.
///
/// Reads the OAuth token `muse login` keeps in the macOS Keychain (see
/// `MuseCredentialReader`) and posts it to
/// `https://api.meta.ai/muse-code/key` — the same call the CLI makes at
/// start-up to learn its API key and subscription usage. The call is
/// idempotent: it hands back the key the account already has rather than
/// minting a new one, so polling it leaves the CLI's own session alone.
///
/// Nothing is written back — not the token, not the returned key.
///
/// The request goes through `URLSession`'s default configuration, which
/// honours the macOS system proxy. That matters for Meta's hosts: where a
/// resolver hands back an unreachable address, the system proxy — which
/// receives the host name rather than an IP — is what reaches them.
public struct MuseQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .muse

    public static let usageURL = URL(string: "https://api.meta.ai/muse-code/key")!
    static let apiVersion = "1.0.0"

    private let session: URLSession
    private let now: @Sendable () -> Date
    private let credential: @Sendable () throws -> MuseCredential

    public init(
        session: URLSession = .shared,
        homeDirectory: String = RealHomeDirectory.path,
        now: @escaping @Sendable () -> Date = { Date() },
        credential: (@Sendable () throws -> MuseCredential)? = nil
    ) {
        self.session = session
        self.now = now
        self.credential = credential ?? { try MuseCredentialReader.load(homeDirectory: homeDirectory) }
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        let login: MuseCredential
        do {
            login = try credential()
        } catch KeychainStore.KeychainError.interactionNotAllowed {
            throw QuotaError.credentialRejected(L10n.Quota.Muse.keychainAccessNeeded)
        } catch let error as QuotaError {
            throw error
        } catch {
            SafeLog.warn("Muse Code login unreadable: \(String(describing: type(of: error)))")
            throw QuotaError.noCredential
        }

        let data = try await post(token: login.accessToken)
        let snapshot = try MuseResponseParser.parse(data: data)
        return AccountQuota(
            accountId: account.id,
            tool: .muse,
            buckets: snapshot.buckets,
            plan: snapshot.tierName ?? account.plan,
            email: snapshot.email ?? login.email ?? account.email,
            queriedAt: now()
        )
    }

    static func makeRequest(token: String) -> URLRequest {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiVersion, forHTTPHeaderField: "x-api-version")
        request.setValue("VibeBar", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("{}".utf8)
        return request
    }

    private func post(token: String) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: Self.makeRequest(token: token))
        } catch {
            SafeLog.net("Muse Code usage request failed: \(SafeLog.sanitize(error.localizedDescription))")
            throw mapURLError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.unknown("no HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw QuotaError.needsLogin
        case 429:
            throw QuotaError.rateLimited
        case 500...599:
            throw QuotaError.network("server \(http.statusCode)")
        default:
            throw QuotaError.unknown("HTTP \(http.statusCode)")
        }
    }
}
