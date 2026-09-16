import XCTest
@testable import VibeBarCore

final class EInkScreenArrangementTests: XCTestCase {
    let devices = [EInkDeviceConfig(deviceID: "a"), EInkDeviceConfig(deviceID: "b")]
    var group: EInkScreenGroup {
        EInkScreenGroup(screens: [.init(deviceID: "a"), .init(deviceID: "b", y: 152)])
    }

    func testNearEdgesSnapIntoAnExactHorizontalJoin() {
        let move = EInkScreenArrangement.move("b", to: EInkPoint(x: 290, y: 6), group: group, devices: devices)
        XCTAssertEqual(move.x, 296)
        XCTAssertEqual(move.y, 0)
        XCTAssertEqual(move.verticalGuide, 296)
        let placed = EInkScreenArrangement.dropping("b", move: move, group: group, devices: devices)
        XCTAssertEqual(placed.screens[1], EInkScreenPlacement(deviceID: "b", x: 296, y: 0))
        XCTAssertNoThrow(try EInkScreenGroupRenderer.validate(placed, devices: devices))
    }

    func testNearEdgesSnapIntoAnExactVerticalJoin() {
        let move = EInkScreenArrangement.move("b", to: EInkPoint(x: 7, y: 145), group: group, devices: devices)
        XCTAssertEqual(move.x, 0)
        XCTAssertEqual(move.y, 152)
        XCTAssertEqual(move.horizontalGuide, 152)
    }

    func testDistantDragRemainsFreeWithoutGuides() {
        let move = EInkScreenArrangement.move("b", to: EInkPoint(x: 403, y: 505), group: group, devices: devices)
        XCTAssertEqual(move.x, 403)
        XCTAssertEqual(move.y, 505)
        XCTAssertNil(move.verticalGuide)
        XCTAssertNil(move.horizontalGuide)
    }

    func testOverlappingDropSettlesAgainstNearestFreeEdge() {
        let move = EInkScreenArrangement.move("b", to: EInkPoint(x: 250, y: 20), group: group, devices: devices)
        let placed = EInkScreenArrangement.dropping("b", move: move, group: group, devices: devices)
        XCTAssertEqual(placed.screens[1].x, 296)
        XCTAssertEqual(placed.screens[1].y, 20)
        XCTAssertNoThrow(try EInkScreenGroupRenderer.validate(placed, devices: devices))
    }

    func testRotatedScreenKeepsItsUprightDimensions() {
        var devices = devices
        devices[1].orientation = .degrees90
        let move = EInkScreenArrangement.move("b", to: EInkPoint(x: -148, y: 3), group: group, devices: devices)
        XCTAssertEqual(move.x, -152)
        XCTAssertEqual(move.y, 0)
        let placed = EInkScreenArrangement.dropping("b", move: move, group: group, devices: devices)
        XCTAssertEqual(placed.bounds(for: ["a", "b"], devices: devices)?.width, 448)
    }
}
