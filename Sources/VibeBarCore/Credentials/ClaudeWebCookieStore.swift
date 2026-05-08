import Foundation

/// Storage for the minimum Claude web session cookie needed by Vibe Bar.
///
/// Cookies are stored in the user's Keychain, split by source: one
/// captured from Vibe Bar's WebView, one imported from browser cookies.
/// Older plaintext files under `~/.vibebar/cookies` are migrated once and
/// deleted immediately.
public enum ClaudeWebCookieStore {
    public enum CookieSource: Sendable {
        case webView
        case browser
        case legacy
    }

    private static let legacyService = "Vibe Bar Claude Web Cookies"
    private static let legacyAccount = "claude.ai"
    private static let legacyOrganizationAccount = "claude.ai.organization"
    private static let organizationAccount = "claude.organization-id"

    public static func readCookieHeader() throws -> String {
        if let header = candidateCookieHeaders().first {
            return header
        }
        throw QuotaError.noCredential
    }

    public static func readCookieHeader(source: CookieSource) throws -> String {
        migrateLegacyPlaintextCookiesIfNeeded()
        if let header = storedCookieHeader(source: source) {
            return header
        }
        throw QuotaError.noCredential
    }

    public static func candidateCookieHeaders() -> [String] {
        migrateLegacyPlaintextCookiesIfNeeded()
        var headers: [String] = []
        appendStoredCookieHeader(source: .browser, to: &headers)
        appendStoredCookieHeader(source: .webView, to: &headers)
        return unique(headers)
    }

    public static func writeCookieHeader(_ header: String, source: CookieSource = .legacy) throws {
        guard let minimized = minimizedCookieHeader(from: header) else { throw QuotaError.noCredential }
        try SecureCookieHeaderStore.store(
            minimized,
            provider: .claude,
            source: secureSource(for: source)
        )
        try? VibeBarLocalStore.deleteFile(at: VibeBarLocalStore.claudeCookieURL)
        try? VibeBarLocalStore.deleteFile(at: legacyURL(for: source))
    }

    public static func hasCookieHeader() -> Bool {
        (try? readCookieHeader()) != nil
    }

    public static func deleteCookieHeader() throws {
        try SecureCookieHeaderStore.deleteAll(provider: .claude)
        try VibeBarLocalStore.deleteFile(at: VibeBarLocalStore.claudeCookieURL)
        try VibeBarLocalStore.deleteFile(at: VibeBarLocalStore.claudeWebViewCookieURL)
        try VibeBarLocalStore.deleteFile(at: VibeBarLocalStore.claudeBrowserCookieURL)
        try VibeBarLocalStore.deleteFile(at: VibeBarLocalStore.claudeOrganizationIDURL)
        try? KeychainStore.deleteItem(
            service: SecureCookieHeaderStore.keychainService,
            account: organizationAccount,
            useDataProtectionKeychain: true
        )
        try? KeychainStore.deleteItem(service: legacyService, account: legacyAccount, useDataProtectionKeychain: true)
        try? KeychainStore.deleteItem(service: legacyService, account: legacyOrganizationAccount, useDataProtectionKeychain: true)
    }

    public static func readOrganizationID() -> String? {
        if let raw = try? KeychainStore.readString(
            service: SecureCookieHeaderStore.keychainService,
            account: organizationAccount,
            useDataProtectionKeychain: true
        ), let normalized = normalizedOrganizationID(raw) {
            return normalized
        }

        if let local = try? VibeBarLocalStore.readString(from: VibeBarLocalStore.claudeOrganizationIDURL),
           let normalized = normalizedOrganizationID(local) {
            try? KeychainStore.writeString(
                service: SecureCookieHeaderStore.keychainService,
                account: organizationAccount,
                value: normalized,
                useDataProtectionKeychain: true
            )
            try? VibeBarLocalStore.deleteFile(at: VibeBarLocalStore.claudeOrganizationIDURL)
            return normalized
        }
        return nil
    }

    public static func writeOrganizationID(_ organizationID: String) throws {
        guard let trimmed = normalizedOrganizationID(organizationID) else { return }
        try KeychainStore.writeString(
            service: SecureCookieHeaderStore.keychainService,
            account: organizationAccount,
            value: trimmed,
            useDataProtectionKeychain: true
        )
        try? VibeBarLocalStore.deleteFile(at: VibeBarLocalStore.claudeOrganizationIDURL)
    }

    public static func storageState(source: CookieSource) -> SecureCookieHeaderStore.LoadResult {
        migrateLegacyPlaintextCookiesIfNeeded()
        return SecureCookieHeaderStore.load(
            provider: .claude,
            source: secureSource(for: source)
        )
    }

    public static func sessionKeyHeader(from header: String) -> String? {
        for pair in cookiePairs(from: header) where pair.name == "sessionKey" {
            let value = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.hasPrefix("sk-ant-") else { continue }
            return "sessionKey=\(value)"
        }
        return nil
    }

    public static func minimizedCookieHeader(from raw: String) -> String? {
        sessionKeyHeader(from: raw)
    }

    public static func normalizedCookieHeader(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.localizedCaseInsensitiveContains("Cookie:") {
            return trimmed
                .replacingOccurrences(of: "Cookie:", with: "", options: [.caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func appendCookieHeader(_ raw: String?, to headers: inout [String]) {
        guard let raw else { return }
        guard let header = minimizedCookieHeader(from: raw) else { return }
        headers.append(header)
    }

    private static func appendStoredCookieHeader(source: CookieSource, to headers: inout [String]) {
        appendCookieHeader(storedCookieHeader(source: source), to: &headers)
    }

    private static func storedCookieHeader(source: CookieSource) -> String? {
        switch SecureCookieHeaderStore.load(provider: .claude, source: secureSource(for: source)) {
        case .found(let raw):
            return minimizedCookieHeader(from: raw)
        case .missing, .temporarilyUnavailable, .invalid:
            return nil
        }
    }

    private static func migrateLegacyPlaintextCookiesIfNeeded() {
        migrateLegacyPlaintextCookieIfNeeded(from: VibeBarLocalStore.claudeBrowserCookieURL, source: .browser)
        migrateLegacyPlaintextCookieIfNeeded(from: VibeBarLocalStore.claudeWebViewCookieURL, source: .webView)
        migrateLegacyPlaintextCookieIfNeeded(from: VibeBarLocalStore.claudeCookieURL, source: .webView)
    }

    private static func migrateLegacyPlaintextCookieIfNeeded(from url: URL, source: CookieSource) {
        guard let raw = try? VibeBarLocalStore.readString(from: url) else { return }
        defer { try? VibeBarLocalStore.deleteFile(at: url) }
        guard let header = minimizedCookieHeader(from: raw) else { return }
        try? SecureCookieHeaderStore.store(
            header,
            provider: .claude,
            source: secureSource(for: source)
        )
    }

    private static func secureSource(for source: CookieSource) -> SecureCookieHeaderStore.Source {
        switch source {
        case .webView, .legacy: return .webView
        case .browser: return .browser
        }
    }

    private static func legacyURL(for source: CookieSource) -> URL {
        switch source {
        case .webView: return VibeBarLocalStore.claudeWebViewCookieURL
        case .browser: return VibeBarLocalStore.claudeBrowserCookieURL
        case .legacy: return VibeBarLocalStore.claudeCookieURL
        }
    }

    private static func normalizedOrganizationID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func cookiePairs(from header: String) -> [(name: String, value: String)] {
        normalizedCookieHeader(from: header)
            .split(separator: ";")
            .compactMap { part in
                let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pieces.count == 2 else { return nil }
                return (
                    name: pieces[0].trimmingCharacters(in: .whitespacesAndNewlines),
                    value: pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
    }

    private static func unique(_ headers: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for header in headers where seen.insert(header).inserted {
            out.append(header)
        }
        return out
    }
}
