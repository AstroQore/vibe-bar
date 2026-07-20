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
        importOrder: BrowserCookieImportOrder = BrowserCookieDefaults.importOrder,
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
        importOrder: BrowserCookieImportOrder = BrowserCookieDefaults.importOrder,
        detection: BrowserDetection = BrowserDetection(),
        client: BrowserCookieClient = BrowserCookieClient(),
        logger: ((String) -> Void)? = nil
    ) -> Result? {
        let candidates = importOrder.cookieImportCandidates(
            using: detection,
            allowKeychainPrompt: allowKeychainPrompt
        )
        guard !candidates.isEmpty else { return nil }

        let query = BrowserCookieQuery(domains: cookieDomains)

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
                guard let header = sessionHeader(from: store.records) else { continue }
                let label = "\(browser.displayName) (\(store.store.profile.name))"
                return Result(
                    header: header,
                    sourceLabel: label,
                    cookieCount: store.records.count
                )
            }
        }
        return nil
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
