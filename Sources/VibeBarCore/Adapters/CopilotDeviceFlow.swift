import Foundation

/// GitHub OAuth device flow used for Copilot. The client id matches
/// VS Code's GitHub OAuth app, which is the same path Codex Bar uses
/// for Copilot accounts.
public struct CopilotDeviceFlow: Sendable {
    public static let defaultHost = "github.com"

    private let clientID = "Iv1.b507a08c87ecfe98"
    private let scopes = "read:user"
    private let host: String
    private let session: URLSession

    public struct DeviceCodeResponse: Decodable, Sendable {
        public let deviceCode: String
        public let userCode: String
        public let verificationUri: String
        public let verificationUriComplete: String?
        public let expiresIn: Int
        public let interval: Int

        public var verificationURLToOpen: String {
            verificationUriComplete ?? verificationUri
        }

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationUri = "verification_uri"
            case verificationUriComplete = "verification_uri_complete"
            case expiresIn = "expires_in"
            case interval
        }
    }

    public struct AccessTokenResponse: Decodable, Sendable {
        public let accessToken: String
        public let tokenType: String
        public let scope: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case scope
        }
    }

    public init(enterpriseHost: String? = nil, session: URLSession = .shared) {
        self.host = Self.normalizedHost(enterpriseHost)
        self.session = session
    }

    public var deviceCodeURL: URL? {
        Self.makeRequestURL(host: host, path: "/login/device/code")
    }

    public var accessTokenURL: URL? {
        Self.makeRequestURL(host: host, path: "/login/oauth/access_token")
    }

    public static func normalizedHost(_ raw: String?) -> String {
        guard var host = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            return defaultHost
        }

        let parseable = host.contains("://") ? host : "https://\(host)"
        if let components = URLComponents(string: parseable),
           let parsedHost = components.host,
           !parsedHost.isEmpty {
            host = parsedHost
            if let port = components.port {
                host += ":\(port)"
            }
        } else {
            if host.hasPrefix("https://") {
                host.removeFirst("https://".count)
            } else if host.hasPrefix("http://") {
                host.removeFirst("http://".count)
            }
            host = host.split(separator: "/", maxSplits: 1).first.map(String.init) ?? host
        }

        let normalized = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return normalized.isEmpty ? defaultHost : normalized
    }

    public func requestDeviceCode() async throws -> DeviceCodeResponse {
        guard let url = deviceCodeURL else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formURLEncodedBody([
            "client_id": clientID,
            "scope": scopes
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
    }

    public func pollForToken(deviceCode: String, interval: Int) async throws -> String {
        guard let url = accessTokenURL else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formURLEncodedBody([
            "client_id": clientID,
            "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
        ])

        var pollInterval = max(1, interval)
        while true {
            try await Task.sleep(nanoseconds: UInt64(pollInterval) * 1_000_000_000)
            try Task.checkCancellation()

            let (data, _) = try await session.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? String {
                switch error {
                case "authorization_pending":
                    continue
                case "slow_down":
                    pollInterval += 5
                    continue
                case "expired_token":
                    throw URLError(.timedOut)
                case "access_denied":
                    throw URLError(.userCancelledAuthentication)
                default:
                    throw URLError(.userAuthenticationRequired)
                }
            }

            if let token = try? JSONDecoder().decode(AccessTokenResponse.self, from: data) {
                return token.accessToken
            }
            throw URLError(.cannotParseResponse)
        }
    }

    public static func makeRequestURL(host: String, path: String) -> URL? {
        URL(string: "https://\(host)\(path)")
    }

    private static func formURLEncodedBody(_ parameters: [String: String]) -> Data {
        let pairs = parameters
            .map { key, value in
                "\(formEncode(key))=\(formEncode(value))"
            }
            .joined(separator: "&")
        return Data(pairs.utf8)
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
