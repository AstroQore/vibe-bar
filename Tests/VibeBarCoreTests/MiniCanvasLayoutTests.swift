import XCTest
@testable import VibeBarCore

final class MiniCanvasLayoutTests: XCTestCase {
    func testGroupMovesAsAUnitAndStopsAtCanvasEdges() {
        var canvas = MiniCanvasLayout()
        canvas.snapToGrid = false
        let a = canvas.add(.ring, fieldID: "codex.weekly", x: 10, y: 20)
        let b = canvas.add(.text, fieldID: "claude.weekly", x: 130, y: 40)
        canvas.group([a, b])
        let moved = canvas.moving([a], dx: 900, dy: -900)
        XCTAssertEqual(moved.elements[1].x + moved.elements[1].width, canvas.width)
        XCTAssertEqual(moved.elements[0].y, 0)
        XCTAssertEqual(moved.elements[1].x - moved.elements[0].x, 120)
        XCTAssertEqual(moved.elements[1].y - moved.elements[0].y, 20)
        XCTAssertEqual(canvas.elements[0].x, 10, "drag previews must not change their baseline")
    }

    func testDuplicateCreatesIndependentIDsAndGroupWhileKeepingBindingsAndAppearance() {
        var canvas = MiniCanvasLayout()
        let a = canvas.add(.sector, fieldID: "codex.weekly")
        let b = canvas.add(.text, fieldID: "codex.weekly")
        canvas.elements[1].textContent = .custom
        canvas.elements[1].text = "Hello"
        canvas.elements[1].colour = .custom
        canvas.elements[1].x = canvas.width - canvas.elements[1].width
        canvas.group([a, b])
        let copies = canvas.duplicate([a])
        XCTAssertEqual(copies.count, 2)
        XCTAssertTrue(copies.isDisjoint(with: [a, b]))
        XCTAssertEqual(canvas.elements[3].text, "Hello")
        XCTAssertEqual(canvas.elements[3].fieldID, "codex.weekly")
        XCTAssertEqual(canvas.elements[2].groupID, canvas.elements[3].groupID)
        XCTAssertNotEqual(canvas.elements[0].groupID, canvas.elements[2].groupID)
        XCTAssertEqual(canvas.elements[2].x - canvas.elements[0].x, canvas.elements[3].x - canvas.elements[1].x)
        canvas.ungroup(copies)
        XCTAssertNil(canvas.elements[2].groupID)
        XCTAssertNotNil(canvas.elements[0].groupID)
    }

    func testMalformedGeometryIsFiniteContainedAndHasUniqueIDs() {
        var canvas = MiniCanvasLayout()
        _ = canvas.add(.ring, fieldID: nil)
        canvas.elements.append(canvas.elements[0])
        canvas.width = .infinity; canvas.height = -2
        canvas.elements[0].width = 9000; canvas.elements[0].height = .nan
        canvas.elements[0].x = 2000; canvas.elements[0].y = -500
        canvas.elements[0].fontSize = .infinity
        let safe = canvas.normalized()
        XCTAssertEqual(safe.elements.count, 1)
        XCTAssertEqual(safe.width, 288)
        XCTAssertEqual(safe.height, 96)
        XCTAssertEqual(safe.elements[0].x, 0)
        XCTAssertEqual(safe.elements[0].y, 0)
        XCTAssertLessThanOrEqual(safe.elements[0].height, safe.height)
        XCTAssertNoThrow(try JSONEncoder().encode(safe))
    }

    func testEveryElementAndCustomModeSurviveSettingsRoundTripAndStyleSwitch() throws {
        var settings = AppSettings.default
        let id = settings.miniWindow.windows[0].id
        var canvas = MiniCanvasLayout()
        for kind in MiniCanvasElement.Kind.allCases { _ = canvas.add(kind, fieldID: "codex.weekly") }
        settings.miniCanvasLayouts[id.uuidString] = canvas
        settings.miniWindow.windows[0].displayMode = .custom
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.miniCanvasLayouts[id.uuidString], canvas)
        XCTAssertEqual(decoded.miniWindow.windows[0].displayMode, .custom)
        settings.miniWindow.windows[0].displayMode = .regular
        XCTAssertEqual(settings.miniCanvasLayouts[id.uuidString], canvas)
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).miniCanvasLayouts.isEmpty)
    }

    func testLegacyDefaultCycleDoesNotOpenAnEmptyCustomCanvas() {
        var window = MiniWindowConfig(name: "Mini", displayMode: .rail, fieldIds: [])
        XCTAssertEqual(window.nextDisplayMode(), .regular)
        window.cycleModes = [.rail, .custom]
        XCTAssertEqual(window.nextDisplayMode(), .custom)
    }

    func testGridIsDefaultAndFreeModePreservesArbitraryCoordinates() {
        var canvas = MiniCanvasLayout()
        XCTAssertTrue(canvas.snapToGrid)
        let id = canvas.add(.ring, fieldID: nil, x: 23, y: 35)
        XCTAssertEqual(canvas.elements[0].x, 24)
        XCTAssertEqual(canvas.elements[0].y, 24)
        XCTAssertEqual(canvas.elements[0].width, 48)
        let snapped = canvas.moving([id], dx: 15, dy: 7)
        XCTAssertEqual(snapped.elements[0].x, 48)
        XCTAssertEqual(snapped.elements[0].y, 24)
        canvas.snapToGrid = false
        let free = canvas.moving([id], dx: 11.5, dy: 7.25)
        XCTAssertEqual(free.elements[0].x, 35.5)
        XCTAssertEqual(free.elements[0].y, 31.25)
    }

    func testCanvasAndElementsAcceptArbitraryCellCountsBeyondTheShortcuts() {
        var canvas = MiniCanvasLayout()
        canvas.width = 12 * MiniCanvasLayout.gridSpacing
        canvas.height = 14 * MiniCanvasLayout.gridSpacing
        let id = canvas.add(.sector, fieldID: nil)
        for span in MiniCanvasLayout.Span.presets + [.init(4, 5), .init(7, 2)] {
            canvas.resize(id, to: span)
            XCTAssertEqual(canvas.elements[0].width, Double(span.columns) * MiniCanvasLayout.gridSpacing)
            XCTAssertEqual(canvas.elements[0].height, Double(span.rows) * MiniCanvasLayout.gridSpacing)
        }
        XCTAssertEqual(canvas.normalized().width / MiniCanvasLayout.gridSpacing, 12)
        XCTAssertEqual(canvas.normalized().height / MiniCanvasLayout.gridSpacing, 14)
    }

    func testPaletteClicksPlaceElementsIntoEmptyCells() {
        var canvas = MiniCanvasLayout()
        for kind in MiniCanvasElement.Kind.allCases { _ = canvas.add(kind, fieldID: nil) }
        for (i, a) in canvas.elements.enumerated() {
            let rect = CGRect(x: a.x, y: a.y, width: a.width, height: a.height)
            for b in canvas.elements.dropFirst(i + 1) {
                XCTAssertFalse(rect.intersects(CGRect(x: b.x, y: b.y, width: b.width, height: b.height)))
            }
        }
    }

    func testReorderingALoneElementCrossesAnEntireGroup() {
        var canvas = MiniCanvasLayout()
        let a = canvas.add(.ring, fieldID: nil)
        let b = canvas.add(.text, fieldID: nil)
        let c = canvas.add(.sector, fieldID: nil)
        canvas.group([a, b])
        let before = canvas
        canvas.reorder(c, by: -1)
        XCTAssertEqual(canvas.elements.map(\.id), [c, a, b])
        XCTAssertEqual(canvas.elements[1].groupID, canvas.elements[2].groupID)
        canvas.reorder(c, by: 1)
        XCTAssertEqual(canvas, before)
    }

    func testReorderingAGroupMovesAllChildrenAndStopsAtTheEnds() {
        var canvas = MiniCanvasLayout()
        let a = canvas.add(.ring, fieldID: nil)
        let b = canvas.add(.text, fieldID: nil)
        let c = canvas.add(.sector, fieldID: nil)
        canvas.group([a, b])
        canvas.reorder(b, by: 1)
        XCTAssertEqual(canvas.elements.map(\.id), [c, a, b])
        let atFront = canvas
        canvas.reorder(a, by: 1)
        XCTAssertEqual(canvas, atFront)
        canvas.reorder(a, by: -1)
        XCTAssertEqual(canvas.elements.map(\.id), [a, b, c])
    }

    @MainActor
    func testCanvasSurvivesRealSettingsSaveReloadAndAnExternalWindowEdit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        try JSONEncoder().encode(AppSettings.default).write(to: url)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MiniCanvasTests.\(UUID().uuidString)"))
        let store = SettingsStore(userDefaults: defaults, settingsURL: url)
        let id = store.settings.miniWindow.windows[0].id.uuidString
        var canvas = MiniCanvasLayout()
        _ = canvas.add(.sector, fieldID: "codex.weekly", x: 72, y: 40)
        store.settings.miniCanvasLayouts[id] = canvas
        store.flush()

        // A roster-only edit by an older client preserves unknown top-level keys.
        var external = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var roster = try XCTUnwrap(external["miniWindow"] as? [String: Any])
        var windows = try XCTUnwrap(roster["windows"] as? [[String: Any]])
        windows[0]["name"] = "Renamed elsewhere"
        roster["windows"] = windows
        external["miniWindow"] = roster
        try JSONSerialization.data(withJSONObject: external).write(to: url, options: .atomic)
        store.settings.refreshIntervalSeconds = 900
        store.flush()

        let reloaded = SettingsStore(userDefaults: defaults, settingsURL: url)
        XCTAssertEqual(reloaded.settings.miniCanvasLayouts[id], canvas)
        XCTAssertEqual(reloaded.settings.miniWindow.windows[0].name, "Renamed elsewhere")
        XCTAssertEqual(reloaded.settings.refreshIntervalSeconds, 900)
    }
}
