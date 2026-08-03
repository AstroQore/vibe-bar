import XCTest
import CryptoKit
import SQLite3
@testable import VibeBarCore

/// The Relay HMAC-binds every batch cursor to the device that consumed it. When
/// a Mac revokes its old Core and re-joins the same workspace as a *new* Core
/// (new `core_device_id`, same `workspace_id`), the cursor cached locally by the
/// old Core no longer belongs to the current principal — replaying it makes the
/// Relay answer 400 and the sync wedges forever on `relay_http_error`.
///
/// These tests pin the fix: the local cursor is scoped to the Core device that
/// minted it, a foreign or pre-migration (NULL) owner is treated as "no cursor",
/// and the very next sync recovers with `after: nil` — no re-join required,
/// because the Relay remembers each device's own server-side cursor.
final class RemoteCursorDeviceBindingTests: XCTestCase {
    private let workspace = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let coreDeviceA = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
    private let coreDeviceB = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!

    // MARK: - Ledger unit tests

    func testRelayCursorIsScopedToCoreDevice() async throws {
        let ledger = try makeLedger()
        try await ledger.recordSync(
            workspaceID: workspace,
            coreDeviceID: coreDeviceA,
            cursor: "cursor-a",
            errorCode: nil
        )

        // The device that stored it reads it back.
        let owned = try await ledger.relayCursor(workspaceID: workspace, coreDeviceID: coreDeviceA)
        XCTAssertEqual(owned, "cursor-a")

        // A different Core device (a re-joined Core) sees no cursor at all.
        let foreign = try await ledger.relayCursor(workspaceID: workspace, coreDeviceID: coreDeviceB)
        XCTAssertNil(foreign)
    }

    func testErrorPathPreservesCursorOwnershipWithoutRearmingTheWedge() async throws {
        let ledger = try makeLedger()
        try await ledger.recordSync(
            workspaceID: workspace,
            coreDeviceID: coreDeviceA,
            cursor: "cursor-a",
            errorCode: nil
        )
        // A failed sync by a *different* Core (cursor: nil, error set) must not
        // stamp its own device onto the carried-over cursor — that would make
        // `cursor-a` look like it belongs to device B and re-arm the 400 wedge.
        try await ledger.recordSync(
            workspaceID: workspace,
            coreDeviceID: coreDeviceB,
            cursor: nil,
            errorCode: "relay_http_error"
        )
        let ownerCursor = try await ledger.relayCursor(workspaceID: workspace, coreDeviceID: coreDeviceA)
        XCTAssertEqual(ownerCursor, "cursor-a", "The original owner still owns the carried-over cursor")
        let errorDeviceCursor = try await ledger.relayCursor(workspaceID: workspace, coreDeviceID: coreDeviceB)
        XCTAssertNil(errorDeviceCursor, "A device that only recorded an error never inherits the cursor")
    }

    func testPreMigrationNullDeviceRowInvalidatesCursor() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.sqlite3")

        // Reproduce a database written before `core_device_id` existed: the old
        // schema, with a cursor row and no ownership column.
        try writeLegacySyncState(at: url, cursor: "legacy-cursor")

        // Opening through the current ledger runs the additive migration
        // (ALTER TABLE ... ADD COLUMN core_device_id), leaving the legacy row's
        // ownership NULL.
        let ledger = try RemoteUsageLedger(url: url)

        // A NULL owner never matches any Core, so the stale cursor is dropped
        // and the next fetch will start from the Relay's server-side cursor.
        let legacyForA = try await ledger.relayCursor(workspaceID: workspace, coreDeviceID: coreDeviceA)
        XCTAssertNil(legacyForA)
        let legacyForB = try await ledger.relayCursor(workspaceID: workspace, coreDeviceID: coreDeviceB)
        XCTAssertNil(legacyForB)

        // The migration is non-destructive: a fresh recordSync re-establishes
        // ownership and the cursor becomes readable again.
        try await ledger.recordSync(
            workspaceID: workspace,
            coreDeviceID: coreDeviceA,
            cursor: "healed-cursor",
            errorCode: nil
        )
        let healed = try await ledger.relayCursor(workspaceID: workspace, coreDeviceID: coreDeviceA)
        XCTAssertEqual(healed, "healed-cursor")
    }

    // MARK: - Service-level: a foreign-device cursor does not wedge the stream

    @MainActor
    func testRefreshDiscardsForeignDeviceCursorAndDoesNotWedge() async throws {
        let config = try RemoteCoreConfig(
            workspaceID: workspace,
            coreDeviceID: coreDeviceB,
            relayURL: URL(string: "https://relay.example.invalid")!,
            coreEpoch: 1,
            ingestKeyID: "ingest-epoch-1",
            probeSigningPublicKeys: [:]
        )
        let identity = RemoteCoreIdentity(
            signingPrivateKey: P256.Signing.PrivateKey(),
            recipientPrivateKey: P256.KeyAgreement.PrivateKey()
        )
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = try RemoteUsageLedger(url: directory.appendingPathComponent("ledger.sqlite3"))

        // Seed a cursor left behind by the *revoked* Core (device A) before this
        // Mac re-joined as device B.
        try await ledger.recordSync(
            workspaceID: workspace,
            coreDeviceID: coreDeviceA,
            cursor: "stale-cursor",
            errorCode: nil
        )

        CursorBindingStubRelay.reset()
        defer { CursorBindingStubRelay.reset() }
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [CursorBindingStubRelay.self]
        let client = RemoteRelayClient(
            config: config,
            bearerToken: String(repeating: "t", count: 40),
            session: URLSession(configuration: sessionConfig)
        )
        let service = RemoteProbeService(
            config: config, identity: identity, client: client, ledger: ledger
        )
        await service.refresh()

        // The foreign cursor was dropped: the batch fetch went out with no
        // `after` param (had it replayed "stale-cursor", the stub answers 400),
        // so the stream did not wedge.
        XCTAssertNil(service.lastErrorCode)
        let afters = CursorBindingStubRelay.recordedAfters()
        XCTAssertEqual(afters.count, 1, "Exactly one batch page was requested")
        XCTAssertNil(afters.first!, "The batch fetch omitted the stale cursor")

        // The stale cursor stays invisible to the current Core on a re-read.
        let currentCursor = try await ledger.relayCursor(workspaceID: workspace, coreDeviceID: coreDeviceB)
        XCTAssertNil(currentCursor)
    }

    // MARK: - Fixtures

    private func makeLedger() throws -> RemoteUsageLedger {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try RemoteUsageLedger(url: directory.appendingPathComponent("ledger.sqlite3"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-cursor-binding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    /// Create the pre-migration `remote_sync_state` schema (no `core_device_id`
    /// column) with one cursor row, using raw SQLite so the ledger's own
    /// migration path is exercised on open. `cursor` is a test literal.
    private func writeLegacySyncState(at url: URL, cursor: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        ) == SQLITE_OK, let handle else {
            XCTFail("could not open legacy ledger")
            throw RemoteSyncError.invalidConfiguration
        }
        defer { sqlite3_close_v2(handle) }
        let create = """
            CREATE TABLE remote_sync_state (
                workspace_id TEXT PRIMARY KEY,
                relay_cursor TEXT,
                last_sync_at INTEGER,
                last_error_code TEXT
            );
            """
        guard sqlite3_exec(handle, create, nil, nil, nil) == SQLITE_OK else {
            XCTFail("could not create legacy schema")
            throw RemoteSyncError.invalidConfiguration
        }
        let insert = """
            INSERT INTO remote_sync_state(workspace_id, relay_cursor, last_sync_at, last_error_code)
            VALUES('\(workspace.uuidString.lowercased())', '\(cursor)', 1000, NULL);
            """
        guard sqlite3_exec(handle, insert, nil, nil, nil) == SQLITE_OK else {
            XCTFail("could not seed legacy row")
            throw RemoteSyncError.invalidConfiguration
        }
    }
}

/// Stubs the two Relay endpoints this scenario touches: the device roster
/// (empty — the config authorizes no probe) and the batch page. The batch page
/// answers 400 for any request that carries an `after` cursor — the Relay's
/// real response when a cursor is replayed against a device it was not bound to
/// — and 200 with an empty page when `after` is omitted. Each batch request's
/// `after` value is recorded so the test can assert the stale cursor was
/// dropped.
private final class CursorBindingStubRelay: URLProtocol {
    nonisolated(unsafe) private static var afters: [String?] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        afters = []
    }

    static func recordedAfters() -> [String?] {
        lock.lock(); defer { lock.unlock() }
        return afters
    }

    private static func recordAfter(_ value: String?) {
        lock.lock(); defer { lock.unlock() }
        afters.append(value)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/devices") {
            respond(status: 200, body: ["devices": []])
            return
        }
        if path.hasSuffix("/batches") {
            let after = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "after" })?.value
            Self.recordAfter(after)
            if after != nil {
                respond(status: 400, body: ["error": "cursor_principal_mismatch"])
            } else {
                respond(status: 200, body: ["batches": [], "next_cursor": ""])
            }
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
}
