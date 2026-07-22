import XCTest
@testable import VibeBarCore

/// Smoke tests for `GeminiQuotaAdapter`'s account-source boundary.
/// Gemini live quota is Web-only; CLI telemetry remains a cost-history
/// input, not a quota account.
final class GeminiDualFetchTests: XCTestCase {
    override func tearDown() {
        GeminiAdapterStubURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeEmptyHomeAdapter() throws -> (GeminiQuotaAdapter, URL) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebar-gemini-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let adapter = GeminiQuotaAdapter(
            session: .shared,
            homeDirectory: temp.path,
            now: { Date() },
            cookieHeader: { throw QuotaError.noCredential }
        )
        return (adapter, temp)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func account(source: CredentialSource) -> AccountIdentity {
        AccountIdentity(
            id: source == .oauthCLI ? "stale-oauth-gemini" : "web-gemini",
            tool: .gemini,
            alias: source == .oauthCLI ? "Stale Gemini CLI" : "Gemini Web",
            source: source,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    func testOAuthAccountThrowsUnknownBecauseCLIQuotaIsRemoved() async throws {
        let (adapter, temp) = try makeEmptyHomeAdapter()
        defer { cleanup(temp) }

        do {
            _ = try await adapter.fetch(for: account(source: .oauthCLI))
            XCTFail("Expected throw for CLI quota source")
        } catch QuotaError.unknown {
            // Pass
        } catch {
            XCTFail("Expected .unknown, got \(error)")
        }
    }

    func testWebAccountWithoutCookiesSurfacesNoCredential() async throws {
        // With no cookies imported, the adapter should surface a
        // QuotaError without crashing. The injected loader keeps this
        // test isolated from the developer's real Gemini Keychain item.
        let (adapter, temp) = try makeEmptyHomeAdapter()
        defer { cleanup(temp) }

        do {
            _ = try await adapter.fetch(for: account(source: .webCookie))
            XCTFail("Expected noCredential without an injected cookie")
        } catch is QuotaError {
            // Pass — any QuotaError variant is acceptable here.
        } catch {
            XCTFail("Expected a QuotaError, got \(error)")
        }
    }

    func testUnsupportedSourceThrowsUnknown() async throws {
        let (adapter, temp) = try makeEmptyHomeAdapter()
        defer { cleanup(temp) }

        // A Gemini account that somehow got registered with the wrong
        // source (e.g. a stale persisted snapshot) must surface a
        // clear error instead of silently doing nothing.
        let oddAccount = AccountIdentity(
            id: "stale-gemini",
            tool: .gemini,
            alias: "Stale",
            source: .cliDetected,
            createdAt: Date(),
            updatedAt: Date()
        )
        do {
            _ = try await adapter.fetch(for: oddAccount)
            XCTFail("Expected throw for unsupported source")
        } catch QuotaError.unknown {
            // Pass
        } catch {
            XCTFail("Expected .unknown, got \(error)")
        }
    }

    func testResponseShapeChangeUsesInjectedWebCalibrationImmediately() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GeminiAdapterStubURLProtocol.self]
        let session = URLSession(configuration: config)
        GeminiAdapterStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            if request.httpMethod == "GET" {
                return (
                    response,
                    Data(#"<script>window.WIZ_global_data={"SNlM0e":"synthetic-xsrf"};</script>"#.utf8)
                )
            }
            // A successful Google response that no longer contains the known
            // quota rpcid must enter WebKit calibration in this same refresh.
            return (response, Data(#")]}'\n[["wrb.fr","rotated","[]",null]]"#.utf8))
        }

        let adapter = GeminiQuotaAdapter(
            session: session,
            cookieHeader: { "__Secure-1PSID=synthetic" },
            browserCookieImporter: { nil },
            webFallback: { account, _ in
                AccountQuota(
                    accountId: account.id,
                    tool: .gemini,
                    buckets: [
                        QuotaBucket(
                            id: "five_hour",
                            title: "5 Hours",
                            shortLabel: "5 Hours",
                            usedPercent: 12
                        ),
                        QuotaBucket(
                            id: "weekly",
                            title: "Weekly",
                            shortLabel: "Weekly",
                            usedPercent: 34
                        )
                    ],
                    plan: "Ultra",
                    queriedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            }
        )

        let quota = try await adapter.fetch(for: account(source: .webCookie))

        XCTAssertEqual(quota.plan, "Ultra")
        XCTAssertEqual(quota.buckets.map(\.id), ["five_hour", "weekly"])
        XCTAssertEqual(quota.buckets.map(\.usedPercent), [12, 34])
    }
}

private final class GeminiAdapterStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler:
        (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

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
