import Foundation

/// Account metadata exposed by the official Grok CLI settings endpoint.
/// The billing endpoint deliberately carries only quota amounts, while this
/// endpoint supplies the human-facing subscription tier (for example,
/// `SuperGrok Heavy`).
public struct GrokAccountSettingsSnapshot: Sendable, Equatable {
    public let subscriptionTierDisplay: String?

    public init(subscriptionTierDisplay: String?) {
        self.subscriptionTierDisplay = subscriptionTierDisplay
    }
}

public enum GrokAccountSettingsFetcher {
    public static let defaultEndpoint =
        URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!
    private static let requestTimeoutSeconds: TimeInterval = 15

    public static func fetch(
        credentials: GrokCredentials,
        session: URLSession = .shared,
        endpoint: URL = Self.defaultEndpoint
    ) async throws -> GrokAccountSettingsSnapshot {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("VibeBar", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw mapURLError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Grok settings: invalid response object")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw QuotaError.needsLogin
            }
            if http.statusCode == 429 {
                throw QuotaError.rateLimited
            }
            throw QuotaError.network("Grok settings returned HTTP \(http.statusCode).")
        }

        do {
            let payload = try JSONDecoder().decode(SettingsPayload.self, from: data)
            return GrokAccountSettingsSnapshot(
                subscriptionTierDisplay: ProviderPlanDisplay.grokDisplayName(
                    payload.subscriptionTierDisplay
                )
            )
        } catch let error as QuotaError {
            throw error
        } catch {
            throw QuotaError.parseFailure("Could not decode Grok account settings.")
        }
    }

    private struct SettingsPayload: Decodable {
        let subscriptionTierDisplay: String?

        enum CodingKeys: String, CodingKey {
            case subscriptionTierDisplay = "subscription_tier_display"
        }
    }
}
