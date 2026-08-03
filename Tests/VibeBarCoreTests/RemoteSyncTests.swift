import XCTest
import CryptoKit
@testable import VibeBarCore

final class RemoteSyncTests: XCTestCase {
    private let workspace = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let producer = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    func testPythonGoldenVectorDecryptsAndValidates() throws {
        let vector = try loadVector()
        let expected = vector["expected"] as! [String: Any]
        let envelope = expected["envelope"] as! [String: Any]
        let signing = Data(base64Encoded: expected["signing_public_key"] as! String)!
        let config = try RemoteCoreConfig(
            workspaceID: workspace,
            coreDeviceID: UUID(),
            relayURL: URL(string: "https://relay.example.invalid")!,
            coreEpoch: 1,
            ingestKeyID: "ingest-epoch-1",
            probeSigningPublicKeys: [producer: signing]
        )
        let identity = RemoteCoreIdentity(
            signingPrivateKey: P256.Signing.PrivateKey(),
            recipientPrivateKey: try P256.KeyAgreement.PrivateKey(
                rawRepresentation: scalar(3)
            )
        )
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let opened = try RemoteProtocolCrypto.openIngestEnvelope(
            data,
            config: config,
            identity: identity,
            acceptedAt: ISO8601DateFormatter().date(from: "2026-08-04T00:00:00Z")!
        )
        let payload = try RemotePayloadDecoder.decode(opened.plaintext)
        XCTAssertEqual(opened.sequence, 1)
        XCTAssertEqual(opened.producerID, producer)
        XCTAssertEqual(payload.probe.alias, "Example machine")
        XCTAssertTrue(payload.operations.isEmpty)
    }

    func testGoldenVectorRejectsMutation() throws {
        let vector = try loadVector()
        let expected = vector["expected"] as! [String: Any]
        var envelope = expected["envelope"] as! [String: Any]
        let signing = Data(base64Encoded: expected["signing_public_key"] as! String)!
        let config = try RemoteCoreConfig(
            workspaceID: workspace,
            coreDeviceID: UUID(),
            relayURL: URL(string: "https://relay.example.invalid")!,
            coreEpoch: 1,
            ingestKeyID: "ingest-epoch-1",
            probeSigningPublicKeys: [producer: signing]
        )
        let identity = RemoteCoreIdentity(
            signingPrivateKey: P256.Signing.PrivateKey(),
            recipientPrivateKey: try P256.KeyAgreement.PrivateKey(rawRepresentation: scalar(3))
        )
        envelope["key_id"] = "mutated"
        let data = try JSONSerialization.data(withJSONObject: envelope)
        XCTAssertThrowsError(
            try RemoteProtocolCrypto.openIngestEnvelope(
                data,
                config: config,
                identity: identity,
                acceptedAt: ISO8601DateFormatter().date(from: "2026-08-04T00:00:00Z")!
            )
        )
    }

    func testCoreConfigurationUsesUUIDKeyedJSONObjects() throws {
        let signing = P256.Signing.PrivateKey().publicKey.x963Representation
        let provisioning = try RemoteCoreProvisioning(
            workspaceID: workspace,
            coreDeviceID: UUID(),
            relayURL: URL(string: "https://relay.example.invalid")!,
            relayBearerToken: String(repeating: "t", count: 32),
            coreEpoch: 1,
            ingestKeyID: "ingest-epoch-1",
            probeSigningPublicKeys: [producer: signing]
        )
        let encoded = try JSONEncoder().encode(provisioning)
        let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        let keys = try XCTUnwrap(object["probe_signing_public_keys"] as? [String: String])
        XCTAssertEqual(Set(keys.keys), [producer.uuidString.lowercased()])
        XCTAssertEqual(try JSONDecoder().decode(RemoteCoreProvisioning.self, from: encoded).workspaceID, workspace)
    }

    func testLedgerIsIdempotentAndStopsAtSequenceGap() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = try RemoteUsageLedger(url: directory.appendingPathComponent("ledger.sqlite3"))
        let first = try RemotePayloadDecoder.decode(payload(sequence: 1, previous: nil, generation: 1))
        let inserted = try await ledger.importBatch(first, sequence: 1, receivedAt: Date())
        XCTAssertTrue(inserted)
        let duplicate = try await ledger.importBatch(first, sequence: 1, receivedAt: Date())
        XCTAssertFalse(duplicate)

        let third = try RemotePayloadDecoder.decode(payload(sequence: 3, previous: 2, generation: 1))
        do {
            _ = try await ledger.importBatch(third, sequence: 3, receivedAt: Date())
            XCTFail("Expected a visible sequence gap")
        } catch let error as RemoteSyncError {
            XCTAssertEqual(error, .sequenceGap(expected: 2, received: 3))
        }
        let summaries = try await ledger.machineSummaries(
            workspaceID: workspace,
            now: ISO8601DateFormatter().date(from: "2026-08-03T12:00:00Z")!
        )
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].todayTokens, 15)
        XCTAssertEqual(summaries[0].lastSequence, 1)
    }

    func testPayloadRejectsUnknownPrivacyField() throws {
        var object = try JSONSerialization.jsonObject(
            with: payload(sequence: 1, previous: nil, generation: 1)
        ) as! [String: Any]
        object["transcript"] = "must never be accepted"
        XCTAssertThrowsError(
            try RemotePayloadDecoder.decode(JSONSerialization.data(withJSONObject: object))
        )
    }

    private func payload(sequence: Int, previous: Int?, generation: Int) throws -> Data {
        let operation: [String: Any] = [
            "op": "usage_upsert",
            "source_key": String(repeating: "s", count: 43),
            "source_generation": generation,
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

    private func loadVector() throws -> [String: Any] {
        let file = try XCTUnwrap(
            Bundle.module.url(
                forResource: "ingest-p256-v1",
                withExtension: "json",
                subdirectory: "RemoteSync"
            )
        )
        return try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    }

    private func scalar(_ value: UInt8) -> Data {
        Data(repeating: 0, count: 31) + Data([value])
    }
}
