import XCTest
@testable import VibeBarCore

final class CostSnapshotCacheTests: XCTestCase {
    func testRemovingCursorSnapshotPreventsFutureHydration() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCostSnapshotRemoval-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        let cache = CostSnapshotCache(directory: directory)
        let snapshot = CostSnapshot.empty(tool: .cursor)

        await cache.save(snapshot)
        let hydrated = await cache.load(tool: .cursor)
        XCTAssertNotNil(hydrated)

        await cache.remove(tool: .cursor)
        let removed = await cache.load(tool: .cursor)
        XCTAssertNil(removed)
    }
}
