import XCTest
@testable import VibeBarCore

/// End-to-end cover for the wiring `CostUsageService` sets up: a real scan
/// of synthetic session logs, with a `UsageEventLedger` attached as the
/// scanner's event sink.
///
/// The service itself is deliberately not instantiated here. Its refresh
/// path talks to `CostHistoryStore.shared` / `CostSnapshotCache.shared`,
/// which are singletons rooted at the *real* `~/.vibebar`, and its
/// privacy-mode branch erases them — running that in a unit test would
/// delete the developer's own cost history. What the service contributes
/// on top of this test is three one-liners (pass the sink, call
/// `rollupAndPrune`, call `eraseAll`), and the behaviours those depend on
/// are exercised directly below.
final class CostUsageServiceLedgerTests: XCTestCase {
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func makeCodexHome(now: Date) throws -> URL {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarLedgerScan-\(UUID().uuidString)", isDirectory: true)
        let sessions = home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)
        let lines = [
            codexTokenCountLine(
                timestamp: now.addingTimeInterval(-3 * 3_600), model: "gpt-5",
                input: 1_000_000, cached: 0, output: 20_000
            ),
            codexTokenCountLine(
                timestamp: now.addingTimeInterval(-2 * 3_600), model: "gpt-5",
                input: 1_400_000, cached: 200_000, output: 50_000
            ),
            codexTokenCountLine(
                timestamp: now.addingTimeInterval(-3_600), model: "gpt-5-mini",
                input: 1_600_000, cached: 400_000, output: 90_000
            )
        ]
        try lines.joined(separator: "\n").write(
            to: sessions.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        return home
    }

    func testScanWithSinkFillsTheLedgerWithTheSnapshotTotals() async throws {
        let now = Date(timeIntervalSince1970: 1_762_339_200)
        let home = try makeCodexHome(now: now)
        defer { try? FileManager.default.removeItem(at: home) }
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("ServiceScan")
        defer { try? FileManager.default.removeItem(at: directory) }

        let scanned = await CostUsageScanner.scan(
            tool: .codex, homeDirectory: home.path, now: now, eventSink: ledger
        )
        let snapshot = try XCTUnwrap(scanned)
        XCTAssertGreaterThan(snapshot.allTimeRequests, 0)

        let filter = UsageLedgerFixtures.wideFilter(around: now)
        let summary = try await ledger.summary(filter)
        XCTAssertEqual(summary.requests, snapshot.allTimeRequests)
        XCTAssertEqual(Int(summary.realTotalTokens), snapshot.allTimeTokens)
        XCTAssertEqual(
            Double(try XCTUnwrap(summary.costMicros)) / 1_000_000,
            snapshot.allTimeCostUSD,
            accuracy: 0.000_01
        )
        XCTAssertEqual(summary.unpricedRequests, 0)

        // Codex reports non-cached input separately, so nothing lands in
        // the cache-creation column and cache reads come through intact.
        XCTAssertEqual(summary.cacheCreation, 0)
        XCTAssertEqual(summary.cacheRead, 400_000)

        let providers = try await ledger.providerStats(filter)
        XCTAssertEqual(providers.map(\.tool), [.codex])
        XCTAssertEqual(Int(try XCTUnwrap(providers.first?.totalTokens)), snapshot.allTimeTokens)

        let models = try await ledger.modelStats(filter)
        XCTAssertEqual(Set(models.map(\.model)), ["gpt-5", "gpt-5-mini"])

        let page = try await ledger.requestPage(filter, page: 0, pageSize: 10)
        XCTAssertEqual(page.totalCount, snapshot.allTimeRequests)
        XCTAssertEqual(page.rows.first?.model, "gpt-5-mini")
    }

    /// The scan cache goes warm after the first pass; a sink attached to a
    /// fresh ledger has to see the cache-reused files too, or a ledger
    /// created after the first refresh would never backfill.
    func testCacheReusedFilesStillReachTheSink() async throws {
        let now = Date(timeIntervalSince1970: 1_762_339_200)
        let home = try makeCodexHome(now: now)
        defer { try? FileManager.default.removeItem(at: home) }

        let (first, firstDirectory) = try UsageLedgerFixtures.makeLedger("ServiceWarmA")
        defer { try? FileManager.default.removeItem(at: firstDirectory) }
        _ = await CostUsageScanner.scan(
            tool: .codex, homeDirectory: home.path, now: now, eventSink: first
        )
        let filter = UsageLedgerFixtures.wideFilter(around: now)
        let seeded = try await first.summary(filter)
        XCTAssertGreaterThan(seeded.requests, 0)

        // Second pass reads entirely from the warm scan cache.
        let (second, secondDirectory) = try UsageLedgerFixtures.makeLedger("ServiceWarmB")
        defer { try? FileManager.default.removeItem(at: secondDirectory) }
        _ = await CostUsageScanner.scan(
            tool: .codex, homeDirectory: home.path, now: now, eventSink: second
        )
        let backfilled = try await second.summary(filter)
        XCTAssertEqual(backfilled.requests, seeded.requests)
        XCTAssertEqual(backfilled.realTotalTokens, seeded.realTotalTokens)
        XCTAssertEqual(backfilled.costMicros, seeded.costMicros)

        // Re-scanning into the already-populated ledger must not duplicate.
        _ = await CostUsageScanner.scan(
            tool: .codex, homeDirectory: home.path, now: now, eventSink: first
        )
        let repeated = try await first.summary(filter)
        XCTAssertEqual(repeated.requests, seeded.requests)
        XCTAssertEqual(repeated.realTotalTokens, seeded.realTotalTokens)
    }

    /// Privacy mode never reaches the scanner with a sink attached — the
    /// service returns before scanning — so a nil sink must leave the
    /// ledger untouched and the snapshot unchanged.
    func testScanWithoutSinkWritesNothingAndErasePurges() async throws {
        let now = Date(timeIntervalSince1970: 1_762_339_200)
        let home = try makeCodexHome(now: now)
        defer { try? FileManager.default.removeItem(at: home) }
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("ServicePrivacy")
        defer { try? FileManager.default.removeItem(at: directory) }

        let filter = UsageLedgerFixtures.wideFilter(around: now)
        let unsinkedScan = await CostUsageScanner.scan(
            tool: .codex, homeDirectory: home.path, now: now
        )
        let withoutSink = try XCTUnwrap(unsinkedScan)
        let withoutSinkRequests = try await ledger.summary(filter).requests
        XCTAssertEqual(withoutSinkRequests, 0)

        let sinkedScan = await CostUsageScanner.scan(
            tool: .codex, homeDirectory: home.path, now: now, eventSink: ledger
        )
        let withSink = try XCTUnwrap(sinkedScan)
        // The sink is a pure side channel: the snapshot is identical.
        XCTAssertEqual(withSink.allTimeRequests, withoutSink.allTimeRequests)
        XCTAssertEqual(withSink.allTimeTokens, withoutSink.allTimeTokens)
        XCTAssertEqual(withSink.allTimeCostUSD, withoutSink.allTimeCostUSD, accuracy: 0.000_01)
        let withSinkRequests = try await ledger.summary(filter).requests
        XCTAssertGreaterThan(withSinkRequests, 0)

        try await ledger.eraseAll()
        let afterEraseRequests = try await ledger.summary(filter).requests
        XCTAssertEqual(afterEraseRequests, 0)
        let afterEraseCost = try await ledger.summary(filter).costMicros
        XCTAssertNil(afterEraseCost)
    }

    private func codexTokenCountLine(
        timestamp: Date,
        model: String,
        input: Int,
        cached: Int,
        output: Int
    ) -> String {
        let timestampString = Self.isoFormatter.string(from: timestamp)
        return """
        {"timestamp":"\(timestampString)","type":"event_msg","payload":{"type":"token_count","model":"\(model)","info":{"total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"output_tokens":\(output)}}}}
        """
    }
}
