import XCTest
@testable import VibeBarCore

final class SessionIndexingBoundsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarSessionIndexingBounds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var scratchURL: URL { directory.appendingPathComponent("scratch", isDirectory: true) }

    // MARK: - Document trimming

    func testTrimmedCapsMessagesByRoleAndStopsAtBudget() {
        let policy = SessionIndexExcerptPolicy(
            toolExcerptCharacters: 10,
            proseExcerptCharacters: 20,
            sessionExcerptBytes: 60
        )
        let document = TranscriptDocument(
            messages: [
                SessionMessage(seq: 0, role: .user, text: String(repeating: "u", count: 40), timestamp: nil),
                SessionMessage(seq: 1, role: .tool, text: String(repeating: "t", count: 40), timestamp: nil),
                SessionMessage(seq: 2, role: .assistant, text: "short", timestamp: nil),
                SessionMessage(seq: 3, role: .user, text: String(repeating: "z", count: 40), timestamp: nil)
            ],
            totalMessageCount: 4,
            truncated: false
        )

        let trimmed = SessionIndexingBounds.trimmed(document, policy: policy, headTruncated: false, provider: .claude)
        // user 40→21 ("…" included), tool 40→11, assistant 5; the fourth
        // message (21 bytes… the ellipsis is 3 UTF-8 bytes, so 20+3=23)
        // would push past the 60-byte budget and everything stops there.
        XCTAssertEqual(trimmed.messages.count, 3)
        XCTAssertEqual(trimmed.messages[0].text.count, 21)
        XCTAssertTrue(trimmed.messages[0].text.hasSuffix("…"))
        XCTAssertEqual(trimmed.messages[1].text.count, 11)
        XCTAssertEqual(trimmed.messages[2].text, "short")
        XCTAssertTrue(trimmed.truncated)
        XCTAssertEqual(trimmed.totalMessageCount, 4)
    }

    func testTrimmedLeavesCompliantDocumentAlone() {
        let document = TranscriptDocument(
            messages: [
                SessionMessage(seq: 0, role: .user, text: "hello", timestamp: nil),
                SessionMessage(seq: 1, role: .tool, text: "[Tool: ls]", timestamp: nil)
            ],
            totalMessageCount: 2,
            truncated: false
        )
        let trimmed = SessionIndexingBounds.trimmed(document, policy: .standard, headTruncated: false, provider: .claude)
        XCTAssertEqual(trimmed, document)
    }

    // MARK: - Head-bounded parsing

    private func codexLine(role: String, text: String) -> String {
        let payload: [String: Any] = [
            "type": "message",
            "role": role,
            "content": [["type": "input_text", "text": text]]
        ]
        let object: [String: Any] = ["type": "response_item", "payload": payload]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    func testOversizedCodexRolloutParsesHeadOnly() throws {
        // Two real messages; a head limit that ends inside the second line,
        // so only the first survives (the partial trailing line is skipped).
        let first = codexLine(role: "user", text: "alpha bravo charlie")
        let second = codexLine(role: "assistant", text: "delta echo foxtrot")
        let fileURL = directory.appendingPathComponent("rollout-big.jsonl")
        try Data((first + "\n" + second + "\n").utf8).write(to: fileURL)

        var policy = SessionIndexExcerptPolicy.standard
        policy.headParseByteLimit = Int64(first.utf8.count + 10)
        let adapter = BoundedSessionAdapter(
            inner: CodexSessionAdapter(homeDirectory: directory.path),
            policy: policy,
            scratchDirectory: scratchURL
        )

        let document = try adapter.parseTranscript(fileURL: fileURL, range: nil)
        XCTAssertEqual(document.messages.map(\.text), ["alpha bravo charlie"])
        XCTAssertTrue(document.truncated)

        // The head copy is scratch, and it must not outlive the parse.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: scratchURL.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testSmallRolloutParsesWholeFile() throws {
        let first = codexLine(role: "user", text: "alpha bravo charlie")
        let second = codexLine(role: "assistant", text: "delta echo foxtrot")
        let fileURL = directory.appendingPathComponent("rollout-small.jsonl")
        try Data((first + "\n" + second + "\n").utf8).write(to: fileURL)

        let adapter = BoundedSessionAdapter(
            inner: CodexSessionAdapter(homeDirectory: directory.path),
            policy: .standard,
            scratchDirectory: scratchURL
        )
        let document = try adapter.parseTranscript(fileURL: fileURL, range: nil)
        XCTAssertEqual(
            document.messages.map(\.text),
            ["alpha bravo charlie", "delta echo foxtrot"]
        )
        XCTAssertFalse(document.truncated)
    }

    func testExplicitRangeBypassesTheBounds() throws {
        // A viewer-shaped read (range != nil) must see the full text even
        // when it exceeds every indexing cap.
        let long = String(repeating: "verbose tool output ", count: 500)
        let line = codexLine(role: "assistant", text: long)
        let fileURL = directory.appendingPathComponent("rollout-view.jsonl")
        try Data((line + "\n").utf8).write(to: fileURL)

        var policy = SessionIndexExcerptPolicy.standard
        policy.proseExcerptCharacters = 10
        let adapter = BoundedSessionAdapter(
            inner: CodexSessionAdapter(homeDirectory: directory.path),
            policy: policy,
            scratchDirectory: scratchURL
        )
        let document = try adapter.parseTranscript(fileURL: fileURL, range: 0..<1)
        XCTAssertEqual(document.messages.first?.text, long)
    }

    // MARK: - The viewer's own bound

    func testStandardHeadLimitStaysWellAboveTheExcerptBudget() {
        // The head copy exists to bound *memory*, and the excerpt budget is
        // what it feeds; 64 MiB was two orders of magnitude past saturation.
        let policy = SessionIndexExcerptPolicy.standard
        XCTAssertEqual(policy.headParseByteLimit, 8 * 1024 * 1024)
        XCTAssertGreaterThan(policy.headParseByteLimit, Int64(policy.sessionExcerptBytes) * 16)
        // The viewer reads more than the indexer, and still not the file.
        XCTAssertGreaterThan(
            SessionIndexingBounds.viewerHeadParseByteLimit,
            policy.headParseByteLimit
        )
    }

    func testReadTranscriptBoundsALargeLogAndReportsIt() throws {
        let first = codexLine(role: "user", text: "alpha bravo charlie")
        let second = codexLine(role: "assistant", text: "delta echo foxtrot")
        let fileURL = directory.appendingPathComponent("rollout-viewer.jsonl")
        let contents = first + "\n" + second + "\n"
        try Data(contents.utf8).write(to: fileURL)

        let read = try SessionIndexingBounds.readTranscript(
            adapter: CodexSessionAdapter(homeDirectory: directory.path),
            fileURL: fileURL,
            headByteLimit: Int64(first.utf8.count + 10),
            scratchDirectory: scratchURL
        )
        XCTAssertTrue(read.isHeadTruncated)
        XCTAssertTrue(read.document.truncated)
        XCTAssertEqual(read.document.messages.map(\.text), ["alpha bravo charlie"])
        XCTAssertEqual(read.fileByteSize, Int64(contents.utf8.count))
        // Full text, unlike the indexing path: the viewer applies no excerpt
        // trim at all, only the byte bound.
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: scratchURL.path))?.isEmpty ?? true)
    }

    func testReadTranscriptWithNoLimitReadsTheWholeFile() throws {
        let first = codexLine(role: "user", text: "alpha bravo charlie")
        let second = codexLine(role: "assistant", text: "delta echo foxtrot")
        let fileURL = directory.appendingPathComponent("rollout-whole.jsonl")
        try Data((first + "\n" + second + "\n").utf8).write(to: fileURL)

        let read = try SessionIndexingBounds.readTranscript(
            adapter: CodexSessionAdapter(homeDirectory: directory.path),
            fileURL: fileURL,
            headByteLimit: nil,
            scratchDirectory: scratchURL
        )
        XCTAssertFalse(read.isHeadTruncated)
        XCTAssertFalse(read.document.truncated)
        XCTAssertEqual(
            read.document.messages.map(\.text),
            ["alpha bravo charlie", "delta echo foxtrot"]
        )
    }

    func testHeadBoundNeverAppliesToAStoreThatCannotBeCutAtAnOffset() {
        // A SQLite or protobuf store truncated at a byte offset is not a
        // shorter session, it is a corrupt one.
        for provider in SessionProvider.allCases
        where !SessionIndexingBounds.headTruncatableProviders.contains(provider) {
            XCTAssertFalse(
                SessionIndexingBounds.headTruncatableProviders.contains(provider),
                "\(provider.rawValue) must not be head-truncated"
            )
        }
        XCTAssertEqual(
            SessionIndexingBounds.headTruncatableProviders,
            [.codex, .claude, .claudeCowork]
        )
    }

    // MARK: - Maintenance gate

    func testMaintenanceGateRefusesASecondClaimUntilItIsReleased() async {
        let gate = SessionIndexMaintenanceGate()
        let firstClaim = await gate.tryAcquire()
        XCTAssertTrue(firstClaim, "a free gate is claimable")
        let secondClaim = await gate.tryAcquire()
        XCTAssertFalse(secondClaim, "a held gate refuses the maintenance pass")
        await gate.release()
        let afterRelease = await gate.tryAcquire()
        XCTAssertTrue(afterRelease, "release hands the gate back")
        await gate.release()
    }

    func testMaintenanceGateMakesAWaiterRunAfterTheHolder() async {
        // `acquire` is the refresh side: it waits rather than skipping.
        let gate = SessionIndexMaintenanceGate()
        await gate.acquire()
        let order = OrderRecorder()

        let waiter = Task {
            await gate.acquire()
            await order.append("second")
            await gate.release()
        }
        // Give the waiter a chance to park on the gate before releasing.
        try? await Task.sleep(for: .milliseconds(50))
        await order.append("first")
        await gate.release()
        await waiter.value

        let recorded = await order.entries
        XCTAssertEqual(recorded, ["first", "second"])
    }

    private actor OrderRecorder {
        var entries: [String] = []
        func append(_ value: String) { entries.append(value) }
    }

    func testBoundedRegistryKeepsProvidersAndOrder() {
        let registry = SessionProviderRegistry.standard(homeDirectory: directory.path)
        let bounded = SessionIndexingBounds.boundedRegistry(
            registry,
            scratchDirectory: scratchURL
        )
        XCTAssertEqual(bounded.providers, registry.providers)
        XCTAssertTrue(bounded.adapters.allSatisfy { $0 is BoundedSessionAdapter })
    }
    func testCodexIDEEnvelopeIsStrippedBeforeTheCap() {
        // Kilobytes of editor context ahead of the marker: a raw-text cap
        // would cut both the marker and the request away and the index
        // would only ever see the context prefix.
        let context = "# Context from my IDE setup:\n" + String(repeating: "x", count: 5_000)
        let raw = context + "\n## My request for Codex:\nfind the flaky retry test"
        let document = TranscriptDocument(
            messages: [SessionMessage(seq: 0, role: .user, text: raw, timestamp: nil)],
            totalMessageCount: 1,
            truncated: false
        )
        let trimmed = SessionIndexingBounds.trimmed(
            document, policy: .standard, headTruncated: false, provider: .codex
        )
        XCTAssertTrue(
            trimmed.messages.first?.text.contains("find the flaky retry test") ?? false,
            "the user's actual request must survive the excerpt cap"
        )
        XCTAssertFalse(trimmed.messages.first?.text.hasPrefix("xxxx") ?? true)
    }
}
