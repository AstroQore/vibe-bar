import Foundation

/// Keychain-backed store for username/password pairs captured inside
/// the misc-provider WebView login flow.
///
/// WKWebView doesn't talk to the system AutoFill / Safari password
/// store, so providers that use a real password form (QQ login on
/// Tencent, mobile + password on Volcengine, etc.) used to lose the
/// credential the moment the login window closed. This store keeps a
/// small per-tool list of "form login" records so the next time the
/// user opens the same login window the WebView can repopulate the
/// fields.
///
/// Layout:
///
/// - Service: `com.astroqore.VibeBar.web-form-passwords`
/// - Account: `<tool.rawValue>.formCredentials`
/// - Value:   JSON array of `WebFormCredential`
///
/// Records dedupe on `(host, username)` — re-saving the same login
/// updates the password and bumps `savedAt` instead of duplicating.
public enum WebFormCredentialStore {
    public static let keychainService = "com.astroqore.VibeBar.web-form-passwords"
    private static let accountSuffix = ".formCredentials"

    public static func keychainAccount(tool: ToolType) -> String {
        precondition(tool.isMisc, "WebFormCredentialStore is misc-only; got \(tool)")
        return "\(tool.rawValue)\(accountSuffix)"
    }

    public static func read(for tool: ToolType) -> [WebFormCredential] {
        guard tool.isMisc else { return [] }
        do {
            let data = try KeychainStore.readData(
                service: keychainService,
                account: keychainAccount(tool: tool),
                useDataProtectionKeychain: true
            )
            return decode(data)
        } catch {
            return []
        }
    }

    /// Look up the credential to autofill for a given host.
    /// Picks the most-recently-saved record whose host matches `host`
    /// (case-insensitive, suffix-aware so `passport.qq.com` matches
    /// records stored under `qq.com`).
    public static func bestMatch(for host: String, tool: ToolType) -> WebFormCredential? {
        let lowered = host.lowercased()
        let candidates = read(for: tool).filter { $0.matchesHost(lowered) }
        return candidates.max(by: { $0.savedAt < $1.savedAt })
    }

    /// Save or update `credential`. Returns `true` if the credential
    /// landed in Keychain. Existing records with the same
    /// `(host, username)` are replaced.
    @discardableResult
    public static func save(_ credential: WebFormCredential, for tool: ToolType) -> Bool {
        guard tool.isMisc else { return false }
        guard credential.isUsable else { return false }
        var current = read(for: tool)
        current.removeAll { existing in
            existing.host.caseInsensitiveCompare(credential.host) == .orderedSame &&
            existing.username == credential.username
        }
        current.append(credential)
        return write(current, for: tool)
    }

    /// Remove a single record. Returns `true` if anything changed.
    @discardableResult
    public static func remove(host: String, username: String, for tool: ToolType) -> Bool {
        guard tool.isMisc else { return false }
        var current = read(for: tool)
        let before = current.count
        current.removeAll { existing in
            existing.host.caseInsensitiveCompare(host) == .orderedSame &&
            existing.username == username
        }
        guard current.count != before else { return false }
        return write(current, for: tool)
    }

    @discardableResult
    public static func clearAll(for tool: ToolType) -> Bool {
        guard tool.isMisc else { return false }
        return write([], for: tool)
    }

    public static func hasAny(for tool: ToolType) -> Bool {
        !read(for: tool).isEmpty
    }

    // MARK: - Persistence

    @discardableResult
    private static func write(_ credentials: [WebFormCredential], for tool: ToolType) -> Bool {
        let account = keychainAccount(tool: tool)
        if credentials.isEmpty {
            do {
                try KeychainStore.deleteItem(
                    service: keychainService,
                    account: account,
                    useDataProtectionKeychain: true
                )
                return true
            } catch KeychainStore.KeychainError.itemNotFound {
                return true
            } catch {
                SafeLog.warn("WebFormCredentialStore delete failed for \(tool.rawValue): \(error)")
                return false
            }
        }
        do {
            let data = try JSONEncoder().encode(credentials)
            try KeychainStore.writeData(
                service: keychainService,
                account: account,
                data: data,
                useDataProtectionKeychain: true
            )
            return true
        } catch {
            SafeLog.error("WebFormCredentialStore write failed for \(tool.rawValue): \(error)")
            return false
        }
    }

    private static func decode(_ data: Data) -> [WebFormCredential] {
        (try? JSONDecoder().decode([WebFormCredential].self, from: data)) ?? []
    }
}

public struct WebFormCredential: Codable, Equatable, Sendable {
    public var host: String
    public var username: String
    public var password: String
    public var savedAt: Date

    public init(host: String, username: String, password: String, savedAt: Date = Date()) {
        self.host = WebFormCredential.normalizeHost(host)
        self.username = username
        self.password = password
        self.savedAt = savedAt
    }

    public var isUsable: Bool {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = password
        return !h.isEmpty && !u.isEmpty && !p.isEmpty
    }

    /// Suffix match so `passport.qq.com` matches a record saved under
    /// `qq.com` (and vice versa). Exact equality also wins.
    public func matchesHost(_ candidate: String) -> Bool {
        let stored = WebFormCredential.normalizeHost(host).lowercased()
        let asked = WebFormCredential.normalizeHost(candidate).lowercased()
        guard !stored.isEmpty, !asked.isEmpty else { return false }
        if stored == asked { return true }
        if asked.hasSuffix("." + stored) { return true }
        if stored.hasSuffix("." + asked) { return true }
        return false
    }

    static func normalizeHost(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(".") {
            trimmed = String(trimmed.dropFirst())
        }
        return trimmed
    }
}
