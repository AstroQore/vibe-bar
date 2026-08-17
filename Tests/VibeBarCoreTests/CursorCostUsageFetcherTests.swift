import XCTest
@testable import VibeBarCore

final class CursorCostUsageFetcherTests: XCTestCase {
    override func tearDown() {
        CursorCostStubURLProtocol.handler = nil
        super.tearDown()
    }

    func testBuildsSnapshotFromCursorEventsAndExcludesGrokBotRows() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CursorCostStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let now = Date(timeIntervalSince1970: 1_786_968_000)
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("cursor-dashboard")
        defer { try? FileManager.default.removeItem(at: directory) }
        var firstEventInputTokens = 100
        var firstEventCostCents = 100

        CursorCostStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/dashboard/get-filtered-usage-events")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://cursor.test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "WorkosCursorSessionToken=fixture")
            let body = try Self.body(of: request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let page = try XCTUnwrap(object["page"] as? Int)

            if page == 1 {
                return Self.response("""
                {
                  "totalUsageEventsCount": 3,
                  "usageEventsDisplay": [
                    {
                      "timestamp": "1786967900000",
                      "model": "cursor-grok-4.6-high-fast",
                      "clientType": "cli",
                      "tokenUsage": {
                        "inputTokens": \(firstEventInputTokens),
                        "outputTokens": 50,
                        "cacheWriteTokens": 5,
                        "cacheReadTokens": 10,
                        "totalCents": \(firstEventCostCents)
                      }
                    },
                    {
                      "timestamp": "1786967950000",
                      "model": "composer-2.5",
                      "tokenUsage": {
                        "inputTokens": "10",
                        "outputTokens": "5",
                        "cacheWriteTokens": 0,
                        "cacheReadTokens": 0,
                        "totalCents": "50"
                      }
                    }
                  ]
                }
                """)
            }
            return Self.response("""
            {
              "totalUsageEventsCount": "3",
              "usageEventsDisplay": [
                {
                  "timestamp": "1786967990000",
                  "model": "cloud-model",
                  "clientType": "grok-bot",
                  "tokenUsage": {
                    "inputTokens": 999,
                    "outputTokens": 999,
                    "cacheWriteTokens": 0,
                    "cacheReadTokens": 0,
                    "totalCents": 999
                  }
                }
              ]
            }
            """)
        }

        let snapshot = try await CursorCostUsageFetcher(
            session: session,
            baseURL: URL(string: "https://cursor.test")!,
            pageSize: 2,
            maxPages: 3
        ).fetchSnapshot(
            cookieHeader: "WorkosCursorSessionToken=fixture",
            since: nil,
            until: now,
            now: now,
            eventSink: ledger,
            sourceID: "fixture-account"
        )

        XCTAssertEqual(snapshot.tool, .cursor)
        XCTAssertEqual(snapshot.allTimeRequests, 2)
        XCTAssertEqual(snapshot.allTimeTokens, 180)
        XCTAssertEqual(snapshot.allTimeCostUSD, 1.50, accuracy: 0.000_001)
        XCTAssertEqual(Set(snapshot.modelBreakdowns.map(\.modelName)), [
            "cursor-grok-4.6-high-fast", "composer-2.5"
        ])
        XCTAssertFalse(snapshot.modelBreakdowns.contains { $0.modelName == "cloud-model" })

        let filter = UsageQueryFilter(range: DateInterval(
            start: now.addingTimeInterval(-300),
            end: now.addingTimeInterval(1)
        ))
        let ledgerSummary = try await ledger.summary(filter)
        XCTAssertEqual(ledgerSummary.requests, snapshot.allTimeRequests)
        XCTAssertEqual(ledgerSummary.realTotalTokens, Int64(snapshot.allTimeTokens))
        XCTAssertEqual(ledgerSummary.costMicros, 1_500_000)
        XCTAssertEqual(ledgerSummary.freshInput, 110)
        XCTAssertEqual(ledgerSummary.output, 55)
        XCTAssertEqual(ledgerSummary.cacheCreation, 5)
        XCTAssertEqual(ledgerSummary.cacheRead, 10)
        let ledgerTools = try await ledger.providerStats(filter).map(\.tool)
        XCTAssertEqual(ledgerTools, [.cursor])
        _ = try await ledger.prepareForPricingRevision("cursor-authoritative-v1")
        let repricedSummary = try await ledger.summary(filter)
        XCTAssertEqual(repricedSummary.costMicros, ledgerSummary.costMicros)

        // Re-fetching an unchanged dashboard must update neither side's
        // final totals nor duplicate request rows in the Workbench ledger.
        _ = try await CursorCostUsageFetcher(
            session: session,
            baseURL: URL(string: "https://cursor.test")!,
            pageSize: 2,
            maxPages: 3
        ).fetchSnapshot(
            cookieHeader: "WorkosCursorSessionToken=fixture",
            since: nil,
            until: now,
            now: now,
            eventSink: ledger,
            sourceID: "fixture-account"
        )
        let secondLedgerSummary = try await ledger.summary(filter)
        XCTAssertEqual(secondLedgerSummary, ledgerSummary)

        // Cursor may correct a row in place while keeping both the total event
        // count and latest timestamp unchanged. The content fingerprint must
        // force a re-ingest, while the stable event identity updates instead
        // of duplicating the request.
        firstEventInputTokens = 120
        firstEventCostCents = 125
        let correctedSnapshot = try await CursorCostUsageFetcher(
            session: session,
            baseURL: URL(string: "https://cursor.test")!,
            pageSize: 2,
            maxPages: 3
        ).fetchSnapshot(
            cookieHeader: "WorkosCursorSessionToken=fixture",
            since: nil,
            until: now,
            now: now,
            eventSink: ledger,
            sourceID: "fixture-account"
        )
        let correctedLedgerSummary = try await ledger.summary(filter)
        XCTAssertEqual(correctedSnapshot.allTimeRequests, 2)
        XCTAssertEqual(correctedSnapshot.allTimeTokens, 200)
        XCTAssertEqual(correctedSnapshot.allTimeCostUSD, 1.75, accuracy: 0.000_001)
        XCTAssertEqual(correctedLedgerSummary.requests, 2)
        XCTAssertEqual(correctedLedgerSummary.realTotalTokens, 200)
        XCTAssertEqual(correctedLedgerSummary.costMicros, 1_750_000)
    }

    func testRejectedCursorAppSessionFallsBackWithoutDoubleCounting() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CursorCostStubURLProtocol.self]
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

        CursorCostStubURLProtocol.handler = { request in
            if request.value(forHTTPHeaderField: "Cookie") == preferred.header {
                return (401, Data())
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), fallback.header)
            return Self.response("""
            {
              "totalUsageEventsCount": 1,
              "usageEventsDisplay": [
                {
                  "timestamp": "1786967900000",
                  "model": "composer-2.5",
                  "tokenUsage": {
                    "inputTokens": 100,
                    "outputTokens": 50,
                    "cacheWriteTokens": 0,
                    "cacheReadTokens": 0,
                    "totalCents": 25
                  }
                }
              ]
            }
            """)
        }

        let outcome = await CursorCostUsageFetcher.fetch(
            homeDirectory: "/Users/example",
            now: Date(timeIntervalSince1970: 1_786_968_000),
            retentionDays: 30,
            session: session,
            resolutionPlan: plan
        )
        guard case .success(let snapshot) = outcome else {
            return XCTFail("Expected browser fallback snapshot")
        }
        XCTAssertEqual(snapshot.allTimeRequests, 1)
        XCTAssertEqual(snapshot.allTimeTokens, 150)
        XCTAssertEqual(snapshot.allTimeCostUSD, 0.25, accuracy: 0.000_001)
    }

    private static func body(of request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func response(_ body: String) -> (Int, Data) {
        (200, Data(body.utf8))
    }
}

private final class CursorCostStubURLProtocol: URLProtocol {
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
