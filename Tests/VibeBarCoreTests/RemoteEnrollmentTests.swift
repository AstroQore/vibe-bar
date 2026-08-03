import XCTest
import CryptoKit
@testable import VibeBarCore

/// Exercises the join-with-code enrollment client against a stubbed
/// URLProtocol: no network, no Keychain, and only synthetic identifiers.
/// The stub echoes the encryption public key straight out of the request, so
/// the happy path also asserts the request encoding the control center's
/// `POST /api/v1/enroll/consume` contract expects.
final class RemoteEnrollmentTests: XCTestCase {
    private let workspace = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let device = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let bearer = "vbr1." + String(repeating: "a", count: 40)
    private let controlURL = URL(string: "https://control.example.invalid")!

    private final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var responder: (@Sendable (URLRequest, Data) -> (HTTPURLResponse, Data?))?
        nonisolated(unsafe) static var lastRequestBody: Data?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let body = StubURLProtocol.body(of: request)
            StubURLProtocol.lastRequestBody = body
            guard let responder = StubURLProtocol.responder else {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let (response, data) = responder(request, body)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        /// URLSession replaces `httpBody` with a stream by the time a
        /// URLProtocol sees the request, so read whichever one is populated.
        private static func body(of request: URLRequest) -> Data {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(contentsOf: buffer[0..<read])
            }
            return data
        }
    }

    private func makeStubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeClient() throws -> RemoteEnrollmentClient {
        try RemoteEnrollmentClient(controlURL: controlURL, session: makeStubbedSession())
    }

    override func tearDown() {
        StubURLProtocol.responder = nil
        StubURLProtocol.lastRequestBody = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func respond(
        status: Int,
        json: @escaping @Sendable ([String: Any]) -> [String: Any]?
    ) {
        StubURLProtocol.responder = { request, body in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let sent = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            guard let object = json(sent) else { return (response, nil) }
            return (response, try? JSONSerialization.data(withJSONObject: object))
        }
    }

    private func successBody(
        role: String = "core",
        overridingCoreKey: String? = nil
    ) -> @Sendable ([String: Any]) -> [String: Any]? {
        let workspace = workspace
        let device = device
        let bearer = bearer
        return { sent in
            let echoed = overridingCoreKey ?? (sent["encryption_public_key"] as? String ?? "")
            return [
                "workspace_id": workspace.uuidString.lowercased(),
                "device_id": device.uuidString.lowercased(),
                "role": role,
                "relay_url": "https://relay.example.invalid",
                "bearer_token": bearer,
                "core": [
                    "public_key": echoed,
                    "epoch": 1,
                    "key_id": "ingest-epoch-1"
                ]
            ]
        }
    }

    private func assertEnrollmentError(
        _ expected: RemoteEnrollmentError,
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected.code)", file: file, line: line)
        } catch let error as RemoteEnrollmentError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected \(expected.code), got \(error)", file: file, line: line)
        }
    }

    // MARK: - Happy path

    func testSuccessfulEnrollmentAssemblesLoadableConfiguration() async throws {
        respond(status: 201, json: successBody())
        let enrollment = try await makeClient().enrollCore(
            code: " vb-abcde-23456 ",
            deviceName: "Example Mac"
        )

        // The request matched the contract…
        let sent = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: XCTUnwrap(StubURLProtocol.lastRequestBody)))
                as? [String: Any]
        )
        XCTAssertEqual(sent["code"] as? String, "VB-ABCDE-23456")
        XCTAssertEqual(sent["name"] as? String, "Example Mac")
        XCTAssertEqual(sent["platform"] as? String, "macos")
        for key in ["signing_public_key", "encryption_public_key"] {
            let raw = try XCTUnwrap(sent[key] as? String)
            let decoded = try XCTUnwrap(Data(base64Encoded: raw))
            XCTAssertEqual(decoded.count, 65, "\(key) must be uncompressed x963")
            XCTAssertEqual(decoded.first, 0x04, "\(key) must carry the x963 prefix")
        }
        XCTAssertEqual(
            Data(base64Encoded: sent["signing_public_key"] as? String ?? ""),
            enrollment.identity.signingPrivateKey.publicKey.x963Representation
        )

        // …and the response became exactly what a provisioning file installs.
        let provisioning = enrollment.provisioning
        XCTAssertEqual(provisioning.schema, 1)
        XCTAssertEqual(provisioning.workspaceID, workspace)
        XCTAssertEqual(provisioning.coreDeviceID, device)
        XCTAssertEqual(provisioning.relayURL.absoluteString, "https://relay.example.invalid")
        XCTAssertEqual(provisioning.relayBearerToken, bearer)
        XCTAssertEqual(provisioning.coreEpoch, 1)
        XCTAssertEqual(provisioning.ingestKeyID, "ingest-epoch-1")
        XCTAssertTrue(provisioning.probeSigningPublicKeys.isEmpty)
        XCTAssertEqual(enrollment.deviceName, "Example Mac")

        // The non-secret half round-trips through the on-disk config format.
        let config = try RemoteCoreConfig(
            workspaceID: provisioning.workspaceID,
            coreDeviceID: provisioning.coreDeviceID,
            relayURL: provisioning.relayURL,
            coreEpoch: provisioning.coreEpoch,
            ingestKeyID: provisioning.ingestKeyID,
            probeSigningPublicKeys: provisioning.probeSigningPublicKeys
        )
        let encoded = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(RemoteCoreConfig.self, from: encoded), config)
    }

    // MARK: - Error taxonomy

    func testInvalidCodeYieldsTypedError() async throws {
        respond(status: 404) { _ in ["error": "invalid_code"] }
        let client = try makeClient()
        await assertEnrollmentError(.codeRejected) {
            _ = try await client.enrollCore(code: "VB-ABCDE-23456", deviceName: "Example Mac")
        }
    }

    func testCoreExistsYieldsTypedError() async throws {
        respond(status: 409) { _ in ["error": "core_exists"] }
        let client = try makeClient()
        await assertEnrollmentError(.coreExists) {
            _ = try await client.enrollCore(code: "VB-ABCDE-23456", deviceName: "Example Mac")
        }
    }

    func testRateLimitAndServerErrorsAreDistinct() async throws {
        respond(status: 429) { _ in nil }
        let client = try makeClient()
        await assertEnrollmentError(.rateLimited) {
            _ = try await client.enrollCore(code: "VB-ABCDE-23456", deviceName: "Example Mac")
        }
        respond(status: 503) { _ in nil }
        await assertEnrollmentError(.server(503)) {
            _ = try await client.enrollCore(code: "VB-ABCDE-23456", deviceName: "Example Mac")
        }
    }

    func testTransportFailureYieldsNetworkError() async throws {
        StubURLProtocol.responder = nil
        let client = try makeClient()
        await assertEnrollmentError(.network) {
            _ = try await client.enrollCore(code: "VB-ABCDE-23456", deviceName: "Example Mac")
        }
    }

    func testProbeGrantIsRefusedByTheCore() async throws {
        respond(status: 201, json: successBody(role: "probe"))
        let client = try makeClient()
        await assertEnrollmentError(.wrongRole("probe")) {
            _ = try await client.enrollCore(code: "VB-ABCDE-23456", deviceName: "Example Mac")
        }
    }

    func testEchoedCoreKeyMustMatchTheGeneratedKey() async throws {
        let other = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        respond(
            status: 201,
            json: successBody(overridingCoreKey: other.base64EncodedString())
        )
        let client = try makeClient()
        await assertEnrollmentError(.coreKeyMismatch) {
            _ = try await client.enrollCore(code: "VB-ABCDE-23456", deviceName: "Example Mac")
        }
    }

    func testMalformedSuccessBodiesAreRejected() async throws {
        let client = try makeClient()

        // Missing relay_url entirely.
        respond(status: 201) { sent in
            [
                "workspace_id": "11111111-1111-4111-8111-111111111111",
                "device_id": "22222222-2222-4222-8222-222222222222",
                "role": "core",
                "bearer_token": String(repeating: "b", count: 44),
                "core": [
                    "public_key": sent["encryption_public_key"] as? String ?? "",
                    "epoch": 1,
                    "key_id": "ingest-epoch-1"
                ]
            ]
        }
        await assertEnrollmentError(.malformedResponse) {
            _ = try await client.enrollCore(code: "VB-ABCDE-23456", deviceName: "Example Mac")
        }

        // A plaintext relay origin can never carry this protocol.
        respond(status: 201) { sent in
            [
                "workspace_id": "11111111-1111-4111-8111-111111111111",
                "device_id": "22222222-2222-4222-8222-222222222222",
                "role": "core",
                "relay_url": "http://relay.example.invalid",
                "bearer_token": String(repeating: "b", count: 44),
                "core": [
                    "public_key": sent["encryption_public_key"] as? String ?? "",
                    "epoch": 1,
                    "key_id": "ingest-epoch-1"
                ]
            ]
        }
        await assertEnrollmentError(.malformedResponse) {
            _ = try await client.enrollCore(code: "VB-ABCDE-23456", deviceName: "Example Mac")
        }

        // A too-short bearer token is rejected before it reaches the Vault.
        respond(status: 201) { sent in
            [
                "workspace_id": "11111111-1111-4111-8111-111111111111",
                "device_id": "22222222-2222-4222-8222-222222222222",
                "role": "core",
                "relay_url": "https://relay.example.invalid",
                "bearer_token": "short",
                "core": [
                    "public_key": sent["encryption_public_key"] as? String ?? "",
                    "epoch": 1,
                    "key_id": "ingest-epoch-1"
                ]
            ]
        }
        await assertEnrollmentError(.malformedResponse) {
            _ = try await client.enrollCore(code: "VB-ABCDE-23456", deviceName: "Example Mac")
        }
    }

    // MARK: - Input validation

    func testPlaintextControlURLIsRejected() {
        for raw in [
            "http://vibebar.example.invalid",
            "https://vibebar.example.invalid/api",
            "https://user:secret@vibebar.example.invalid",
            "https://vibebar.example.invalid?token=x"
        ] {
            let url = URL(string: raw)!
            XCTAssertThrowsError(try RemoteEnrollmentClient(controlURL: url)) { error in
                XCTAssertEqual(error as? RemoteEnrollmentError, .invalidControlURL)
            }
        }
        XCTAssertNoThrow(
            try RemoteEnrollmentClient(controlURL: URL(string: "https://vibebar.example.invalid")!)
        )
    }

    func testControlURLTextFallsBackToTheHostedDefault() throws {
        XCTAssertEqual(
            try RemoteEnrollmentClient.controlURL(from: "   "),
            RemoteEnrollmentClient.defaultControlURL
        )
        XCTAssertEqual(
            try RemoteEnrollmentClient.controlURL(from: " https://vibebar.example.invalid "),
            URL(string: "https://vibebar.example.invalid")
        )
    }

    func testPairingCodeNormalization() throws {
        XCTAssertEqual(
            try RemoteEnrollmentClient.normalizedCode("  vb-abcde-23456\n"),
            "VB-ABCDE-23456"
        )
        for raw in ["", "   ", "VB ABCDE 23456", "VB-ABCDE-23456!", String(repeating: "A", count: 65)] {
            XCTAssertThrowsError(try RemoteEnrollmentClient.normalizedCode(raw)) { error in
                XCTAssertEqual(error as? RemoteEnrollmentError, .invalidCode)
            }
        }
    }

    func testFreshlyJoinedWorkspaceHasNoRegisteredProbes() throws {
        // A Core that just joined authorizes no producer yet; the config must
        // still be representable, because probes enroll afterwards.
        let config = try RemoteCoreConfig(
            workspaceID: workspace,
            coreDeviceID: device,
            relayURL: URL(string: "https://relay.example.invalid")!,
            coreEpoch: 1,
            ingestKeyID: "ingest-epoch-1",
            probeSigningPublicKeys: [:]
        )
        XCTAssertTrue(config.probeSigningPublicKeys.isEmpty)
    }
}
