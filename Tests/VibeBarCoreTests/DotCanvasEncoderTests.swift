import XCTest
@testable import VibeBarCore

final class DotCanvasEncoderTests: XCTestCase {
    private func object(_ value: DotCanvasValue) throws -> [String: Any] {
        let data = try DotCanvasPayload.jsonEncoder().encode(value)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func rootProps(_ payload: DotCanvasPayload) throws -> [String: Any] {
        let window = try object(payload.windowData)
        let root = try XCTUnwrap((window["default"] as? [[String: Any]])?.first)
        return try XCTUnwrap(root["props"] as? [String: Any])
    }

    private func sampleTree() -> EInkNode {
        EInkNode(
            .column,
            width: .points(296),
            height: .points(152),
            padding: EInkInsets(all: 6),
            children: [EInkNode(.text("VIBE BAR", font: .pixel12(bold: true), alignment: .leading), height: .points(14))]
        )
    }

    func testPayloadShapeMatchesTheDeviceContract() throws {
        let payload = try DotCanvasEncoder.encode(
            sampleTree(),
            orientation: .degrees0,
            refreshNow: true,
            taskKey: "task-key-0001",
            taskAlias: "Vibe Bar",
            generatedAtISO: "2026-01-01T00:00:00Z"
        )
        let json = try JSONSerialization.jsonObject(with: try payload.jsonData()) as? [String: Any]
        let body = try XCTUnwrap(json)
        XCTAssertEqual(body["refreshNow"] as? Bool, true)
        XCTAssertEqual(body["taskKey"] as? String, "task-key-0001")
        XCTAssertEqual(body["taskAlias"] as? String, "Vibe Bar")
        XCTAssertEqual(body["border"] as? Int, 0)
        let layoutFull = try XCTUnwrap(body["layoutFull"] as? [String: Any])
        XCTAssertEqual(layoutFull["tw"] as? String, "p-0 bg-white")
        XCTAssertEqual((layoutFull["style"] as? [String: Any])?["padding"] as? Int, 0)
        XCTAssertEqual((body["data"] as? [String: Any])?["generatedAt"] as? String, "2026-01-01T00:00:00Z")
        XCTAssertNotNil((body["windowData"] as? [String: Any])?["default"])
    }

    func testOptionalTaskFieldsAreOmittedNotNulled() throws {
        let payload = try DotCanvasEncoder.encode(sampleTree(), orientation: .degrees0)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: try payload.jsonData()) as? [String: Any])
        XCTAssertNil(body["taskKey"])
        XCTAssertNil(body["taskAlias"])
    }

    func testLandscapeRootCarriesThePanelSize() throws {
        let payload = try DotCanvasEncoder.encode(sampleTree(), orientation: .degrees0)
        let style = try XCTUnwrap(try rootProps(payload)["style"] as? [String: Any])
        XCTAssertEqual(style["width"] as? Int, 296)
        XCTAssertEqual(style["height"] as? Int, 152)
        XCTAssertEqual(style["position"] as? String, "relative")
        XCTAssertNil(style["transform"], "an unrotated layout needs no wrapper transform")
    }

    func testPortraitWrapperUsesTheVerifiedOffsetsAndTransform() throws {
        for (orientation, degrees) in [(EInkOrientation.degrees90, 90), (.degrees270, -90)] {
            let tree = EInkNode(
                .column,
                width: .points(152),
                height: .points(296),
                padding: EInkInsets(all: 6),
                children: [EInkNode(.text("VIBE BAR", font: .pixel12(bold: true), alignment: .leading), height: .points(14))]
            )
            let payload = try DotCanvasEncoder.encode(tree, orientation: orientation)
            let props = try rootProps(payload)
            let wrapper = try XCTUnwrap((props["children"] as? [[String: Any]])?.first)
            let style = try XCTUnwrap((wrapper["props"] as? [String: Any])?["style"] as? [String: Any])
            XCTAssertEqual(style["position"] as? String, "absolute")
            XCTAssertEqual(style["left"] as? Int, 72)
            XCTAssertEqual(style["top"] as? Int, -72)
            XCTAssertEqual(style["width"] as? Int, 152)
            XCTAssertEqual(style["height"] as? Int, 296)
            XCTAssertEqual(style["transform"] as? String, "rotate(\(degrees)deg)")
            XCTAssertEqual(style["transformOrigin"] as? String, "center")
        }
    }

    func testUpsideDownWrapperIsFullSize() throws {
        let payload = try DotCanvasEncoder.encode(sampleTree(), orientation: .degrees180)
        let props = try rootProps(payload)
        let wrapper = try XCTUnwrap((props["children"] as? [[String: Any]])?.first)
        let style = try XCTUnwrap((wrapper["props"] as? [String: Any])?["style"] as? [String: Any])
        XCTAssertEqual(style["left"] as? Int, 0)
        XCTAssertEqual(style["top"] as? Int, 0)
        XCTAssertEqual(style["width"] as? Int, 296)
        XCTAssertEqual(style["height"] as? Int, 152)
        XCTAssertEqual(style["transform"] as? String, "rotate(180deg)")
    }

    func testEveryBoxKindEncodesToItsDeviceElement() throws {
        let boxes = [
            EInkDrawBox(frame: EInkRect(x: 6, y: 6, width: 100, height: 14), content: .text("$121,216", font: .sans(size: 18, bold: true), alignment: .trailing)),
            EInkDrawBox(frame: EInkRect(x: 6, y: 24, width: 100, height: 10), content: .outline),
            EInkDrawBox(frame: EInkRect(x: 7, y: 25, width: 50, height: 8), content: .fill),
            EInkDrawBox(frame: EInkRect(x: 6, y: 40, width: 48, height: 48), content: .ring(percent: 62, stroke: 6))
        ]
        let payload = try DotCanvasEncoder.encode(boxes: boxes, orientation: .degrees0)
        let children = try XCTUnwrap(try rootProps(payload)["children"] as? [[String: Any]])
        XCTAssertEqual(children.map { $0["type"] as? String }, ["span", "div", "div", "img"])

        let span = try XCTUnwrap(children[0]["props"] as? [String: Any])
        XCTAssertEqual(span["tw"] as? String, "text-[18px]-chillduansans text-black font-bold text-right justify-end")
        let spanStyle = try XCTUnwrap(span["style"] as? [String: Any])
        XCTAssertEqual(spanStyle["textAlign"] as? String, "right")
        XCTAssertEqual(spanStyle["whiteSpace"] as? String, "nowrap")
        XCTAssertEqual(spanStyle["lineHeight"] as? String, "18px")
        XCTAssertEqual(spanStyle["left"] as? Int, 6)

        let outline = try XCTUnwrap(children[1]["props"] as? [String: Any])
        let outlineStyle = try XCTUnwrap(outline["style"] as? [String: Any])
        XCTAssertEqual(outlineStyle["borderWidth"] as? Int, 1)
        XCTAssertEqual(outlineStyle["borderStyle"] as? String, "solid")
        XCTAssertEqual(outlineStyle["borderColor"] as? String, "black")
        XCTAssertEqual(outline["tw"] as? String, "flex bg-white")
        XCTAssertEqual((children[2]["props"] as? [String: Any])?["tw"] as? String, "flex bg-black")

        let image = try XCTUnwrap(children[3]["props"] as? [String: Any])
        XCTAssertEqual(image["tw"] as? String, "img-dither-none img-kernel-threshold")
        XCTAssertTrue((image["src"] as? String)?.hasPrefix("data:image/png;base64,") == true)
    }

    func testAlignmentEmitsBothTheTextAndFlexClass() {
        XCTAssertEqual(DotCanvasEncoder.alignmentClass(for: .leading), "text-left justify-start")
        XCTAssertEqual(DotCanvasEncoder.alignmentClass(for: .center), "text-center justify-center")
        XCTAssertEqual(DotCanvasEncoder.alignmentClass(for: .trailing), "text-right justify-end")
    }

    func testPixelFontUsesTheUnsuffixedDeviceClass() {
        XCTAssertEqual(DotCanvasEncoder.twClass(for: .pixel12(bold: false)), "text-pixel-12 text-black")
        XCTAssertEqual(DotCanvasEncoder.twClass(for: .pixel12(bold: true)), "text-pixel-12 text-black font-bold")
        XCTAssertEqual(DotCanvasEncoder.twClass(for: .sans(size: 26, bold: true)), "text-[26px]-chillduansans text-black font-bold")
    }

    func testTooManyElementsAreRejectedWithTheCount() {
        let boxes = (0..<120).map {
            EInkDrawBox(frame: EInkRect(x: 0, y: $0, width: 4, height: 1), content: .fill)
        }
        XCTAssertThrowsError(try DotCanvasEncoder.encode(boxes: boxes, orientation: .degrees0)) { error in
            guard case let .limitsExceeded(violations) = error as? DotCanvasEncoder.EncodeError else {
                return XCTFail("expected a limit violation, got \(error)")
            }
            XCTAssertEqual(violations, [.elementCount(121)])
            XCTAssertTrue(String(describing: error).contains("121"))
        }
    }

    func testOverlongStringIsRejected() {
        let boxes = [
            EInkDrawBox(
                frame: EInkRect(x: 0, y: 0, width: 100, height: 12),
                content: .text(String(repeating: "A", count: 4001), font: .pixel12(bold: false), alignment: .leading)
            )
        ]
        XCTAssertThrowsError(try DotCanvasEncoder.encode(boxes: boxes, orientation: .degrees0)) { error in
            guard case let .limitsExceeded(violations) = error as? DotCanvasEncoder.EncodeError else {
                return XCTFail("expected a limit violation, got \(error)")
            }
            XCTAssertEqual(violations, [.stringTooLong(length: 4001)])
        }
    }

    func testTemplateMarkerIsRejected() {
        let boxes = [
            EInkDrawBox(
                frame: EInkRect(x: 0, y: 0, width: 100, height: 12),
                content: .text("{{ total }}", font: .pixel12(bold: false), alignment: .leading)
            )
        ]
        XCTAssertThrowsError(try DotCanvasEncoder.encode(boxes: boxes, orientation: .degrees0)) { error in
            guard case let .limitsExceeded(violations) = error as? DotCanvasEncoder.EncodeError else {
                return XCTFail("expected a limit violation, got \(error)")
            }
            XCTAssertEqual(violations, [.templateMarker("windowData")])
        }
    }

    func testEncodingIsDeterministic() throws {
        let first = try DotCanvasEncoder.encode(sampleTree(), orientation: .degrees90).jsonData()
        let second = try DotCanvasEncoder.encode(sampleTree(), orientation: .degrees90).jsonData()
        XCTAssertEqual(first, second)
    }
}
