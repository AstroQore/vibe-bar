import Combine
import XCTest
@testable import VibeBarCore

@MainActor
final class SessionIndexRefreshCoordinatorTests: XCTestCase {
    private actor Passes {
        private(set) var observed: [SessionIndexRefreshCoordinator.Pass] = []
        private var reports: [SessionIndexRefreshCoordinator.Report]

        init(_ reports: [SessionIndexRefreshCoordinator.Report]) {
            self.reports = reports
        }

        func run(_ pass: SessionIndexRefreshCoordinator.Pass) -> SessionIndexRefreshCoordinator.Report {
            observed.append(pass)
            return reports.isEmpty ? .init(changed: false) : reports.removeFirst()
        }
    }

    private final class Power: @unchecked Sendable {
        private let lock = NSLock()
        private var allowed = true
        var backgroundAllowed: Bool { lock.withLock { allowed } }
        func set(_ value: Bool) { lock.withLock { allowed = value } }
    }

    func testTwoPagesAndColdMCPShareOneRefreshAfterAWaiterLeaves() async throws {
        let gate = SessionIndexMaintenanceGate()
        let passes = Passes([.init(changed: true, completedDiscovery: true)])
        let coordinator = SessionIndexRefreshCoordinator(gate: gate) { pass, _ in await passes.run(pass) }
        try await gate.acquire()

        let first = try XCTUnwrap(coordinator.requestRefresh())
        let waiter = Task { await first.value }
        waiter.cancel()
        let second = try XCTUnwrap(coordinator.requestRefresh())
        let mcp = Task { await coordinator.backfillIfNeeded(hasRows: { false }) }
        var generations: [UInt64] = []
        let subscription = coordinator.$state.map(\.generation).removeDuplicates().sink { generations.append($0) }
        defer { subscription.cancel() }

        await gate.release()
        let finished = await second.value
        _ = await waiter.value
        _ = await mcp.value
        XCTAssertTrue(finished)
        XCTAssertNotNil(coordinator.lastDiscoveryFinishedAt)
        XCTAssertEqual(generations, [0, 1])
        let observed = await passes.observed
        XCTAssertEqual(observed, [.full])
    }

    func testBudgetContinuationBacksOffThenResumesWithoutAChangeNotification() async {
        let power = Power()
        let passes = Passes([
            .init(changed: false, hasMore: true),
            .init(changed: false, completedDiscovery: true),
            .init(changed: false, hasMore: true),
            .init(changed: true)
        ])
        let coordinator = SessionIndexRefreshCoordinator(
            gate: SessionIndexMaintenanceGate(),
            backgroundAllowed: { power.backgroundAllowed }
        ) { pass, _ in await passes.run(pass) }

        let more = await coordinator.preloadOnce()
        XCTAssertTrue(more)
        XCTAssertNil(coordinator.lastDiscoveryFinishedAt)
        XCTAssertEqual(coordinator.state.generation, 0)
        power.set(false)
        let paused = await coordinator.preloadOnce()
        XCTAssertFalse(paused, "power backoff does not run the next slice")
        XCTAssertFalse(coordinator.state.isDiscovering)
        power.set(true)

        let discovered = await coordinator.preloadOnce()
        XCTAssertFalse(discovered)
        XCTAssertNotNil(coordinator.lastDiscoveryFinishedAt)
        let recentMore = await coordinator.preloadOnce()
        let recentFinished = await coordinator.preloadOnce()
        XCTAssertTrue(recentMore)
        XCTAssertFalse(recentFinished)
        XCTAssertEqual(coordinator.state.generation, 1)
        let observed = await passes.observed
        XCTAssertEqual(observed, [.discovery, .discovery, .recent, .recent])
    }

    func testVisibleEmptyIndexContinuesUntilListedRowsExistInLowPowerMode() async {
        let passes = Passes([
            .init(changed: true, hasMore: true), // first batch has only hidden reviews
            .init(changed: true, hasMore: true)
        ])
        let coordinator = SessionIndexRefreshCoordinator(
            gate: SessionIndexMaintenanceGate(),
            backgroundAllowed: { false },
            hasCachedRows: { await passes.observed.count >= 2 }
        ) { pass, _ in await passes.run(pass) }
        defer { coordinator.stop() }

        let idle = await coordinator.preloadOnce()
        XCTAssertFalse(idle)
        let rows = expectation(description: "second slice discovered a listed session")
        let subscription = coordinator.$state.map(\.generation).removeDuplicates().sink {
            if $0 == 2 { rows.fulfill() }
        }
        defer { subscription.cancel() }

        coordinator.setVisible(.sessions, true)
        await fulfillment(of: [rows], timeout: 4)
        let warm = await coordinator.preloadOnce()
        XCTAssertFalse(warm)
        coordinator.setVisible(.sessions, false)
        let closed = await coordinator.preloadOnce()
        XCTAssertFalse(closed)
        let observed = await passes.observed
        XCTAssertEqual(observed, [.discovery, .discovery])
    }

    func testBackgroundYieldsToMaintenanceAndMutationFailuresAreReported() async throws {
        let gate = SessionIndexMaintenanceGate()
        let passes = Passes([])
        let coordinator = SessionIndexRefreshCoordinator(gate: gate) { pass, _ in await passes.run(pass) }
        try await gate.acquire()
        let ran = await coordinator.preloadOnce()
        XCTAssertFalse(ran)
        await gate.release()
        let failed = await coordinator.mutate { false }
        XCTAssertFalse(failed)
        XCTAssertEqual(coordinator.state.generation, 0)
        let observed = await passes.observed
        XCTAssertEqual(observed, [])
    }

    func testQuitCancelsAQueuedRefreshWithoutMarkingFreshness() async throws {
        let gate = SessionIndexMaintenanceGate()
        let passes = Passes([])
        let coordinator = SessionIndexRefreshCoordinator(gate: gate) { pass, _ in await passes.run(pass) }
        try await gate.acquire()
        let task = try XCTUnwrap(coordinator.requestRefresh())
        coordinator.stop()
        await gate.release()
        let finished = await task.value
        XCTAssertFalse(finished)
        XCTAssertNil(coordinator.lastDiscoveryFinishedAt)
        XCTAssertNil(coordinator.requestRefresh())
        let observed = await passes.observed
        XCTAssertEqual(observed, [])
    }
}

private struct BlockingDiscovery: SessionProviderAdapter {
    let started: XCTestExpectation
    let resume: DispatchSemaphore

    var provider: SessionProvider { .codex }
    func roots(homeDirectory: String) -> [URL] { [] }

    func discoverSessionFiles(homeDirectory: String) -> [URL] {
        started.fulfill()
        _ = resume.wait(timeout: .now() + 5)
        return []
    }

    func extractMetadata(fileURL: URL) throws -> SessionSummary { throw CocoaError(.fileReadUnknown) }

    func parseTranscript(fileURL: URL, range: Range<Int>?) throws -> TranscriptDocument {
        throw CocoaError(.fileReadUnknown)
    }

    func deletionPlan(for summary: SessionSummary, homeDirectory: String) throws -> SessionDeletionPlan {
        throw CocoaError(.fileWriteUnknown)
    }
}

extension SessionIndexRefreshCoordinatorTests {
    func testCachedPageReturnsWhileProviderDiscoveryIsStillBlocked() async throws {
        let directory = try SessionStructureFixtures.temporaryDirectory("cached-first-page")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionIndexStore(url: directory.appendingPathComponent("index.sqlite3"))
        let source = directory.appendingPathComponent("synthetic.jsonl")
        let first = SessionSummary(
            provider: .codex,
            sessionID: "cached",
            title: "Cached row",
            sourcePath: source.path,
            sizeBytes: 10,
            messageCount: 1
        )
        _ = try await store.upsertSession(first)
        let started = expectation(description: "provider started walking its roots")
        let resume = DispatchSemaphore(value: 0)
        let index = SessionIndexService(
            homeDirectory: directory.path,
            store: store,
            registry: SessionProviderRegistry(adapters: [BlockingDiscovery(started: started, resume: resume)]),
            bodyIndexing: { true }
        )
        let scan = Task { await index.refreshIndexFully() }
        await fulfillment(of: [started], timeout: 1)

        let read = expectation(description: "cached first page returned")
        let page = Task {
            let page = try await SessionVisibleRows.page(index)
            read.fulfill()
            return page
        }
        // The old service actor had to finish discovery before it could
        // answer this query. Keep the walker blocked until the read returns.
        await fulfillment(of: [read], timeout: 1)
        resume.signal()
        _ = await scan.value
        let result = try await page.value
        XCTAssertEqual(result.totalCount, 1)
        XCTAssertEqual(result.summaries.map(\.sessionID), [first.sessionID])
    }
}

extension SessionIndexRefreshCoordinatorTests {
    func testLargePlainRolloutGetsListedUnderBackgroundBudget() async throws {
        let directory = try SessionStructureFixtures.temporaryDirectory("bounded-background")
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = "0199bbbb-0000-7000-8000-000000000001"
        let source = directory.appendingPathComponent(
            ".codex/sessions/2026/05/01/rollout-2026-05-01T10-00-00-\(id).jsonl"
        )
        let rollout = CodexRolloutBuilder().meta(id: id).prompt("Background-indexed prompt")
        for _ in 0..<10 { rollout.assistant("An early complete metadata record") }
        try SessionStructureFixtures.write(rollout.lines, to: source)

        let timestamp = "2026-05-01T10:12:00Z"
        let file = try FileHandle(forWritingTo: source)
        try file.seekToEnd()
        // The bounded body reader should never reach this distant tail.
        try file.write(contentsOf: Data(repeating: 32, count: 10 * 1024 * 1024))
        try file.write(contentsOf: Data("\n{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\"}\n".utf8))
        try file.close()

        let store = try SessionIndexStore(url: directory.appendingPathComponent("index.sqlite3"))
        let registry = SessionIndexingBounds.boundedRegistry(
            SessionProviderRegistry(adapters: [CodexSessionAdapter(homeDirectory: directory.path)]),
            scratchDirectory: directory.appendingPathComponent("scratch", isDirectory: true)
        )
        let index = SessionIndexService(
            homeDirectory: directory.path,
            store: store,
            registry: registry,
            bodyIndexing: { true }
        )
        let result = await index.refreshIndexBatch(budget: SessionIndexRefreshBudget(
            maxFiles: 32, maxBytes: 16 * 1024 * 1024, maxFileBytes: 9 * 1024 * 1024
        ))
        XCTAssertEqual(result.written, 1)
        XCTAssertEqual(result.deferred, 0)
        XCTAssertLessThan(result.bytes, 9 * 1024 * 1024)
        let page = try await SessionVisibleRows.page(index)
        let row = try XCTUnwrap(page.summaries.first)
        XCTAssertEqual(row.sessionID, id)
        XCTAssertGreaterThan(row.sizeBytes, 9 * 1024 * 1024)
        XCTAssertEqual(row.lastActiveAt, ISO8601DateFormatter().date(from: timestamp))
    }
}

extension SessionIndexRefreshCoordinatorTests {
    func testBackgroundFindsCompressedCodexRolloutsAndRetainsAnArchivedSession() async throws {
        let directory = try SessionStructureFixtures.temporaryDirectory("background-compressed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionRoot = directory.appendingPathComponent(".codex/sessions/2026/05/01")
        let existingID = "0199bbbb-0000-7000-8000-000000000001"
        let newID = "0199bbbb-0000-7000-8000-000000000002"
        let existing = sessionRoot.appendingPathComponent("rollout-2026-05-01T10-00-00-\(existingID).jsonl")
        let added = sessionRoot.appendingPathComponent("rollout-2026-05-01T10-01-00-\(newID).jsonl")
        try SessionStructureFixtures.write(
            CodexRolloutBuilder().meta(id: existingID).prompt("Synthetic archive token").lines, to: existing
        )
        let store = try SessionIndexStore(url: directory.appendingPathComponent("index.sqlite3"))
        let registry = SessionIndexingBounds.boundedRegistry(
            SessionProviderRegistry(adapters: [CodexSessionAdapter(homeDirectory: directory.path)]),
            scratchDirectory: directory.appendingPathComponent("scratch", isDirectory: true)
        )
        let index = SessionIndexService(
            homeDirectory: directory.path, store: store, registry: registry, bodyIndexing: { true }
        )
        await index.refreshIndex()
        let before = try await SessionVisibleRows.page(index)
        XCTAssertEqual(before.totalCount, 1)

        let archived = try ZstdRawFrame.compressInPlace(existing)
        try SessionStructureFixtures.write(
            CodexRolloutBuilder().meta(id: newID).prompt("Synthetic new compressed token").lines, to: added
        )
        let compressed = try ZstdRawFrame.compressInPlace(added)
        let budget = SessionIndexRefreshBudget(
            maxFiles: 32, maxBytes: 16 * 1024 * 1024, maxFileBytes: 9 * 1024 * 1024
        )
        let first = await index.refreshIndexBatch(budget: budget)
        XCTAssertTrue(first.hasMore)
        let between = try await SessionVisibleRows.page(index)
        XCTAssertTrue(between.summaries.contains { $0.sessionID == existingID })
        let second = await index.refreshIndexBatch(budget: budget)
        XCTAssertTrue(second.completedDiscovery)
        XCTAssertEqual(first.deferred + second.deferred, 0)
        let after = try await SessionVisibleRows.page(index)
        let filenames = Set(after.summaries.map { URL(fileURLWithPath: $0.sourcePath).lastPathComponent })
        XCTAssertEqual(after.totalCount, 2)
        XCTAssertEqual(filenames, [archived.lastPathComponent, compressed.lastPathComponent])
        XCTAssertEqual(after.summaries.first(where: { $0.sessionID == existingID })?.title, before.summaries.first?.title)
        let oldHit = try await index.search("Synthetic archive token")
        XCTAssertEqual(oldHit.map { URL(fileURLWithPath: $0.summary.sourcePath).lastPathComponent }, [archived.lastPathComponent])
        let newHit = try await index.search("Synthetic new compressed token")
        XCTAssertEqual(newHit.map { URL(fileURLWithPath: $0.summary.sourcePath).lastPathComponent }, [compressed.lastPathComponent])
    }
}
