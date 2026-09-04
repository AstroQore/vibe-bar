import XCTest
@testable import VibeBarCore

/// `AppSettings.language` is only a preference until something reads it.
/// `SettingsStore` is that something: it mirrors the value into `L10n` on
/// every assignment and once at load, which is what makes the picker take
/// effect without a relaunch — the same assignment publishes to every
/// `$settings` subscriber, so the pass that redraws the picker redraws
/// the labels around it.
@MainActor
final class LanguageSettingBindingTests: XCTestCase {
    private var home: URL!
    private var settingsURL: URL!
    private var restoreLanguage: AppLanguage!

    override func setUpWithError() throws {
        try super.setUpWithError()
        restoreLanguage = AppLocalization.languageOverride
        home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("language-setting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        settingsURL = home.appendingPathComponent("settings.json")
    }

    override func tearDownWithError() throws {
        AppLocalization.languageOverride = restoreLanguage
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }

    private func makeStore() throws -> SettingsStore {
        SettingsStore(
            userDefaults: try XCTUnwrap(
                UserDefaults(suiteName: "LanguageSettingBindingTests.\(UUID().uuidString)")
            ),
            settingsURL: settingsURL
        )
    }

    func testChangingTheSettingChangesWhatTheNextLookupReturns() throws {
        let store = try makeStore()
        store.settings.language = .simplifiedChinese
        XCTAssertEqual(AppLocalization.languageOverride, .simplifiedChinese)
        XCTAssertEqual(L10n.Common.refresh, "刷新")

        store.settings.language = .english
        XCTAssertEqual(L10n.Common.refresh, "Refresh")

        // `.system` hands the decision back to macOS rather than pinning
        // whichever language happened to be showing.
        store.settings.language = .system
        XCTAssertEqual(AppLocalization.languageOverride, .system)
        XCTAssertEqual(AppLocalization.resolvedLanguageCode, AppLocalization.resolve(override: .system))
    }

    /// `didSet` does not run for an assignment made inside `init`, so a
    /// language chosen in a previous session has to be installed by the
    /// initializer or the first launch comes up in the wrong one.
    func testALanguageChosenLastSessionIsInstalledAtLoad() throws {
        try Data(#"{"displayMode":"remaining","language":"zh-Hans"}"#.utf8)
            .write(to: settingsURL)
        AppLocalization.languageOverride = .system

        let store = try makeStore()
        XCTAssertEqual(store.settings.language, .simplifiedChinese)
        XCTAssertEqual(AppLocalization.languageOverride, .simplifiedChinese)
        XCTAssertEqual(L10n.Common.refresh, "刷新")
    }
}
