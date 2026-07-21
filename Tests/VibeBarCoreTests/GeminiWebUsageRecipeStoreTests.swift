import XCTest
@testable import VibeBarCore

final class GeminiWebUsageRecipeStoreTests: XCTestCase {
    func testMissingRecipeFallsBackToKnownContract() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("recipe.json")

        XCTAssertEqual(GeminiWebUsageRecipeStore.load(from: url), .fallback)
        XCTAssertEqual(GeminiWebUsageRecipe.fallback.rpcID, "jSf9Qc")
        XCTAssertEqual(GeminiWebUsageRecipe.fallback.argument, "[]")
    }

    func testRecipeRoundTripsWithoutSessionData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recipe.json")
        let recipe = GeminiWebUsageRecipe(
            rpcID: "rotatedQuotaRPC",
            argument: #"[["dynamic-argument"]]"#,
            learnedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try GeminiWebUsageRecipeStore.save(recipe, to: url)

        XCTAssertEqual(GeminiWebUsageRecipeStore.load(from: url), recipe)
        let persisted = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(persisted.contains("Cookie"))
        XCTAssertFalse(persisted.contains("SNlM0e"))
    }

    func testInvalidRecipeIsRejectedAndNeverLoaded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recipe.json")
        let invalid = GeminiWebUsageRecipe(rpcID: "bad rpc id", argument: "[]")

        XCTAssertThrowsError(try GeminiWebUsageRecipeStore.save(invalid, to: url))
        XCTAssertEqual(GeminiWebUsageRecipeStore.load(from: url), .fallback)
    }
}
