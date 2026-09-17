import Foundation
import Security

/// What Vibe Bar needs from Meta AI's Muse Code login.
public struct MuseCredential: Sendable, Equatable {
    public let accessToken: String
    public let email: String?
    public let fullName: String?

    public init(accessToken: String, email: String?, fullName: String?) {
        self.accessToken = accessToken
        self.email = email
        self.fullName = fullName
    }
}

/// Reads the login `muse login` leaves behind — and never writes it.
///
/// The CLI splits the login in two:
///
/// - `~/.config/muse/auth.json` names the mechanism and where the secret
///   lives (`providers.meta.storage == "keychain"`) and carries the account's
///   name and email, but no token;
/// - the secret is a login-keychain generic password, service
///   `ai.meta.dev.credentials`, account `meta`, whose payload is JSON:
///   `{secret_schema_version, access_token, api_key}`.
///
/// The keychain item belongs to `muse`, so macOS may ask before another app
/// reads it. Background refreshes never raise that prompt: they read with the
/// no-UI *fail* policy and report
/// `KeychainStore.KeychainError.interactionNotAllowed`, and the Meta AI
/// settings page offers the one user-initiated read that does
/// (`authorizeKeychainAccess`). The *skip* policy the shared store uses would
/// be wrong here: it drops a prompt-gated item from the results, so a login
/// waiting for permission would read as no login at all. The minted `api_key` is ignored on purpose —
/// Vibe Bar only needs the OAuth token the quota endpoint accepts.
public enum MuseCredentialReader {
    public static let keychainService = "ai.meta.dev.credentials"
    public static let keychainAccount = "meta"
    static let providerKey = "meta"

    /// Identity half of the login, readable without touching the keychain.
    public struct AuthFile: Sendable, Equatable {
        public let mechanism: String?
        public let storage: String?
        public let email: String?
        public let fullName: String?
        /// A token stored inline — the file-backed fallback the CLI uses
        /// when no keychain is available.
        public let inlineAccessToken: String?

        public var usesKeychain: Bool { storage == nil || storage == "keychain" }
    }

    public static func authFileURL(homeDirectory: String = RealHomeDirectory.path) -> URL {
        URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".config/muse/auth.json")
    }

    /// True when `muse login` has left a Meta login behind.
    public static func hasLogin(homeDirectory: String = RealHomeDirectory.path) -> Bool {
        readAuthFile(homeDirectory: homeDirectory) != nil
    }

    public static func readAuthFile(homeDirectory: String = RealHomeDirectory.path) -> AuthFile? {
        guard let data = try? Data(contentsOf: authFileURL(homeDirectory: homeDirectory)) else {
            return nil
        }
        return decodeAuthFile(data: data)
    }

    public static func decodeAuthFile(data: Data) -> AuthFile? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let providers = root["providers"] as? [String: Any],
              let meta = providers[providerKey] as? [String: Any]
        else { return nil }
        return AuthFile(
            mechanism: nonEmpty(meta["mechanism"]),
            storage: nonEmpty(meta["storage"]),
            email: nonEmpty(meta["user_email"]),
            fullName: nonEmpty(meta["user_full_name"]),
            inlineAccessToken: nonEmpty(meta["access_token"])
        )
    }

    /// The access token out of the keychain payload.
    public static func decodeSecret(_ raw: String) throws -> String {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else {
            throw QuotaError.parseFailure("Muse Code keychain payload is not JSON")
        }
        guard let token = nonEmpty(root["access_token"]) else { throw QuotaError.needsLogin }
        return token
    }

    /// Loads the login for a background refresh — the keychain read never
    /// prompts.
    ///
    /// - Throws: `QuotaError.noCredential` without a login,
    ///   `KeychainStore.KeychainError.interactionNotAllowed` until the user has allowed
    ///   access, `QuotaError.needsLogin` for a login with no token left.
    public static func load(
        homeDirectory: String = RealHomeDirectory.path,
        readSecret: () throws -> String = { try readSecretWithoutPrompt() }
    ) throws -> MuseCredential {
        guard let authFile = readAuthFile(homeDirectory: homeDirectory) else {
            throw QuotaError.noCredential
        }
        let token: String
        if authFile.usesKeychain {
            do {
                token = try decodeSecret(try readSecret())
            } catch KeychainStore.KeychainError.itemNotFound {
                throw QuotaError.needsLogin
            }
        } else if let inline = authFile.inlineAccessToken {
            token = inline
        } else {
            throw QuotaError.needsLogin
        }
        return MuseCredential(accessToken: token, email: authFile.email, fullName: authFile.fullName)
    }

    /// Whether a background read would succeed right now, without prompting.
    public enum AccessState: Sendable, Equatable {
        case noLogin
        case authorized
        case needsAuthorization
        case missingSecret
        case keychainUnavailable
    }

    public static func accessState(homeDirectory: String = RealHomeDirectory.path) -> AccessState {
        guard let authFile = readAuthFile(homeDirectory: homeDirectory) else { return .noLogin }
        guard authFile.usesKeychain else {
            return authFile.inlineAccessToken == nil ? .missingSecret : .authorized
        }
        // An attributes-only preflight is not enough: reading a legacy
        // keychain item's attributes never needs its ACL, only its data does.
        // So the probe reads the data — silently — and drops it.
        do {
            _ = try readSecretWithoutPrompt()
            return .authorized
        } catch KeychainStore.KeychainError.interactionNotAllowed {
            return .needsAuthorization
        } catch KeychainStore.KeychainError.itemNotFound {
            return .missingSecret
        } catch {
            return .keychainUnavailable
        }
    }

    /// The secret, read with UI disabled under the *fail* policy: an item
    /// macOS would have to ask about answers `interactionNotAllowed` rather
    /// than vanishing from the results.
    public static func readSecretWithoutPrompt() throws -> String {
        guard !DemoMode.isEnabled, !KeychainAccessGate.isDisabled else {
            throw KeychainStore.KeychainError.itemNotFound
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        KeychainNoUIQuery.apply(to: &query, uiPolicy: .fail)
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let raw = String(data: data, encoding: .utf8) else {
                throw KeychainStore.KeychainError.itemNotFound
            }
            return raw
        case errSecItemNotFound:
            throw KeychainStore.KeychainError.itemNotFound
        case errSecInteractionNotAllowed, errSecAuthFailed:
            throw KeychainStore.KeychainError.interactionNotAllowed
        default:
            throw KeychainStore.KeychainError.unhandledStatus(status)
        }
    }

    /// The one read allowed to show the system keychain prompt. Call it only
    /// from a control the user just clicked; choosing "Always Allow" there is
    /// what lets every later background read succeed silently.
    ///
    /// The secret is decoded and dropped — nothing is stored.
    public static func authorizeKeychainAccess() throws {
        guard !DemoMode.isEnabled, !KeychainAccessGate.isDisabled else {
            throw KeychainStore.KeychainError.itemNotFound
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let raw = String(data: data, encoding: .utf8) else {
                throw KeychainStore.KeychainError.itemNotFound
            }
            _ = try decodeSecret(raw)
        case errSecItemNotFound:
            throw KeychainStore.KeychainError.itemNotFound
        case errSecInteractionNotAllowed, errSecUserCanceled, errSecAuthFailed:
            throw KeychainStore.KeychainError.interactionNotAllowed
        default:
            throw KeychainStore.KeychainError.unhandledStatus(status)
        }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
