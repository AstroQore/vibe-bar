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
                        "inputTokens": 100,
                        "outputTokens": 50,
                        "cacheWriteTokens": 5,
                        "cacheReadTokens": 10,
                        "totalCents": 100
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
            now: now
        )

        XCTAssertEqual(snapshot.tool, .cursor)
        XCTAssertEqual(snapshot.allTimeRequests, 2)
        XCTAssertEqual(snapshot.allTimeTokens, 180)
        XCTAssertEqual(snapshot.allTimeCostUSD, 1.50, accuracy: 0.000_001)
        XCTAssertEqual(Set(snapshot.modelBreakdowns.map(\.modelName)), [
            "cursor-grok-4.6-high-fast", "composer-2.5"
        ])
        XCTAssertFalse(snapshot.modelBreakdowns.contains { $0.modelName == "cloud-model" })
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
