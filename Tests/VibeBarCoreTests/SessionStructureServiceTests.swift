import SQLite3
import XCTest
@testable import VibeBarCore

final class SessionStructureServiceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try SessionStructureFixtures.temporaryDirectory("service")
    }

    override func tearDownWithError() throws {
        // Restore permissions a test may have removed so cleanup succeeds.
        if let enumerator = FileManager.default.enumerator(atPath: directory.path) {
            for case let item as String in enumerator {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.appendingPathComponent(item).path)
            }
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private var storeURL: URL { directory.appendingPathComponent("session_structure.sqlite3") }

    private func rollout(id: String, turns: Int, model: String = "gpt-5", tokens: Bool = true) throws -> SessionSummary {
        let builder = CodexRolloutBuilder().meta(id: id)
        for index in 0..<turns {
            builder.taskStarted("t\(index)")
                .turnContext(model: model)
                .prompt("Question \(index)", turnID: "t\(index)")
                .functionCall("exec_command", callID: "c\(index)", arguments: ["cmd": "echo \(index)"])
                .stringOutput(callID: "c\(index)", text: "Exit code: 0\nWall time: 0.1 seconds\nOutput:\n\(index)\n")
            if tokens { builder.tokenCount(input: 100, cached: 40, output: 10) }
            builder.assistant("Answer \(index)").taskComplete("t\(index)")
        }
        let url = try SessionStructureFixtures.write(
            builder.lines,
            to: directory.appendingPathComponent("sessions/rollout-2026-05-01T10-00-00-\(id).jsonl")
        )
        return summary(.codex, id: id, url: url)
    }

    private func summary(_ provider: SessionProvider, id: String, url: URL, lastActive: TimeInterval = 0) -> SessionSummary {
        let size = SessionFileFingerprint.of(path: url.path)?.size ?? 0
        return SessionSummary(provider: provider, sessionID: id, lastActiveAt: Date(timeIntervalSince1970: 1_700_000_000 + lastActive),
                              sourcePath: url.path, sizeBytes: size)
    }

    private func threadID(_ n: Int) -> String {
        String(format: "0190bbbb-0000-7000-8000-%012d", n)
    }

    // MARK: - Store

    func testStoreRoundTripsAndInvalidatesOnFingerprintChange() async throws {
        let session = try rollout(id: threadID(1), turns: 2)
        let structure = try XCTUnwrap(CodexSessionStructureParser.parse(fileURL: URL(fileURLWithPath: session.sourcePath)))
        let fingerprint = try XCTUnwrap(SessionFileFingerprint.of(path: session.sourcePath))
        let store = SessionStructureStore(url: storeURL)
        await store.upsert(SessionStructureRecord(structure: structure, fingerprint: fingerprint))

        let hit = await store.record(forPath: session.sourcePath, fingerprint: fingerprint)
        XCTAssertEqual(hit?.stats, structure.stats)
        XCTAssertEqual(hit?.outline, structure.outline)
        XCTAssertEqual(hit?.kind, .interactive)
        XCTAssertTrue(hit?.outline.allSatisfy { ($0.promptPreview?.count ?? 0) <= 120 } ?? false)

        var touched = fingerprint
        touched.mtimeNs += 1
        let afterMTime = await store.record(forPath: session.sourcePath, fingerprint: touched)
        XCTAssertNil(afterMTime)
        var grown = fingerprint
        grown.size += 1
        let afterSize = await store.record(forPath: session.sourcePath, fingerprint: grown)
        XCTAssertNil(afterSize)
        let count = await store.count()
        XCTAssertEqual(count, 1)
    }

    func testStoreDropsRowsWrittenByAnotherParserVersion() async throws {
        let session = try rollout(id: threadID(2), turns: 1)
        let structure = try XCTUnwrap(CodexSessionStructureParser.parse(fileURL: URL(fileURLWithPath: session.sourcePath)))
        let fingerprint = try XCTUnwrap(SessionFileFingerprint.of(path: session.sourcePath))
        let old = SessionStructureStore(url: storeURL, parserVersion: 1)
        await old.upsert(SessionStructureRecord(structure: structure, fingerprint: fingerprint, parserVersion: 1))
        let oldCount = await old.count()
        XCTAssertEqual(oldCount, 1)

        let upgraded = SessionStructureStore(url: storeURL, parserVersion: 2)
        let upgradedCount = await upgraded.count()
        XCTAssertEqual(upgradedCount, 0, "a parser upgrade purges every older row on open")
        let miss = await upgraded.record(forPath: session.sourcePath, fingerprint: fingerprint)
        XCTAssertNil(miss)
    }

    func testStoreDegradesWhenItCannotOpenAndReplacesACorruptFile() async throws {
        let unopenable = SessionStructureStore(url: directory.appendingPathComponent("missing/deeper/structure.sqlite3"))
        let available = await unopenable.isAvailable
        XCTAssertFalse(available)
        let session = try rollout(id: threadID(3), turns: 1)
        let structure = try XCTUnwrap(CodexSessionStructureParser.parse(fileURL: URL(fileURLWithPath: session.sourcePath)))
        let fingerprint = try XCTUnwrap(SessionFileFingerprint.of(path: session.sourcePath))
        await unopenable.upsert(SessionStructureRecord(structure: structure, fingerprint: fingerprint))
        let nothing = await unopenable.record(forPath: session.sourcePath)
        XCTAssertNil(nothing)

        try Data(repeating: 0x5A, count: 8_192).write(to: storeURL)
        let recovered = SessionStructureStore(url: storeURL)
        await recovered.upsert(SessionStructureRecord(structure: structure, fingerprint: fingerprint))
        let row = await recovered.record(forPath: session.sourcePath, fingerprint: fingerprint)
        XCTAssertNotNil(row, "a file that is not a database is derived data and gets rebuilt")
    }

    // MARK: - Service

    func testSecondServiceInstanceIsServedFromTheSidecar() async throws {
        let session = try rollout(id: threadID(4), turns: 3)
        let first = SessionStructureService(store: SessionStructureStore(url: storeURL))
        let parsed = try await XCTUnwrapAsync(await first.stats(for: session))
        XCTAssertEqual(parsed.promptCount, 3)

        // Unreadable now: anything the next instance returns came from the sidecar.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: session.sourcePath)
        let second = SessionStructureService(store: SessionStructureStore(url: storeURL))
        let cached = try await XCTUnwrapAsync(await second.outline(for: session))
        XCTAssertEqual(cached.stats, parsed)
        XCTAssertEqual(cached.detail, .outline)
        XCTAssertEqual(cached.turns.count, 3)
        let full = await second.structure(for: session, detail: .full)
        XCTAssertNil(full, "full detail needs the file")
    }

    func testFileChangeInvalidatesTheCachedRow() async throws {
        let id = threadID(5)
        let session = try rollout(id: id, turns: 1)
        let service = SessionStructureService(store: SessionStructureStore(url: storeURL))
        let before = await service.stats(for: session)
        XCTAssertEqual(before?.promptCount, 1)

        let longer = try rollout(id: id, turns: 3)
        let after = await service.stats(for: longer)
        XCTAssertEqual(after?.promptCount, 3)
        let full = await service.structure(for: longer, detail: .full)
        XCTAssertEqual(full?.turns.count, 3)
        XCTAssertEqual(full?.detail, .full)
    }

    func testFullStructuresAreKeptInASmallLRU() async throws {
        let service = SessionStructureService(store: nil, configuration: .init(cacheCapacity: 2))
        let sessions = try (6..<9).map { try rollout(id: threadID($0), turns: 1) }
        for session in sessions { _ = await service.structure(for: session, detail: .full) }
        let cached = await service.cachedPaths
        XCTAssertEqual(cached, [sessions[1].sourcePath, sessions[2].sourcePath])
        _ = await service.structure(for: sessions[1], detail: .full)
        let reordered = await service.cachedPaths
        XCTAssertEqual(reordered.last, sessions[1].sourcePath)
    }

    func testLargeFilesGetAnOutlineAndTurnsByWindow() async throws {
        let session = try rollout(id: threadID(9), turns: 4)
        let service = SessionStructureService(
            store: SessionStructureStore(url: storeURL),
            configuration: .init(fullParseLimitBytes: 1_024)
        )
        let structure = try await XCTUnwrapAsync(await service.structure(for: session, detail: .full))
        XCTAssertEqual(structure.detail, .outline, "over the limit, full detail falls back to the outline")
        XCTAssertEqual(structure.turns.count, 4)
        XCTAssertTrue(structure.turns.allSatisfy(\.steps.isEmpty))

        let turn = try await XCTUnwrapAsync(await service.turn(at: 2, for: session))
        XCTAssertEqual(turn.index, 2)
        XCTAssertEqual(turn.prompt.text, "Question 2")
        XCTAssertEqual(turn.steps.filter(\.kind.isAction).first?.callID, "c2")
        XCTAssertEqual(turn.usage, structure.turns[2].usage, "usage comes from the whole-file outline")
        XCTAssertEqual(turn.finalAnswer, "Answer 2")
    }

    func testRefreshFillsTheSidecarWithinItsBudgets() async throws {
        let sessions = try (10..<13).enumerated().map { offset, n -> SessionSummary in
            let s = try rollout(id: threadID(n), turns: 1)
            return summary(.codex, id: s.sessionID, url: URL(fileURLWithPath: s.sourcePath), lastActive: TimeInterval(offset))
        }
        let unsupported = SessionSummary(provider: .gemini, sessionID: "g", sourcePath: directory.appendingPathComponent("g.json").path)
        let store = SessionStructureStore(url: storeURL)
        let service = SessionStructureService(store: store, configuration: .init(batchMaxFiles: 2))

        let first = await service.refresh(summaries: sessions + [unsupported])
        XCTAssertEqual(first.parsed, 2)
        XCTAssertEqual(first.deferred, 1)
        XCTAssertEqual(first.unsupported, 1)
        let newest = await store.record(forPath: sessions[2].sourcePath)
        XCTAssertNotNil(newest, "most recently active first")

        let second = await service.refresh(summaries: sessions)
        XCTAssertEqual(second.upToDate, 2)
        XCTAssertEqual(second.parsed, 1)
        let rows = await store.count()
        XCTAssertEqual(rows, 3)
    }

    func testCodexStateDatabaseFillsTokensWhenTheRolloutHasNoCounter() async throws {
        let id = threadID(20)
        let session = try rollout(id: id, turns: 2, tokens: false)
        let stateURL = directory.appendingPathComponent("state_5.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(stateURL.path, &handle), SQLITE_OK)
        let sql = """
            CREATE TABLE threads (id TEXT PRIMARY KEY, tokens_used INTEGER NOT NULL DEFAULT 0, model TEXT,
                                  reasoning_effort TEXT, git_branch TEXT, thread_source TEXT);
            INSERT INTO threads VALUES ('\(id)', 4321, 'gpt-5', 'high', 'feature/state', 'user');
            """
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let service = SessionStructureService(store: nil, codexState: CodexThreadStateReader(url: stateURL))
        let stats = try await XCTUnwrapAsync(await service.stats(for: session))
        XCTAssertEqual(stats.totalTokens, 4_321)
        XCTAssertEqual(stats.usageSource, .codexStateDatabase)
        XCTAssertEqual(stats.gitBranch, "feature/state")

        let missing = CodexThreadStateReader(url: directory.appendingPathComponent("absent.sqlite"))
        XCTAssertNil(missing.thread(id: id))
    }

    func testUnsupportedProvidersAndMissingFilesReturnNil() async throws {
        let service = SessionStructureService(store: nil)
        let gemini = SessionSummary(provider: .gemini, sessionID: "x", sourcePath: "/Users/example/none.json")
        let none = await service.stats(for: gemini)
        XCTAssertNil(none)
        let gone = SessionSummary(provider: .codex, sessionID: "y", sourcePath: directory.appendingPathComponent("gone.jsonl").path)
        let missing = await service.structure(for: gone, detail: .full)
        XCTAssertNil(missing)
    }
}

/// `XCTUnwrap` for an already-awaited optional, so call sites read `try await XCTUnwrapAsync(await …)`.
func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let resolved = try await value()
    return try XCTUnwrap(resolved, file: file, line: line)
}
