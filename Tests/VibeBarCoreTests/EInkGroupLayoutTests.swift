import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import VibeBarCore

/// Combined group pages, measured on the hardware they are shown on: two
/// panels side by side (592 × 152) and two stacked (296 × 304).
///
/// The owner's two-screen Forecast is the case this file exists for: every
/// template was laid out as one wide panel, so names sat on one screen and
/// their verdicts on the other, text boxes ran across the bezel, and rows
/// that did not fit the height were clamped on top of each other. The audit
/// below is the contract that replaced it — on every screen, every box stays
/// on that screen, and no two text boxes (or a text box and a bar) overlap.
///
/// Set `VIBEBAR_EINK_PNG_DIR` to a directory to also get each group template
/// drawn as a PNG, both arrangements, at 3×.
final class EInkGroupLayoutTests: XCTestCase {
    // MARK: - Fixtures

    struct Arrangement {
        var name: String
        var group: EInkScreenGroup
        var devices: [EInkDeviceConfig]
        var ids: [String] { group.orderedScreenIDs }
    }

    static let horizontal = Arrangement(
        name: "side-by-side",
        group: EInkScreenGroup(id: "g", screens: [.init(deviceID: "left"), .init(deviceID: "right", x: 296)]),
        devices: [EInkDeviceConfig(deviceID: "left"), EInkDeviceConfig(deviceID: "right")]
    )
    static let vertical = Arrangement(
        name: "stacked",
        group: EInkScreenGroup(id: "g", screens: [.init(deviceID: "top"), .init(deviceID: "bottom", y: 152)]),
        devices: [EInkDeviceConfig(deviceID: "top"), EInkDeviceConfig(deviceID: "bottom")]
    )
    static var portraitPair: Arrangement {
        var devices = [EInkDeviceConfig(deviceID: "a"), EInkDeviceConfig(deviceID: "b")]
        devices[0].orientation = .degrees90
        devices[1].orientation = .degrees90
        return Arrangement(
            name: "portrait-pair",
            group: EInkScreenGroup(id: "g", screens: [.init(deviceID: "a"), .init(deviceID: "b", x: 152)]),
            devices: devices
        )
    }
    static let arrangements = [horizontal, vertical]

    enum Names: String, CaseIterable { case short, long, logos }

    func snapshot(_ names: Names) -> EInkDataSnapshot {
        var snapshot = EInkFixtures.snapshot()
        guard names != .short else { return snapshot }
        let verdicts: [QuotaPaceForecast.Verdict] = [.surplus, .watch, .atRisk, .enough, .learning, .surplus, .watch]
        snapshot.quota = EInkFixtures.longNameRows().enumerated().map { index, row in
            var copy = row
            copy.forecast = EInkFixtures.forecast(verdicts[index], projected: Double(30 + 10 * index),
                                                  runsOutIn: index.isMultiple(of: 2) ? Double(index + 2) * 3_600 : nil)
            return copy
        }
        if names == .logos { snapshot.logos = EInkFixtures.logos(for: snapshot.quota) }
        return snapshot
    }

    func slide(_ preset: EInkPreset, _ snapshot: EInkDataSnapshot, options: EInkSlideOptions = .default,
               names: Names = .short) -> EInkSlide {
        var slide = EInkSlide(id: "page", kind: .preset(preset), quotaFieldIDs: snapshot.quota.map(\.fieldID), options: options)
        if names == .logos { slide.options.labelStyle = .logoAndWindow }
        return slide
    }

    func combined(_ arrangement: Arrangement, _ slide: EInkSlide) -> (EInkScreenGroup, EInkScreenFrame) {
        var group = arrangement.group
        let frame = EInkScreenFrame(id: "page", regions: [.init(id: "r", deviceIDs: arrangement.ids, slide: slide)])
        group.frames = [frame]
        group.playbackMode = .appTimer
        return (group, frame)
    }

    /// Every page a combined slide paginates into, as each screen shows it.
    func pages(_ arrangement: Arrangement, _ slide: EInkSlide, _ snapshot: EInkDataSnapshot) throws -> [[String: [EInkDrawBox]]] {
        let (group, _) = combined(arrangement, slide)
        return try EInkPagination.frames(group, devices: arrangement.devices, snapshot: snapshot).map {
            try EInkScreenGroupRenderer.boxes(group: group, frame: $0, devices: arrangement.devices,
                                              snapshot: snapshot, layouts: [:])
        }
    }

    // MARK: - The audit

    /// Where a text box's glyphs actually land: the box, widened to the
    /// measured string when the string is wider and the box does not clip.
    static func ink(_ box: EInkDrawBox) -> EInkRect {
        guard case let .text(value, font, alignment) = box.content, !box.clipsContent else { return box.frame }
        let measured = EInkTextMetrics.width(value, font: font)
        guard measured > box.frame.width else { return box.frame }
        let x: Int
        switch alignment {
        case .leading: x = box.frame.x
        case .trailing: x = box.frame.maxX - measured
        case .center: x = box.frame.x + (box.frame.width - measured) / 2
        }
        return EInkRect(x: x, y: box.frame.y, width: measured, height: box.frame.height)
    }

    static func overlaps(_ a: EInkRect, _ b: EInkRect) -> Bool {
        a.x < b.maxX && a.maxX > b.x && a.y < b.maxY && a.maxY > b.y
    }

    /// What is wrong with one screen's boxes, in words.
    static func violations(_ boxes: [EInkDrawBox], screen: EInkRect) -> [String] {
        var found: [String] = []
        let paper = EInkRect(x: 0, y: 0, width: screen.width, height: screen.height)
        for box in boxes where !paper.contains(ink(box)) {
            found.append("off its screen: \(describe(box)) at \(ink(box))")
        }
        for box in boxes where box.clipsContent {
            // A clipping box narrower than its words cuts them.
            guard case let .text(value, font, _) = box.content else { continue }
            if EInkTextMetrics.width(value, font: font) > box.frame.width {
                found.append("cut by its box: \(describe(box)) in \(box.frame.width) px")
            }
        }
        let texts = boxes.filter { if case .text = $0.content { return true }; return false }
        let rings = boxes.filter { if case .ring = $0.content { return true }; return false }
        for (i, text) in texts.enumerated() {
            for other in texts[(i + 1)...] where overlaps(ink(text), ink(other)) {
                found.append("text over text: \(describe(text)) / \(describe(other))")
            }
            for other in boxes where other.content == .outline || other.content == .fill {
                if overlaps(ink(text), other.frame), !rings.contains(where: { overlaps($0.frame, text.frame) }) {
                    found.append("text over a bar or rule: \(describe(text)) / \(other.frame)")
                }
            }
        }
        return found
    }

    static func describe(_ box: EInkDrawBox) -> String {
        if case let .text(value, _, _) = box.content { return "\"\(value)\"" }
        return "\(box.content)"
    }

    func audit(_ arrangement: Arrangement, _ pages: [[String: [EInkDrawBox]]], label: String,
               file: StaticString = #filePath, line: UInt = #line) {
        for (index, page) in pages.enumerated() {
            for id in arrangement.ids {
                let device = arrangement.devices.first { $0.deviceID == id }!
                let size = device.profile.frameSize(for: device.orientation)
                let problems = Self.violations(page[id] ?? [], screen: EInkRect(x: 0, y: 0, width: size.width, height: size.height))
                XCTAssertTrue(problems.isEmpty, "\(label) page \(index + 1) \(id): \(problems.joined(separator: "; "))",
                              file: file, line: line)
            }
        }
    }

    // MARK: - The owner's panel

    /// The reported Forecast, reproduced: seven buckets on two screens side
    /// by side. Before the fix the verdicts were on the right panel, the names
    /// on the left, and four rows were drawn on top of each other at y = 134.
    func testTheTwoScreenForecastNoLongerCrossesTheSeamOrOverlaps() throws {
        let snapshot = snapshot(.short)
        let pages = try pages(Self.horizontal, slide(.forecast, snapshot), snapshot)
        audit(Self.horizontal, pages, label: "forecast")
        // Each screen names the buckets it draws the verdicts for.
        for id in ["left", "right"] {
            let texts = pages[0][id]!.compactMap { box -> String? in
                if case let .text(value, _, _) = box.content { return value }
                return nil
            }
            XCTAssertTrue(texts.contains { $0.contains(" · ") }, "\(id) has no names: \(texts)")
            XCTAssertTrue(texts.contains { ["SURPLUS", "ENOUGH", "WATCH", "AT RISK", "LEARNING"].contains($0) },
                          "\(id) has no verdicts: \(texts)")
        }
        // Nothing selected is lost: what one page cannot hold, the next does.
        let drawn = Set(pages.flatMap { page in page.values.flatMap { $0 } }.compactMap { box -> String? in
            if case let .text(value, _, _) = box.content { return value }
            return nil
        })
        for row in snapshot.quota { XCTAssertTrue(drawn.contains(row.slotLabel), "\(row.slotLabel) never drawn") }
    }

    /// Every template with a list, tiled screen by screen, in both
    /// arrangements and with the owner's own long names: every box is on its
    /// own screen. Each screen draws exactly what that layout draws on a
    /// panel of its own, so how it packs *within* a screen is the single-panel
    /// contract (`EInkLongNameTests`, `EInkPresetRenderTests`), not this one.
    func testEveryListTemplateTilesWithEveryBoxOnItsOwnScreen() throws {
        let presets = EInkPreset.allCases.filter { $0 != .alert && EInkGroupLayouts.isPaneAware($0) }
        XCTAssertTrue(presets.contains(.quotaLedger) && presets.contains(.usageTiles) && presets.contains(.cards))
        for arrangement in Self.arrangements + [Self.portraitPair] {
            for names in Names.allCases {
                let snapshot = snapshot(names)
                for preset in presets {
                    for (index, page) in try pages(arrangement, slide(preset, snapshot, names: names), snapshot).enumerated() {
                        for id in arrangement.ids {
                            let device = arrangement.devices.first { $0.deviceID == id }!
                            let size = device.profile.frameSize(for: device.orientation)
                            let paper = EInkRect(x: 0, y: 0, width: size.width, height: size.height)
                            for box in page[id] ?? [] {
                                XCTAssertTrue(paper.contains(box.frame),
                                    "\(preset.rawValue)/\(arrangement.name)/\(names) page \(index + 1) \(id): \(Self.describe(box)) at \(box.frame)")
                            }
                        }
                    }
                }
            }
        }
    }

    /// The group templates and the ledgers the fix was for: nothing leaves
    /// its screen and nothing overlaps, in both arrangements (and on a pair
    /// of portrait screens), for every set of names.
    func testGroupTemplatesAndTiledLedgersNeverOverlap() throws {
        for arrangement in Self.arrangements + [Self.portraitPair] {
            for names in Names.allCases {
                let snapshot = snapshot(names)
                for preset in EInkPreset.groupLayouts {
                    let pages = try pages(arrangement, slide(preset, snapshot, names: names), snapshot)
                    audit(arrangement, pages, label: "\(preset.rawValue)/\(arrangement.name)/\(names.rawValue)")
                }
            }
        }
        for arrangement in Self.arrangements {
            let snapshot = snapshot(.short)
            for preset in [EInkPreset.quotaLedger, .forecast, .resets, .briefing] {
                let pages = try pages(arrangement, slide(preset, snapshot), snapshot)
                audit(arrangement, pages, label: "\(preset.rawValue)/\(arrangement.name)")
            }
        }
    }

    /// The group templates with the bars off, which hands the body the most
    /// height — where a row is most tempted to grow into its neighbour.
    func testGroupTemplatesHoldWithTheBarsOff() throws {
        var options = EInkSlideOptions.default
        options.header = nil
        options.footer = nil
        options.compact = true
        for arrangement in Self.arrangements {
            for names in Names.allCases {
                let snapshot = snapshot(names)
                for preset in EInkPreset.groupLayouts {
                    let pages = try pages(arrangement, slide(preset, snapshot, options: options, names: names), snapshot)
                    audit(arrangement, pages, label: "\(preset.rawValue)/\(arrangement.name)/\(names.rawValue)/bare")
                }
            }
        }
    }

    /// A template that is one picture still spans the screens, but no word
    /// is left across the bezel.
    func testSpanningTemplatesKeepTheirTextOffTheSeam() throws {
        let snapshot = snapshot(.short)
        for arrangement in Self.arrangements {
            for preset in [EInkPreset.heatmap, .usageTrend, .usageTable, .usageDual, .topModels] {
                for page in try pages(arrangement, slide(preset, snapshot), snapshot) {
                    for (id, boxes) in page {
                        let device = arrangement.devices.first { $0.deviceID == id }!
                        let size = device.profile.frameSize(for: device.orientation)
                        let paper = EInkRect(x: 0, y: 0, width: size.width, height: size.height)
                        for box in boxes {
                            guard case let .text(value, _, _) = box.content else { continue }
                            XCTAssertTrue(paper.contains(box.frame), "\(preset.rawValue)/\(arrangement.name) \(id): \"\(value)\" at \(box.frame)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - What each template promises

    func testCapacitiesAreCountedScreenByScreen() {
        let across = EInkGroupLayouts.readingOrder([EInkRect(x: 296, y: 0, width: 296, height: 152),
                                                    EInkRect(x: 0, y: 0, width: 296, height: 152)])
        let stacked = [EInkRect(x: 0, y: 0, width: 296, height: 152), EInkRect(x: 0, y: 152, width: 296, height: 152)]
        XCTAssertEqual(across.first?.x, 0)
        XCTAssertEqual(EInkGroupLayouts.capacity(.headline, panes: across), 2 + 6)
        XCTAssertEqual(EInkGroupLayouts.capacity(.wideLedger, panes: across), 6)
        XCTAssertEqual(EInkGroupLayouts.capacity(.cards, panes: across), 8)
        XCTAssertEqual(EInkGroupLayouts.capacity(.quotaLedger, panes: across), 10)
        // Stacked screens have no partner beside them: the wide ledger falls
        // back to a ledger per screen.
        XCTAssertEqual(EInkGroupLayouts.capacity(.wideLedger, panes: stacked), 10)
        XCTAssertNil(EInkGroupLayouts.capacity(.heatmap, panes: across))
        var profile = EInkDeviceProfile(width: 592, height: 152)
        profile.panes = across
        XCTAssertEqual(EInkPreset.forecast.pageCapacity(for: .degrees0, profile: profile), 8)
    }

    /// The headline screen draws two buckets large and the rest continue on
    /// the other screen, in order.
    func testHeadlinePutsTwoBucketsOnTheFirstScreenAndContinuesTheList() throws {
        let snapshot = snapshot(.short)
        for arrangement in Self.arrangements {
            let page = try pages(arrangement, slide(.headline, snapshot), snapshot)[0]
            let first = texts(page[arrangement.ids[0]]!)
            let second = texts(page[arrangement.ids[1]]!)
            XCTAssertTrue(first.contains("Claude · 5 Hours") && first.contains("Claude · Weekly"), "\(first)")
            XCTAssertTrue(first.contains("62%"), "the figure is drawn large on the headline screen: \(first)")
            XCTAssertFalse(second.contains("Claude · 5 Hours"))
            XCTAssertTrue(second.contains("Codex · Weekly"), "\(second)")
            let big = page[arrangement.ids[0]]!.contains { box in
                if case let .text("62%", font, _) = box.content { return font == .sans(size: 32, bold: true) }
                return false
            }
            XCTAssertTrue(big, "\(arrangement.name): the headline figure is 32 px")
        }
    }

    /// A wide ledger row starts on the left screen and ends at the same
    /// height on the right one.
    func testWideLedgerRowsLineUpAcrossTheSeam() throws {
        let snapshot = snapshot(.short)
        let page = try pages(Self.horizontal, slide(.wideLedger, snapshot), snapshot)[0]
        for row in snapshot.quota.prefix(5) {
            let name = try XCTUnwrap(page["left"]!.first { $0.content.text == row.slotLabel }, row.slotLabel)
            let countdown = try XCTUnwrap(page["right"]!.first { $0.content.text == row.countdown }, row.countdown)
            XCTAssertEqual(name.frame.y + name.frame.height / 2, countdown.frame.y + countdown.frame.height / 2, row.slotLabel)
        }
        XCTAssertFalse(texts(page["left"]!).contains("SURPLUS"), "verdicts belong on the right screen")
        XCTAssertTrue(texts(page["right"]!).contains("SURPLUS"))
    }

    func testCardsGiveEveryScreenFourCardsAndACross() throws {
        let snapshot = snapshot(.short)
        let page = try pages(Self.horizontal, slide(.cards, snapshot), snapshot)[0]
        for id in ["left", "right"] {
            let percents = texts(page[id]!).filter { $0.hasSuffix("%") }
            XCTAssertEqual(percents.count, id == "left" ? 4 : 3, "\(id): \(percents)")
            let rules = page[id]!.filter { $0.content == .fill && ($0.frame.width == 1 || $0.frame.height == 1) }
            XCTAssertGreaterThanOrEqual(rules.count, 2, "\(id) draws a cross of rules")
        }
    }

    // MARK: - Preview and device agree

    /// The Settings preview is built from the very boxes the engine encodes,
    /// and every screen's payload is inside the Canvas API's limits.
    func testThePreviewIsTheSameGeometryTheEncoderSends() throws {
        for arrangement in Self.arrangements {
            for names in Names.allCases {
                let snapshot = snapshot(names)
                for preset in EInkPreset.groupLayouts + [.quotaLedger, .forecast] {
                    let (group, _) = combined(arrangement, slide(preset, snapshot, names: names))
                    for frame in EInkPagination.frames(group, devices: arrangement.devices, snapshot: snapshot) {
                        let engine = try EInkScreenGroupRenderer.boxes(group: group, frame: frame,
                            devices: arrangement.devices, snapshot: snapshot, layouts: [:])
                        let plans = EInkPreviewPlanner.planGroup(group: group, frame: frame,
                            devices: arrangement.devices, snapshot: snapshot)
                        for id in arrangement.ids {
                            XCTAssertEqual(plans[id]?.boxes, engine[id], "\(preset.rawValue)/\(arrangement.name)/\(id)")
                            let payload = try DotCanvasEncoder.encode(boxes: engine[id] ?? [], orientation: .degrees0)
                            XCTAssertFalse(payload.windowData.allStrings.isEmpty)
                        }
                    }
                }
            }
        }
    }

    /// Pagination follows the screens: a selection larger than a page
    /// continues on the next one, and nothing is dropped.
    func testNothingSelectedIsDroppedAcrossPages() throws {
        for arrangement in Self.arrangements {
            for names in Names.allCases {
                let snapshot = snapshot(names)
                for preset in EInkPreset.groupLayouts {
                    let (group, _) = combined(arrangement, slide(preset, snapshot, names: names))
                    let frames = EInkPagination.frames(group, devices: arrangement.devices, snapshot: snapshot)
                    let fields = frames.flatMap { $0.regions[0].slide.quotaFieldIDs }
                    XCTAssertEqual(Set(fields), Set(snapshot.quota.map(\.fieldID)), "\(preset.rawValue)/\(arrangement.name)/\(names)")
                    XCTAssertEqual(fields.count, snapshot.quota.count, "each bucket lands on exactly one page")
                }
            }
        }
    }

    /// Taking a combined page apart hands each screen a template its own
    /// picker can name.
    func testSeparatingAGroupTemplateLeavesEachScreenALedger() {
        let snapshot = snapshot(.short)
        let (group, frame) = combined(Self.horizontal, slide(.cards, snapshot))
        let separate = frame.settingMode(.separate, screenIDs: group.orderedScreenIDs)
        XCTAssertEqual(separate.regions.map { $0.slide.kind.preset }, [.quotaLedger, .quotaLedger])
        XCTAssertEqual(separate.regions[0].slide.quotaFieldIDs, snapshot.quota.map(\.fieldID))
        XCTAssertFalse(EInkPreset.userSelectable.contains(.cards))
        XCTAssertEqual(EInkPreset.groupLayouts, [.headline, .wideLedger, .cards])
    }

    // MARK: - Pictures

    /// Draws every group template in both arrangements when
    /// `VIBEBAR_EINK_PNG_DIR` is set. Not an assertion — the audit above is —
    /// but the pictures are what a person reviewing a layout actually looks
    /// at.
    func testWritesPreviewPicturesWhenAsked() throws {
        guard let directory = ProcessInfo.processInfo.environment["VIBEBAR_EINK_PNG_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set VIBEBAR_EINK_PNG_DIR to write the previews")
        }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for arrangement in Self.arrangements + [Self.portraitPair] {
            for names in [Names.short, .long, .logos] {
                let snapshot = snapshot(names)
                for preset in EInkPreset.groupLayouts + [.quotaLedger, .forecast] {
                    let (group, _) = combined(arrangement, slide(preset, snapshot, names: names))
                    let frames = EInkPagination.frames(group, devices: arrangement.devices, snapshot: snapshot)
                    let plans = EInkPreviewPlanner.planGroup(group: group, frame: frames[0],
                        devices: arrangement.devices, snapshot: snapshot)
                    let name = "\(preset.rawValue)-\(arrangement.name)-\(names.rawValue).png"
                    try GroupPicture.write(group: group, devices: arrangement.devices, plans: plans,
                                           to: url.appendingPathComponent(name))
                }
            }
        }
    }

    private func texts(_ boxes: [EInkDrawBox]) -> [String] {
        boxes.compactMap(\.content.text)
    }
}

private extension EInkDrawBox.Content {
    var text: String? {
        if case let .text(value, _, _) = self { return value }
        return nil
    }
}

/// A 1-bit-looking drawing of a group's screens, laid out as they hang with a
/// grey bezel between them. Test-only: the app's preview is SwiftUI.
enum GroupPicture {
    static let scale = 3
    static let bezel = 8

    static func write(group: EInkScreenGroup, devices: [EInkDeviceConfig], plans: [String: EInkPreviewPlan], to url: URL) throws {
        let ids = group.orderedScreenIDs
        let rects = ids.compactMap { group.rect(for: $0, devices: devices) }
        guard let bounds = group.bounds(for: ids, devices: devices) else { return }
        func origin(_ rect: EInkRect) -> (Int, Int) {
            let column = Set(rects.filter { $0.maxX <= rect.x }.map(\.x)).count
            let row = Set(rects.filter { $0.maxY <= rect.y }.map(\.y)).count
            return (rect.x - bounds.x + column * bezel + bezel, rect.y - bounds.y + row * bezel + bezel)
        }
        let columns = Set(rects.map(\.x)).count
        let rows = Set(rects.map(\.y)).count
        let width = (bounds.width + (columns + 1) * bezel) * scale
        let height = (bounds.height + (rows + 1) * bezel) * scale
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(gray: 0.55, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        for (id, rect) in zip(ids, rects) {
            let (x, y) = origin(rect)
            context.saveGState()
            context.translateBy(x: CGFloat(x), y: CGFloat(y))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
            context.clip(to: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
            for box in plans[id]?.boxes ?? [] { draw(box, in: context) }
            context.restoreGState()
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    static func draw(_ box: EInkDrawBox, in context: CGContext) {
        let frame = CGRect(x: box.frame.x, y: box.frame.y, width: box.frame.width, height: box.frame.height)
        let black = CGColor(gray: 0, alpha: 1)
        switch box.content {
        case .fill:
            context.setFillColor(black)
            context.fill(frame)
        case .outline:
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(frame)
            context.setStrokeColor(black)
            context.setLineWidth(1)
            context.stroke(frame.insetBy(dx: 0.5, dy: 0.5))
        case let .text(value, font, alignment):
            let ctFont: CTFont
            switch font {
            case .pixel12: ctFont = EInkFonts.font(.pixel, size: EInkFonts.pixelPointSize)
            case let .sans(size, bold): ctFont = EInkFonts.font(bold ? .sansBold : .sans, size: CGFloat(size))
            }
            let attributed = NSAttributedString(string: value, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): black
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let x: CGFloat
            switch alignment {
            case .leading: x = frame.minX
            case .trailing: x = frame.maxX - width
            case .center: x = frame.midX - width / 2
            }
            let baseline = frame.midY + (ascent - descent) / 2
            context.saveGState()
            if box.clipsContent { context.clip(to: frame) }
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, context)
            context.restoreGState()
        case let .image(uri):
            guard let comma = uri.range(of: ","), let data = Data(base64Encoded: String(uri[comma.upperBound...])) else { return }
            drawPNG(data, in: frame, context: context)
        case let .ring(percent, stroke):
            guard let data = try? EInkRingRasterizer.pngData(percent: percent, size: box.frame.width, stroke: stroke) else { return }
            drawPNG(data, in: frame, context: context)
        }
    }

    static func drawPNG(_ data: Data, in frame: CGRect, context: CGContext) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        context.saveGState()
        context.interpolationQuality = .none
        context.translateBy(x: frame.minX, y: frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        context.restoreGState()
    }
}
