import SQLite3
import XCTest
@testable import VibeBarCore

/// Codex Auto Review ("guardian") rollouts: how they are linked at index
/// time, which rows the list and search show, what the review index answers,
/// and what a deletion takes with it.
///
/// Every rollout here is synthetic — invented ids, invented text — written in
/// the three shapes Codex has used:
///
/// - **new**: `session_meta.session_id` names the root conversation (0.142 on);
/// - **self-linked with parent**: `session_id` is the rollout's own id and the
///   real parent is only in `parent_thread_id` (0.137 – 0.142 pre-releases);
/// - **self-linked orphan**: own id in `session_id`, no `parent_thread_id`
///   at all (0.124 – 0.136).
final class SessionReviewLinkingTests: XCTestCase {
    private var directory: URL!
    private var home: URL { directory.appendingPathComponent("home", isDirectory: true) }
    private var databaseURL: URL { directory.appendingPathComponent("session_index.sqlite3") }
    private var stampURL: URL { directory.appendingPathComponent("session_index_reparse.json") }
    private var scratchURL: URL { directory.appendingPathComponent("scratch", isDirectory: true) }

    private let parentID = "0199aaaa-0000-7000-8000-000000000001"
    private let otherID = "0199aaaa-0000-7000-8000-000000000002"
    private let newReviewID = "0199aaaa-0000-7000-8000-000000000003"
    private let selfLinkedID = "0199aaaa-0000-7000-8000-000000000004"
    private let orphanID = "0199aaaa-0000-7000-8000-000000000005"
    /// An intermediate subagent the new shape names in `parent_thread_id`;
    /// never written as a rollout, because the kit links new-shape reviews
    /// to the root in `session_id` instead.
    private let intermediateID = "0199aaaa-0000-7000-8000-000000000009"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarSessionReviewLinking-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private func iso(_ minute: Int, second: Int = 0) -> String {
        String(format: "2026-01-02T10:%02d:%02dZ", minute, second)
    }

    @discardableResult
    private func writeRollout(
        id: String,
        minute: Int,
        meta extra: [String: Any] = [:],
        messages: [(role: String, text: String)]
    ) throws -> URL {
        let folder = home.appendingPathComponent(".codex/sessions/2026/01/02", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(
            String(format: "rollout-2026-01-02T10-%02d-00-", minute) + id + ".jsonl"
        )
        var payload: [String: Any] = [
            "id": id,
            "timestamp": iso(minute),
            "cwd": "/Users/example/Code/demo",
            "originator": "codex_cli_rs",
            "cli_version": "0.0.0-test"
        ]
        payload.merge(extra) { _, new in new }
        var lines: [[String: Any]] = [["type": "session_meta", "timestamp": iso(minute), "payload": payload]]
        for (offset, message) in messages.enumerated() {
            lines.append([
                "type": "response_item",
                "timestamp": iso(minute, second: offset + 1),
                "payload": [
                    "type": "message",
                    "role": message.role,
                    "content": [[
                        "type": message.role == "user" ? "input_text" : "output_text",
                        "text": message.text
                    ]]
                ]
            ])
        }
        let body = try lines.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func guardian(sessionID: String, parentThreadID: String?) -> [String: Any] {
        var meta: [String: Any] = [
            "source": ["subagent": ["other": "guardian"]],
            "session_id": sessionID
        ]
        if let parentThreadID { meta["parent_thread_id"] = parentThreadID }
        return meta
    }

    /// Five rollouts: a session, an unrelated session, and one review in each
    /// of the three shapes — two of which belong to the session.
    private func writeFixtureHome() throws {
        try writeRollout(id: parentID, minute: 0, messages: [
            ("user", "please refactor the socket server"),
            ("assistant", "refactoring the socket server now")
        ])
        try writeRollout(id: otherID, minute: 20, messages: [
            ("user", "write release notes for the demo"),
            ("assistant", "drafted the release notes")
        ])
        try writeRollout(
            id: newReviewID,
            minute: 5,
            meta: guardian(sessionID: parentID, parentThreadID: intermediateID),
            messages: [("user", "review this command"), ("assistant", "verdict zebracrossing approved")]
        )
        try writeRollout(
            id: selfLinkedID,
            minute: 6,
            meta: guardian(sessionID: selfLinkedID, parentThreadID: parentID),
            messages: [("user", "review that command"), ("assistant", "verdict quokkaparade approved")]
        )
        try writeRollout(
            id: orphanID,
            minute: 7,
            meta: guardian(sessionID: orphanID, parentThreadID: nil),
            messages: [("user", "review another command"), ("assistant", "verdict narwhalbanner denied")]
        )
    }

    private var rawRegistry: SessionProviderRegistry {
        SessionProviderRegistry(adapters: [CodexSessionAdapter(homeDirectory: home.path)])
    }

    /// The registry the app indexes with: every adapter wrapped in the bounds,
    /// which is where the link repair lives.
    private var boundedRegistry: SessionProviderRegistry {
        SessionIndexingBounds.boundedRegistry(rawRegistry, scratchDirectory: scratchURL)
    }

    private func service(_ store: SessionIndexStore, registry: SessionProviderRegistry) -> SessionIndexService {
        SessionIndexService(homeDirectory: home.path, store: store, registry: registry, bodyIndexing: { true })
    }

    private func variants(_ store: SessionIndexStore) async throws -> [String: String?] {
        var out: [String: String?] = [:]
        for summary in try await store.allSummaries() { out[summary.sessionID] = summary.providerVariant }
        return out
    }

    /// An index as a build before this fix left it: written through the
    /// kit's raw adapter, so the two old-shape reviews name themselves.
    private func legacyIndex() async throws -> SessionIndexStore {
        try writeFixtureHome()
        let store = try SessionIndexStore(url: databaseURL)
        await service(store, registry: rawRegistry).refreshIndex()
        return store
    }

    // MARK: - Index-time repair (defect 2)

    func testTheIndexingAdapterRepointsSelfLinkedReviewsAndUnlinksOrphans() throws {
        try writeFixtureHome()
        let raw = CodexSessionAdapter(homeDirectory: home.path)
        let bounded = try XCTUnwrap(boundedRegistry.adapter(for: .codex))
        func url(_ id: String) throws -> URL {
            let folder = home.appendingPathComponent(".codex/sessions/2026/01/02")
            let name = try XCTUnwrap(
                try FileManager.default.contentsOfDirectory(atPath: folder.path).first { $0.contains(id) }
            )
            return folder.appendingPathComponent(name)
        }
        let prefix = CodexSessionAdapter.autoReviewVariantPrefix

        // The kit's own reading: the old shapes name themselves.
        XCTAssertEqual(try raw.extractMetadata(fileURL: url(selfLinkedID)).providerVariant, prefix + selfLinkedID)
        XCTAssertEqual(try raw.extractMetadata(fileURL: url(orphanID)).providerVariant, prefix + orphanID)

        // The indexer's reading.
        XCTAssertEqual(try bounded.extractMetadata(fileURL: url(selfLinkedID)).providerVariant, prefix + parentID,
                       "parent_thread_id is the real parent when session_id is the rollout's own id")
        XCTAssertNil(try bounded.extractMetadata(fileURL: url(orphanID)).providerVariant,
                     "a review that never recorded a parent becomes an ordinary, listed session")
        XCTAssertEqual(try bounded.extractMetadata(fileURL: url(newReviewID)).providerVariant, prefix + parentID,
                       "the new shape already names the root and is left alone")
        XCTAssertNil(try bounded.extractMetadata(fileURL: url(parentID)).providerVariant)

        // Nothing else about the row moves: the deleter re-parses by id.
        let repaired = try bounded.extractMetadata(fileURL: url(selfLinkedID))
        let original = try raw.extractMetadata(fileURL: url(selfLinkedID))
        XCTAssertEqual(repaired.sessionID, original.sessionID)
        XCTAssertEqual(repaired.sourcePath, original.sourcePath)
        XCTAssertEqual(repaired.createdAt, original.createdAt)
        XCTAssertEqual(repaired.harness, original.harness)
    }

    func testReviewParentIDIgnoresARowThatNamesItself() {
        let prefix = CodexSessionAdapter.autoReviewVariantPrefix
        func row(_ id: String, _ variant: String?, provider: SessionProvider = .codex) -> SessionSummary {
            SessionSummary(provider: provider, sessionID: id, providerVariant: variant,
                           sourcePath: "/Users/example/.codex/sessions/\(id).jsonl")
        }
        XCTAssertEqual(SessionVisibleRows.reviewParentID(of: row(newReviewID, prefix + parentID)), parentID)
        XCTAssertNil(SessionVisibleRows.reviewParentID(of: row(orphanID, prefix + orphanID)))
        XCTAssertNil(SessionVisibleRows.reviewParentID(of: row(parentID, nil)))
        XCTAssertNil(SessionVisibleRows.reviewParentID(of: row(parentID, prefix + otherID, provider: .claude)),
                     "only Codex writes Auto Review rows")
        XCTAssertFalse(SessionVisibleRows.isListed(row(orphanID, prefix + orphanID)),
                       "listing mirrors the SQL exclusion, self-linked rows included")
        XCTAssertTrue(SessionVisibleRows.isListed(row(parentID, nil)))
    }

    // MARK: - Reparse v2: only the self-linked rows are re-read

    func testReparseV2DropsOnlySelfLinkedReviewCursorsAndTheNextPassRepairsThem() async throws {
        let store = try await legacyIndex()
        let prefix = CodexSessionAdapter.autoReviewVariantPrefix
        var before = try await variants(store)
        XCTAssertEqual(before[selfLinkedID], .some(prefix + selfLinkedID))
        XCTAssertEqual(before[orphanID], .some(prefix + orphanID))

        // A plain refresh with the repaired adapter changes nothing: the files
        // have not moved, so their cursors say there is nothing to re-read.
        // That is the whole reason the reparse step exists.
        await service(store, registry: boundedRegistry).refreshIndex()
        before = try await variants(store)
        XCTAssertEqual(before[selfLinkedID], .some(prefix + selfLinkedID))

        // A launch that already ran v1 runs v2 alone.
        XCTAssertEqual(SessionIndexReparse.steps.map(\.version), [1, SessionIndexReparse.currentVersion])
        try Data(#"{"version":1}"#.utf8).write(to: stampURL)
        let outcome = SessionIndexReparse.runIfNeeded(databaseURL: databaseURL, stampURL: stampURL)
        XCTAssertEqual(outcome?.version, 2)
        XCTAssertEqual(outcome?.cursorsDropped, 2, "the two self-linked reviews, and nothing else")
        XCTAssertEqual(remainingCursorCount(), 3)
        XCTAssertNil(SessionIndexReparse.runIfNeeded(databaseURL: databaseURL, stampURL: stampURL),
                     "stamped: a relaunch does not re-read them again")

        // The rows survived the reparse — nothing vanished meanwhile — and
        // until the re-read lands, nobody who opens no Workbench sees them as
        // sessions: not the list, not search.
        let rowsAfterReparse = try await store.sessionCount()
        XCTAssertEqual(rowsAfterReparse, 5)
        try await assertSelfLinkedReviewsAreNotRows(store)

        // The next pass rewrites them.
        await service(store, registry: boundedRegistry).refreshIndex()
        let after = try await variants(store)
        XCTAssertEqual(after[selfLinkedID], .some(prefix + parentID))
        XCTAssertEqual(after[orphanID], .some(nil))
        XCTAssertEqual(after[newReviewID], .some(prefix + parentID))
        XCTAssertEqual(after[parentID], .some(nil))
        XCTAssertEqual(after.count, 5, "re-read in place, not duplicated")
    }

    /// What `sessions.list` / `sessions.search` (and the Sessions page) see
    /// of the legacy rows before they are re-read: nothing of their own.
    private func assertSelfLinkedReviewsAreNotRows(
        _ store: SessionIndexStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let index = service(store, registry: boundedRegistry)
        let page = try await SessionVisibleRows.page(index, limit: 100)
        XCTAssertEqual(Set(page.summaries.map(\.sessionID)), [parentID, otherID], file: file, line: line)
        for needle in ["quokkaparade", "narwhalbanner"] {
            let result = try await SessionVisibleRows.search(index, query: needle)
            XCTAssertEqual(result.rankedCount, 1, "the index still finds \(needle)", file: file, line: line)
            XCTAssertTrue(result.hits.isEmpty, "but no row stands for it", file: file, line: line)
        }
        // A review that already names its parent still folds onto it.
        let folded = try await SessionVisibleRows.search(index, query: "zebracrossing")
        XCTAssertEqual(folded.hits.map(\.hit.summary.sessionID), [parentID], file: file, line: line)
    }

    func testSelfLinkedReviewsAreNeverRowsBeforeTheyAreReRead() async throws {
        let store = try await legacyIndex()
        try await assertSelfLinkedReviewsAreNotRows(store)
    }

    /// The launch path: a step that dropped cursors re-reads them inside the
    /// same hold of the gate, without waiting for the Workbench to be opened.
    func testAReparseThatDropsCursorsRefreshesTheIndexStraightAway() async throws {
        let store = try await legacyIndex()
        let index = service(store, registry: boundedRegistry)
        let refreshes = RefreshCounter()
        let gate = SessionIndexMaintenanceGate()
        try Data(#"{"version":1}"#.utf8).write(to: stampURL)

        let outcome = await SessionIndexReparse.runIfNeededBehindGate(
            databaseURL: databaseURL,
            stampURL: stampURL,
            gate: gate,
            refreshAfterDrop: {
                await refreshes.increment()
                await index.refreshIndex()
            }
        )
        XCTAssertEqual(outcome?.cursorsDropped, 2)
        let count = await refreshes.value
        XCTAssertEqual(count, 1)
        let reclaimed = await gate.tryAcquire()
        XCTAssertTrue(reclaimed, "the gate is handed back after the refresh")
        await gate.release()

        let prefix = CodexSessionAdapter.autoReviewVariantPrefix
        let after = try await variants(store)
        XCTAssertEqual(after[selfLinkedID], .some(prefix + parentID))
        XCTAssertEqual(after[orphanID], .some(nil))
        let repaired = try await SessionVisibleRows.search(index, query: "quokkaparade")
        XCTAssertEqual(repaired.hits.map(\.hit.summary.sessionID), [parentID])
        XCTAssertEqual(repaired.hits.first?.matchedReview?.sessionID, selfLinkedID)
        let unlinked = try await SessionVisibleRows.search(index, query: "narwhalbanner")
        XCTAssertEqual(unlinked.hits.map(\.hit.summary.sessionID), [orphanID], "now a session of its own")

        // Stamped and nothing left to drop: no second pass on the next launch.
        let again = await SessionIndexReparse.runIfNeededBehindGate(
            databaseURL: databaseURL,
            stampURL: stampURL,
            gate: gate,
            refreshAfterDrop: { await refreshes.increment() }
        )
        XCTAssertNil(again)
        let finalCount = await refreshes.value
        XCTAssertEqual(finalCount, 1)
    }

    func testAReparseThatDropsNothingDoesNotRefresh() async throws {
        try writeFixtureHome()
        let store = try SessionIndexStore(url: databaseURL)
        await service(store, registry: boundedRegistry).refreshIndex()
        let refreshes = RefreshCounter()
        try Data(#"{"version":1}"#.utf8).write(to: stampURL)
        let outcome = await SessionIndexReparse.runIfNeededBehindGate(
            databaseURL: databaseURL,
            stampURL: stampURL,
            gate: SessionIndexMaintenanceGate(),
            refreshAfterDrop: { await refreshes.increment() }
        )
        XCTAssertEqual(outcome?.cursorsDropped, 0, "a fresh index has no self-linked rows to drop")
        let count = await refreshes.value
        XCTAssertEqual(count, 0)
    }

    private func remainingCursorCount() -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database = handle else { return -1 }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM session_files", -1, &statement, nil) == SQLITE_OK,
              let statement else { return -1 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: - Review index (defect 1)

    func testTheReviewIndexCountsEveryReviewByParentWithoutLoadingThem() async throws {
        try writeFixtureHome()
        let store = try SessionIndexStore(url: databaseURL)
        await service(store, registry: boundedRegistry).refreshIndex()
        let reviews = SessionReviewIndex(databaseURL: databaseURL)

        let overview = try await reviews.overview()
        XCTAssertEqual(overview.countsByParent, [parentID: 2])
        // Exactly what the list's exclusion hides, so the chip subtraction
        // leaves the number of rows the list can show.
        XCTAssertEqual(overview.hiddenRowsByHarness.values.reduce(0, +), 2)
        let harnessCounts = try await store.harnessCounts()
        let page = try await SessionVisibleRows.page(service(store, registry: boundedRegistry))
        XCTAssertEqual(harnessCounts.values.reduce(0, +) - overview.totalHiddenRows, page.totalCount)

        let children = try await reviews.reviews(forParents: [parentID], limit: 10)
        XCTAssertEqual(children.map(\.sessionID), [newReviewID, selfLinkedID], "oldest first")
        XCTAssertTrue(children.allSatisfy { SessionVisibleRows.reviewParentID(of: $0) == parentID })
        let limited = try await reviews.reviews(forParents: [parentID], limit: 1)
        XCTAssertEqual(limited.map(\.sessionID), [newReviewID])
        let count = try await reviews.reviewCount(forParent: parentID)
        XCTAssertEqual(count, 2)
        let none = try await reviews.reviews(forParents: [otherID, "not-a-session"], limit: 10)
        XCTAssertTrue(none.isEmpty)
    }

    /// The kit's related-rows read stops at 2 000, oldest first; on a Mac
    /// with more reviews than that, the newest ones were never counted. The
    /// grouped query has no such cliff, and holds one entry per parent.
    func testEveryReviewIsCountedPastTheKitsRelatedRowsCeiling() async throws {
        let store = try SessionIndexStore(url: databaseURL)
        let prefix = CodexSessionAdapter.autoReviewVariantPrefix
        let busyParent = "0199bbbb-0000-7000-8000-000000000001"
        let quietParent = "0199bbbb-0000-7000-8000-000000000002"
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        var entries: [SessionIndexStore.IndexBatchEntry] = []
        for index in 0..<2_600 {
            // The quiet parent's 600 reviews are the newest rows of all —
            // exactly the ones an oldest-first cap drops.
            let parent = index < 2_000 ? busyParent : quietParent
            let id = String(format: "0199cccc-0000-7000-8000-%012d", index)
            let path = "/Users/example/.codex/sessions/2026/01/02/rollout-\(id).jsonl"
            entries.append(SessionIndexStore.IndexBatchEntry(
                summary: SessionSummary(
                    provider: .codex,
                    sessionID: id,
                    providerVariant: prefix + parent,
                    harness: .codex,
                    createdAt: start.addingTimeInterval(TimeInterval(index)),
                    lastActiveAt: start.addingTimeInterval(TimeInterval(index)),
                    sourcePath: path,
                    sizeBytes: 1_024
                ),
                pathHash: id,
                path: path,
                provider: .codex,
                mtimeNanos: Int64(index),
                size: 1_024,
                excerpts: nil
            ))
        }
        for batch in stride(from: 0, to: entries.count, by: 500) {
            try await store.applyIndexBatch(Array(entries[batch..<min(batch + 500, entries.count)]))
        }

        let kitDefault = try await store.summaries(provider: .codex, providerVariantPrefix: prefix)
        XCTAssertEqual(kitDefault.count, 2_000, "the ceiling the Sessions page used to live under")
        XCTAssertFalse(kitDefault.contains { $0.providerVariant == prefix + quietParent })

        let reviews = SessionReviewIndex(databaseURL: databaseURL)
        let overview = try await reviews.overview()
        XCTAssertEqual(overview.countsByParent, [busyParent: 2_000, quietParent: 600])
        XCTAssertEqual(overview.hiddenRowsByHarness[.codex], 2_600)
        let quiet = try await reviews.reviews(forParents: [quietParent], limit: 1_000)
        XCTAssertEqual(quiet.count, 600)
        let quietCount = try await reviews.reviewCount(forParent: quietParent)
        XCTAssertEqual(quietCount, 600)
    }

    /// A search hit in a review past the transcript's merge bound still has
    /// to be merged, or its `matchedSeq` lands nowhere.
    func testTheMatchedReviewIsMergedEvenPastTheBound() async throws {
        let store = try SessionIndexStore(url: databaseURL)
        let prefix = CodexSessionAdapter.autoReviewVariantPrefix
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        var entries: [SessionIndexStore.IndexBatchEntry] = []
        for index in 0..<600 {
            let id = String(format: "0199dddd-0000-7000-8000-%012d", index)
            let path = "/Users/example/.codex/sessions/2026/01/02/rollout-\(id).jsonl"
            entries.append(SessionIndexStore.IndexBatchEntry(
                summary: SessionSummary(
                    provider: .codex, sessionID: id, providerVariant: prefix + parentID, harness: .codex,
                    createdAt: start.addingTimeInterval(TimeInterval(index)), sourcePath: path, sizeBytes: 64
                ),
                pathHash: id, path: path, provider: .codex, mtimeNanos: Int64(index), size: 64, excerpts: nil
            ))
        }
        try await store.applyIndexBatch(entries)
        let fetched = try await SessionReviewIndex(databaseURL: databaseURL)
            .reviews(forParents: [parentID], limit: 500)
        XCTAssertEqual(fetched.count, 500)
        let newest = entries.last!.summary
        XCTAssertFalse(fetched.contains { $0.id == newest.id }, "the newest review is past the bound")

        let merged = SessionVisibleRows.reviewsToMerge(fetched, parentID: parentID, focused: newest)
        XCTAssertEqual(merged.count, 501)
        XCTAssertEqual(merged.last?.id, newest.id)
        // Already inside the bound: not added twice.
        let inside = SessionVisibleRows.reviewsToMerge(fetched, parentID: parentID, focused: fetched[3])
        XCTAssertEqual(inside.count, 500)
        // Another session's review, or no hit at all: untouched.
        let stranger = SessionSummary(provider: .codex, sessionID: otherID, providerVariant: prefix + otherID + "x",
                                      sourcePath: "/Users/example/.codex/sessions/s.jsonl")
        XCTAssertEqual(SessionVisibleRows.reviewsToMerge(fetched, parentID: parentID, focused: stranger).count, 500)
        XCTAssertEqual(SessionVisibleRows.reviewsToMerge(fetched, parentID: parentID, focused: nil).count, 500)
        XCTAssertEqual(SessionVisibleRows.reviewsToMerge([], parentID: parentID, focused: newest).map(\.id),
                       [newest.id], "a failed lookup still loads the review the hit is in")
    }

    /// The legacy index is the shape the bug produced: a self-linked row is
    /// nobody's review, and must not be counted as its own.
    func testASelfLinkedRowIsNobodysReview() async throws {
        _ = try await legacyIndex()
        let reviews = SessionReviewIndex(databaseURL: databaseURL)
        let overview = try await reviews.overview()
        XCTAssertEqual(overview.countsByParent, [parentID: 1])
        XCTAssertEqual(overview.totalHiddenRows, 3, "all three are still hidden until they are re-read")
        let selfReviews = try await reviews.reviews(forParents: [selfLinkedID, orphanID], limit: 10)
        XCTAssertTrue(selfReviews.isEmpty)
        let selfCount = try await reviews.reviewCount(forParent: orphanID)
        XCTAssertEqual(selfCount, 0)
    }

    func testAMissingIndexIsReportedNotCreated() async throws {
        let reviews = SessionReviewIndex(databaseURL: databaseURL)
        do {
            _ = try await reviews.overview()
            XCTFail("expected the read-only connection to refuse a missing database")
        } catch let failure as SessionReviewIndex.Failure {
            XCTAssertEqual(failure, .unavailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
    }

    // MARK: - Listed rows: the one rule Workbench and MCP share (defect 3)

    func testThePageNeverListsAnAutoReview() async throws {
        try writeFixtureHome()
        let store = try SessionIndexStore(url: databaseURL)
        let index = service(store, registry: boundedRegistry)
        await index.refreshIndex()

        let page = try await SessionVisibleRows.page(index, limit: 100)
        XCTAssertEqual(Set(page.summaries.map(\.sessionID)), [parentID, otherID, orphanID])
        XCTAssertEqual(page.totalCount, 3)
        XCTAssertTrue(page.summaries.allSatisfy(SessionVisibleRows.isListed))
        XCTAssertFalse(page.summaries.contains {
            $0.providerVariant?.hasPrefix(CodexSessionAdapter.autoReviewVariantPrefix) == true
        })
        // The filters `sessions.list` passes through keep the exclusion.
        let codexOnly = try await SessionVisibleRows.page(
            index, providers: [.codex], projectIncludes: ["Code/demo"], order: .oldestFirst, limit: 100
        )
        XCTAssertEqual(codexOnly.summaries.map(\.sessionID), [parentID, orphanID, otherID])
    }

    func testSearchFoldsAReviewHitIntoTheSessionItReviewed() async throws {
        try writeFixtureHome()
        let store = try SessionIndexStore(url: databaseURL)
        let index = service(store, registry: boundedRegistry)
        await index.refreshIndex()

        // Only the new-shape review says this.
        let inReview = try await SessionVisibleRows.search(index, query: "zebracrossing")
        XCTAssertEqual(inReview.rankedCount, 1)
        let hit = try XCTUnwrap(inReview.hits.first)
        XCTAssertEqual(hit.hit.summary.sessionID, parentID)
        XCTAssertEqual(hit.matchedReview?.sessionID, newReviewID)
        XCTAssertNotNil(hit.hit.matchedSeq, "kept, counting the review's messages")

        // Only the repaired old-shape review says this.
        let inRepaired = try await SessionVisibleRows.search(index, query: "quokkaparade")
        XCTAssertEqual(inRepaired.hits.map(\.hit.summary.sessionID), [parentID])
        XCTAssertEqual(inRepaired.hits.first?.matchedReview?.sessionID, selfLinkedID)

        // Every review says "verdict", and so does nothing else: the two
        // reviews of one session collapse onto it, the orphan is a session
        // of its own now.
        let everywhere = try await SessionVisibleRows.search(index, query: "verdict")
        XCTAssertEqual(everywhere.rankedCount, 3)
        XCTAssertEqual(Set(everywhere.hits.map(\.hit.summary.sessionID)), [parentID, orphanID])
        XCTAssertTrue(everywhere.hits.allSatisfy { SessionVisibleRows.isListed($0.hit.summary) },
                      "no hit is an Auto Review row")
        XCTAssertEqual(everywhere.hits.count, 2)
    }

    func testFoldKeepsAnOrphanAndCollapsesDuplicates() {
        let prefix = CodexSessionAdapter.autoReviewVariantPrefix
        let parent = SessionSummary(provider: .codex, sessionID: parentID,
                                    sourcePath: "/Users/example/.codex/sessions/p.jsonl")
        let review = SessionSummary(provider: .codex, sessionID: newReviewID, providerVariant: prefix + parentID,
                                    sourcePath: "/Users/example/.codex/sessions/r.jsonl")
        let orphan = SessionSummary(provider: .codex, sessionID: selfLinkedID, providerVariant: prefix + otherID,
                                    sourcePath: "/Users/example/.codex/sessions/o.jsonl")
        let selfLinked = SessionSummary(provider: .codex, sessionID: orphanID, providerVariant: prefix + orphanID,
                                        sourcePath: "/Users/example/.codex/sessions/s.jsonl")
        XCTAssertTrue(SessionVisibleRows.isSelfLinkedReview(selfLinked))
        XCTAssertFalse(SessionVisibleRows.isSelfLinkedReview(orphan))
        XCTAssertFalse(SessionVisibleRows.isSelfLinkedReview(parent))
        let hits = [
            SessionSearchHit(summary: review, snippet: "in review", matchedSeq: 3),
            SessionSearchHit(summary: selfLinked, snippet: "waiting on a re-read", matchedSeq: 2),
            SessionSearchHit(summary: parent, snippet: "in parent", matchedSeq: 1),
            SessionSearchHit(summary: orphan, snippet: "orphan", matchedSeq: 0)
        ]
        XCTAssertEqual(SessionVisibleRows.reviewParentIDs(in: hits), [parentID, otherID])
        let folded = SessionVisibleRows.fold(hits, parents: [parentID: parent])
        XCTAssertEqual(folded.map(\.hit.summary.sessionID), [parentID, selfLinkedID],
                       "parent once, at the review's better rank; a self-linked review is dropped; "
                           + "an unresolvable review stands alone")
        XCTAssertEqual(folded[0].hit.snippet, "in review")
        XCTAssertEqual(folded[0].hit.matchedSeq, 3)
        XCTAssertEqual(folded[0].matchedReview?.sessionID, newReviewID)
        XCTAssertNil(folded[1].matchedReview)
    }

    // MARK: - Deletion cascade (defect 4)

    func testDeletingASessionTakesItsReviewsThroughTheDeleter() async throws {
        try writeFixtureHome()
        let store = try SessionIndexStore(url: databaseURL)
        let index = service(store, registry: boundedRegistry)
        await index.refreshIndex()
        let parentRow = try await store.summary(provider: .codex, sessionID: parentID)
        let otherRow = try await store.summary(provider: .codex, sessionID: otherID)
        let parent = try XCTUnwrap(parentRow)
        let other = try XCTUnwrap(otherRow)

        let plan = try await SessionDeletionCascade.plan(
            selected: [parent, other],
            reviewIndex: SessionReviewIndex(databaseURL: databaseURL)
        )
        XCTAssertEqual(plan.selected.map(\.sessionID), [parentID, otherID])
        XCTAssertEqual(plan.reviews.map(\.sessionID), [newReviewID, selfLinkedID])
        XCTAssertEqual(plan.count, 4)
        XCTAssertEqual(Array(plan.all.prefix(2)).map(\.sessionID), [newReviewID, selfLinkedID], "reviews go first")
        XCTAssertEqual(plan.reviewBytes, plan.reviews.reduce(0) { $0 + $1.sizeBytes })
        XCTAssertEqual(plan.totalBytes, plan.all.reduce(0) { $0 + $1.sizeBytes })

        let deleter = SessionDeleter(homeDirectory: home.path)
        let outcomes = SessionDeletionCascade.execute(plan) { deleter.delete($0, registry: rawRegistry) }
        XCTAssertEqual(outcomes.filter(\.success).count, 4)
        for summary in plan.all {
            XCTAssertFalse(FileManager.default.fileExists(atPath: summary.sourcePath))
        }
        let survivors = try FileManager.default.contentsOfDirectory(
            atPath: home.appendingPathComponent(".codex/sessions/2026/01/02").path
        )
        XCTAssertEqual(survivors.count, 1)
        XCTAssertTrue(survivors[0].contains(orphanID), "an unrelated session is not this deletion's business")
    }

    /// A review the deleter refuses — here a symlink, one of its safety
    /// checks — keeps its session on disk, and both are reported kept. The
    /// session's other review and the unrelated session still go.
    func testAReviewThatCannotBeDeletedKeepsItsSession() async throws {
        try writeFixtureHome()
        let store = try SessionIndexStore(url: databaseURL)
        await service(store, registry: boundedRegistry).refreshIndex()
        let parentRow = try await store.summary(provider: .codex, sessionID: parentID)
        let otherRow = try await store.summary(provider: .codex, sessionID: otherID)
        let parent = try XCTUnwrap(parentRow)
        let other = try XCTUnwrap(otherRow)
        let plan = try await SessionDeletionCascade.plan(
            selected: [parent, other],
            reviewIndex: SessionReviewIndex(databaseURL: databaseURL)
        )
        let refused = try XCTUnwrap(plan.reviews.first { $0.sessionID == selfLinkedID })
        // Swap the review's log for a link to a copy of itself: still inside
        // the provider root, but the deleter never removes a symlink.
        let copy = URL(fileURLWithPath: refused.sourcePath).deletingLastPathComponent()
            .appendingPathComponent("held-aside.bak")
        try FileManager.default.moveItem(atPath: refused.sourcePath, toPath: copy.path)
        try FileManager.default.createSymbolicLink(atPath: refused.sourcePath, withDestinationPath: copy.path)

        let deleter = SessionDeleter(homeDirectory: home.path)
        let outcomes = SessionDeletionCascade.execute(plan) { deleter.delete($0, registry: rawRegistry) }
        let removed = Set(outcomes.filter(\.success).map(\.summary.sessionID))
        let kept = outcomes.filter { !$0.success }
        XCTAssertEqual(removed, [newReviewID, otherID])
        XCTAssertEqual(Set(kept.map(\.summary.sessionID)), [selfLinkedID, parentID],
                       "the refused review and its session are both counted as kept")
        XCTAssertEqual(kept.first { $0.summary.sessionID == parentID }?.failureReason, .symlinkedTarget,
                       "the session is kept for the review's own reason")
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent.sourcePath), "the session is not deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.sourcePath))
    }

    func testExecuteNeverHandsABlockedSessionToTheDeleter() {
        let prefix = CodexSessionAdapter.autoReviewVariantPrefix
        func row(_ id: String, _ variant: String?) -> SessionSummary {
            SessionSummary(provider: .codex, sessionID: id, providerVariant: variant,
                           sourcePath: "/Users/example/.codex/sessions/\(id).jsonl")
        }
        let parent = row(parentID, nil)
        let other = row(otherID, nil)
        let failing = row(newReviewID, prefix + parentID)
        let fine = row(selfLinkedID, prefix + parentID)
        let otherReview = row(orphanID, prefix + otherID)
        let plan = SessionDeletionCascade.Plan(selected: [parent, other], reviews: [failing, fine, otherReview])

        var batches: [[String]] = []
        let outcomes = SessionDeletionCascade.execute(plan) { batch in
            batches.append(batch.map(\.sessionID))
            return batch.map { $0.sessionID == newReviewID ? .failed($0, .removalFailed("x.jsonl")) : .succeeded($0) }
        }
        XCTAssertEqual(batches, [[newReviewID, selfLinkedID, orphanID], [otherID]],
                       "reviews first; the blocked session is never asked for")
        XCTAssertEqual(outcomes.filter { !$0.success }.map(\.summary.sessionID), [newReviewID, parentID])
        XCTAssertEqual(outcomes.first { $0.summary.sessionID == parentID }?.failureReason, .removalFailed("x.jsonl"))

        // A review the deleter returned nothing for blocks its session too.
        let silent = SessionDeletionCascade.execute(plan) { batch in
            batch.filter { $0.sessionID != fine.sessionID }.map { .succeeded($0) }
        }
        XCTAssertEqual(silent.first { $0.summary.sessionID == parentID }?.success, false)
        XCTAssertEqual(silent.first { $0.summary.sessionID == otherID }?.success, true)
    }

    func testThePlanCountsEachFileOnceAndOnlyForSelectedParents() {
        let prefix = CodexSessionAdapter.autoReviewVariantPrefix
        func row(_ id: String, _ variant: String?, provider: SessionProvider = .codex, bytes: Int64) -> SessionSummary {
            SessionSummary(provider: provider, sessionID: id, providerVariant: variant,
                           sourcePath: "/Users/example/.codex/sessions/\(id).jsonl", sizeBytes: bytes)
        }
        let parent = row(parentID, nil, bytes: 10)
        let review = row(newReviewID, prefix + parentID, bytes: 100)
        let ticked = row(selfLinkedID, prefix + parentID, bytes: 1_000)
        let stranger = row(orphanID, prefix + otherID, bytes: 10_000)

        // A review the user also ticked by hand is counted with the selection.
        let plan = SessionDeletionCascade.plan(selected: [parent, ticked], reviews: [review, ticked, stranger])
        XCTAssertEqual(plan.reviews.map(\.sessionID), [newReviewID])
        XCTAssertEqual(plan.count, 3)
        XCTAssertEqual(plan.reviewBytes, 100)
        XCTAssertEqual(plan.totalBytes, 1_110)

        // Reviews have no reviews, and other providers have none at all.
        XCTAssertEqual(SessionDeletionCascade.parentIDs(of: [review]), [])
        XCTAssertEqual(SessionDeletionCascade.parentIDs(of: [row("x", nil, provider: .claude, bytes: 0)]), [])
        XCTAssertEqual(SessionDeletionCascade.parentIDs(of: [parent, parent]), [parentID])
    }

    /// No plan rather than a partial one: reviews the plan missed would be
    /// stranded when their sessions went.
    func testAPlanThatCannotSeeEveryReviewIsRefused() async throws {
        let parent = SessionSummary(provider: .codex, sessionID: parentID,
                                    sourcePath: "/Users/example/.codex/sessions/p.jsonl")
        // The review index cannot answer at all.
        do {
            _ = try await SessionDeletionCascade.plan(
                selected: [parent],
                reviewIndex: SessionReviewIndex(databaseURL: databaseURL)
            )
            XCTFail("expected a refusal")
        } catch let error as SessionDeletionCascade.PlanError {
            XCTAssertEqual(error, .reviewLookupFailed)
            XCTAssertFalse(error.message.isEmpty)
        }
        // A selection with no Codex session has nothing to look up.
        let claude = SessionSummary(provider: .claude, sessionID: "c-1",
                                    sourcePath: "/Users/example/.claude/projects/demo/c-1.jsonl")
        let alone = try await SessionDeletionCascade.plan(
            selected: [claude],
            reviewIndex: SessionReviewIndex(databaseURL: databaseURL)
        )
        XCTAssertEqual(alone.all.map(\.sessionID), ["c-1"])

        // More reviews than one deletion collects: the extra row the read
        // asks for proves the list was cut.
        let store = try SessionIndexStore(url: databaseURL)
        let prefix = CodexSessionAdapter.autoReviewVariantPrefix
        var entries: [SessionIndexStore.IndexBatchEntry] = []
        for index in 0..<6 {
            let id = String(format: "0199eeee-0000-7000-8000-%012d", index)
            let path = "/Users/example/.codex/sessions/2026/01/02/rollout-\(id).jsonl"
            entries.append(SessionIndexStore.IndexBatchEntry(
                summary: SessionSummary(provider: .codex, sessionID: id, providerVariant: prefix + parentID,
                                        harness: .codex, sourcePath: path),
                pathHash: id, path: path, provider: .codex, mtimeNanos: Int64(index), size: 1, excerpts: nil
            ))
        }
        try await store.applyIndexBatch(entries)
        let reviews = SessionReviewIndex(databaseURL: databaseURL)
        do {
            _ = try await SessionDeletionCascade.plan(selected: [parent], reviewIndex: reviews, limit: 5)
            XCTFail("expected a refusal past the limit")
        } catch let error as SessionDeletionCascade.PlanError {
            XCTAssertEqual(error, .tooManyReviews(limit: 5))
        }
        // Exactly at the limit is complete, and allowed.
        let full = try await SessionDeletionCascade.plan(selected: [parent], reviewIndex: reviews, limit: 6)
        XCTAssertEqual(full.reviews.count, 6)
    }
}

private actor RefreshCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
