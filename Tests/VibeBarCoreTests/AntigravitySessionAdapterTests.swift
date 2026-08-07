import XCTest
import SQLite3
@testable import VibeBarCore

/// Test-only protobuf writer, mirroring the wire format the AntiGravity
/// databases store in `steps.step_payload` and `gen_metadata.data`.
enum AntigravityProtoFixture {
    static func varint(_ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var remaining = value
        while remaining > 0x7F {
            bytes.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        bytes.append(UInt8(remaining & 0x7F))
        return bytes
    }

    static func tag(_ field: UInt64, _ wire: UInt64) -> [UInt8] {
        varint((field << 3) | wire)
    }

    static func varintField(_ field: UInt64, _ value: UInt64) -> [UInt8] {
        tag(field, 0) + varint(value)
    }

    static func message(_ field: UInt64, _ payload: [UInt8]) -> [UInt8] {
        tag(field, 2) + varint(UInt64(payload.count)) + payload
    }

    static func string(_ field: UInt64, _ value: String) -> [UInt8] {
        message(field, [UInt8](value.utf8))
    }

    /// A step payload shaped like the real thing: a couple of scalar
    /// fields, some id / field-name noise, and the readable content one
    /// level down inside a nested message.
    static func stepPayload(texts: [String], noise: [String] = defaultNoise) -> Data {
        var nested: [UInt8] = []
        for (offset, text) in texts.enumerated() {
            nested += string(UInt64(offset + 1), text)
        }
        for (offset, junk) in noise.enumerated() {
            nested += string(UInt64(offset + 20), junk)
        }
        var outer = varintField(1, 42)
        outer += string(2, "sessionID")
        outer += message(3, nested)
        return Data(outer)
    }

    static let defaultNoise = [
        "e702954a-f739-425f-b5d3-565dafc7882e",
        "$115b8202-1278-45f4-ba9c-add45ae32d63",
        "/Users/example/proj/scratch/chunk_7.json",
        "dGhpc2lzYmFzZTY0bm9pc2VBQkNERUZHSA==",
        "toolSummary"
    ]

    /// `gen_metadata.data`: outer message 1, per-turn usage under 4,
    /// wall clock under 9.4, routed model under 19.
    static func turnBlob(
        seconds: UInt64,
        input: UInt64,
        output: UInt64,
        model: String? = "gemini-3-flash-a"
    ) -> Data {
        var usage = varintField(1, 1132)
        usage += varintField(2, input)
        usage += varintField(3, output)
        usage += string(11, "req-fixture")
        let timeBlock = varintField(1, seconds) + varintField(2, 0)
        var outer = message(4, usage) + message(9, message(4, timeBlock))
        if let model { outer += string(19, model) }
        return Data(message(1, outer))
    }
}

/// Writes a conversation database with just the tables the session
/// adapter reads.
enum AntigravityDBFixture {
    struct Step {
        let idx: Int
        let type: Int
        let payload: Data?
    }

    struct Turn {
        let idx: Int
        let blob: Data
    }

    @discardableResult
    static func write(
        at url: URL,
        steps: [Step],
        turns: [Turn] = [],
        walMode: Bool = false,
        keepOpen: Bool = false
    ) throws -> OpaquePointer? {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
        ) == SQLITE_OK, let db else {
            throw CocoaError(.fileWriteUnknown)
        }
        if walMode {
            sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        }
        let schema = """
            CREATE TABLE `steps` (`idx` integer, `step_type` integer NOT NULL DEFAULT 0,
                `status` integer NOT NULL DEFAULT 0, `metadata` blob, `render_info` blob,
                `step_payload` blob, PRIMARY KEY (`idx`));
            CREATE TABLE `gen_metadata` (`idx` integer, `data` blob,
                `size` integer NOT NULL DEFAULT 0, PRIMARY KEY (`idx`));
            CREATE TABLE `trajectory_meta` (`trajectory_id` text, PRIMARY KEY (`trajectory_id`));
            """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close_v2(db)
            throw CocoaError(.fileWriteUnknown)
        }

        for step in steps {
            var statement: OpaquePointer?
            let sql = "INSERT INTO steps(idx, step_type, step_payload) VALUES (?, ?, ?)"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_close_v2(db)
                throw CocoaError(.fileWriteUnknown)
            }
            sqlite3_bind_int64(statement, 1, sqlite3_int64(step.idx))
            sqlite3_bind_int64(statement, 2, sqlite3_int64(step.type))
            if let payload = step.payload {
                payload.withUnsafeBytes { raw in
                    sqlite3_bind_blob(statement, 3, raw.baseAddress, Int32(payload.count),
                                      unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            } else {
                sqlite3_bind_null(statement, 3)
            }
            let stepped = sqlite3_step(statement)
            sqlite3_finalize(statement)
            guard stepped == SQLITE_DONE else {
                sqlite3_close_v2(db)
                throw CocoaError(.fileWriteUnknown)
            }
        }

        for turn in turns {
            var statement: OpaquePointer?
            let sql = "INSERT INTO gen_metadata(idx, data, size) VALUES (?, ?, ?)"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_close_v2(db)
                throw CocoaError(.fileWriteUnknown)
            }
            sqlite3_bind_int64(statement, 1, sqlite3_int64(turn.idx))
            turn.blob.withUnsafeBytes { raw in
                sqlite3_bind_blob(statement, 2, raw.baseAddress, Int32(turn.blob.count),
                                  unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            sqlite3_bind_int64(statement, 3, sqlite3_int64(turn.blob.count))
            let stepped = sqlite3_step(statement)
            sqlite3_finalize(statement)
            guard stepped == SQLITE_DONE else {
                sqlite3_close_v2(db)
                throw CocoaError(.fileWriteUnknown)
            }
        }

        if keepOpen { return db }
        sqlite3_close_v2(db)
        return nil
    }

    /// A `conversation_summaries` row set, as written by the CLI.
    static func writeSummaries(
        at url: URL,
        rows: [(id: String, title: String, preview: String, workspaces: String)]
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
        ) == SQLITE_OK, let db else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close_v2(db) }
        let schema = """
            CREATE TABLE `conversation_summaries` (`conversation_id` text,
                `title` text NOT NULL DEFAULT "", `preview` text NOT NULL DEFAULT "",
                `step_count` integer NOT NULL DEFAULT 0, `last_modified_time` datetime NOT NULL,
                `workspace_uris` text NOT NULL, `status` text NOT NULL DEFAULT "",
                `agent_name` text NOT NULL DEFAULT "", PRIMARY KEY (`conversation_id`));
            """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for row in rows {
            var statement: OpaquePointer?
            let sql = """
                INSERT INTO conversation_summaries
                    (conversation_id, title, preview, step_count, last_modified_time,
                     workspace_uris, status, agent_name)
                VALUES (?, ?, ?, 4, '2026-07-16 08:18:19.171238+00:00', ?, 'DONE', 'agy')
                """
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw CocoaError(.fileWriteUnknown)
            }
            sqlite3_bind_text(statement, 1, row.id, -1, transient)
            sqlite3_bind_text(statement, 2, row.title, -1, transient)
            sqlite3_bind_text(statement, 3, row.preview, -1, transient)
            sqlite3_bind_text(statement, 4, row.workspaces, -1, transient)
            let stepped = sqlite3_step(statement)
            sqlite3_finalize(statement)
            guard stepped == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
        }
    }
}

final class AntigravitySessionAdapterTests: XCTestCase {
    private var home: URL!
    private let adapter = AntigravitySessionAdapter()
    private let conversationID = "6529ee47-c850-4306-a253-95704c871de0"
    private let base: UInt64 = 1_779_434_400

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarAntigravitySessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Fixtures

    private func conversationsDirectory(surface: String) -> URL {
        home
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent(surface, isDirectory: true)
            .appendingPathComponent("conversations", isDirectory: true)
    }

    private var defaultSteps: [AntigravityDBFixture.Step] {
        [
            AntigravityDBFixture.Step(
                idx: 0, type: 14,
                payload: AntigravityProtoFixture.stepPayload(
                    texts: ["You are a translation worker for this workspace."]
                )
            ),
            AntigravityDBFixture.Step(
                idx: 1, type: 15,
                payload: AntigravityProtoFixture.stepPayload(
                    texts: ["Reading the input chunk before translating it."]
                )
            ),
            AntigravityDBFixture.Step(
                idx: 2, type: 33,
                payload: AntigravityProtoFixture.stepPayload(
                    texts: ["Searching the web for release notes."]
                )
            ),
            AntigravityDBFixture.Step(
                idx: 3, type: 999,
                payload: AntigravityProtoFixture.stepPayload(
                    texts: ["An unrecognized step still shows its text."]
                )
            )
        ]
    }

    @discardableResult
    private func writeConversation(
        surface: String = "antigravity",
        id: String? = nil,
        steps: [AntigravityDBFixture.Step]? = nil,
        turns: [AntigravityDBFixture.Turn] = []
    ) throws -> URL {
        let url = conversationsDirectory(surface: surface)
            .appendingPathComponent("\(id ?? conversationID).db")
        try AntigravityDBFixture.write(at: url, steps: steps ?? defaultSteps, turns: turns)
        return url
    }

    private func writeHistory(_ lines: [String], surface: String = "antigravity-cli") throws {
        let url = home
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent(surface, isDirectory: true)
            .appendingPathComponent("history.jsonl")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private var defaultTurns: [AntigravityDBFixture.Turn] {
        [
            AntigravityDBFixture.Turn(
                idx: 1, blob: AntigravityProtoFixture.turnBlob(seconds: base, input: 1_000, output: 200)
            ),
            AntigravityDBFixture.Turn(
                idx: 3, blob: AntigravityProtoFixture.turnBlob(seconds: base + 60, input: 2_000, output: 300)
            )
        ]
    }

    // MARK: - Discovery

    func testDiscoveryCoversEverySurfaceAndDerivesTheVariant() throws {
        let ide = try writeConversation(surface: "antigravity")
        let cli = try writeConversation(surface: "antigravity-cli", id: "11111111-2222-3333-4444-555555555555")
        let ide2 = try writeConversation(surface: "antigravity-ide", id: "99999999-2222-3333-4444-555555555555")

        let found = adapter.discoverSessionFiles(homeDirectory: home.path)
        XCTAssertEqual(
            Set(found.map(SessionTestPaths.canonical)),
            Set([ide, cli, ide2].map(SessionTestPaths.canonical))
        )
        XCTAssertEqual(adapter.roots(homeDirectory: home.path).count, 3)
        XCTAssertEqual(try adapter.extractMetadata(fileURL: ide).providerVariant, "ide")
        XCTAssertEqual(try adapter.extractMetadata(fileURL: cli).providerVariant, "cli")
        XCTAssertEqual(try adapter.extractMetadata(fileURL: ide2).providerVariant, "ide2")
    }

    func testDiscoveryIgnoresJournalSiblingsAndToleratesMissingDirectories() throws {
        XCTAssertTrue(adapter.discoverSessionFiles(homeDirectory: home.path).isEmpty)

        let url = try writeConversation()
        let directory = url.deletingLastPathComponent()
        try Data().write(to: directory.appendingPathComponent("\(conversationID).db-wal"))
        try Data().write(to: directory.appendingPathComponent("\(conversationID).db-shm"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("notes.json"))

        XCTAssertEqual(
            adapter.discoverSessionFiles(homeDirectory: home.path).map(SessionTestPaths.canonical),
            [SessionTestPaths.canonical(url)]
        )
    }

    func testMetadataRefusesAFileOutsideAConversationsDirectory() throws {
        let stray = home.appendingPathComponent("stray.db")
        try Data().write(to: stray)
        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: stray))
    }

    func testRegistryShipsTheAntigravityAdapter() {
        let registry = SessionProviderRegistry.standard(homeDirectory: home.path)
        XCTAssertNotNil(registry.adapter(for: .antigravity))
        XCTAssertTrue(registry.providers.contains(.antigravity))
    }

    // MARK: - Metadata

    func testMetadataUsesTurnDatesAndTurnCount() throws {
        let url = try writeConversation(turns: defaultTurns)
        let summary = try adapter.extractMetadata(fileURL: url)

        XCTAssertEqual(summary.provider, .antigravity)
        XCTAssertEqual(summary.sessionID, conversationID)
        XCTAssertEqual(summary.messageCount, 2)
        XCTAssertEqual(summary.createdAt?.timeIntervalSince1970, TimeInterval(base))
        XCTAssertEqual(summary.lastActiveAt?.timeIntervalSince1970, TimeInterval(base + 60))
        XCTAssertGreaterThan(summary.sizeBytes, 0)
    }

    func testMetadataFallsBackToFileDatesWithoutGenMetadata() throws {
        let url = try writeConversation()
        let summary = try adapter.extractMetadata(fileURL: url)
        XCTAssertEqual(summary.messageCount, 0)
        XCTAssertNotNil(summary.createdAt)
        XCTAssertNotNil(summary.lastActiveAt)
    }

    // MARK: - Title chain

    func testDisjointSummaryRowsStillLeaveEveryConversationListed() throws {
        let url = try writeConversation(surface: "antigravity-cli")
        // Exactly the observed shape: the summaries store knows about
        // conversations that no longer exist on disk, and knows nothing
        // about the ones that do.
        try AntigravityDBFixture.writeSummaries(
            at: home.appendingPathComponent(".gemini/antigravity-cli/conversation_summaries.db"),
            rows: [
                (id: "aaaaaaaa-1111-2222-3333-444444444444", title: "Stale title",
                 preview: "gone", workspaces: "[\"file:///Users/example/gone\"]"),
                (id: "bbbbbbbb-1111-2222-3333-444444444444", title: "Another stale title",
                 preview: "gone", workspaces: "")
            ]
        )

        let summary = try adapter.extractMetadata(fileURL: url)
        XCTAssertEqual(summary.sessionID, conversationID)
        // Fell all the way through to the first readable step text.
        XCTAssertEqual(summary.title, "You are a translation worker for this workspace.")
        XCTAssertNil(summary.projectDir)
    }

    func testSummaryRowWinsWhenItMatchesTheConversation() throws {
        let url = try writeConversation(surface: "antigravity-cli")
        try AntigravityDBFixture.writeSummaries(
            at: home.appendingPathComponent(".gemini/antigravity-cli/conversation_summaries.db"),
            rows: [(id: conversationID, title: "Hydrated title", preview: "preview",
                    workspaces: "[\"file:///Users/example/proj\"]")]
        )

        let summary = try adapter.extractMetadata(fileURL: url)
        XCTAssertEqual(summary.title, "Hydrated title")
        XCTAssertEqual(summary.projectDir, "/Users/example/proj")
    }

    func testIDEConversationsHydrateFromTheSharedCLISummariesStore() throws {
        // Observed shape: the IDE surface has no summaries store of its
        // own, `title` is empty, and the usable label lives in `preview`
        // as a markdown heading.
        let url = try writeConversation(surface: "antigravity")
        try AntigravityDBFixture.writeSummaries(
            at: home.appendingPathComponent(".gemini/antigravity-cli/conversation_summaries.db"),
            rows: [(id: conversationID, title: "", preview: "### 翻译项目启动与核心术语确认",
                    workspaces: "[\"file:///Users/example/agy%20misc\"]")]
        )

        let summary = try adapter.extractMetadata(fileURL: url)
        XCTAssertEqual(summary.title, "翻译项目启动与核心术语确认")
        XCTAssertEqual(summary.projectDir, "/Users/example/agy misc")
    }

    func testHistoryProvidesTitleAndWorkingDirectoryForTheCLI() throws {
        let url = try writeConversation(surface: "antigravity-cli")
        try writeHistory([
            "{\"display\":\"exit\",\"timestamp\":1779249577634,\"workspace\":\"/Users/example/other\"}",
            "{\"display\":\"Summarize today's releases\",\"timestamp\":1779249622163,"
                + "\"workspace\":\"/Users/example/proj\",\"conversationId\":\"\(conversationID)\"}",
            "{\"display\":\"and then translate them\",\"timestamp\":1779249722163,"
                + "\"workspace\":\"/Users/example/proj\",\"conversationId\":\"\(conversationID)\"}",
            "not json at all"
        ])

        let summary = try adapter.extractMetadata(fileURL: url)
        XCTAssertEqual(summary.title, "Summarize today's releases")
        XCTAssertEqual(summary.projectDir, "/Users/example/proj")
    }

    func testHistoryWorkingDirectoryOutranksTheSummaryRow() throws {
        let url = try writeConversation(surface: "antigravity-cli")
        try writeHistory([
            "{\"display\":\"Prompt text\",\"timestamp\":1779249622163,"
                + "\"workspace\":\"/Users/example/current\",\"conversationId\":\"\(conversationID)\"}"
        ])
        try AntigravityDBFixture.writeSummaries(
            at: home.appendingPathComponent(".gemini/antigravity-cli/conversation_summaries.db"),
            rows: [(id: conversationID, title: "Hydrated title", preview: "preview",
                    workspaces: "[\"file:///Users/example/stale\"]")]
        )

        let summary = try adapter.extractMetadata(fileURL: url)
        XCTAssertEqual(summary.title, "Hydrated title")
        XCTAssertEqual(summary.projectDir, "/Users/example/current")
    }

    func testTitleFallsBackToAShortenedConversationID() throws {
        let url = try writeConversation(steps: [
            AntigravityDBFixture.Step(idx: 0, type: 15, payload: nil),
            AntigravityDBFixture.Step(
                idx: 1, type: 15,
                payload: AntigravityProtoFixture.stepPayload(texts: [], noise: ["shortid", "sessionID"])
            )
        ])
        XCTAssertEqual(try adapter.extractMetadata(fileURL: url).title, "Conversation 6529ee47…")
    }

    // MARK: - Transcript

    func testTranscriptMapsStepTypesToRolesAndLabelsUnknownOnes() throws {
        let url = try writeConversation()
        let document = try adapter.parseTranscript(fileURL: url, range: nil)

        XCTAssertEqual(document.messages.map(\.role), [.system, .assistant, .tool, .other])
        XCTAssertEqual(document.messages.map(\.text), [
            "You are a translation worker for this workspace.",
            "Reading the input chunk before translating it.",
            "Searching the web for release notes.",
            "Step 999: An unrecognized step still shows its text."
        ])
        XCTAssertEqual(document.totalMessageCount, 4)
        XCTAssertFalse(document.truncated)
    }

    func testTranscriptDropsProtobufNoiseAroundTheRealText() throws {
        let url = try writeConversation(steps: [
            AntigravityDBFixture.Step(
                idx: 0, type: 15,
                payload: AntigravityProtoFixture.stepPayload(
                    texts: ["The actual model reply, in prose.", "翻译项目启动与核心术语确认"]
                )
            )
        ])
        let document = try adapter.parseTranscript(fileURL: url, range: nil)

        XCTAssertEqual(document.messages.count, 1)
        let text = try XCTUnwrap(document.messages.first?.text)
        XCTAssertTrue(text.contains("The actual model reply, in prose."))
        XCTAssertTrue(text.contains("翻译项目启动与核心术语确认"))
        for noise in AntigravityProtoFixture.defaultNoise {
            XCTAssertFalse(text.contains(noise), "noise leaked into the transcript: \(noise)")
        }
        XCTAssertFalse(text.contains("sessionID"))
    }

    func testTranscriptHonorsARange() throws {
        let url = try writeConversation()
        let document = try adapter.parseTranscript(fileURL: url, range: 1..<3)
        XCTAssertEqual(document.messages.map(\.role), [.assistant, .tool])
        XCTAssertEqual(document.totalMessageCount, 4)
        XCTAssertTrue(document.truncated)
    }

    func testTurnCardsAppearOnlyForRegionsWithoutStepText() throws {
        // idx 0 has readable text, idx 1 does not — so only the second
        // turn is represented by its token card.
        let url = try writeConversation(
            steps: [
                AntigravityDBFixture.Step(
                    idx: 0, type: 15,
                    payload: AntigravityProtoFixture.stepPayload(texts: ["Model reply with content."])
                ),
                AntigravityDBFixture.Step(idx: 1, type: 15, payload: nil)
            ],
            turns: [
                AntigravityDBFixture.Turn(
                    idx: 0, blob: AntigravityProtoFixture.turnBlob(seconds: base, input: 1_000, output: 200)
                ),
                AntigravityDBFixture.Turn(
                    idx: 1,
                    blob: AntigravityProtoFixture.turnBlob(seconds: base + 60, input: 7, output: 9)
                )
            ]
        )

        let document = try adapter.parseTranscript(fileURL: url, range: nil)
        XCTAssertEqual(document.messages.map(\.role), [.assistant, .other])
        XCTAssertEqual(document.messages.map(\.text), [
            "Model reply with content.",
            "Turn — gemini-3-flash-a · in 7 · out 9"
        ])
        XCTAssertEqual(document.messages.last?.timestamp?.timeIntervalSince1970, TimeInterval(base + 60))
    }

    func testTranscriptReadsADatabaseWithAnOpenWriteAheadLog() throws {
        let url = conversationsDirectory(surface: "antigravity-cli")
            .appendingPathComponent("\(conversationID).db")
        let handle = try AntigravityDBFixture.write(
            at: url, steps: defaultSteps, turns: defaultTurns, walMode: true, keepOpen: true
        )
        defer { if let handle { sqlite3_close_v2(handle) } }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-wal"))
        let document = try adapter.parseTranscript(fileURL: url, range: nil)
        XCTAssertEqual(document.messages.count, 4)
        XCTAssertEqual(try adapter.extractMetadata(fileURL: url).messageCount, 2)
    }

    // MARK: - Protobuf-only conversations

    func testProtobufSnapshotsAreListedWithoutContent() throws {
        let url = conversationsDirectory(surface: "antigravity")
            .appendingPathComponent("\(conversationID).pb")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data([0x00, 0x01, 0x02]).write(to: url)

        let summary = try adapter.extractMetadata(fileURL: url)
        XCTAssertEqual(summary.sessionID, conversationID)
        XCTAssertEqual(summary.providerVariant, "ide")
        XCTAssertEqual(summary.messageCount, SessionSummary.unknownMessageCount)
        XCTAssertFalse(summary.hasKnownMessageCount)
        XCTAssertEqual(summary.title, "Conversation 6529ee47…")
        XCTAssertEqual(try adapter.parseTranscript(fileURL: url, range: nil), .empty)
    }

    // MARK: - Deletion

    func testDeletionIsRefusedForEverySurface() throws {
        for surface in ["antigravity", "antigravity-cli", "antigravity-ide"] {
            let url = try writeConversation(surface: surface)
            let summary = try adapter.extractMetadata(fileURL: url)
            XCTAssertThrowsError(try adapter.deletionPlan(for: summary, homeDirectory: home.path)) { error in
                XCTAssertEqual(error as? SessionDeleteError, .unsupportedProvider)
            }
        }
    }

    func testDeleterRefusesAntigravitySessionsAndLeavesTheFileInPlace() throws {
        let url = try writeConversation()
        let summary = try adapter.extractMetadata(fileURL: url)
        let outcomes = SessionDeleter(homeDirectory: home.path).delete(
            [summary], registry: SessionProviderRegistry.standard(homeDirectory: home.path)
        )
        XCTAssertEqual(outcomes.first?.success, false)
        XCTAssertEqual(outcomes.first?.failureReason, .unsupportedProvider)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Text heuristics

    func testProseFilterKeepsSentencesAndDropsIdentifierNoise() {
        XCTAssertTrue(AntigravityStepText.isProse("Reading the input JSON file"))
        XCTAssertTrue(AntigravityStepText.isProse("翻译项目启动与核心术语确认"))
        XCTAssertTrue(AntigravityStepText.isProse("已经完成了"))

        XCTAssertFalse(AntigravityStepText.isProse("short"))
        XCTAssertFalse(AntigravityStepText.isProse("sessionID"))
        XCTAssertFalse(AntigravityStepText.isProse("e702954a-f739-425f-b5d3-565dafc7882e"))
        XCTAssertFalse(AntigravityStepText.isProse("/Users/example/proj/scratch/chunk_7.json"))
        XCTAssertFalse(AntigravityStepText.isProse("dGhpc2lzYmFzZTY0bm9pc2VBQkNERUZHSA=="))
        XCTAssertFalse(AntigravityStepText.isProse("-3750763034362895579P"))
    }
}
