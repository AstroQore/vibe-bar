import Foundation

/// Storage for the minimum Claude web session cookie needed by Vibe Bar.
///
/// Cookies are stored in Keychain. Older builds wrote
/// `~/.vibebar/cookies/claude-web.txt`; reads still migrate that legacy file
/// into Keychain and then remove it.
public enum ClaudeWebCookieStore {
    private static let service = "Vibe Bar Claude Web Cookies"
    private static let account = "claude.ai"
    private static let organizationAccount = "claude.ai.organization"

    public static func readCookieHeader() throws -> String {
        if let header = candidateCookieHeaders().first {
            return header
        }
        throw QuotaError.noCredential
    }

    public static func candidateCookieHeaders() -> [String] {
        var headers: [String] = []
        let rawKeychainHeader = try? KeychainStore.readString(service: service, account: account, useDataProtectionKeychain: true)
        let keychainHeader = rawKeychainHeader
            .map { normalizedCookieHeader(from: $0) }
            .flatMap { $0.isEmpty ? nil : $0 }
            .flatMap { minimizedCookieHeader(from: $0) }
        if let rawKeychainHeader,
           let keychainHeader,
           normalizedCookieHeader(from: rawKeychainHeader) != keychainHeader {
            try? KeychainStore.writeString(service: service, account: account, value: keychainHeader, useDataProtectionKeychain: true)
        }
        appendCookieHeader(keychainHeader, to: &headers)
        if let legacy = try? VibeBarLocalStore.readString(from: VibeBarLocalStore.claudeCookieURL) {
            let legacyHeader = minimizedCookieHeader(from: legacy)
            if keychainHeader == nil, let legacyHeader {
                appendCookieHeader(legacyHeader, to: &headers)
                try? writeCookieHeader(legacyHeader)
            }
            try? VibeBarLocalStore.deleteFile(at: VibeBarLocalStore.claudeCookieURL)
        }
        return unique(headers)
    }

    public static func writeCookieHeader(_ header: String) throws {
        guard let minimized = minimizedCookieHeader(from: header) else { throw QuotaError.noCredential }
        try KeychainStore.writeString(service: service, account: account, value: minimized, useDataProtectionKeychain: true)
        try? VibeBarLocalStore.deleteFile(at: VibeBarLocalStore.claudeCookieURL)
    }

    public static func hasCookieHeader() -> Bool {
        (try? readCookieHeader()) != nil
    }

    public static func deleteCookieHeader() throws {
        try VibeBarLocalStore.deleteFile(at: VibeBarLocalStore.claudeCookieURL)
        try VibeBarLocalStore.deleteFile(at: VibeBarLocalStore.claudeOrganizationIDURL)
        try? KeychainStore.deleteItem(service: service, account: account, useDataProtectionKeychain: true)
        try? KeychainStore.deleteItem(service: service, account: organizationAccount, useDataProtectionKeychain: true)
    }

    public static func readOrganizationID() -> String? {
        if let raw = try? KeychainStore.readString(service: service, account: organizationAccount, useDataProtectionKeychain: true),
           let normalized = normalizedOrganizationID(raw) {
            try? VibeBarLocalStore.deleteFile(at: VibeBarLocalStore.claudeOrganizationIDURL)
            return normalized
        }
        if let legacy = try? VibeBarLocalStore.readString(from: VibeBarLocalStore.claudeOrganizationIDURL),
           let normalized = normalizedOrganizationID(legacy) {
            try? writeOrganizationID(normalized)
            return normalized
        }
        return nil
    }

    public static func writeOrganizationID(_ organizationID: String) throws {
        guard let trimmed = normalizedOrganizationID(organizationID) else { return }
        try KeychainStore.writeString(service: service, account: organizationAccount, value: trimmed, useDataProtectionKeychain: true)
        try? VibeBarLocalStore.deleteFile(at: VibeBarLocalStore.claudeOrganizationIDURL)
    }

    public static func sessionKeyHeader(from header: String) -> String? {
        for pair in cookiePairs(from: header) where pair.name == "sessionKey" {
            let value = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
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
