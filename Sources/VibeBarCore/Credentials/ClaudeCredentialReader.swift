import Foundation

public struct ClaudeCredential: Sendable {
    public let accessToken: String
    public let expiresAt: Date?
    public let rateLimitTier: String?
    public let source: CredentialSource
}

public enum ClaudeCredentialReader {
    private static let keychainService = "Claude Code-credentials"

    public static func loadFromCLI() throws -> ClaudeCredential {
        if let fromKeychain = try? readFromKeychain() {
            return fromKeychain
        }
        return try readFromCredentialsJSON()
    }

    public static func loadFromOAuth() throws -> ClaudeCredential {
        if let fromFile = try? readFromCredentialsJSON(source: .oauthCLI) {
            return fromFile
        }
        if let fromKeychain = try? readFromKeychain(source: .oauthCLI) {
            return fromKeychain
        }
        throw QuotaError.noCredential
    }

    public static func decode(jsonString: String, source: CredentialSource) throws -> ClaudeCredential {
        guard let data = jsonString.data(using: .utf8) else {
            throw QuotaError.parseFailure("credentials json is not utf8")
        }
        return try decode(data: data, source: source)
    }

    public static func decode(data: Data, source: CredentialSource) throws -> ClaudeCredential {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.parseFailure("credentials json is not an object")
        }

        let oauth: [String: Any] =
            (root["claudeAiOauth"] as? [String: Any])
            ?? (root["claude.ai_oauth"] as? [String: Any])
            ?? root

        let accessToken = (oauth["accessToken"] as? String)
            ?? (oauth["access_token"] as? String)
            ?? ""

        if accessToken.isEmpty {
            throw QuotaError.needsLogin
        }

        let expiresAt = parseExpiresAt(oauth["expiresAt"] ?? oauth["expires_at"])
        let rateLimitTier = stringValue(oauth["rateLimitTier"] ?? oauth["rate_limit_tier"])

        return ClaudeCredential(
            accessToken: accessToken,
            expiresAt: expiresAt,
            rateLimitTier: rateLimitTier,
            source: source
        )
    }

    private static func readFromKeychain(source: CredentialSource = .cliDetected) throws -> ClaudeCredential {
        let raw = try KeychainStore.readString(service: keychainService)
        return try decode(jsonString: raw, source: source)
    }

    private static func readFromCredentialsJSON(source: CredentialSource = .cliDetected) throws -> ClaudeCredential {
        let url = RealHomeDirectory.url
            .appendingPathComponent(".claude/.credentials.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw QuotaError.noCredential
        }
        let data = try Data(contentsOf: url)
        return try decode(data: data, source: source)
    }

    private static func parseExpiresAt(_ any: Any?) -> Date? {
        switch any {
        case let n as NSNumber:
            // Could be seconds or milliseconds; assume ms if very large.
            let v = n.doubleValue
            return v > 1_000_000_000_000 ? Date(timeIntervalSince1970: v / 1000.0)
                                         : Date(timeIntervalSince1970: v)
        case let s as String:
            if let d = Double(s) {
                return d > 1_000_000_000_000 ? Date(timeIntervalSince1970: d / 1000.0)
                                             : Date(timeIntervalSince1970: d)
            }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s)
        default:
            return nil
        }
    }

    private static func stringValue(_ any: Any?) -> String? {
        guard let string = any as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
