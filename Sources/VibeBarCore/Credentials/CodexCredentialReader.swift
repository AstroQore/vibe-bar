import Foundation

/// Resolved Codex credential ready to be used in an HTTP Authorization header.
/// `accessToken` is sensitive — never log it, never persist outside Keychain.
public struct CodexCredential: Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let accountId: String?
    public let idToken: String?
    public let email: String?
    public let plan: String?
    public let authMode: String
    public let lastRefresh: String?
    public let lastRefreshDate: Date?
    public let source: CredentialSource

    public var needsRefresh: Bool {
        guard refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        guard let lastRefreshDate else { return true }
        return Date().timeIntervalSince(lastRefreshDate) > 8 * 24 * 60 * 60
    }
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

    /// OAuth-priority reader. This deliberately reads `auth.json`
    /// first because it is the Codex CLI's durable OAuth material and
    /// includes refresh metadata that the Keychain mirror may not expose.
    public static func loadFromOAuth() throws -> CodexCredential {
        try readFromAuthJSON(source: .oauthCLI)
    }

    public static func saveOAuth(_ credential: CodexCredential) throws {
        let url = authJSONURL()
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }

        var tokens = (root["tokens"] as? [String: Any]) ?? [:]
        tokens["access_token"] = credential.accessToken
        if let refreshToken = credential.refreshToken {
            tokens["refresh_token"] = refreshToken
        }
        if let idToken = credential.idToken {
            tokens["id_token"] = idToken
        }
        if let accountId = credential.accountId {
            tokens["account_id"] = accountId
        }
        root["tokens"] = tokens
        root["auth_mode"] = credential.authMode
        root["last_refresh"] = ISO8601DateFormatter().string(from: Date())

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
        let refreshToken = stringValue(in: tokens, snakeCaseKey: "refresh_token", camelCaseKey: "refreshToken")
            ?? stringValue(in: root, snakeCaseKey: "refresh_token", camelCaseKey: "refreshToken")
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
            refreshToken: refreshToken,
            accountId: accountId,
            idToken: idToken,
            email: email,
            plan: plan,
            authMode: authMode.isEmpty ? "chatgpt" : authMode,
            lastRefresh: lastRefresh,
            lastRefreshDate: parseLastRefresh(lastRefresh),
            source: source
        )
    }

    private static func readFromKeychain() throws -> CodexCredential {
        let raw = try KeychainStore.readString(service: keychainService)
        return try decode(jsonString: raw, source: .cliDetected)
    }

    private static func readFromAuthJSON(source: CredentialSource = .cliDetected) throws -> CodexCredential {
        let url = authJSONURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw QuotaError.noCredential
        }
        let data = try Data(contentsOf: url)
        return try decode(data: data, source: source)
    }

    private static func parseLastRefresh(_ raw: String?) -> Date? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: raw) { return date }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: raw)
    }

    private static func authJSONURL() -> URL {
        RealHomeDirectory.url
            .appendingPathComponent(".codex/auth.json")
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
