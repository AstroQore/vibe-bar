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
