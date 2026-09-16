import XCTest
@testable import VibeBarCore

final class EInkScreenGroupTests: XCTestCase {
    private var devices: [EInkDeviceConfig] {
        [EInkDeviceConfig(deviceID: "top"), EInkDeviceConfig(deviceID: "bottom")]
    }
    private var group: EInkScreenGroup {
        EInkScreenGroup(screens: [.init(deviceID: "top"), .init(deviceID: "bottom", y: 152)])
    }

    func testTwoLandscapeScreensStackInto296By304Canvas() throws {
        XCTAssertEqual(group.bounds(for: ["top", "bottom"], devices: devices), EInkRect(x: 0, y: 0, width: 296, height: 304))
        try EInkScreenGroupRenderer.validate(group, devices: devices)
    }

    func testRotatedAndNegativePlacementsUseUprightPixels() throws {
        var devices = devices
        devices[0].orientation = .degrees90
        var group = group
        group.screens = [.init(deviceID: "top", x: -152), .init(deviceID: "bottom")]
        XCTAssertEqual(group.bounds(for: ["top", "bottom"], devices: devices), EInkRect(x: -152, y: 0, width: 448, height: 296))
        try EInkScreenGroupRenderer.validate(group, devices: devices)
    }

    func testRejectsOverlapsAndDoubleAssignments() {
        var group = group
        group.screens[1].y = 100
        XCTAssertThrowsError(try EInkScreenGroupRenderer.validate(group, devices: devices))
        group.screens[1].y = 152
        let slide = EInkSlide(id: "page", kind: .preset(.quotaLedger))
        group.frames = [.init(regions: [.init(deviceIDs: ["top", "bottom"], slide: slide), .init(deviceIDs: ["top"], slide: slide)])]
        XCTAssertThrowsError(try EInkScreenGroupRenderer.validate(group, devices: devices))
    }

    func testSpanningTextKeepsTheSameBoxAcrossSeamWithoutReflow() throws {
        var layout = EInkCanvasLayout(profile: EInkDeviceProfile(width: 296, height: 304), orientation: .degrees0)
        var element = EInkCanvasElement(kind: .text)
        element.x = 20; element.y = 145; element.width = 200; element.height = 30; element.text = "Across the seam"; element.textBinding = .custom
        layout.elements = [element]
        let slide = EInkSlide(id: "page", kind: .custom(layoutID: "wide"))
        var group = group
        let frame = EInkScreenFrame(regions: [.init(deviceIDs: ["top", "bottom"], slide: slide)])
        group.frames = [frame]
        let boxes = try EInkScreenGroupRenderer.boxes(group: group, frame: frame, devices: devices,
            snapshot: EInkFixtures.snapshot(), layouts: ["wide": layout])
        let top = try XCTUnwrap(boxes["top"]?.first { if case .text("Across the seam", _, _) = $0.content { return true }; return false })
        let bottom = try XCTUnwrap(boxes["bottom"]?.first { $0.content == top.content })
        XCTAssertEqual(top.frame.y - bottom.frame.y, 152)
        XCTAssertEqual(top.frame.width, bottom.frame.width)
        XCTAssertEqual(top.frame.height, bottom.frame.height)
        XCTAssertLessThan(bottom.frame.y, 0)
        let payload = try DotCanvasEncoder.encode(boxes: boxes["bottom"]!, orientation: .degrees0)
        XCTAssertTrue(payload.windowData.allStrings.contains("hidden"))
    }

    func testSeparatePagesAndBlankScreensRemainIndependent() throws {
        var group = group
        let slide = EInkSlide(id: "page", kind: .preset(.quotaLedger))
        let frame = EInkScreenFrame(regions: [.init(deviceIDs: ["top"], slide: slide)])
        group.frames = [frame]
        let boxes = try EInkScreenGroupRenderer.boxes(group: group, frame: frame, devices: devices, snapshot: EInkFixtures.snapshot(), layouts: [:])
        XCTAssertFalse(boxes["top"]!.isEmpty)
        XCTAssertTrue(boxes["bottom"]!.isEmpty)
    }

    func testSettingsMigrateAndRetainGroupFields() throws {
        let old = try JSONDecoder().decode(EInkSyncSettings.self, from: Data(#"{"devices":[]}"#.utf8))
        XCTAssertEqual(old.groups, [])
        var group = group
        group.frames = [.init(regions: [.init(deviceIDs: ["top", "bottom"], slide: .init(id: "page", kind: .preset(.quotaLedger), quotaFieldIDs: ["extra.weekly"]))])]
        let settings = EInkSyncSettings(devices: devices, groups: [group])
        XCTAssertEqual(try JSONDecoder().decode(EInkSyncSettings.self, from: JSONEncoder().encode(settings)), settings)
        XCTAssertTrue(settings.selectedQuotaFieldIDs.contains("extra.weekly"))
        XCTAssertTrue(settings.referencedQuotaFieldIDs.contains("extra.weekly"))
    }
}
