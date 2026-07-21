import XCTest
@testable import VibeBarCore

final class GrokAccountSettingsFetcherTests: XCTestCase {
    func testFetchReadsHeavyTierFromOfficialSettingsPayload() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GrokSettingsStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let endpoint = URL(string: "https://grok-settings.test/v1/settings")!
        let credentials = Self.credentials()

        GrokSettingsStubURLProtocol.reset()
        GrokSettingsStubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer xai-test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.httpShouldHandleCookies, false)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                Data(#"{"subscription_tier_display":"SuperGrok Heavy"}"#.utf8)
            )
        }

        let snapshot = try await GrokAccountSettingsFetcher.fetch(
            credentials: credentials,
            session: session,
            endpoint: endpoint
        )

        XCTAssertEqual(snapshot.subscriptionTierDisplay, "SuperGrok Heavy")
    }

    func testFetchMapsUnauthorizedResponseToNeedsLogin() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GrokSettingsStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let endpoint = URL(string: "https://grok-settings.test/v1/settings")!

        GrokSettingsStubURLProtocol.reset()
        GrokSettingsStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        do {
            _ = try await GrokAccountSettingsFetcher.fetch(
                credentials: Self.credentials(),
                session: session,
                endpoint: endpoint
            )
            XCTFail("Expected needsLogin")
        } catch let error as QuotaError {
            guard case .needsLogin = error else {
                return XCTFail("Expected .needsLogin, got \(error)")
            }
        }
    }

    private static func credentials() -> GrokCredentials {
        GrokCredentials(
            accessToken: "xai-test-token",
            scope: "https://auth.x.ai::test-client",
            authMode: "oidc",
            email: "user@example.com",
            firstName: nil,
            lastName: nil,
            teamId: nil,
            subscriptionTier: nil,
            expiresAt: nil
        )
    }
}

private final class GrokSettingsStubURLProtocol: URLProtocol {
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
