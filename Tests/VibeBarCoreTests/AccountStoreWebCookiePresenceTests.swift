import XCTest
@testable import VibeBarCore

@MainActor
final class AccountStoreWebCookiePresenceTests: XCTestCase {
    func testExplicitWebCookiePresenceRegistersWebOnlyAccounts() {
        let accounts = AccountStore(
            claudeUsageMode: .webOnly,
            geminiUsageMode: .webOnly,
            miscProviderInstances: [],
            webCookiePresence: AccountStore.WebCookiePresence(
                openAI: false,
                claude: true,
                gemini: true,
                grok: false
            )
        )

        XCTAssertEqual(accounts.accounts(for: .claude).map(\.id), ["web-claude"])
        XCTAssertEqual(accounts.accounts(for: .gemini).map(\.id), ["web-gemini"])
    }

    func testExplicitEmptyWebCookiePresenceSuppressesWebOnlyAccounts() {
        let accounts = AccountStore(
            claudeUsageMode: .webOnly,
            geminiUsageMode: .webOnly,
            miscProviderInstances: [],
            webCookiePresence: AccountStore.WebCookiePresence.none
        )

        XCTAssertTrue(accounts.accounts(for: .claude).isEmpty)
        XCTAssertTrue(accounts.accounts(for: .gemini).isEmpty)
    }
}
