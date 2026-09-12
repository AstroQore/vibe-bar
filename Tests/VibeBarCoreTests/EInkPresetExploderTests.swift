import XCTest
@testable import VibeBarCore

/// The exploder's one hard promise: a preset turned into a Studio layout draws
/// the same panel it drew before.
///
/// Anything less is a button that silently changes what the device shows, and
/// on a glanceable surface across a room nobody would ever notice which half
/// moved.
final class EInkPresetExploderTests: XCTestCase {
    private func boxes(_ node: EInkNode, orientation: EInkOrientation) -> [EInkDrawBox] {
        let size = EInkDeviceProfile.quote0.frameSize(for: orientation)
        return EInkBoxLayout.resolve(node, in: EInkRect(x: 0, y: 0, width: size.width, height: size.height))
    }

    private func calendar() -> Calendar { EInkFixtures.calendar() }

    func testEveryPresetAtEveryOrientationExplodesIntoTheSameBoxes() throws {
        let snapshot = EInkFixtures.snapshot()
        for preset in EInkPreset.allCases {
            for orientation in EInkOrientation.allCases {
                let slide = EInkFixtures.slide(preset: preset)
                let presetTree = try EInkRenderer.tree(
                    slide: slide,
                    orientation: orientation,
                    snapshot: snapshot,
                    calendar: calendar()
                )
                let layout = EInkPresetExploder.explode(
                    slide: slide,
                    orientation: orientation,
                    snapshot: snapshot,
                    calendar: calendar()
                )
                let explodedTree = EInkCustomLayoutRenderer.tree(
                    layout: layout,
                    slide: slide,
                    orientation: orientation,
                    snapshot: snapshot
                )
                XCTAssertEqual(
                    boxes(explodedTree, orientation: orientation),
                    boxes(presetTree, orientation: orientation),
                    "\(preset.rawValue) at \(orientation.rawValue)° does not survive being exploded"
                )
            }
        }
    }

    /// A name drawn as two fragments keeps both of them bound.
    ///
    /// The landscape briefing was the case round 2 part A left broken: the
    /// row split into "ChatGPT Agentic" and "GPT-5.3 Codex Spark · Weekly",
    /// and exploding it froze both halves as text, so the panel stopped
    /// following the bucket's name the moment anyone opened the Studio.
    func testATwoFragmentNameKeepsABindingForEachFragment() throws {
        var snapshot = EInkFixtures.snapshot()
        snapshot.quota = EInkFixtures.longNameRows(count: 3)
        for preset in [EInkPreset.briefing, .quotaLedger] {
            let slide = EInkFixtures.slide(preset: preset, fieldIDs: snapshot.quota.map(\.fieldID))
            let layout = EInkPresetExploder.explode(
                slide: slide,
                orientation: .degrees0,
                snapshot: snapshot,
                calendar: calendar()
            )
            let slot = layout.elements.filter { $0.moduleID == "slot:codex.spark_weekly" }
            let name = try XCTUnwrap(
                slot.first { $0.textBinding == .label && $0.labelPart == .name },
                "\(preset.rawValue) lost the SubProvider's binding"
            )
            let window = try XCTUnwrap(
                slot.first { $0.textBinding == .label && $0.labelPart == .window },
                "\(preset.rawValue) lost the group and window's binding"
            )
            XCTAssertEqual(name.fieldID, "codex.spark_weekly")
            XCTAssertEqual(window.fieldID, "codex.spark_weekly")
            XCTAssertEqual(
                EInkCustomLayoutRenderer.text(for: name, snapshot: snapshot),
                "ChatGPT Agentic"
            )
            XCTAssertEqual(
                EInkCustomLayoutRenderer.text(for: window, snapshot: snapshot),
                "GPT-5.3 Codex Spark · Weekly"
            )

            // And the exploded layout still draws exactly the preset's panel.
            let presetTree = try EInkRenderer.tree(
                slide: slide,
                orientation: .degrees0,
                snapshot: snapshot,
                calendar: calendar()
            )
            let explodedTree = EInkCustomLayoutRenderer.tree(
                layout: layout,
                slide: slide,
                orientation: .degrees0,
                snapshot: snapshot
            )
            XCTAssertEqual(
                boxes(explodedTree, orientation: .degrees0),
                boxes(presetTree, orientation: .degrees0),
                "\(preset.rawValue) does not survive being exploded"
            )
        }
    }

    /// A fragment renames itself when its bucket does, which is the whole
    /// reason the part is stored rather than the string.
    func testAnExplodedFragmentFollowsTheSlidesOwnNameForTheBucket() throws {
        var snapshot = EInkFixtures.snapshot()
        snapshot.quota = EInkFixtures.longNameRows(count: 2)
        var element = EInkCanvasElement(kind: .text, fieldID: "codex.spark_weekly")
        element.textBinding = .label
        element.labelPart = .window
        var options = EInkSlideOptions.default
        options.customLabels = ["codex.spark_weekly": "ChatGPT Agentic · Codex Spark · Weekly"]
        XCTAssertEqual(
            EInkCustomLayoutRenderer.text(for: element, snapshot: snapshot, options: options),
            "Codex Spark · Weekly"
        )

        // And it round-trips through settings.json.
        let data = try JSONEncoder().encode(element)
        let decoded = try JSONDecoder().decode(EInkCanvasElement.self, from: data)
        XCTAssertEqual(decoded.labelPart, .window)
        XCTAssertEqual(decoded, element)
        // A layout written before parts existed reads as the whole name.
        let legacy = Data(#"{"kind":"text","textBinding":"label","fieldID":"codex.spark_weekly"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(EInkCanvasElement.self, from: legacy).labelPart, .whole)
    }

    /// A slot's elements come back as one group, and the group still follows
    /// its bucket — the difference between a layout and a screenshot.
    func testAQuotaSlotBecomesOneGroupThatKeepsItsBinding() {
        let snapshot = EInkFixtures.snapshot()
        let slide = EInkFixtures.slide(preset: .quotaLedger, fieldIDs: ["claude.five_hour", "claude.weekly"])
        let layout = EInkPresetExploder.explode(slide: slide, orientation: .degrees0, snapshot: snapshot)

        let slotModules = Set(layout.elements.compactMap(\.moduleID)).filter { $0.hasPrefix("slot:") }
        XCTAssertEqual(slotModules, ["slot:claude.five_hour", "slot:claude.weekly"])
        XCTAssertTrue(layout.elements.contains { $0.moduleID == EInkPresets.headerModule })
        XCTAssertTrue(layout.elements.contains { $0.moduleID == EInkPresets.footerModule })

        let slot = layout.elements.filter { $0.moduleID == "slot:claude.weekly" }
        XCTAssertEqual(Set(slot.compactMap(\.groupID)).count, 1, "one slot is one group")
        XCTAssertTrue(slot.contains { $0.kind == .horizontalBar && $0.fieldID == "claude.weekly" })
        XCTAssertTrue(slot.contains { $0.kind == .text && $0.textBinding == .label })
        XCTAssertTrue(slot.contains { $0.kind == .text && $0.textBinding == .countdown })
    }

    /// A bound bar follows its bucket: change the reading and the exploded
    /// layout moves with it, without being exploded again.
    func testAnExplodedBarFollowsItsBucketAfterTheNumbersMove() {
        var snapshot = EInkFixtures.snapshot()
        let slide = EInkFixtures.slide(preset: .quotaLedger, fieldIDs: ["claude.five_hour"])
        let layout = EInkPresetExploder.explode(slide: slide, orientation: .degrees0, snapshot: snapshot)

        snapshot.quota = snapshot.quota.map { row in
            guard row.fieldID == "claude.five_hour" else { return row }
            var moved = row
            moved.remainingPercent = 4
            return moved
        }
        let tree = EInkCustomLayoutRenderer.tree(
            layout: layout,
            slide: slide,
            orientation: .degrees0,
            snapshot: snapshot
        )
        let strings = boxes(tree, orientation: .degrees0).compactMap { box -> String? in
            if case let .text(value, _, _) = box.content { return value }
            return nil
        }
        XCTAssertTrue(strings.contains("4%"), "the exploded percentage still reads the bucket")
        XCTAssertFalse(strings.contains("62%"), "the exploded percentage is not frozen")
    }

    /// A round 1 file has one layout per slide and no orientation in the key.
    func testTheLayoutTableMigratesOntoTheDevicesCurrentOrientation() {
        let slide = EInkSlide(id: "slide-1", kind: .custom(layoutID: "slide-1"))
        let device = EInkDeviceConfig(deviceID: "panel-1", orientation: .degrees90, slides: [slide])
        let layouts = ["slide-1": EInkCanvasLayout(profile: .quote0, orientation: .degrees90)]
        XCTAssertTrue(EInkCanvasLayoutMigration.needsMigration(layouts))

        let migrated = EInkCanvasLayoutMigration.migrated(layouts, devices: [device])
        XCTAssertEqual(Set(migrated.keys), ["slide-1/90"])
        XCTAssertFalse(EInkCanvasLayoutMigration.needsMigration(migrated))
        // Running it twice changes nothing.
        XCTAssertEqual(EInkCanvasLayoutMigration.migrated(migrated, devices: [device]), migrated)
    }

    /// Rotating a panel whose custom slide has no layout for the new
    /// orientation draws the preset's arrangement rather than nothing.
    func testAMissingOrientationFallsBackToExplodingOnTheFly() throws {
        let snapshot = EInkFixtures.snapshot()
        var slide = EInkFixtures.slide(preset: .quotaLedger)
        let layouts = [
            EInkRenderer.layoutKey("slide-1", orientation: .degrees0):
                EInkPresetExploder.explode(slide: slide, orientation: .degrees0, snapshot: snapshot)
        ]
        slide.kind = .custom(layoutID: "slide-1")

        let drawn = try EInkRenderer.tree(
            slide: slide,
            orientation: .degrees90,
            snapshot: snapshot,
            layouts: layouts,
            calendar: calendar()
        )
        var presetSlide = slide
        presetSlide.kind = .preset(.quotaLedger)
        let expected = try EInkRenderer.tree(
            slide: presetSlide,
            orientation: .degrees90,
            snapshot: snapshot,
            calendar: calendar()
        )
        XCTAssertEqual(boxes(drawn, orientation: .degrees90), boxes(expected, orientation: .degrees90))
    }

    /// A slide naming a layout id nothing knows about still refuses to draw:
    /// substituting a preset for a layout the user authored is the failure
    /// `EInkRenderError` exists to prevent.
    func testAnEntirelyUnknownLayoutStillThrows() {
        var slide = EInkFixtures.slide(preset: .quotaLedger)
        slide.kind = .custom(layoutID: "gone")
        XCTAssertThrowsError(
            try EInkRenderer.tree(slide: slide, orientation: .degrees0, snapshot: EInkFixtures.snapshot())
        ) { error in
            XCTAssertEqual(error as? EInkRenderError, .layoutMissing(layoutID: "gone"))
        }
    }

    /// The scans that decide what a pass fetches have to find an oriented
    /// layout too, or a migrated round 1 layout draws bound elements from data
    /// nobody gathered — "$0.00" on a panel, or a blank percentage.
    func testTheDataDependencyScansFindOrientedLayoutsToo() {
        var element = EInkCanvasElement(kind: .statTile)
        element.textBinding = .usageMetric
        var quotaElement = EInkCanvasElement(kind: .horizontalBar, fieldID: "claude.weekly_fable")
        quotaElement.x = 6
        quotaElement.y = 40
        var layout = EInkCanvasLayout(profile: .quote0, orientation: .degrees90)
        layout.elements = [element, quotaElement]

        let slide = EInkSlide(id: "slide-1", kind: .custom(layoutID: "slide-1"))
        let device = EInkDeviceConfig(deviceID: "panel-1", orientation: .degrees90, slides: [slide])
        let settings = EInkSyncSettings(apiKeyPresent: true, syncEnabled: true, devices: [device])
        let oriented = [EInkRenderer.layoutKey("slide-1", orientation: .degrees90): layout]

        XCTAssertTrue(slide.needsUsageData(layouts: oriented))
        XCTAssertTrue(settings.selectedQuotaFieldIDs(layouts: oriented).contains("claude.weekly_fable"))
        XCTAssertTrue(settings.referencedQuotaFieldIDs(layouts: oriented).contains("claude.weekly_fable"))
        XCTAssertEqual(
            EInkAlertEvaluator.watchedFieldIDs(device, layouts: oriented),
            ["claude.weekly_fable"]
        )
    }

    func testReflowProducesThePresetArrangementAgain() {
        let snapshot = EInkFixtures.snapshot()
        let slide = EInkFixtures.slide(preset: .quotaRings)
        let exploded = EInkPresetExploder.explode(slide: slide, orientation: .degrees270, snapshot: snapshot)
        let reflowed = EInkPresetExploder.reflow(slide: slide, orientation: .degrees270, snapshot: snapshot)
        XCTAssertEqual(exploded.elements.map(\.kind), reflowed.elements.map(\.kind))
        XCTAssertEqual(exploded.elements.map(\.x), reflowed.elements.map(\.x))
        XCTAssertEqual(exploded.elements.map(\.y), reflowed.elements.map(\.y))
    }
}
