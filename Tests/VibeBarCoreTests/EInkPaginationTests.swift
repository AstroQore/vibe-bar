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
        let pages = EInkPagination.frames(group, snapshot: EInkFixtures.snapshot())
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
        let pages = EInkPagination.frames(group, snapshot: EInkFixtures.snapshot())
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

    func testStudioTemplateKeepsEveryOverflowPageBoundToTheRightQuota() throws {
        var snapshot = EInkFixtures.snapshot()
        let seed = snapshot.quota[0]
        snapshot.quota = (0..<13).map { index in
            var row = seed; row.fieldID = "codex.template-\(index)"
            row.providerDisplayName = "Provider \(index)"; row.windowTitle = "Weekly"
            row.remainingPercent = 20 + index
            return row
        }
        var slide = EInkSlide(id: "studio", kind: .preset(.quotaRings), quotaFieldIDs: snapshot.quota.map(\.fieldID))
        let layout = EInkPresetExploder.explode(slide: slide, orientation: .degrees0, snapshot: snapshot)
        slide.kind = .custom(layoutID: "template"); slide.options.sourcePreset = .quotaRings
        let layouts = ["template/0": layout]
        let settings = EInkSyncSettings(devices: [.init(deviceID: "panel", slides: [slide])])
        XCTAssertEqual(Set(settings.selectedQuotaFieldIDs(layouts: layouts)), Set(slide.quotaFieldIDs))
        XCTAssertEqual(EInkAlertEvaluator.watchedFieldIDs(settings.devices[0], layouts: layouts), Set(slide.quotaFieldIDs))
        let pages = EInkPagination.pages(slide, orientation: .degrees0, snapshot: snapshot, layouts: layouts)
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pages.flatMap(\.quotaFieldIDs), slide.quotaFieldIDs)
        for page in pages {
            let tree = try EInkRenderer.tree(slide: page, orientation: .degrees0, snapshot: snapshot, layouts: layouts)
            let bindings = EInkBoxLayout.resolveAnnotated(tree, in: EInkRect(x: 0, y: 0, width: 296, height: 152)).compactMap { $0.binding?.fieldID }
            XCTAssertEqual(Set(bindings), Set(page.quotaFieldIDs))
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
            XCTAssertNil(object["renderFieldMap"])
            XCTAssertNil(object["renderSourceFieldIDs"])
        }
        XCTAssertEqual(layouts["template/0"], layout, "rendering a page does not rewrite the saved template")
    }

    func testDisabledGroupStillOwnsMembersAndOldSettingsDecode() throws {
        let settings = EInkSyncSettings(devices: [.init(deviceID: "a"),.init(deviceID: "b")], groups: [.init(id: "group", screens: [.init(deviceID: "a"),.init(deviceID: "b",y:152)])])
        XCTAssertEqual(settings.owningGroup(for: "a")?.id, "group")
        XCTAssertNil(settings.group(for: "a"))
        let decoded = try JSONDecoder().decode(EInkSyncSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.groups.count, 1)
        XCTAssertNil(decoded.groups[0].behavior)
    }
}
