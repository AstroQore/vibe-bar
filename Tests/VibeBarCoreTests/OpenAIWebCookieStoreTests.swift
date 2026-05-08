import XCTest
@testable import VibeBarCore

final class OpenAIWebCookieStoreTests: XCTestCase {
    func testCookieHeaderKeepsChatGPTSessionCookies() {
        let header = OpenAIWebCookieStore.cookieHeader(from: [
            (name: "__Secure-next-auth.session-token", value: "session"),
            (name: "oai-did", value: "device")
        ])

        XCTAssertEqual(header, "__Secure-next-auth.session-token=session; oai-did=device")
    }

    func testCookieHeaderReturnsNilWithoutUsefulCookies() {
        XCTAssertNil(OpenAIWebCookieStore.cookieHeader(from: [
            (name: "unrelated", value: "value")
        ]))
    }

    func testStoredHeadersUseBrowserBeforeWebView() throws {
        try SecureCookieHeaderStore.withInMemoryStoreForTesting {
            try OpenAIWebCookieStore.writeCookieHeader(
                "__Secure-next-auth.session-token=webview",
                source: .webView
            )
            try OpenAIWebCookieStore.writeCookieHeader(
                "__Secure-next-auth.session-token=browser",
                source: .browser
            )

            XCTAssertEqual(
                try OpenAIWebCookieStore.readCookieHeader(source: .browser),
                "__Secure-next-auth.session-token=browser"
            )
            XCTAssertEqual(
                OpenAIWebCookieStore.candidateCookieHeaders(),
                [
                    "__Secure-next-auth.session-token=browser",
                    "__Secure-next-auth.session-token=webview"
                ]
            )
        }
    }
}
