import XCTest
@testable import VibeBarCore

final class CursorServiceStatusTests: XCTestCase {
    override func tearDown() {
        CursorStatusURLProtocol.handler = nil
        super.tearDown()
    }

    func testFetchesCursorStatuspageGroupsAndIncidents() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CursorStatusURLProtocol.self]
        let session = URLSession(configuration: configuration)
        CursorStatusURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/v2/summary.json":
                return Data("""
                {
                  "page": {"id":"cursor","name":"Cursor","updated_at":"2026-08-17T08:00:00Z"},
                  "status": {"indicator":"none","description":"All Systems Operational"},
                  "components": [
                    {"id":"agents","name":"Agents","status":"degraded_performance","group_id":null,"group":true},
                    {"id":"cloud","name":"Cloud Agents","status":"degraded_performance","group_id":"agents","group":false},
                    {"id":"ide","name":"IDE","status":"operational","group_id":null,"group":false}
                  ]
                }
                """.utf8)
            case "/api/v2/incidents.json":
                return Data("""
                {"incidents":[{
                  "id":"incident-1",
                  "name":"Cloud Agents degraded",
                  "impact":"minor",
                  "created_at":"2026-08-17T07:30:00Z",
                  "resolved_at":null,
                  "shortlink":"https://status.cursor.com/incidents/incident-1"
                }]}
                """.utf8)
            default:
                throw URLError(.badURL)
            }
        }

        let snapshot = try await ServiceStatusClient(session: session).fetch(tool: .cursor)
        XCTAssertEqual(snapshot.tool, .cursor)
        XCTAssertEqual(snapshot.indicator, .none)
        XCTAssertEqual(snapshot.effectiveIndicator, .minor)
        XCTAssertEqual(snapshot.groups, [ServiceComponentGroup(id: "agents", name: "Agents")])
        XCTAssertEqual(snapshot.components.map(\.name), ["Cloud Agents", "IDE"])
        XCTAssertEqual(snapshot.recentIncidents.first?.name, "Cloud Agents degraded")

        let grok = ServiceStatusSnapshot(
            tool: .grok,
            indicator: .none,
            description: "All systems operational",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            groups: [],
            components: [ServiceComponentSummary(
                id: "grok-web",
                name: "Grok Web",
                status: .operational
            )],
            recentIncidents: []
        )
        let spaceXAI = try XCTUnwrap(ServiceStatusSnapshot.mergedSpaceXAI(
            grok: grok,
            cursor: snapshot
        ))
        XCTAssertEqual(spaceXAI.tool, .grok)
        XCTAssertEqual(spaceXAI.indicator, .minor)
        XCTAssertEqual(spaceXAI.groups.map(\.name), ["Grok", "Cursor"])
        XCTAssertTrue(spaceXAI.components(in: spaceXAI.groups.first).contains {
            $0.name == "Grok Web"
        })
        XCTAssertTrue(spaceXAI.components(in: spaceXAI.groups.last).contains {
            $0.name == "Cloud Agents"
        })

        let cursorOnly = try XCTUnwrap(ServiceStatusSnapshot.mergedSpaceXAI(
            grok: nil,
            cursor: snapshot
        ))
        XCTAssertEqual(cursorOnly.tool, .grok)
        XCTAssertEqual(cursorOnly.indicator, .minor)
        XCTAssertEqual(cursorOnly.groups.map(\.name), ["Cursor"])
    }
}

private final class CursorStatusURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let data = try XCTUnwrap(Self.handler)(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
