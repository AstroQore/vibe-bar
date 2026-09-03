import XCTest
@testable import VibeBarCore

/// The vocabulary `sessions.*` hands an agent: how a filter narrows, how a
/// session is named, and where a transcript window stops.
final class SessionAgentQueryTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_767_225_600)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarSessionAgentQuery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var scratchURL: URL { directory.appendingPathComponent("scratch", isDirectory: true) }

    private func summary(
        sessionID: String = "s-1",
        provider: SessionProvider = .codex,
        projectDir: String? = "/Users/example/Coding/vibe-bar",
        model: String? = "gpt-5-codex",
        lastActiveAt: Date? = nil,
        createdAt: Date? = nil
    ) -> SessionSummary {
        SessionSummary(
            provider: provider,
            sessionID: sessionID,
            model: model,
            title: "Bounded the transcript viewer",
            projectDir: projectDir,
            createdAt: createdAt ?? epoch,
            lastActiveAt: lastActiveAt ?? epoch,
            sourcePath: "/Users/example/.codex/sessions/\(sessionID).jsonl",
            sizeBytes: 4_096,
            messageCount: 12
        )
    }

    // MARK: - Filter semantics

    func testProjectDirIsACaseInsensitiveSubstring() {
        // Substring, not prefix — see `SessionQueryFilter.projectDir` for why
        // (the store's SQL is what keeps `totalCount` honest).
        var filter = SessionQueryFilter(projectDir: "vibe-bar")
        XCTAssertTrue(filter.matches(summary()))
        filter.projectDir = "VIBE-BAR"
        XCTAssertTrue(filter.matches(summary()), "matching must not depend on case")
        filter.projectDir = "/Users/example/Coding/vibe-bar"
        XCTAssertTrue(filter.matches(summary()), "a full path behaves as an exact match")
        filter.projectDir = "some-other-repo"
        XCTAssertFalse(filter.matches(summary()))
        // A session with no recorded project cannot satisfy a project filter.
        XCTAssertFalse(
            SessionQueryFilter(projectDir: "vibe-bar").matches(summary(projectDir: nil))
        )
    }

    func testModelsMatchExactlyAndCaseInsensitively() {
        XCTAssertTrue(SessionQueryFilter(models: ["GPT-5-Codex"]).matches(summary()))
        // A substring of a model id is not that model.
        XCTAssertFalse(SessionQueryFilter(models: ["gpt-5"]).matches(summary()))
        // Never inferred: a log that recorded no model matches no filter.
        XCTAssertFalse(SessionQueryFilter(models: ["gpt-5-codex"]).matches(summary(model: nil)))
    }

    func testTimeWindowIsInclusiveBelowAndExclusiveAbove() {
        let filter = SessionQueryFilter(from: epoch, to: epoch.addingTimeInterval(60))
        XCTAssertTrue(filter.matches(summary(lastActiveAt: epoch)))
        XCTAssertTrue(filter.matches(summary(lastActiveAt: epoch.addingTimeInterval(59))))
        XCTAssertFalse(filter.matches(summary(lastActiveAt: epoch.addingTimeInterval(60))))
        XCTAssertFalse(filter.matches(summary(lastActiveAt: epoch.addingTimeInterval(-1))))
    }

    func testATimeWindowRejectsASessionWithNoTimestampAtAll() {
        // "Unknown" is not "in range".
        let undated = SessionSummary(
            provider: .codex, sessionID: "s-2",
            createdAt: nil, lastActiveAt: nil,
            sourcePath: "/Users/example/.codex/sessions/s-2.jsonl", sizeBytes: 1, messageCount: 0
        )
        XCTAssertFalse(SessionQueryFilter(from: epoch).matches(undated))
        XCTAssertTrue(SessionQueryFilter().matches(undated), "an unfiltered query keeps it")
    }

    /// Which half of the filter the index can answer decides whether
    /// `totalCount` may be reported at all.
    func testOnlyToAndModelsForceTheHostSidePath() {
        XCTAssertTrue(SessionQueryFilter().isAnsweredEntirelyByTheIndex)
        XCTAssertTrue(
            SessionQueryFilter(
                providers: [.codex], harnesses: [.codex],
                projectDir: "vibe-bar", from: epoch
            ).isAnsweredEntirelyByTheIndex,
            "providers, harnesses, projectDir and from are all SQL clauses in the store"
        )
        XCTAssertFalse(SessionQueryFilter(to: epoch).isAnsweredEntirelyByTheIndex)
        XCTAssertFalse(SessionQueryFilter(models: ["gpt-5"]).isAnsweredEntirelyByTheIndex)
        XCTAssertTrue(
            SessionQueryFilter(models: []).isAnsweredEntirelyByTheIndex,
            "an empty model list narrows nothing here; the store already returns nothing for it"
        )
    }

    // MARK: - Locator

    func testACompositeIDParsesEvenWhenThePathHasColons() {
        let id = "codex:abc-123:/Users/example/odd:dir/rollout.jsonl"
        let locator = try? XCTUnwrap(SessionLocator.parse(compositeID: id))
        XCTAssertEqual(locator?.provider, .codex)
        XCTAssertEqual(locator?.sessionID, "abc-123")
    }

    func testARealSummaryIDRoundTripsThroughTheLocator() {
        let row = summary()
        let locator = SessionLocator.parse(compositeID: row.id)
        XCTAssertEqual(locator?.provider, row.provider)
        XCTAssertEqual(locator?.sessionID, row.sessionID)
    }

    func testNonsenseIDsAreRejectedRatherThanGuessed() {
        XCTAssertNil(SessionLocator.parse(compositeID: "not-a-provider:abc:/x"))
        XCTAssertNil(SessionLocator.parse(compositeID: "codex"))
        XCTAssertNil(SessionLocator.parse(compositeID: "codex::/x"))
    }

    // MARK: - Window slicing

    private func messages(_ count: Int, text: @escaping (Int) -> String = { "message \($0)" })
        -> [SessionMessage] {
        (0..<count).map {
            SessionMessage(
                seq: $0,
                role: $0.isMultiple(of: 2) ? .user : .assistant,
                text: text($0),
                timestamp: nil
            )
        }
    }

    private func window(
        _ request: TranscriptWindowRequest,
        in messages: [SessionMessage],
        reachedEndOfFile: Bool = true
    ) -> TranscriptWindow {
        SessionIndexingBounds.window(
            for: request,
            in: messages,
            reachedEndOfFile: reachedEndOfFile,
            bytesRead: 1_024,
            fileBytes: 1_024
        )
    }

    func testAroundCentresTheWindowOnTheMatch() {
        let result = window(TranscriptWindowRequest(around: 50, radius: 2), in: messages(100))
        XCTAssertEqual(result.messages.map(\.seq), [48, 49, 50, 51, 52])
        XCTAssertEqual(result.totalMessageCount, 100)
        XCTAssertEqual(result.nextFrom, 53)
        XCTAssertFalse(result.isTruncated)
    }

    func testAroundClampsAtTheStartOfTheSession() {
        let result = window(TranscriptWindowRequest(around: 1, radius: 5), in: messages(100))
        XCTAssertEqual(result.messages.map(\.seq), [0, 1, 2, 3, 4, 5, 6])
    }

    func testFromAndLimitPageForwardAndStopAtTheEnd() {
        let first = window(TranscriptWindowRequest(from: 0, limit: 3), in: messages(7))
        XCTAssertEqual(first.messages.map(\.seq), [0, 1, 2])
        XCTAssertEqual(first.nextFrom, 3)
        XCTAssertTrue(first.hasMore)

        let last = window(TranscriptWindowRequest(from: 6, limit: 3), in: messages(7))
        XCTAssertEqual(last.messages.map(\.seq), [6])
        XCTAssertNil(last.nextFrom, "the last page must not hand back a cursor")
        XCTAssertFalse(last.hasMore)
    }

    func testTheMessageLimitTruncatesAWideAroundWindowAndLeavesACursor() {
        let result = window(
            TranscriptWindowRequest(around: 50, radius: 40, limit: 10), in: messages(200)
        )
        XCTAssertEqual(result.messages.count, 10)
        XCTAssertEqual(result.messages.first?.seq, 10)
        XCTAssertEqual(result.nextFrom, 20)
        XCTAssertEqual(result.reasons, [.messageLimit])
        XCTAssertTrue(result.notice { "\($0) B" }?.contains("nextFrom") ?? false)
    }

    /// The failure this cap exists for: 200 tool-call outputs must come back
    /// as a truncated answer plus a cursor, not as a multi-megabyte payload.
    func testTheByteBudgetStopsAWindowOfHugeMessages() {
        let fat = messages(200) { _ in String(repeating: "x", count: 6_000) }
        let result = window(TranscriptWindowRequest(from: 0, limit: 200), in: fat)
        XCTAssertLessThan(result.messages.count, 200)
        let bytes = result.messages.reduce(0) { $0 + $1.text.utf8.count }
        XCTAssertLessThanOrEqual(bytes, TranscriptWindowRequest.maximumTextBytes)
        XCTAssertTrue(result.reasons.contains(.byteBudget))
        XCTAssertEqual(result.nextFrom, result.messages.count, "resume at the message that did not fit")
    }

    func testOneEnormousMessageIsClippedRatherThanFillingTheAnswer() {
        let huge = String(repeating: "y", count: 50_000)
        let result = window(
            TranscriptWindowRequest(from: 0, limit: 3),
            in: [
                SessionMessage(seq: 0, role: .tool, text: huge, timestamp: nil),
                SessionMessage(seq: 1, role: .user, text: "and then?", timestamp: nil)
            ]
        )
        XCTAssertEqual(result.messages.count, 2, "clipping one message must not drop the next")
        XCTAssertTrue(result.textTruncated[0])
        XCTAssertFalse(result.textTruncated[1])
        XCTAssertEqual(result.textBytes[0], 50_000, "the original size is still reported")
        XCTAssertLessThan(result.messages[0].text.count, huge.count)
        XCTAssertTrue(result.reasons.contains(.messageText))
    }

    func testEvenASingleOversizedMessageComesBack() {
        // A response of zero messages plus "the budget was full" is not an
        // answer, so the first message always goes through.
        let giant = String(repeating: "z", count: 400_000)
        let result = window(
            TranscriptWindowRequest(from: 0, limit: 5),
            in: [SessionMessage(seq: 0, role: .tool, text: giant, timestamp: nil)]
        )
        XCTAssertEqual(result.messages.count, 1)
        XCTAssertTrue(result.textTruncated[0])
    }

    func testRolesThinAWindowRatherThanExtendingIt() {
        // Only the user turns inside seq 0…5 — not "the next 3 user turns,
        // wherever they are".
        let result = window(
            TranscriptWindowRequest(from: 0, limit: 6, roles: [.user]), in: messages(100)
        )
        XCTAssertEqual(result.messages.map(\.seq), [0, 2, 4])
        XCTAssertTrue(result.messages.allSatisfy { $0.role == .user })
    }

    func testAWindowPastTheReadableRegionSaysSoAndOffersNoCursor() {
        // The escalating read stopped at its ceiling before reaching seq 5000.
        let result = window(
            TranscriptWindowRequest(around: 5_000, radius: 5),
            in: messages(1_200),
            reachedEndOfFile: false
        )
        XCTAssertTrue(result.messages.isEmpty)
        XCTAssertEqual(result.reasons, [.readCeiling])
        XCTAssertNil(result.nextFrom, "a cursor here would invite an identical retry forever")
        XCTAssertNil(result.totalMessageCount, "a prefix's count is not the log's count")
        XCTAssertTrue(result.notice { "\($0) B" }?.contains("bounded read") ?? false)
    }

    func testABoundedReadWithheldTheTotalButStillPages() {
        let result = window(
            TranscriptWindowRequest(from: 0, limit: 5), in: messages(1_200), reachedEndOfFile: false
        )
        XCTAssertEqual(result.messages.count, 5)
        XCTAssertNil(result.totalMessageCount)
        XCTAssertEqual(result.nextFrom, 5)
    }

    // MARK: - Escalating read

    private func codexLine(role: String, text: String) -> String {
        let payload: [String: Any] = [
            "type": "message",
            "role": role,
            "content": [["type": "input_text", "text": text]]
        ]
        let object: [String: Any] = ["type": "response_item", "payload": payload]
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    /// A message index cannot be turned into a byte offset without parsing,
    /// so reaching a deep message means growing the read. The point of the
    /// estimate is that it does not take log₂(file) attempts to get there.
    func testTheReadGrowsUntilItReachesTheRequestedMessage() throws {
        // ~500 messages of ~2 KB each, comfortably past a 1 MiB first read.
        let body = String(repeating: "context ", count: 250)
        let lines = (0..<500).map { codexLine(role: $0.isMultiple(of: 2) ? "user" : "assistant",
                                              text: "\(body) turn \($0)") }
        let fileURL = directory.appendingPathComponent("rollout-deep.jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: fileURL)
        XCTAssertGreaterThan(
            SessionParsing.fileSize(fileURL),
            SessionIndexingBounds.agentTranscriptInitialByteLimit,
            "the fixture has to be bigger than the first read for this to test anything"
        )

        let result = try SessionIndexingBounds.readTranscriptWindow(
            adapter: CodexSessionAdapter(homeDirectory: directory.path),
            fileURL: fileURL,
            request: TranscriptWindowRequest(around: 480, radius: 2),
            scratchDirectory: scratchURL
        )
        XCTAssertEqual(result.messages.map(\.seq), [478, 479, 480, 481, 482])
        XCTAssertTrue(result.messages[2].text.contains("turn 480"))
        // Nothing was cut: the window is exactly what was asked for.
        XCTAssertFalse(result.isTruncated)
        // But the read stopped the moment it had the window rather than
        // finishing the file, so it does not know how long the session is —
        // and says nil instead of reporting the prefix's count as the total.
        XCTAssertNil(result.totalMessageCount)
        XCTAssertNotNil(result.nextFrom, "there is more to read past this window")
        XCTAssertLessThan(result.bytesRead, result.fileBytes)
        XCTAssertTrue(
            (try? FileManager.default.contentsOfDirectory(atPath: scratchURL.path))?.isEmpty ?? true,
            "every head copy is scratch and must not outlive its parse"
        )
    }

    func testASmallSessionIsReadWholeInOneGo() throws {
        let lines = (0..<5).map { codexLine(role: "user", text: "turn \($0)") }
        let fileURL = directory.appendingPathComponent("rollout-small.jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: fileURL)

        let result = try SessionIndexingBounds.readTranscriptWindow(
            adapter: CodexSessionAdapter(homeDirectory: directory.path),
            fileURL: fileURL,
            request: TranscriptWindowRequest(from: 0, limit: 40),
            scratchDirectory: scratchURL
        )
        XCTAssertEqual(result.messages.count, 5)
        XCTAssertEqual(result.totalMessageCount, 5)
        XCTAssertNil(result.nextFrom)
        XCTAssertFalse(result.isTruncated)
    }

    func testTheCeilingBoundsTheReadRatherThanTheRequest() throws {
        let body = String(repeating: "context ", count: 250)
        let lines = (0..<500).map { codexLine(role: "user", text: "\(body) turn \($0)") }
        let fileURL = directory.appendingPathComponent("rollout-ceiling.jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: fileURL)

        // A ceiling far below what seq 480 needs: the answer is a refusal
        // with a reason, not a whole-file parse.
        let result = try SessionIndexingBounds.readTranscriptWindow(
            adapter: CodexSessionAdapter(homeDirectory: directory.path),
            fileURL: fileURL,
            request: TranscriptWindowRequest(around: 480, radius: 2),
            byteCeiling: 64 * 1024,
            scratchDirectory: scratchURL
        )
        XCTAssertTrue(result.reasons.contains(.readCeiling))
        XCTAssertNil(result.totalMessageCount)
        XCTAssertLessThanOrEqual(result.bytesRead, 64 * 1024)
        XCTAssertLessThan(result.bytesRead, result.fileBytes)
    }

    func testTheGrowthEstimateBeatsPlainDoubling() {
        // 100 messages in 1 MiB, and seq 900 wanted: doubling would offer
        // 2 MiB, the measured rate says ~10 MiB is what it actually takes.
        let read = SessionIndexingBounds.BoundedTranscript(
            document: TranscriptDocument(
                messages: (0..<100).map {
                    SessionMessage(seq: $0, role: .user, text: "x", timestamp: nil)
                },
                totalMessageCount: 100,
                truncated: true
            ),
            isHeadTruncated: true,
            fileByteSize: 100 * 1024 * 1024
        )
        let next = SessionIndexingBounds.nextByteLimit(
            after: 1024 * 1024, read: read, needed: 900
        )
        XCTAssertGreaterThan(next, 2 * 1024 * 1024, "doubling alone would take too many passes")
        XCTAssertLessThan(next, 32 * 1024 * 1024)
    }
}
