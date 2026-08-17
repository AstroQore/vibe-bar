import XCTest
@testable import VibeBarCore

final class ClaudeCoworkSessionAdapterTests: XCTestCase {
    private var home: URL!
    private let sessionID = "35ffa07a-9f0b-4e96-b18f-c9960a220785"
    private let space = "4fb4807b-947a-44da-9376-0a7f1702c804"
    private let run = "db026688-9ca4-4a3a-a982-3669e92dbc9c"
    private let workspace = "f9866219-e87d-416d-b244-70f88e17873d"

    private let adapter = ClaudeCoworkSessionAdapter()

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarCoworkSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Fixtures

    /// `~/Library/Application Support/Claude/local-agent-mode-sessions/
    ///   <space>/<run>/local_<uuid>/.claude/projects/<encoded-cwd>/<uuid>.jsonl`
    private func projectDirectory(workspace: String? = nil) -> URL {
        CostUsageScanner.claudeCoworkRoot(homeDirectory: home.path)
            .appendingPathComponent(space, isDirectory: true)
            .appendingPathComponent(run, isDirectory: true)
            .appendingPathComponent("local_\(workspace ?? self.workspace)", isDirectory: true)
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent("-Users-example-proj", isDirectory: true)
    }

    @discardableResult
    private func writeSession(
        id: String? = nil,
        workspace: String? = nil,
        lines: [String]? = nil
    ) throws -> URL {
        let id = id ?? sessionID
        let directory = projectDirectory(workspace: workspace)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(id).jsonl")
        try ((lines ?? transcriptLines(id: id)).joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func transcriptLines(id: String) -> [String] {
        [
            """
            {"type":"user","timestamp":"2026-05-02T09:00:00.000Z","sessionId":"\(id)",\
            "cwd":"/Users/example/proj","message":{"role":"user","content":"Summarize the deck"}}
            """,
            """
            {"type":"assistant","timestamp":"2026-05-02T09:00:12.000Z","sessionId":"\(id)",\
            "cwd":"/Users/example/proj","message":{"role":"assistant","model":"claude-fable-5",\
            "content":[{"type":"text","text":"Here is the summary."}],\
            "usage":{"input_tokens":10,"output_tokens":4}}}
            """
        ]
    }

    // MARK: - Discovery

    func testTranscriptsUnderTheCoworkRootAreDiscovered() throws {
        let first = try writeSession()
        let second = try writeSession(
            id: "29962512-5e85-474c-9222-f7980d65f053",
            workspace: "8bd57877-c885-442d-85d9-ab51ac019c62"
        )
        let found = Set(adapter.discoverSessionFiles(homeDirectory: home.path).map(SessionTestPaths.canonical))
        XCTAssertEqual(found, [SessionTestPaths.canonical(first), SessionTestPaths.canonical(second)])
    }

    /// The single root is also the containment fence a deleter would check,
    /// so it must be the Cowork tree and nothing broader.
    func testTheOnlyRootIsClaudeAppsCoworkTree() {
        XCTAssertEqual(
            adapter.roots(homeDirectory: home.path),
            [CostUsageScanner.claudeCoworkRoot(homeDirectory: home.path)]
        )
    }

    func testDiscoveryToleratesAMissingRoot() {
        XCTAssertTrue(adapter.discoverSessionFiles(homeDirectory: home.path).isEmpty)
    }

    /// Cowork buries its transcripts under a *hidden* `.claude` directory, so
    /// a sweep that skipped hidden entries would silently find nothing.
    func testTheHiddenClaudeDirectoryIsNotSkipped() throws {
        try writeSession()
        XCTAssertEqual(adapter.discoverSessionFiles(homeDirectory: home.path).count, 1)
    }

    /// A JSONL that is inside the workspace but not under `.claude/projects`
    /// is some other file the app keeps there, not a transcript.
    func testFilesOutsideTheProjectsDirectoryAreIgnored() throws {
        try writeSession()
        let stray = CostUsageScanner.claudeCoworkRoot(homeDirectory: home.path)
            .appendingPathComponent(space, isDirectory: true)
            .appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try "{}\n".write(to: stray.appendingPathComponent("notes.jsonl"),
                         atomically: true, encoding: .utf8)

        XCTAssertEqual(adapter.discoverSessionFiles(homeDirectory: home.path).count, 1)
    }

    /// The Cowork sweep and the cost scanner's must stay the same set, or a
    /// transcript could be billed and yet be missing from the session list.
    func testTheSweepMatchesTheCostScannersOwn() throws {
        try writeSession()
        let scanned = CostUsageScanner.collectClaudeCoworkJSONL(
            under: CostUsageScanner.claudeCoworkRoot(homeDirectory: home.path)
        )
        XCTAssertEqual(
            Set(adapter.discoverSessionFiles(homeDirectory: home.path).map(SessionTestPaths.canonical)),
            Set(scanned.map(SessionTestPaths.canonical))
        )
    }

    // MARK: - Metadata

    func testMetadataUsesClaudeCodesParserWithTheCoworkHarness() throws {
        let url = try writeSession()
        let summary = try adapter.extractMetadata(fileURL: url)

        XCTAssertEqual(summary.provider, .claudeCowork)
        XCTAssertEqual(summary.harness, .claudeCowork)
        XCTAssertEqual(summary.sessionID, sessionID)
        XCTAssertEqual(summary.projectDir, "/Users/example/proj")
        XCTAssertEqual(summary.title, "Summarize the deck")
        XCTAssertEqual(summary.model, "claude-fable-5")
        XCTAssertEqual(summary.createdAt,
                       ISO8601DateFormatter.vibeBarTest.date(from: "2026-05-02T09:00:00.000Z"))
        XCTAssertEqual(summary.lastActiveAt,
                       ISO8601DateFormatter.vibeBarTest.date(from: "2026-05-02T09:00:12.000Z"))
        XCTAssertEqual(summary.messageCount, 2)
    }

    /// Same bytes, same answers — only the provider, the harness, and the
    /// delete verdict differ between the two Claude adapters.
    func testTheTwoClaudeAdaptersAgreeOnEverythingButProvenance() throws {
        let url = try writeSession()
        let cowork = try adapter.extractMetadata(fileURL: url)
        let code = try ClaudeSessionAdapter().extractMetadata(fileURL: url)

        XCTAssertEqual(cowork.sessionID, code.sessionID)
        XCTAssertEqual(cowork.title, code.title)
        XCTAssertEqual(cowork.model, code.model)
        XCTAssertEqual(cowork.projectDir, code.projectDir)
        XCTAssertEqual(code.harness, .claudeCode)
        XCTAssertNotEqual(cowork.harness, code.harness)
    }

    func testTranscriptIsParsedLikeClaudeCode() throws {
        let document = try adapter.parseTranscript(fileURL: try writeSession(), range: nil)
        XCTAssertEqual(document.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(document.messages.map(\.text), ["Summarize the deck", "Here is the summary."])
    }

    // MARK: - Deletion

    func testDeletionIsRefusedBecauseTheFilesAreInsideClaudeAppsContainer() throws {
        let url = try writeSession()
        let summary = try adapter.extractMetadata(fileURL: url)
        XCTAssertThrowsError(try adapter.deletionPlan(for: summary, homeDirectory: home.path)) { error in
            XCTAssertEqual(error as? SessionDeleteError, .providerIsReadOnly(.claudeCowork))
        }

        let outcomes = SessionDeleter(homeDirectory: home.path).delete(
            [summary], registry: .standard(homeDirectory: home.path)
        )
        XCTAssertEqual(outcomes.first?.success, false)
        XCTAssertEqual(
            outcomes.first?.failureReason?.message,
            "Cowork sessions live inside Claude.app's container and are never removed by Vibe Bar."
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Resume

    func testCoworkSessionsHaveNoResumeCommand() {
        XCTAssertThrowsError(
            try SessionResumeCommandBuilder.command(provider: .claudeCowork, sessionID: sessionID)
        ) { error in
            XCTAssertEqual(error as? SessionResumeError, .resumeUnavailable)
        }
    }
}
