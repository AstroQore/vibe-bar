import XCTest
import SQLite3
@testable import VibeBarCore

/// Builds a `store.db` with the two tables the adapter reads.
///
/// Nothing here is copied from a real Cursor store: the blob ids are made
/// up (the adapter only needs a reference and a row to agree, not a true
/// SHA-256), and every message is synthetic.
enum CursorStoreFixture {
    // MARK: - Wire writer

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

    static func bytesField(_ field: UInt64, _ payload: [UInt8]) -> [UInt8] {
        tag(field, 2) + varint(UInt64(payload.count)) + payload
    }

    static func stringField(_ field: UInt64, _ value: String) -> [UInt8] {
        bytesField(field, [UInt8](value.utf8))
    }

    /// A blob id as the 32 raw bytes a reference carries, plus the lowercase
    /// hex the `blobs` table is keyed by.
    struct BlobID {
        let bytes: [UInt8]
        let hex: String

        init(seed: UInt8) {
            bytes = [UInt8](repeating: seed, count: 32)
            hex = bytes.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// A node: the workspace URI, surface, timestamp, and the references to
    /// its messages — the shape the real root node has.
    static func node(
        workspaceURI: String? = nil,
        surface: String? = nil,
        timestampMillis: UInt64? = nil,
        references: [BlobID] = [],
        inlineMessage: String? = nil
    ) -> Data {
        var out: [UInt8] = []
        for reference in references {
            out += bytesField(1, reference.bytes)
        }
        if let inlineMessage { out += stringField(4, inlineMessage) }
        if let workspaceURI { out += stringField(9, workspaceURI) }
        if let surface { out += stringField(22, surface) }
        if let timestampMillis { out += varintField(26, timestampMillis) }
        return Data(out)
    }

    // MARK: - Messages

    static func userMessage(_ text: String) -> String {
        json(["role": "user", "content": text])
    }

    static func assistantMessage(_ text: String, model: String? = nil) -> String {
        var part: [String: Any] = ["type": "text", "text": text]
        if let model {
            part["providerOptions"] = ["cursor": ["modelName": model]]
        }
        return json([
            "role": "assistant",
            "id": "msg_fixture",
            "content": [["type": "reasoning", "text": "thinking"], part]
        ])
    }

    static func toolMessage() -> String {
        json(["role": "tool", "content": [["type": "tool-result", "text": "exit 0"]]])
    }

    static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Store

    struct Blob {
        let id: BlobID
        let data: Data

        init(id: BlobID, data: Data) {
            self.id = id
            self.data = data
        }

        init(id: BlobID, message: String) {
            self.id = id
            self.data = Data(message.utf8)
        }
    }

    static func hexEncoded(_ text: String) -> String {
        text.utf8.map { String(format: "%02x", $0) }.joined()
    }

    /// `~/.cursor/chats/<workspace-hash>/<agent-id>/store.db`.
    @discardableResult
    static func write(
        home: URL,
        agentID: String,
        workspaceHash: String = "0af52b5f862f8eb7689b0795c4f131f8",
        card: [String: Any]? = nil,
        metaKey: String = "0",
        metaValue: String? = nil,
        blobs: [Blob],
        walMode: Bool = false
    ) throws -> URL {
        let directory = home
            .appendingPathComponent(".cursor/chats", isDirectory: true)
            .appendingPathComponent(workspaceHash, isDirectory: true)
            .appendingPathComponent(agentID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("store.db")

        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
        ) == SQLITE_OK, let database else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close_v2(database) }
        if walMode {
            sqlite3_exec(database, "PRAGMA journal_mode=WAL", nil, nil, nil)
        }
        let schema = """
            CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB);
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
            """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }

        let value = metaValue ?? hexEncoded(json(card ?? [:]))
        try insertMeta(database, key: metaKey, value: value)
        for blob in blobs {
            try insertBlob(database, id: blob.id.hex, data: blob.data)
        }
        return url
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func insertMeta(_ database: OpaquePointer, key: String, value: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database, "INSERT INTO meta(key, value) VALUES(?, ?)", -1, &statement, nil
        ) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, transient)
        sqlite3_bind_text(statement, 2, value, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func insertBlob(_ database: OpaquePointer, id: String, data: Data) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database, "INSERT INTO blobs(id, data) VALUES(?, ?)", -1, &statement, nil
        ) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, transient)
        data.withUnsafeBytes { raw in
            sqlite3_bind_blob(statement, 2, raw.baseAddress, Int32(data.count), transient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
    }
}

final class CursorSessionAdapterTests: XCTestCase {
    private var home: URL!
    private let agentID = "ef677032-4618-4f13-9ffa-fded8574b84d"
    private let adapter = CursorSessionAdapter()

    private let root = CursorStoreFixture.BlobID(seed: 0x11)
    private let userBlob = CursorStoreFixture.BlobID(seed: 0x22)
    private let assistantBlob = CursorStoreFixture.BlobID(seed: 0x33)
    private let toolBlob = CursorStoreFixture.BlobID(seed: 0x44)

    private let createdAtMillis = 1_779_280_100_206

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarCursorSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Fixtures

    private func card(name: String? = "Polish the showcase", mode: String? = "default") -> [String: Any] {
        var object: [String: Any] = [
            "agentId": agentID,
            "latestRootBlobId": root.hex,
            "createdAt": createdAtMillis,
            "isRunEverything": true
        ]
        if let name { object["name"] = name }
        if let mode { object["mode"] = mode }
        return object
    }

    @discardableResult
    private func writeStore(
        card: [String: Any]? = nil,
        blobs: [CursorStoreFixture.Blob]? = nil,
        agentID: String? = nil,
        walMode: Bool = false
    ) throws -> URL {
        try CursorStoreFixture.write(
            home: home,
            agentID: agentID ?? self.agentID,
            card: card ?? self.card(),
            blobs: blobs ?? defaultBlobs,
            walMode: walMode
        )
    }

    private var defaultBlobs: [CursorStoreFixture.Blob] {
        [
            CursorStoreFixture.Blob(id: root, data: CursorStoreFixture.node(
                workspaceURI: "file:///Users/example/agents%20misc/showcase",
                surface: "cli",
                timestampMillis: UInt64(createdAtMillis),
                references: [userBlob, assistantBlob, toolBlob]
            )),
            CursorStoreFixture.Blob(id: userBlob, message: CursorStoreFixture.userMessage("Center the hero")),
            CursorStoreFixture.Blob(id: assistantBlob, message: CursorStoreFixture.assistantMessage(
                "Centered it.", model: "gpt-5.3-codex-xhigh"
            )),
            CursorStoreFixture.Blob(id: toolBlob, message: CursorStoreFixture.toolMessage())
        ]
    }

    // MARK: - Discovery

    func testEveryStoreUnderTheChatsRootIsDiscovered() throws {
        let first = try writeStore()
        let second = try CursorStoreFixture.write(
            home: home,
            agentID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            workspaceHash: "127502a760b74ac1c273356ea37f8ef4",
            card: ["agentId": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"],
            blobs: []
        )
        let found = Set(adapter.discoverSessionFiles(homeDirectory: home.path).map(SessionTestPaths.canonical))
        XCTAssertEqual(found, [SessionTestPaths.canonical(first), SessionTestPaths.canonical(second)])
        XCTAssertEqual(adapter.roots(homeDirectory: home.path).count, 1)
    }

    func testDiscoveryToleratesAMissingChatsDirectory() {
        XCTAssertTrue(adapter.discoverSessionFiles(homeDirectory: home.path).isEmpty)
    }

    // MARK: - Metadata

    func testMetadataComesFromTheHexCardAndTheBlobWalk() throws {
        let url = try writeStore()
        let summary = try adapter.extractMetadata(fileURL: url)

        XCTAssertEqual(summary.provider, .cursor)
        XCTAssertEqual(summary.harness, .cursor)
        XCTAssertEqual(summary.sessionID, agentID)
        XCTAssertEqual(summary.title, "Polish the showcase")
        XCTAssertEqual(summary.providerVariant, "default")
        XCTAssertEqual(summary.createdAt, Date(timeIntervalSince1970: 1_779_280_100.206))
        // The workspace URI is percent-encoded on the wire.
        XCTAssertEqual(summary.projectDir, "/Users/example/agents misc/showcase")
        XCTAssertEqual(summary.model, "gpt-5.3-codex-xhigh")
        XCTAssertEqual(summary.messageCount, 3)
        XCTAssertEqual(summary.sourcePath, url.path)
        XCTAssertGreaterThan(summary.sizeBytes, 0)
    }

    func testTheModelIsReadFromAnInlineMessageNodeToo() throws {
        let inline = CursorStoreFixture.BlobID(seed: 0x55)
        let blobs: [CursorStoreFixture.Blob] = [
            CursorStoreFixture.Blob(id: root, data: CursorStoreFixture.node(
                workspaceURI: "file:///Users/example/proj",
                references: [inline]
            )),
            CursorStoreFixture.Blob(id: inline, data: CursorStoreFixture.node(
                inlineMessage: CursorStoreFixture.assistantMessage("Done.", model: "gpt-5.3-codex-high")
            ))
        ]
        let summary = try adapter.extractMetadata(fileURL: try writeStore(blobs: blobs))
        XCTAssertEqual(summary.model, "gpt-5.3-codex-high")
        XCTAssertEqual(summary.messageCount, 1)
    }

    /// Short or aborted conversations record no model at all, and a row that
    /// says nothing is the correct answer — never a guess.
    func testASessionWithoutAModelKeepsItNil() throws {
        let blobs: [CursorStoreFixture.Blob] = [
            CursorStoreFixture.Blob(id: root, data: CursorStoreFixture.node(references: [userBlob])),
            CursorStoreFixture.Blob(id: userBlob, message: CursorStoreFixture.userMessage("Hello"))
        ]
        let summary = try adapter.extractMetadata(fileURL: try writeStore(blobs: blobs))
        XCTAssertNil(summary.model)
        XCTAssertNil(summary.projectDir)
    }

    func testAnUnnamedConversationFallsBackToAShortenedAgentID() throws {
        let summary = try adapter.extractMetadata(fileURL: try writeStore(card: card(name: nil)))
        XCTAssertEqual(summary.title, "Agent ef677032…")
    }

    func testAStoreWithoutAnAgentIDIsRejected() throws {
        let url = try CursorStoreFixture.write(
            home: home,
            agentID: agentID,
            card: ["latestRootBlobId": root.hex],
            blobs: []
        )
        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: url))
        XCTAssertTrue(adapter.discoverSessions(homeDirectory: home.path).isEmpty)
    }

    func testAMetaValueThatIsNotHexIsRejected() throws {
        let url = try CursorStoreFixture.write(
            home: home,
            agentID: agentID,
            metaValue: "not hex at all",
            blobs: []
        )
        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: url)) { error in
            guard case SessionParseError.unreadable = error else {
                return XCTFail("expected unreadable, got \(error)")
            }
        }
    }

    /// Cursor writes the card under key `'0'`, but the adapter reads the row
    /// rather than trusting the key, so a store that moved it still lists.
    func testTheCardIsFoundUnderAnyMetaKey() throws {
        let url = try CursorStoreFixture.write(
            home: home,
            agentID: agentID,
            card: card(),
            metaKey: "1",
            blobs: defaultBlobs
        )
        XCTAssertEqual(try adapter.extractMetadata(fileURL: url).sessionID, agentID)
    }

    func testAStoreInWALModeStillReads() throws {
        let url = try writeStore(walMode: true)
        XCTAssertEqual(try adapter.extractMetadata(fileURL: url).sessionID, agentID)
    }

    /// A reference the graph names but the store does not hold is skipped,
    /// not treated as a corrupt session.
    func testDanglingReferencesAreSkipped() throws {
        let missing = CursorStoreFixture.BlobID(seed: 0x66)
        let blobs: [CursorStoreFixture.Blob] = [
            CursorStoreFixture.Blob(id: root, data: CursorStoreFixture.node(
                references: [missing, userBlob]
            )),
            CursorStoreFixture.Blob(id: userBlob, message: CursorStoreFixture.userMessage("Still here"))
        ]
        XCTAssertEqual(try adapter.extractMetadata(fileURL: try writeStore(blobs: blobs)).messageCount, 1)
    }

    /// The graph is a merkle chain, so a node that points back at an
    /// ancestor is normal; the walk must not follow it twice.
    func testACycleInTheGraphTerminates() throws {
        let second = CursorStoreFixture.BlobID(seed: 0x77)
        let blobs: [CursorStoreFixture.Blob] = [
            CursorStoreFixture.Blob(id: root, data: CursorStoreFixture.node(
                references: [second, userBlob]
            )),
            CursorStoreFixture.Blob(id: second, data: CursorStoreFixture.node(references: [root])),
            CursorStoreFixture.Blob(id: userBlob, message: CursorStoreFixture.userMessage("Once"))
        ]
        XCTAssertEqual(try adapter.extractMetadata(fileURL: try writeStore(blobs: blobs)).messageCount, 1)
    }

    // MARK: - Transcript

    func testTranscriptKeepsUserAndAssistantTextInChainOrder() throws {
        let url = try writeStore()
        let document = try adapter.parseTranscript(fileURL: url, range: nil)

        XCTAssertEqual(document.messages.map(\.role), [.user, .assistant])
        // Reasoning parts and tool turns are dropped; only the reply text
        // is transcript.
        XCTAssertEqual(document.messages.map(\.text), ["Center the hero", "Centered it."])
        XCTAssertEqual(document.totalMessageCount, 2)
        XCTAssertFalse(document.truncated)
    }

    func testTranscriptHonorsARange() throws {
        let document = try adapter.parseTranscript(fileURL: try writeStore(), range: 0..<1)
        XCTAssertEqual(document.messages.map(\.text), ["Center the hero"])
        XCTAssertTrue(document.truncated)
        XCTAssertEqual(document.totalMessageCount, 2)
    }

    // MARK: - Deletion

    func testDeletionIsRefusedBecauseCursorOwnsTheStore() throws {
        let url = try writeStore()
        let summary = try adapter.extractMetadata(fileURL: url)
        XCTAssertThrowsError(try adapter.deletionPlan(for: summary, homeDirectory: home.path)) { error in
            XCTAssertEqual(error as? SessionDeleteError, .providerIsReadOnly(.cursor))
        }

        let outcomes = SessionDeleter(homeDirectory: home.path).delete(
            [summary], registry: .standard(homeDirectory: home.path)
        )
        XCTAssertEqual(outcomes.first?.success, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Helpers

    func testHexDecodingRejectsAnythingThatIsNotAnEvenRunOfHexDigits() {
        XCTAssertEqual(CursorSessionAdapter.hexDecoded("7b7d"), Data("{}".utf8))
        XCTAssertEqual(CursorSessionAdapter.hexDecoded("7B7D"), Data("{}".utf8))
        XCTAssertNil(CursorSessionAdapter.hexDecoded("7b7"))
        XCTAssertNil(CursorSessionAdapter.hexDecoded("zz"))
        XCTAssertNil(CursorSessionAdapter.hexDecoded(""))
    }

    func testFileURIsArePercentDecodedAndNonFileURIsRefused() {
        XCTAssertEqual(
            CursorSessionAdapter.path(fromFileURI: "file:///Users/example/a%20project"),
            "/Users/example/a project"
        )
        XCTAssertNil(CursorSessionAdapter.path(fromFileURI: "https://example.com/x"))
        XCTAssertNil(CursorSessionAdapter.path(fromFileURI: "/Users/example/plain"))
    }
}
