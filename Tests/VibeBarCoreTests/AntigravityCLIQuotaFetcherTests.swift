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

    func testAgyErrorWinsWhenDesktopProbeIsAbsent() {
        XCTAssertEqual(
            AntigravityQuotaAdapter.preferredLocalSourceError(
                desktopError: .noCredential,
                cliError: .needsLogin
            ),
            .needsLogin
        )
        XCTAssertEqual(
            AntigravityQuotaAdapter.preferredLocalSourceError(
                desktopError: nil,
                cliError: .network("loopback unavailable")
            ),
            .network("loopback unavailable")
        )
    }

    func testSpecificDesktopErrorWinsOverAgyError() {
        XCTAssertEqual(
            AntigravityQuotaAdapter.preferredLocalSourceError(
                desktopError: .parseFailure("desktop response changed"),
                cliError: .needsLogin
            ),
            .parseFailure("desktop response changed")
        )
    }

    func testPartialDesktopAndAgyQuotasMergeWithoutLosingRicherLanes() {
        func bucket(_ id: String, used: Double) -> QuotaBucket {
            QuotaBucket(id: id, title: id, shortLabel: id, usedPercent: used)
        }
        let desktop = AccountQuota(
            accountId: "antigravity",
            tool: .antigravity,
            buckets: [
                bucket("gemini_five_hour", used: 10),
                bucket("gemini_weekly", used: 20),
                bucket("claude_gpt_weekly", used: 30)
            ],
            plan: "Desktop",
            queriedAt: Date(timeIntervalSince1970: 10)
        )
        let agy = AccountQuota(
            accountId: "antigravity",
            tool: .antigravity,
            buckets: [
                bucket("gemini_weekly", used: 99),
                bucket("claude_gpt_five_hour", used: 40)
            ],
            plan: "CLI",
            queriedAt: Date(timeIntervalSince1970: 20)
        )

        let merged = AntigravityQuotaAdapter.mergingPartialQuota(
            primary: desktop,
            fallback: agy
        )
        XCTAssertEqual(merged.buckets.map(\.id), [
            "gemini_five_hour",
            "gemini_weekly",
            "claude_gpt_five_hour",
            "claude_gpt_weekly"
        ])
        XCTAssertEqual(merged.bucket(id: "gemini_weekly")?.usedPercent, 20)
        XCTAssertEqual(merged.bucket(id: "claude_gpt_five_hour")?.usedPercent, 40)
        XCTAssertEqual(merged.plan, "Desktop")
        XCTAssertEqual(merged.queriedAt, Date(timeIntervalSince1970: 20))
    }
}
