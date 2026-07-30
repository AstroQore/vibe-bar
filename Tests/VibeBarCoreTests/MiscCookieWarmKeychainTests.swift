import XCTest
@testable import VibeBarCore
import SweetCookieKit

/// The silent re-import path has to reach browsers whose Safe Storage key
/// SweetCookieKit already holds, even though `BrowserCookieAccessGate`'s
/// non-interactive preflight would veto them. These tests pin that
/// bypass so a future gate change can't quietly re-block it.
final class MiscCookieWarmKeychainTests: XCTestCase {
    /// Reports every path as present with a single `Default` profile, so
    /// `BrowserDetection` finds a usable Chromium cookie store without a
    /// browser actually being installed on the test machine.
    private func fakeDetection() -> BrowserDetection {
        BrowserDetection(
            homeDirectory: "/Users/example",
            fileExists: { _ in true },
            directoryContents: { _ in ["Default"] }
        )
    }

    override func setUp() {
        super.setUp()
        BrowserCookieAccessGate.reset()
        MiscCookieResolver.resetKeychainWarmthForTesting()
        KeychainAccessGate.isDisabled = false
    }

    override func tearDown() {
        BrowserCookieAccessGate.reset()
        MiscCookieResolver.resetKeychainWarmthForTesting()
        KeychainAccessGate.isDisabled = false
        super.tearDown()
    }

    func testCooldownBrowserIsSkippedOnASilentRead() {
        BrowserCookieAccessGate.recordDenied(for: .chrome)
        XCTAssertEqual([Browser.chrome].cookieImportCandidates(using: fakeDetection()), [])
    }

    func testWarmBrowserBypassesTheCooldownOnASilentRead() {
        BrowserCookieAccessGate.recordDenied(for: .chrome)
        let candidates = [Browser.chrome].cookieImportCandidates(
            using: fakeDetection(),
            warmKeychainBrowsers: [Browser.chrome.rawValue]
        )
        XCTAssertEqual(candidates, [.chrome])
    }

    func testWarmthOnlyTracksBrowsersThatNeedKeychainDecryption() {
        MiscCookieResolver.markKeychainWarm(.safari)
        MiscCookieResolver.markKeychainWarm(.firefox)
        XCTAssertTrue(
            MiscCookieResolver.warmKeychainBrowserIDs.isEmpty,
            "Safari / Firefox never unlock a Safe Storage key, so marking them warm is meaningless."
        )

        MiscCookieResolver.markKeychainWarm(.chrome)
        XCTAssertEqual(MiscCookieResolver.warmKeychainBrowserIDs, [Browser.chrome.rawValue])
    }

    /// Warmth is a prompt-avoidance shortcut, not a way around the user's
    /// own kill switch.
    func testGlobalKeychainKillSwitchStillWinsOverWarmth() {
        KeychainAccessGate.isDisabled = true
        let candidates = [Browser.chrome].cookieImportCandidates(
            using: fakeDetection(),
            warmKeychainBrowsers: [Browser.chrome.rawValue]
        )
        XCTAssertEqual(candidates, [])
    }
}
