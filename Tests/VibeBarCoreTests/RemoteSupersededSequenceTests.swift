import XCTest
import SQLite3
@testable import VibeBarCore

/// A skipped superseded batch still consumes a slot in its producer's sequence
/// chain. dev.18 advanced only the Relay cursor when it skipped one, so the
/// ledger watermark stayed at 0 while the cursor walked over the whole
/// superseded backlog — and the first current-epoch batch then arrived as a
/// `sequence_gap` that aborted every later sync.
///
/// These tests pin both halves of the fix at the ledger level: recording a skip
/// moves the watermark forward (and only forward), and a Core with no recorded
/// position at all adopts the first sequence it can actually decrypt instead of
/// demanding a sequence 1 that no longer exists anywhere.
///
/// Synthetic UUIDs only; every payload is built locally.
final class RemoteSupersededSequenceTests: XCTestCase {
    private let workspace = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let producer = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    // MARK: - noteSupersededBatch

    func testNoteSupersededBatchAdvancesWatermarkAndDedupsARedelivery() async throws {
        let (ledger, url) = try makeLedger()

        try await ledger.noteSupersededBatch(
            workspaceID: workspace, producerID: producer, sequence: 1, receivedAt: Date()
        )
        try await ledger.noteSupersededBatch(
            workspaceID: workspace, producerID: producer, sequence: 2, receivedAt: Date()
        )
        XCTAssertEqual(try storedWatermark(at: url), 2)

        // A re-delivery of an already-accounted-for sequence is a no-op import,
        // exactly like a re-delivered imported batch.
        let redelivered = try RemotePayloadDecoder.decode(payload(sequence: 2, previous: 1))
        let imported = try await ledger.importBatch(redelivered, sequence: 2, receivedAt: Date())
        XCTAssertFalse(imported)

        // And the batch that follows the skipped run imports as the contiguous
        // next sequence — the wedge the fix removes.
        let next = try RemotePayloadDecoder.decode(payload(sequence: 3, previous: 2))
        let importedNext = try await ledger.importBatch(next, sequence: 3, receivedAt: Date())
        XCTAssertTrue(importedNext)
        let summaries = try await ledger.machineSummaries(
            workspaceID: workspace,
            now: ISO8601DateFormatter().date(from: "2026-08-03T12:00:00Z")!
        )
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].lastSequence, 3)
        XCTAssertEqual(summaries[0].todayTokens, 15)
    }

    func testNoteSupersededBatchNeverLowersAHigherWatermark() async throws {
        let (ledger, url) = try makeLedger()

        // Import first so the watermark is owned by real data.
        let first = try RemotePayloadDecoder.decode(payload(sequence: 1, previous: nil))
        _ = try await ledger.importBatch(first, sequence: 1, receivedAt: Date())
        let second = try RemotePayloadDecoder.decode(payload(sequence: 2, previous: 1))
        _ = try await ledger.importBatch(second, sequence: 2, receivedAt: Date())
        XCTAssertEqual(try storedWatermark(at: url), 2)

        // An out-of-order superseded skip for an earlier sequence must not drag
        // the position backwards.
        try await ledger.noteSupersededBatch(
            workspaceID: workspace, producerID: producer, sequence: 1, receivedAt: Date()
        )
        XCTAssertEqual(try storedWatermark(at: url), 2)

        // The probe's real metadata survives a skip as well: the placeholder
        // insert only ever touches last_sequence.
        let summaries = try await ledger.machineSummaries(
            workspaceID: workspace,
            now: ISO8601DateFormatter().date(from: "2026-08-03T12:00:00Z")!
        )
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].alias, "Example machine")
        XCTAssertEqual(summaries[0].lastSequence, 2)

        // A forward skip still moves it.
        try await ledger.noteSupersededBatch(
            workspaceID: workspace, producerID: producer, sequence: 5, receivedAt: Date()
        )
        XCTAssertEqual(try storedWatermark(at: url), 5)
    }

    func testProducerWithOnlySupersededBatchesDoesNotSurfaceAsAMachine() async throws {
        let (ledger, url) = try makeLedger()
        try await ledger.noteSupersededBatch(
            workspaceID: workspace, producerID: producer, sequence: 7, receivedAt: Date()
        )

        // The watermark row exists...
        XCTAssertEqual(try storedWatermark(at: url), 7)
        // ...but a machine whose metadata was never received is not rendered as
        // a nameless entry in the UI.
        let summaries = try await ledger.machineSummaries(
            workspaceID: workspace,
            now: ISO8601DateFormatter().date(from: "2026-08-03T12:00:00Z")!
        )
        XCTAssertTrue(summaries.isEmpty)

        // The first importable batch fills the real metadata in and the machine
        // appears with its own alias.
        let current = try RemotePayloadDecoder.decode(payload(sequence: 8, previous: 7))
        let importedCurrent = try await ledger.importBatch(current, sequence: 8, receivedAt: Date())
        XCTAssertTrue(importedCurrent)
        let healed = try await ledger.machineSummaries(
            workspaceID: workspace,
            now: ISO8601DateFormatter().date(from: "2026-08-03T12:00:00Z")!
        )
        XCTAssertEqual(healed.count, 1)
        XCTAssertEqual(healed[0].alias, "Example machine")
        XCTAssertEqual(healed[0].lastSequence, 8)
    }

    // MARK: - Adopt-on-first-batch

    func testImportAdoptsTheFirstEverSequenceForAProducer() async throws {
        let (ledger, _) = try makeLedger()

        // A Core that already skipped (or never saw) sequences 1...147 can never
        // obtain them. Starting at the first batch it can decrypt is the only
        // non-wedging behavior.
        let adopted = try RemotePayloadDecoder.decode(payload(sequence: 148, previous: 147))
        let importedAdopted = try await ledger.importBatch(adopted, sequence: 148, receivedAt: Date())
        XCTAssertTrue(importedAdopted)
        let summaries = try await ledger.machineSummaries(
            workspaceID: workspace,
            now: ISO8601DateFormatter().date(from: "2026-08-03T12:00:00Z")!
        )
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].lastSequence, 148)
        XCTAssertEqual(summaries[0].todayTokens, 15)
    }

    func testAdoptionDoesNotRelaxContiguityOnceAWatermarkExists() async throws {
        let (ledger, _) = try makeLedger()
        let adopted = try RemotePayloadDecoder.decode(payload(sequence: 148, previous: 147))
        _ = try await ledger.importBatch(adopted, sequence: 148, receivedAt: Date())

        // A real mid-stream gap must still be visible.
        let skipped = try RemotePayloadDecoder.decode(payload(sequence: 150, previous: 149))
        do {
            _ = try await ledger.importBatch(skipped, sequence: 150, receivedAt: Date())
            XCTFail("Expected a visible sequence gap once a watermark exists")
        } catch let error as RemoteSyncError {
            XCTAssertEqual(error, .sequenceGap(expected: 149, received: 150))
        }

        // A sequence below the watermark is still a rollback.
        let stale = try RemotePayloadDecoder.decode(payload(sequence: 147, previous: 146))
        do {
            _ = try await ledger.importBatch(stale, sequence: 147, receivedAt: Date())
            XCTFail("Expected a rollback for a sequence below the watermark")
        } catch let error as RemoteSyncError {
            XCTAssertEqual(error, .rollback)
        }

        // The contiguous next sequence still imports normally.
        let next = try RemotePayloadDecoder.decode(payload(sequence: 149, previous: 148))
        let importedNext = try await ledger.importBatch(next, sequence: 149, receivedAt: Date())
        XCTAssertTrue(importedNext)
    }

    // MARK: - Fixtures

    private func makeLedger() throws -> (RemoteUsageLedger, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-superseded-seq-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.sqlite3")
        return (try RemoteUsageLedger(url: url), url)
    }

    /// Read `remote_machines.last_sequence` straight from the file, so a
    /// watermark-only row (which `machineSummaries` deliberately hides) is still
    /// observable.
    private func storedWatermark(at url: URL) throws -> Int64? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle
        else {
            XCTFail("could not open the ledger for verification")
            throw RemoteSyncError.invalidConfiguration
        }
        defer { sqlite3_close_v2(handle) }
        var statement: OpaquePointer?
        let sql = """
            SELECT last_sequence FROM remote_machines
            WHERE workspace_id = ? AND producer_id = ?
            """
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            XCTFail("could not prepare the verification query")
            throw RemoteSyncError.invalidConfiguration
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, workspace.uuidString.lowercased(), -1, transient)
        sqlite3_bind_text(statement, 2, producer.uuidString.lowercased(), -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func payload(sequence: Int, previous: Int?) throws -> Data {
        let operation: [String: Any] = [
            "op": "usage_upsert",
            "source_key": String(repeating: "s", count: 43),
            "source_generation": 1,
            "event_key": String(repeating: "e", count: 42) + String(sequence),
            "tool": "codex",
            "occurred_at": "2026-08-03T06:00:00Z",
            "observed_at": "2026-08-03T06:01:00Z",
            "model": "example-model",
            "tokens": [
                "input": 10, "output": 5, "cache_read": 0,
                "cache_creation": 0, "reasoning": 0, "tool": 0,
                "total_only": NSNull()
            ],
            "request_count": 1,
            "service_tier": NSNull(),
            "accounting": "exact",
            "parser_version": 1
        ]
        let body: [String: Any] = [
            "schema": 1,
            "workspace_id": workspace.uuidString.lowercased(),
            "producer_id": producer.uuidString.lowercased(),
            "probe": [
                "alias": "Example machine", "version": "0.1.0",
                "platform": "linux-x86_64", "timezone": "UTC"
            ],
            "previous_sequence": previous.map { $0 as Any } ?? NSNull(),
            "operations": [operation],
            "status": [
                "last_scan_at": "2026-08-03T06:01:00Z",
                "backlog_batches": 1,
                "applied_control_sequence": 0,
                "sources": ["codex": "ok"]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }
}
