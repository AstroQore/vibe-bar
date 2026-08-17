import XCTest
@testable import VibeBarCore

final class AntigravityCLIQuotaFetcherTests: XCTestCase {
    func testParsesOnlyExactAgyProcessNames() {
        let output = """
          101 /Users/example/.local/bin/agy
          102 /opt/homebrew/bin/antigravity-cli
          103 /usr/local/bin/antigravity_cli
          104 /Users/example/bin/agy-helper
          105 /Applications/Antigravity.app/Contents/MacOS/Antigravity
        """
        XCTAssertEqual(AntigravityCLIQuotaFetcher.parseAgyPIDs(output), [101, 102, 103])
    }

    func testResolvesExecutableFromOverrideBeforeKnownPaths() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebar-agy-binary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("agy")
        XCTAssertTrue(FileManager.default.createFile(atPath: binary.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: binary.path
        )

        XCTAssertEqual(
            AntigravityCLIQuotaFetcher.resolveBinary(
                environment: ["ANTIGRAVITY_CLI_PATH": binary.path, "PATH": ""],
                homeDirectory: directory.path
            ),
            binary.path
        )
    }

    func testCompleteSharedQuotaRequiresAllFourLanes() {
        func bucket(_ id: String) -> QuotaBucket {
            QuotaBucket(id: id, title: id, shortLabel: id, usedPercent: 0)
        }
        let complete = [
            bucket("gemini_five_hour"),
            bucket("gemini_weekly"),
            bucket("claude_gpt_five_hour"),
            bucket("claude_gpt_weekly")
        ]
        XCTAssertTrue(AntigravityQuotaAdapter.hasCompleteSharedQuota(complete))
        XCTAssertFalse(AntigravityQuotaAdapter.hasCompleteSharedQuota(
            complete.filter { $0.id != "claude_gpt_five_hour" }
        ))
    }
}
