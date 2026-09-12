import XCTest
@testable import VibeBarCore

final class EInkCanvasLayoutTests: XCTestCase {
    private func layout(orientation: EInkOrientation = .degrees0) -> EInkCanvasLayout {
        EInkCanvasLayout(profile: .quote0, orientation: orientation)
    }

    func testCanvasSizeComesFromProfileAndOrientation() {
        XCTAssertEqual(layout().width, 296)
        XCTAssertEqual(layout().height, 152)
        XCTAssertEqual(layout(orientation: .degrees270).width, 152)
        XCTAssertEqual(layout(orientation: .degrees270).height, 296)
        XCTAssertEqual(EInkCanvasLayout.gridSpacing, 8)
        XCTAssertEqual(EInkCanvasLayout.pixelSpacing, 1)
        XCTAssertEqual(EInkCanvasLayout.safeMargin, 6)
    }

    func testNormalizedSnapsToWholePixelsAndClampsInside() {
        var canvas = layout()
        var element = EInkCanvasElement(kind: .text)
        element.x = 401.7
        element.y = -12.3
        element.width = 900
        element.height = 11.4
        canvas.elements = [element]
        let normalized = canvas.normalized()
        let placed = try! XCTUnwrap(normalized.elements.first)
        XCTAssertEqual(placed.x, placed.x.rounded())
        XCTAssertEqual(placed.y, placed.y.rounded())
        XCTAssertGreaterThanOrEqual(placed.x, 0)
        XCTAssertGreaterThanOrEqual(placed.y, 0)
        XCTAssertLessThanOrEqual(placed.x + placed.width, normalized.width)
        XCTAssertLessThanOrEqual(placed.y + placed.height, normalized.height)
    }

    /// Snapping is a gesture aid, not a re-arrangement: it moves a drag in
    /// eight-pixel steps and leaves a stored element exactly where it was put.
    /// Normalizing to the grid is what silently re-laid-out an exploded preset
    /// — whose boxes are at real device pixels — the moment the toggle moved.
    func testMajorGridSnappingMovesInEightPixelStepsAndLeavesStoredPixelsAlone() {
        var canvas = layout()
        canvas.snapToGrid = true
        let id = canvas.add(.text, x: 13, y: 21)
        let placed = try! XCTUnwrap(canvas.normalized().elements.first)
        XCTAssertEqual(placed.x, 13)
        XCTAssertEqual(placed.y, 21)

        let moved = canvas.moving([id], dx: 10, dy: -6, majorGrid: true)
        XCTAssertEqual(moved.elements.first?.x, 21)
        XCTAssertEqual(moved.elements.first?.y, 13)
    }

    func testMovingClampsTheSelectionAsAUnit() {
        var canvas = layout()
        let first = canvas.add(.text, x: 8, y: 8)
        let second = canvas.add(.ring, x: 80, y: 40)
        let moved = canvas.moving([first, second], dx: -400, dy: -400)
        let boxes = moved.elements
        XCTAssertEqual(boxes.map(\.x).min(), 0)
        XCTAssertEqual(boxes.map(\.y).min(), 0)
        // Relative offsets survive the clamp.
        XCTAssertEqual(boxes[1].x - boxes[0].x, 72)
        XCTAssertEqual(boxes[1].y - boxes[0].y, 32)
    }

    func testAddResizeDuplicateGroupUngroupReorder() {
        var canvas = layout()
        let ring = canvas.add(.ring)
        let bar = canvas.add(.horizontalBar)
        XCTAssertEqual(canvas.elements.count, 2)

        canvas.resize(ring, width: 32, height: 32)
        XCTAssertEqual(canvas.elements.first { $0.id == ring }?.width, 32)

        canvas.group([ring, bar])
        let groupID = try! XCTUnwrap(canvas.elements.first?.groupID)
        XCTAssertTrue(canvas.elements.allSatisfy { $0.groupID == groupID })
        XCTAssertEqual(canvas.expandedSelection([ring]), Set(canvas.elements.map(\.id)))

        let copies = canvas.duplicate([ring])
        XCTAssertEqual(copies.count, 2, "duplicating one member copies the whole group")
        XCTAssertEqual(canvas.elements.count, 4)

        canvas.reorder(ring, by: -1)
        XCTAssertEqual(canvas.elements.count, 4)
        // A group stays contiguous after a z-order move.
        let layers = canvas.elements.map { $0.groupID ?? $0.id }
        XCTAssertEqual(layers, [layers[0], layers[0], layers[2], layers[2]])

        canvas.ungroup([ring])
        XCTAssertNil(canvas.elements.first { $0.id == ring }?.groupID)
    }

    func testEveryElementKindHasSaneDefaults() {
        for kind in EInkCanvasElement.Kind.allCases {
            let element = EInkCanvasElement(kind: kind)
            XCTAssertGreaterThan(element.width, 0, "\(kind)")
            XCTAssertGreaterThan(element.height, 0, "\(kind)")
        }
        XCTAssertEqual(EInkCanvasElement.Kind.usageTrend.preset, .usageTrend)
        XCTAssertNil(EInkCanvasElement.Kind.text.preset)
        // Eight primitives — the six the Studio's palette offers plus the
        // two only the exploder produces (`fill`, `image`) — and one
        // whole-preset block per user-selectable preset. `alert` is the
        // engine's, so it has no block.
        XCTAssertEqual(EInkCanvasElement.Kind.allCases.count, 8 + EInkPreset.userSelectable.count)
    }

    func testCodableRoundTrip() throws {
        var canvas = layout(orientation: .degrees90)
        canvas.add(.statTile, fieldID: "claude.weekly")
        canvas.add(.divider)
        canvas.add(.usageTiles)
        canvas = canvas.normalized()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(canvas)
        XCTAssertEqual(try JSONDecoder().decode(EInkCanvasLayout.self, from: data), canvas)
    }

    func testTolerantDecodeOfUnknownFields() throws {
        let json = """
        {"width": "wide", "height": null, "snapToGrid": 3,
         "elements": [{"kind": "hologram", "x": "left", "font": {"family": "sans", "size": 2}}]}
        """
        let decoded = try JSONDecoder().decode(EInkCanvasLayout.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.width, 296)
        XCTAssertEqual(decoded.height, 152)
        // A layout with no readable flag snaps: it is the default the Studio
        // opens with, and the toggle no longer rewrites anything.
        XCTAssertTrue(decoded.snapToGrid)
        XCTAssertEqual(decoded.elements.first?.kind, .text)
        XCTAssertEqual(decoded.elements.first?.font, .sans(size: EInkFont.minimumSansSize, bold: false))
    }

    func testFontRulesEnforceTheMinimumSizes() {
        XCTAssertEqual(EInkFont.sans(size: 4, bold: true).normalized, .sans(size: 13, bold: true))
        XCTAssertEqual(EInkFont.pixel12(bold: true).pointSize, 12)
        XCTAssertEqual(EInkFont.sans(size: 24, bold: true).lineHeight, 24)
        XCTAssertTrue(EInkFont.pixel12(bold: true).isBold)
    }
}
