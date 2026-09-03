import XCTest
@testable import VibeBarCore
import SweetCookieKit

/// A declined Chromium "Safe Storage" prompt parks that browser for six
/// hours, and the Settings row now says so. Two things have to hold for
/// that message to be true:
///
/// 1. An ordinary "Import from browser" click honours the cooldown instead
///    of prompting straight through it — only the explicit "Retry now" /
///    "Reset browser-cookie cooldown" control clears the gate.
/// 2. The cooldown is only blamed for an import that would actually have
///    read that browser. A provider whose credential lives in Chromium
///    localStorage never touches the Keychain gate at all.
final class MiscCookieImportCooldownTests: XCTestCase {
    private var emptyHome: URL!

    /// Reports every path as present with a single `Default` profile, so
    /// `BrowserDetection` finds usable Chromium data without a browser
    /// actually being installed on the test machine.
    private func fakeDetection() -> BrowserDetection {
        BrowserDetection(
            homeDirectory: "/Users/example",
            fileExists: { _ in true },
            directoryContents: { _ in ["Default"] }
        )
    }

    /// The opposite: nothing on disk, so no browser counts as a source
    /// this import could have read.
    private func absentDetection() -> BrowserDetection {
        BrowserDetection(
            homeDirectory: "/Users/example",
            fileExists: { _ in false },
            directoryContents: { _ in nil }
        )
    }

    /// A home with no Chromium profiles under it, so the localStorage
    /// importer finds no roots and nothing is ever written.
    private func context(detection: BrowserDetection) -> MiscCookieResolver.BrowserImportContext {
        MiscCookieResolver.BrowserImportContext(
            detection: detection,
            homeDirectory: emptyHome
        )
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        BrowserCookieAccessGate.reset()
        MiscCookieResolver.resetKeychainWarmthForTesting()
        KeychainAccessGate.isDisabled = false
        emptyHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebar-cooldown-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        BrowserCookieAccessGate.reset()
        MiscCookieResolver.resetKeychainWarmthForTesting()
        KeychainAccessGate.isDisabled = false
        if let emptyHome { try? FileManager.default.removeItem(at: emptyHome) }
        try super.tearDownWithError()
    }

    // MARK: - The cooldown is honoured, not bypassed

    func testAPromptingImportSkipsABrowserInsideItsCooldown() {
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        BrowserCookieAccessGate.recordDenied(for: .chrome, now: now)

        let partition = MiscCookieResolver.cooldownPartition(
            [.chrome, .brave],
            detection: fakeDetection(),
            now: now
        )
        XCTAssertEqual(partition.eligible, [.brave])
        XCTAssertEqual(partition.blocked.map(\.browserName), [Browser.chrome.displayName])
        XCTAssertEqual(partition.blocked.first?.until, now.addingTimeInterval(60 * 60 * 6))
    }

    /// The cap on Chromium browsers per click has to land on a browser we
    /// can actually read, so the filter runs on the preference list rather
    /// than on what `cookieImportCandidates` returns.
    func testTheOneChromiumPerClickCapSkipsPastACooledDownBrowser() {
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        BrowserCookieAccessGate.recordDenied(for: .chrome, now: now)

        let partition = MiscCookieResolver.cooldownPartition(
            [.chrome, .brave, .edge],
            detection: fakeDetection(),
            now: now
        )
        let candidates = partition.eligible.cookieImportCandidates(
            using: fakeDetection(),
            allowKeychainPrompt: true
        )
        XCTAssertEqual(candidates, [.brave])
    }

    func testResettingTheGateLetsTheNextImportPromptAgain() {
        BrowserCookieAccessGate.recordDenied(for: .chrome)
        XCTAssertTrue(
            MiscCookieResolver.cooldownPartition([.chrome], detection: fakeDetection()).eligible.isEmpty
        )

        // What "Retry now" and "Reset browser-cookie cooldown" do first.
        BrowserCookieAccessGate.reset()
        XCTAssertEqual(
            MiscCookieResolver.cooldownPartition([.chrome], detection: fakeDetection()).eligible,
            [.chrome]
        )
    }

    func testExpiredCooldownsDoNotBlockAnImport() {
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        BrowserCookieAccessGate.recordDenied(for: .chrome, now: now)
        let partition = MiscCookieResolver.cooldownPartition(
            [.chrome],
            detection: fakeDetection(),
            now: now.addingTimeInterval(60 * 60 * 6 + 1)
        )
        XCTAssertEqual(partition.eligible, [.chrome])
        XCTAssertTrue(partition.blocked.isEmpty)
    }

    func testAnUninstalledBrowserIsNotReportedAsBlockingThisImport() {
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        BrowserCookieAccessGate.recordDenied(for: .chrome, now: now)
        let partition = MiscCookieResolver.cooldownPartition(
            [.chrome],
            detection: absentDetection(),
            now: now
        )
        XCTAssertTrue(partition.eligible.isEmpty)
        XCTAssertTrue(partition.blocked.isEmpty, "Nothing to read means nothing to blame.")
    }

    /// End to end through the import walk: every Chromium channel the user
    /// prefers is suppressed, so the row says "declined" rather than
    /// sending them back to the browser to sign in again.
    func testAFullySuppressedImportReportsTheCooldownOutcome() {
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        for browser in BrowserKind.chrome.sweetCookieKitBrowsers {
            BrowserCookieAccessGate.recordDenied(for: browser, now: now)
        }

        let attempt = MiscCookieResolver.attemptBrowserImport(
            spec: Self.syntheticCookieSpec,
            settings: MiscProviderSettings(preferredBrowser: .chrome),
            context: context(detection: fakeDetection()),
            now: now
        )

        XCTAssertNil(attempt.session)
        guard case let .keychainCooldown(browser, until) = attempt.emptyOutcome else {
            return XCTFail("Expected keychainCooldown, got \(attempt.emptyOutcome)")
        }
        XCTAssertTrue(BrowserKind.chrome.sweetCookieKitBrowsers.map(\.displayName).contains(browser))
        XCTAssertEqual(until, now.addingTimeInterval(60 * 60 * 6))
    }

    // MARK: - Cooldowns are per attempt, not process-wide

    /// Kimi's credential lives in Chromium localStorage, which the
    /// Keychain gate never gates. An unrelated Chrome cooldown from some
    /// earlier cookie-jar import must not make a failed Kimi import claim
    /// that Chrome Keychain access was declined.
    func testLocalStorageImportIsNotBlamedOnAnUnrelatedChromeCooldown() {
        BrowserCookieAccessGate.recordDenied(for: .chrome)

        let attempt = MiscCookieResolver.attemptBrowserImport(
            spec: KimiQuotaAdapter.cookieSpec,
            settings: .default,
            context: context(detection: fakeDetection())
        )

        XCTAssertNil(attempt.session)
        XCTAssertTrue(attempt.blockedByCooldown.isEmpty)
        XCTAssertEqual(attempt.emptyOutcome, .noSessionFound)
    }

    /// The same rule for a cookie-jar provider whose preferred browser is
    /// not the one in the cooldown: Safari needs no Keychain key at all.
    func testACooldownOnADifferentBrowserIsNotBlamedEither() {
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        BrowserCookieAccessGate.recordDenied(for: .chrome, now: now)

        let partition = MiscCookieResolver.cooldownPartition(
            BrowserKind.safari.sweetCookieKitBrowsers,
            detection: fakeDetection(),
            now: now
        )
        XCTAssertEqual(partition.eligible, [.safari])
        XCTAssertTrue(partition.blocked.isEmpty)
    }

    func testAnAttemptWithNothingBlockedFallsBackToNoSessionFound() {
        let attempt = MiscCookieResolver.attemptBrowserImport(
            spec: KimiQuotaAdapter.cookieSpec,
            settings: .default,
            context: context(detection: absentDetection())
        )
        XCTAssertEqual(attempt.emptyOutcome, .noSessionFound)
    }

    /// Domains that cannot resolve to any real cookie store, so a walk that
    /// reaches SweetCookieKit finds nothing on any machine.
    private static let syntheticCookieSpec = MiscCookieResolver.Spec(
        tool: .volcengine,
        domains: ["cookies.invalid"],
        requiredNames: []
    )
}
