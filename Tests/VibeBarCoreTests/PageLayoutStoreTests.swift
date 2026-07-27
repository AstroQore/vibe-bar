import XCTest
@testable import VibeBarCore

/// `PageLayoutStore` owns measured card heights only. The user's arrangement
/// moved to `AppSettings.pageLayouts` — see `AppSettingsTests`.
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

    // MARK: - Round trip

    func testPersistsAndReloadsAcrossInstances() async {
        let store = PageLayoutStore(fileURL: tempURL)
        await store.updateMeasuredHeights([.status: 96, .costAll: 240], for: .overview)
        await store.updateMeasuredHeights([.cost(tool: .claude): 310], for: .detail(.claude))
        await store.flushPendingWrites()

        let reloaded = PageLayoutStore(fileURL: tempURL)
        let overview = await reloaded.measuredHeights(for: .overview)
        let claude = await reloaded.measuredHeights(for: .detail(.claude))
        let codex = await reloaded.measuredHeights(for: .detail(.codex))
        let all = await reloaded.allMeasuredHeights()

        XCTAssertEqual(overview, [.status: 96, .costAll: 240])
        XCTAssertEqual(claude, [.cost(tool: .claude): 310])
        XCTAssertTrue(codex.isEmpty)
        XCTAssertEqual(all.count, 2)
    }

    func testUnmeasuredPageHasNoEntry() async {
        let store = PageLayoutStore(fileURL: tempURL)
        let overview = await store.measuredHeights(for: .overview)
        let all = await store.allMeasuredHeights()
        XCTAssertTrue(overview.isEmpty)
        XCTAssertTrue(all.isEmpty)
    }

    // MARK: - Clearing

    func testClearRemovesThePageEntryOnly() async {
        let store = PageLayoutStore(fileURL: tempURL)
        await store.updateMeasuredHeights([.status: 96], for: .overview)
        await store.updateMeasuredHeights([.status: 64], for: .detail(.grok))

        await store.clearMeasuredHeights(for: .overview)
        let clearedOverview = await store.measuredHeights(for: .overview)
        let keptGrok = await store.measuredHeights(for: .detail(.grok))
        XCTAssertTrue(clearedOverview.isEmpty)
        XCTAssertEqual(keptGrok, [.status: 64])
        await store.flushPendingWrites()

        let reloaded = PageLayoutStore(fileURL: tempURL)
        let reloadedOverview = await reloaded.measuredHeights(for: .overview)
        let reloadedGrok = await reloaded.measuredHeights(for: .detail(.grok))
        XCTAssertTrue(reloadedOverview.isEmpty)
        XCTAssertEqual(reloadedGrok, [.status: 64])
    }

    func testClearOnAnUnknownPageIsANoOp() async {
        let store = PageLayoutStore(fileURL: tempURL)
        await store.clearMeasuredHeights(for: .overview)
        await store.flushPendingWrites()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
    }

    // MARK: - Measured heights

    func testMeasuredHeightsMergeOnlyWhenTheChangeExceedsHalfAPoint() async {
        let store = PageLayoutStore(fileURL: tempURL)
        await store.updateMeasuredHeights([.status: 100, .costAll: 200], for: .overview)
        var height = await store.measuredHeights(for: .overview)[.status]
        XCTAssertEqual(height, 100)

        // Sub-threshold wobble is ignored in both directions, and 0.5 pt
        // exactly still counts as noise.
        await store.updateMeasuredHeights([.status: 100.4], for: .overview)
        height = await store.measuredHeights(for: .overview)[.status]
        XCTAssertEqual(height, 100)

        await store.updateMeasuredHeights([.status: 99.5], for: .overview)
        height = await store.measuredHeights(for: .overview)[.status]
        XCTAssertEqual(height, 100)

        await store.updateMeasuredHeights([.status: 100.5], for: .overview)
        height = await store.measuredHeights(for: .overview)[.status]
        XCTAssertEqual(height, 100)

        // A real change lands.
        await store.updateMeasuredHeights([.status: 100.6], for: .overview)
        height = await store.measuredHeights(for: .overview)[.status]
        XCTAssertEqual(height, 100.6)

        // Untouched entries survive the merge.
        let untouched = await store.measuredHeights(for: .overview)[.costAll]
        XCTAssertEqual(untouched, 200)
    }

    func testMeasuredHeightsIgnoreNonPositiveAndNonFiniteValues() async {
        let store = PageLayoutStore(fileURL: tempURL)
        await store.updateMeasuredHeights(
            [.status: 0, .costAll: -12, .quotaHistoryAll: .nan, .cost(tool: .codex): .infinity],
            for: .overview
        )
        let empty = await store.measuredHeights(for: .overview)
        XCTAssertTrue(empty.isEmpty)

        await store.updateMeasuredHeights([.status: 0, .costAll: 42], for: .overview)
        let stored = await store.measuredHeights(for: .overview)
        XCTAssertNil(stored[.status])
        XCTAssertEqual(stored[.costAll], 42)
    }

    // MARK: - File handling

    func testFileIsWrittenOwnerOnly() async throws {
        let store = PageLayoutStore(fileURL: tempURL)
        await store.updateMeasuredHeights([.status: 96], for: .overview)
        await store.flushPendingWrites()

        let attributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
    }

    func testEraseAllRemovesTheFileAndTheCache() async {
        let store = PageLayoutStore(fileURL: tempURL)
        await store.updateMeasuredHeights([.status: 96], for: .overview)
        await store.flushPendingWrites()
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))

        await store.eraseAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
        let inMemory = await store.allMeasuredHeights()
        let onDisk = await PageLayoutStore(fileURL: tempURL).allMeasuredHeights()
        XCTAssertTrue(inMemory.isEmpty)
        XCTAssertTrue(onDisk.isEmpty)
    }

    func testCorruptFileLoadsEmptyAndStillAcceptsNewHeights() async {
        try? Data("not json".utf8).write(to: tempURL, options: .atomic)
        let store = PageLayoutStore(fileURL: tempURL)
        let initial = await store.allMeasuredHeights()
        XCTAssertTrue(initial.isEmpty)

        await store.updateMeasuredHeights([.status: 96], for: .overview)
        await store.flushPendingWrites()
        let reloaded = await PageLayoutStore(fileURL: tempURL).measuredHeights(for: .overview)
        XCTAssertEqual(reloaded, [.status: 96])
    }

    func testFileFromANewerSchemaIsDiscarded() async {
        let blob = Data(#"""
        {"schemaVersion": 99, "pages": {"overview": {"measuredHeights": {"status": 77}}}}
        """#.utf8)
        try? blob.write(to: tempURL, options: .atomic)

        let store = PageLayoutStore(fileURL: tempURL)
        let all = await store.allMeasuredHeights()
        XCTAssertTrue(all.isEmpty)
    }

    /// The arrangement used to live in this file. A developer's stale copy must
    /// still yield its heights — and quietly drop the rest, which now belongs
    /// to `AppSettings`.
    func testReadsHeightsOutOfAFileThatStillCarriesTheOldArrangementFields() async {
        let blob = Data(#"""
        {
          "schemaVersion": 1,
          "generatedBy": "vibe-bar 9.9",
          "pages": {
            "overview": {
              "ratio": "wide-narrow",
              "columns": [["status"], ["cost-all", "future-card:v9"]],
              "measuredHeights": {"status": 77, "future-card:v9": 51},
              "pinnedModules": ["status"]
            },
            "detail:claude": {
              "ratio": "narrow-wide",
              "columns": [["quota-group:claude:five_hour"], []]
            },
            "detail:some-future-provider": {
              "measuredHeights": {"quota-history-all": 123}
            }
          }
        }
        """#.utf8)
        try? blob.write(to: tempURL, options: .atomic)

        let store = PageLayoutStore(fileURL: tempURL)
        let overview = await store.measuredHeights(for: .overview)
        XCTAssertEqual(overview[.status], 77)
        XCTAssertEqual(overview[PageLayoutModuleID("future-card:v9")], 51)

        // A page whose entry carried only an arrangement contributes nothing.
        let claude = await store.measuredHeights(for: .detail(.claude))
        XCTAssertTrue(claude.isEmpty)

        // A page for a provider this build does not know keeps its heights.
        let future = await store.measuredHeights(for: PageLayoutPageID("detail:some-future-provider"))
        XCTAssertEqual(future[.quotaHistoryAll], 123)
    }

    func testUnknownPagesAndModulesSurviveARewrite() async {
        let blob = Data(#"""
        {
          "schemaVersion": 1,
          "pages": {
            "detail:some-future-provider": {
              "measuredHeights": {"future-card:v9": 51}
            }
          }
        }
        """#.utf8)
        try? blob.write(to: tempURL, options: .atomic)

        let store = PageLayoutStore(fileURL: tempURL)
        await store.updateMeasuredHeights([.status: 96], for: .overview)
        await store.flushPendingWrites()

        let reloaded = PageLayoutStore(fileURL: tempURL)
        let future = await reloaded.measuredHeights(
            for: PageLayoutPageID("detail:some-future-provider")
        )
        let overview = await reloaded.measuredHeights(for: .overview)
        XCTAssertEqual(future[PageLayoutModuleID("future-card:v9")], 51)
        XCTAssertEqual(overview, [.status: 96])
    }

    func testWritesUseStringKeyedPageAndModuleObjectsAndNoArrangement() async throws {
        let store = PageLayoutStore(fileURL: tempURL)
        await store.updateMeasuredHeights([.status: 96], for: .overview)
        await store.flushPendingWrites()

        let data = try Data(contentsOf: tempURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["schemaVersion"] as? Int, 1)
        let pages = try XCTUnwrap(root["pages"] as? [String: Any])
        let overview = try XCTUnwrap(pages["overview"] as? [String: Any])
        let heights = try XCTUnwrap(overview["measuredHeights"] as? [String: Double])
        XCTAssertEqual(heights["status"], 96)
        // Arrangement is a user preference and lives in AppSettings now.
        XCTAssertNil(overview["ratio"])
        XCTAssertNil(overview["columns"])
    }
}
