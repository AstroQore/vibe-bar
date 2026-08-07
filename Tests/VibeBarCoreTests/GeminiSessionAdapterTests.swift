import XCTest
@testable import VibeBarCore

final class GeminiSessionAdapterTests: XCTestCase {
    private var home: URL!
    private let adapter = GeminiSessionAdapter()
    private let sessionID = "0419e82e-1111-2222-3333-444444444444"
    private let projectHash = "db00f90b6e57cb295021b9fe8eccb6657256d9cbac4b7c8f4a1422327b18cd39"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarGeminiSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Fixtures

    /// `~/.gemini/tmp/<hash>/chats/session-<stamp>.json`, plus the
    /// sibling `.project_root` marker the CLI writes next to `chats/`.
    @discardableResult
    private func writeSession(
        json: String,
        hash: String? = nil,
        projectRoot: String? = "/Users/example/proj",
        fileName: String = "session-2026-01-01T00-00-0419e82e.json"
    ) throws -> URL {
        let projectDir = home
            .appendingPathComponent(".gemini/tmp", isDirectory: true)
            .appendingPathComponent(hash ?? projectHash, isDirectory: true)
        let chats = projectDir.appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        if let projectRoot {
            try projectRoot.write(
                to: projectDir.appendingPathComponent(".project_root"),
                atomically: true,
                encoding: .utf8
            )
        }
        let url = chats.appendingPathComponent(fileName)
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private var sessionJSON: String {
        """
        {"sessionId":"\(sessionID)","projectHash":"\(projectHash)",\
        "startTime":"2026-01-01T00:00:00.000Z","lastUpdated":"2026-01-01T00:05:00.000Z","messages":[\
        {"id":"9f95a7de-1111-2222-3333-444444444444","timestamp":"2026-01-01T00:00:10.000Z",\
        "type":"user","content":"Summarize the repo"},\
        {"id":"17e0c0ce-1111-2222-3333-444444444444","timestamp":"2026-01-01T00:00:20.000Z",\
        "type":"gemini","content":"Here is the summary.","toolCalls":[],"thoughts":[],\
        "model":"gemini-3-pro","tokens":{"input":120,"output":45}},\
        {"id":"27e0c0ce-1111-2222-3333-444444444444","timestamp":"2026-01-01T00:00:30.000Z",\
        "type":"gemini","content":""}]}
        """
    }

    // MARK: - Metadata

    func testProjectRootMarkerResolvesTheProjectDirectory() throws {
        let url = try writeSession(json: sessionJSON)
        let summary = try adapter.extractMetadata(fileURL: url)

        XCTAssertEqual(summary.provider, .gemini)
        XCTAssertEqual(summary.sessionID, sessionID)
        XCTAssertEqual(summary.projectDir, "/Users/example/proj")
        XCTAssertEqual(summary.title, "Summarize the repo")
        XCTAssertEqual(summary.summary, "Here is the summary.")
        XCTAssertEqual(summary.messageCount, 3)
        XCTAssertEqual(summary.createdAt,
                       ISO8601DateFormatter.vibeBarTest.date(from: "2026-01-01T00:00:00.000Z"))
        XCTAssertEqual(summary.lastActiveAt,
                       ISO8601DateFormatter.vibeBarTest.date(from: "2026-01-01T00:05:00.000Z"))
    }

    func testProjectDirectoryIsNilWithoutTheMarker() throws {
        let url = try writeSession(json: sessionJSON, projectRoot: nil)
        XCTAssertNil(try adapter.extractMetadata(fileURL: url).projectDir)
    }

    func testTimestampsFallBackToTheMessagesWhenTheHeaderHasNone() throws {
        let url = try writeSession(json: """
        {"sessionId":"\(sessionID)","messages":[\
        {"timestamp":"2026-02-02T10:00:00.000Z","type":"user","content":"first"},\
        {"timestamp":"2026-02-02T11:00:00.000Z","type":"gemini","content":"second"}]}
        """)
        let summary = try adapter.extractMetadata(fileURL: url)
        XCTAssertEqual(summary.createdAt,
                       ISO8601DateFormatter.vibeBarTest.date(from: "2026-02-02T10:00:00.000Z"))
        XCTAssertEqual(summary.lastActiveAt,
                       ISO8601DateFormatter.vibeBarTest.date(from: "2026-02-02T11:00:00.000Z"))
    }

    func testSessionIdFallsBackToTheFilename() throws {
        let url = try writeSession(json: "{\"messages\":[]}")
        XCTAssertEqual(try adapter.extractMetadata(fileURL: url).sessionID,
                       "session-2026-01-01T00-00-0419e82e")
    }

    func testUnreadableFileThrows() throws {
        let url = try writeSession(json: "not json")
        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: url))
    }

    // MARK: - Discovery

    func testDiscoveryWalksEveryProjectHash() throws {
        let first = try writeSession(json: sessionJSON)
        let second = try writeSession(
            json: sessionJSON,
            hash: "aa00f90b6e57cb295021b9fe8eccb6657256d9cbac4b7c8f4a1422327b18cd39",
            projectRoot: "/Users/example/other",
            fileName: "session-2026-01-02T00-00-1119e82e.json"
        )
        let found = Set(adapter.discoverSessionFiles(homeDirectory: home.path).map(SessionTestPaths.canonical))
        XCTAssertEqual(found, [SessionTestPaths.canonical(first), SessionTestPaths.canonical(second)])
    }

    func testDiscoveryIgnoresNonSessionFiles() throws {
        try writeSession(json: sessionJSON)
        let chats = home
            .appendingPathComponent(".gemini/tmp", isDirectory: true)
            .appendingPathComponent(projectHash, isDirectory: true)
            .appendingPathComponent("chats", isDirectory: true)
        try "{}".write(to: chats.appendingPathComponent("checkpoint.json"),
                       atomically: true, encoding: .utf8)

        XCTAssertEqual(adapter.discoverSessionFiles(homeDirectory: home.path).count, 1)
    }

    func testDiscoveryToleratesMissingDirectories() {
        XCTAssertTrue(adapter.discoverSessionFiles(homeDirectory: home.path).isEmpty)
        XCTAssertEqual(adapter.roots(homeDirectory: home.path).count, 1)
    }

    // MARK: - Transcript

    func testTranscriptMapsGeminiTurnsToTheAssistantRole() throws {
        let url = try writeSession(json: sessionJSON)
        let document = try adapter.parseTranscript(fileURL: url, range: nil)

        XCTAssertEqual(document.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(document.messages.map(\.text), ["Summarize the repo", "Here is the summary."])
        XCTAssertEqual(document.totalMessageCount, 2)
    }

    func testTranscriptHonorsARange() throws {
        let url = try writeSession(json: sessionJSON)
        let document = try adapter.parseTranscript(fileURL: url, range: 1..<2)
        XCTAssertEqual(document.messages.map(\.text), ["Here is the summary."])
        XCTAssertTrue(document.truncated)
    }

    // MARK: - Deletion plan

    func testDeletionPlanIsTheSessionFileAlone() throws {
        let url = try writeSession(json: sessionJSON)
        let summary = try adapter.extractMetadata(fileURL: url)
        let plan = try adapter.deletionPlan(for: summary, homeDirectory: home.path)

        XCTAssertEqual(plan.pathsToRemove, [url.path])
        XCTAssertEqual(plan.expectedSessionID, sessionID)
    }
}
