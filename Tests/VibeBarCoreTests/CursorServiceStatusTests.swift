import XCTest
@testable import VibeBarCore

final class CursorServiceStatusTests: XCTestCase {
    /// Fixed clock so the synthetic `uptimeData` dates line up with the day
    /// buckets the client builds.
    private let now = Date(timeIntervalSince1970: 1_786_000_000)
    private let dayCount = 90
    /// Seconds of partial outage the fixture reports on one day.
    private let outageSeconds = 5_100

    override func tearDown() {
        CursorStatusURLProtocol.handler = nil
        super.tearDown()
    }

    func testFetchesCursorStatuspageGroupsIncidentsAndUptimeHistory() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CursorStatusURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let html = statusPageHTML()
        CursorStatusURLProtocol.handler = { request in
            switch request.url?.path {
            case "/":
                return Data(html.utf8)
            case "/api/v2/summary.json":
                return Data("""
                {
                  "page": {"id":"cursor","name":"Cursor","updated_at":"2026-08-17T08:00:00Z"},
                  "status": {"indicator":"none","description":"All Systems Operational"},
                  "components": [
                    {"id":"agents","name":"Agents","status":"degraded_performance","group_id":null,"group":true},
                    {"id":"cloud","name":"Cloud Agents","status":"degraded_performance","group_id":"agents","group":false},
                    {"id":"ide","name":"IDE","status":"operational","group_id":null,"group":false},
                    {"id":"bot","name":"Grok Bot","status":"operational","group_id":null,"group":false}
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

        let snapshot = try await ServiceStatusClient(session: session)
            .fetch(tool: .cursor, dayCount: dayCount, now: now)
        XCTAssertEqual(snapshot.tool, .cursor)
        XCTAssertEqual(snapshot.indicator, .none)
        XCTAssertEqual(snapshot.effectiveIndicator, .minor)
        XCTAssertEqual(snapshot.groups, [ServiceComponentGroup(id: "agents", name: "Agents")])
        XCTAssertEqual(snapshot.components.map(\.name), ["Cloud Agents", "IDE", "Grok Bot"])
        XCTAssertEqual(snapshot.recentIncidents.first?.name, "Cloud Agents degraded")

        // Every component gets a real 90-day strip and an uptime percentage
        // scraped from the page's `window.uptimeData` blob — not an empty
        // gray track like the JSON-only fetch used to produce.
        for component in snapshot.components {
            XCTAssertEqual(component.recentDays.count, dayCount, component.name)
            XCTAssertNotNil(component.uptimePercent, component.name)
        }

        let cloud = try XCTUnwrap(snapshot.components.first { $0.name == "Cloud Agents" })
        let expected = (1 - Double(outageSeconds) / (Double(dayCount) * 86_400)) * 100
        XCTAssertEqual(try XCTUnwrap(cloud.uptimePercent), expected, accuracy: 0.0001)
        XCTAssertEqual(cloud.recentDays.filter { $0.worstImpact != nil }.count, 1)
        XCTAssertEqual(cloud.recentDays.compactMap(\.worstImpact), [.major])

        let ide = try XCTUnwrap(snapshot.components.first { $0.name == "IDE" })
        XCTAssertEqual(try XCTUnwrap(ide.uptimePercent), 100, accuracy: 0.0001)
        XCTAssertTrue(ide.recentDays.allSatisfy { $0.worstImpact == nil })

        // The aggregate the card header shows is now driven by real history.
        XCTAssertGreaterThan(snapshot.displayUptimePercent, 99)
        XCTAssertLessThan(snapshot.displayUptimePercent, 100)
    }

    /// Grok Bot is published on Cursor's status page but is a first-class
    /// SpaceXAI sub-provider here, so it must get its own group rather than
    /// read as a Cursor feature.
    func testSpaceXAIMergeSplitsGrokBotIntoItsOwnGroup() async throws {
        let snapshot = try await cursorSnapshot()
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
        XCTAssertEqual(spaceXAI.groups.map(\.name), ["Grok", "Cursor", "Grok Bot"])

        let grokGroup = spaceXAI.groups[0]
        let cursorGroup = spaceXAI.groups[1]
        let botGroup = spaceXAI.groups[2]
        XCTAssertEqual(botGroup.id, "subprovider:grok-bot")
        XCTAssertEqual(spaceXAI.components(in: grokGroup).map(\.name), ["Grok Web"])
        XCTAssertEqual(spaceXAI.components(in: cursorGroup).map(\.name), ["Cloud Agents", "IDE"])
        XCTAssertEqual(spaceXAI.components(in: botGroup).map(\.name), ["Grok Bot"])
        XCTAssertTrue(spaceXAI.components(in: nil).isEmpty)

        // Sub-provider grouping must not drop the scraped history.
        for component in spaceXAI.components(in: botGroup) {
            XCTAssertEqual(component.recentDays.count, dayCount)
            XCTAssertNotNil(component.uptimePercent)
        }

        let cursorOnly = try XCTUnwrap(ServiceStatusSnapshot.mergedSpaceXAI(
            grok: nil,
            cursor: snapshot
        ))
        XCTAssertEqual(cursorOnly.tool, .grok)
        XCTAssertEqual(cursorOnly.indicator, .minor)
        XCTAssertEqual(cursorOnly.groups.map(\.name), ["Cursor", "Grok Bot"])

        let googleFallback = ServiceStatusSnapshot.preferredGoogleAI(
            gemini: nil,
            antigravity: snapshot
        )
        XCTAssertEqual(googleFallback, snapshot)
    }

    /// A blocked or redesigned status page must still yield current status and
    /// incidents — with honest empty strips rather than a fabricated 100%.
    func testMissingUptimeBlobLeavesUptimeUnknown() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CursorStatusURLProtocol.self]
        let session = URLSession(configuration: configuration)
        CursorStatusURLProtocol.handler = { request in
            switch request.url?.path {
            case "/":
                throw URLError(.timedOut)
            case "/api/v2/summary.json":
                return Data("""
                {
                  "page": {"id":"cursor","name":"Cursor","updated_at":"2026-08-17T08:00:00Z"},
                  "status": {"indicator":"none","description":"All Systems Operational"},
                  "components": [
                    {"id":"ide","name":"IDE","status":"operational","group_id":null,"group":false}
                  ]
                }
                """.utf8)
            case "/api/v2/incidents.json":
                return Data(#"{"incidents":[]}"#.utf8)
            default:
                throw URLError(.badURL)
            }
        }

        let snapshot = try await ServiceStatusClient(session: session)
            .fetch(tool: .cursor, dayCount: dayCount, now: now)
        XCTAssertEqual(snapshot.components.map(\.name), ["IDE"])
        XCTAssertNil(snapshot.components.first?.uptimePercent)
        XCTAssertTrue(try XCTUnwrap(snapshot.components.first).recentDays.isEmpty)
        XCTAssertEqual(snapshot.description, "All Systems Operational")
    }

    // MARK: - Fixtures

    private func cursorSnapshot() async throws -> ServiceStatusSnapshot {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CursorStatusURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let html = statusPageHTML()
        CursorStatusURLProtocol.handler = { request in
            switch request.url?.path {
            case "/":
                return Data(html.utf8)
            case "/api/v2/summary.json":
                return Data("""
                {
                  "page": {"id":"cursor","name":"Cursor","updated_at":"2026-08-17T08:00:00Z"},
                  "status": {"indicator":"none","description":"All Systems Operational"},
                  "components": [
                    {"id":"cloud","name":"Cloud Agents","status":"degraded_performance","group_id":null,"group":false},
                    {"id":"ide","name":"IDE","status":"operational","group_id":null,"group":false},
                    {"id":"bot","name":"Grok Bot","status":"operational","group_id":null,"group":false}
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
        return try await ServiceStatusClient(session: session)
            .fetch(tool: .cursor, dayCount: dayCount, now: now)
    }

    /// Synthetic stand-in for the real page: the alias line plus the
    /// `window.uptimeData` blob, keyed by the fixture's own component ids.
    private func statusPageHTML() -> String {
        let specs: [(id: String, name: String, outageDayOffset: Int?)] = [
            ("cloud", "Cloud Agents", 3),
            ("ide", "IDE", nil),
            ("bot", "Grok Bot", nil)
        ]
        let entries = specs.map { id, name, outageOffset -> String in
            """
            "\(id)":{"component":{"code":"\(id)","name":"\(name)","startDate":"2026-01-01"},\
            "days":\(uptimeDays(outageDayOffset: outageOffset))}
            """
        }
        return """
        <script>var uptimeData = window.uptimeData;</script>
        <script>window.uptimeData = {\(entries.joined(separator: ","))};</script>
        """
    }

    private func uptimeDays(outageDayOffset: Int?) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = calendar.startOfDay(for: now)
        let days = stride(from: dayCount - 1, through: 0, by: -1).compactMap { offset -> String? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let outages = offset == outageDayOffset ? "{\"p\":\(outageSeconds)}" : "{}"
            return "{\"date\":\"\(formatter.string(from: date))\",\"outages\":\(outages),\"related_events\":[]}"
        }
        return "[" + days.joined(separator: ",") + "]"
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
