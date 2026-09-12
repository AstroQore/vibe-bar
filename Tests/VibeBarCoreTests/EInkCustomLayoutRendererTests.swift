import XCTest
@testable import VibeBarCore

/// The Studio's half of the render pipeline: a free layout has to reach the
/// device through exactly the same boxes the presets do.
final class EInkCustomLayoutRendererTests: XCTestCase {
    private let snapshot = EInkFixtures.snapshot()

    private func layout(_ elements: [EInkCanvasElement], portrait: Bool = false) -> EInkCanvasLayout {
        var layout = EInkCanvasLayout(profile: .quote0, orientation: portrait ? .degrees90 : .degrees0)
        layout.elements = elements
        return layout.normalized()
    }

    private func element(
        _ kind: EInkCanvasElement.Kind,
        fieldID: String? = nil,
        x: Double = 0,
        y: Double = 0,
        width: Double? = nil,
        height: Double? = nil
    ) -> EInkCanvasElement {
        var e = EInkCanvasElement(kind: kind, fieldID: fieldID)
        e.x = x
        e.y = y
        if let width { e.width = width }
        if let height { e.height = height }
        return e
    }

    private func boxes(
        _ layout: EInkCanvasLayout,
        slide: EInkSlide = EInkSlide(id: "slide-1", kind: .custom(layoutID: "layout-1")),
        orientation: EInkOrientation = .degrees0
    ) -> [EInkDrawBox] {
        let size = EInkDeviceProfile.quote0.frameSize(for: orientation)
        return EInkBoxLayout.resolve(
            EInkCustomLayoutRenderer.tree(
                layout: layout,
                slide: slide,
                orientation: orientation,
                snapshot: snapshot
            ),
            in: EInkRect(x: 0, y: 0, width: size.width, height: size.height)
        )
    }

    // MARK: - Structure

    /// The golden: a ring, two texts and a rule land where the author put
    /// them, in the order they were authored, with nothing else emitted.
    func testASampleLayoutResolvesToTheBoxesTheAuthorPlaced() throws {
        var ring = element(.ring, fieldID: "claude.weekly", x: 8, y: 8, width: 48, height: 48)
        ring.thickness = 6
        ring.font = .sans(size: 14, bold: true)
        var title = element(.text, fieldID: "claude.weekly", x: 64, y: 8, width: 120, height: 12)
        title.textBinding = .label
        var countdown = element(.text, fieldID: "claude.weekly", x: 64, y: 24, width: 120, height: 12)
        countdown.textBinding = .countdown
        countdown.alignment = .trailing
        countdown.autoWidth = false
        let rule = element(.divider, x: 64, y: 40, width: 120, height: 1)

        let resolved = boxes(layout([ring, title, countdown, rule]))
        XCTAssertEqual(resolved.count, 5)  // ring raster + its label, two texts, the rule

        XCTAssertEqual(resolved[0].frame, EInkRect(x: 8, y: 8, width: 48, height: 48))
        guard case let .ring(percent, stroke) = resolved[0].content else {
            return XCTFail("expected a ring")
        }
        XCTAssertEqual(percent, 41)
        XCTAssertEqual(stroke, 6)

        // The ring's own percentage label, centred on it.
        guard case let .text(ringLabel, _, ringAlignment) = resolved[1].content else {
            return XCTFail("expected the ring label")
        }
        XCTAssertEqual(ringLabel, "41")
        XCTAssertEqual(ringAlignment, .center)

        guard case let .text(titleText, titleFont, _) = resolved[2].content else {
            return XCTFail("expected the label text")
        }
        XCTAssertEqual(titleText, "Claude · Weekly")
        XCTAssertEqual(titleFont, .pixel12(bold: false))
        // Measured, because the author left the box on auto.
        XCTAssertEqual(resolved[2].frame.x, 64)
        XCTAssertEqual(resolved[2].frame.width, EInkTextMetrics.width("Claude · Weekly", font: .pixel12(bold: false)))
        XCTAssertFalse(resolved[2].clipsContent)

        // Fixed, because the author said so: the box keeps its width and the
        // device is told to clip.
        XCTAssertEqual(resolved[3].frame, EInkRect(x: 64, y: 24, width: 120, height: 12))
        XCTAssertTrue(resolved[3].clipsContent)

        XCTAssertEqual(resolved[4].content, .fill)
        XCTAssertEqual(resolved[4].frame, EInkRect(x: 64, y: 40, width: 120, height: 1))
    }

    /// Every binding, against the fixture's own numbers.
    func testEveryTextBindingDrawsItsOwnValue() {
        func drawn(_ mutate: (inout EInkCanvasElement) -> Void) -> String {
            var e = element(.text, fieldID: "claude.weekly")
            mutate(&e)
            return EInkCustomLayoutRenderer.text(for: e, snapshot: snapshot)
        }

        XCTAssertEqual(drawn { $0.textBinding = .percent }, "41%")
        XCTAssertEqual(drawn { $0.textBinding = .label }, "Claude · Weekly")
        XCTAssertEqual(drawn { $0.textBinding = .countdown }, "4d 00h")
        XCTAssertEqual(drawn { $0.textBinding = .custom; $0.text = "STANDUP" }, "STANDUP")
        XCTAssertEqual(
            drawn { $0.textBinding = .usageMetric; $0.usagePeriod = .today; $0.usageMetric = .cost },
            EInkFormat.money(snapshot.usage.today.costUSD)
        )
        XCTAssertEqual(
            drawn { $0.textBinding = .usageMetric; $0.usagePeriod = .week; $0.usageMetric = .tokens },
            EInkFormat.tokens(snapshot.usage.week.tokens)
        )
        XCTAssertEqual(
            drawn { $0.textBinding = .usageMetric; $0.usagePeriod = .month; $0.usageMetric = .requests },
            EInkFormat.int(snapshot.usage.month.requests)
        )
    }

    /// Money is written in full dollars, as the presets print it, and never
    /// abbreviated by the Studio's own path.
    func testUsageMoneyKeepsThePresetsFullDollarForm() {
        var tile = element(.statTile, x: 8, y: 8, width: 130, height: 46)
        tile.textBinding = .usageMetric
        tile.usagePeriod = .allTime
        tile.usageMetric = .cost
        tile.font = .sans(size: 18, bold: true)

        let resolved = boxes(layout([tile]))
        let strings = resolved.compactMap { box -> String? in
            if case let .text(value, _, _) = box.content { return value }
            return nil
        }
        XCTAssertEqual(strings.first, "ALL TIME")
        XCTAssertEqual(strings[1], EInkFormat.money(snapshot.usage.allTime.costUSD))
        XCTAssertTrue(strings[1].contains(","), "full dollars with separators, not a compact form")
        XCTAssertEqual(strings[2], "\(EInkFormat.tokens(snapshot.usage.allTime.tokens)) tokens")
    }

    func testBarsAndRingsReadTheBoundBucket() {
        let bar = element(.horizontalBar, fieldID: "grok.weekly", x: 10, y: 10, width: 100, height: 10)
        let column = element(.verticalBar, fieldID: "codex.weekly", x: 10, y: 40, width: 22, height: 60)
        let resolved = boxes(layout([bar, column]))

        // Track, fill, track, fill.
        XCTAssertEqual(resolved.count, 4)
        XCTAssertEqual(resolved[0].content, .outline)
        XCTAssertEqual(resolved[1].content, .fill)
        // 17 % of the 98 px inner track.
        XCTAssertEqual(resolved[1].frame.width, EInkBoxLayout.fillLength(98, percent: 17))
        XCTAssertEqual(resolved[3].frame.height, EInkBoxLayout.fillLength(58, percent: 88))
        XCTAssertEqual(resolved[3].frame.maxY, resolved[2].frame.maxY - 1, "a vertical bar fills upwards")
    }

    /// An element with no bucket behind it draws nothing rather than a
    /// plausible number nobody can tell apart from a reading.
    func testUnboundElementsDrawNothing() {
        let ring = element(.ring, x: 8, y: 8, width: 48, height: 48)
        var text = element(.text, x: 64, y: 8)
        text.textBinding = .percent
        XCTAssertTrue(boxes(layout([ring, text])).isEmpty)
    }

    // MARK: - Presets in a frame

    /// The contract that lets a preset be an element: at the panel's own
    /// rectangle, the Studio's output is the preset's output, box for box.
    func testAPresetAtThePanelFrameMatchesThePresetSlideExactly() throws {
        for orientation in EInkOrientation.allCases {
            let size = EInkDeviceProfile.quote0.frameSize(for: orientation)
            let frame = EInkRect(x: 0, y: 0, width: size.width, height: size.height)
            for kind in EInkCanvasElement.Kind.allCases {
                guard let preset = kind.preset else { continue }
                var block = EInkCanvasElement(kind: kind)
                block.x = 0
                block.y = 0
                block.width = Double(size.width)
                block.height = Double(size.height)

                let presetSlide = EInkSlide(id: "slide-1", kind: .preset(preset))
                let expected = EInkBoxLayout.resolve(
                    try EInkRenderer.tree(
                        slide: presetSlide,
                        orientation: orientation,
                        snapshot: snapshot
                    ),
                    in: frame
                )
                let custom = boxes(
                    layout([block], portrait: orientation.isPortrait),
                    slide: EInkSlide(id: "slide-1", kind: .custom(layoutID: "layout-1")),
                    orientation: orientation
                )
                XCTAssertEqual(custom, expected, "\(preset.rawValue) at \(orientation.rawValue)°")
            }
        }
    }

    /// A preset block keeps its own bucket choice, independent of the slide.
    func testAPresetBlockHonoursItsOwnSelection() throws {
        var block = EInkCanvasElement(kind: .quotaLedger)
        block.x = 0
        block.y = 0
        block.width = 296
        block.height = 152
        block.fieldIDs = ["grok.weekly", "codex.weekly"]

        let strings = boxes(layout([block])).compactMap { box -> String? in
            if case let .text(value, _, _) = box.content { return value }
            return nil
        }
        XCTAssertTrue(strings.contains("Grok · Weekly"))
        XCTAssertTrue(strings.contains("Codex · Weekly"))
        XCTAssertFalse(strings.contains("Claude · Weekly"))
    }

    /// A slide that names nothing draws the same rows the preset slide would.
    func testAPresetBlockFallsBackToTheSlideSelection() {
        var block = EInkCanvasElement(kind: .usageTiles)
        block.x = 0
        block.y = 0
        block.width = 296
        block.height = 152
        var slide = EInkSlide(id: "slide-1", kind: .custom(layoutID: "layout-1"))
        slide.usagePeriods = [.month]

        let strings = boxes(layout([block]), slide: slide).compactMap { box -> String? in
            if case let .text(value, _, _) = box.content { return value }
            return nil
        }
        XCTAssertTrue(strings.contains("30 DAYS"))
        XCTAssertFalse(strings.contains("TODAY"))
    }

    // MARK: - Diagnostics

    func testDiagnosticsFindAnOverflowingFixedBox() {
        var wide = element(.text, fieldID: "antigravity.claude_gpt_weekly", x: 8, y: 8, width: 24, height: 12)
        wide.textBinding = .label
        wide.autoWidth = false
        var measured = wide
        measured.id = UUID()
        measured.y = 32
        measured.autoWidth = true

        let report = EInkLayoutDiagnostics.report(
            layout: layout([wide, measured]),
            slide: EInkSlide(id: "slide-1", kind: .custom(layoutID: "layout-1")),
            orientation: .degrees0,
            snapshot: snapshot
        )
        XCTAssertEqual(report.issues(for: wide.id), [.textOverflow(elementID: wide.id)])
        XCTAssertTrue(report.issues(for: measured.id).isEmpty, "a measured box is never too narrow for itself")
    }

    func testDiagnosticsCountTheElementsTheDeviceWillSee() {
        var rule = element(.divider, x: 0, y: 0, width: 200, height: 1)
        var elements: [EInkCanvasElement] = []
        for index in 0..<10 {
            rule.id = UUID()
            rule.y = Double(index * 8)
            elements.append(rule)
        }
        let report = EInkLayoutDiagnostics.report(
            layout: layout(elements),
            slide: EInkSlide(id: "slide-1", kind: .custom(layoutID: "layout-1")),
            orientation: .degrees0,
            snapshot: snapshot
        )
        XCTAssertEqual(report.elementCount, 11, "ten rules plus the root the device counts")
        XCTAssertEqual(report.elementLimit, DotCanvasEncoder.Limits.maxElements)
        XCTAssertTrue(report.isClear)
    }

    /// The encoder is the authority on the limit, so a layout the diagnostics
    /// call over-budget has to be one the encoder actually rejects.
    func testAMaxElementLayoutIsRejectedByTheEncoder() throws {
        var elements: [EInkCanvasElement] = []
        for index in 0..<90 {
            var rule = EInkCanvasElement(kind: .divider)
            rule.id = UUID()
            rule.x = Double((index % 2) * 140)
            rule.y = Double((index / 2) * 3)
            rule.width = 120
            rule.height = 1
            elements.append(rule)
        }
        let built = layout(elements)
        let slide = EInkSlide(id: "slide-1", kind: .custom(layoutID: "layout-1"))
        let report = EInkLayoutDiagnostics.report(
            layout: built, slide: slide, orientation: .degrees0, snapshot: snapshot
        )
        XCTAssertTrue(
            report.issues.contains(.tooManyElements(count: report.elementCount, limit: 80)),
            "\(report.elementCount) elements should be over budget"
        )

        XCTAssertThrowsError(
            try EInkRenderer.render(
                slide: slide,
                device: EInkFixtures.device(orientation: .degrees0),
                snapshot: snapshot,
                layouts: ["layout-1": built]
            )
        ) { error in
            guard case let DotCanvasEncoder.EncodeError.limitsExceeded(violations) = error else {
                return XCTFail("expected a limits violation, got \(error)")
            }
            XCTAssertEqual(violations, [.elementCount(report.elementCount)])
        }
    }

    /// A tile's caption is its own line, not a second copy of the value: the
    /// `.custom` binding has nothing to put on the big line, because the fixed
    /// text *is* the caption.
    func testAStatTileNeverDrawsItsCaptionTwice() {
        var tile = element(.statTile, x: 8, y: 8, width: 120, height: 46)
        tile.textBinding = .custom
        tile.text = "STANDUP"
        tile.subText = "10:00"

        let strings = boxes(layout([tile])).compactMap { box -> String? in
            if case let .text(value, _, _) = box.content { return value }
            return nil
        }
        XCTAssertEqual(strings, ["STANDUP", "10:00"])
    }

    /// A caption and a sub value are fixed-width lines too, in a different
    /// face from the big one — so the checks measure all three.
    func testDiagnosticsMeasureEveryStatTileLine() {
        var tile = element(.statTile, fieldID: "claude.weekly", x: 8, y: 8, width: 40, height: 46)
        tile.textBinding = .percent
        tile.font = .sans(size: 14, bold: true)
        tile.text = "A VERY LONG CAPTION INDEED"

        func report(_ e: EInkCanvasElement) -> [EInkLayoutDiagnostics.Issue] {
            EInkLayoutDiagnostics.report(
                layout: layout([e]),
                slide: EInkSlide(id: "slide-1", kind: .custom(layoutID: "layout-1")),
                orientation: .degrees0,
                snapshot: snapshot
            ).issues(for: e.id)
        }
        XCTAssertEqual(report(tile), [.textOverflow(elementID: tile.id)])

        var short = tile
        short.text = "LEFT"
        short.subText = "4d"
        XCTAssertTrue(report(short).isEmpty, "41% in 40 px with short lines fits")
    }

    /// The Canvas API rejects a payload containing its own template marker,
    /// so a layout must not be able to hold one — otherwise the Studio calls
    /// a slide clear that can never reach a panel.
    func testFixedTextCannotCarryTheTemplateMarkerOrRunAwayInLength() throws {
        var marker = element(.text, x: 8, y: 8, width: 120, height: 12)
        marker.textBinding = .custom
        marker.text = "{{quota}} {{{left}}}"
        var long = element(.text, x: 8, y: 40, width: 120, height: 12)
        long.textBinding = .custom
        long.text = String(repeating: "A", count: 5_000)

        let built = layout([marker, long])
        let cleaned = try XCTUnwrap(built.elements.first { $0.id == marker.id })
        XCTAssertFalse(cleaned.text.contains("{{"))
        XCTAssertEqual(
            built.elements.first { $0.id == long.id }?.text.count,
            EInkCanvasLayout.maximumTextLength
        )

        // And the encoder, which is the authority, accepts what survived.
        XCTAssertNoThrow(
            try EInkRenderer.render(
                slide: EInkSlide(id: "slide-1", kind: .custom(layoutID: "layout-1")),
                device: EInkFixtures.device(orientation: .degrees0),
                snapshot: snapshot,
                layouts: ["layout-1": built]
            )
        )
    }

    /// The registry keeps a bucket a Studio layout names, even when nothing
    /// else refers to it.
    func testALayoutOnlyBucketStaysInTheKeepSet() {
        var ring = EInkCanvasElement(kind: .ring, fieldID: "cursor.models")
        var built = EInkCanvasLayout(profile: .quote0, orientation: .degrees0)
        built.elements = [ring]
        var device = EInkFixtures.device(orientation: .degrees0)
        device.slides = [EInkSlide(id: "slide-1", kind: .custom(layoutID: "layout-1"))]
        var settings = EInkSyncSettings()
        settings.devices = [device]

        XCTAssertFalse(settings.referencedQuotaFieldIDs.contains("cursor.models"))
        XCTAssertTrue(
            settings.referencedQuotaFieldIDs(layouts: ["layout-1": built]).contains("cursor.models")
        )
        ring.fieldID = nil
        ring.fieldIDs = ["grok.weekly"]
        built.elements = [ring]
        XCTAssertTrue(
            settings.referencedQuotaFieldIDs(layouts: ["layout-1": built]).contains("grok.weekly")
        )
    }

    // MARK: - Orientation

    /// Turning the device keeps every element's pixel and pulls back only
    /// what no longer fits.
    func testATurnedPanelRefitsTheLayoutRatherThanRescalingIt() {
        var inside = EInkCanvasElement(kind: .divider)
        inside.x = 10
        inside.y = 10
        inside.width = 100
        inside.height = 1
        var wide = EInkCanvasElement(kind: .text)
        wide.x = 200
        wide.y = 120
        wide.width = 80
        wide.height = 12

        let landscape = layout([inside, wide])
        XCTAssertEqual(landscape.width, 296)
        let portrait = landscape.fitted(profile: .quote0, orientation: .degrees90)
        XCTAssertEqual(portrait.width, 152)
        XCTAssertEqual(portrait.height, 296)

        let moved = portrait.elements.first { $0.id == wide.id }
        XCTAssertEqual(moved?.width, 80, "the element keeps its size")
        XCTAssertEqual(moved?.x, 72, "and is pulled back inside the narrower panel")
        XCTAssertEqual(moved?.y, 120, "the axis that grew leaves it alone")

        let untouched = portrait.elements.first { $0.id == inside.id }
        XCTAssertEqual(untouched?.x, 10)
        XCTAssertEqual(untouched?.y, 10)

        // And the renderer refits on its own, so a stale layout still draws
        // inside the panel it is being sent to.
        for box in boxes(landscape, orientation: .degrees90) {
            XCTAssertLessThanOrEqual(box.frame.maxX, 152)
            XCTAssertLessThanOrEqual(box.frame.maxY, 296)
        }
    }

    // MARK: - What a custom slide asks the assembler for

    func testACustomSlideReportsItsBucketsAndWhetherItReadsUsage() {
        var spend = EInkCanvasElement(kind: .text)
        spend.textBinding = .usageMetric
        var bucket = EInkCanvasElement(kind: .ring, fieldID: "cursor.models")
        var built = EInkCanvasLayout(profile: .quote0, orientation: .degrees0)
        built.elements = [bucket, spend]

        var device = EInkFixtures.device(orientation: .degrees0)
        device.slides = [EInkSlide(id: "slide-1", kind: .custom(layoutID: "layout-1"))]
        var settings = EInkSyncSettings()
        settings.devices = [device]
        let layouts = ["layout-1": built]

        XCTAssertTrue(settings.selectedQuotaFieldIDs(layouts: layouts).contains("cursor.models"))

        // A preset block with no selection of its own draws the slide's
        // buckets, so those have to be assembled too — a slide converted from
        // a preset keeps them, and `selectedQuotaFieldIDs` only reads preset
        // slides.
        var block = EInkCanvasElement(kind: .quotaLedger)
        var withBlock = built
        withBlock.elements = [block]
        device.slides[0].quotaFieldIDs = ["codex.five_hour"]
        settings.devices = [device]
        XCTAssertTrue(
            settings.selectedQuotaFieldIDs(layouts: ["layout-1": withBlock]).contains("codex.five_hour")
        )
        block.fieldIDs = ["grok.weekly"]
        withBlock.elements = [block]
        XCTAssertFalse(
            settings.selectedQuotaFieldIDs(layouts: ["layout-1": withBlock]).contains("codex.five_hour"),
            "a block that picked its own buckets does not also pull the slide's"
        )
        XCTAssertTrue(device.slides[0].needsUsageData(layouts: layouts))

        built.elements = [bucket]
        XCTAssertFalse(device.slides[0].needsUsageData(layouts: ["layout-1": built]))
        bucket.fieldID = nil
        built.elements = [bucket]
        XCTAssertFalse(settings.selectedQuotaFieldIDs(layouts: ["layout-1": built]).contains("cursor.models"))
    }
}
