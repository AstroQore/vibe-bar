import XCTest
@testable import VibeBarCore

final class MenuBarSettingsTests: XCTestCase {
    func testFieldStylesRoundTripAndDefaultToLabel() throws {
        var item = MenuBarItemSettings(
            kind: .compact,
            isVisible: true,
            showTitle: false,
            selectedFieldIds: ["claude.five_hour", "codex.weekly"]
        )
        item.fieldStyles["claude.five_hour"] = .logoAndPercent
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(MenuBarItemSettings.self, from: data)
        XCTAssertEqual(decoded.style(for: "claude.five_hour"), .logoAndPercent)
        // A field with no entry draws the default label-and-percent style.
        XCTAssertEqual(decoded.style(for: "codex.weekly"), .labelAndPercent)
    }

    func testUnknownFieldStyleFallsBackInsteadOfFailingDecode() throws {
        let json = """
        {"kind":"compact","isVisible":true,"showTitle":false,"layout":"singleLine",
         "selectedFieldIds":["claude.five_hour"],"customLabels":{},
         "fieldStyles":{"claude.five_hour":"holographic","codex.weekly":"logoAndPercent"}}
        """
        let decoded = try JSONDecoder().decode(MenuBarItemSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.style(for: "claude.five_hour"), .labelAndPercent)
        XCTAssertEqual(decoded.style(for: "codex.weekly"), .logoAndPercent)
    }

    func testPreStyleSettingsDecodeWithEmptyStyles() throws {
        let json = """
        {"kind":"compact","isVisible":true,"showTitle":true,"layout":"twoRows",
         "selectedFieldIds":["claude.five_hour"],"customLabels":{}}
        """
        let decoded = try JSONDecoder().decode(MenuBarItemSettings.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.fieldStyles.isEmpty)
    }

    func testMergesGroupWindowsRoundTrips() throws {
        var item = MenuBarItemSettings(
            kind: .compact,
            isVisible: true,
            showTitle: false,
            selectedFieldIds: ["claude.five_hour", "claude.weekly"]
        )
        // Opt-in: a freshly built item shows the un-merged list.
        XCTAssertFalse(item.mergesGroupWindows)
        item.mergesGroupWindows = true
        let data = try JSONEncoder().encode(item)
        XCTAssertTrue(
            try JSONDecoder().decode(MenuBarItemSettings.self, from: data).mergesGroupWindows
        )
    }

    func testPreMergeSettingsDecodeWithMergingOff() throws {
        // Every settings file written before group merging existed: the bar
        // was arranged against the un-merged layout, so that is what it keeps.
        let json = """
        {"kind":"compact","isVisible":true,"showTitle":true,"layout":"singleLine",
         "selectedFieldIds":["claude.five_hour","claude.weekly"],"customLabels":{},
         "fieldStyles":{}}
        """
        let decoded = try JSONDecoder().decode(MenuBarItemSettings.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.mergesGroupWindows)
    }

    func testMergesGroupWindowsSurvivesAppSettingsRoundTrip() throws {
        var settings = AppSettings(
            displayMode: .remaining,
            refreshIntervalSeconds: 600,
            launchAtLogin: false,
            menuBarTextEnabled: true,
            mockEnabled: false
        )
        var item = settings.menuBarItem(.compact)
        item.mergesGroupWindows = true
        settings.setMenuBarItem(item)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(decoded.menuBarItem(.compact).mergesGroupWindows)
    }
}
