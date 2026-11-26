import SQLite3
import XCTest
@testable import VibeBarCore

/// Claude session titles: the desktop app's title wins, injected markup is
/// taken off a first-prompt title, the desktop metadata is read
/// incrementally, and the sync pass rewrites only rows that differ.
///
/// Every id, title and path here is synthetic.
final class ClaudeSessionTitlesTests: XCTestCase {
    private var directory: URL!
    private var root: URL { directory.appendingPathComponent("claude-code-sessions", isDirectory: true) }
    private var org: URL { root.appendingPathComponent("acct/org", isDirectory: true) }
    private var databaseURL: URL { directory.appendingPathComponent("session_index.sqlite3") }

    private let firstID = "11111111-1111-4111-8111-111111111111"
    private let secondID = "22222222-2222-4222-8222-222222222222"
    private let thirdID = "33333333-3333-4333-8333-333333333333"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSessionTitlesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: org, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Resolution

    func testDesktopTitleWins() {
        XCTAssertEqual(
            ClaudeSessionTitle.resolved(current: "fix the login page please", projectDir: "/Users/example/app",
                                        desktopTitle: "Login page fix"),
            "Login page fix"
        )
    }

    func testBlankDesktopTitleFallsBackToTranscriptTitle() {
        XCTAssertEqual(
            ClaudeSessionTitle.resolved(current: "fix it", projectDir: nil, desktopTitle: "   "),
            "fix it"
        )
    }

    func testTruncatedSystemReminderFallsBackToFolder() {
        XCTAssertEqual(
            ClaudeSessionTitle.resolved(current: "<system-reminder> The user started this session from",
                                        projectDir: "/Users/example/net-monitor", desktopTitle: nil),
            "net-monitor"
        )
    }

    func testClosedSystemReminderKeepsTheRest() {
        XCTAssertEqual(
            ClaudeSessionTitle.cleaned("<system-reminder>x</system-reminder> rename the tabs", projectDir: nil),
            "rename the tabs"
        )
    }

    func testPastedContentKeepsThePaste() {
        XCTAssertEqual(
            ClaudeSessionTitle.cleaned("<pasted_content id=\"ab12\"> we want to rebuild this product", projectDir: "/x/y"),
            "we want to rebuild this product"
        )
    }

    func testOrdinaryTitleUntouched() {
        XCTAssertEqual(ClaudeSessionTitle.cleaned("plain prompt <b>", projectDir: "/x/y"), "plain prompt <b>")
        XCTAssertNil(ClaudeSessionTitle.cleaned(nil, projectDir: "/x/y"))
    }

    // MARK: - Lookup

    func testLookupReadsBothTranscriptIDsAndRescansOnlyWhenStale() throws {
        try writeMetadata("local_a", cli: firstID, last: secondID, title: "Dashboard design")
        try writeMetadata("local_b", cli: thirdID, last: nil, title: nil)
        let lookup = ClaudeDesktopTitleLookup(root: root, minimumInterval: 60)
        let start = Date()

        let first = lookup.snapshot(now: start)
        XCTAssertEqual(first.titles[firstID], "Dashboard design")
        XCTAssertEqual(first.titles[secondID], "Dashboard design")
        XCTAssertNil(first.titles[thirdID])

        // Within the interval the disk is not looked at again.
        try writeMetadata("local_b", cli: thirdID, last: nil, title: "Late title",
                          modified: start.addingTimeInterval(5))
        XCTAssertEqual(lookup.snapshot(now: start.addingTimeInterval(10)).generation, first.generation)

        let later = lookup.snapshot(now: start.addingTimeInterval(61))
        XCTAssertEqual(later.titles[thirdID], "Late title")
        XCTAssertNotEqual(later.generation, first.generation)

        // Nothing moved: same generation.
        XCTAssertEqual(lookup.snapshot(now: start.addingTimeInterval(200)).generation, later.generation)
    }

    func testLookupMatchesSessionIDCaseInsensitively() throws {
        try writeMetadata("local_a", cli: firstID.uppercased(), last: nil, title: "Upper")
        let lookup = ClaudeDesktopTitleLookup(root: root, minimumInterval: 0)
        XCTAssertEqual(lookup.title(forSessionID: firstID), "Upper")
    }

    func testRepairLeavesOtherProvidersAlone() {
        let lookup = ClaudeDesktopTitleLookup(root: root, minimumInterval: 0)
        let codex = summary(provider: .codex, id: firstID, title: "<system-reminder> x")
        XCTAssertEqual(ClaudeTitleRepair.repaired(codex, lookup: lookup).title, "<system-reminder> x")
    }

    // MARK: - Sync

    func testSyncRewritesOnlyDifferingRows() throws {
        try makeIndex(rows: [
            (1, "claude", firstID, "first prompt text", "/Users/example/a"),
            (2, "claude", secondID, "Already right", "/Users/example/b"),
            (3, "claude", thirdID, "<system-reminder> injected", "/Users/example/c"),
            (4, "codex", firstID, "codex row", "/Users/example/d"),
        ])
        let titles = [firstID: "Desktop name", secondID: "Already right"]

        XCTAssertEqual(ClaudeTitleSync.run(databaseURL: databaseURL, titles: titles), 2)
        XCTAssertEqual(try titlesInIndex(), [
            1: "Desktop name", 2: "Already right", 3: "c", 4: "codex row",
        ])
        // Idempotent.
        XCTAssertEqual(ClaudeTitleSync.run(databaseURL: databaseURL, titles: titles), 0)
    }

    func testSyncWithoutIndexDoesNothing() {
        XCTAssertEqual(ClaudeTitleSync.run(databaseURL: databaseURL, titles: [firstID: "x"]), 0)
    }

    // MARK: - Fixtures

    private func writeMetadata(_ name: String, cli: String, last: String?, title: String?,
                               modified: Date? = nil) throws {
        var object: [String: Any] = ["cliSessionId": cli, "sessionId": "local_\(UUID().uuidString)"]
        if let last { object["lastAssistantCliSessionId"] = last }
        if let title { object["title"] = title }
        let url = org.appendingPathComponent("\(name).json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    private func summary(provider: SessionProvider, id: String, title: String?) -> SessionSummary {
        SessionSummary(
            provider: provider, sessionID: id, providerVariant: nil, harness: nil, model: nil,
            title: title, summary: nil, projectDir: "/Users/example/p", createdAt: nil,
            lastActiveAt: nil, sourcePath: "/Users/example/p/\(id).jsonl", sizeBytes: 0, messageCount: -1
        )
    }

    private func makeIndex(rows: [(Int64, String, String, String, String)]) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, """
            CREATE TABLE sessions (id INTEGER PRIMARY KEY, provider TEXT NOT NULL, session_id TEXT NOT NULL,
                title TEXT, project_dir TEXT, source_path TEXT NOT NULL DEFAULT '')
            """, nil, nil, nil), SQLITE_OK)
        for row in rows {
            let sql = "INSERT INTO sessions (id, provider, session_id, title, project_dir) VALUES (\(row.0), '\(row.1)', '\(row.2)', '\(row.3)', '\(row.4)')"
            XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        }
    }

    private func titlesInIndex() throws -> [Int64: String] {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "SELECT id, title FROM sessions", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var out: [Int64: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            out[sqlite3_column_int64(statement, 0)] = String(cString: sqlite3_column_text(statement, 1))
        }
        return out
    }
}
