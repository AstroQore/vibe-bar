import XCTest
@testable import VibeBarCore

final class SessionDeleterTests: XCTestCase {
    private var home: URL!
    private var outside: URL!
    private let sessionID = "11111111-2222-3333-4444-555555555555"

    private var registry: SessionProviderRegistry { .standard(homeDirectory: home.path) }
    private var deleter: SessionDeleter { SessionDeleter(homeDirectory: home.path) }

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarSessionDeleterTests-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    // MARK: - Fixtures

    private func claudeLines(id: String) -> String {
        """
        {"type":"user","timestamp":"2026-01-01T00:00:01.000Z","sessionId":"\(id)",\
        "cwd":"/Users/example/proj","message":{"role":"user","content":"Prompt"}}
        """
    }

    @discardableResult
    private func writeClaudeSession(
        id: String? = nil,
        fileName: String? = nil,
        in directory: URL? = nil
    ) throws -> URL {
        let id = id ?? sessionID
        let target = try directory ?? claudeProjectDirectory()
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let url = target.appendingPathComponent(fileName ?? "\(id).jsonl")
        try (claudeLines(id: id) + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func claudeProjectDirectory() throws -> URL {
        let url = home.appendingPathComponent(".claude/projects/-Users-example-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func summary(for url: URL, id: String? = nil) -> SessionSummary {
        SessionSummary(provider: .claude, sessionID: id ?? sessionID, sourcePath: url.path)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Happy path

    func testDeletesTheSessionFile() throws {
        let url = try writeClaudeSession()
        let outcomes = deleter.delete([summary(for: url)], registry: registry)

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertTrue(outcomes[0].success)
        XCTAssertNil(outcomes[0].failureReason)
        XCTAssertFalse(exists(url))
    }

    func testSidecarDirectoryIsRemovedWithTheFile() throws {
        let url = try writeClaudeSession()
        let sidecar = url.deletingPathExtension()
        let nested = sidecar.appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "{}\n".write(to: nested.appendingPathComponent("agent-abc.jsonl"),
                         atomically: true, encoding: .utf8)

        XCTAssertTrue(deleter.delete([summary(for: url)], registry: registry)[0].success)
        XCTAssertFalse(exists(url))
        XCTAssertFalse(exists(sidecar))
    }

    func testGrokSessionDirectoryIsRemoved() throws {
        let sessionDir = home
            .appendingPathComponent(".grok/sessions/%2FUsers%2Fexample%2Fproj", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let summaryURL = sessionDir.appendingPathComponent("summary.json")
        try "{\"info\":{\"id\":\"\(sessionID)\",\"cwd\":\"/Users/example/proj\"}}"
            .write(to: summaryURL, atomically: true, encoding: .utf8)
        try "{\"type\":\"user\",\"content\":\"hi\"}\n".write(
            to: sessionDir.appendingPathComponent("chat_history.jsonl"),
            atomically: true, encoding: .utf8
        )

        let outcomes = deleter.delete(
            [SessionSummary(provider: .grok, sessionID: sessionID, sourcePath: summaryURL.path)],
            registry: registry
        )
        XCTAssertTrue(outcomes[0].success)
        XCTAssertFalse(exists(sessionDir))
    }

    // MARK: - Refusals

    func testContainmentEscapeThroughASymlinkedDirectoryIsBlocked() throws {
        // A link inside the provider root pointing at a tree the CLI
        // never wrote. Resolving the target lands outside every root.
        let planted = try writeClaudeSession(in: outside)
        let link = try claudeProjectDirectory().appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let reachable = link.appendingPathComponent(planted.lastPathComponent)
        let outcomes = deleter.delete([summary(for: reachable)], registry: registry)

        XCTAssertFalse(outcomes[0].success)
        XCTAssertEqual(outcomes[0].failureReason, .pathEscapesProviderRoot)
        XCTAssertTrue(exists(planted))
    }

    func testAbsolutePathOutsideEveryRootIsBlocked() throws {
        let planted = try writeClaudeSession(in: outside)
        let outcomes = deleter.delete([summary(for: planted)], registry: registry)

        XCTAssertEqual(outcomes[0].failureReason, .pathEscapesProviderRoot)
        XCTAssertTrue(exists(planted))
    }

    func testSymlinkedTargetIsRefusedEvenInsideTheRoot() throws {
        let real = try writeClaudeSession()
        let link = try claudeProjectDirectory()
            .appendingPathComponent("99999999-2222-3333-4444-555555555555.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let outcomes = deleter.delete([summary(for: link)], registry: registry)

        XCTAssertFalse(outcomes[0].success)
        XCTAssertEqual(outcomes[0].failureReason, .symlinkedTarget)
        XCTAssertTrue(exists(real))
        XCTAssertTrue(exists(link))
    }

    func testSessionIdMismatchAbortsTheDelete() throws {
        let url = try writeClaudeSession(id: sessionID, fileName: "rolled-over.jsonl")
        let stale = summary(for: url, id: "99999999-2222-3333-4444-555555555555")

        let outcomes = deleter.delete([stale], registry: registry)

        XCTAssertFalse(outcomes[0].success)
        XCTAssertEqual(outcomes[0].failureReason, .sessionIDMismatch)
        XCTAssertTrue(exists(url))
    }

    func testUnparsableValidationFileAbortsTheDelete() throws {
        let directory = try claudeProjectDirectory()
        let url = directory.appendingPathComponent("\(sessionID).jsonl")
        try Data().write(to: url)

        let outcomes = deleter.delete([summary(for: url)], registry: registry)

        XCTAssertEqual(outcomes[0].failureReason, .validationUnreadable)
        XCTAssertTrue(exists(url))
    }

    /// The three providers whose stores belong to another running app never
    /// reach the containment fence at all — their adapters refuse first, and
    /// each says which app to delete from instead.
    func testProvidersWhoseStoreAnotherAppOwnsAreRefused() {
        let paths: [SessionProvider: String] = [
            .antigravity: ".gemini/antigravity/conversations/\(sessionID).db",
            .cursor: ".cursor/chats/workspace/\(sessionID)/store.db",
            .claudeCowork: "Library/Application Support/Claude/local-agent-mode-sessions/"
                + "space/x/local_\(sessionID)/.claude/projects/-Users-example-proj/\(sessionID).jsonl"
        ]
        for (provider, path) in paths {
            XCTAssertFalse(provider.supportsDeletion, "\(provider) must not be deletable")
            let summary = SessionSummary(
                provider: provider,
                sessionID: sessionID,
                sourcePath: home.appendingPathComponent(path).path
            )
            let outcomes = deleter.delete([summary], registry: registry)

            XCTAssertFalse(outcomes[0].success)
            XCTAssertEqual(outcomes[0].failureReason, .providerIsReadOnly(provider))
        }
    }

    /// Every provider the registry does claim can plan a delete, and every
    /// one it refuses is exactly the read-only set.
    func testDeletabilityMatchesTheAdaptersThatPlan() {
        for provider in SessionProvider.allCases {
            XCTAssertNotNil(registry.adapter(for: provider), "\(provider) has no adapter")
        }
        XCTAssertEqual(
            Set(SessionProvider.allCases.filter { !$0.supportsDeletion }),
            [.antigravity, .cursor, .claudeCowork]
        )
    }

    // MARK: - Batch behavior

    func testBatchContinuesPastAFailureAndReportsPerItem() throws {
        let first = try writeClaudeSession(id: sessionID, fileName: "first.jsonl")
        let blocked = try writeClaudeSession(id: sessionID, fileName: "blocked.jsonl", in: outside)
        let third = try writeClaudeSession(id: sessionID, fileName: "third.jsonl")

        let outcomes = deleter.delete(
            [summary(for: first), summary(for: blocked), summary(for: third)],
            registry: registry
        )

        XCTAssertEqual(outcomes.map(\.success), [true, false, true])
        XCTAssertEqual(outcomes[1].failureReason, .pathEscapesProviderRoot)
        XCTAssertEqual(outcomes.map(\.summary.sourcePath),
                       [first.path, blocked.path, third.path],
                       "outcomes must line up with the input order")
        XCTAssertFalse(exists(first))
        XCTAssertTrue(exists(blocked))
        XCTAssertFalse(exists(third))
    }

    func testEmptyBatchIsANoOp() {
        XCTAssertTrue(deleter.delete([], registry: registry).isEmpty)
    }

    // MARK: - Containment helper

    func testContainmentRequiresStrictlyBelowARoot() throws {
        let root = try claudeProjectDirectory().deletingLastPathComponent()
        let roots = [root.path]

        XCTAssertTrue(SessionDeleter.isContained(root.appendingPathComponent("a/b.jsonl").path, in: roots))
        XCTAssertFalse(SessionDeleter.isContained(root.path, in: roots),
                       "the root itself must never be a removal target")
        XCTAssertFalse(SessionDeleter.isContained(root.path + "-sibling/x.jsonl", in: roots),
                       "a sibling sharing the prefix must not count as contained")
    }
}
