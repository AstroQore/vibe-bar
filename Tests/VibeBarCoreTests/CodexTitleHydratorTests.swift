import SQLite3
import XCTest
@testable import VibeBarCore

/// Builds a minimal `threads` table with the columns Codex's real state
/// database exposes, so the hydrator's query is exercised against the
/// verified schema rather than a reduced stand-in.
enum CodexStateFixture {
    static func write(at url: URL, threads: [(id: String, title: String, cwd: String)]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close_v2(db) }

        let create = """
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            rollout_path TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            source TEXT NOT NULL,
            model_provider TEXT NOT NULL,
            cwd TEXT NOT NULL,
            title TEXT NOT NULL,
            sandbox_policy TEXT NOT NULL,
            approval_mode TEXT NOT NULL
        )
        """
        guard sqlite3_exec(db, create, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }

        for thread in threads {
            var statement: OpaquePointer?
            let insert = """
            INSERT INTO threads
            (id, rollout_path, created_at, updated_at, source, model_provider, cwd, title, sandbox_policy, approval_mode)
            VALUES (?, '', 0, 0, 'cli', 'openai', ?, ?, 'workspace-write', 'on-request')
            """
            guard sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, thread.id)
            bindText(statement, 2, thread.cwd)
            bindText(statement, 3, thread.title)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    private static func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, index, value, -1, transient)
    }
}

final class CodexTitleHydratorTests: XCTestCase {
    private var home: URL!
    private let sessionID = "019c2215-0f3c-7f72-89e3-92598c209589"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarCodexHydratorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func writeSessionIndex(_ lines: [String]) throws {
        let codex = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: codex.appendingPathComponent("session_index.jsonl"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func summary(id: String, title: String? = nil, projectDir: String? = nil) -> SessionSummary {
        SessionSummary(
            provider: .codex,
            sessionID: id,
            title: title,
            projectDir: projectDir,
            sourcePath: "/Users/example/.codex/sessions/rollout-\(id).jsonl"
        )
    }

    // MARK: - session_index.jsonl

    func testSessionIndexProvidesThreadNames() throws {
        try writeSessionIndex([
            "{\"id\":\"\(sessionID)\",\"thread_name\":\"Indexed title\",\"updated_at\":\"2026-04-26T19:14:35.000Z\"}"
        ])
        let hydrator = CodexTitleHydrator(homeDirectory: home.path)
        XCTAssertEqual(hydrator.thread(for: sessionID)?.title, "Indexed title")

        let hydrated = hydrator.hydrate([summary(id: sessionID)])
        XCTAssertEqual(hydrated.first?.title, "Indexed title")
    }

    func testSessionIndexEntriesWithoutANameAreIgnored() throws {
        try writeSessionIndex([
            "{\"id\":\"\(sessionID)\",\"updated_at\":\"2026-04-26T19:14:35.000Z\"}",
            "not json at all"
        ])
        XCTAssertNil(CodexTitleHydrator(homeDirectory: home.path).thread(for: sessionID))
    }

    // MARK: - state_<N>.sqlite

    func testStateDatabaseTitleAndCwd() throws {
        try CodexStateFixture.write(
            at: home.appendingPathComponent(".codex/sqlite/state_5.sqlite"),
            threads: [(id: sessionID, title: "Database title", cwd: "/Users/example/proj")]
        )
        let hydrator = CodexTitleHydrator(homeDirectory: home.path)
        let thread = hydrator.thread(for: sessionID)
        XCTAssertEqual(thread?.title, "Database title")
        XCTAssertEqual(thread?.cwd, "/Users/example/proj")

        // The rollout header wins for cwd when it had one; hydration
        // only fills the gap.
        let hydrated = hydrator.hydrate([summary(id: sessionID, projectDir: "/Users/example/from-header")])
        XCTAssertEqual(hydrated.first?.projectDir, "/Users/example/from-header")
        XCTAssertEqual(hydrator.hydrate([summary(id: sessionID)]).first?.projectDir, "/Users/example/proj")
    }

    func testStateDatabaseOverridesTheSessionIndex() throws {
        try writeSessionIndex([
            "{\"id\":\"\(sessionID)\",\"thread_name\":\"Indexed title\"}"
        ])
        try CodexStateFixture.write(
            at: home.appendingPathComponent(".codex/sqlite/state_5.sqlite"),
            threads: [(id: sessionID, title: "Database title", cwd: "/Users/example/proj")]
        )
        XCTAssertEqual(CodexTitleHydrator(homeDirectory: home.path).thread(for: sessionID)?.title,
                       "Database title")
    }

    func testHighestVersionedStateFileWins() throws {
        try CodexStateFixture.write(
            at: home.appendingPathComponent(".codex/sqlite/state_5.sqlite"),
            threads: [(id: sessionID, title: "Old schema title", cwd: "/Users/example/old")]
        )
        try CodexStateFixture.write(
            at: home.appendingPathComponent(".codex/sqlite/state_7.sqlite"),
            threads: [(id: sessionID, title: "Current title", cwd: "/Users/example/current")]
        )
        XCTAssertEqual(CodexTitleHydrator(homeDirectory: home.path).thread(for: sessionID)?.title,
                       "Current title")
    }

    func testSqliteSubdirectoryIsPreferredOverTheLegacyLocation() throws {
        try CodexStateFixture.write(
            at: home.appendingPathComponent(".codex/state_9.sqlite"),
            threads: [(id: sessionID, title: "Legacy title", cwd: "/Users/example/legacy")]
        )
        try CodexStateFixture.write(
            at: home.appendingPathComponent(".codex/sqlite/state_5.sqlite"),
            threads: [(id: sessionID, title: "Current title", cwd: "/Users/example/current")]
        )
        XCTAssertEqual(CodexTitleHydrator(homeDirectory: home.path).thread(for: sessionID)?.title,
                       "Current title")
    }

    func testLegacyLocationIsUsedWhenTheSubdirectoryHasNoDatabase() throws {
        try CodexStateFixture.write(
            at: home.appendingPathComponent(".codex/state_9.sqlite"),
            threads: [(id: sessionID, title: "Legacy title", cwd: "/Users/example/legacy")]
        )
        XCTAssertEqual(CodexTitleHydrator(homeDirectory: home.path).thread(for: sessionID)?.title,
                       "Legacy title")
    }

    func testStateFileVersionParsing() {
        XCTAssertEqual(CodexTitleHydrator.stateFileVersion("state_12.sqlite"), 12)
        XCTAssertNil(CodexTitleHydrator.stateFileVersion("state_.sqlite"))
        XCTAssertNil(CodexTitleHydrator.stateFileVersion("logs_2.sqlite"))
        XCTAssertNil(CodexTitleHydrator.stateFileVersion("state_5.sqlite-shm"))
    }

    // MARK: - Failure modes

    func testMissingSourcesYieldNoTitlesRatherThanAnError() {
        let hydrator = CodexTitleHydrator(homeDirectory: home.path)
        XCTAssertTrue(hydrator.threads().isEmpty)
        let input = [summary(id: sessionID, title: "Derived from prompt")]
        XCTAssertEqual(hydrator.hydrate(input).first?.title, "Derived from prompt")
    }

    func testCorruptDatabaseYieldsNoTitles() throws {
        let url = home.appendingPathComponent(".codex/sqlite/state_5.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("this is not a database".utf8).write(to: url)
        XCTAssertTrue(CodexTitleHydrator(homeDirectory: home.path).threads().isEmpty)
    }

    func testInvalidateForcesAReload() throws {
        let hydrator = CodexTitleHydrator(homeDirectory: home.path)
        XCTAssertNil(hydrator.thread(for: sessionID))

        try writeSessionIndex(["{\"id\":\"\(sessionID)\",\"thread_name\":\"Appeared later\"}"])
        XCTAssertNil(hydrator.thread(for: sessionID), "the first load should still be cached")

        hydrator.invalidate()
        XCTAssertEqual(hydrator.thread(for: sessionID)?.title, "Appeared later")
    }
}
