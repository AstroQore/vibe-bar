import XCTest
@testable import VibeBarCore
import SweetCookieKit

/// The browsers a user ticked are the browsers every import reads — the
/// four core providers' importers through the default order, the misc
/// resolver through its restricted one — and nothing else is.
final class BrowserCookieImportPreferenceTests: XCTestCase {
    override func tearDown() {
        BrowserCookieImportPreference.apply(nil)
        super.tearDown()
    }

    func testNoChoiceMeansTheCatalogueOrderAndAnUntouchedProviderOrder() {
        BrowserCookieImportPreference.apply(nil)
        XCTAssertNil(BrowserCookieImportPreference.selected)
        XCTAssertEqual(BrowserCookieImportPreference.order, BrowserCookieDefaults.importOrder)
        XCTAssertEqual(BrowserCookieImportPreference.restrict([.edge, .safari]), [.edge, .safari])
    }

    func testAChoiceIsTheOrderAndRestrictsAProviderToItInTheChosenOrder() {
        BrowserCookieImportPreference.apply(["edge", "chrome"])
        XCTAssertEqual(BrowserCookieImportPreference.selected, [.edge, .chrome])
        XCTAssertEqual(BrowserCookieImportPreference.order, [.edge, .chrome])
        XCTAssertEqual(BrowserCookieImportPreference.restrict([.safari, .chrome, .edge, .brave]), [.edge, .chrome],
                       "the chosen order wins over the provider's")
        XCTAssertEqual(BrowserCookieImportPreference.restrict([.safari, .firefox]), [],
                       "a provider whose browsers were all left unticked reads nothing")
    }

    func testUnknownValuesAreDroppedAndAnEmptyChoiceIsNoChoice() {
        BrowserCookieImportPreference.apply(["chrome", "netscape"])
        XCTAssertEqual(BrowserCookieImportPreference.selected, [.chrome])
        BrowserCookieImportPreference.apply([])
        XCTAssertNil(BrowserCookieImportPreference.selected)
        BrowserCookieImportPreference.apply(["netscape"])
        XCTAssertNil(BrowserCookieImportPreference.selected)
    }

    func testThePickerListsInstalledBrowsersWithACookieStoreInCatalogueOrder() {
        let detection = BrowserDetection(
            homeDirectory: "/Users/example",
            fileExists: { path in
                if path.hasSuffix(".app") { return path.hasSuffix("/Google Chrome.app") || path.hasSuffix("/Microsoft Edge.app") }
                return true
            },
            directoryContents: { _ in ["Default"] }
        )
        XCTAssertEqual(BrowserCookieImportPreference.available(using: detection), [.safari, .chrome, .edge])
    }

    func testTheSettingRoundTripsAndDropsDuplicatesAndBlanks() throws {
        var settings = AppSettings.default
        settings.cookieImportBrowsers = ["edge", " ", "chrome", "edge"]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.cookieImportBrowsers, ["edge", "chrome"])
        let absent = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertNil(absent.cookieImportBrowsers)
        let empty = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"cookieImportBrowsers":[]}"#.utf8))
        XCTAssertNil(empty.cookieImportBrowsers, "an empty list is no choice, not a choice of nothing")
    }
}
