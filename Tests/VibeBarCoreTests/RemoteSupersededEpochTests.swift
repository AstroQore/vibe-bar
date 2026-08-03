import XCTest
import CryptoKit
@testable import VibeBarCore

/// A Core rotation (revoke Core → new Core enrolls) bumps `core_epoch` and
/// mints a new ingest key, but the Relay still holds a backlog of the previous
/// generation's ciphertext — encrypted to the revoked recipient key no current
/// device can decrypt. These tests pin the fix: such backlog is classified
/// `.supersededEnvelope` (skip + ack), never fatal, and the classification can
/// never be reached without a valid producer signature.
///
/// Synthetic UUIDs and freshly generated keys only. The crypto half seals real
/// envelopes with the exact reverse of `RemoteProtocolCrypto.openIngestEnvelope`
/// so a passing test also proves the seal/open pair agrees; the service half
/// drives `RemoteProbeService` against a stubbed `URLProtocol`.
final class RemoteSupersededEpochTests: XCTestCase {
    private let workspace = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let producer = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    // MARK: - openIngestEnvelope classification

    func testSupersededEpochEnvelopeIsClassifiedSuperseded() throws {
        let identity = makeIdentity()
        let producerSigningKey = P256.Signing.PrivateKey()
        let config = try makeConfig(
            coreEpoch: 2,
            ingestKeyID: "ingest-epoch-2",
            keys: [producer: producerSigningKey.publicKey.x963Representation]
        )
        // A properly signed batch from the previous generation: config.coreEpoch
        // - 1, with the old generation's key id.
        let envelope = try seal(
            signer: producerSigningKey,
            recipient: identity.recipientPrivateKey.publicKey,
            coreEpoch: 1,
            keyID: "ingest-epoch-1",
            sequence: 1,
            plaintext: Data("never decrypted".utf8)
        )
        let data = try JSONSerialization.data(withJSONObject: envelope)
        XCTAssertThrowsError(
            try RemoteProtocolCrypto.openIngestEnvelope(
                data, config: config, identity: identity,
                acceptedAt: iso("2026-08-03T06:01:00Z")
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncError, .supersededEnvelope,
                "An authenticated older-epoch batch must be superseded, not invalid_envelope"
            )
        }
    }

    func testSupersededClassificationRequiresAValidSignature() throws {
        let identity = makeIdentity()
        let producerSigningKey = P256.Signing.PrivateKey()
        // Not in the roster. It signs the batch, but the envelope still
        // advertises (and the config still expects) the producer's key.
        let attacker = P256.Signing.PrivateKey()
        let config = try makeConfig(
            coreEpoch: 2,
            ingestKeyID: "ingest-epoch-2",
            keys: [producer: producerSigningKey.publicKey.x963Representation]
        )
        let envelope = try seal(
            signer: producerSigningKey,
            signatureKey: attacker,
            recipient: identity.recipientPrivateKey.publicKey,
            coreEpoch: 1,
            keyID: "ingest-epoch-1",
            sequence: 1,
            plaintext: Data("forged".utf8)
        )
        let data = try JSONSerialization.data(withJSONObject: envelope)
        XCTAssertThrowsError(
            try RemoteProtocolCrypto.openIngestEnvelope(
                data, config: config, identity: identity,
                acceptedAt: iso("2026-08-03T06:01:00Z")
            )
        ) { error in
            // The signature gate fires before the superseded decision, so a
            // forged old-epoch batch is rejected, never silently skipped.
            XCTAssertEqual(error as? RemoteSyncError, .invalidSignature)
            XCTAssertNotEqual(error as? RemoteSyncError, .supersededEnvelope)
        }
    }

    func testFutureEpochStaysFatal() throws {
        let identity = makeIdentity()
        let producerSigningKey = P256.Signing.PrivateKey()
        let config = try makeConfig(
            coreEpoch: 2,
            ingestKeyID: "ingest-epoch-2",
            keys: [producer: producerSigningKey.publicKey.x963Representation]
        )
        // A properly signed batch whose epoch is AHEAD of this Core: the Core is
        // behind and this must surface, never skip forward.
        let envelope = try seal(
            signer: producerSigningKey,
            recipient: identity.recipientPrivateKey.publicKey,
            coreEpoch: 3,
            keyID: "ingest-epoch-3",
            sequence: 1,
            plaintext: Data("ahead".utf8)
        )
        let data = try JSONSerialization.data(withJSONObject: envelope)
        XCTAssertThrowsError(
            try RemoteProtocolCrypto.openIngestEnvelope(
                data, config: config, identity: identity,
                acceptedAt: iso("2026-08-03T06:01:00Z")
            )
        ) { error in
            XCTAssertEqual(error as? RemoteSyncError, .invalidEnvelope)
        }
    }

    // MARK: - Service-level: superseded backlog does not wedge the stream

    @MainActor
    func testRefreshSkipsSupersededBatchAndImportsCurrentOne() async throws {
        let identity = makeIdentity()
        let producerSigningKey = P256.Signing.PrivateKey()
        let config = try makeConfig(
            coreEpoch: 2,
            ingestKeyID: "ingest-epoch-2",
            keys: [producer: producerSigningKey.publicKey.x963Representation]
        )

        // First batch: superseded backlog from epoch 1, encrypted to a revoked
        // recipient key the current Core does not hold.
        let superseded = try seal(
            signer: producerSigningKey,
            recipient: P256.KeyAgreement.PrivateKey().publicKey,
            coreEpoch: 1,
            keyID: "ingest-epoch-1",
            sequence: 1,
            plaintext: Data("cannot be opened".utf8)
        )
        // Second batch: current epoch, encrypted to this Core's recipient key,
        // carrying a real usage payload at sequence 1.
        let current = try seal(
            signer: producerSigningKey,
            recipient: identity.recipientPrivateKey.publicKey,
            coreEpoch: 2,
            keyID: "ingest-epoch-2",
            sequence: 1,
            plaintext: try usagePayload(sequence: 1)
        )

        let received = Int64(iso("2026-08-03T06:01:00Z").timeIntervalSince1970)
        StubRelay.reset()
        StubRelay.deviceKey = producerSigningKey.publicKey.x963Representation
        StubRelay.producer = producer
        StubRelay.core = config.coreDeviceID
        StubRelay.page = [
            ["cursor": "c1", "received_at": received, "envelope": superseded],
            ["cursor": "c2", "received_at": received, "envelope": current]
        ]
        StubRelay.nextCursor = "c2"
        defer { StubRelay.reset() }

        let client = makeClient(config)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-superseded-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = try RemoteUsageLedger(url: directory.appendingPathComponent("ledger.sqlite3"))

        let service = RemoteProbeService(
            config: config, identity: identity, client: client, ledger: ledger
        )
        await service.refresh()

        // The superseded batch was skipped but not fatal: the current batch
        // imported and the sync succeeded.
        XCTAssertNil(service.lastErrorCode)
        XCTAssertEqual(service.machines.count, 1)
        XCTAssertEqual(service.machines.first?.producerID, producer)
        XCTAssertEqual(service.machines.first?.allTimeTokens, 15)

        // Both cursors were acknowledged so the Relay GC can reclaim them, and
        // the ledger cursor advanced past BOTH batches.
        XCTAssertEqual(Set(StubRelay.acknowledged()), ["c1", "c2"])
        let cursor = try await ledger.relayCursor(workspaceID: workspace)
        XCTAssertEqual(cursor, "c2")
    }

    // MARK: - Fixtures

    private func makeIdentity() -> RemoteCoreIdentity {
        RemoteCoreIdentity(
            signingPrivateKey: P256.Signing.PrivateKey(),
            recipientPrivateKey: P256.KeyAgreement.PrivateKey()
        )
    }

    private func makeConfig(
        coreEpoch: Int,
        ingestKeyID: String,
        keys: [UUID: Data]
    ) throws -> RemoteCoreConfig {
        try RemoteCoreConfig(
            workspaceID: workspace,
            coreDeviceID: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
            relayURL: URL(string: "https://relay.example.invalid")!,
            coreEpoch: coreEpoch,
            ingestKeyID: ingestKeyID,
            probeSigningPublicKeys: keys
        )
    }

    private func iso(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    /// Seal an ingest envelope with the exact reverse of the open path:
    /// AES-GCM over the plaintext with the canonical header as AAD, then a P-256
    /// signature over the canonical unsigned envelope. `signatureKey`, when set,
    /// signs with a different key than the one the envelope advertises — used to
    /// forge a bad signature while keeping the advertised producer key intact.
    private func seal(
        signer: P256.Signing.PrivateKey,
        signatureKey: P256.Signing.PrivateKey? = nil,
        recipient: P256.KeyAgreement.PublicKey,
        coreEpoch: Int,
        keyID: String,
        sequence: Int64,
        createdAt: String = "2026-08-03T06:00:00Z",
        expiresAt: String = "2026-09-02T06:00:00Z",
        plaintext: Data,
        nonce: Data = Data((0..<12).map { UInt8($0) })
    ) throws -> [String: Any] {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let header: [String: Any] = [
            "protocol_version": 1,
            "minimum_consumer_version": 1,
            "workspace_id": workspace.uuidString.lowercased(),
            "stream": "ingest",
            "producer_id": producer.uuidString.lowercased(),
            "sequence": Int(sequence),
            "core_epoch": coreEpoch,
            "key_id": keyID,
            "created_at": createdAt,
            "expires_at": expiresAt,
            "ephemeral_public_key": ephemeral.publicKey.x963Representation.base64EncodedString(),
            "nonce": nonce.base64EncodedString(),
            "signing_public_key": signer.publicKey.x963Representation.base64EncodedString()
        ]
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let symmetricKey = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("VibeBar Sync Protocol v1\0".utf8),
            sharedInfo: hkdfInfo(sequence: sequence),
            outputByteCount: 32
        )
        let sealed = try AES.GCM.seal(
            plaintext,
            using: symmetricKey,
            nonce: AES.GCM.Nonce(data: nonce),
            authenticating: try canonical(header)
        )
        var ciphertext = sealed.ciphertext
        ciphertext.append(sealed.tag)
        var object = header
        object["ciphertext"] = ciphertext.base64EncodedString()
        let signature = try (signatureKey ?? signer)
            .signature(for: try canonical(object)).rawRepresentation
        object["signature"] = signature.base64EncodedString()
        return object
    }

    /// Canonicalize through the same round trip `openIngestEnvelope` performs
    /// (it re-parses `Data` before encoding), so the AAD and signature bytes
    /// computed here match byte-for-byte.
    private func canonical(_ object: [String: Any]) throws -> Data {
        let reparsed = try JSONSerialization.jsonObject(
            with: try JSONSerialization.data(withJSONObject: object)
        )
        return try RemoteCanonicalJSON.encode(reparsed)
    }

    private func hkdfInfo(sequence: Int64) -> Data {
        var output = Data("vibebar/envelope/v1\0ingest\0".utf8)
        output.append(contentsOf: workspace.uuidString.lowercased().utf8)
        output.append(0)
        output.append(contentsOf: producer.uuidString.lowercased().utf8)
        output.append(0)
        var bigEndian = UInt64(sequence).bigEndian
        withUnsafeBytes(of: &bigEndian) { output.append(contentsOf: $0) }
        return output
    }

    private func usagePayload(sequence: Int) throws -> Data {
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
            "previous_sequence": sequence == 1 ? NSNull() : (sequence - 1) as Any,
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

    private func makeClient(_ config: RemoteCoreConfig) -> RemoteRelayClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubRelay.self]
        return RemoteRelayClient(
            config: config,
            bearerToken: String(repeating: "t", count: 40),
            session: URLSession(configuration: configuration)
        )
    }
}

/// Stubs the three Relay endpoints the refresh loop touches (devices roster,
/// batch page, ack) and records the cursors that were acknowledged.
private final class StubRelay: URLProtocol {
    nonisolated(unsafe) static var page: [[String: Any]] = []
    nonisolated(unsafe) static var nextCursor = ""
    nonisolated(unsafe) static var deviceKey = Data()
    nonisolated(unsafe) static var producer = UUID()
    nonisolated(unsafe) static var core = UUID()
    nonisolated(unsafe) private static var acks: [String] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        page = []
        nextCursor = ""
        deviceKey = Data()
        acks = []
    }

    static func acknowledged() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return acks
    }

    private static func recordAck(_ cursor: String) {
        lock.lock(); defer { lock.unlock() }
        acks.append(cursor)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Cache-Control": "no-store"]
        )!
        let body = Self.body(for: request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(for request: URLRequest) -> Data? {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/devices") {
            return try? JSONSerialization.data(withJSONObject: [
                "devices": [
                    [
                        "device_id": producer.uuidString.lowercased(),
                        "role": "probe",
                        "status": "active",
                        "signing_public_key": deviceKey.base64EncodedString()
                    ],
                    [
                        "device_id": core.uuidString.lowercased(),
                        "role": "core",
                        "status": "active"
                    ]
                ]
            ])
        }
        if path.hasSuffix("/batches") {
            return try? JSONSerialization.data(withJSONObject: [
                "batches": page,
                "next_cursor": nextCursor
            ])
        }
        if path.hasSuffix("/acks") {
            let cursor = ackCursor(request)
            recordAck(cursor)
            return try? JSONSerialization.data(withJSONObject: ["acknowledged_cursor": cursor])
        }
        return nil
    }

    private static func ackCursor(_ request: URLRequest) -> String {
        let data = requestBody(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cursor = object["cursor"] as? String
        else { return "" }
        return cursor
    }

    /// URLProtocol receives POST bodies via `httpBodyStream`, not `httpBody`.
    private static func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
