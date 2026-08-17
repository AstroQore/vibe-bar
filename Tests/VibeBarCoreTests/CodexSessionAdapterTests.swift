import XCTest
@testable import VibeBarCore

final class CodexSessionAdapterTests: XCTestCase {
    private var home: URL!
    private let sessionID = "019c2215-0f3c-7f72-89e3-92598c209589"

    private var adapter: CodexSessionAdapter { CodexSessionAdapter(homeDirectory: home.path) }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarCodexSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Fixtures

    /// `~/.codex/sessions/<yyyy>/<MM>/<dd>/rollout-<stamp>-<uuid>.jsonl`.
    @discardableResult
    private func writeRollout(
        lines: [String],
        root: String = ".codex/sessions",
        fileID: String? = nil
    ) throws -> URL {
        let directory = home
            .appendingPathComponent(root, isDirectory: true)
            .appendingPathComponent("2026/02/03", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "rollout-2026-02-03T13-58-51-\(fileID ?? sessionID).jsonl"
        let url = directory.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func metaLine(id: String? = nil, originator: String? = "codex_cli_rs") -> String {
        let originatorField = originator.map { "\"originator\":\"\($0)\"," } ?? ""
        return """
        {"timestamp":"2026-02-03T05:58:51.452Z","type":"session_meta","payload":\
        {"id":"\(id ?? sessionID)","timestamp":"2026-02-03T05:58:51.452Z","cwd":"/Users/example/proj",\
        \(originatorField)"cli_version":"0.0.0","source":"cli","model_provider":"openai"}}
        """
    }

    private func turnContextLine(model: String) -> String {
        """
        {"timestamp":"2026-02-03T05:58:52.000Z","type":"turn_context","payload":\
        {"turn_id":"01a01124-c7c7-7b91-9774-94c735dae055","cwd":"/Users/example/proj",\
        "model":"\(model)","effort":"xhigh","summary":"auto"}}
        """
    }

    private func userMessageLine(_ text: String, timestamp: String = "2026-02-03T05:59:00.000Z") -> String {
        """
        {"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user",\
        "content":[{"type":"input_text","text":\(JSONFixture.string(text))}]}}
        """
    }

    private var rolloutLines: [String] {
        [
            metaLine(),
            userMessageLine("Add the session list"),
            """
            {"timestamp":"2026-02-03T05:59:05.000Z","type":"response_item","payload":{"type":"reasoning",\
            "summary":[],"encrypted_content":"REDACTED"}}
            """,
            """
            {"timestamp":"2026-02-03T05:59:06.000Z","type":"response_item","payload":{"type":"message",\
            "role":"assistant","content":[{"type":"output_text","text":"Working on it."}]}}
            """,
            """
            {"timestamp":"2026-02-03T05:59:07.000Z","type":"response_item","payload":{"type":"function_call",\
            "name":"shell","arguments":"{}","call_id":"call_1"}}
            """,
            """
            {"timestamp":"2026-02-03T05:59:08.000Z","type":"response_item","payload":\
            {"type":"function_call_output","call_id":"call_1","output":"exit 0"}}
            """,
            """
            {"timestamp":"2026-02-03T05:59:09.000Z","type":"event_msg","payload":{"type":"token_count",\
            "info":{"total_token_usage":{"input_tokens":10,"output_tokens":2}}}}
            """
        ]
    }

    // MARK: - Metadata

    func testMetadataComesFromTheSessionMetaHeader() throws {
        let url = try writeRollout(lines: rolloutLines)
        let summary = try adapter.extractMetadata(fileURL: url)

        XCTAssertEqual(summary.provider, .codex)
        XCTAssertEqual(summary.sessionID, sessionID)
        XCTAssertEqual(summary.projectDir, "/Users/example/proj")
        XCTAssertEqual(summary.title, "Add the session list")
        XCTAssertEqual(summary.createdAt,
                       ISO8601DateFormatter.vibeBarTest.date(from: "2026-02-03T05:58:51.452Z"))
        XCTAssertEqual(summary.lastActiveAt,
                       ISO8601DateFormatter.vibeBarTest.date(from: "2026-02-03T05:59:09.000Z"))
        XCTAssertEqual(summary.messageCount, rolloutLines.count)
    }

    // MARK: - Harness

    /// Every Codex surface writes into the same rollout tree, and exactly one
    /// `originator` is not Codex. Anything unrecognised — including a header
    /// with no originator at all — stays on Codex rather than being invented
    /// as ChatGPT Work usage.
    func testTheOriginatorDecidesCodexVersusChatGPTWork() throws {
        let cases: [(originator: String?, expected: Harness)] = [
            ("codex_work_desktop", .chatgptWork),
            ("Codex Desktop", .codex),
            ("codex-tui", .codex),
            ("codex_cli_rs", .codex),
            ("codex_exec", .codex),
            ("codex_vscode", .codex),
            ("something_new", .codex),
            (nil, .codex)
        ]
        for (originator, expected) in cases {
            let url = try writeRollout(lines: [
                metaLine(originator: originator),
                userMessageLine("Hello")
            ])
            XCTAssertEqual(
                try adapter.extractMetadata(fileURL: url).harness,
                expected,
                "originator \(originator ?? "<absent>")"
            )
        }
    }

    /// The session list and the cost ledger must agree about which rollout is
    /// ChatGPT Work, so both go through the one mapping.
    func testTheHarnessMappingIsTheCostScannersOwn() {
        for originator in ["codex_work_desktop", "Codex Desktop", nil] {
            XCTAssertEqual(
                CostUsageScanner.codexHarness(originator: originator),
                originator == CostUsageScanner.chatgptWorkOriginator ? .chatgptWork : .codex
            )
        }
    }

    // MARK: - Model

    func testTheModelComesFromTheTurnContext() throws {
        let url = try writeRollout(lines: [
            metaLine(),
            turnContextLine(model: "gpt-daybreak-blue-latest"),
            userMessageLine("Hello")
        ])
        XCTAssertEqual(try adapter.extractMetadata(fileURL: url).model, "gpt-daybreak-blue-latest")
    }

    /// Older rollouts stamped the model inside the token-count event instead.
    func testTheModelFallsBackToTheTokenCountInfo() throws {
        let url = try writeRollout(lines: [
            metaLine(),
            userMessageLine("Hello"),
            """
            {"timestamp":"2026-02-03T05:59:09.000Z","type":"event_msg","payload":{"type":"token_count",\
            "info":{"model":"gpt-5-codex","total_token_usage":{"input_tokens":10,"output_tokens":2}}}}
            """
        ])
        XCTAssertEqual(try adapter.extractMetadata(fileURL: url).model, "gpt-5-codex")
    }

    func testARolloutThatNamesNoModelKeepsItNil() throws {
        let url = try writeRollout(lines: [metaLine(), userMessageLine("Hello")])
        XCTAssertNil(try adapter.extractMetadata(fileURL: url).model)
    }

    func testFilenameAndHeaderIdMismatchIsRejected() throws {
        let url = try writeRollout(
            lines: rolloutLines,
            fileID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: url)) { error in
            guard case SessionParseError.invalidFormat = error else {
                return XCTFail("expected invalidFormat, got \(error)")
            }
        }
        // A rejected file also drops out of the summarized sweep instead
        // of failing the whole discovery pass.
        XCTAssertTrue(adapter.discoverSessions(homeDirectory: home.path).isEmpty)
        XCTAssertEqual(adapter.discoverSessionFiles(homeDirectory: home.path).count, 1)
    }

    func testFilenameUUIDIsUsedWhenTheHeaderHasNoId() throws {
        let url = try writeRollout(lines: [
            "{\"timestamp\":\"2026-02-03T05:58:51.452Z\",\"type\":\"session_meta\",\"payload\":{\"cwd\":\"/Users/example/proj\"}}",
            userMessageLine("Hello")
        ])
        XCTAssertEqual(try adapter.extractMetadata(fileURL: url).sessionID, sessionID)
    }

    func testIDEContextEnvelopeIsStrippedFromTheDerivedTitle() throws {
        let prompt = """
        # Context from my IDE setup:
        The user is working in VS Code. Open file: Sources/Thing.swift
        Selected text: struct Thing {}

        ## My request for Codex:
        Rename Thing to Widget
        """
        let url = try writeRollout(lines: [metaLine(), userMessageLine(prompt)])
        let summary = try adapter.extractMetadata(fileURL: url)

        XCTAssertEqual(summary.title, "Rename Thing to Widget")
        XCTAssertEqual(summary.summary, "Rename Thing to Widget")
    }

    func testPromptWithoutTheEnvelopeIsLeftAlone() {
        XCTAssertEqual(CodexSessionAdapter.strippingIDEEnvelope("## My request for Codex: inline"),
                       "## My request for Codex: inline")
    }

    func testArchivedSessionsAreDiscovered() throws {
        let live = try writeRollout(lines: rolloutLines)
        let archived = try writeRollout(
            lines: [metaLine(id: "019c2215-0f3c-7f72-89e3-92598c209590"), userMessageLine("Archived")],
            root: ".codex/archived_sessions",
            fileID: "019c2215-0f3c-7f72-89e3-92598c209590"
        )
        let found = Set(adapter.discoverSessionFiles(homeDirectory: home.path).map(SessionTestPaths.canonical))
        XCTAssertEqual(found, [SessionTestPaths.canonical(live), SessionTestPaths.canonical(archived)])
        XCTAssertEqual(adapter.roots(homeDirectory: home.path).count, 2)
    }

    func testDiscoveryToleratesMissingDirectories() {
        XCTAssertTrue(adapter.discoverSessionFiles(homeDirectory: home.path).isEmpty)
    }

    func testTrailingUUIDParsing() {
        XCTAssertEqual(
            CodexSessionAdapter.trailingUUID(in: "rollout-2026-02-03T13-58-51-\(sessionID)"),
            sessionID
        )
        XCTAssertNil(CodexSessionAdapter.trailingUUID(in: "rollout-2026-02-03T13-58-51"))
        XCTAssertNil(CodexSessionAdapter.trailingUUID(in: "rollout-not-a-uuid-here-at-all-zzzzzzzzzzzz"))
    }

    // MARK: - Transcript

    func testTranscriptKeepsOnlyResponseItems() throws {
        let url = try writeRollout(lines: rolloutLines)
        let document = try adapter.parseTranscript(fileURL: url, range: nil)

        XCTAssertEqual(document.messages.map(\.role), [.user, .assistant, .assistant, .tool])
        XCTAssertEqual(document.messages.map(\.text), [
            "Add the session list",
            "Working on it.",
            "[Tool: shell]",
            "exit 0"
        ])
        XCTAssertEqual(document.totalMessageCount, 4)
        XCTAssertFalse(document.truncated)
    }

    func testTranscriptHonorsARange() throws {
        let url = try writeRollout(lines: rolloutLines)
        let document = try adapter.parseTranscript(fileURL: url, range: 0..<2)
        XCTAssertEqual(document.messages.map(\.text), ["Add the session list", "Working on it."])
        XCTAssertTrue(document.truncated)
        XCTAssertEqual(document.totalMessageCount, 4)
    }

    // MARK: - Deletion plan

    func testDeletionPlanIsTheRolloutFileAlone() throws {
        let url = try writeRollout(lines: rolloutLines)
        let summary = try adapter.extractMetadata(fileURL: url)
        let plan = try adapter.deletionPlan(for: summary, homeDirectory: home.path)

        XCTAssertEqual(plan.pathsToRemove, [url.path])
        XCTAssertEqual(plan.validationSourcePath, url.path)
        XCTAssertEqual(plan.expectedSessionID, sessionID)
    }

    // MARK: - Hydration wiring

    func testTitleFromTheStateDatabaseOverridesTheFirstPrompt() throws {
        let url = try writeRollout(lines: rolloutLines)
        try CodexStateFixture.write(
            at: home.appendingPathComponent(".codex/sqlite/state_5.sqlite"),
            threads: [(id: sessionID, title: "Session manager work", cwd: "/Users/example/other")]
        )
        XCTAssertEqual(try adapter.extractMetadata(fileURL: url).title, "Session manager work")
    }
}

enum JSONFixture {
    /// JSON-encode a Swift string, quotes included, so fixture literals
    /// can embed newlines and punctuation safely.
    static func string(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [])
        var text = String(decoding: data, as: UTF8.self)
        text.removeFirst()
        text.removeLast()
        return text
    }
}
