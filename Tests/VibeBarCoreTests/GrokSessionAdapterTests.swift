import XCTest
@testable import VibeBarCore

final class GrokSessionAdapterTests: XCTestCase {
    private var home: URL!
    private let adapter = GrokSessionAdapter()
    private let sessionID = "019f8d56-e50c-7870-8c21-e7a5fb0b4193"
    /// `~/.grok/sessions/<percent-encoded cwd>/<session-id>/`.
    private let encodedCwd = "%2FUsers%2Fexample%2Fmy%20proj"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarGrokSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Fixtures

    @discardableResult
    private func writeSession(
        summaryJSON: String,
        chatHistory: [String]? = nil,
        directoryName: String? = nil,
        root: String = ".grok/sessions"
    ) throws -> URL {
        let sessionDir = home
            .appendingPathComponent(root, isDirectory: true)
            .appendingPathComponent(encodedCwd, isDirectory: true)
            .appendingPathComponent(directoryName ?? sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let summaryURL = sessionDir.appendingPathComponent("summary.json")
        try summaryJSON.write(to: summaryURL, atomically: true, encoding: .utf8)
        if let chatHistory {
            try (chatHistory.joined(separator: "\n") + "\n").write(
                to: sessionDir.appendingPathComponent("chat_history.jsonl"),
                atomically: true,
                encoding: .utf8
            )
        }
        return summaryURL
    }

    private func summaryJSON(id: String? = nil, title: String? = "Percent decoding") -> String {
        let titleField = title.map { "\"generated_title\":\(JSONFixture.string($0))," } ?? "\"generated_title\":null,"
        return """
        {"info":{"id":"\(id ?? sessionID)","cwd":"/Users/example/my proj"},\
        "session_summary":"Explored the percent-encoded session layout.",\
        "created_at":"2026-07-20T08:12:28.436699Z","updated_at":"2026-07-20T08:12:38.563679Z",\
        "last_active_at":"2026-07-20T08:12:38.563679Z","num_messages":10,"num_chat_messages":4,\
        "current_model_id":"grok-4","next_trace_turn":2,"chat_format_version":1,\
        \(titleField)"agent_name":"grok_composer_search","reasoning_effort":"high"}
        """
    }

    private var chatHistory: [String] {
        [
            "{\"type\":\"system\",\"content\":\"You are Grok.\"}",
            "{\"type\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]}",
            "{\"type\":\"reasoning\",\"id\":\"r1\",\"summary\":[],\"encrypted_content\":\"REDACTED\",\"status\":\"done\"}",
            "{\"type\":\"backend_tool_call\",\"kind\":{\"name\":\"search\"}}",
            "{\"type\":\"assistant\",\"content\":\"hi there\",\"tool_calls\":[],\"model_id\":\"grok-4\"}",
            "{\"type\":\"tool_result\",\"tool_call_id\":\"t1\",\"content\":\"tool output\"}"
        ]
    }

    // MARK: - Metadata

    func testMetadataDecodesTheEncodedProjectDirectory() throws {
        let url = try writeSession(summaryJSON: summaryJSON(), chatHistory: chatHistory)
        let summary = try adapter.extractMetadata(fileURL: url)

        XCTAssertEqual(summary.provider, .grok)
        XCTAssertEqual(summary.sessionID, sessionID)
        XCTAssertEqual(summary.projectDir, "/Users/example/my proj")
        XCTAssertEqual(summary.title, "Percent decoding")
        XCTAssertEqual(summary.summary, "Explored the percent-encoded session layout.")
        XCTAssertEqual(summary.messageCount, 4)
        XCTAssertGreaterThan(summary.sizeBytes, 0)
    }

    func testMicrosecondTimestampsAreParsed() throws {
        let url = try writeSession(summaryJSON: summaryJSON())
        let summary = try adapter.extractMetadata(fileURL: url)

        XCTAssertEqual(summary.createdAt,
                       ISO8601DateFormatter.vibeBarTest.date(from: "2026-07-20T08:12:28.436Z"))
        XCTAssertEqual(summary.lastActiveAt,
                       ISO8601DateFormatter.vibeBarTest.date(from: "2026-07-20T08:12:38.563Z"))
    }

    func testTitleFallsBackToTheSessionSummaryWhenUngenerated() throws {
        let url = try writeSession(summaryJSON: summaryJSON(title: nil))
        XCTAssertEqual(try adapter.extractMetadata(fileURL: url).title,
                       "Explored the percent-encoded session layout.")
    }

    func testDirectoryNameMustMatchTheSessionId() throws {
        let url = try writeSession(
            summaryJSON: summaryJSON(),
            directoryName: "019f8d56-e50c-7870-8c21-000000000000"
        )
        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: url)) { error in
            guard case SessionParseError.invalidFormat = error else {
                return XCTFail("expected invalidFormat, got \(error)")
            }
        }
        XCTAssertTrue(adapter.discoverSessions(homeDirectory: home.path).isEmpty)
    }

    func testSummaryWithoutAnIdIsRejected() throws {
        let url = try writeSession(summaryJSON: "{\"info\":{\"cwd\":\"/Users/example/proj\"}}")
        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: url))
    }

    // MARK: - Discovery

    func testDiscoveryFindsSummaryFilesInBothRoots() throws {
        let live = try writeSession(summaryJSON: summaryJSON(), chatHistory: chatHistory)
        let archived = try writeSession(
            summaryJSON: summaryJSON(id: "019f8d56-e50c-7870-8c21-e7a5fb0b4199"),
            directoryName: "019f8d56-e50c-7870-8c21-e7a5fb0b4199",
            root: ".grok/archived_sessions"
        )
        let found = Set(adapter.discoverSessionFiles(homeDirectory: home.path).map(SessionTestPaths.canonical))
        XCTAssertEqual(found, [SessionTestPaths.canonical(live), SessionTestPaths.canonical(archived)])
    }

    func testDiscoveryToleratesMissingDirectories() {
        XCTAssertTrue(adapter.discoverSessionFiles(homeDirectory: home.path).isEmpty)
    }

    // MARK: - Transcript

    func testTranscriptKeepsOnlyConversationRoles() throws {
        let url = try writeSession(summaryJSON: summaryJSON(), chatHistory: chatHistory)
        let document = try adapter.parseTranscript(fileURL: url, range: nil)

        XCTAssertEqual(document.messages.map(\.role), [.system, .user, .assistant, .tool])
        XCTAssertEqual(document.messages.map(\.text), ["You are Grok.", "hello", "hi there", "tool output"])
        XCTAssertEqual(document.totalMessageCount, 4)
    }

    func testTranscriptIsEmptyWhenTheChatHistoryIsAbsent() throws {
        let url = try writeSession(summaryJSON: summaryJSON())
        XCTAssertEqual(try adapter.parseTranscript(fileURL: url, range: nil), .empty)
    }

    // MARK: - Deletion plan

    func testDeletionPlanRemovesTheWholeSessionDirectory() throws {
        let url = try writeSession(summaryJSON: summaryJSON(), chatHistory: chatHistory)
        let summary = try adapter.extractMetadata(fileURL: url)
        let plan = try adapter.deletionPlan(for: summary, homeDirectory: home.path)

        XCTAssertEqual(plan.pathsToRemove, [url.deletingLastPathComponent().path])
        XCTAssertEqual(plan.validationSourcePath, url.path)
        XCTAssertEqual(plan.expectedSessionID, sessionID)
    }

    func testDeletionPlanRefusesADirectoryThatDoesNotMatchTheSessionId() throws {
        let url = try writeSession(summaryJSON: summaryJSON(), chatHistory: chatHistory)
        let stale = SessionSummary(
            provider: .grok,
            sessionID: "019f8d56-e50c-7870-8c21-000000000000",
            sourcePath: url.path
        )
        XCTAssertThrowsError(try adapter.deletionPlan(for: stale, homeDirectory: home.path))
    }
}
