import XCTest
@testable import VibeBarCore
import SweetCookieKit

/// An uninstalled browser is not a cookie source, however much of its
/// profile it left behind — and the silent gate asks each browser's own
/// Safe Storage item, so one browser's answer never stands in for another's.
///
/// The case that motivated this: ChatGPT Atlas uninstalled, its profile and
/// cookie store still on disk, its Safe Storage key gone. It was picked as
/// the one Chromium browser an import may read, failed for want of a key,
/// was recorded as a *denial*, and every provider's empty result was then
/// blamed on "ChatGPT Atlas Keychain access declined" — while Chrome, which
/// had the sessions, was never read.
final class BrowserCookieSourceTests: XCTestCase {
    private let originalPreflight = BrowserCookieAccessGate.preflight

    override func setUp() {
        super.setUp()
        BrowserCookieAccessGate.reset()
        KeychainAccessGate.isDisabled = false
    }

    override func tearDown() {
        BrowserCookieAccessGate.preflight = originalPreflight
        BrowserCookieAccessGate.reset()
        KeychainAccessGate.isDisabled = false
        super.tearDown()
    }

    /// Chrome installed with data; Atlas's data present but its app gone.
    private func leftoverAtlasDetection() -> BrowserDetection {
        BrowserDetection(
            homeDirectory: "/Users/example",
            fileExists: { path in
                if path.hasSuffix(".app") { return path.hasSuffix("/Google Chrome.app") }
                return true
            },
            directoryContents: { _ in ["Default"] }
        )
    }

    func testAnUninstalledBrowserWithLeftoverDataIsNotACookieSource() {
        let detection = leftoverAtlasDetection()
        XCTAssertTrue(detection.isAppInstalled(.chrome))
        XCTAssertFalse(detection.isAppInstalled(.chatgptAtlas))
        XCTAssertTrue(detection.isCookieSourceAvailable(.chrome))
        XCTAssertTrue(detection.isCookieSourceAvailable(.safari), "Safari is part of macOS")
        XCTAssertFalse(detection.isCookieSourceAvailable(.chatgptAtlas), "a profile without its app is a leftover, not a source")
        XCTAssertFalse(detection.hasUsableProfileData(.chatgptAtlas))
        XCTAssertTrue(detection.hasUsableProfileData(.chrome))
    }

    func testTheOneChromiumBrowserAnImportMayReadIsAnInstalledOne() {
        let detection = leftoverAtlasDetection()
        let order: [Browser] = [.safari, .chatgptAtlas, .chrome, .edge]
        XCTAssertEqual(order.cookieImportCandidates(using: detection, allowKeychainPrompt: true), [.safari, .chrome])
    }

    func testAnUninstalledBrowserInCooldownIsNeitherReadNorBlamed() {
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        BrowserCookieAccessGate.recordDenied(for: .chatgptAtlas, now: now)
        let partition = MiscCookieResolver.cooldownPartition([.chatgptAtlas, .chrome], detection: leftoverAtlasDetection(), now: now)
        XCTAssertEqual(partition.eligible, [.chrome])
        XCTAssertTrue(partition.blocked.isEmpty, "a browser that could not have been read cannot be what blocked the import")
    }

    func testTheSettingsCardDoesNotListACooldownForABrowserThatIsGone() {
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        BrowserCookieAccessGate.recordDenied(for: .chatgptAtlas, now: now)
        BrowserCookieAccessGate.recordDenied(for: .chrome, now: now)
        let listed = BrowserCookieAccessGate.activeCooldowns(now: now, detection: leftoverAtlasDetection())
        XCTAssertEqual(listed.map(\.browserName), [Browser.chrome.displayName])
    }

    func testTheSilentGateAsksEachBrowsersOwnKeyAndSkipsAnAbsentOneWithoutACooldown() {
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        BrowserCookieAccessGate.preflight = { service, _ in
            if service.hasPrefix("Chrome") { return .allowed }
            if service.hasPrefix("Microsoft Edge") { return .interactionRequired }
            return .notFound
        }
        XCTAssertEqual(BrowserCookieAccessGate.keychainPreflight(for: .chrome), .allowed)
        XCTAssertEqual(BrowserCookieAccessGate.keychainPreflight(for: .chatgptAtlas), .absent)
        XCTAssertEqual(BrowserCookieAccessGate.keychainPreflight(for: .edge), .interactionRequired)

        XCTAssertTrue(BrowserCookieAccessGate.shouldAttempt(.chrome, now: now))
        XCTAssertFalse(BrowserCookieAccessGate.shouldAttempt(.chatgptAtlas, now: now), "no key, no read")
        XCTAssertNil(BrowserCookieAccessGate.blockedUntil(.chatgptAtlas, now: now), "a missing key is not a refusal")
        XCTAssertFalse(BrowserCookieAccessGate.shouldAttempt(.edge, now: now))
        XCTAssertNotNil(BrowserCookieAccessGate.blockedUntil(.edge, now: now), "a read that would prompt is parked")
        XCTAssertTrue(BrowserCookieAccessGate.shouldAttempt(.chrome, now: now), "Chrome's cooldown is Chrome's alone")
        XCTAssertTrue(BrowserCookieAccessGate.shouldAttempt(.safari, now: now))
    }

    func testAChannelWithoutItsOwnLabelsFallsBackToTheCatalogue() {
        BrowserCookieAccessGate.preflight = { service, _ in service.hasPrefix("Chrome") ? .allowed : .notFound }
        XCTAssertTrue(Browser.chromeBeta.safeStorageLabels.isEmpty)
        XCTAssertEqual(BrowserCookieAccessGate.keychainPreflight(for: .chromeBeta), .allowed)
    }
}
