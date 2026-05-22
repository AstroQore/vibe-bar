import Foundation

/// Storage for the grok.com web session cookies imported from a
/// signed-in browser. Mirrors `GeminiWebCookieStore`: cookies live in
/// the user's Keychain via `SecureCookieHeaderStore` under the `grok`
/// provider namespace; nothing is persisted to `~/.vibebar/`.
///
/// The minimisation step keeps `sso`, `sso-rw`, and the
/// `cf_clearance` cookie that Cloudflare's challenge-passed gate
/// stamps on the grok.com origin. xAI's gRPC-web billing endpoint
/// rejects requests that don't carry the Cloudflare cookie even when
/// the bearer / session pair is valid, so dropping it silently breaks
/// the fetcher.
///
/// At least one of `sso` / `sso-rw` must be present; otherwise the
/// browser is treated as "signed out for grok.com" and the
/// minimisation returns `nil` so the caller can surface a "no
/// credentials" state.
public enum GrokWebCookieStore {
    public enum CookieSource: Sendable {
        case webView
        case browser
        case legacy
    }

    /// Cookie names kept by the minimisation step. Anything outside
    /// this list is dropped before the header reaches the Keychain.
    /// The Cloudflare clearance cookie is required for grok.com's
    /// gRPC-web gate to let the request through, so it stays even
    /// though it's not strictly an auth cookie.
    static let keptCookieNames: Set<String> = [
        "sso",
        "sso-rw",
        "cf_clearance"
    ]

    /// The two cookies that actually authenticate the session. At
    /// least one of these has to land in the minimised header for the
    /// browser session to count as "signed in to grok.com".
    static let authCookieNames: Set<String> = [
        "sso",
        "sso-rw"
    ]

    public static func readCookieHeader() throws -> String {
        if let header = candidateCookieHeaders().first {
            return header
        }
        throw QuotaError.noCredential
    }

    public static func readCookieHeader(source: CookieSource) throws -> String {
        if let header = storedCookieHeader(source: source) {
            return header
        }
        throw QuotaError.noCredential
    }

    public static func candidateCookieHeaders() -> [String] {
        var headers: [String] = []
        appendStoredCookieHeader(source: .browser, to: &headers)
        appendStoredCookieHeader(source: .webView, to: &headers)
        return unique(headers)
    }

    public static func writeCookieHeader(_ header: String, source: CookieSource = .legacy) throws {
        guard let minimized = minimizedCookieHeader(from: header) else { throw QuotaError.noCredential }
        try SecureCookieHeaderStore.store(
            minimized,
            provider: .grok,
            source: secureSource(for: source)
        )
    }

    public static func hasCookieHeader() -> Bool {
        (try? readCookieHeader()) != nil
    }

    public static func deleteCookieHeader() throws {
        try SecureCookieHeaderStore.deleteAll(provider: .grok)
    }

    public static func storageState(source: CookieSource) -> SecureCookieHeaderStore.LoadResult {
        SecureCookieHeaderStore.load(
            provider: .grok,
            source: secureSource(for: source)
        )
    }

    public static func minimizedCookieHeader(from raw: String) -> String? {
        let pairs = cookiePairs(from: raw)
        let kept = pairs.filter { keptCookieNames.contains($0.name) }
        // Require at least one of the auth cookies. Without them the
        // header carries no useful session and the fetcher's first call
        // would just bounce off Cloudflare or grok.com's auth gate.
        guard kept.contains(where: { authCookieNames.contains($0.name) && !$0.value.isEmpty }) else {
            return nil
        }
        let header = kept.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return header.isEmpty ? nil : header
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

    private static func appendStoredCookieHeader(source: CookieSource, to headers: inout [String]) {
        guard let raw = storedCookieHeader(source: source) else { return }
        headers.append(raw)
    }

    private static func storedCookieHeader(source: CookieSource) -> String? {
        switch SecureCookieHeaderStore.load(provider: .grok, source: secureSource(for: source)) {
        case .found(let raw):
            return minimizedCookieHeader(from: raw)
        case .missing, .temporarilyUnavailable, .invalid:
            return nil
        }
    }

    private static func secureSource(for source: CookieSource) -> SecureCookieHeaderStore.Source {
        switch source {
        case .webView, .legacy: return .webView
        case .browser: return .browser
        }
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
