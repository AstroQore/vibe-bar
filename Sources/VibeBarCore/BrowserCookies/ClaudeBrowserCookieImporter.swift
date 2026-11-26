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
        try ClaudeWebCookieStore.writeCookieHeader(result.header, source: .browser)
        return result
    }

    public static func importFromBrowsers(
        allowKeychainPrompt: Bool = false,
        importOrder: BrowserCookieImportOrder = BrowserCookieImportPreference.order,
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
                guard let header = sessionHeader(from: store.records, now: Date()) else { continue }
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

    /// The header one browser store can contribute right now.
    ///
    /// claude.ai binds a Chrome session to the device (Device Bound Session
    /// Credentials): the session key is only honoured next to a
    /// `__Host-sessionBinding` cookie that Chrome re-signs every few minutes
    /// with a key that never leaves the browser. A bound store is therefore
    /// usable only while one of those cookies is still inside its lifetime;
    /// the header carries it, and the next refresh imports a newer one.
    public static func sessionHeader(from records: [BrowserCookieRecord], now: Date) -> String? {
        var pairs = records.filter { $0.name == "sessionKey" }.map { (name: $0.name, value: $0.value) }
        guard let sessionKey = sessionHeader(from: pairs) else { return nil }
        let bindingNames = ClaudeWebCookieStore.sessionBindingCookieNames
        let binding = records.filter { bindingNames.contains($0.name) }
        guard !binding.isEmpty else { return sessionKey }
        pairs = binding
            .filter { ($0.expires ?? .distantPast) > now && !$0.value.isEmpty }
            .map { (name: $0.name, value: $0.value) }
        guard !pairs.isEmpty else { return nil }
        return ClaudeWebCookieStore.minimizedCookieHeader(
            from: ([sessionKey] + pairs.map { "\($0.name)=\($0.value)" }).joined(separator: "; ")
        )
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
