import XCTest
@testable import VibeBarCore

final class AntigravityCLIQuotaFetcherTests: XCTestCase {
    func testPrintModeUsagePreservesGroupAndResetState() throws {
        let output = """
        {"conversation_id":"","status":"SUCCESS","response":"text","num_turns":0,
         "command":{"name":"usage","data":{"description":"d","groups":[
          {"name":"Gemini Models","buckets":[
            {"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly",
             "remaining_fraction":0.7525,"reset_time":"2026-11-30T20:05:33Z"},
            {"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h",
             "remaining_fraction":0.825,"reset_time":"2026-11-26T08:05:33Z"}]},
          {"name":"Claude and GPT models","buckets":[
            {"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly",
             "remaining_fraction":1,"reset_time":"1970-01-01T00:00:00Z"},
            {"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h",
             "remaining_fraction":1,"reset_time":"1970-01-01T00:00:00Z"},
            {"id":"3p-monthly","name":"Unknown","window":"monthly","remaining_fraction":0.5}]}]}}}
        """
        let snapshot = try AntigravityResponseParser.parseCLIUsage(data: Data(output.utf8))
        XCTAssertEqual(snapshot.buckets.map(\.id), ["gemini_five_hour", "gemini_weekly", "claude_gpt_five_hour", "claude_gpt_weekly"])
        XCTAssertEqual(snapshot.buckets[0].usedPercent, 17.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.buckets[1].usedPercent, 24.75, accuracy: 0.001)
        XCTAssertEqual(snapshot.buckets[1].resetAt, ISO8601DateFormatter().date(from: "2026-11-30T20:05:33Z"))
        XCTAssertNil(snapshot.buckets[2].resetAt)
        XCTAssertNil(snapshot.buckets[3].resetAt)
    }

    func testPrintModeUsageSurfacesFailureInsteadOfEmptyQuota() {
        XCTAssertThrowsError(try AntigravityResponseParser.parseCLIUsage(
            data: Data(#"{"status":"ERROR","error":"You are not signed in."}"#.utf8)
        )) { XCTAssertEqual($0 as? QuotaError, .needsLogin) }
        XCTAssertThrowsError(try AntigravityResponseParser.parseCLIUsage(data: Data("Welcome".utf8))) {
            guard case .parseFailure = $0 as? QuotaError else { return XCTFail("\($0)") }
        }
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

    func testAgyErrorWinsWhenDesktopKeepsItsTokenPrivate() {
        let hidden = AntigravityLanguageServerClient.tokenUnavailableError
        XCTAssertEqual(
            AntigravityQuotaAdapter.preferredLocalSourceError(desktopError: hidden, cliError: .needsLogin),
            .needsLogin
        )
        // With no CLI installed the desktop hint is the actionable one.
        XCTAssertEqual(
            AntigravityQuotaAdapter.preferredLocalSourceError(desktopError: hidden, cliError: .noCredential),
            hidden
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
