import SweetCookieKit
import XCTest
@testable import VibeBarCore

final class ClaudeBrowserCookieImporterTests: XCTestCase {
    func testSessionHeaderExtractsOnlySessionKey() {
        let header = ClaudeBrowserCookieImporter.sessionHeader(from: [
            (name: "other", value: "ignored"),
            (name: "sessionKey", value: "sk-ant-test")
        ])

        XCTAssertEqual(header, "sessionKey=sk-ant-test")
    }

    func testSessionHeaderReturnsNilWithoutSessionKey() {
        XCTAssertNil(ClaudeBrowserCookieImporter.sessionHeader(from: [
            (name: "sessionKeyLC", value: "1"),
            (name: "cf_clearance", value: "not-auth")
        ]))
    }

    func testSessionHeaderRejectsNonClaudeSessionKey() {
        XCTAssertNil(ClaudeBrowserCookieImporter.sessionHeader(from: [
            (name: "sessionKey", value: "not-a-claude-session")
        ]))
    }

    func testDeviceBoundStoreIsImportedOnlyWithALiveBindingCookie() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func record(_ name: String, _ value: String, expiresIn seconds: TimeInterval) -> BrowserCookieRecord {
            BrowserCookieRecord(domain: "claude.ai", name: name, path: "/", value: value,
                                expires: now.addingTimeInterval(seconds), isSecure: true, isHTTPOnly: true)
        }
        let key = record("sessionKey", "sk-ant-test", expiresIn: 86_400)

        // An unbound store (Safari, Firefox, the in-app sign-in) needs nothing else.
        XCTAssertEqual(ClaudeBrowserCookieImporter.sessionHeader(from: [key], now: now), "sessionKey=sk-ant-test")
        // Chrome: the binding cookie travels with the key while it is alive.
        XCTAssertEqual(
            ClaudeBrowserCookieImporter.sessionHeader(
                from: [key, record("__Host-sessionBinding", "bind", expiresIn: -5),
                       record("__Host-sessionBindingGrace", "grace", expiresIn: 300)],
                now: now
            ),
            "sessionKey=sk-ant-test; __Host-sessionBindingGrace=grace"
        )
        // Once every binding cookie has lapsed the key alone is rejected, so
        // the store contributes nothing.
        XCTAssertNil(ClaudeBrowserCookieImporter.sessionHeader(
            from: [key, record("__Host-sessionBinding", "bind", expiresIn: -5)], now: now
        ))
    }
}

final class BrowserRequestHeadersTests: XCTestCase {
    func testCookieSessionRequestsCarryABrowserIdentity() {
        var request = URLRequest(url: URL(string: "https://claude.ai/api/organizations")!)
        BrowserRequestHeaders.applySameOriginFetch(to: &request, referer: "https://claude.ai/")
        let agent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
        XCTAssertNotNil(agent.range(of: #"Chrome/\d+\.0\.0\.0 Safari/537\.36$"#, options: .regularExpression))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-Fetch-Site"), "same-origin")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://claude.ai/")
        XCTAssertEqual(BrowserRequestHeaders.chromeUserAgent(major: "158"),
                       "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/158.0.0.0 Safari/537.36")
    }
}
