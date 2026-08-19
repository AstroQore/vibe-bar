import XCTest
@testable import VibeBarCore

final class GrokBotSessionAdapterTests: XCTestCase {
    private var home: URL!
    private let adapter = GrokBotSessionAdapter()

    /// A `%` on purpose: the real client's account ids are not plain
    /// identifiers, and the key parser has to keep accepting them.
    private let account = "acct%SYNTHETIC1"
    private let scout = "11111111-2222-3333-4444-555555555555"
    private let archivist = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private let orphan = "99999999-8888-7777-6666-555555555555"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarGrokBotAdapterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private var storeDirectory: URL {
        home.appendingPathComponent(GrokBotSessionAdapter.storeRelativePath, isDirectory: true)
    }

    // MARK: - Fixtures

    /// Writes a blob under the base32 of `key`, the way the client names it.
    @discardableResult
    private func writeBlob(key: String, json: String) throws -> URL {
        let url = storeDirectory
            .appendingPathComponent(Base32TestEncoder.encode(key))
            .appendingPathExtension("blob")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func transcriptKey(_ botID: String) -> String {
        "sand.client.slice.account.\(account).transcript.replicas.\(botID)"
    }

    @discardableResult
    private func writeRoster() throws -> URL {
        let json = """
        {"schemaVersion":2,"value":{"rows":[
        {"id":"\(scout)","name":"Scout","title":"","description":"Watches the release feed.",
         "createdAt":1767225600000,"updatedAt":1767229200000,"lastActivityAt":1767229200000,
         "lastViewedAt":1767229200000,"path":"/home/box/sand-data/agents/\(scout)/state",
         "isGroup":false,"memberIds":[],"conversationPartnerIds":["\(archivist)"],
         "origin":"user","hasUnread":false,"unreadCount":0,"isHiddenFromSidebar":false},
        {"id":"\(archivist)","name":"Archivist","title":"","description":"",
         "createdAt":1767139200000,"updatedAt":1767142800000,"lastActivityAt":1767142800000,
         "path":"/home/box/sand-data/agents/\(archivist)/state","isGroup":false,
         "memberIds":[],"conversationPartnerIds":["\(scout)"],"origin":"user"},
        {"id":"cccccccc-dddd-eeee-ffff-000000000000","name":"Never Opened","title":"",
         "description":"","createdAt":1767000000000,"lastActivityAt":1767000000000,
         "path":"/home/box/sand-data/agents/x/state","origin":"user"}
        ]}}
        """
        return try writeBlob(key: "sand.client.slice.account.\(account).roster.last-roster", json: json)
    }

    /// Scout's replica: one of every entry kind the client writes.
    @discardableResult
    private func writeScoutReplica() throws -> URL {
        let json = """
        {"schemaVersion":1,"value":{"persistedAt":1767229200000,"epochHint":3,
        "acceptedSequenceHint":9,"entries":[
        {"kind":"message","id":"t1u","role":"user","content":"Summarize today's releases.",
         "isStreaming":false,"timestampMs":1767225660000},
        {"kind":"send-message","id":"t1s1","timestampMs":1767225720000,
         "message":{"type":"text","content":"Three releases landed."}},
        {"kind":"message","id":"t2u","role":"user","content":"Anything for the changelog?",
         "isStreaming":false,"timestampMs":1767225780000,
         "fromAgent":{"id":"\(archivist)","name":"Archivist"}},
        {"kind":"message","id":"t2a","role":"assistant","content":"Only the release notes.",
         "isStreaming":false,"timestampMs":1767225840000,
         "toAgent":{"id":"\(archivist)","name":"Archivist","kind":"agent"}},
        {"kind":"event","id":"event-1","timestampMs":1767225900000,
         "event":{"type":"name-changed","from":"Watcher","to":"Scout"}},
        {"kind":"user-attachment","id":"att-1","file_name":"notes.png","file_path":"/tmp/notes.png",
         "width":10,"height":10,"byteSize":42},
        {"kind":"send-message","id":"t3s","timestampMs":1767225960000,
         "message":{"type":"widget","widget":{"kind":"poll"}}}
        ]}}
        """
        return try writeBlob(key: transcriptKey(scout), json: json)
    }

    @discardableResult
    private func writeArchivistReplica() throws -> URL {
        let json = """
        {"schemaVersion":1,"value":{"persistedAt":1767142800000,"entries":[
        {"kind":"message","id":"a1u","role":"user","content":"Index the archive.",
         "isStreaming":false,"timestampMs":1767139260000},
        {"kind":"send-message","id":"a1s","timestampMs":1767139320000,
         "message":{"type":"text","content":"Indexed 40 documents."}}
        ]}}
        """
        return try writeBlob(key: transcriptKey(archivist), json: json)
    }

    /// A replica whose bot the roster never mentions, plus the two files the
    /// scan has to walk past: client state under the same prefix, and a
    /// transcript blob holding something that is not a replica.
    private func writeNoise() throws {
        try writeBlob(
            key: transcriptKey(orphan),
            json: """
            {"schemaVersion":1,"value":{"entries":[
            {"kind":"message","id":"o1","role":"user","content":"Who am I talking to?",
             "isStreaming":false,"timestampMs":1767300000000}]}}
            """
        )
        try writeBlob(
            key: "sand.client.slice.account.\(account).ui-layout",
            json: #"{"schemaVersion":1,"value":{"sidebarWidth":320}}"#
        )
        try writeBlob(key: transcriptKey("77777777-6666-5555-4444-333333333333"), json: "not json {")
        // The client leaves a non-base32 marker file in the same directory.
        try Data().write(to: storeDirectory.appendingPathComponent(".migrated-from-local-storage"))
    }

    private func summary(for botID: String) throws -> SessionSummary {
        let summaries = adapter.discoverSessions(homeDirectory: home.path)
        return try XCTUnwrap(summaries.first { $0.sessionID == botID })
    }

    // MARK: - Discovery

    func testDiscoveryFindsOneSessionPerTranscriptReplica() throws {
        try writeRoster()
        try writeScoutReplica()
        try writeArchivistReplica()
        try writeNoise()

        // Four blobs decode to a transcript key, so four are candidates: the
        // roster, the layout slice and the marker file never were.
        XCTAssertEqual(adapter.discoverSessionFiles(homeDirectory: home.path).count, 4)
        // The one holding invalid JSON drops out here rather than sinking the
        // sweep.
        let summaries = adapter.discoverSessions(homeDirectory: home.path)
        XCTAssertEqual(Set(summaries.map(\.sessionID)), [scout, archivist, orphan])
    }

    func testAMissingStoreIsEmptyRatherThanAFailure() throws {
        try FileManager.default.removeItem(at: storeDirectory)
        XCTAssertEqual(adapter.roots(homeDirectory: home.path).count, 1)
        XCTAssertTrue(adapter.discoverSessionFiles(homeDirectory: home.path).isEmpty)
        XCTAssertTrue(adapter.discoverSessions(homeDirectory: home.path).isEmpty)
    }

    func testTheStoreRootIsTheGrokBotApplicationSupportDirectory() {
        let root = adapter.roots(homeDirectory: "/Users/example").first
        XCTAssertEqual(
            root?.path,
            "/Users/example/Library/Application Support/Grok Bot/sand-client-persistence"
        )
    }

    // MARK: - Keys

    func testOnlyTranscriptKeysAreClaimed() {
        let url = { (key: String) in
            URL(fileURLWithPath: "/store/\(Base32TestEncoder.encode(key)).blob")
        }
        XCTAssertEqual(
            GrokBotSessionAdapter.transcriptKey(at: url(transcriptKey(scout))),
            GrokBotSessionAdapter.TranscriptKey(accountID: account, botID: scout)
        )
        for other in [
            "sand.client.slice.account.\(account).roster.last-roster",
            "sand.client.slice.account.\(account).composer-drafts",
            "sand.client.slice.ui-layout",
            "sand.client.slice.account.\(account).transcript.replicas.",
            // A bot id that is not an identifier never becomes a session id.
            "sand.client.slice.account.\(account).transcript.replicas.../../etc/passwd"
        ] {
            XCTAssertNil(GrokBotSessionAdapter.transcriptKey(at: url(other)), other)
        }
        // Not base32 at all, and base32 of something else entirely.
        XCTAssertNil(GrokBotSessionAdapter.transcriptKey(
            at: URL(fileURLWithPath: "/store/not-base32!.blob")
        ))
        XCTAssertNil(GrokBotSessionAdapter.transcriptKey(at: url(transcriptKey(scout))
            .deletingPathExtension()))
    }

    // MARK: - Metadata

    func testMetadataTakesItsNameAndClocksFromTheRosterRow() throws {
        try writeRoster()
        try writeScoutReplica()
        let summary = try summary(for: scout)

        XCTAssertEqual(summary.provider, .grokBot)
        XCTAssertEqual(summary.harness, .grokBot)
        XCTAssertEqual(summary.effectiveHarness.displayName, "Grok Bot")
        XCTAssertEqual(summary.providerVariant, "bot")
        XCTAssertEqual(summary.title, "Scout")
        XCTAssertEqual(summary.summary, "→ Archivist: Only the release notes.")
        XCTAssertEqual(summary.createdAt, Date(timeIntervalSince1970: 1_767_225_600))
        // Five conversation entries — four with text plus the widget turn
        // that carries none. The rename event and the attachment are not
        // conversation and do not count.
        XCTAssertEqual(summary.messageCount, 5)
        // Cloud-side: no model, and the roster's `path` is remote.
        XCTAssertNil(summary.model)
        XCTAssertNil(summary.projectDir)
        XCTAssertGreaterThan(summary.sizeBytes, 0)
    }

    /// The roster and the transcript are two clocks that disagree in both
    /// directions — the roster lags a live conversation, and it also records
    /// activity (a rename) that leaves no entry behind.
    func testLastActiveTakesWhicheverClockIsLater() throws {
        try writeRoster()
        try writeScoutReplica()
        try writeArchivistReplica()
        // Roster: 1767229200000. Newest entry: 1767225960000.
        XCTAssertEqual(
            try summary(for: scout).lastActiveAt,
            Date(timeIntervalSince1970: 1_767_229_200)
        )
        // Archivist's roster row stops at 1767142800000 while its newest
        // entry is older still, so the roster wins there too.
        XCTAssertEqual(
            try summary(for: archivist).lastActiveAt,
            Date(timeIntervalSince1970: 1_767_142_800)
        )
    }

    func testASessionWithNoRosterRowFallsBackToItsFirstPrompt() throws {
        try writeRoster()
        try writeNoise()
        let summary = try summary(for: orphan)

        XCTAssertEqual(summary.title, "Who am I talking to?")
        XCTAssertEqual(summary.createdAt, Date(timeIntervalSince1970: 1_767_300_000))
        XCTAssertEqual(summary.lastActiveAt, Date(timeIntervalSince1970: 1_767_300_000))
    }

    /// No roster at all is a store that still lists — the names are simply
    /// missing.
    func testAMissingRosterDoesNotSinkTheScan() throws {
        try writeScoutReplica()
        let summary = try summary(for: scout)
        XCTAssertEqual(summary.title, "Summarize today's releases.")
    }

    func testAMalformedReplicaIsRejectedRatherThanReturnedEmpty() throws {
        let url = try writeBlob(key: transcriptKey(scout), json: "not json {")
        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: url))
        XCTAssertThrowsError(try adapter.parseTranscript(fileURL: url, range: nil))
    }

    func testAFileOutsideTheKeyNamespaceIsRejectedAsTheWrongFormat() throws {
        let url = try writeBlob(
            key: "sand.client.slice.account.\(account).ui-layout",
            json: #"{"schemaVersion":1,"value":{"entries":[]}}"#
        )
        XCTAssertThrowsError(try adapter.extractMetadata(fileURL: url)) { error in
            guard case .invalidFormat = error as? SessionParseError else {
                return XCTFail("expected invalidFormat, got \(error)")
            }
        }
    }

    // MARK: - Transcript

    /// Read from the transcript owner's point of view: `send-message` is the
    /// bot talking, an inbound `fromAgent` turn is another bot prompting it,
    /// and an `assistant` turn with a `toAgent` is this bot answering that
    /// other bot — the same string the other bot's replica stores inbound.
    func testTranscriptRolesFollowTheBotsPointOfView() throws {
        try writeRoster()
        let url = try writeScoutReplica()
        let document = try adapter.parseTranscript(fileURL: url, range: nil)

        XCTAssertEqual(document.messages.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(document.messages.map(\.text), [
            "Summarize today's releases.",
            "Three releases landed.",
            "Archivist: Anything for the changelog?",
            "→ Archivist: Only the release notes."
        ])
        XCTAssertEqual(document.messages.map(\.seq), [0, 1, 2, 3])
        XCTAssertEqual(document.totalMessageCount, 4)
        XCTAssertFalse(document.truncated)
        XCTAssertEqual(
            document.messages.first?.timestamp,
            Date(timeIntervalSince1970: 1_767_225_660)
        )
    }

    /// Both halves of an agent-to-agent exchange are `.user` / `.assistant`
    /// rather than `.other`, because those are the only two roles the search
    /// index keeps — a cross-bot conversation that could not be searched
    /// would be the largest silent hole in this provider.
    func testAgentTurnsSurviveTheSearchExcerptFilter() throws {
        let url = try writeScoutReplica()
        let document = try adapter.parseTranscript(fileURL: url, range: nil)
        let excerpts = SessionIndexService.excerpts(from: document, provider: .grokBot)

        XCTAssertEqual(excerpts.count, 4)
        XCTAssertTrue(excerpts.contains { $0.excerpt.contains("Anything for the changelog?") })
        XCTAssertTrue(excerpts.contains { $0.excerpt.contains("Only the release notes.") })
    }

    func testTranscriptSlicesByRange() throws {
        let url = try writeScoutReplica()
        let document = try adapter.parseTranscript(fileURL: url, range: 1..<3)

        XCTAssertEqual(document.messages.map(\.seq), [1, 2])
        XCTAssertEqual(document.totalMessageCount, 4)
        XCTAssertTrue(document.truncated)
    }

    // MARK: - Read-only

    func testDeletionIsRefusedWithAMessageNamingTheOwningApp() throws {
        try writeRoster()
        try writeScoutReplica()
        let summary = try summary(for: scout)
        let registry = SessionProviderRegistry.standard(homeDirectory: home.path)

        XCTAssertFalse(SessionProvider.grokBot.supportsDeletion)
        XCTAssertThrowsError(try adapter.deletionPlan(for: summary, homeDirectory: home.path)) { error in
            XCTAssertEqual(error as? SessionDeleteError, .providerIsReadOnly(.grokBot))
        }

        let outcomes = SessionDeleter(homeDirectory: home.path).delete([summary], registry: registry)
        XCTAssertEqual(outcomes.first?.success, false)
        XCTAssertEqual(outcomes.first?.failureReason, .providerIsReadOnly(.grokBot))
        XCTAssertEqual(
            SessionDeleteError.providerIsReadOnly(.grokBot).message,
            "Grok Bot sessions are the app's own cloud cache; manage them in Grok Bot."
        )
        // Refused means untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: summary.sourcePath))
    }

    func testThereIsNoResumeCommand() {
        XCTAssertThrowsError(
            try SessionResumeCommandBuilder.command(provider: .grokBot, sessionID: scout)
        ) { error in
            XCTAssertEqual(error as? SessionResumeError, .resumeUnavailable)
        }
    }

    // MARK: - Wiring

    func testTheStandardRegistryCarriesTheAdapter() {
        let registry = SessionProviderRegistry.standard(homeDirectory: home.path)
        XCTAssertTrue(registry.adapter(for: .grokBot) is GrokBotSessionAdapter)
        XCTAssertEqual(SessionProvider.grokBot.defaultHarness, .grokBot)
        XCTAssertEqual(SessionProvider.grokBot.displayName, "Grok Bot")
    }

    /// The Sessions filter row groups harnesses under their L1 company, and
    /// Grok Bot belongs to SpaceXAI — after Cursor, the harness whose quota
    /// bucket it rides in on.
    func testGrokBotJoinsTheSpaceXAIChipGroupAfterCursor() {
        let group = Harness.chipGroups(companies: ToolType.coreProviderRepresentatives)
            .first { $0.company == .grok }
        XCTAssertEqual(group?.harnesses, [.grokBuild, .cursor, .grokBot])
        XCTAssertEqual(Harness.grokBot.companyName, "SpaceXAI")
    }

    /// End to end through the index the MCP `sessions.*` tools read from:
    /// a Grok Bot conversation lists, counts, and is full-text searchable —
    /// including the half of it that another bot said.
    func testTheIndexListsCountsAndSearchesGrokBotSessions() async throws {
        try writeRoster()
        try writeScoutReplica()
        try writeArchivistReplica()

        let store = try SessionIndexStore(url: home.appendingPathComponent("session_index.sqlite3"))
        let service = SessionIndexService(
            homeDirectory: home.path,
            store: store,
            registry: SessionProviderRegistry.standard(homeDirectory: home.path),
            bodyIndexing: { true }
        )
        await service.refreshIndex()

        let summaries = try await store.allSummaries()
        XCTAssertEqual(Set(summaries.map(\.provider)), [.grokBot])
        let providerCounts = try await store.providerCounts()
        let harnessCounts = try await store.harnessCounts()
        let page = try await store.summaryPage(harnesses: [.grokBot])
        XCTAssertEqual(providerCounts[.grokBot], 2)
        XCTAssertEqual(harnessCounts[.grokBot], 2)
        XCTAssertEqual(page.summaries.compactMap(\.title).sorted(), ["Archivist", "Scout"])

        let hits = try await store.search(text: "changelog", providers: [.grokBot])
        XCTAssertEqual(hits.map(\.summary.sessionID), [scout])
        XCTAssertEqual(hits.first?.summary.effectiveHarness, .grokBot)
    }

    /// Grok Bot has no local tokens at all, so it must not become a default
    /// harness for any tool the cost scanner writes rows for.
    func testGrokBotIsNeverADefaultCostHarness() {
        for tool in ToolType.allCases {
            XCTAssertNotEqual(Harness.defaultHarness(for: tool), .grokBot, "\(tool)")
        }
    }
}
