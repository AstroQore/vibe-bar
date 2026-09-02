import XCTest
@testable import VibeBarCore

/// The first-run assistant must open for a fresh install and never for an
/// upgrade — and the only thing separating the two is what the install
/// looks like, because the completion key did not exist before the
/// assistant did. Only Vibe Bar's own evidence counts — a quota cache, or a
/// settings file that was already there at launch; a Codex or Claude CLI
/// login on the Mac is what its users have *before* they install it.
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

    /// A clean install shows the assistant — including, and especially, on a
    /// Mac that already has Codex or Claude CLI credentials. The gate takes
    /// no such signal, so there is nothing for those credentials to change.
    func testFreshInstallShows() {
        // No settings file before the store was built, no quota cache.
        XCTAssertEqual(
            OnboardingGate.decide(hasCompletedOnboarding: false, hasQuotaCaches: false, hadSettingsFile: false),
            .show
        )
    }

    func testCompletedSkipsWhateverTheInstallLooksLike() {
        for caches in [false, true] {
            for file in [false, true] {
                XCTAssertEqual(
                    OnboardingGate.decide(hasCompletedOnboarding: true, hasQuotaCaches: caches, hadSettingsFile: file),
                    .skip,
                    "caches=\(caches) file=\(file)"
                )
            }
        }
    }

    func testUnsetKeyOnAnExistingInstallMarksCompletedSilently() {
        // A quota cache is proof the app has run here before.
        XCTAssertEqual(
            OnboardingGate.decide(hasCompletedOnboarding: false, hasQuotaCaches: true, hadSettingsFile: false),
            .markCompleted
        )
        // So is a settings file that was on disk before this launch wrote
        // one — the case of a user whose providers never produced a cache.
        XCTAssertEqual(
            OnboardingGate.decide(hasCompletedOnboarding: false, hasQuotaCaches: false, hadSettingsFile: true),
            .markCompleted
        )
        XCTAssertEqual(
            OnboardingGate.decide(hasCompletedOnboarding: false, hasQuotaCaches: true, hadSettingsFile: true),
            .markCompleted
        )
    }

    func testShouldShowReadsTheSettingsKey() {
        var settings = AppSettings.default
        XCTAssertTrue(OnboardingGate.shouldShow(settings: settings, hasQuotaCaches: false, hadSettingsFile: false))
        XCTAssertFalse(OnboardingGate.shouldShow(settings: settings, hasQuotaCaches: true, hadSettingsFile: false))
        XCTAssertFalse(OnboardingGate.shouldShow(settings: settings, hasQuotaCaches: false, hadSettingsFile: true))
        settings.hasCompletedOnboarding = true
        XCTAssertFalse(OnboardingGate.shouldShow(settings: settings, hasQuotaCaches: false, hadSettingsFile: false))
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
