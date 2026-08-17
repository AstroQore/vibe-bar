import XCTest
@testable import VibeBarCore

final class CursorQuotaAdapterFallbackTests: XCTestCase {
    override func tearDown() {
        CursorQuotaFallbackStub.handler = nil
        super.tearDown()
    }

    func testRejectedCursorAppSessionFallsBackToSavedCookie() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CursorQuotaFallbackStub.self]
        let session = URLSession(configuration: configuration)
        let preferred = MiscCookieResolver.Resolution(
            slotID: nil,
            header: "WorkosCursorSessionToken=revoked-app",
            sourceLabel: "Cursor.app"
        )
        let fallback = MiscCookieResolver.Resolution(
            slotID: UUID(),
            header: "WorkosCursorSessionToken=working-browser",
            sourceLabel: "Browser"
        )
        let plan = CursorSessionResolutionPlan(preferred: preferred, fallbacks: [fallback])

        CursorQuotaFallbackStub.handler = { request in
            let cookie = request.value(forHTTPHeaderField: "Cookie")
            if cookie == preferred.header {
                return (401, Data())
            }
            XCTAssertEqual(cookie, fallback.header)
            switch request.url?.path {
            case "/api/usage-summary":
                return (200, Data("""
                {
                  "membershipType": "ultra",
                  "billingCycleStart": "2026-08-12T00:00:00Z",
                  "billingCycleEnd": "2026-09-12T00:00:00Z",
                  "individualUsage": {
                    "plan": {"autoPercentUsed": 1, "apiPercentUsed": 2}
                  }
                }
                """.utf8))
            case "/api/auth/me":
                return (200, Data(#"{"sub":"fixture-user"}"#.utf8))
            case "/api/dashboard/get-sand-usage-status":
                return (200, Data("""
                {
                  "currentPeriodStart": "2026-08-12T00:00:00Z",
                  "nextResetTimestampUtc": "2026-08-19T00:00:00Z",
                  "usagePercent": 5,
                  "hasNonZeroIncludedLimit": true
                }
                """.utf8))
            default:
                return (404, Data())
            }
        }

        let account = AccountIdentity(
            id: CursorSessionResolver.stableAccountID,
            tool: .cursor,
            alias: "Cursor",
            source: .cliDetected
        )
        let quota = try await CursorQuotaAdapter(
            session: session,
            now: { Date(timeIntervalSince1970: 1_786_968_000) },
            resolutionPlanProvider: { _, _ in plan }
        ).fetch(for: account)

        XCTAssertEqual(quota.plan, "Ultra")
        XCTAssertEqual(quota.buckets.map(\.id), ["models", "other_models", "grok_bot_weekly"])
    }
}

private final class CursorQuotaFallbackStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
