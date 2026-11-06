import Foundation
import XCTest
@testable import VibeBarCore

final class OpenCodeGoQuotaAdapterTests: XCTestCase {
    private let defaultID = ToolType.openCodeGo.rawValue
    private let cloneID = "openCodeGo-copy"
    private let clock = Date(timeIntervalSince1970: 1_700_000_000)

    override func tearDown() {
        OpenCodeGoStubURLProtocol.handler = nil
        super.tearDown()
    }

    func testFetchUsesTheInstanceKeyAndKeepsSubOnePercentValues() async throws {
        let clock = clock
        let adapter = makeAdapter(
            storedKeys: [defaultID: "key-for-default", cloneID: " key-for-copy\n"],
            environmentKey: "key-from-environment"
        )
        respond(200, Self.usage(0.1, 0.5, 99)) { request in
            XCTAssertEqual(request.url?.absoluteString, "https://opencode.ai/zen/go/v1/usage")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key-for-copy")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertFalse(request.httpShouldHandleCookies)
        }

        let account = account(for: cloneID)
        let quota = try await adapter.fetch(for: account)
        XCTAssertEqual(quota.accountId, account.id)
        XCTAssertEqual(quota.queriedAt, clock)
        XCTAssertNil(quota.error)
        XCTAssertEqual(quota.buckets.map(\.id), ["opencodego.rolling", "opencodego.weekly", "opencodego.monthly"])
        XCTAssertEqual(quota.buckets.map(\.usedPercent), [0.1, 0.5, 99])
        XCTAssertEqual(quota.buckets.map(\.rawWindowSeconds), [18_000, 604_800, 2_592_000])
        XCTAssertEqual(quota.buckets[0].resetAt, clock.addingTimeInterval(0.5))
        XCTAssertEqual(quota.buckets[1].resetAt, clock.addingTimeInterval(60))
        XCTAssertNil(quota.buckets[2].resetAt)
    }

    func testZeroAndOnePercentAreRealReadingsAndExhaustedWindowStillHasQuota() async throws {
        let adapter = makeAdapter(environmentKey: " key-from-environment\n")
        respond(200, Self.usage(0, 1, 100, monthlyStatus: "rate-limited")) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key-from-environment")
        }
        let quota = try await adapter.fetch(for: account(for: defaultID))
        XCTAssertEqual(quota.buckets.map(\.usedPercent), [0, 1, 100])
    }

    func testCopyWithNoKeyCannotBorrowTheDefaultCredential() async {
        let adapter = makeAdapter(storedKeys: [defaultID: "key-for-default"], environmentKey: "key-from-environment")
        OpenCodeGoStubURLProtocol.handler = { _ in
            XCTFail("The unconfigured copy must not reach the network.")
            throw URLError(.badServerResponse)
        }

        await assertQuotaError(.noCredential, adapter: adapter, instanceID: cloneID)
    }

    func testHTTPFailuresAreDistinctAndDoNotRetryWithTheEnvironmentKey() async {
        let adapter = makeAdapter(storedKeys: [defaultID: "key-for-default"], environmentKey: "key-from-environment")
        let failureCases: [(Int, String, QuotaError)] = [
            (401, #"{"error":{"type":"AuthError","message":"do not display this upstream body"}}"#, .credentialRejected("")),
            (403, #"{"error":{"type":"EntitlementError","message":"do not display this upstream body"}}"#,
             .parseFailure(L10n.Error.openCodeGoSubscriptionRequired)),
            (403, "unexpected access error", .network("HTTP 403")),
            (429, "rate limited", .rateLimited),
            (503, "unavailable", .network("HTTP 503"))
        ]
        for (status, body, error) in failureCases {
            let requestReceived = expectation(description: "One request for HTTP \(status)")
            requestReceived.assertForOverFulfill = true
            respond(status, body) { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key-for-default")
                requestReceived.fulfill()
            }
            await assertQuotaError(error, adapter: adapter, instanceID: defaultID)
            await fulfillment(of: [requestReceived], timeout: 1)
        }
    }

    func testMissingOrInvalidUsageIsNotReportedAsZero() async {
        let adapter = makeAdapter(environmentKey: "key-from-environment")
        for body in [
            #"{"usage":{}}"#,
            #"{"usage":{"rolling":{"status":"ok","percent":0},"weekly":{"status":"ok","percent":0}}}"#,
            #"{"usage":{"rolling":{"status":"ok","percent":0},"weekly":{"status":"ok","percent":0},"monthly":{"status":"ok"}}}"#,
            Self.usage(-1, 0, 0),
            Self.usage(0, 0, 0, monthlyStatus: "not-subscribed")
        ] {
            respond(200, body)
            await assertQuotaError(.parseFailure(""), adapter: adapter, instanceID: defaultID)
        }
    }

    func testCancelledRequestRemainsCancellation() async {
        OpenCodeGoStubURLProtocol.handler = { _ in throw URLError(.cancelled) }
        do {
            _ = try await makeAdapter(environmentKey: "key-from-environment").fetch(for: account(for: defaultID))
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // URLSession cancellation must not become a quota/network error.
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
    }

    func testKeyOnlyAccountDiscoveryKeepsStableIdentityAndIgnoresOldDashboardSettings() {
        let defaults = MiscProviderInstance.defaultInstance(
            for: .openCodeGo, settings: .init(sourceMode: .browserOnly, workspaceID: "wrk_fixture")
        )
        let copy = MiscProviderInstance(id: cloneID, tool: .openCodeGo)
        let unrelated = MiscProviderInstance.defaultInstance(for: .kilo)
        let instances = [defaults, copy, unrelated]
        let accounts = AccountStore.miscAccounts(for: instances) { instanceID in
            instanceID == self.cloneID || instanceID == unrelated.id
        }
        XCTAssertEqual(accounts.map(\.id), instances.map { AccountStore.miscAccountId(forInstanceID: $0.id) })
        XCTAssertEqual(accounts.map(\.source), [.notConfigured, .apiToken, .notConfigured])
        XCTAssertEqual(
            AccountStore.miscAccounts(for: [defaults], hasOpenCodeGoAPIKey: { $0 == self.defaultID }).first?.source,
            .apiToken
        )
    }

    private func makeAdapter(
        storedKeys: [String: String] = [:], environmentKey: String? = nil
    ) -> OpenCodeGoQuotaAdapter {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenCodeGoStubURLProtocol.self]
        let clock = clock
        return OpenCodeGoQuotaAdapter(
            session: URLSession(configuration: configuration),
            environment: environmentKey.map { ["OPENCODE_API_KEY": $0] } ?? [:],
            storedAPIKey: { storedKeys[$0] },
            now: { clock }
        )
    }

    private func account(for instanceID: String) -> AccountIdentity {
        AccountIdentity(
            id: AccountStore.miscAccountId(forInstanceID: instanceID), tool: .openCodeGo,
            alias: "OpenCode Go", source: .notConfigured
        )
    }

    private func assertQuotaError(
        _ expected: QuotaError, adapter: OpenCodeGoQuotaAdapter, instanceID: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await adapter.fetch(for: account(for: instanceID))
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? QuotaError, expected, file: file, line: line)
        }
    }

    private func respond(
        _ status: Int, _ body: String, check: @escaping @Sendable (URLRequest) -> Void = { _ in }
    ) {
        OpenCodeGoStubURLProtocol.handler = { request in
            check(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
    }

    private static func usage(
        _ rolling: Double, _ weekly: Double, _ monthly: Double, monthlyStatus: String = "ok"
    ) -> String {
        """
        {"usage":{
          "rolling":{"status":"ok","percent":\(rolling),"resetsAt":"2023-11-14T22:13:20.500Z"},
          "weekly":{"status":"ok","percent":\(weekly),"resetsAt":"2023-11-14T22:14:20Z"},
          "monthly":{"status":"\(monthlyStatus)","percent":\(monthly),"resetsAt":"unknown"}
        }}
        """
    }
}

private final class OpenCodeGoStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
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
