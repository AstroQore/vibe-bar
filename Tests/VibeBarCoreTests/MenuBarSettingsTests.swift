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
}
