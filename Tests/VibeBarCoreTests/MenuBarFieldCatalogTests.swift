import XCTest
@testable import VibeBarCore

final class MenuBarFieldCatalogTests: XCTestCase {
    func testDedicatedProviderMiniFieldsAreCatalogued() {
        let expected = [
            "gemini.gemini-2.5-pro",
            "gemini.gemini-2.5-flash",
            "gemini.gemini-2.5-flash-lite",
            "antigravity.claude-sonnet-4-20250514",
            "antigravity.gemini-2.5-pro",
            "antigravity.gemini-2.5-flash-lite",
            "grok.monthly"
        ]

        for id in expected {
            XCTAssertNotNil(MenuBarFieldCatalog.field(id: id), "\(id) should be selectable in the mini window")
        }
    }

    func testDefaultMiniWindowIncludesDedicatedProviderFields() {
        let selected = Set(AppSettings.defaultMiniWindow.selectedFieldIds)
        XCTAssertTrue(selected.contains("gemini.gemini-2.5-pro"))
        XCTAssertTrue(selected.contains("antigravity.gemini-2.5-pro"))
        XCTAssertTrue(selected.contains("grok.monthly"))
    }
}
