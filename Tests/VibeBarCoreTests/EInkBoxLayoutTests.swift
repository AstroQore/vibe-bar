import XCTest
@testable import VibeBarCore

final class EInkBoxLayoutTests: XCTestCase {
    private let frame = EInkRect(x: 0, y: 0, width: 296, height: 152)
    private var bounds: EInkRect { frame.inset(by: EInkInsets(all: 6)) }

    private func text(_ value: String) -> EInkNode {
        EInkNode(.text(value, font: .pixel12(bold: false), alignment: .leading))
    }

    func testFlexChildrenSplitTheLeftoverExactly() {
        let root = EInkNode(
            .row,
            width: .points(100),
            height: .points(20),
            gap: 4,
            children: [
                EInkNode(.fill, width: .points(20), height: .points(4)),
                EInkNode(.fill, width: .flex(1), height: .points(4)),
                EInkNode(.fill, width: .flex(1), height: .points(4))
            ]
        )
        let boxes = EInkBoxLayout.resolve(root, in: frame, bounds: frame)
        XCTAssertEqual(boxes.count, 3)
        XCTAssertEqual(boxes[0].frame.width, 20)
        XCTAssertEqual(boxes[1].frame.width + boxes[2].frame.width, 72)
        XCTAssertEqual(boxes[2].frame.maxX, 100)
    }

    func testJustifyModes() {
        func offsets(_ justify: EInkMainAlignment) -> [Int] {
            let root = EInkNode(
                .row,
                width: .points(100),
                height: .points(10),
                justify: justify,
                children: (0..<2).map { _ in EInkNode(.fill, width: .points(20), height: .points(10)) }
            )
            return EInkBoxLayout.resolve(root, in: frame, bounds: frame).map(\.frame.x)
        }
        XCTAssertEqual(offsets(.start), [0, 20])
        XCTAssertEqual(offsets(.center), [30, 50])
        XCTAssertEqual(offsets(.end), [60, 80])
        XCTAssertEqual(offsets(.between), [0, 80])
    }

    func testCrossAlignment() {
        func origin(_ align: EInkCrossAlignment) -> Int {
            let root = EInkNode(
                .row,
                width: .points(100),
                height: .points(40),
                align: align,
                children: [EInkNode(.fill, width: .points(10), height: .points(10))]
            )
            return EInkBoxLayout.resolve(root, in: frame, bounds: frame)[0].frame.y
        }
        XCTAssertEqual(origin(.start), 0)
        XCTAssertEqual(origin(.center), 15)
        XCTAssertEqual(origin(.end), 30)
    }

    func testPaddingInsetsTheContentBox() {
        let root = EInkNode(
            .column,
            width: .points(100),
            height: .points(60),
            padding: EInkInsets(all: 6),
            children: [EInkNode(.fill, width: .flex(1), height: .points(4))]
        )
        let box = EInkBoxLayout.resolve(root, in: frame, bounds: frame)[0].frame
        XCTAssertEqual(box.x, 6)
        XCTAssertEqual(box.y, 6)
        XCTAssertEqual(box.width, 88)
    }

    func testBarsEmitAnOutlineAndAnInsetFill() {
        let root = EInkNode(.horizontalBar(percent: 50), width: .points(100), height: .points(10))
        let boxes = EInkBoxLayout.resolve(root, in: frame, bounds: frame)
        XCTAssertEqual(boxes.count, 2)
        XCTAssertEqual(boxes[0].content, .outline)
        XCTAssertEqual(boxes[1].content, .fill)
        XCTAssertEqual(boxes[1].frame, EInkRect(x: 1, y: 1, width: 49, height: 8))

        let vertical = EInkNode(.verticalBar(percent: 25), width: .points(20), height: .points(100))
        let verticalBoxes = EInkBoxLayout.resolve(vertical, in: frame, bounds: frame)
        XCTAssertEqual(verticalBoxes[1].frame.maxY, 99)
        XCTAssertEqual(verticalBoxes[1].frame.height, 25)

        let empty = EInkBoxLayout.resolve(
            EInkNode(.horizontalBar(percent: 0), width: .points(100), height: .points(10)),
            in: frame,
            bounds: frame
        )
        XCTAssertEqual(empty.count, 1, "a zero-percent bar is the track alone")
    }

    func testRingEmitsTheArcAndItsCentredLabel() {
        let root = EInkNode(
            .ring(percent: 62, stroke: 6, labelFont: .sans(size: 14, bold: true)),
            width: .points(48),
            height: .points(48)
        )
        let boxes = EInkBoxLayout.resolve(root, in: frame, bounds: frame)
        XCTAssertEqual(boxes[0].content, .ring(percent: 62, stroke: 6))
        XCTAssertEqual(boxes[1].content, .text("62", font: .sans(size: 14, bold: true), alignment: .center))
        XCTAssertEqual(boxes[1].frame.width, 48)
    }

    func testEveryEmittedBoxIsClampedIntoTheSafeArea() {
        let root = EInkNode(
            .column,
            width: .points(296),
            height: .points(152),
            children: [text("AntiGravity AntiGravity AntiGravity AntiGravity AntiGravity")]
        )
        for box in EInkBoxLayout.resolve(root, in: frame) {
            XCTAssertTrue(bounds.contains(box.frame), "\(box.frame) escaped \(bounds)")
        }
    }

    func testEmptyTextIsNotEmitted() {
        let root = EInkNode(.column, width: .points(100), height: .points(20), children: [text("")])
        XCTAssertTrue(EInkBoxLayout.resolve(root, in: frame, bounds: frame).isEmpty)
    }

    func testPixelFontMetricsTrackTheDeviceMeasurements() {
        // Fusion Pixel 12 px, the font behind `text-pixel-12`. "AntiGravity"
        // measures 62 px on the device; the estimate must land on it and
        // never come in under.
        let font = EInkFont.pixel12(bold: false)
        XCTAssertEqual(EInkTextMetrics.width("AntiGravity", font: font), 63)
        XCTAssertEqual(EInkTextMetrics.width("REQUESTS", font: font), 56)
        XCTAssertEqual(EInkTextMetrics.width("TODAY $254", font: font), 69)
        XCTAssertEqual(EInkTextMetrics.width("292M tokens", font: font), 70)
        XCTAssertEqual(EInkTextMetrics.width("Claude Code", font: font), 67)
        XCTAssertEqual(EInkTextMetrics.width("\u{4E2D}\u{6587}", font: font), 24)
        XCTAssertGreaterThan(EInkTextMetrics.width("12345", font: .sans(size: 26, bold: true)), 60)
    }

    func testFillLengthRounding() {
        XCTAssertEqual(EInkBoxLayout.fillLength(100, percent: 0), 0)
        XCTAssertEqual(EInkBoxLayout.fillLength(100, percent: 100), 100)
        XCTAssertEqual(EInkBoxLayout.fillLength(10, percent: 55), 6)
        XCTAssertEqual(EInkBoxLayout.fillLength(10, percent: 250), 10)
        XCTAssertEqual(EInkBoxLayout.fillLength(0, percent: 50), 0)
    }
}
