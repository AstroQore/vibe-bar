import XCTest
@testable import VibeBarCore

/// Locks the cookie minimisation contract — the importer leans on
/// `GeminiWebCookieStore.minimizedCookieHeader(from:)` to drop
/// analytics cookies and require the authoritative `__Secure-1PSID`.
final class GeminiWebCookieStoreTests: XCTestCase {
    func testMinimizedHeaderKeepsAuthCookies() {
        let raw = "_ga=GA1.example; __Secure-1PSID=abc.synthetic-jwt; SAPISID=def-token; pref=light"
        let minimized = GeminiWebCookieStore.minimizedCookieHeader(from: raw)
        XCTAssertNotNil(minimized)
        XCTAssertTrue(minimized!.contains("__Secure-1PSID=abc.synthetic-jwt"))
        XCTAssertTrue(minimized!.contains("SAPISID=def-token"))
        XCTAssertFalse(minimized!.contains("_ga"))
        XCTAssertFalse(minimized!.contains("pref="))
    }

    func testMinimizedHeaderRequiresPSID() {
        // Without `__Secure-1PSID` the rest of the cookie set is
        // useless for the usage RPCs — the helper must bail out.
        let raw = "SAPISID=def-token; HSID=ghi; SSID=jkl"
        let minimized = GeminiWebCookieStore.minimizedCookieHeader(from: raw)
        XCTAssertNil(minimized)
    }

    func testMinimizedHeaderRejectsBlankPSID() {
        let raw = "__Secure-1PSID=; SAPISID=def-token"
        let minimized = GeminiWebCookieStore.minimizedCookieHeader(from: raw)
        XCTAssertNil(minimized)
    }

    func testNormalizedHeaderStripsCookiePrefix() {
        let raw = "Cookie: __Secure-1PSID=abc; SAPISID=def"
        let normalized = GeminiWebCookieStore.normalizedCookieHeader(from: raw)
        XCTAssertEqual(normalized, "__Secure-1PSID=abc; SAPISID=def")
    }
}
