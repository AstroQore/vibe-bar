import XCTest
import CryptoKit
@testable import VibeBarCore

/// Covers how a Core learns which probes it authorizes: parsing the Relay's
/// device roster, folding it into the installed configuration, and refusing to
/// churn the store when nothing moved. Synthetic UUIDs and keys only, and the
/// HTTP half runs against a stubbed URLProtocol.
final class RemoteDeviceRosterTests: XCTestCase {
    private let workspace = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let core = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let probeA = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let probeB = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let probeC = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!

    private final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> (HTTPURLResponse, Data?))?
        nonisolated(unsafe) static var lastRequestURL: URL?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            StubURLProtocol.lastRequestURL = request.url
            guard let responder = StubURLProtocol.responder else {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let (response, data) = responder(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    override func tearDown() {
        StubURLProtocol.responder = nil
        StubURLProtocol.lastRequestURL = nil
        super.tearDown()
    }

    private func signingKey(_ seed: UInt8) throws -> Data {
        try P256.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 0, count: 31) + Data([seed])
        ).publicKey.x963Representation
    }

    private func config(_ keys: [UUID: Data]) throws -> RemoteCoreConfig {
        try RemoteCoreConfig(
            workspaceID: workspace,
            coreDeviceID: core,
            relayURL: URL(string: "https://relay.example.invalid")!,
            coreEpoch: 1,
            ingestKeyID: "ingest-epoch-1",
            probeSigningPublicKeys: keys
        )
    }

    private func makeClient(_ config: RemoteCoreConfig) -> RemoteRelayClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return RemoteRelayClient(
            config: config,
            bearerToken: String(repeating: "t", count: 40),
            session: URLSession(configuration: configuration)
        )
    }

    private func respond(_ body: Any?, status: Int = 200, noStore: Bool = true) {
        StubURLProtocol.responder = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: noStore ? ["Cache-Control": "no-store"] : [:]
            )!
            guard let body else { return (response, nil) }
            return (response, try? JSONSerialization.data(withJSONObject: body))
        }
    }

    // MARK: - Roster policy

    func testOnlyActiveProbesBecomeAuthorizedProducers() throws {
        let devices = [
            RemoteRelayDevice(deviceID: probeA, role: "probe", status: "active",
                              signingPublicKey: try signingKey(3)),
            // Revoked probes lose their authorization.
            RemoteRelayDevice(deviceID: probeB, role: "probe", status: "revoked",
                              signingPublicKey: try signingKey(4)),
            // The Core itself never publishes to its own ingest stream.
            RemoteRelayDevice(deviceID: core, role: "core", status: "active",
                              signingPublicKey: try signingKey(5)),
            RemoteRelayDevice(deviceID: probeC, role: "view", status: "active",
                              signingPublicKey: try signingKey(6))
        ]
        let resolution = RemoteProbeRoster.resolve(from: devices)
        XCTAssertEqual(Set(resolution.keys.keys), [probeA])
        XCTAssertEqual(resolution.keys[probeA], try signingKey(3))
        XCTAssertEqual(resolution.skipped, 0)
    }

    func testUnusableProbeKeysAreSkippedAndCounted() throws {
        let devices = [
            RemoteRelayDevice(deviceID: probeA, role: "probe", status: "active",
                              signingPublicKey: try signingKey(3)),
            RemoteRelayDevice(deviceID: probeB, role: "probe", status: "active",
                              signingPublicKey: nil),
            RemoteRelayDevice(deviceID: probeC, role: "probe", status: "active",
                              signingPublicKey: nil)
        ]
        let resolution = RemoteProbeRoster.resolve(from: devices)
        XCTAssertEqual(Set(resolution.keys.keys), [probeA])
        XCTAssertEqual(resolution.skipped, 2)
    }

    func testNewProbeIsAddedAndRevokedProbeIsDropped() throws {
        // Installed: A only — the state a file-provisioned Core is stuck in
        // after its workspace enrolled B and revoked A.
        let installed = try config([probeA: try signingKey(3)])
        let resolution = RemoteProbeRoster.resolve(from: [
            RemoteRelayDevice(deviceID: probeA, role: "probe", status: "revoked",
                              signingPublicKey: try signingKey(3)),
            RemoteRelayDevice(deviceID: probeB, role: "probe", status: "active",
                              signingPublicKey: try signingKey(4))
        ])
        let updated = try XCTUnwrap(
            RemoteProbeRoster.updatedConfiguration(for: installed, resolution: resolution)
        )
        XCTAssertEqual(Set(updated.probeSigningPublicKeys.keys), [probeB])
        XCTAssertEqual(updated.probeSigningPublicKeys[probeB], try signingKey(4))
        // Everything else about the binding is preserved verbatim.
        XCTAssertEqual(updated.workspaceID, installed.workspaceID)
        XCTAssertEqual(updated.coreDeviceID, installed.coreDeviceID)
        XCTAssertEqual(updated.relayURL, installed.relayURL)
        XCTAssertEqual(updated.coreEpoch, installed.coreEpoch)
        XCTAssertEqual(updated.ingestKeyID, installed.ingestKeyID)
    }

    func testCodeJoinedCoreLearnsItsFirstProbe() throws {
        // The empty map a code-based enrollment installs.
        let installed = try config([:])
        let resolution = RemoteProbeRoster.resolve(from: [
            RemoteRelayDevice(deviceID: probeA, role: "probe", status: "active",
                              signingPublicKey: try signingKey(3))
        ])
        let updated = try XCTUnwrap(
            RemoteProbeRoster.updatedConfiguration(for: installed, resolution: resolution)
        )
        XCTAssertEqual(updated.probeSigningPublicKeys[probeA], try signingKey(3))
    }

    func testUnchangedRosterDoesNotRewriteTheConfiguration() throws {
        let installed = try config([probeA: try signingKey(3)])
        let resolution = RemoteProbeRoster.resolve(from: [
            RemoteRelayDevice(deviceID: probeA, role: "probe", status: "active",
                              signingPublicKey: try signingKey(3)),
            // Ordering and irrelevant roles must not look like a change.
            RemoteRelayDevice(deviceID: core, role: "core", status: "active",
                              signingPublicKey: try signingKey(5))
        ])
        XCTAssertNil(
            try RemoteProbeRoster.updatedConfiguration(for: installed, resolution: resolution),
            "An unchanged roster must not touch the store"
        )
    }

    // MARK: - Relay client

    func testFetchDevicesParsesTheRelayRoster() async throws {
        let installed = try config([:])
        respond([
            "devices": [
                [
                    "device_id": probeA.uuidString.lowercased(),
                    "role": "probe",
                    "status": "active",
                    "signing_public_key": try signingKey(3).base64EncodedString(),
                    "created_at": 1_700_000_000
                ],
                [
                    "device_id": probeB.uuidString.lowercased(),
                    "role": "probe",
                    "status": "active",
                    // Not a P-256 x963 point: kept as a row, key dropped.
                    "signing_public_key": Data(repeating: 0x01, count: 12).base64EncodedString(),
                    "created_at": 1_700_000_100
                ],
                [
                    "device_id": core.uuidString.lowercased(),
                    "role": "core",
                    "status": "active",
                    "created_at": 1_700_000_200
                ]
            ]
        ])
        let devices = try await makeClient(installed).fetchDevices()
        XCTAssertEqual(devices.count, 3)
        XCTAssertEqual(devices[0].signingPublicKey, try signingKey(3))
        XCTAssertNil(devices[1].signingPublicKey)
        XCTAssertNil(devices[2].signingPublicKey)
        XCTAssertEqual(devices[2].role, "core")

        let url = try XCTUnwrap(StubURLProtocol.lastRequestURL)
        XCTAssertEqual(
            url.path,
            "/v1/workspaces/\(workspace.uuidString.lowercased())/devices"
        )
        // Malformed keys never silently authorize anyone.
        XCTAssertEqual(RemoteProbeRoster.resolve(from: devices).skipped, 1)
    }

    func testFetchDevicesRejectsUnusableResponses() async throws {
        let installed = try config([:])
        let client = makeClient(installed)

        respond(["not_devices": []])
        await assertRelayFailure { _ = try await client.fetchDevices() }

        respond(["devices": [["device_id": "not-a-uuid", "role": "probe", "status": "active"]]])
        await assertRelayFailure { _ = try await client.fetchDevices() }

        // A cacheable roster response is refused like every other Relay read.
        respond(["devices": []], noStore: false)
        await assertRelayFailure { _ = try await client.fetchDevices() }

        respond(nil, status: 403)
        await assertRelayFailure { _ = try await client.fetchDevices() }
    }

    private func assertRelayFailure(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected the roster fetch to fail", file: file, line: line)
        } catch is RemoteSyncError {
            // Expected: the service keeps its installed map on any of these.
        } catch {
            XCTFail("Expected RemoteSyncError, got \(error)", file: file, line: line)
        }
    }
}
