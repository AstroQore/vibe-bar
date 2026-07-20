import SweetCookieKit
import XCTest
@testable import VibeBarCore

/// Locks the cookie minimisation contract — the importer leans on
/// `GeminiWebCookieStore.minimizedCookieHeader(from:)` to drop
/// analytics cookies and require the authoritative `__Secure-1PSID`.
final class GeminiWebCookieStoreTests: XCTestCase {
    func testMinimizedHeaderKeepsAuthCookies() {
        let raw = "_ga=GA1.example; __Secure-1PSID=abc.synthetic-jwt; SAPISID=def-token; SIDCC=sidcc; __Secure-1PAPISID=papi1; __Secure-3PAPISID=papi3; pref=light"
        let minimized = GeminiWebCookieStore.minimizedCookieHeader(from: raw)
        XCTAssertNotNil(minimized)
        XCTAssertTrue(minimized!.contains("__Secure-1PSID=abc.synthetic-jwt"))
        XCTAssertTrue(minimized!.contains("SAPISID=def-token"))
        XCTAssertTrue(minimized!.contains("SIDCC=sidcc"))
        XCTAssertTrue(minimized!.contains("__Secure-1PAPISID=papi1"))
        XCTAssertTrue(minimized!.contains("__Secure-3PAPISID=papi3"))
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

    func testBrowserImporterUsesMostSpecificMatchingCookieRecord() throws {
        let records = [
            record(domain: "google.com", name: "__Secure-1PSID", path: "/", value: "parent"),
            record(domain: "gemini.google.com", name: "__Secure-1PSID", path: "/", value: "host"),
            record(domain: "google.com", name: "SIDCC", path: "/", value: "sidcc"),
            record(domain: "google.com", name: "__Secure-1PAPISID", path: "/", value: "papi1"),
            record(domain: "google.com", name: "__Secure-3PAPISID", path: "/", value: "papi3"),
            record(domain: "other.google.com", name: "SAPISID", path: "/", value: "wrong-host"),
            record(domain: "gemini.google.com", name: "SSID", path: "/other", value: "wrong-path")
        ]

        let header = try XCTUnwrap(GeminiBrowserCookieImporter.sessionHeader(from: records))
        XCTAssertTrue(header.contains("__Secure-1PSID=host"))
        XCTAssertFalse(header.contains("__Secure-1PSID=parent"))
        XCTAssertTrue(header.contains("SIDCC=sidcc"))
        XCTAssertTrue(header.contains("__Secure-1PAPISID=papi1"))
        XCTAssertTrue(header.contains("__Secure-3PAPISID=papi3"))
        XCTAssertFalse(header.contains("wrong-host"))
        XCTAssertFalse(header.contains("wrong-path"))
    }

    private func record(
        domain: String,
        name: String,
        path: String,
        value: String
    ) -> BrowserCookieRecord {
        BrowserCookieRecord(
            domain: domain,
            name: name,
            path: path,
            value: value,
            expires: nil,
            isSecure: true,
            isHTTPOnly: true
        )
    }
}
