import XCTest
@testable import VibeBarCore

final class BrowserCredentialSourceTests: XCTestCase {
    private let credential = ChromiumLocalStorageCredential(
        origin: "https://example.com",
        key: "access_token",
        syntheticCookieName: "session-token",
        valueFormat: .jwt(segments: 3, minLength: 16, maxLength: 4_096)
    )

    func testJWTValueBecomesCookieShapedHeader() {
        let token = "synthetic-header.synthetic_payload.synthetic-signature"
        XCTAssertEqual(
            credential.cookieHeader(from: "  \(token)\n"),
            "session-token=\(token)"
        )
    }

    func testJWTValidationRejectsMalformedOrInjectableValues() {
        XCTAssertNil(credential.cookieHeader(from: "not-a-jwt"))
        XCTAssertNil(credential.cookieHeader(from: "aaa..ccc"))
        XCTAssertNil(credential.cookieHeader(from: "aaa.bbb.ccc;other=value"))
        XCTAssertNil(credential.cookieHeader(from: "aaa.bbb.ccc\r\nInjected:value"))
        XCTAssertNil(credential.cookieHeader(from: "aaa.bébé.ccc"))
        XCTAssertNil(credential.cookieHeader(
            from: "aaa.\(String(repeating: "b", count: 4_100)).ccc"
        ))
    }

    func testOpaqueValueStillRejectsHeaderSeparatorsAndControls() {
        let opaque = ChromiumLocalStorageCredential(
            origin: "https://example.com",
            key: "session",
            syntheticCookieName: "session",
            valueFormat: .opaque(minLength: 3, maxLength: 20)
        )

        XCTAssertEqual(opaque.cookieHeader(from: "abc=123"), "session=abc=123")
        XCTAssertNil(opaque.cookieHeader(from: "abc;other=value"))
        XCTAssertNil(opaque.cookieHeader(from: "abc\nvalue"))
    }

    func testInvalidSyntheticCookieNameIsRejected() {
        let invalid = ChromiumLocalStorageCredential(
            origin: "https://example.com",
            key: "access_token",
            syntheticCookieName: "bad name",
            valueFormat: .opaque(minLength: 1, maxLength: 20)
        )
        XCTAssertNil(invalid.cookieHeader(from: "value"))
    }

    func testCompositeSourceDetectsAnOlderIncompleteHeader() {
        let source = BrowserCredentialSource.chromiumLocalStorageFields([
            credential,
            ChromiumLocalStorageCredential(
                origin: "https://example.com",
                key: "refresh_token",
                syntheticCookieName: "refresh-token",
                valueFormat: .jwt(segments: 3, minLength: 16, maxLength: 4_096)
            )
        ])

        XCTAssertFalse(source.hasCompleteBrowserCredential(
            in: "session-token=synthetic.header.signature"
        ))
        XCTAssertTrue(source.hasCompleteBrowserCredential(
            in: "session-token=synthetic.header.signature; refresh-token=refresh.header.signature"
        ))
    }
}
