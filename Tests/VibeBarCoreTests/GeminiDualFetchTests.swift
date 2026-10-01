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

    /// A signed-out Google session in one browser must not hide the live one
    /// in the next: the adapter walks every store until one authenticates.
    func testSignedOutFirstStoreFallsThroughToLiveStore() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GeminiAdapterStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let getCookies = LockedStrings()
        GeminiAdapterStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            if request.httpMethod == "GET" {
                getCookies.append(cookie)
                // Only the live session's page carries the XSRF token.
                let body = cookie.contains("live")
                    ? #"<script>window.WIZ_global_data={"SNlM0e":"synthetic-xsrf"};</script>"#
                    : "<html>signed out</html>"
                return (response, Data(body.utf8))
            }
            return (response, Data(#")]}'\n[["wrb.fr","rotated","[]",null]]"#.utf8))
        }

        let stored = LockedStrings()
        let fallbackHeaders = LockedStrings()
        let adapter = GeminiQuotaAdapter(
            session: session,
            cookieHeader: { "__Secure-1PSID=synthetic-expired" },
            browserCookieImporter: {
                [
                    .init(header: "__Secure-1PSID=synthetic-stale", sourceLabel: "Safari", cookieCount: 1),
                    .init(header: "__Secure-1PSID=synthetic-live", sourceLabel: "Chrome (Default)", cookieCount: 1)
                ]
            },
            storeCookieHeader: { stored.append($0) },
            webFallback: { account, header in
                fallbackHeaders.append(header)
                return AccountQuota(
                    accountId: account.id,
                    tool: .gemini,
                    buckets: [],
                    plan: nil,
                    email: nil,
                    queriedAt: Date(),
                    error: nil
                )
            }
        )
        let account = AccountIdentity(
            id: "web-gemini",
            tool: .gemini,
            email: nil,
            alias: nil,
            plan: nil,
            accountId: nil,
            source: .webCookie,
            allowsWebFallback: false,
            updatedAt: Date()
        )

        _ = try await adapter.fetch(for: account)
        XCTAssertEqual(fallbackHeaders.values, ["__Secure-1PSID=synthetic-live"])
        XCTAssertEqual(stored.values, ["__Secure-1PSID=synthetic-live"])

        // The stale store was answered once and is set aside: a second
        // refresh must not spend another request on it.
        _ = try await adapter.fetch(for: account)
        XCTAssertEqual(
            getCookies.values.filter { $0.contains("stale") }.count,
            1
        )
    }

    func testValidatedImportSkipsSignedOutCandidate() async throws {
        let stored = LockedStrings()
        let result = try await GeminiBrowserCookieImporter.importValidatedAndStoreFromBrowsers(
            isSignedOut: { $0.contains("stale") },
            candidates: {
                [
                    .init(header: "stale", sourceLabel: "Safari", cookieCount: 1),
                    .init(header: "live", sourceLabel: "Chrome (Default)", cookieCount: 1)
                ]
            },
            store: { stored.append($0) }
        )
        XCTAssertEqual(result?.sourceLabel, "Chrome (Default)")
        XCTAssertEqual(stored.values, ["live"])
    }

    func testValidatedImportKeepsFirstCandidateWhenAllAreSignedOut() async throws {
        let stored = LockedStrings()
        let result = try await GeminiBrowserCookieImporter.importValidatedAndStoreFromBrowsers(
            isSignedOut: { _ in true },
            candidates: { [.init(header: "a", sourceLabel: "A", cookieCount: 1),
                           .init(header: "b", sourceLabel: "B", cookieCount: 1)] },
            store: { stored.append($0) }
        )
        XCTAssertEqual(result?.sourceLabel, "A")
        XCTAssertEqual(stored.values, ["a"])
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
            browserCookieImporter: { [] },
            storeCookieHeader: { _ in },
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

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}
