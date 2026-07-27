import XCTest
@testable import VibeBarCore

final class PageLayoutStoreTests: XCTestCase {
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-layout-tests-\(UUID().uuidString).json")
    }

    override func tearDown() {
        if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
        super.tearDown()
    }

    private func sampleConfig() -> PageLayoutConfig {
        PageLayoutConfig(
            ratio: .wideNarrow,
            columns: [
                [.quotaGroup(tool: .codex, groupKey: "weekly"), .costAll],
                [.status]
            ],
            measuredHeights: [.status: 96]
        )
    }

    // MARK: - Round trip

    func testPersistsAndReloadsAcrossInstances() async {
        let store = PageLayoutStore(fileURL: tempURL)
        let config = sampleConfig()
        await store.setConfig(config, for: .overview)
        await store.setConfig(
            PageLayoutConfig(ratio: .narrowWide, columns: [[.cost(tool: .claude)], []]),
            for: .detail(.claude)
        )
        await store.flushPendingWrites()

        let reloaded = PageLayoutStore(fileURL: tempURL)
        let overview = await reloaded.config(for: .overview)
        let claude = await reloaded.config(for: .detail(.claude))
        let codex = await reloaded.config(for: .detail(.codex))
        let all = await reloaded.allConfigs()

        XCTAssertEqual(overview, config)
        XCTAssertEqual(claude?.ratio, .narrowWide)
        XCTAssertEqual(claude?.leftColumn, [.cost(tool: .claude)])
        XCTAssertNil(codex)
        XCTAssertEqual(all.count, 2)
    }

    func testSetConfigNormalizesBeforeStoring() async {
        let store = PageLayoutStore(fileURL: tempURL)
        await store.setConfig(
            PageLayoutConfig(columns: [[.status, .costAll], [.status], [.quotaHistoryAll]]),
            for: .overview
        )
        let stored = await store.config(for: .overview)
        XCTAssertEqual(stored?.leftColumn, [.status, .costAll])
        XCTAssertEqual(stored?.rightColumn, [.quotaHistoryAll])
    }

    func testUnconfiguredPageHasNoEntry() async {
        let store = PageLayoutStore(fileURL: tempURL)
        let overview = await store.config(for: .overview)
        let all = await store.allConfigs()
        XCTAssertNil(overview)
        XCTAssertTrue(all.isEmpty)
    }

    // MARK: - Reset

    func testResetRemovesThePageEntryOnly() async {
        let store = PageLayoutStore(fileURL: tempURL)
        await store.setConfig(sampleConfig(), for: .overview)
        await store.setConfig(PageLayoutConfig(columns: [[.status], []]), for: .detail(.grok))

        await store.resetConfig(for: .overview)
        let clearedOverview = await store.config(for: .overview)
        let keptGrok = await store.config(for: .detail(.grok))
        XCTAssertNil(clearedOverview)
        XCTAssertNotNil(keptGrok)
        await store.flushPendingWrites()

        let reloaded = PageLayoutStore(fileURL: tempURL)
        let reloadedOverview = await reloaded.config(for: .overview)
        let reloadedGrok = await reloaded.config(for: .detail(.grok))
        XCTAssertNil(reloadedOverview)
        XCTAssertNotNil(reloadedGrok)
    }

    func testResetAlsoDropsMeasuredHeights() async {
        let store = PageLayoutStore(fileURL: tempURL)
        await store.updateMeasuredHeights([.status: 120], for: .overview)
        let before = await store.config(for: .overview)
        XCTAssertEqual(before?.measuredHeight(for: .status), 120)

        await store.resetConfig(for: .overview)
        let after = await store.config(for: .overview)
        XCTAssertNil(after)
    }

    func testResetOnAnUnknownPageIsANoOp() async {
        let store = PageLayoutStore(fileURL: tempURL)
        await store.resetConfig(for: .overview)
        await store.flushPendingWrites()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
    }

    // MARK: - Measured heights

    func testMeasuredHeightsMergeOnlyWhenTheChangeExceedsHalfAPoint() async {
        let store = PageLayoutStore(fileURL: tempURL)
        await store.updateMeasuredHeights([.status: 100, .costAll: 200], for: .overview)
        var height = await store.config(for: .overview)?.measuredHeight(for: .status)
        XCTAssertEqual(height, 100)

        // Sub-threshold wobble is ignored in both directions, and 0.5 pt
        // exactly still counts as noise.
        await store.updateMeasuredHeights([.status: 100.4], for: .overview)
        height = await store.config(for: .overview)?.measuredHeight(for: .status)
        XCTAssertEqual(height, 100)

        await store.updateMeasuredHeights([.status: 99.5], for: .overview)
        height = await store.config(for: .overview)?.measuredHeight(for: .status)
        XCTAssertEqual(height, 100)

        await store.updateMeasuredHeights([.status: 100.5], for: .overview)
        height = await store.config(for: .overview)?.measuredHeight(for: .status)
        XCTAssertEqual(height, 100)

        // A real change lands.
        await store.updateMeasuredHeights([.status: 100.6], for: .overview)
        height = await store.config(for: .overview)?.measuredHeight(for: .status)
        XCTAssertEqual(height, 100.6)

        // Untouched entries survive the merge.
        let untouched = await store.config(for: .overview)?.measuredHeight(for: .costAll)
        XCTAssertEqual(untouched, 200)
    }

    func testMeasuredHeightsIgnoreNonPositiveAndNonFiniteValues() async {
        let store = PageLayoutStore(fileURL: tempURL)
        await store.updateMeasuredHeights(
            [.status: 0, .costAll: -12, .quotaHistoryAll: .nan, .cost(tool: .codex): .infinity],
            for: .overview
        )
        let empty = await store.config(for: .overview)
        XCTAssertNil(empty)

        await store.updateMeasuredHeights([.status: 0, .costAll: 42], for: .overview)
        let stored = await store.config(for: .overview)
        XCTAssertNil(stored?.measuredHeight(for: .status))
        XCTAssertEqual(stored?.measuredHeight(for: .costAll), 42)
    }

    func testMeasuredHeightsDoNotDisturbTheSavedArrangement() async {
        let store = PageLayoutStore(fileURL: tempURL)
        let config = sampleConfig()
        await store.setConfig(config, for: .overview)
        await store.updateMeasuredHeights([.costAll: 310], for: .overview)

        let stored = await store.config(for: .overview)
        XCTAssertEqual(stored?.columns, config.columns)
        XCTAssertEqual(stored?.ratio, .wideNarrow)
        XCTAssertEqual(stored?.measuredHeight(for: .costAll), 310)
        XCTAssertEqual(stored?.measuredHeight(for: .status), 96)
    }

    func testHeightsOnlyEntryIsRecognizableAsUncustomized() async {
        let store = PageLayoutStore(fileURL: tempURL)
        await store.updateMeasuredHeights([.status: 64], for: .overview)
        let stored = await store.config(for: .overview)
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.isEmpty, true)
    }

    // MARK: - File handling

    func testFileIsWrittenOwnerOnly() async throws {
        let store = PageLayoutStore(fileURL: tempURL)
        await store.setConfig(sampleConfig(), for: .overview)
        await store.flushPendingWrites()

        let attributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
    }

    func testEraseAllRemovesTheFileAndTheCache() async {
        let store = PageLayoutStore(fileURL: tempURL)
        await store.setConfig(sampleConfig(), for: .overview)
        await store.flushPendingWrites()
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))

        await store.eraseAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
        let inMemory = await store.allConfigs()
        let onDisk = await PageLayoutStore(fileURL: tempURL).allConfigs()
        XCTAssertTrue(inMemory.isEmpty)
        XCTAssertTrue(onDisk.isEmpty)
    }

    func testCorruptFileLoadsEmptyAndStillAcceptsNewConfigs() async {
        try? Data("not json".utf8).write(to: tempURL, options: .atomic)
        let store = PageLayoutStore(fileURL: tempURL)
        let initial = await store.allConfigs()
        XCTAssertTrue(initial.isEmpty)

        await store.setConfig(sampleConfig(), for: .overview)
        await store.flushPendingWrites()
        let reloaded = await PageLayoutStore(fileURL: tempURL).config(for: .overview)
        XCTAssertEqual(reloaded, sampleConfig())
    }

    func testFileFromANewerSchemaIsDiscarded() async {
        let blob = Data(#"""
        {"schemaVersion": 99, "pages": {"overview": {"ratio": "equal", "columns": [["status"], []]}}}
        """#.utf8)
        try? blob.write(to: tempURL, options: .atomic)

        let store = PageLayoutStore(fileURL: tempURL)
        let all = await store.allConfigs()
        XCTAssertTrue(all.isEmpty)
    }

    func testDecodesAFileWithUnknownFieldsPagesAndModules() async {
        let blob = Data(#"""
        {
          "schemaVersion": 1,
          "generatedBy": "vibe-bar 9.9",
          "pages": {
            "overview": {
              "ratio": "wide-narrow",
              "columns": [["status"], ["cost-all", "future-card:v9"]],
              "measuredHeights": {"status": 77},
              "pinnedModules": ["status"]
            },
            "detail:claude": {
              "ratio": "narrow-wide",
              "columns": [["quota-group:claude:five_hour"], []]
            },
            "detail:some-future-provider": {
              "ratio": "spiral",
              "columns": [["quota-history-all"], []]
            }
          }
        }
        """#.utf8)
        try? blob.write(to: tempURL, options: .atomic)

        let store = PageLayoutStore(fileURL: tempURL)
        let all = await store.allConfigs()
        XCTAssertEqual(all.count, 3)

        let overview = await store.config(for: .overview)
        XCTAssertEqual(overview?.ratio, .wideNarrow)
        XCTAssertEqual(overview?.leftColumn, [.status])
        XCTAssertEqual(overview?.rightColumn, [.costAll, PageLayoutModuleID("future-card:v9")])
        XCTAssertEqual(overview?.measuredHeight(for: .status), 77)

        let claude = await store.config(for: .detail(.claude))
        XCTAssertEqual(claude?.leftColumn, [.quotaGroup(tool: .claude, groupKey: "five_hour")])

        // A page for a provider this build does not know survives intact, and
        // its unreadable ratio degrades to the fallback rather than dropping
        // the entry.
        let future = await store.config(for: PageLayoutPageID("detail:some-future-provider"))
        XCTAssertEqual(future?.ratio, .equal)
        XCTAssertEqual(future?.leftColumn, [.quotaHistoryAll])
    }

    func testUnknownPagesAndModulesSurviveARewrite() async {
        let blob = Data(#"""
        {
          "schemaVersion": 1,
          "pages": {
            "detail:some-future-provider": {
              "ratio": "equal",
              "columns": [["future-card:v9"], []],
              "measuredHeights": {"future-card:v9": 51}
            }
          }
        }
        """#.utf8)
        try? blob.write(to: tempURL, options: .atomic)

        let store = PageLayoutStore(fileURL: tempURL)
        await store.setConfig(sampleConfig(), for: .overview)
        await store.flushPendingWrites()

        let reloaded = PageLayoutStore(fileURL: tempURL)
        let future = await reloaded.config(for: PageLayoutPageID("detail:some-future-provider"))
        let overview = await reloaded.config(for: .overview)
        XCTAssertEqual(future?.leftColumn, [PageLayoutModuleID("future-card:v9")])
        XCTAssertEqual(future?.measuredHeight(for: PageLayoutModuleID("future-card:v9")), 51)
        XCTAssertEqual(overview, sampleConfig())
    }

    func testWritesUseStringKeyedPageAndModuleObjects() async throws {
        let store = PageLayoutStore(fileURL: tempURL)
        await store.setConfig(sampleConfig(), for: .overview)
        await store.flushPendingWrites()

        let data = try Data(contentsOf: tempURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["schemaVersion"] as? Int, 1)
        let pages = try XCTUnwrap(root["pages"] as? [String: Any])
        let overview = try XCTUnwrap(pages["overview"] as? [String: Any])
        XCTAssertEqual(overview["ratio"] as? String, "wide-narrow")
        XCTAssertEqual(
            overview["columns"] as? [[String]],
            [["quota-group:codex:weekly", "cost-all"], ["status"]]
        )
        let heights = try XCTUnwrap(overview["measuredHeights"] as? [String: Double])
        XCTAssertEqual(heights["status"], 96)
    }
}
