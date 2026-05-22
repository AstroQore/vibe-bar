import XCTest
@testable import VibeBarCore

final class MenuBarFieldCatalogTests: XCTestCase {
    func testDedicatedProviderMiniFieldsAreCatalogued() {
        let expected = [
            "gemini.gemini-2.5-pro",
            "gemini.gemini-2.5-flash",
            "gemini.gemini-2.5-flash-lite",
            "antigravity.claude-sonnet-4.6-thinking",
            "antigravity.claude-opus-4.6-thinking",
            "antigravity.gpt-oss-120b-medium",
            "antigravity.gemini-3.5-flash-high",
            "antigravity.gemini-3.5-flash-medium",
            "antigravity.gemini-3.1-pro-high",
            "antigravity.gemini-3.1-pro-low",
            "grok.monthly"
        ]

        for id in expected {
            XCTAssertNotNil(MenuBarFieldCatalog.field(id: id), "\(id) should be selectable in the mini window")
        }
    }

    func testDefaultMiniWindowIncludesDedicatedProviderFields() {
        let selected = Set(AppSettings.defaultMiniWindow.selectedFieldIds)
        XCTAssertTrue(selected.contains("gemini.gemini-2.5-pro"))
        XCTAssertTrue(selected.contains("antigravity.gemini-3.5-flash-high"))
        XCTAssertTrue(selected.contains("antigravity.claude-sonnet-4.6-thinking"))
        XCTAssertTrue(selected.contains("grok.monthly"))
    }
}
