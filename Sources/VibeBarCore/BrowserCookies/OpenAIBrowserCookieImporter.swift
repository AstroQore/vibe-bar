import Foundation
import SweetCookieKit

public enum OpenAIBrowserCookieImporter {
    public struct Result: Sendable {
        public let header: String
        public let sourceLabel: String
        public let cookieCount: Int
    }

    public static let cookieDomains = ["chatgpt.com", "chat.openai.com", "openai.com"]

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
        try OpenAIWebCookieStore.writeCookieHeader(result.header, source: .browser)
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
                logger?("\(browser.displayName) OpenAI cookie import failed: \(SafeLog.sanitize(error.localizedDescription))")
                continue
            }

            for store in stores {
                let pairs = store.records.map { record in
                    (name: record.name, value: record.value)
                }
                guard let header = OpenAIWebCookieStore.cookieHeader(from: pairs) else { continue }
                let label = "\(browser.displayName) (\(store.store.profile.name))"
                return Result(header: header, sourceLabel: label, cookieCount: store.records.count)
            }
        }

        return nil
    }
}
