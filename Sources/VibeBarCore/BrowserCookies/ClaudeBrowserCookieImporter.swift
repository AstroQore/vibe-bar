import Foundation
import SweetCookieKit

/// Imports the minimum Claude web session cookie from the user's
/// installed browsers. This is the reliable fallback for the Claude
/// card when the in-app WebView login flow hits SSO / blank-page
/// trouble.
public enum ClaudeBrowserCookieImporter {
    public struct Result: Sendable {
        public let header: String
        public let sourceLabel: String
        public let cookieCount: Int
    }

    public static let cookieDomains = ["claude.ai"]

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
        try ClaudeWebCookieStore.writeCookieHeader(result.header)
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
                logger?("\(browser.displayName) Claude cookie import failed: \(SafeLog.sanitize(error.localizedDescription))")
                continue
            }

            for store in stores {
                let pairs = store.records.map { record in
                    (name: record.name, value: record.value)
                }
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

    public static func sessionHeader(from cookies: [(name: String, value: String)]) -> String? {
        for cookie in cookies where cookie.name == "sessionKey" {
            let value = cookie.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.hasPrefix("sk-ant-") else { continue }
            return ClaudeWebCookieStore.minimizedCookieHeader(from: "sessionKey=\(value)")
        }
        return nil
    }
}
