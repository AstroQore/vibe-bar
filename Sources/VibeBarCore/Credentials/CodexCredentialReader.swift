import Foundation

/// Resolved Codex credential ready to be used in an HTTP Authorization header.
/// `accessToken` is sensitive — never log it, never persist outside Keychain.
public struct CodexCredential: Sendable {
    public let accessToken: String
    public let accountId: String?
    public let authMode: String
    public let lastRefresh: String?
    public let source: CredentialSource
}

public enum CodexCredentialReader {
    private static let keychainService = "Codex Auth"

    /// CLI-detected reader. Prefers macOS Keychain "Codex Auth" entry, falls
    /// back to ~/.codex/auth.json.
    public static func loadFromCLI() throws -> CodexCredential {
        if let fromKeychain = try? readFromKeychain() {
            return fromKeychain
        }
        return try readFromAuthJSON()
    }

    /// Decode a Codex credential JSON blob.
    public static func decode(jsonString: String, source: CredentialSource) throws -> CodexCredential {
        guard let data = jsonString.data(using: .utf8) else {
            throw QuotaError.parseFailure("auth.json is not utf8")
        }
        return try decode(data: data, source: source)
    }

    public static func decode(data: Data, source: CredentialSource) throws -> CodexCredential {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.parseFailure("auth.json is not a JSON object")
        }
        let authMode = (root["auth_mode"] as? String) ?? ""
        let lastRefresh = root["last_refresh"] as? String

        let tokens = (root["tokens"] as? [String: Any]) ?? [:]
        let accessToken = (tokens["access_token"] as? String)
            ?? (root["access_token"] as? String)
            ?? ""
        let accountId = (tokens["account_id"] as? String)
            ?? (root["account_id"] as? String)

        if accessToken.isEmpty {
            throw QuotaError.needsLogin
        }

        if authMode != "chatgpt" && !authMode.isEmpty {
            // Non-chatgpt auth modes (e.g. apikey) don't have official quota.
            throw QuotaError.notImplemented
        }

        return CodexCredential(
            accessToken: accessToken,
            accountId: accountId,
            authMode: authMode.isEmpty ? "chatgpt" : authMode,
            lastRefresh: lastRefresh,
            source: source
        )
    }

    private static func readFromKeychain() throws -> CodexCredential {
        let raw = try KeychainStore.readString(service: keychainService)
        return try decode(jsonString: raw, source: .cliDetected)
    }

    private static func readFromAuthJSON() throws -> CodexCredential {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw QuotaError.noCredential
        }
        let data = try Data(contentsOf: url)
        return try decode(data: data, source: .cliDetected)
    }
}
