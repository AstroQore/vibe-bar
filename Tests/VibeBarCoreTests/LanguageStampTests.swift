import XCTest
@testable import VibeBarCore

/// `LanguageStamp` is the value every language-aware cache key and
/// `.equatable()` guard in the app holds. Those guards live in the App
/// target, which has no tests of its own, so this pins the one thing they
/// all depend on: that the stamp actually differs across a language change
/// and compares equal within one.
final class LanguageStampTests: XCTestCase {
    private func withLanguage<T>(_ language: AppLanguage, _ body: () -> T) -> T {
        let restore = AppLocalization.languageOverride
        defer { AppLocalization.languageOverride = restore }
        AppLocalization.languageOverride = language
        return body()
    }

    func testStampDiffersAcrossLanguages() {
        let english = withLanguage(.english) { LanguageStamp.current }
        let chinese = withLanguage(.simplifiedChinese) { LanguageStamp.current }
        XCTAssertNotEqual(
            english, chinese,
            "a cache keyed on this would survive a language change and keep serving the old one"
        )
    }

    func testStampIsStableWithinALanguage() {
        let (first, second) = withLanguage(.english) {
            (LanguageStamp.current, LanguageStamp.current)
        }
        XCTAssertEqual(
            first, second,
            "an unstable stamp would invalidate every cache holding it on every render"
        )
    }

    /// The stamp follows the app's own language setting, not the machine's.
    /// That is the whole reason it exists rather than reading `Locale`.
    func testStampFollowsTheAppLanguageNotTheSystem() {
        XCTAssertEqual(
            withLanguage(.simplifiedChinese) { LanguageStamp.current.code },
            "zh-Hans"
        )
        XCTAssertEqual(withLanguage(.english) { LanguageStamp.current.code }, "en")
    }
}
