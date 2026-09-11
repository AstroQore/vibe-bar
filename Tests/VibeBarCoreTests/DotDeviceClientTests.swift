import XCTest
@testable import VibeBarCore

final class DotStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    static func reset() {
        handler = nil
        lastRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class DotDeviceClientTests: XCTestCase {
    private func client() -> DotDeviceClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DotStubURLProtocol.self]
        return DotDeviceClient(
            baseURL: URL(string: "https://dot.example.test")!,
            session: URLSession(configuration: configuration)
        )
    }

    private func respond(_ status: Int, _ body: String) {
        DotStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
    }

    override func setUp() {
        super.setUp()
        DotStubURLProtocol.reset()
    }

    func testBaseURLAndDefaults() {
        XCTAssertEqual(DotDeviceClient.defaultBaseURL.absoluteString, "https://dot.mindreset.tech")
        XCTAssertEqual(DotDeviceClient.timeout, 30)
        XCTAssertEqual(DotDeviceClient.minimumRequestInterval, 0.15)
    }

    func testListDevicesSendsTheBearerTokenAndParsesTheRoster() async throws {
        respond(200, #"[{"id":"0000AAAA0000","edition":2,"model":"quote_0","series":"quote","alias":"Desk"}]"#)
        let devices = try await client().listDevices(apiKey: "dot_app_synthetic_key")
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].id, "0000AAAA0000")
        XCTAssertEqual(devices[0].profile?.width, 296)
        let request = try XCTUnwrap(DotStubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/authV2/open/devices")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer dot_app_synthetic_key")
    }

    func testStatusPathAndParse() async throws {
        respond(200, #"{"deviceId":"0000AAAA0000","status":{"battery":"On power"},"renderInfo":{"current":{"image":["https://cdn.example.test/a.png"]}}}"#)
        let status = try await client().status(deviceID: "0000AAAA0000", apiKey: "k")
        XCTAssertEqual(status.battery, "On power")
        XCTAssertEqual(status.currentImageURL?.absoluteString, "https://cdn.example.test/a.png")
        XCTAssertEqual(DotStubURLProtocol.lastRequest?.url?.path, "/api/authV2/open/device/0000AAAA0000/status")
    }

    func testListTasksUsesTheTaskTypeSegment() async throws {
        respond(200, #"[{"key":"S0000AAAA0000","type":"CANVAS_API"}]"#)
        _ = try await client().listTasks(deviceID: "0000AAAA0000", type: .loop, apiKey: "k")
        XCTAssertEqual(DotStubURLProtocol.lastRequest?.url?.path, "/api/authV2/open/device/0000AAAA0000/loop/list")
        _ = try await client().listTasks(deviceID: "0000AAAA0000", type: .fixed, apiKey: "k")
        XCTAssertEqual(DotStubURLProtocol.lastRequest?.url?.path, "/api/authV2/open/device/0000AAAA0000/fixed/list")
    }

    func testSendCanvasPostsTheEncodedPayload() async throws {
        respond(200, #"{"message":"ok"}"#)
        let payload = try EInkRenderer.render(
            slide: EInkFixtures.slide(preset: .usageTiles),
            device: EInkFixtures.device(orientation: .degrees0),
            snapshot: EInkFixtures.snapshot()
        )
        let message = try await client().sendCanvas(deviceID: "0000AAAA0000", payload: payload, apiKey: "k")
        XCTAssertEqual(message, "ok")
        let request = try XCTUnwrap(DotStubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/authV2/open/device/0000AAAA0000/canvas")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testUpdateIntervalRoundsToWholeMinutes() async throws {
        respond(200, #"{"message":"updated"}"#)
        _ = try await client().updateInterval(deviceID: "0000AAAA0000", powerMs: 305_000, batteryMs: 1_000, apiKey: "k")
        let request = try XCTUnwrap(DotStubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/api/authV2/open/device/0000AAAA0000/settings")
        XCTAssertEqual(DotDeviceClient.roundedInterval(305_000), 300_000)
        XCTAssertEqual(DotDeviceClient.roundedInterval(1_000), 60_000)
        XCTAssertEqual(DotDeviceClient.roundedInterval(99_999_999), 43_200_000)
    }

    func testStatusCodesMapToTypedErrors() async {
        let cases: [(Int, DotDeviceError)] = [
            (401, .unauthorized),
            (403, .unauthorized),
            (404, .taskNotInLoop),
            (429, .rateLimited),
            (503, .http(code: 503))
        ]
        for (status, expected) in cases {
            respond(status, "{}")
            do {
                _ = try await client().listDevices(apiKey: "k")
                XCTFail("expected \(expected) for HTTP \(status)")
            } catch {
                XCTAssertEqual(error as? DotDeviceError, expected)
            }
        }
        XCTAssertTrue(DotDeviceError.unauthorized.invalidatesCredential)
        XCTAssertFalse(DotDeviceError.rateLimited.invalidatesCredential)
    }

    func testUnparseableBodyBecomesADecodingError() async {
        respond(200, "not json at all")
        do {
            _ = try await client().listDevices(apiKey: "k")
            XCTFail("expected a decoding error")
        } catch {
            guard case .decoding = error as? DotDeviceError else {
                return XCTFail("expected .decoding, got \(error)")
            }
        }
    }
}
