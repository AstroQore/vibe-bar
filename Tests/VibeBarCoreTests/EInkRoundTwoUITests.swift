import XCTest
@testable import VibeBarCore

/// The Core half of round 2's settings and Studio work: the geometry the
/// upright previews are drawn in, what a typed cadence field commits, what the
/// Studio palette is allowed to place, and the briefing's long-name wrap.
final class EInkRoundTwoUITests: XCTestCase {
    private let snapshot = EInkFixtures.snapshot()

    // MARK: - Upright geometry

    /// The frame a reader sees is the frame the layout was authored in. That
    /// identity is what lets the preview draw the authored boxes with no
    /// rotation and still be showing the panel.
    func testThePhysicalFrameIsTheAuthoredFrame() {
        for orientation in EInkOrientation.allCases {
            let physical = orientation.physicalFrame(.quote0)
            let authored = EInkDeviceProfile.quote0.frameSize(for: orientation)
            XCTAssertEqual(physical.width, authored.width, "\(orientation.rawValue)°")
            XCTAssertEqual(physical.height, authored.height, "\(orientation.rawValue)°")
        }
        XCTAssertEqual(EInkOrientation.degrees0.physicalFrame().width, 296)
        XCTAssertEqual(EInkOrientation.degrees90.physicalFrame().width, 152)
        XCTAssertEqual(EInkOrientation.degrees90.physicalFrame().height, 296)
    }

    /// The encoder turns the canvas clockwise, so the reader turns the device
    /// the other way — and the device's own top edge ends up on the opposite
    /// side from the one a naive reading gives.
    func testTheDeviceTopEdgeFollowsTheRotationBackwards() {
        XCTAssertEqual(EInkOrientation.degrees0.uprightDeviceEdge, .top)
        XCTAssertEqual(EInkOrientation.degrees90.uprightDeviceEdge, .left)
        XCTAssertEqual(EInkOrientation.degrees180.uprightDeviceEdge, .bottom)
        XCTAssertEqual(EInkOrientation.degrees270.uprightDeviceEdge, .right)
    }

    /// The read-back PNG is always the panel's native raster; turning it by
    /// this much undoes the encoder's own rotation exactly.
    func testTheReadBackRasterIsTurnedBackByTheComplementOfTheRotation() {
        for orientation in EInkOrientation.allCases {
            XCTAssertEqual((orientation.rawValue + orientation.uprightImageDegrees) % 360, 0)
        }
        XCTAssertEqual(EInkOrientation.degrees0.uprightImageDegrees, 0)
        XCTAssertEqual(EInkOrientation.degrees90.uprightImageDegrees, 270)
        XCTAssertEqual(EInkOrientation.degrees270.uprightImageDegrees, 90)
    }

    // MARK: - Cadence

    func testATypedCadenceIsClampedToItsOwnRange() {
        XCTAssertEqual(EInkCadence.dataRefreshMinutes.parse("0", current: 15), 1)
        XCTAssertEqual(EInkCadence.dataRefreshMinutes.parse("99999", current: 15), 1440)
        XCTAssertEqual(EInkCadence.batteryRefreshMinutes.parse("240", current: 60), 240)
        XCTAssertEqual(EInkCadence.secondsPerSlide.parse("5", current: 300), 10)
        XCTAssertEqual(EInkCadence.secondsPerSlide.parse("86400", current: 300), 86_400)
        XCTAssertEqual(EInkCadence.secondsPerSlide.parse("999999999999", current: 300), 86_400)
    }

    /// A reader who types "15 min" or "1,440" meant a number; a field that
    /// refuses to commit reads as broken.
    func testATypedCadenceTakesTheNumberOutOfWhateverWasTyped() {
        XCTAssertEqual(EInkCadence.dataRefreshMinutes.parse("15 min", current: 15), 15)
        XCTAssertEqual(EInkCadence.dataRefreshMinutes.parse("1,440", current: 15), 1440)
        XCTAssertEqual(EInkCadence.dataRefreshMinutes.parse("", current: 42), 42)
        XCTAssertEqual(EInkCadence.dataRefreshMinutes.parse("   ", current: 42), 42)
        XCTAssertEqual(EInkCadence.dataRefreshMinutes.parse("abc", current: 4000), 1440)
    }

    func testEveryCadenceFieldReadsAndWritesItsOwnDeviceField() {
        var device = EInkFixtures.device(orientation: .degrees0)
        for field in EInkCadence.allCases {
            field.apply(field.range.upperBound + 10, to: &device)
            XCTAssertEqual(field.value(in: device), field.range.upperBound, field.rawValue)
            field.apply(field.range.lowerBound - 10, to: &device)
            XCTAssertEqual(field.value(in: device), field.range.lowerBound, field.rawValue)
        }
        XCTAssertEqual(EInkCadence.dataRefreshMinutes.range, 1...1440)
        XCTAssertEqual(EInkCadence.batteryRefreshMinutes.range, 1...1440)
        XCTAssertEqual(EInkCadence.secondsPerSlide.range, 10...86_400)
    }

    /// Switching playback modes must not take the seconds with it — the owner
    /// lost them every time he tried "One slide".
    func testSwitchingPlaybackModesKeepsTheSecondsPerSlide() {
        var device = EInkFixtures.device(orientation: .degrees0)
        device.secondsPerSlide = 900
        device.playbackMode = .single
        XCTAssertEqual(device.secondsPerSlide, 900)
        device.playbackMode = .deviceLoop
        XCTAssertEqual(device.sanitized.secondsPerSlide, 900)
        device.playbackMode = .appTimer
        XCTAssertEqual(device.sanitized.secondsPerSlide, 900)
    }

    // MARK: - Studio palette

    /// The black block the owner found on his paper: `.fill` reached the
    /// palette because it was built by filtering `Kind.allCases`, so clicking
    /// an entry named "Element" dropped an unexplained, unbindable black
    /// rectangle. Neither it nor `.image` is something an author draws.
    func testTheStudioPaletteNeverOffersTheExplodeOnlyKinds() {
        XCTAssertFalse(EInkStudioModules.authorPlaceable.contains(.fill))
        XCTAssertFalse(EInkStudioModules.authorPlaceable.contains(.image))
        for kind in EInkStudioModules.authorPlaceable {
            XCTAssertNil(kind.preset, "\(kind.rawValue) is a whole preset, not a primitive")
        }
        XCTAssertEqual(EInkStudioModules.presetBlocks.count, EInkPreset.userSelectable.count)
        XCTAssertFalse(EInkStudioModules.presetBlocks.contains { $0.preset == .alert })
    }

    /// Every module drops one group, and every part of it carries the module
    /// id — which is what lets the Studio name the group and Ungroup split it.
    func testEveryModuleDropsOneBoundGroup() {
        for module in EInkStudioModule.allCases {
            let elements = EInkStudioModules.elements(
                module,
                fieldID: "claude.weekly",
                width: 284,
                origin: EInkPoint(x: 6, y: 6)
            )
            XCTAssertGreaterThan(elements.count, 1, module.rawValue)
            XCTAssertEqual(Set(elements.compactMap(\.groupID)).count, 1, module.rawValue)
            XCTAssertEqual(Set(elements.compactMap(\.moduleID)).count, 1, module.rawValue)
            XCTAssertFalse(elements.contains { $0.kind == .fill }, module.rawValue)
        }
        let slot = EInkStudioModules.elements(
            .quotaSlot,
            fieldID: "claude.weekly",
            width: 284,
            origin: EInkPoint(x: 6, y: 6)
        )
        XCTAssertTrue(slot.allSatisfy { $0.fieldID == "claude.weekly" })
        XCTAssertEqual(
            Set(slot.map(\.textBinding)),
            [.label, .percent, .countdown]
        )
    }

    /// A dropped module draws something. An element that draws nothing is the
    /// dashed placeholder the Studio shows, and a palette that only ever
    /// produced those would be a palette nobody can use.
    func testADroppedModuleDrawsOnThePanel() {
        let slide = EInkFixtures.slide(preset: .quotaLedger, fieldIDs: ["claude.weekly"])
        for module in EInkStudioModule.allCases {
            let elements = EInkStudioModules.elements(
                module,
                fieldID: "claude.weekly",
                width: 284,
                origin: EInkPoint(x: 6, y: 6)
            )
            let drawn = elements.compactMap {
                EInkCustomLayoutRenderer.node(
                    for: $0,
                    slide: slide,
                    orientation: .degrees0,
                    snapshot: snapshot
                )
            }
            XCTAssertEqual(drawn.count, elements.count, module.rawValue)
        }
    }

    /// A preset dropped from the palette and "Edit in Studio" on that preset
    /// have to be the same paper, or the palette teaches a layout the device
    /// does not draw.
    func testAPresetModuleIsExactlyWhatEditInStudioProduces() {
        let slide = EInkFixtures.slide(preset: .usageTiles)
        let dropped = EInkStudioModules.presetElements(
            .quotaLedger,
            slide: slide,
            orientation: .degrees90,
            snapshot: snapshot,
            calendar: EInkFixtures.calendar()
        )
        var exploded = slide
        exploded.kind = .preset(.quotaLedger)
        let direct = EInkPresetExploder.explode(
            slide: exploded.fitted(to: .degrees90),
            orientation: .degrees90,
            snapshot: snapshot,
            calendar: EInkFixtures.calendar()
        ).elements
        XCTAssertEqual(dropped.count, direct.count)
        XCTAssertEqual(dropped.map(\.x), direct.map(\.x))
        XCTAssertEqual(dropped.map(\.y), direct.map(\.y))
        XCTAssertEqual(dropped.map(\.text), direct.map(\.text))
    }

    /// Inserting a module keeps the group it arrived with; `add` would have
    /// re-placed each member on its own.
    func testInsertingAModuleKeepsItTogether() {
        var layout = EInkCanvasLayout(profile: .quote0, orientation: .degrees0)
        let ids = layout.insert(
            EInkStudioModules.elements(.headerBar, width: 284, origin: layout.nextModuleOrigin)
        )
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(layout.elements.compactMap(\.groupID)).count, 1)
        XCTAssertEqual(layout.expandedSelection([ids.first!]), ids)
    }

    // MARK: - Custom labels reach a custom layout

    /// The Studio inspector and the slide editor both write a per-bucket name
    /// into the slide's options. A custom layout that read the bucket's own
    /// name instead would take the edit, store it, and keep drawing the old
    /// name on the panel — which is the failure a settings field that "works"
    /// and changes nothing always is.
    func testACustomLayoutDrawsTheSlideName() {
        var slide = EInkSlide(id: "s", kind: .custom(layoutID: "s"), quotaFieldIDs: ["claude.weekly"])
        slide.options.customLabels = ["claude.weekly": "Claude · Weekly, mine"]
        var element = EInkCanvasElement(kind: .text, fieldID: "claude.weekly")
        element.textBinding = .label

        XCTAssertEqual(
            EInkCustomLayoutRenderer.text(for: element, snapshot: snapshot, options: slide.options),
            "Claude · Weekly, mine"
        )
        let node = EInkCustomLayoutRenderer.node(
            for: element,
            slide: slide,
            orientation: .degrees0,
            snapshot: snapshot
        )
        guard case let .text(printed, _, _)? = node?.kind else {
            return XCTFail("a label element draws text")
        }
        XCTAssertEqual(printed, "Claude · Weekly, mine")
    }

    /// And the explode keeps the binding on a renamed slot rather than
    /// freezing it: the preset prints the slide's name, so the comparison that
    /// decides "is this still live data" has to use the same name.
    func testExplodingARenamedSlotKeepsItBound() {
        var slide = EInkFixtures.slide(preset: .quotaLedger, fieldIDs: ["claude.weekly", "codex.weekly"])
        slide.options.customLabels = ["claude.weekly": "My Claude week"]
        let layout = EInkPresetExploder.explode(
            slide: slide,
            orientation: .degrees0,
            snapshot: snapshot,
            calendar: EInkFixtures.calendar()
        )
        let label = layout.elements.first { $0.textBinding == .label && $0.fieldID == "claude.weekly" }
        XCTAssertNotNil(label, "the renamed slot's name is still bound to its bucket")
        XCTAssertEqual(
            EInkCustomLayoutRenderer.text(for: label!, snapshot: snapshot, options: slide.options),
            "My Claude week"
        )
    }

    // MARK: - Briefing long names

    private func briefingBoxes(_ rows: [EInkQuotaRow]) -> [EInkDrawBox] {
        var snapshot = self.snapshot
        snapshot.quota = rows
        let slide = EInkFixtures.slide(preset: .briefing, fieldIDs: rows.map(\.fieldID))
        let frame = EInkRect(x: 0, y: 0, width: 296, height: 152)
        return EInkBoxLayout.resolve(
            EInkRenderer.presetTree(
                .briefing,
                slide: slide,
                orientation: .degrees0,
                snapshot: snapshot,
                frame: frame,
                calendar: EInkFixtures.calendar()
            ),
            in: frame
        )
    }

    private func longNamedRows() -> [EInkQuotaRow] {
        EInkFixtures.quotaRows(count: 3).enumerated().map { index, row in
            var copy = row
            copy.providerDisplayName = "ChatGPT Agentic · GPT-5.3 Codex Spark \(index)"
            copy.windowTitle = "Weekly"
            return copy
        }
    }

    /// The owner's panel printed "ChatGPT Agentic · GPT-5.3 Code…". The name
    /// now takes a line of its own instead: the layout gives up a row, never a
    /// word.
    func testLandscapeBriefingWrapsALongNameInsteadOfCuttingIt() {
        let rows = longNamedRows()
        let boxes = briefingBoxes(rows)
        let names = boxes.filter { box in
            guard case let .text(value, _, _) = box.content else { return false }
            return value.hasPrefix("ChatGPT Agentic")
        }
        XCTAssertEqual(names.count, rows.count)
        for box in names {
            XCTAssertFalse(box.clipsContent, "a name is never cut")
        }
        // The figures sit under the name rather than beside it.
        for name in names {
            let below = boxes.contains { box in
                guard case let .text(value, _, _) = box.content else { return false }
                return value.contains("%") && box.frame.y >= name.frame.maxY && box.frame.y < name.frame.maxY + 14
            }
            XCTAssertTrue(below, "the figures wrap under the name")
        }
    }

    /// Short names keep the one-line row: the wrap is a fallback, not the new
    /// normal.
    func testLandscapeBriefingKeepsOneLineRowsWhenTheNamesFit() {
        let boxes = briefingBoxes(Array(EInkFixtures.quotaRows(count: 3)))
        let name = boxes.first { box in
            guard case let .text(value, _, _) = box.content else { return false }
            return value == "Claude · 5 Hours"
        }
        let unwrapped = try? XCTUnwrap(name)
        let beside = boxes.contains { box in
            guard case let .text(value, _, _) = box.content, let unwrapped else { return false }
            return value.contains("%") && box.frame.y == unwrapped.frame.y
        }
        XCTAssertTrue(beside, "the figures stay on the name's own line")
    }

    /// Whatever the form, nothing leaves the panel and no figure is cut.
    func testTheBriefingNeverPushesARowOffThePanel() {
        for rows in [longNamedRows(), Array(EInkFixtures.quotaRows(count: 4))] {
            let boxes = briefingBoxes(rows)
            for box in boxes {
                XCTAssertGreaterThanOrEqual(box.frame.y, 0)
                XCTAssertLessThanOrEqual(box.frame.maxY, 152)
                XCTAssertLessThanOrEqual(box.frame.maxX, 296)
            }
            let figures = boxes.filter { box in
                guard case let .text(value, _, _) = box.content else { return false }
                return value.contains("%")
            }
            XCTAssertFalse(figures.isEmpty)
            XCTAssertFalse(figures.contains(where: \.clipsContent))
        }
    }
}
