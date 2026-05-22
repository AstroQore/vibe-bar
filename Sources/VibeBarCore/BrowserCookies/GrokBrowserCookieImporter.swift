import Foundation
import SweetCookieKit

/// Imports the minimum grok.com web session cookie set from the
/// user's installed browsers. Mirrors `GeminiBrowserCookieImporter`:
/// queries every browser profile via SweetCookieKit, then funnels the
/// raw name/value pairs through `GrokWebCookieStore.minimizedCookieHeader`
/// before persisting to Keychain.
///
/// Codex Bar's importer accepts a session as soon as it sees `sso` or
/// `sso-rw`; we apply the same gate here so Vibe Bar and Codex Bar
/// recognise the same browser session as "signed in to grok.com".
public enum GrokBrowserCookieImporter {
    public struct Result: Sendable {
        public let header: String
        public let sourceLabel: String
        public let cookieCount: Int
    }

    public static let cookieDomains = ["grok.com"]

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
        try GrokWebCookieStore.writeCookieHeader(result.header, source: .browser)
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
                logger?("\(browser.displayName) Grok cookie import failed: \(SafeLog.sanitize(error.localizedDescription))")
                continue
            }

            for store in stores {
                let pairs = store.records.map { (name: $0.name, value: $0.value) }
                guard let header = sessionHeader(from: pairs) else { continue }
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
    /// pairs. The kept-list and auth-cookie gate live in
    /// `GrokWebCookieStore` so this importer stays a thin shim.
    public static func sessionHeader(from cookies: [(name: String, value: String)]) -> String? {
        let raw = cookies
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        return GrokWebCookieStore.minimizedCookieHeader(from: raw)
    }
}
