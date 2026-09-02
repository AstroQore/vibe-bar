import XCTest
@testable import VibeBarCore

/// The first-run assistant must open for a fresh install and never for an
/// upgrade — and the only thing separating the two is what the install
/// looks like, because the completion key did not exist before the
/// assistant did.
final class OnboardingGateTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebar-onboarding-gate-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    // MARK: - The rule

    func testFreshInstallShows() {
        XCTAssertEqual(
            OnboardingGate.decide(hasCompletedOnboarding: false, hasQuotaCaches: false, hasCLIQuotaAccount: false),
            .show
        )
    }

    func testCompletedSkipsWhateverTheInstallLooksLike() {
        for caches in [false, true] {
            for account in [false, true] {
                XCTAssertEqual(
                    OnboardingGate.decide(hasCompletedOnboarding: true, hasQuotaCaches: caches, hasCLIQuotaAccount: account),
                    .skip,
                    "caches=\(caches) account=\(account)"
                )
            }
        }
    }

    func testUnsetKeyOnAnExistingInstallMarksCompletedSilently() {
        // Quota caches alone are proof the app has run here before.
        XCTAssertEqual(
            OnboardingGate.decide(hasCompletedOnboarding: false, hasQuotaCaches: true, hasCLIQuotaAccount: false),
            .markCompleted
        )
        // So is a Codex / Claude account the launch path could already resolve.
        XCTAssertEqual(
            OnboardingGate.decide(hasCompletedOnboarding: false, hasQuotaCaches: false, hasCLIQuotaAccount: true),
            .markCompleted
        )
        XCTAssertEqual(
            OnboardingGate.decide(hasCompletedOnboarding: false, hasQuotaCaches: true, hasCLIQuotaAccount: true),
            .markCompleted
        )
    }

    func testShouldShowReadsTheSettingsKey() {
        var settings = AppSettings.default
        XCTAssertTrue(OnboardingGate.shouldShow(settings: settings, hasQuotaCaches: false, hasCLIQuotaAccount: false))
        XCTAssertFalse(OnboardingGate.shouldShow(settings: settings, hasQuotaCaches: true, hasCLIQuotaAccount: false))
        XCTAssertFalse(OnboardingGate.shouldShow(settings: settings, hasQuotaCaches: false, hasCLIQuotaAccount: true))
        settings.hasCompletedOnboarding = true
        XCTAssertFalse(OnboardingGate.shouldShow(settings: settings, hasQuotaCaches: false, hasCLIQuotaAccount: false))
    }

    // MARK: - The quota-cache probe

    func testMissingQuotaDirectoryHasNoCaches() {
        let missing = temporaryDirectory.appendingPathComponent("quotas", isDirectory: true)
        XCTAssertFalse(OnboardingGate.hasQuotaCaches(in: missing))
    }

    func testEmptyQuotaDirectoryHasNoCaches() throws {
        let quotas = temporaryDirectory.appendingPathComponent("quotas", isDirectory: true)
        try FileManager.default.createDirectory(at: quotas, withIntermediateDirectories: true)
        XCTAssertFalse(OnboardingGate.hasQuotaCaches(in: quotas))
    }

    func testDotfilesAloneDoNotCountAsCaches() throws {
        let quotas = temporaryDirectory.appendingPathComponent("quotas", isDirectory: true)
        try FileManager.default.createDirectory(at: quotas, withIntermediateDirectories: true)
        try Data().write(to: quotas.appendingPathComponent(".DS_Store"))
        XCTAssertFalse(OnboardingGate.hasQuotaCaches(in: quotas))
    }

    func testAnyCacheFileCounts() throws {
        let quotas = temporaryDirectory.appendingPathComponent("quotas", isDirectory: true)
        try FileManager.default.createDirectory(at: quotas, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: quotas.appendingPathComponent("cli-codex.json"))
        XCTAssertTrue(OnboardingGate.hasQuotaCaches(in: quotas))
    }
}
