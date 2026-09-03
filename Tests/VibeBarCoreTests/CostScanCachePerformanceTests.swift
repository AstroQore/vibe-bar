import XCTest
@testable import VibeBarCore

/// Covers the scan-cache changes made to stop the cost scan re-parsing every
/// session file on every pass:
///
/// - an oversized cache file is still *used* (the 64 MB rejection turned a
///   large history into a permanent re-parse loop),
/// - the cache only writes itself back when something actually changed,
/// - the warm in-memory copy is reused across passes but yields to the file
///   whenever the file no longer matches what the copy came from,
/// - a codex file that could not be read is not cached as "empty" against its
///   live fingerprint.
final class CostScanCachePerformanceTests: XCTestCase {
    private func makeTempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarScanCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func event(_ date: Date) -> CostUsageScanCache.ParsedEvent {
        CostUsageScanCache.ParsedEvent(
            date: date,
            model: "gpt-5",
            input: 100,
            output: 20,
            cache: 0
        )
    }

    override func tearDown() {
        CostUsageScanCacheStore.shared.forget()
        super.tearDown()
    }

    // MARK: - A1: size

    func testLoadKeepsACacheLargerThanTheOldSixtyFourMegabyteCap() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // Padding a cached model name is the cheapest way to get a genuinely
        // oversized file without synthesising millions of events.
        let padded = String(repeating: "m", count: 65 * 1024 * 1024)
        var cache = CostUsageScanCache()
        cache.store(
            [CostUsageScanCache.ParsedEvent(
                date: Date(timeIntervalSince1970: 1_700_000_000),
                model: padded,
                input: 1,
                output: 1,
                cache: 0
            )],
            for: "/Users/example/.codex/sessions/a.jsonl",
            mtime: Date(timeIntervalSince1970: 1_700_000_000),
            size: 10
        )
        cache.save(homeDirectory: home.path, tool: .codex)

        let url = CostUsageScanCache.fileURL(homeDirectory: home.path, tool: .codex)
        let size = try XCTUnwrap(
            (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        )
        XCTAssertGreaterThan(size, CostUsageScanCache.largeFileWarningBytes)

        let loaded = CostUsageScanCache.load(homeDirectory: home.path, tool: .codex)
        XCTAssertEqual(loaded.entries.count, 1, "an oversized cache must still be reused")
    }

    // MARK: - A3: dirty tracking

    func testCacheIsCleanUntilSomethingChanges() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = "/Users/example/.codex/sessions/a.jsonl"
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)

        var cache = CostUsageScanCache()
        XCTAssertFalse(cache.dirty)
        cache.store([event(mtime)], for: path, mtime: mtime, size: 42)
        XCTAssertTrue(cache.dirty)
        cache.saveIfDirty(homeDirectory: home.path, tool: .codex)
        XCTAssertFalse(cache.dirty)

        // A reuse that changes nothing must not mark the cache dirty, which
        // is what lets a steady-state pass skip rewriting the whole file.
        XCTAssertNotNil(cache.reusable(for: path, mtime: mtime, size: 42))
        cache.prune(known: [path])
        XCTAssertFalse(cache.dirty)

        cache.prune(known: [])
        XCTAssertTrue(cache.dirty, "dropping an entry is a change")
    }

    func testSaveIfDirtyDoesNotTouchTheFileWhenNothingChanged() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = CostUsageScanCache.fileURL(homeDirectory: home.path, tool: .codex)

        var cache = CostUsageScanCache()
        cache.store(
            [event(Date(timeIntervalSince1970: 1_700_000_000))],
            for: "/Users/example/.codex/sessions/a.jsonl",
            mtime: Date(timeIntervalSince1970: 1_700_000_000),
            size: 42
        )
        cache.saveIfDirty(homeDirectory: home.path, tool: .codex)
        let firstWrite = try XCTUnwrap(
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        )

        cache.saveIfDirty(homeDirectory: home.path, tool: .codex)
        let secondWrite = try XCTUnwrap(
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        )
        XCTAssertEqual(firstWrite, secondWrite, "a clean cache must not be rewritten")
    }

    // MARK: - A3: warm store

    func testWarmStoreReusesTheDecodedCacheAndYieldsToAChangedFile() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = "/Users/example/.claude/projects/p/a.jsonl"
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)

        var cache = CostUsageScanCache()
        cache.store([event(mtime)], for: path, mtime: mtime, size: 7)
        CostUsageScanCacheStore.shared.checkin(
            cache, homeDirectory: home.path, tool: .claude, retentionDays: nil
        )

        // Warm hit: the entry survives even though nothing re-read the file.
        var warm = CostUsageScanCacheStore.shared.checkout(
            homeDirectory: home.path, tool: .claude, retentionDays: nil
        )
        XCTAssertEqual(warm.reusable(for: path, mtime: mtime, size: 7)?.count, 1)

        // Someone else rewrites the file: the warm copy must be abandoned.
        var replacement = CostUsageScanCache()
        replacement.store([], for: "/Users/example/.claude/projects/p/b.jsonl", mtime: mtime, size: 9)
        replacement.save(homeDirectory: home.path, tool: .claude)

        warm = CostUsageScanCacheStore.shared.checkout(
            homeDirectory: home.path, tool: .claude, retentionDays: nil
        )
        XCTAssertNil(
            warm.reusable(for: path, mtime: mtime, size: 7),
            "an externally rewritten cache file must win over the warm copy"
        )
    }

    func testWarmStoreReloadsWhenRetentionChanges() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = "/Users/example/.codex/sessions/a.jsonl"
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)

        var cache = CostUsageScanCache(retentionDays: 30)
        cache.store([event(mtime)], for: path, mtime: mtime, size: 7)
        CostUsageScanCacheStore.shared.checkin(
            cache, homeDirectory: home.path, tool: .codex, retentionDays: 30
        )

        var other = CostUsageScanCacheStore.shared.checkout(
            homeDirectory: home.path, tool: .codex, retentionDays: 7
        )
        XCTAssertNil(
            other.reusable(for: path, mtime: mtime, size: 7),
            "a different retention window must not reuse the previous window's events"
        )
    }

    func testErasingTheCacheAlsoDropsTheWarmCopy() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = "/Users/example/.codex/sessions/a.jsonl"
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)

        var cache = CostUsageScanCache()
        cache.store([event(mtime)], for: path, mtime: mtime, size: 7)
        CostUsageScanCacheStore.shared.checkin(
            cache, homeDirectory: home.path, tool: .codex, retentionDays: nil
        )

        CostUsageScanCache.eraseAll(homeDirectory: home.path)

        var afterErase = CostUsageScanCacheStore.shared.checkout(
            homeDirectory: home.path, tool: .codex, retentionDays: nil
        )
        XCTAssertNil(afterErase.reusable(for: path, mtime: mtime, size: 7))
    }

    // MARK: - Codex partial-read guard

    func testUnreadableCodexFileIsNotCachedAsEmpty() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_762_339_200)
        let logURL = sessions.appendingPathComponent("session.jsonl")
        let line = """
        {"type":"event_msg","timestamp":"2025-11-05T06:00:00.000Z","payload":\
        {"type":"token_count","model":"gpt-5","info":{"total_token_usage":\
        {"input_tokens":1000,"cached_input_tokens":0,"output_tokens":100}}}}
        """
        try line.write(to: logURL, atomically: true, encoding: .utf8)
        // Unreadable, but still present with a live mtime/size.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o000))],
            ofItemAtPath: logURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: logURL.path
            )
        }
        // Mode bits do not stop root, and this test is entirely about the
        // failed-read path.
        try XCTSkipUnless(
            (try? Data(contentsOf: logURL)) == nil,
            "this process can read a 0o000 file; skipping the failed-read case"
        )

        let blocked = await CostUsageScanner.scan(
            tool: .codex, homeDirectory: home.path, now: now
        )
        XCTAssertEqual(blocked?.allTimeTokens, 0)

        var cache = CostUsageScanCache.load(homeDirectory: home.path, tool: .codex)
        let values = try logURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = try XCTUnwrap(values.contentModificationDate)
        let size = Int64(try XCTUnwrap(values.fileSize))
        XCTAssertNil(
            cache.reusable(for: logURL.path, mtime: mtime, size: size),
            "a file we failed to read must not be cached as empty against its live fingerprint"
        )

        // Once it is readable again the same fingerprint must still produce
        // the real events — which it cannot if the empty result was cached.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: logURL.path
        )
        CostUsageScanCacheStore.shared.forget()
        let recovered = await CostUsageScanner.scan(
            tool: .codex, homeDirectory: home.path, now: now
        )
        XCTAssertEqual(recovered?.allTimeTokens, 1_100)
    }

    func testUnreadableClaudeFileIsNotCachedAsEmpty() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("-Users-example-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_762_339_200)
        let logURL = project.appendingPathComponent("session.jsonl")
        let line = """
        {"type":"assistant","timestamp":"2025-11-05T06:00:00.000Z","sessionId":"s1",\
        "requestId":"r1","message":{"id":"m1","model":"claude-sonnet-4-5",\
        "usage":{"input_tokens":1000,"output_tokens":100}}}
        """
        try line.write(to: logURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o000))],
            ofItemAtPath: logURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: logURL.path
            )
        }
        try XCTSkipUnless(
            (try? Data(contentsOf: logURL)) == nil,
            "this process can read a 0o000 file; skipping the failed-read case"
        )

        let blocked = await CostUsageScanner.scan(
            tool: .claude, homeDirectory: home.path, now: now
        )
        XCTAssertEqual(blocked?.allTimeTokens, 0)

        var cache = CostUsageScanCache.load(homeDirectory: home.path, tool: .claude)
        let values = try logURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = try XCTUnwrap(values.contentModificationDate)
        let size = Int64(try XCTUnwrap(values.fileSize))
        XCTAssertNil(
            cache.reusable(for: logURL.path, mtime: mtime, size: size),
            "a Claude file we failed to read must not be cached as empty against its live fingerprint"
        )
    }
}
