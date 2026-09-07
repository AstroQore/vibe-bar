import SQLite3
import XCTest
@testable import VibeBarCore

final class SessionIndexCompactorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarSessionIndexCompactor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var databaseURL: URL { directory.appendingPathComponent("session_index.sqlite3") }
    private var stampURL: URL { directory.appendingPathComponent("stamp.json") }
    private var scratchURL: URL { directory.appendingPathComponent("scratch", isDirectory: true) }

    private func makeCompactor(
        policy: SessionIndexExcerptPolicy = SessionIndexExcerptPolicy(
            toolExcerptCharacters: 100,
            proseExcerptCharacters: 200,
            sessionExcerptBytes: 4_096
        )
    ) -> SessionIndexCompactor {
        SessionIndexCompactor(
            databaseURL: databaseURL,
            stampURL: stampURL,
            scratchDirectoryURL: scratchURL,
            policy: policy
        )
    }

    private func seedStore() async throws -> SessionIndexStore {
        let store = try SessionIndexStore(url: databaseURL)
        let summary = SessionSummary(
            provider: .codex,
            sessionID: "0000-test",
            sourcePath: "/Users/example/.codex/sessions/rollout-test.jsonl"
        )
        let row = try await store.upsertSession(summary)
        // One over-long tool excerpt carrying a unique marker beyond the
        // 100-character cap, one compliant user excerpt, and a run of tool
        // excerpts that blows the 4 KiB per-session budget.
        var excerpts: [SessionIndexStore.MessageExcerpt] = [
            .init(seq: 0, role: .user, excerpt: "please summarize the zebra migration"),
            .init(
                seq: 1,
                role: .tool,
                excerpt: String(repeating: "x", count: 300) + " QUAGGAMARKER tail"
            )
        ]
        for seq in 2..<60 {
            excerpts.append(.init(seq: seq, role: .tool, excerpt: String(repeating: "y", count: 90)))
        }
        try await store.replaceMessages(sessionRow: row, excerpts: excerpts)
        return store
    }

    func testCompactTrimsMergesAndVacuums() async throws {
        let store = try await seedStore()
        let compactor = makeCompactor()

        let maybeOutcome = await compactor.compact()
        let outcome = try XCTUnwrap(maybeOutcome)
        XCTAssertTrue(outcome.completed)
        XCTAssertEqual(outcome.sessionsTrimmed, 1)
        XCTAssertEqual(outcome.messagesTrimmed, 1, "only the 300-char tool excerpt exceeds its cap")
        XCTAssertGreaterThan(outcome.messagesDropped, 0, "the budget stop drops the tail")
        XCTAssertTrue(outcome.ranFullVacuum, "first pass converts the database to auto_vacuum")
        XCTAssertGreaterThan(outcome.mergeSteps, 0)

        // Content within the caps stays searchable; content beyond them is gone.
        let kept = try await store.search(text: "zebra migration")
        XCTAssertEqual(kept.count, 1)
        let trimmedAway = try await store.search(text: "QUAGGAMARKER", scopes: [.tool])
        XCTAssertTrue(trimmedAway.isEmpty, "text beyond the tool cap must leave the index")

        // The budget stop keeps a prefix: total stored bytes obey the budget.
        let remaining = try await store.messageCount()
        XCTAssertLessThan(remaining, 60)
        XCTAssertGreaterThan(remaining, 0)

        // A second pass finds nothing to do.
        let maybeSecond = await compactor.compact()
        let second = try XCTUnwrap(maybeSecond)
        XCTAssertTrue(second.completed)
        XCTAssertEqual(second.sessionsTrimmed, 0)
        XCTAssertEqual(second.messagesDropped, 0)
        XCTAssertEqual(second.messagesTrimmed, 0)
        XCTAssertFalse(second.ranFullVacuum, "auto_vacuum is already incremental")
    }

    func testCompactIfDueHonorsStamp() async throws {
        _ = try await seedStore()
        let compactor = makeCompactor()

        let first = await compactor.compactIfDue()
        XCTAssertNotNil(first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stampURL.path))

        let throttled = await compactor.compactIfDue()
        XCTAssertNil(throttled, "a completed pass parks the compactor for the interval")

        // A stale stamp (or a bumped policy version) makes it due again.
        try FileManager.default.removeItem(at: stampURL)
        let rerun = await compactor.compactIfDue()
        XCTAssertNotNil(rerun)
    }

    func testMissingDatabaseDoesNothing() async {
        let compactor = makeCompactor()
        let outcome = await compactor.compact()
        XCTAssertNil(outcome)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: databaseURL.path),
            "maintenance must never create the database"
        )
    }

    func testUnsupportedSchemaVersionLeavesRowsAlone() async throws {
        let store = try await seedStore()
        let before = try await store.messageCount()

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "PRAGMA user_version = 99", nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(handle)

        let outcome = await makeCompactor().compact()
        XCTAssertNil(outcome, "an unknown kit schema is not ours to rewrite")
        let after = try await store.messageCount()
        XCTAssertEqual(before, after)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stampURL.path))
    }

    func testSweepRemovesStaleScratchFiles() async throws {
        _ = try await seedStore()
        try FileManager.default.createDirectory(at: scratchURL, withIntermediateDirectories: true)
        let stale = scratchURL.appendingPathComponent("head-old.jsonl")
        let fresh = scratchURL.appendingPathComponent("head-new.jsonl")
        try Data("old".utf8).write(to: stale)
        try Data("new".utf8).write(to: fresh)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3 * 24 * 60 * 60)],
            ofItemAtPath: stale.path
        )

        _ = await makeCompactor().compact()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }
    func testScratchSweepRefusesSymlinkedRootAndSkipsSymlinkedEntries() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarScratchSymlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: base) }
        let home = base.appendingPathComponent("home", isDirectory: true)
        let victim = base.appendingPathComponent("victim", isDirectory: true)
        try fileManager.createDirectory(
            at: home.appendingPathComponent(".vibebar", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: victim, withIntermediateDirectories: true)
        let victimFile = victim.appendingPathComponent("keep.txt")
        try Data("precious".utf8).write(to: victimFile)
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3 * 86_400)],
            ofItemAtPath: victimFile.path
        )

        // A symlink planted where the scratch root should be must be removed
        // as a link — its target untouched.
        let scratch = VibeBarLocalStore.sessionIndexScratchDirectoryURL(homeDirectory: home.path)
        try fileManager.createSymbolicLink(at: scratch, withDestinationURL: victim)
        let compactor = SessionIndexCompactor(
            databaseURL: base.appendingPathComponent("absent.sqlite3"),
            stampURL: base.appendingPathComponent("stamp.json"),
            scratchDirectoryURL: scratch
        )
        compactor.sweepScratchForTesting(now: Date())
        XCTAssertTrue(fileManager.fileExists(atPath: victimFile.path), "the sweep must never follow a symlinked root")
        var isDirectory: ObjCBool = false
        XCTAssertFalse(
            fileManager.fileExists(atPath: scratch.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue,
            "the planted link itself should be gone"
        )

        // A symlinked entry inside a real scratch root is dropped as a link.
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        let plantedLink = scratch.appendingPathComponent("escape")
        try fileManager.createSymbolicLink(at: plantedLink, withDestinationURL: victim)
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3 * 86_400)],
            ofItemAtPath: plantedLink.path
        )
        compactor.sweepScratchForTesting(now: Date())
        XCTAssertTrue(fileManager.fileExists(atPath: victimFile.path))
        XCTAssertNil(try? fileManager.destinationOfSymbolicLink(atPath: plantedLink.path))
    }
}

extension SessionIndexCompactorTests {
    /// A parser fix reaches files the index already read only if their
    /// cursors go. The rows themselves stay, so nothing vanishes from the
    /// Workbench while the next pass re-reads them.
    func testAReparseDropsOnlyTheNamedProvidersCursorsAndRunsOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("session_index.sqlite3")
        let stampURL = directory.appendingPathComponent("reparse.json")

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &handle,
                                       SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        let database = try XCTUnwrap(handle)
        XCTAssertEqual(sqlite3_exec(database, """
            CREATE TABLE session_files (path_hash TEXT PRIMARY KEY, path TEXT NOT NULL, provider TEXT NOT NULL);
            INSERT INTO session_files VALUES ('a', '/a.db', 'antigravity'), ('b', '/b.db', 'antigravity'),
                                             ('c', '/c.jsonl', 'claude');
            """, nil, nil, nil), SQLITE_OK)
        func remaining() -> [String] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT provider FROM session_files ORDER BY path_hash", -1,
                                     &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            var out: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                out.append(String(cString: sqlite3_column_text(statement, 0)))
            }
            return out
        }

        let first = SessionIndexReparse.runIfNeeded(databaseURL: databaseURL, stampURL: stampURL, version: 1)
        XCTAssertEqual(first?.cursorsDropped, 2)
        XCTAssertEqual(remaining(), ["claude"], "another provider's cursors are not this fix's business")

        // Stamped, so a relaunch does not pay for the same re-scan again.
        XCTAssertNil(SessionIndexReparse.runIfNeeded(databaseURL: databaseURL, stampURL: stampURL, version: 1))
        // A later version runs again.
        XCTAssertEqual(
            SessionIndexReparse.runIfNeeded(databaseURL: databaseURL, stampURL: stampURL, version: 2,
                                            providers: ["claude"])?.cursorsDropped,
            1
        )
        XCTAssertTrue(remaining().isEmpty)
        sqlite3_close_v2(database)

        // No index yet: nothing to do, and stamped so it never runs on the
        // database the next scan creates.
        let fresh = directory.appendingPathComponent("fresh.json")
        XCTAssertNil(SessionIndexReparse.runIfNeeded(
            databaseURL: directory.appendingPathComponent("missing.sqlite3"), stampURL: fresh, version: 1
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }
}
