import XCTest
import CryptoKit
@testable import VibeBarCore

/// A background Relay pass and a manual refresh can overlap. The second
/// caller must join the pass already in flight; queueing another pass used to
/// leave a MainActor waiter spinning on an already-completed Task and freeze
/// the whole app at 100% CPU.
final class RemoteRefreshCoalescingTests: XCTestCase {
    override func tearDown() {
        RefreshCoalescingStubRelay.reset(blockDeviceResponse: false)
        super.tearDown()
    }

    @MainActor
    func testManualRefreshJoinsTheActiveLoopPass() async throws {
        RefreshCoalescingStubRelay.reset(blockDeviceResponse: true)
        let service = try makeService()

        // `start()` immediately begins the same pass the production 60-second
        // loop runs. Hold its roster response so a manual caller definitely
        // reaches refresh() while that pass is active.
        service.start()
        let requestStarted = await Task.detached {
            RefreshCoalescingStubRelay.waitForDeviceRequest(timeout: 2)
        }.value
        guard requestStarted else {
            service.stop()
            XCTFail("The loop refresh never reached the Relay stub")
            return
        }

        let manualRefresh = Task { @MainActor in
            await service.refresh()
        }
        // Give the manual task one MainActor turn to join the blocked pass.
        await Task.yield()
        RefreshCoalescingStubRelay.resumeDeviceResponse()

        await manualRefresh.value
        service.stop()

        XCTAssertEqual(
            RefreshCoalescingStubRelay.deviceRequestCount(),
            1,
            "Overlapping callers must share one roster request"
        )
        XCTAssertEqual(
            RefreshCoalescingStubRelay.batchRequestCount(),
            1,
            "Overlapping callers must share one batch request"
        )
    }

    @MainActor
    private func makeService() throws -> RemoteProbeService {
        let workspaceID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let config = try RemoteCoreConfig(
            workspaceID: workspaceID,
            coreDeviceID: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
            relayURL: URL(string: "https://relay.example.invalid")!,
            coreEpoch: 1,
            ingestKeyID: "ingest-epoch-1",
            probeSigningPublicKeys: [:]
        )
        let identity = RemoteCoreIdentity(
            signingPrivateKey: P256.Signing.PrivateKey(),
            recipientPrivateKey: P256.KeyAgreement.PrivateKey()
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-refresh-coalescing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let ledger = try RemoteUsageLedger(url: directory.appendingPathComponent("ledger.sqlite3"))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RefreshCoalescingStubRelay.self]
        let client = RemoteRelayClient(
            config: config,
            bearerToken: String(repeating: "t", count: 40),
            session: URLSession(configuration: sessionConfiguration)
        )
        return RemoteProbeService(
            config: config,
            identity: identity,
            client: client,
            ledger: ledger
        )
    }
}

/// The `/devices` response is held behind a condition so the test can start a
/// second MainActor caller while the loop's first pass is definitely in
/// flight. Only synthetic public material is returned.
private final class RefreshCoalescingStubRelay: URLProtocol {
    private static let condition = NSCondition()
    nonisolated(unsafe) private static var blockDeviceResponse = false
    nonisolated(unsafe) private static var deviceRequests = 0
    nonisolated(unsafe) private static var batchRequests = 0

    static func reset(blockDeviceResponse: Bool) {
        condition.lock()
        self.blockDeviceResponse = blockDeviceResponse
        deviceRequests = 0
        batchRequests = 0
        condition.broadcast()
        condition.unlock()
    }

    static func waitForDeviceRequest(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while deviceRequests == 0 {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    static func resumeDeviceResponse() {
        condition.lock()
        blockDeviceResponse = false
        condition.broadcast()
        condition.unlock()
    }

    static func deviceRequestCount() -> Int {
        condition.lock()
        defer { condition.unlock() }
        return deviceRequests
    }

    static func batchRequestCount() -> Int {
        condition.lock()
        defer { condition.unlock() }
        return batchRequests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/devices") {
            Self.waitBeforeDeviceResponse()
            respond(body: ["devices": []])
            return
        }
        if path.hasSuffix("/batches") {
            Self.recordBatchRequest()
            respond(body: ["batches": [], "next_cursor": ""])
            return
        }
        respond(body: [:])
    }

    private static func waitBeforeDeviceResponse() {
        condition.lock()
        deviceRequests += 1
        condition.broadcast()
        while blockDeviceResponse {
            condition.wait()
        }
        condition.unlock()
    }

    private static func recordBatchRequest() {
        condition.lock()
        batchRequests += 1
        condition.unlock()
    }

    private func respond(body: [String: Any]) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
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
