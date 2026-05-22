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

    /// Locks the de-duplication fix that resolves the live "Needs
    /// re-login" bug. `GeminiBrowserCookieImporter` queries both
    /// `gemini.google.com` and `.google.com` in a single Chrome scan,
    /// so each `.google.com`-scoped cookie is returned 2-3 times.
    /// Without de-duplication the resulting header carries multiple
    /// values per name and Google's `CookieMismatch` protection
    /// 302s every quota request to `accounts.google.com/CookieMismatch`
    /// before any user code runs.
    func testMinimizedHeaderDeduplicatesByCookieName() throws {
        // Simulates the unfiltered importer output: each name appears
        // 3 times (host-only + parent-domain × 2 query passes) except
        // the rotating PSIDTS/PSIDCC family which is only ever
        // host-only on the parent and therefore appears once.
        let raw = [
            "APISID=apisid-v1", "HSID=hsid-v1", "SAPISID=sapisid-v1",
            "SID=sid-v1", "SSID=ssid-v1",
            "__Secure-1PSID=psid-v1.synthetic", "__Secure-3PSID=psid3-v1.synthetic",
            "APISID=apisid-v1", "HSID=hsid-v1", "SAPISID=sapisid-v1",
            "SID=sid-v1", "SSID=ssid-v1",
            "__Secure-1PSID=psid-v1.synthetic", "__Secure-3PSID=psid3-v1.synthetic",
            "APISID=apisid-v1", "HSID=hsid-v1", "SAPISID=sapisid-v1",
            "SID=sid-v1", "SSID=ssid-v1",
            "__Secure-1PSID=psid-v1.synthetic", "__Secure-3PSID=psid3-v1.synthetic",
            "__Secure-1PSIDTS=psidts-v1.rotating", "__Secure-3PSIDTS=psidts3-v1.rotating",
            "__Secure-1PSIDCC=psidcc-v1.rotating", "__Secure-3PSIDCC=psidcc3-v1.rotating"
        ].joined(separator: "; ")
        let minimized = try XCTUnwrap(GeminiWebCookieStore.minimizedCookieHeader(from: raw))
        let names = minimized
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1).first.map(String.init) ?? "" }
        XCTAssertEqual(names.count, Set(names).count, "Each cookie name must appear at most once in the minimised header — duplicates trigger Google CookieMismatch.")
        // Spot-check the must-have rotating cookies are still present.
        XCTAssertTrue(minimized.contains("__Secure-1PSIDTS=psidts-v1.rotating"))
        XCTAssertTrue(minimized.contains("__Secure-3PSIDTS=psidts3-v1.rotating"))
        // And the dedup keeps the first occurrence intact.
        XCTAssertTrue(minimized.contains("__Secure-1PSID=psid-v1.synthetic"))
    }

    /// If the importer's later duplicate happens to carry a fresher
    /// value (e.g. host-only PSID rotated mid-scan), the dedup still
    /// keeps the FIRST occurrence — that matches how browsers order
    /// cookies in the Cookie header (more-specific first). Locks the
    /// "first wins" tie-break in case someone later flips it to last.
    func testMinimizedHeaderDeduplicationKeepsFirstOccurrence() throws {
        let raw = "__Secure-1PSID=first.value; SAPISID=sapi; __Secure-1PSID=second.value"
        let minimized = try XCTUnwrap(GeminiWebCookieStore.minimizedCookieHeader(from: raw))
        XCTAssertTrue(minimized.contains("__Secure-1PSID=first.value"))
        XCTAssertFalse(minimized.contains("__Secure-1PSID=second.value"))
    }

    func testNormalizedHeaderStripsCookiePrefix() {
        let raw = "Cookie: __Secure-1PSID=abc; SAPISID=def"
        let normalized = GeminiWebCookieStore.normalizedCookieHeader(from: raw)
        XCTAssertEqual(normalized, "__Secure-1PSID=abc; SAPISID=def")
    }
}
