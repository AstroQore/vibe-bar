import XCTest
import CryptoKit
@testable import VibeBarCore

/// dev.20 acknowledged every batch individually inside the per-batch loop, so
/// draining a backlog of a few hundred queued batches fired that many
/// `POST /acks` in a tight burst. The Relay sits behind an nginx rate limiter:
/// the burst tripped it, nginx answered 429, and because that is not the
/// superseded case it escaped the per-batch catch and aborted the whole cycle —
/// the cursor never advanced and the UI reported `relay_http_error` with
/// "Last sync: never" even though batches had imported fine before the abort.
///
/// These tests pin both halves of the fix: the ack is a monotonic watermark, so
/// one per page is exactly equivalent to one per batch; and a rate-limited
/// request is retried with bounded backoff instead of aborting the cycle.
///
/// Synthetic UUIDs and freshly generated keys only; every envelope is sealed
/// locally with the exact reverse of `RemoteProtocolCrypto.openIngestEnvelope`.
final class RemoteAckBatchingTests: XCTestCase {
    private let workspace = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let producer = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    override func tearDown() {
        AckBatchingStubRelay.reset()
        super.tearDown()
    }

    // MARK: - One ack per page

    /// Two full pages — twenty batches — cost two acks, not twenty. This is the
    /// request-count reduction the fix is for: the ack cursor is a watermark
    /// (`last_batch_id = MAX(existing, through)`), so the last batch of a page
    /// covers everything below it.
    @MainActor
    func testAFullPageIsAcknowledgedOnceAtItsLastCursor() async throws {
        let identity = makeIdentity()
        let signingKey = P256.Signing.PrivateKey()
        let config = try makeConfig(keys: [producer: signingKey.publicKey.x963Representation])

        AckBatchingStubRelay.reset()
        AckBatchingStubRelay.deviceKey = signingKey.publicKey.x963Representation
        AckBatchingStubRelay.producer = producer
        AckBatchingStubRelay.core = config.coreDeviceID
        AckBatchingStubRelay.pages = [
            try page(sequences: Array(1...10), signer: signingKey, identity: identity),
            try page(sequences: Array(11...20), signer: signingKey, identity: identity)
        ]

        let (ledger, service) = try makeService(config: config, identity: identity)
        await service.refresh()

        XCTAssertNil(service.lastErrorCode)
        // Twenty batches imported...
        XCTAssertEqual(service.machines.count, 1)
        XCTAssertEqual(service.machines.first?.lastSequence, 20)
        XCTAssertEqual(service.machines.first?.allTimeTokens, 20 * 15)
        // ...through exactly two acks, one per page, each at that page's last
        // cursor. The pre-fix loop issued twenty.
        XCTAssertEqual(AckBatchingStubRelay.acknowledged(), ["c10", "c20"])
        XCTAssertEqual(
            AckBatchingStubRelay.ackAttemptCount(), 2,
            "One ack request per page, not one per batch"
        )
        // And the persisted cursor is the same watermark.
        let cursor = try await ledger.relayCursor(
            workspaceID: workspace,
            coreDeviceID: config.coreDeviceID
        )
        XCTAssertEqual(cursor, "c20")
    }

    // MARK: - Surviving the rate limiter

    @MainActor
    func testARateLimitedAckIsRetriedAndTheCycleSucceeds() async throws {
        let identity = makeIdentity()
        let signingKey = P256.Signing.PrivateKey()
        let config = try makeConfig(keys: [producer: signingKey.publicKey.x963Representation])

        AckBatchingStubRelay.reset()
        AckBatchingStubRelay.deviceKey = signingKey.publicKey.x963Representation
        AckBatchingStubRelay.producer = producer
        AckBatchingStubRelay.core = config.coreDeviceID
        AckBatchingStubRelay.pages = [
            try page(sequences: [1, 2, 3], signer: signingKey, identity: identity)
        ]
        // nginx refuses the first attempt exactly as it did in production.
        AckBatchingStubRelay.rateLimitedAckAttempts = 1

        let (ledger, service) = try makeService(config: config, identity: identity)
        await service.refresh()

        // The 429 is a "come back shortly", not a failure: the retry lands and
        // the cycle finishes clean.
        XCTAssertNil(service.lastErrorCode)
        XCTAssertEqual(service.machines.first?.lastSequence, 3)
        XCTAssertEqual(AckBatchingStubRelay.ackAttemptCount(), 2, "One 429, then one success")
        XCTAssertEqual(AckBatchingStubRelay.acknowledged(), ["c3"])
        let cursor = try await ledger.relayCursor(
            workspaceID: workspace,
            coreDeviceID: config.coreDeviceID
        )
        XCTAssertEqual(cursor, "c3")
    }

    /// 503 is the other "come back shortly" answer nginx and CDNs use when they
    /// shed load, and it must be treated like 429 rather than aborting.
    @MainActor
    func testAShedAckIsRetriedAndTheCycleSucceeds() async throws {
        let identity = makeIdentity()
        let signingKey = P256.Signing.PrivateKey()
        let config = try makeConfig(keys: [producer: signingKey.publicKey.x963Representation])

        AckBatchingStubRelay.reset()
        AckBatchingStubRelay.deviceKey = signingKey.publicKey.x963Representation
        AckBatchingStubRelay.producer = producer
        AckBatchingStubRelay.core = config.coreDeviceID
        AckBatchingStubRelay.pages = [
            try page(sequences: [1], signer: signingKey, identity: identity)
        ]
        AckBatchingStubRelay.rateLimitedAckStatus = 503
        AckBatchingStubRelay.rateLimitedAckAttempts = 2

        let (_, service) = try makeService(config: config, identity: identity)
        await service.refresh()

        XCTAssertNil(service.lastErrorCode)
        XCTAssertEqual(AckBatchingStubRelay.ackAttemptCount(), 3, "Two 503s, then the last attempt")
        XCTAssertEqual(AckBatchingStubRelay.acknowledged(), ["c1"])
    }

    @MainActor
    func testAnUnrelentingRateLimitRecordsTheErrorAfterBoundedRetries() async throws {
        let identity = makeIdentity()
        let signingKey = P256.Signing.PrivateKey()
        let config = try makeConfig(keys: [producer: signingKey.publicKey.x963Representation])

        AckBatchingStubRelay.reset()
        AckBatchingStubRelay.deviceKey = signingKey.publicKey.x963Representation
        AckBatchingStubRelay.producer = producer
        AckBatchingStubRelay.core = config.coreDeviceID
        AckBatchingStubRelay.pages = [
            try page(sequences: [1, 2], signer: signingKey, identity: identity)
        ]
        AckBatchingStubRelay.rateLimitedAckAttempts = .max

        let (_, service) = try makeService(config: config, identity: identity)
        await service.refresh()

        // Retries are bounded: three attempts in all, then the error surfaces
        // exactly as it did before the fix. The point is that the cycle ends —
        // it does not spin.
        XCTAssertEqual(AckBatchingStubRelay.ackAttemptCount(), 3)
        XCTAssertEqual(service.lastErrorCode, RemoteSyncError.http(429).code)
        XCTAssertTrue(AckBatchingStubRelay.acknowledged().isEmpty)
        // The single batch page was fetched once; a wedged ack must not send the
        // loop around again.
        XCTAssertEqual(AckBatchingStubRelay.batchRequestCount(), 1)
    }

    /// A non-retryable status is a real failure and must not buy three attempts
    /// and two sleeps before surfacing.
    @MainActor
    func testAnUnauthorizedAckIsNotRetried() async throws {
        let identity = makeIdentity()
        let signingKey = P256.Signing.PrivateKey()
        let config = try makeConfig(keys: [producer: signingKey.publicKey.x963Representation])

        AckBatchingStubRelay.reset()
        AckBatchingStubRelay.deviceKey = signingKey.publicKey.x963Representation
        AckBatchingStubRelay.producer = producer
        AckBatchingStubRelay.core = config.coreDeviceID
        AckBatchingStubRelay.pages = [
            try page(sequences: [1], signer: signingKey, identity: identity)
        ]
        AckBatchingStubRelay.rateLimitedAckStatus = 401
        AckBatchingStubRelay.rateLimitedAckAttempts = .max

        let (_, service) = try makeService(config: config, identity: identity)
        await service.refresh()

        XCTAssertEqual(AckBatchingStubRelay.ackAttemptCount(), 1, "401 fails on the first try")
        XCTAssertEqual(service.lastErrorCode, RemoteSyncError.http(401).code)
    }

    // MARK: - Forward progress across a mid-page failure

    /// Batching the ack must not cost forward progress. When a batch in the
    /// middle of a page fails for a non-superseded reason the cycle still aborts
    /// — but the batches ahead of it already landed in the ledger, so their
    /// watermark is committed before the error propagates. Otherwise every
    /// future cycle would re-walk the same prefix forever.
    @MainActor
    func testAMidPageFailureStillAcknowledgesTheBatchesBeforeIt() async throws {
        let identity = makeIdentity()
        let signingKey = P256.Signing.PrivateKey()
        let config = try makeConfig(keys: [producer: signingKey.publicKey.x963Representation])

        // Sequences 1 and 2 import; 4 skips a slot, which the ledger reports as
        // a visible mid-stream gap.
        let first = try seal(
            signer: signingKey,
            recipient: identity.recipientPrivateKey.publicKey,
            sequence: 1,
            plaintext: try usagePayload(sequence: 1)
        )
        let second = try seal(
            signer: signingKey,
            recipient: identity.recipientPrivateKey.publicKey,
            sequence: 2,
            plaintext: try usagePayload(sequence: 2)
        )
        let gapped = try seal(
            signer: signingKey,
            recipient: identity.recipientPrivateKey.publicKey,
            sequence: 4,
            plaintext: try usagePayload(sequence: 4)
        )
        let received = Int64(iso("2026-08-03T06:01:00Z").timeIntervalSince1970)

        AckBatchingStubRelay.reset()
        AckBatchingStubRelay.deviceKey = signingKey.publicKey.x963Representation
        AckBatchingStubRelay.producer = producer
        AckBatchingStubRelay.core = config.coreDeviceID
        AckBatchingStubRelay.pages = [[
            ["cursor": "c1", "received_at": received, "envelope": first],
            ["cursor": "c2", "received_at": received, "envelope": second],
            ["cursor": "c3", "received_at": received, "envelope": gapped]
        ]]

        let (ledger, service) = try makeService(config: config, identity: identity)
        await service.refresh()

        // The cycle aborts and reports the real reason, unchanged.
        XCTAssertEqual(service.lastErrorCode, "sequence_gap")
        // But the prefix that did import is acknowledged — once, at the last
        // batch that actually succeeded.
        XCTAssertEqual(AckBatchingStubRelay.acknowledged(), ["c2"])
        let cursor = try await ledger.relayCursor(
            workspaceID: workspace,
            coreDeviceID: config.coreDeviceID
        )
        XCTAssertEqual(cursor, "c2", "The next cycle resumes after the last good batch")
        // The error path's recordSync carries the cursor over rather than
        // clearing it, so the recovered position survives the failure record.
        XCTAssertEqual(service.machines.first?.lastSequence, 2)
    }

    // MARK: - Fixtures

    @MainActor
    private func makeService(
        config: RemoteCoreConfig,
        identity: RemoteCoreIdentity
    ) throws -> (RemoteUsageLedger, RemoteProbeService) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-ack-batching-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let ledger = try RemoteUsageLedger(url: directory.appendingPathComponent("ledger.sqlite3"))

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [AckBatchingStubRelay.self]
        let client = RemoteRelayClient(
            config: config,
            bearerToken: String(repeating: "t", count: 40),
            session: URLSession(configuration: sessionConfig)
        )
        // Near-zero backoff: the retry arithmetic is what is under test, not the
        // wall-clock waits. Production keeps the 1s / 2s default.
        let service = RemoteProbeService(
            config: config,
            identity: identity,
            client: client,
            ledger: ledger,
            relayRetryDelays: [.zero, .zero]
        )
        return (ledger, service)
    }

    /// One relay page: contiguous sequences, cursors `c<sequence>`, all sealed
    /// to this Core's current epoch.
    private func page(
        sequences: [Int64],
        signer: P256.Signing.PrivateKey,
        identity: RemoteCoreIdentity
    ) throws -> [[String: Any]] {
        let received = Int64(iso("2026-08-03T06:01:00Z").timeIntervalSince1970)
        return try sequences.map { sequence in
            [
                "cursor": "c\(sequence)",
                "received_at": received,
                "envelope": try seal(
                    signer: signer,
                    recipient: identity.recipientPrivateKey.publicKey,
                    sequence: sequence,
                    plaintext: try usagePayload(sequence: Int(sequence))
                )
            ]
        }
    }

    private func makeIdentity() -> RemoteCoreIdentity {
        RemoteCoreIdentity(
            signingPrivateKey: P256.Signing.PrivateKey(),
            recipientPrivateKey: P256.KeyAgreement.PrivateKey()
        )
    }

    private func makeConfig(keys: [UUID: Data]) throws -> RemoteCoreConfig {
        try RemoteCoreConfig(
            workspaceID: workspace,
            coreDeviceID: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
            relayURL: URL(string: "https://relay.example.invalid")!,
            coreEpoch: 1,
            ingestKeyID: "ingest-epoch-1",
            probeSigningPublicKeys: keys
        )
    }

    private func iso(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    /// Seal an ingest envelope with the exact reverse of the open path: AES-GCM
    /// over the plaintext with the canonical header as AAD, then a P-256
    /// signature over the canonical unsigned envelope.
    private func seal(
        signer: P256.Signing.PrivateKey,
        recipient: P256.KeyAgreement.PublicKey,
        coreEpoch: Int = 1,
        keyID: String = "ingest-epoch-1",
        sequence: Int64,
        createdAt: String = "2026-08-03T06:00:00Z",
        expiresAt: String = "2026-09-02T06:00:00Z",
        plaintext: Data
    ) throws -> [String: Any] {
        let nonce = Data((0..<12).map { _ in UInt8.random(in: .min ... .max) })
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
        object["signature"] = try signer
            .signature(for: try canonical(object)).rawRepresentation.base64EncodedString()
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
}

/// Stubs the three Relay endpoints the refresh loop touches. `/batches` drains
/// `pages` in order and then answers empty, so the loop terminates the way a
/// real drained stream does. `/acks` can be told to answer a retryable (or
/// non-retryable) status for the first N attempts, which is how the production
/// nginx 429 is reproduced. Every ack attempt and batch request is counted so a
/// test can assert on the request volume itself, not just the outcome.
private final class AckBatchingStubRelay: URLProtocol {
    nonisolated(unsafe) static var pages: [[[String: Any]]] = []
    nonisolated(unsafe) static var deviceKey = Data()
    nonisolated(unsafe) static var producer = UUID()
    nonisolated(unsafe) static var core = UUID()
    /// How many leading `/acks` attempts are refused before the first success.
    /// `.max` refuses every attempt.
    nonisolated(unsafe) static var rateLimitedAckAttempts = 0
    nonisolated(unsafe) static var rateLimitedAckStatus = 429
    nonisolated(unsafe) private static var acks: [String] = []
    nonisolated(unsafe) private static var ackAttempts = 0
    nonisolated(unsafe) private static var batchRequests = 0
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        pages = []
        deviceKey = Data()
        rateLimitedAckAttempts = 0
        rateLimitedAckStatus = 429
        acks = []
        ackAttempts = 0
        batchRequests = 0
    }

    static func acknowledged() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return acks
    }

    static func ackAttemptCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return ackAttempts
    }

    static func batchRequestCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return batchRequests
    }

    private static func nextPage() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        batchRequests += 1
        guard !pages.isEmpty else { return [] }
        return pages.removeFirst()
    }

    /// Returns the status this attempt should answer, recording the attempt.
    private static func ackStatus() -> Int {
        lock.lock(); defer { lock.unlock() }
        ackAttempts += 1
        return ackAttempts <= rateLimitedAckAttempts ? rateLimitedAckStatus : 200
    }

    private static func recordAck(_ cursor: String) {
        lock.lock(); defer { lock.unlock() }
        acks.append(cursor)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/devices") {
            respond(status: 200, body: [
                "devices": [
                    [
                        "device_id": Self.producer.uuidString.lowercased(),
                        "role": "probe",
                        "status": "active",
                        "signing_public_key": Self.deviceKey.base64EncodedString()
                    ],
                    [
                        "device_id": Self.core.uuidString.lowercased(),
                        "role": "core",
                        "status": "active"
                    ]
                ]
            ])
            return
        }
        if path.hasSuffix("/batches") {
            let batches = Self.nextPage()
            let last = batches.last?["cursor"] as? String ?? ""
            respond(status: 200, body: ["batches": batches, "next_cursor": last])
            return
        }
        if path.hasSuffix("/acks") {
            let status = Self.ackStatus()
            guard status == 200 else {
                respond(status: status, body: ["error": "rate_limited"])
                return
            }
            let cursor = Self.ackCursor(request)
            Self.recordAck(cursor)
            respond(status: 200, body: ["acknowledged_cursor": cursor])
            return
        }
        respond(status: 200, body: [:])
    }

    private func respond(status: Int, body: [String: Any]) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Cache-Control": "no-store"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data = try? JSONSerialization.data(withJSONObject: body) {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
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
