import XCTest
@testable import VibeBarCore

final class RemoteCostAggregationTests: XCTestCase {
    private let workspace = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let producer = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let formatter = ISO8601DateFormatter()

    func testSelectedMachineBuildsProviderSnapshotAndLearnsFiveMinuteCadence() async throws {
        let ledger = try makeLedger()
        let first = try RemotePayloadDecoder.decode(payload(sequence: 1, previous: nil))
        let second = try RemotePayloadDecoder.decode(payload(sequence: 2, previous: 1))
        _ = try await ledger.importBatch(
            first,
            sequence: 1,
            receivedAt: try XCTUnwrap(formatter.date(from: "2026-08-03T06:05:00Z"))
        )
        _ = try await ledger.importBatch(
            second,
            sequence: 2,
            receivedAt: try XCTUnwrap(formatter.date(from: "2026-08-03T06:10:00Z"))
        )

        let now = try XCTUnwrap(formatter.date(from: "2026-08-03T12:00:00Z"))
        let machines = try await ledger.machineSummaries(workspaceID: workspace, now: now)
        let machine = try XCTUnwrap(machines.first)
        XCTAssertEqual(machine.id, workspace.uuidString.lowercased() + ":" + producer.uuidString.lowercased())
        XCTAssertEqual(machine.expectedReportIntervalSeconds, 300)

        let snapshots = try await ledger.costSnapshots(
            workspaceID: workspace,
            selectedMachineIDs: [machine.id],
            now: now
        )
        let codex = try XCTUnwrap(snapshots[.codex])
        XCTAssertEqual(codex.todayTokens, 30)
        XCTAssertEqual(codex.allTimeTokens, 30)
        XCTAssertEqual(codex.todayRequests, 2)
        XCTAssertEqual(codex.jsonlFilesFound, 1)
        XCTAssertEqual(codex.dailyHistory.map(\.totalTokens), [30])

        let excluded = try await ledger.costSnapshots(
            workspaceID: workspace,
            selectedMachineIDs: [],
            now: now
        )
        XCTAssertTrue(excluded.isEmpty)
    }

    func testFreshnessUsesLearnedCadenceAndKeepsLegacyFallback() throws {
        let lastSeen = try XCTUnwrap(formatter.date(from: "2026-08-03T06:00:00Z"))
        XCTAssertEqual(
            RemoteMachineFreshness.evaluate(
                lastSeenAt: lastSeen,
                expectedReportIntervalSeconds: 300,
                now: lastSeen.addingTimeInterval(240)
            ),
            .live
        )
        XCTAssertEqual(
            RemoteMachineFreshness.evaluate(
                lastSeenAt: lastSeen,
                expectedReportIntervalSeconds: 300,
                now: lastSeen.addingTimeInterval(500)
            ),
            .delayed
        )
        XCTAssertEqual(
            RemoteMachineFreshness.evaluate(
                lastSeenAt: lastSeen,
                expectedReportIntervalSeconds: 300,
                now: lastSeen.addingTimeInterval(800)
            ),
            .stale
        )
        XCTAssertEqual(
            RemoteMachineFreshness.evaluate(
                lastSeenAt: lastSeen,
                expectedReportIntervalSeconds: nil,
                now: lastSeen.addingTimeInterval(180)
            ),
            .delayed
        )
    }

    private func makeLedger() throws -> RemoteUsageLedger {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-cost-aggregation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try RemoteUsageLedger(url: directory.appendingPathComponent("ledger.sqlite3"))
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
            "model": "synthetic-model",
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
                "backlog_batches": 0,
                "applied_control_sequence": 0,
                "sources": ["codex": "ok"]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }
}
