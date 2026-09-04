import XCTest
@testable import VibeBarCore

/// Dates, times and numbers are the half of localization that has no
/// catalog: nothing here is translated by hand, so the only way to get it
/// wrong is to format against the wrong locale — and `Locale.current` is
/// the wrong locale, because it is the *system's* language and
/// `AppSettings.language` is the app's.
final class AppLocaleTests: XCTestCase {
    private var restore: AppLanguage!

    override func setUp() {
        super.setUp()
        restore = AppLocalization.languageOverride
    }

    override func tearDown() {
        AppLocalization.languageOverride = restore
        super.tearDown()
    }

    private let reference = Date(timeIntervalSinceReferenceDate: 800_000_000)  // 2026-05-09

    func testTheLocaleFollowsTheAppLanguageNotTheProcess() {
        AppLocalization.languageOverride = .simplifiedChinese
        XCTAssertEqual(AppLocale.current.identifier, "zh-Hans")
        AppLocalization.languageOverride = .english
        XCTAssertEqual(AppLocale.current.identifier, "en")
    }

    /// The bug this covers: a pricing status line that says "Merged" in
    /// Chinese and then "May 9, 2026" in English, because
    /// `date.formatted(...)` had asked the process.
    func testADateRendersInTheAppLanguage() {
        AppLocalization.languageOverride = .english
        let english = AppLocale.string(reference, template: "MMMdyyyy")
        AppLocalization.languageOverride = .simplifiedChinese
        let chinese = AppLocale.string(reference, template: "MMMdyyyy")

        XCTAssertNotEqual(english, chinese, "the date did not change with the language")
        XCTAssertTrue(chinese.contains("月"), "expected a Chinese month name, got \(chinese)")
        XCTAssertFalse(
            chinese.range(of: "[A-Za-z]", options: .regularExpression) != nil,
            "an English month name survived into the Chinese date: \(chinese)"
        )
    }

    func testStyledDatesAndRelativeDatesFollowTheLanguageToo() {
        AppLocalization.languageOverride = .simplifiedChinese
        let styled = AppLocale.string(reference, dateStyle: .medium, timeStyle: .none)
        XCTAssertTrue(styled.contains("月"), "styled date stayed English: \(styled)")

        let relative = AppLocale.relativeDateTimeFormatter()
            .localizedString(fromTimeInterval: -3600)
        XCTAssertFalse(
            relative.range(of: "[A-Za-z]", options: .regularExpression) != nil,
            "relative date stayed English: \(relative)"
        )
    }

    /// A formatter parked in a `static let` is built once for the process
    /// and keeps the language it was born in — the same staleness that made
    /// `ResetHistoryComparison.verdict` a computed property. `AppLocale`
    /// keys its cache on the resolved language, so a change is a miss
    /// rather than something to remember to invalidate.
    func testAMemoizedFormatterIsNotSharedAcrossLanguages() {
        AppLocalization.languageOverride = .english
        let first = AppLocale.dateFormatter(template: "MMMd")
        let firstAgain = AppLocale.dateFormatter(template: "MMMd")
        XCTAssertTrue(first === firstAgain, "the cache is not memoizing at all")

        AppLocalization.languageOverride = .simplifiedChinese
        let second = AppLocale.dateFormatter(template: "MMMd")
        XCTAssertFalse(first === second, "the English formatter was reused for Chinese")
        XCTAssertEqual(second.locale.identifier, "zh-Hans")
    }

    func testNumbersAndPercentsFollowTheLanguage() {
        AppLocalization.languageOverride = .english
        XCTAssertEqual(AppLocale.number(1234567), "1,234,567")
        AppLocalization.languageOverride = .simplifiedChinese
        XCTAssertEqual(AppLocale.number(1234567), "1,234,567")
        XCTAssertEqual(AppLocale.percent(0.42), "42%")
    }
}
