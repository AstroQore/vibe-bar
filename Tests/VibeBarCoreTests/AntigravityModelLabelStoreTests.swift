import XCTest
@testable import VibeBarCore

final class AntigravityModelLabelStoreTests: XCTestCase {
    private func tempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarLabelStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testEmptyStoreResolvesToRawId() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = AntigravityModelLabelStore.load(homeDirectory: home.path)
        XCTAssertEqual(store.resolve("MODEL_PLACEHOLDER_M132"), "MODEL_PLACEHOLDER_M132")
    }

    func testMergePersistsAndDropsEmpties() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        AntigravityModelLabelStore.merge([
            "MODEL_PLACEHOLDER_M132": "Gemini 3.5 Flash (High)",
            "   ": "ignored-empty-key",
            "MODEL_EMPTY": "   "
        ], homeDirectory: home.path)

        let store = AntigravityModelLabelStore.load(homeDirectory: home.path)
        XCTAssertEqual(store.labels.count, 1)
        XCTAssertEqual(store.resolve("MODEL_PLACEHOLDER_M132"), "Gemini 3.5 Flash (High)")
        XCTAssertEqual(store.resolve("MODEL_EMPTY"), "MODEL_EMPTY")
    }

    func testMergeAccumulatesAcrossCalls() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        AntigravityModelLabelStore.merge(["MODEL_PLACEHOLDER_M132": "Gemini 3.5 Flash (High)"], homeDirectory: home.path)
        AntigravityModelLabelStore.merge(["MODEL_PLACEHOLDER_M20": "Gemini 3.5 Flash (Medium)"], homeDirectory: home.path)

        let store = AntigravityModelLabelStore.load(homeDirectory: home.path)
        XCTAssertEqual(store.labels.count, 2)
        XCTAssertEqual(store.resolve("MODEL_PLACEHOLDER_M132"), "Gemini 3.5 Flash (High)")
        XCTAssertEqual(store.resolve("MODEL_PLACEHOLDER_M20"), "Gemini 3.5 Flash (Medium)")
    }
}
