import Foundation

/// Storage for the minimum Gemini web session cookie set imported from a
/// signed-in browser.
///
/// Vibe Bar does not expose a WKWebView login flow for Gemini (user
/// decision: cookie-import-only). The `webView` cookie source is kept
/// in the API surface for parity with `ClaudeWebCookieStore` and for
/// possible future use, but no code path currently writes to it.
///
/// Cookies are stored in the user's Keychain via `SecureCookieHeaderStore`
/// under the `gemini` provider namespace. Nothing is persisted to
/// `~/.vibebar/`.
///
/// The set of cookies that are kept after `minimizedCookieHeader(from:)`
/// runs is intentionally conservative for now: until the spike against
/// `gemini.google.com/usage` confirms the exact authentication contract,
/// the store keeps every `__Secure-1PSID*` cookie plus the Google SAPISID
/// family. Spike outcomes that prove a smaller set is sufficient should
/// shrink `keptCookieNamePrefixes` accordingly and document why each
/// remaining cookie is required.
public enum GeminiWebCookieStore {
    public enum CookieSource: Sendable {
        case webView
        case browser
        case legacy
    }

    /// Cookie names kept by the minimization step. The list is a
    /// superset of what is likely to be required — the spike will
    /// trim it down. Any cookie *not* in this list is dropped before
    /// the header reaches the Keychain.
    static let keptCookieNames: Set<String> = [
        "__Secure-1PSID",
        "__Secure-1PSIDTS",
        "__Secure-1PSIDCC",
        "__Secure-3PSID",
        "__Secure-3PSIDTS",
        "__Secure-3PSIDCC",
        "SID",
        "HSID",
        "SSID",
        "APISID",
        "SAPISID"
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
            provider: .gemini,
            source: secureSource(for: source)
        )
    }

    public static func hasCookieHeader() -> Bool {
        (try? readCookieHeader()) != nil
    }

    public static func deleteCookieHeader() throws {
        try SecureCookieHeaderStore.deleteAll(provider: .gemini)
    }

    public static func storageState(source: CookieSource) -> SecureCookieHeaderStore.LoadResult {
        SecureCookieHeaderStore.load(
            provider: .gemini,
            source: secureSource(for: source)
        )
    }

    public static func minimizedCookieHeader(from raw: String) -> String? {
        let pairs = cookiePairs(from: raw)
        let kept = pairs.filter { keptCookieNames.contains($0.name) }
        // The authoritative auth cookie is `__Secure-1PSID`. Without it
        // there is no point storing the rest — bail and signal "no
        // credential" to callers.
        guard kept.contains(where: { $0.name == "__Secure-1PSID" && !$0.value.isEmpty }) else {
            return nil
        }
        // De-duplicate by cookie name (keeping the first occurrence).
        // GeminiBrowserCookieImporter queries both `gemini.google.com`
        // and `.google.com` in a single cookie scan, and Chrome's cookie
        // store returns the same `.google.com`-scoped cookie once per
        // matching domain. The unfiltered output therefore contains 2-3
        // copies of every SID-family cookie, and shipping that as a
        // single `Cookie:` header trips Google's `CookieMismatch`
        // protection (HTTP 302 → accounts.google.com/CookieMismatch
        // before any quota request lands). Folding to one value per
        // name restores the canonical browser-sent shape.
        var deduped: [(name: String, value: String)] = []
        var seenNames: Set<String> = []
        for pair in kept where seenNames.insert(pair.name).inserted {
            deduped.append(pair)
        }
        let header = deduped.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
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
        switch SecureCookieHeaderStore.load(provider: .gemini, source: secureSource(for: source)) {
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
