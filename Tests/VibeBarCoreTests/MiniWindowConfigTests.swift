import XCTest
@testable import VibeBarCore

final class MiniWindowConfigTests: XCTestCase {
    func testLegacySingleWindowSettingsMigrateToOneConfig() throws {
        let json = """
        {
            "displayMode": "compact",
            "selectedFieldIds": ["codex.weekly", "claude.five_hour"],
            "compactSelectedFieldIds": ["claude.weekly"],
            "customLabels": {"codex.weekly": "Wk"},
            "groupLabels": {},
            "wasOpen": true
        }
        """
        let settings = try JSONDecoder().decode(MiniWindowSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.windows.count, 1)
        let window = try XCTUnwrap(settings.windows.first)
        XCTAssertEqual(window.displayMode, .compact)
        // The active mode's list is the one the user was looking at.
        XCTAssertEqual(window.fieldIds, ["claude.weekly"])
        XCTAssertTrue(window.wasOpen)
        // Shared labels stay on the settings struct.
        XCTAssertEqual(settings.customLabels["codex.weekly"], "Wk")
        // Pre-dismissal settings decode to an empty dismissed set.
        XCTAssertTrue(settings.hiddenStaleFieldIds.isEmpty)
    }

    func testHiddenStaleFieldIdsSurviveRoundTrip() throws {
        var settings = MiniWindowSettings(selectedFieldIds: ["codex.weekly"])
        settings.hiddenStaleFieldIds = ["claude.weekly_opus", "claude.daily_routines"]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(MiniWindowSettings.self, from: data)
        XCTAssertEqual(decoded.hiddenStaleFieldIds, ["claude.weekly_opus", "claude.daily_routines"])
    }

    func testUnknownDisplayModeFallsBackInsteadOfFailingDecode() throws {
        let json = """
        {
            "displayMode": "holographic",
            "selectedFieldIds": ["codex.weekly"]
        }
        """
        let settings = try JSONDecoder().decode(MiniWindowSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.displayMode, .regular)
        XCTAssertEqual(settings.windows.first?.displayMode, .regular)
    }

    func testMultiWindowRoundTripPreservesEveryConfig() throws {
        var settings = MiniWindowSettings(selectedFieldIds: ["codex.weekly"])
        settings.windows = [
            MiniWindowConfig(name: "Left", displayMode: .ledger, fieldIds: ["claude.weekly", "codex.weekly"]),
            MiniWindowConfig(name: "Corner", displayMode: .strip, fieldIds: ["gemini.weekly"], wasOpen: true)
        ]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(MiniWindowSettings.self, from: data)
        XCTAssertEqual(decoded.windows, settings.windows)
        // The legacy mirror follows the first window so a downgraded build
        // still opens with something sensible.
        XCTAssertEqual(decoded.displayMode, .ledger)
        XCTAssertEqual(decoded.selectedFieldIds, ["claude.weekly", "codex.weekly"])
        XCTAssertFalse(decoded.wasOpen)
    }

    func testPerWindowOverridesAndDensitySurviveRoundTrip() throws {
        var settings = AppSettings.default
        settings.miniWindow.windows[0].displayMode = .strip
        settings.miniWindow.windows[0].stripDensity = .twoLine
        settings.miniWindow.windows[0].customLabels = ["codex.weekly": "Wk (mine)"]
        settings.miniWindow.windows[0].groupLabels = [
            "codex.all-models": "Everything",
            "subprovider:codex/ChatGPT Agentic": "GPT"
        ]
        settings.miniWindow.customLabels["codex.weekly"] = "Shared Wk"

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        let window = try XCTUnwrap(decoded.miniWindow.windows.first)

        XCTAssertEqual(window.stripDensity, .twoLine)
        XCTAssertEqual(window.customLabels["codex.weekly"], "Wk (mine)")
        XCTAssertEqual(window.groupLabels["codex.all-models"], "Everything")
        XCTAssertEqual(window.groupLabels["subprovider:codex/ChatGPT Agentic"], "GPT")
        // Resolution order: window override → shared → nil.
        XCTAssertEqual(
            decoded.miniWindow.resolvedFieldLabel(config: window, fieldId: "codex.weekly"),
            "Wk (mine)"
        )
        XCTAssertEqual(
            decoded.miniWindow.resolvedFieldLabel(config: nil, fieldId: "codex.weekly"),
            "Shared Wk"
        )
        XCTAssertNil(decoded.miniWindow.resolvedGroupLabel(config: window, key: "claude.all-models"))
    }

    func testDisplayModeCycleVisitsEveryModeOnce() {
        var seen: [MiniWindowDisplayMode] = []
        var mode = MiniWindowDisplayMode.regular
        for _ in 0..<MiniWindowDisplayMode.allCases.count {
            seen.append(mode)
            mode = mode.next
        }
        XCTAssertEqual(mode, .regular)
        XCTAssertEqual(Set(seen).count, MiniWindowDisplayMode.allCases.count)
    }

    func testUpsertReplacesInPlaceAndAppendsNew() {
        var settings = MiniWindowSettings(selectedFieldIds: ["codex.weekly"])
        let original = try! XCTUnwrap(settings.windows.first)
        var renamed = original
        renamed.name = "Renamed"
        settings.upsert(renamed)
        XCTAssertEqual(settings.windows.count, 1)
        XCTAssertEqual(settings.windows[0].name, "Renamed")
        let extra = MiniWindowConfig(name: "Second", fieldIds: [])
        settings.upsert(extra)
        XCTAssertEqual(settings.windows.count, 2)
        XCTAssertEqual(settings.config(id: extra.id)?.name, "Second")
    }
}
