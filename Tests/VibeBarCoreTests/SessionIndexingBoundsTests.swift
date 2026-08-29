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

        let trimmed = SessionIndexingBounds.trimmed(document, policy: policy, headTruncated: false)
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
        let trimmed = SessionIndexingBounds.trimmed(document, policy: .standard, headTruncated: false)
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

    func testBoundedRegistryKeepsProvidersAndOrder() {
        let registry = SessionProviderRegistry.standard(homeDirectory: directory.path)
        let bounded = SessionIndexingBounds.boundedRegistry(
            registry,
            scratchDirectory: scratchURL
        )
        XCTAssertEqual(bounded.providers, registry.providers)
        XCTAssertTrue(bounded.adapters.allSatisfy { $0 is BoundedSessionAdapter })
    }
}
