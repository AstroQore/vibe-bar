import Foundation
import SweetCookieKit

/// Imports the minimum Gemini web session cookie set from the user's
/// installed browsers. Vibe Bar does not offer a WKWebView login flow
/// for Gemini (user decision: cookie-import-only), so this importer is
/// the sole on-ramp for the Gemini web credential source.
///
/// Cookies live on `gemini.google.com` and on the parent `.google.com`
/// domain (the `__Secure-1PSID*` family lives on the parent so a single
/// Google login covers Gemini, Antigravity, AI Studio, and other
/// Google AI products). Both domains are queried; the resulting cookie
/// jar is then minimised through `GeminiWebCookieStore` to drop
/// analytics / preference cookies before the header reaches the
/// Keychain.
public enum GeminiBrowserCookieImporter {
    public struct Result: Sendable {
        public let header: String
        public let sourceLabel: String
        public let cookieCount: Int
    }

    public static let cookieDomains = ["gemini.google.com", ".google.com"]

    public static func importAndStoreFromBrowsers(
        allowKeychainPrompt: Bool = false,
        importOrder: BrowserCookieImportOrder = BrowserCookieImportPreference.order,
        detection: BrowserDetection = BrowserDetection(),
        client: BrowserCookieClient = BrowserCookieClient(),
        logger: ((String) -> Void)? = nil
    ) throws -> Result? {
        guard let result = importFromBrowsers(
            allowKeychainPrompt: allowKeychainPrompt,
            importOrder: importOrder,
            detection: detection,
            client: client,
            logger: logger
        ) else {
            return nil
        }
        try GeminiWebCookieStore.writeCookieHeader(result.header, source: .browser)
        return result
    }

    public static func importFromBrowsers(
        allowKeychainPrompt: Bool = false,
        importOrder: BrowserCookieImportOrder = BrowserCookieImportPreference.order,
        detection: BrowserDetection = BrowserDetection(),
        client: BrowserCookieClient = BrowserCookieClient(),
        logger: ((String) -> Void)? = nil
    ) -> Result? {
        importCandidatesFromBrowsers(
            allowKeychainPrompt: allowKeychainPrompt,
            importOrder: importOrder,
            detection: detection,
            client: client,
            logger: logger
        ).first
    }

    /// Every distinct Gemini session header the readable browser stores
    /// hold, in import order. A Mac routinely carries more than one Google
    /// session — a second browser, an old Chrome profile — and the first
    /// store in catalogue order is not necessarily the one still signed in,
    /// so callers that can test a header against the live endpoint walk
    /// this list instead of trusting `importFromBrowsers`' single answer.
    public static func importCandidatesFromBrowsers(
        allowKeychainPrompt: Bool = false,
        importOrder: BrowserCookieImportOrder = BrowserCookieImportPreference.order,
        detection: BrowserDetection = BrowserDetection(),
        client: BrowserCookieClient = BrowserCookieClient(),
        logger: ((String) -> Void)? = nil
    ) -> [Result] {
        let candidates = importOrder.cookieImportCandidates(
            using: detection,
            allowKeychainPrompt: allowKeychainPrompt
        )
        guard !candidates.isEmpty else { return [] }

        let query = BrowserCookieQuery(domains: cookieDomains)
        var results: [Result] = []
        var seenHeaders: Set<String> = []

        for browser in candidates {
            let stores: [BrowserCookieStoreRecords]
            do {
                stores = try client.vibeBarRecords(
                    matching: query,
                    in: browser,
                    allowKeychainPrompt: allowKeychainPrompt,
                    logger: logger
                )
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                logger?("\(browser.displayName) Gemini cookie import failed: \(SafeLog.sanitize(error.localizedDescription))")
                continue
            }

            for store in stores {
                guard let header = sessionHeader(from: store.records),
                      seenHeaders.insert(header).inserted else { continue }
                let label = "\(browser.displayName) (\(store.store.profile.name))"
                results.append(Result(
                    header: header,
                    sourceLabel: label,
                    cookieCount: store.records.count
                ))
            }
        }
        return results
    }

    /// True only when gemini.google.com turned `header` away as logged out.
    public static func liveEndpointReportsSignedOut(_ header: String) async -> Bool {
        await GeminiWebQuotaFetcher.isSignedOut(cookieHeader: header)
    }

    /// Manual-import path: store the first candidate the live endpoint
    /// accepts. `isSignedOut` answers whether a header was turned away as
    /// logged out; any other outcome (success, network trouble, a rotated
    /// RPC) leaves the header eligible, because none of those say the
    /// session is dead. When every candidate is signed out the first one is
    /// still stored so the account exists and surfaces its login error.
    public static func importValidatedAndStoreFromBrowsers(
        allowKeychainPrompt: Bool = false,
        isSignedOut: @Sendable (String) async -> Bool = { header in
            await GeminiBrowserCookieImporter.liveEndpointReportsSignedOut(header)
        },
        candidates: (@Sendable () -> [Result])? = nil,
        store: @Sendable (String) throws -> Void = { header in
            try GeminiWebCookieStore.writeCookieHeader(header, source: .browser)
        }
    ) async throws -> Result? {
        let found = candidates?()
            ?? importCandidatesFromBrowsers(allowKeychainPrompt: allowKeychainPrompt)
        guard let first = found.first else { return nil }
        var chosen = first
        for candidate in found {
            if await !isSignedOut(candidate.header) {
                chosen = candidate
                break
            }
        }
        try store(chosen.header)
        return chosen
    }

    /// Builds a minimised Cookie header from a flat list of name/value
    /// pairs. The minimisation rule lives in `GeminiWebCookieStore` so
    /// the importer stays a thin shim — when the spike (plan §9)
    /// finalises the required cookie set, only the store needs updating.
    public static func sessionHeader(from cookies: [(name: String, value: String)]) -> String? {
        let raw = cookies
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        return GeminiWebCookieStore.minimizedCookieHeader(from: raw)
    }

    /// Builds the exact Cookie header a browser would send to Gemini's Usage
    /// page. A flat name/value projection is not sufficient because Chrome
    /// may contain the same cookie name for the host, parent domain, and
    /// multiple paths. Choosing the most-specific matching record first is
    /// what made the live Web quota request authenticate reliably.
    static func sessionHeader(
        from records: [BrowserCookieRecord],
        host: String = "gemini.google.com",
        path: String = "/usage"
    ) -> String? {
        let matching = records.filter { record in
            let domain = record.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let cookiePath = record.path.isEmpty ? "/" : record.path
            return (host == domain || host.hasSuffix(".\(domain)"))
                && path.hasPrefix(cookiePath)
                && !record.value.isEmpty
        }
        let ordered = matching.sorted { lhs, rhs in
            let lhsPath = lhs.path.isEmpty ? "/" : lhs.path
            let rhsPath = rhs.path.isEmpty ? "/" : rhs.path
            if lhsPath.count != rhsPath.count { return lhsPath.count > rhsPath.count }
            if lhs.domain.count != rhs.domain.count { return lhs.domain.count > rhs.domain.count }
            return lhs.name < rhs.name
        }

        var names: Set<String> = []
        let pairs = ordered.compactMap { record -> (name: String, value: String)? in
            guard names.insert(record.name).inserted else { return nil }
            return (record.name, record.value)
        }
        return sessionHeader(from: pairs)
    }
}
