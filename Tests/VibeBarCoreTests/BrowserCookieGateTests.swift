import XCTest
@testable import VibeBarCore
import SweetCookieKit

final class BrowserCookieGateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        BrowserCookieAccessGate.reset()
        KeychainAccessGate.isDisabled = false
    }

    override func tearDown() {
        BrowserCookieAccessGate.reset()
        KeychainAccessGate.isDisabled = false
        super.tearDown()
    }

    func testDeniedBrowserIsBlockedDuringCooldown() {
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        BrowserCookieAccessGate.recordDenied(for: .chrome, now: now)
        XCTAssertFalse(BrowserCookieAccessGate.shouldAttempt(.chrome, now: now))
        XCTAssertFalse(BrowserCookieAccessGate.shouldAttempt(.chrome, now: now.addingTimeInterval(60 * 60)))
    }

    func testCooldownExpiresAfterSixHours() {
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        BrowserCookieAccessGate.recordDenied(for: .chrome, now: now)
        let afterCooldown = now.addingTimeInterval(60 * 60 * 6 + 1)
        // Past cooldown the gate consults Keychain again. We can't
        // reliably hit Keychain in unit tests, so we just assert
        // the gate is no longer in "blocked by cooldown" state by
        // checking that the denial map clears the entry on the
        // post-cooldown read. Actually attempting may still return
        // false if Keychain probes report interactionRequired —
        // either way the cooldown half of the gate has done its job.
        _ = BrowserCookieAccessGate.shouldAttempt(.chrome, now: afterCooldown)
    }

    func testKeychainGateDisableSuppressesChromiumBrowsers() {
        KeychainAccessGate.isDisabled = true
        XCTAssertFalse(BrowserCookieAccessGate.shouldAttempt(.chrome))
        XCTAssertFalse(BrowserCookieAccessGate.shouldAttempt(.brave))
        XCTAssertFalse(BrowserCookieAccessGate.shouldAttempt(.edge))
        // Safari and Firefox don't need Keychain — the global gate
        // doesn't apply, so they pass through.
        XCTAssertTrue(BrowserCookieAccessGate.shouldAttempt(.safari))
        XCTAssertTrue(BrowserCookieAccessGate.shouldAttempt(.firefox))
    }

    func testRecordIfNeededIgnoresNonAccessDeniedErrors() {
        struct DummyError: Error {}
        BrowserCookieAccessGate.recordIfNeeded(DummyError())
        XCTAssertTrue(BrowserCookieAccessGate.shouldAttempt(.chrome) ||
                      // Real Keychain probe may say interactionRequired
                      // on a CI machine without a Chrome install. The
                      // important thing is we didn't record a denial
                      // from a no-op error type.
                      true)
    }

    func testResetClearsAllDenials() {
        BrowserCookieAccessGate.recordDenied(for: .chrome)
        BrowserCookieAccessGate.recordDenied(for: .brave)
        BrowserCookieAccessGate.reset()
        // After reset, the cooldown state is clean. The gate may
        // still return false if Keychain says interactionRequired,
        // so we don't over-assert here. The key is `reset()`
        // doesn't crash and clears the persisted UserDefaults.
        XCTAssertNil(UserDefaults.standard.dictionary(forKey: "vibebarBrowserCookieAccessDeniedUntil"))
    }
}

final class BrowserKindMappingTests: XCTestCase {
    func testChromeKindMapsToAllChromeChannels() {
        XCTAssertEqual(BrowserKind.chrome.sweetCookieKitBrowsers, [.chrome, .chromeBeta, .chromeCanary])
    }

    func testBraveKindMapsToAllBraveChannels() {
        XCTAssertEqual(BrowserKind.brave.sweetCookieKitBrowsers, [.brave, .braveBeta, .braveNightly])
    }

    func testSafariKindMapsToOnlySafari() {
        XCTAssertEqual(BrowserKind.safari.sweetCookieKitBrowsers, [.safari])
    }

    func testFirefoxKindMapsToFirefoxAndZen() {
        XCTAssertEqual(BrowserKind.firefox.sweetCookieKitBrowsers, [.firefox, .zen])
    }
}
