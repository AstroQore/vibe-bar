import XCTest
@testable import VibeBarCore

final class MenuBarFieldCatalogTests: XCTestCase {
    func testDedicatedProviderMiniFieldsAreCatalogued() {
        // Gemini Web (jSf9Qc parser) only emits 5-hour and weekly
        // buckets — the per-model CLI ids the catalog used to carry
        // (gemini.gemini-2.5-pro etc.) are migrated to `gemini.five_hour`
        // via `fieldIdMigrations`.
        let expected = [
            "gemini.five_hour",
            "gemini.weekly",
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
        XCTAssertTrue(selected.contains("gemini.five_hour"))
        XCTAssertTrue(selected.contains("gemini.weekly"))
        XCTAssertTrue(selected.contains("antigravity.gemini-3.5-flash-high"))
        XCTAssertTrue(selected.contains("antigravity.claude-sonnet-4.6-thinking"))
        XCTAssertTrue(selected.contains("grok.monthly"))
    }

    func testGeminiCLIModelIdsMigrateToWebBuckets() {
        // Old Gemini CLI fields no longer have catalog entries; all of
        // them must migrate to the Web parser's `gemini.five_hour`
        // bucket so users upgrading from <= 0.1 builds don't lose
        // their Gemini quota cells.
        let legacy = [
            "gemini.gemini_pro",
            "gemini.gemini_flash",
            "gemini.gemini_flash_lite",
            "gemini.gemini-2.5-pro",
            "gemini.gemini-2.5-flash",
            "gemini.gemini-2.5-flash-lite",
            "gemini.gemini-3-pro",
            "gemini.gemini-3-flash"
        ]
        let migrated = MenuBarFieldCatalog.migratedFieldIds(legacy)
        XCTAssertEqual(migrated, ["gemini.five_hour"])
    }
}
