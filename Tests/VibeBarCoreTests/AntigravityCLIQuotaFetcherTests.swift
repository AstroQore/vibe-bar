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
        let desktop = AntigravityResponseParser.Snapshot(
            buckets: [
                bucket("gemini_five_hour", used: 10),
                bucket("gemini_weekly", used: 20),
                bucket("claude_gpt_weekly", used: 30)
            ],
            planName: "Desktop",
            email: nil,
            modelLabels: ["MODEL_PLACEHOLDER_M1": "Desktop label"]
        )
        let agy = AntigravityResponseParser.Snapshot(
            buckets: [
                bucket("gemini_weekly", used: 99),
                bucket("claude_gpt_five_hour", used: 40)
            ],
            planName: "CLI",
            email: "user@example.com",
            modelLabels: ["MODEL_PLACEHOLDER_M2": "CLI label"]
        )

        let merged = desktop.merging(agy)
        XCTAssertEqual(merged.buckets.map(\.id), [
            "gemini_five_hour",
            "gemini_weekly",
            "claude_gpt_five_hour",
            "claude_gpt_weekly"
        ])
        XCTAssertEqual(merged.buckets.first { $0.id == "gemini_weekly" }?.usedPercent, 20)
        XCTAssertEqual(merged.buckets.first { $0.id == "claude_gpt_five_hour" }?.usedPercent, 40)
        XCTAssertEqual(merged.planName, "Desktop")
        // The desktop summary carries no email, so the CLI's fills the gap.
        XCTAssertEqual(merged.email, "user@example.com")
        // Model labels are additive — neither source's catalog is discarded.
        XCTAssertEqual(merged.modelLabels, [
            "MODEL_PLACEHOLDER_M1": "Desktop label",
            "MODEL_PLACEHOLDER_M2": "CLI label"
        ])
    }
}
