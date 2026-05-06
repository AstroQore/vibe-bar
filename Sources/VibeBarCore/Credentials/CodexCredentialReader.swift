import Foundation

/// Resolved Codex credential ready to be used in an HTTP Authorization header.
/// `accessToken` is sensitive — never log it, never persist outside Keychain.
public struct CodexCredential: Sendable {
    public let accessToken: String
    public let accountId: String?
    public let idToken: String?
    public let email: String?
    public let plan: String?
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
        let accessToken = stringValue(in: tokens, snakeCaseKey: "access_token", camelCaseKey: "accessToken")
            ?? stringValue(in: root, snakeCaseKey: "access_token", camelCaseKey: "accessToken")
            ?? ""
        let idToken = stringValue(in: tokens, snakeCaseKey: "id_token", camelCaseKey: "idToken")
            ?? stringValue(in: root, snakeCaseKey: "id_token", camelCaseKey: "idToken")
        let payload = JWTClaims.parse(idToken)
        let authDictionaryKey = "https://api.openai.com/auth"
        let profileDictionaryKey = "https://api.openai.com/profile"
        let accountId = stringValue(in: tokens, snakeCaseKey: "account_id", camelCaseKey: "accountId")
            ?? stringValue(in: root, snakeCaseKey: "account_id", camelCaseKey: "accountId")
            ?? JWTClaims.string(["chatgpt_account_id"], in: payload, nested: authDictionaryKey)
            ?? JWTClaims.string(["chatgpt_account_id"], in: payload)
        let email = JWTClaims.string(["email"], in: payload)
            ?? JWTClaims.string(["email"], in: payload, nested: profileDictionaryKey)
        let plan = JWTClaims.string(["chatgpt_plan_type"], in: payload, nested: authDictionaryKey)
            ?? JWTClaims.string(["chatgpt_plan_type"], in: payload)

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
            idToken: idToken,
            email: email,
            plan: plan,
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
        let url = RealHomeDirectory.url
            .appendingPathComponent(".codex/auth.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw QuotaError.noCredential
        }
        let data = try Data(contentsOf: url)
        return try decode(data: data, source: .cliDetected)
    }

    private static func stringValue(
        in dictionary: [String: Any],
        snakeCaseKey: String,
        camelCaseKey: String
    ) -> String? {
        if let value = dictionary[snakeCaseKey] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let value = dictionary[camelCaseKey] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
