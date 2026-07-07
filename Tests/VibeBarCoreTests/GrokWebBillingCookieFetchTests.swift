import XCTest
@testable import VibeBarCore

/// Covers the cookie-authenticated overload of
/// `GrokWebBillingFetcher.fetch(cookieHeader:)`. The bearer-based
/// overload's framing/protobuf tests live in
/// `GrokWebBillingFetcherTests`; this file focuses on the request
/// shape and on the cookie-jar isolation that lets a cookie-only
/// session reach grok.com cleanly.
final class GrokWebBillingCookieFetchTests: XCTestCase {
    func testCookieOverloadSendsCookieHeaderAndNoBearer() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GrokCookieStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let endpoint = URL(string: "https://grok.test/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")!

        GrokCookieStubURLProtocol.reset()
        GrokCookieStubURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "sso=session; cf_clearance=cf789")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/grpc-web+proto")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-grpc-web"), "1")
            XCTAssertEqual(request.httpShouldHandleCookies, false)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/grpc-web+proto"]
            )!
            let payload = Self.protobufPayload(usedPercent: 67.5, resetEpoch: 1_800_000_000)
            return (response, Self.grpcFrame(payload))
        }

        let snapshot = try await GrokWebBillingFetcher.fetch(
            cookieHeader: "sso=session; cf_clearance=cf789",
            session: session,
            endpoint: endpoint
        )
        XCTAssertEqual(snapshot.usedPercent, 67.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.resetsAt, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testCookieOverloadRejectsStaleCookiesAsNeedsLogin() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GrokCookieStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let endpoint = URL(string: "https://grok.test/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")!

        GrokCookieStubURLProtocol.reset()
        GrokCookieStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/plain"]
            )!
            return (response, Data("unauthorized".utf8))
        }

        do {
            _ = try await GrokWebBillingFetcher.fetch(
                cookieHeader: "sso=stale",
                session: session,
                endpoint: endpoint
            )
            XCTFail("Expected needsLogin")
        } catch let error as QuotaError {
            guard case .needsLogin = error else {
                return XCTFail("Expected .needsLogin, got \(error)")
            }
        } catch {
            XCTFail("Expected QuotaError, got \(error)")
        }
    }

    func testQuotaAdapterSurfacesMonthlyBucketAsTopLevel() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GrokCookieStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebar-grok-adapter-\(UUID().uuidString)", isDirectory: true)
        let grokDir = home.appendingPathComponent(".grok", isDirectory: true)
        try FileManager.default.createDirectory(at: grokDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let auth = """
        {
          "https://auth.x.ai::client": {
            "key": "xai-fake-token",
            "auth_mode": "oidc",
            "email": "user@example.com",
            "expires_at": "2099-01-01T00:00:00Z"
          }
        }
        """
        try Data(auth.utf8).write(to: grokDir.appendingPathComponent("auth.json"))

        GrokCookieStubURLProtocol.reset()
        GrokCookieStubURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer xai-fake-token")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/grpc-web+proto"]
            )!
            let payload = Self.protobufPayload(usedPercent: 72, resetEpoch: 1_800_000_000)
            return (response, Self.grpcFrame(payload))
        }

        let adapter = GrokQuotaAdapter(
            session: session,
            homeDirectory: home.path,
            now: { Date(timeIntervalSince1970: 1_799_000_000) }
        )
        let account = AccountIdentity(
            id: "grok",
            tool: .grok,
            alias: "Grok",
            source: .oauthCLI,
            createdAt: Date(),
            updatedAt: Date()
        )

        let quota = try await adapter.fetch(for: account)

        XCTAssertEqual(quota.buckets.count, 1)
        XCTAssertEqual(quota.buckets[0].id, "weekly")
        XCTAssertNil(quota.buckets[0].groupTitle)
    }

    // MARK: - Helpers

    private static func protobufPayload(usedPercent: Float, resetEpoch: UInt64) -> Data {
        var data = Data()
        data.append(0x0D)
        var percentBits = usedPercent.bitPattern.littleEndian
        withUnsafeBytes(of: &percentBits) { data.append(contentsOf: $0) }
        data.append(0x10)
        data.append(contentsOf: varint(resetEpoch))
        return data
    }

    private static func grpcFrame(_ payload: Data, flags: UInt8 = 0x00) -> Data {
        var data = Data([flags])
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    private static func varint(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while remaining != 0
        return bytes
    }
}

private final class GrokCookieStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    static func reset() {
        handler = nil
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
