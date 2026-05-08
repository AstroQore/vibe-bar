import Foundation

enum CodexOAuthTokenRefresher {
    private static let refreshEndpoint = URL(string: "https://auth.openai.com/oauth/token")!
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    enum RefreshError: Error {
        case noRefreshToken
        case invalidResponse
        case unauthorized
        case network(Error)
    }

    static func refresh(_ credential: CodexCredential, session: URLSession = .shared) async throws -> CodexCredential {
        guard let refreshToken = credential.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !refreshToken.isEmpty else {
            throw RefreshError.noRefreshToken
        }

        var request = URLRequest(url: refreshEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "openid profile email"
        ])

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RefreshError.invalidResponse
            }
            switch http.statusCode {
            case 200:
                break
            case 401, 403:
                throw RefreshError.unauthorized
            default:
                throw RefreshError.invalidResponse
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw RefreshError.invalidResponse
            }
            let accessToken = (json["access_token"] as? String) ?? credential.accessToken
            let nextRefreshToken = (json["refresh_token"] as? String) ?? refreshToken
            let idToken = (json["id_token"] as? String) ?? credential.idToken
            return CodexCredential(
                accessToken: accessToken,
                refreshToken: nextRefreshToken,
                accountId: credential.accountId,
                idToken: idToken,
                email: credential.email,
                plan: credential.plan,
                authMode: credential.authMode,
                lastRefresh: ISO8601DateFormatter().string(from: Date()),
                lastRefreshDate: Date(),
                source: credential.source
            )
        } catch let error as RefreshError {
            throw error
        } catch {
            throw RefreshError.network(error)
        }
    }
}
