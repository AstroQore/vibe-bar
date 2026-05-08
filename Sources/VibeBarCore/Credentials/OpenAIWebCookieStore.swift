import Foundation

public enum OpenAIWebCookieStore {
    public enum CookieSource: Sendable, CaseIterable {
        case webView
        case browser
    }

    private static let usefulCookieNames: Set<String> = [
        "__Secure-next-auth.session-token",
        "__Host-next-auth.csrf-token",
        "oai-did",
        "oai-nav-state",
        "cf_clearance",
        "__cf_bm",
        "_cfuvid"
    ]

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

    public static func writeCookieHeader(_ header: String, source: CookieSource) throws {
        guard let normalized = normalizedCookieHeader(from: header) else { throw QuotaError.noCredential }
        try SecureCookieHeaderStore.store(
            normalized,
            provider: .openAI,
            source: secureSource(for: source)
        )
        try? VibeBarLocalStore.deleteFile(at: legacyURL(for: source))
    }

    public static func hasCookieHeader() -> Bool {
        !candidateCookieHeaders().isEmpty
    }

    public static func deleteCookieHeader() throws {
        try SecureCookieHeaderStore.deleteAll(provider: .openAI)
        try VibeBarLocalStore.deleteFile(at: VibeBarLocalStore.openAIWebViewCookieURL)
        try VibeBarLocalStore.deleteFile(at: VibeBarLocalStore.openAIBrowserCookieURL)
    }

    public static func storageState(source: CookieSource) -> SecureCookieHeaderStore.LoadResult {
        migrateLegacyPlaintextCookiesIfNeeded()
        return SecureCookieHeaderStore.load(
            provider: .openAI,
            source: secureSource(for: source)
        )
    }

    public static func normalizedCookieHeader(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withoutPrefix = trimmed.localizedCaseInsensitiveContains("Cookie:")
            ? trimmed.replacingOccurrences(of: "Cookie:", with: "", options: [.caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmed
        return cookieHeader(from: cookiePairs(from: withoutPrefix))
    }

    public static func cookieHeader(from cookies: [(name: String, value: String)]) -> String? {
        let parts = cookies.compactMap { cookie -> String? in
            let name = cookie.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = cookie.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty, usefulCookieNames.contains(name) else { return nil }
            return "\(name)=\(value)"
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "; ")
    }

    private static func appendStoredCookieHeader(source: CookieSource, to headers: inout [String]) {
        guard let header = storedCookieHeader(source: source) else { return }
        headers.append(header)
    }

    private static func storedCookieHeader(source: CookieSource) -> String? {
        switch SecureCookieHeaderStore.load(provider: .openAI, source: secureSource(for: source)) {
        case .found(let raw):
            return normalizedCookieHeader(from: raw)
        case .missing, .temporarilyUnavailable, .invalid:
            return nil
        }
    }

    private static func migrateLegacyPlaintextCookiesIfNeeded() {
        for source in CookieSource.allCases {
            migrateLegacyPlaintextCookieIfNeeded(source: source)
        }
    }

    private static func migrateLegacyPlaintextCookieIfNeeded(source: CookieSource) {
        let url = legacyURL(for: source)
        guard let raw = try? VibeBarLocalStore.readString(from: url) else { return }
        defer { try? VibeBarLocalStore.deleteFile(at: url) }
        guard let header = normalizedCookieHeader(from: raw) else { return }
        try? SecureCookieHeaderStore.store(
            header,
            provider: .openAI,
            source: secureSource(for: source)
        )
    }

    private static func secureSource(for source: CookieSource) -> SecureCookieHeaderStore.Source {
        switch source {
        case .webView: return .webView
        case .browser: return .browser
        }
    }

    private static func legacyURL(for source: CookieSource) -> URL {
        switch source {
        case .webView: return VibeBarLocalStore.openAIWebViewCookieURL
        case .browser: return VibeBarLocalStore.openAIBrowserCookieURL
        }
    }

    private static func cookiePairs(from header: String) -> [(name: String, value: String)] {
        header
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
