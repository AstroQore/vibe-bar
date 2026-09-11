import XCTest
@testable import VibeBarCore

/// The contract every preset has to keep on a real panel: inside the safe
/// margin, inside the Canvas API's hard limits, and byte-identical between two
/// renders of the same input.
final class EInkPresetRenderTests: XCTestCase {
    private func selection(for preset: EInkPreset, count: Int) -> (EInkSlide, EInkDataSnapshot) {
        let snapshot: EInkDataSnapshot
        let slide: EInkSlide
        switch preset.selectionAxis {
        case .quotaFields:
            snapshot = EInkFixtures.snapshot()
            let fields = EInkFixtures.quotaRows(count: count).map(\.fieldID)
            slide = EInkFixtures.slide(preset: preset, fieldIDs: fields)
        case .usagePeriods:
            snapshot = EInkFixtures.snapshot()
            slide = EInkFixtures.slide(preset: preset, periods: Array(EInkUsagePeriod.allCases.prefix(count)))
        case .harnessRows:
            snapshot = EInkFixtures.snapshot(harnessCount: count)
            slide = EInkFixtures.slide(preset: preset)
        }
        return (slide, snapshot)
    }

    func testEveryPresetOrientationAndSelectionCountStaysInsideEveryLimit() throws {
        let safe = EInkInsets(all: Int(EInkCanvasLayout.safeMargin))
        for preset in EInkPreset.allCases {
            for orientation in EInkOrientation.allCases {
                let capacity = preset.capacity(for: orientation)
                for count in 1...capacity {
                    let (slide, snapshot) = selection(for: preset, count: count)
                    let device = EInkFixtures.device(orientation: orientation)
                    let label = "\(preset.rawValue)/\(orientation.rawValue)/\(count)"

                    let node = EInkRenderer.tree(
                        slide: slide,
                        orientation: orientation,
                        profile: device.profile,
                        snapshot: snapshot
                    )
                    let size = device.profile.frameSize(for: orientation)
                    let frame = EInkRect(x: 0, y: 0, width: size.width, height: size.height)
                    let bounds = frame.inset(by: safe)
                    for box in EInkBoxLayout.resolve(node, in: frame) {
                        XCTAssertTrue(bounds.contains(box.frame), "\(label): \(box.frame) escaped \(bounds)")
                    }

                    let payload = try EInkRenderer.render(slide: slide, device: device, snapshot: snapshot)
                    let json = try payload.jsonData()
                    XCTAssertLessThanOrEqual(payload.windowData.elementCount, 80, label)
                    XCTAssertLessThanOrEqual(payload.windowData.elementDepth, 16, label)
                    XCTAssertLessThanOrEqual(json.count, 128 * 1024, label)
                    for string in payload.windowData.allStrings {
                        XCTAssertLessThanOrEqual(string.count, 4000, label)
                    }
                    let text = try XCTUnwrap(String(data: json, encoding: .utf8))
                    XCTAssertFalse(text.contains("{{"), "\(label) contains the device's template marker")
                }
            }
        }
    }

    func testRenderingIsDeterministic() throws {
        let snapshot = EInkFixtures.snapshot()
        for preset in EInkPreset.allCases {
            let device = EInkFixtures.device(orientation: .degrees90)
            let slide = EInkFixtures.slide(preset: preset)
            let first = try EInkRenderer.render(slide: slide, device: device, snapshot: snapshot).jsonData()
            let second = try EInkRenderer.render(slide: slide, device: device, snapshot: snapshot).jsonData()
            XCTAssertEqual(first, second, preset.rawValue)
        }
    }

    func testFewerSelectedFieldsMeanFewerRows() throws {
        let snapshot = EInkFixtures.snapshot()
        let device = EInkFixtures.device(orientation: .degrees0)
        func elementCount(_ fields: [String]) throws -> Int {
            let slide = EInkFixtures.slide(preset: .quotaLedger, fieldIDs: fields)
            return try EInkRenderer.render(slide: slide, device: device, snapshot: snapshot).windowData.elementCount
        }
        let one = try elementCount(["claude.weekly"])
        let three = try elementCount(["claude.weekly", "codex.weekly", "grok.weekly"])
        XCTAssertLessThan(one, three)
    }

    func testSelectionOrderAndUnknownFieldsAreHonoured() {
        let snapshot = EInkFixtures.snapshot()
        let rows = snapshot.quotaRows(fieldIDs: ["codex.weekly", "nope.nope", "claude.weekly"], limit: 5)
        XCTAssertEqual(rows.map(\.fieldID), ["codex.weekly", "claude.weekly"])
        XCTAssertEqual(snapshot.quotaRows(fieldIDs: [], limit: 3).count, 3)
    }

    func testLongestInMiddlePlacesTheWidestNameCentrally() {
        let rows = EInkFixtures.quotaRows(count: 5)
        let ordered = EInkPresets.longestInMiddle(rows)
        XCTAssertEqual(ordered.count, 5)
        XCTAssertEqual(ordered[2].providerDisplayName, "AntiGravity")
        XCTAssertEqual(Set(ordered.map(\.fieldID)), Set(rows.map(\.fieldID)))
    }

    func testLongestFirstPutsTheWidestNameInTheWideColumn() {
        let rows = Array(EInkFixtures.quotaRows(count: 5)[2...4])
        let ordered = EInkPresets.longestFirst(rows)
        XCTAssertEqual(ordered.first?.providerDisplayName, "AntiGravity")
        XCTAssertEqual(ordered[1].providerDisplayName, "Grok")
        XCTAssertEqual(Set(ordered.map(\.fieldID)), Set(rows.map(\.fieldID)))
    }

    func testTaskAliasIsPlainEnglish() {
        let alias = EInkRenderer.defaultTaskAlias(slide: EInkFixtures.slide(preset: .usageTiles), orientation: .degrees270)
        XCTAssertEqual(alias, "Vibe Bar · Usage · Tiles · 270°")
    }

    func testRingsAppearAsImageElements() throws {
        let payload = try EInkRenderer.render(
            slide: EInkFixtures.slide(preset: .quotaRings),
            device: EInkFixtures.device(orientation: .degrees0),
            snapshot: EInkFixtures.snapshot()
        )
        let sources = payload.windowData.allStrings.filter { $0.hasPrefix("data:image/png;base64,") }
        XCTAssertEqual(sources.count, 5)
        XCTAssertTrue(payload.windowData.allStrings.contains("img-dither-none img-kernel-threshold"))
    }
}
