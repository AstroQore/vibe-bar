import XCTest
@testable import VibeBarCore

/// The pure half of "a group is one display": how a page reads across its
/// screens, what a new page starts as, and what the roster lists.
final class EInkDisplayRosterTests: XCTestCase {
    private var devices: [EInkDeviceConfig] {
        [
            EInkDeviceConfig(deviceID: "top", alias: "Desk"),
            EInkDeviceConfig(deviceID: "bottom", alias: "Shelf"),
            EInkDeviceConfig(deviceID: "side", alias: "Wall")
        ]
    }

    private func group(_ ids: [String]) -> EInkScreenGroup {
        EInkScreenGroup(
            name: "Pair",
            screens: ids.enumerated().map { EInkScreenPlacement(deviceID: $1, x: 0, y: $0 * 152) }
        )
    }

    private func slide(_ fields: [String]) -> EInkSlide {
        EInkSlide(id: UUID().uuidString, kind: .preset(.quotaLedger), quotaFieldIDs: fields)
    }

    // MARK: - Reading a page

    func testAPageIsCombinedSeparateOrCustomByWhatItsRegionsCover() {
        let ids = ["top", "bottom"]
        let combined = EInkScreenFrame(regions: [.init(deviceIDs: ids, slide: slide(["a"]))])
        XCTAssertEqual(combined.screenMode(screenIDs: ids), .combined)

        let separate = EInkScreenFrame(regions: [
            .init(deviceIDs: ["top"], slide: slide(["a"])),
            .init(deviceIDs: ["bottom"], slide: slide(["b"]))
        ])
        XCTAssertEqual(separate.screenMode(screenIDs: ids), .separate)

        let threeIDs = ["top", "bottom", "side"]
        let mixed = EInkScreenFrame(regions: [
            .init(deviceIDs: ["top", "bottom"], slide: slide(["a"])),
            .init(deviceIDs: ["side"], slide: slide(["b"]))
        ])
        XCTAssertEqual(mixed.screenMode(screenIDs: threeIDs), .custom)

        // A screen nobody assigned is not a separate page, whatever it looks
        // like: the reading has to stay honest or the picker lies.
        let partial = EInkScreenFrame(regions: [.init(deviceIDs: ["top"], slide: slide(["a"]))])
        XCTAssertEqual(partial.screenMode(screenIDs: ids), .custom)
    }

    // MARK: - Switching a page

    func testSeparateToCombinedKeepsEveryChosenBucket() {
        let ids = ["top", "bottom"]
        let frame = EInkScreenFrame(regions: [
            .init(deviceIDs: ["top"], slide: slide(["codex.weekly", "claude.weekly"])),
            .init(deviceIDs: ["bottom"], slide: slide(["claude.weekly", "gemini.daily"]))
        ])
        let combined = frame.settingMode(.combined, screenIDs: ids)
        XCTAssertEqual(combined.screenMode(screenIDs: ids), .combined)
        XCTAssertEqual(combined.regions.count, 1)
        XCTAssertEqual(combined.regions[0].deviceIDs, ids)
        XCTAssertEqual(
            combined.regions[0].slide.orderedQuotaFieldIDs,
            ["codex.weekly", "claude.weekly", "gemini.daily"]
        )
    }

    func testCombinedToSeparateGivesEveryScreenTheSameSelection() {
        let ids = ["top", "bottom", "side"]
        let frame = EInkScreenFrame(regions: [
            .init(deviceIDs: ids, slide: slide(["codex.weekly", "claude.weekly"]))
        ])
        let separate = frame.settingMode(.separate, screenIDs: ids)
        XCTAssertEqual(separate.screenMode(screenIDs: ids), .separate)
        XCTAssertEqual(separate.regions.map(\.deviceIDs), [["top"], ["bottom"], ["side"]])
        for region in separate.regions {
            XCTAssertEqual(region.slide.orderedQuotaFieldIDs, ["codex.weekly", "claude.weekly"])
        }
        // Distinct regions, so editing one screen cannot edit another.
        XCTAssertEqual(Set(separate.regions.map(\.id)).count, 3)
    }

    func testSeparateSurvivesARoundTripThroughCombined() {
        let ids = ["top", "bottom"]
        let frame = EInkScreenFrame(regions: [
            .init(id: "left", deviceIDs: ["top"], slide: slide(["codex.weekly"])),
            .init(id: "right", deviceIDs: ["bottom"], slide: slide(["claude.weekly"]))
        ])
        let back = frame
            .settingMode(.combined, screenIDs: ids)
            .settingMode(.separate, screenIDs: ids)
        XCTAssertEqual(back.screenMode(screenIDs: ids), .separate)
        for region in back.regions {
            XCTAssertEqual(region.slide.orderedQuotaFieldIDs, ["codex.weekly", "claude.weekly"])
        }
    }

    func testCustomIsLeftExactlyAsItWasAndAnUnassignedScreenIsSeeded() {
        let ids = ["top", "bottom", "side"]
        let frame = EInkScreenFrame(regions: [
            .init(deviceIDs: ["top", "bottom"], slide: slide(["codex.weekly"]))
        ])
        XCTAssertEqual(frame.settingMode(.custom, screenIDs: ids), frame)
        let separate = frame.settingMode(.separate, screenIDs: ids)
        XCTAssertEqual(separate.regions.map(\.deviceIDs), [["top"], ["bottom"], ["side"]])
        XCTAssertEqual(separate.regions[2].slide.orderedQuotaFieldIDs, ["codex.weekly"])
    }

    // MARK: - New pages

    func testANewPageStartsInTheModeItWasAskedFor() {
        let ids = ["top", "bottom"]
        let combined = EInkGroupSlides.newFrame(mode: .combined, screenIDs: ids, available: ["codex.weekly"])
        XCTAssertEqual(combined.screenMode(screenIDs: ids), .combined)
        XCTAssertEqual(combined.regions[0].slide.quotaFieldIDs, ["codex.weekly"])

        let separate = EInkGroupSlides.newFrame(mode: .separate, screenIDs: ids, available: ["codex.weekly"])
        XCTAssertEqual(separate.screenMode(screenIDs: ids), .separate)
        XCTAssertEqual(Set(separate.regions.map(\.slide.id)).count, 2)
    }

    func testCreatingAGroupCombinedUnionsTheScreensOwnSlides() {
        var first = devices[0]
        first.slides = [slide(["codex.weekly"])]
        var second = devices[1]
        second.slides = [slide(["claude.weekly"])]
        let group = EInkGroupSlides.create(name: "Pair", devices: [first, second], vertical: true, mode: .combined)
        XCTAssertEqual(group.frames.count, 1)
        XCTAssertEqual(group.frames[0].screenMode(screenIDs: group.orderedScreenIDs), .combined)
        XCTAssertEqual(
            group.frames[0].regions[0].slide.orderedQuotaFieldIDs,
            ["codex.weekly", "claude.weekly"]
        )
    }

    // MARK: - Order

    func testScreensAreOrderedDownThenAcross() {
        var group = group(["top", "bottom", "side"])
        group.screens = [
            .init(deviceID: "side", x: 296, y: 0),
            .init(deviceID: "bottom", x: 0, y: 152),
            .init(deviceID: "top", x: 0, y: 0)
        ]
        XCTAssertEqual(group.orderedScreenIDs, ["top", "side", "bottom"])
    }

    // MARK: - The roster

    func testAGroupTakesThePlaceOfItsFirstMemberAndItsMembersLeaveTheList() {
        let settings = EInkSyncSettings(devices: devices, groups: [group(["bottom", "side"])]).sanitized
        let entries = EInkDisplayRoster.entries(settings)
        XCTAssertEqual(entries.map(\.id), ["device:top", "group:" + settings.groups[0].id])
        XCTAssertEqual(
            EInkDisplayRoster.memberNames(of: settings.groups[0], devices: settings.devices),
            ["Shelf", "Wall"]
        )
    }

    func testAScreenBelongsToAtMostOneGroup() {
        var second = group(["side", "top"])
        second.id = "second"
        let settings = EInkSyncSettings(devices: devices, groups: [group(["top", "bottom"]), second]).sanitized
        XCTAssertEqual(settings.groups[0].screens.map(\.deviceID), ["top", "bottom"])
        XCTAssertEqual(settings.groups[1].screens.map(\.deviceID), ["side"])
        // Both groups are still listed, and no device is listed twice.
        let entries = EInkDisplayRoster.entries(settings)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.id), ["group:" + settings.groups[0].id, "group:second"])
    }
}
