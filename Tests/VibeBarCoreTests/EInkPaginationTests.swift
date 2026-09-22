import XCTest
@testable import VibeBarCore

final class EInkPaginationTests: XCTestCase {
    func testMoreThanFiveFieldsProducePagesWithoutLosingOrderOrOptions() {
        let fields = (1...13).map { "codex.bucket-\($0)" }
        var slide = EInkSlide(id: "gallery", kind: .preset(.quotaRings), quotaFieldIDs: fields)
        slide.options.slotOrder = Array(fields.reversed())
        slide.options.customLabels[fields[0]] = "Important quota"
        let pages = EInkPagination.pages(slide, orientation: .degrees0)
        XCTAssertEqual(pages.count, 3)
        XCTAssertEqual(pages.map { $0.quotaFieldIDs.count }, [5, 5, 3])
        XCTAssertEqual(pages.flatMap(\.quotaFieldIDs), Array(fields.reversed()))
        XCTAssertEqual(Set(pages.map(\.id)).count, 3)
        XCTAssertEqual(pages[2].options.customLabels[fields[0]], "Important quota")
        XCTAssertEqual(slide.fitted(to: .degrees90).quotaFieldIDs, fields)
    }

    func testSingleLogicalSlideAutomaticallyTurnsItsPages() {
        let slide = EInkSlide(id: "gallery", kind: .preset(.quotaRings), quotaFieldIDs: (1...12).map { "codex.bucket-\($0)" })
        let device = EInkDeviceConfig(deviceID: "panel", playbackMode: .single, singleSlideID: slide.id, slides: [slide])
        let playback = EInkPagination.playbackDevice(device)
        XCTAssertEqual(playback.playbackMode, .appTimer)
        XCTAssertEqual(playback.slides.count, 3)
        XCTAssertEqual(device.slides.count, 1, "derived pages must not multiply saved slides")
    }

    func testADeviceLoopWithoutEnoughSlotsFallsBackWithoutDroppingPages() {
        let slide = EInkSlide(id: "gallery", kind: .preset(.quotaRings), quotaFieldIDs: (1...12).map { "codex.bucket-\($0)" })
        let device = EInkDeviceConfig(deviceID: "panel", playbackMode: .deviceLoop, taskKeys: ["one", "two"], slides: [slide])
        XCTAssertEqual(EInkPagination.playbackDevice(device).playbackMode, .appTimer)
    }

    func testGroupRegionsAdvanceTogetherAndShorterRegionHoldsItsPage() {
        let long = EInkSlide(id: "long", kind: .preset(.quotaRings), quotaFieldIDs: (1...12).map { "codex.bucket-\($0)" })
        let short = EInkSlide(id: "short", kind: .preset(.quotaRings), quotaFieldIDs: ["claude.weekly"])
        let group = EInkScreenGroup(frames: [.init(regions: [.init(deviceIDs: ["a"], slide: long), .init(deviceIDs: ["b"], slide: short)])])
        let pages = EInkPagination.frames(group, snapshot: snapshot(carrying: long.quotaFieldIDs + short.quotaFieldIDs))
        XCTAssertEqual(pages.count, 3)
        XCTAssertEqual(pages.flatMap { $0.regions[0].slide.quotaFieldIDs }, long.quotaFieldIDs)
        XCTAssertTrue(pages.allSatisfy { $0.regions[1].slide.quotaFieldIDs == short.quotaFieldIDs && $0.regions[1].slide.id == short.id })
    }

    func testGroupingCarriesAllExistingSlidesAndCanMergeAndSplitSelections() {
        let a = EInkDeviceConfig(deviceID: "a", slides: [.init(id: "a1", kind: .preset(.quotaRings), quotaFieldIDs: ["codex.weekly"]), .init(id: "a2", kind: .preset(.usageTiles))])
        let b = EInkDeviceConfig(deviceID: "b", slides: [.init(id: "b1", kind: .preset(.quotaRings), quotaFieldIDs: ["claude.weekly"])])
        let c = EInkDeviceConfig(deviceID: "c", slides: [.init(id: "c1", kind: .preset(.quotaRings), quotaFieldIDs: ["gemini.weekly"])])
        let group = EInkGroupSlides.create(name: "Three screens", devices: [a,b,c], vertical: true)
        XCTAssertEqual(group.screens.map(\.y), [0,152,304])
        XCTAssertEqual(group.frames.count, 2)
        XCTAssertEqual(group.frames[1].regions[0].slide.id, "a2")
        let regions = group.frames[0].regions
        let mixed = EInkGroupSlides.merging(Set(regions.prefix(2).map(\.id)), in: group.frames[0])
        XCTAssertEqual(mixed.regions.count, 2)
        XCTAssertEqual(mixed.regions[0].deviceIDs, ["a","b"])
        XCTAssertEqual(mixed.regions[0].slide.quotaFieldIDs, ["codex.weekly","claude.weekly"])
        XCTAssertEqual(EInkGroupSlides.splitting(mixed.regions[0].id, in: mixed).regions.count, 3)
    }

    func testGroupSingleSlideKeepsItsOwnPagesAndExcludesOtherSlides() {
        let first = EInkSlide(id: "first", kind: .preset(.quotaRings), quotaFieldIDs: ["claude.weekly"])
        let chosen = EInkSlide(id: "chosen", kind: .preset(.quotaRings), quotaFieldIDs: (1...12).map { "codex.bucket-\($0)" })
        var group = EInkScreenGroup(frames: [
            .init(id: "one", regions: [.init(deviceIDs: ["a", "b"], slide: first)]),
            .init(id: "two", regions: [.init(deviceIDs: ["a", "b"], slide: chosen)])])
        group.playbackMode = .single; group.singleSlideID = "two"
        let pages = EInkPagination.frames(group, snapshot: snapshot(carrying: first.quotaFieldIDs + chosen.quotaFieldIDs))
        XCTAssertEqual(pages.count, 3)
        XCTAssertTrue(pages.allSatisfy { $0.id.hasPrefix("two") })
        XCTAssertEqual(pages.flatMap { $0.regions[0].slide.quotaFieldIDs }, chosen.quotaFieldIDs)
    }

    func testAdaptivePaginationOnlyConsumesFieldsThatWereActuallyDrawn() throws {
        var snapshot = EInkFixtures.snapshot()
        let seed = snapshot.quota[0]
        snapshot.quota = (0..<13).map { index in
            var row = seed
            row.fieldID = "codex.long-\(index)"
            row.providerDisplayName = "ChatGPT Agentic"
            row.windowTitle = "GPT-5.3 Codex Spark Weekly \(index)"
            return row
        }
        let slide = EInkSlide(id: "long", kind: .preset(.quotaRings), quotaFieldIDs: snapshot.quota.map(\.fieldID))
        let pages = EInkPagination.pages(slide, orientation: .degrees0, snapshot: snapshot)
        func bindings(_ node: EInkNode) -> Set<String> {
            var result = Set(node.binding?.fieldID.map { [$0] } ?? [])
            for child in node.children { result.formUnion(bindings(child)) }
            return result
        }
        for page in pages {
            let tree = try EInkRenderer.tree(slide: page, orientation: .degrees0, snapshot: snapshot)
            XCTAssertTrue(Set(page.quotaFieldIDs).isSubset(of: bindings(tree)))
        }
        XCTAssertEqual(pages.flatMap(\.quotaFieldIDs), slide.quotaFieldIDs)
        XCTAssertGreaterThan(pages.count, 3, "long names need more pages than the nominal five-slot capacity")
    }

    func testAddingAThirdScreenCreatesEditableContentForEverySlide() {
        let a = EInkDeviceConfig(deviceID: "a", slides: [.init(id: "a1", kind: .preset(.quotaLedger))])
        let b = EInkDeviceConfig(deviceID: "b", slides: [.init(id: "b1", kind: .preset(.quotaRings))])
        let c = EInkDeviceConfig(deviceID: "c", slides: [.init(id: "c1", kind: .preset(.usageTiles)), .init(id: "c2", kind: .preset(.usageSplit))])
        let group = EInkGroupSlides.adding(c, to: EInkGroupSlides.create(name: "Group", devices: [a,b], vertical: true), devices: [a,b,c])
        XCTAssertEqual(group.screens.count, 3)
        XCTAssertEqual(group.frames.count, 2)
        XCTAssertEqual(group.frames[1].regions.last?.slide.id, "c2")
        XCTAssertTrue(group.frames.allSatisfy { $0.regions.flatMap(\.deviceIDs) == ["a","b","c"] })
    }

    func testCombinedCanvasUsesItsExtraSpaceAndKeepsEveryPayloadWithinLimits() throws {
        var snapshot = EInkFixtures.snapshot()
        let seed = snapshot.quota[0]
        snapshot.quota = (0..<13).map { index in
            var row = seed; row.fieldID = "codex.short-\(index)"
            row.providerDisplayName = "P\(index)"; row.windowTitle = "Weekly"
            return row
        }
        let slide = EInkSlide(id: "combined", kind: .preset(.quotaLedger), quotaFieldIDs: snapshot.quota.map(\.fieldID))
        let single = EInkPagination.pages(slide, orientation: .degrees0, snapshot: snapshot)
        let profile = EInkDeviceProfile(width: 296, height: 304)
        let combined = EInkPagination.pages(slide, orientation: .degrees0, profile: profile, snapshot: snapshot)
        XCTAssertLessThan(combined.count, single.count)
        XCTAssertEqual(combined.flatMap(\.quotaFieldIDs), slide.quotaFieldIDs)
        for page in combined {
            let device = EInkDeviceConfig(deviceID: "virtual", profile: profile, slides: [page])
            XCTAssertNoThrow(try EInkRenderer.render(slide: page, device: device, snapshot: snapshot))
        }
    }

    func testMaterializingPagesKeepsEverySelectionAndUsesIndependentSlideIDs() {
        let slide = EInkSlide(id: "original", kind: .preset(.quotaRings), quotaFieldIDs: (0..<13).map { "codex.extra-\($0)" })
        let pages = EInkPagination.materializedPages(slide, orientation: .degrees0, snapshot: snapshot(carrying: slide.quotaFieldIDs))
        XCTAssertEqual(pages.flatMap(\.quotaFieldIDs), slide.quotaFieldIDs)
        XCTAssertEqual(pages.first?.id, slide.id)
        XCTAssertEqual(Set(pages.map(\.id)).count, pages.count)
        XCTAssertGreaterThan(pages.count, 1)
    }

    func testMaterializedGroupSlidesKeepAllScreensAndContent() {
        let slide = EInkSlide(id: "original", kind: .preset(.quotaRings), quotaFieldIDs: (0..<13).map { "codex.extra-\($0)" })
        let frame = EInkScreenFrame(id: "frame", regions: [.init(deviceIDs: ["a","b"], slide: slide)])
        let group = EInkScreenGroup(frames: [frame])
        let pages = EInkPagination.materializedFrames(frame, group: group, devices: [], snapshot: EInkFixtures.snapshot())
        XCTAssertEqual(pages.flatMap { $0.regions[0].slide.quotaFieldIDs }, slide.quotaFieldIDs)
        XCTAssertTrue(pages.allSatisfy { $0.regions[0].deviceIDs == ["a","b"] })
        XCTAssertEqual(Set(pages.map(\.id)).count, pages.count)
        XCTAssertEqual(Set(pages.map { $0.regions[0].id }).count, pages.count)
    }

    func testGroupImportsTheCurrentPortraitLayoutWithoutChangingItsSource() throws {
        let slide = EInkSlide(id: "portrait", kind: .custom(layoutID: "source"))
        let a = EInkDeviceConfig(deviceID: "a", orientation: .degrees90, slides: [slide])
        let b = EInkDeviceConfig(deviceID: "b", slides: [.init(id: "b", kind: .preset(.quotaLedger))])
        var portrait = EInkCanvasLayout(profile: .quote0, orientation: .degrees90)
        var element = EInkCanvasElement(kind: .text); element.text = "Portrait content"
        portrait.elements = [element]
        let layouts = ["source/0": EInkCanvasLayout(), "source/90": portrait]
        let imported = EInkGroupSlides.importingLayouts(EInkGroupSlides.create(name: "Group", devices: [a,b], vertical: true), devices: [a,b], layouts: layouts)
        let id = try XCTUnwrap(imported.group.frames[0].regions[0].slide.kind.layoutID)
        XCTAssertNotEqual(id, "source")
        XCTAssertEqual(imported.additions[id + "/0"], portrait)
        XCTAssertEqual(layouts["source/90"], portrait)
        XCTAssertEqual(EInkPreset.quotaRings.layoutOrientation(.degrees0, width: 152, height: 296), .degrees90)
    }

    func testDisabledGroupStillOwnsMembersAndOldSettingsDecode() throws {
        let settings = EInkSyncSettings(devices: [.init(deviceID: "a"),.init(deviceID: "b")], groups: [.init(id: "group", screens: [.init(deviceID: "a"),.init(deviceID: "b",y:152)])])
        XCTAssertEqual(settings.owningGroup(for: "a")?.id, "group")
        XCTAssertNil(settings.group(for: "a"))
        let decoded = try JSONDecoder().decode(EInkSyncSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.groups.count, 1)
        XCTAssertNil(decoded.groups[0].behavior)
    }

    func testABucketTheSnapshotLacksNeitherTakesASlotNorMakesAPage() throws {
        let present = (0..<6).map { "codex.present-\($0)" }
        let missing = (0..<6).map { "claude.gone-\($0)" }
        let snapshot = snapshot(carrying: present)
        // Five buckets from a provider that has since logged out lead the
        // selection, and one more trails it.
        let fields = Array(missing.prefix(5)) + present + [missing[5]]
        let slide = EInkSlide(id: "mixed", kind: .preset(.quotaRings), quotaFieldIDs: fields)
        let pages = EInkPagination.pages(slide, orientation: .degrees0, snapshot: snapshot)
        XCTAssertEqual(pages.count, 2, "six live rows fill one page and start a second; the missing ones make none")
        XCTAssertEqual(pages.flatMap(\.quotaFieldIDs), fields, "the selection is kept whole for materializing")
        for page in pages {
            let rows = snapshot.quotaRows(fieldIDs: page.orderedQuotaFieldIDs, limit: .max)
            XCTAssertFalse(rows.isEmpty, "no page may come out blank")
        }
        let gone = EInkSlide(id: "gone", kind: .preset(.quotaRings), quotaFieldIDs: missing)
        XCTAssertEqual(EInkPagination.pages(gone, orientation: .degrees0, snapshot: snapshot).map(\.quotaFieldIDs), [missing])
    }

    private func snapshot(carrying fields: [String]) -> EInkDataSnapshot {
        var snapshot = EInkFixtures.snapshot()
        let seed = snapshot.quota[0]
        snapshot.quota = fields.enumerated().map { index, fieldID in
            var row = seed
            row.fieldID = fieldID
            row.providerDisplayName = "P\(index)"
            row.windowTitle = "Weekly"
            return row
        }
        return snapshot
    }
}
