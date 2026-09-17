import XCTest
@testable import VibeBarCore

/// Mistral's status page is a Checkly page; its feeds are read from the
/// Checkly host because `status.mistral.ai` answers scripts with a bot
/// challenge. Fixtures are trimmed from the live feeds of 2026-09-17.
final class MistralStatusTests: XCTestCase {
    private let now = ServiceStatusClient.flexibleDate(from: "2026-09-17T12:00:00Z")!

    private let summary = Data(#"""
    {"page":{"name":"Mistral AI Status Page","url":"https://mistral-ai.checkly-status-page.com","status":"HAS_ISSUES"},
     "activeIncidents":[{"id":"44cb5e11-4736-4e6b-9198-97121820e15e","name":"Free Tier Temporarily Disabled","startedAt":"2026-09-04T04:04:04.000Z","status":"IDENTIFIED","severity":"MAJOR","affectedServices":[{"id":"c4869a5a","name":"Chat Completions API","group":"API"}],"url":"https://mistral-ai.checkly-status-page.com/incident/44cb5e11-4736-4e6b-9198-97121820e15e","updatedAt":"2026-09-04T04:04:04.000Z"}],
     "activeMaintenances":[]}
    """#.utf8)

    private let services = Data(#"""
    [{"id":"c4869a5a","name":"Chat Completions API","status":"MAJOR","group":"API"},
     {"id":"6d1417e5","name":"Embeddings API","status":"OPERATIONAL","group":"API"},
     {"id":"edb2d9fb","name":"Vibe","status":"OPERATIONAL","group":"Services"}]
    """#.utf8)

    private let uptime = Data(#"""
    {"metadata":[],
     "uptime":[
       {"name":"API","uptime":98.149,"services":[
         {"id":"c4869a5a","name":"Chat Completions API","uptime":84.864,"days":[
           {"date":"2026-09-15T00:00:00.000Z","events":[]},
           {"date":"2026-09-16T00:00:00.000Z","events":[{"id":"44cb5e11-4736-4e6b-9198-97121820e15e","name":"Free Tier Temporarily Disabled","duration":31762,"severity":"MAJOR","lastUpdateStatus":"IDENTIFIED","created_at":"2026-09-04T04:04:04.000Z"}]},
           {"date":"2026-09-17T00:00:00.000Z","events":[{"id":"44cb5e11-4736-4e6b-9198-97121820e15e","name":"Free Tier Temporarily Disabled","duration":31762,"severity":"MAJOR","lastUpdateStatus":"IDENTIFIED","created_at":"2026-09-04T04:04:04.000Z"}]}
         ]}
       ]},
       {"name":"Services","uptime":99.5,"services":[
         {"id":"edb2d9fb","name":"Vibe","uptime":99.022,"days":[
           {"date":"2026-09-10T00:00:00.000Z","events":[{"id":"5cb98f6e","name":"Completion API Degraded - mistral-vibe-cli-fast","duration":97,"severity":"MEDIUM","lastUpdateStatus":"RESOLVED","created_at":"2026-09-10T08:02:08.486Z"}]}
         ]}
       ]}
     ],
     "partialError":false}
    """#.utf8)

    func testServicesIncidentsAndHistoryMapOntoTheSnapshot() throws {
        let snapshot = try ServiceStatusClient.parseChecklyStatus(
            tool: .mistralVibe, summary: summary, services: services, uptime: uptime, dayCount: 7, now: now
        )
        XCTAssertEqual(snapshot.tool, .mistralVibe)
        XCTAssertEqual(snapshot.indicator, .major)
        XCTAssertEqual(snapshot.groups.map(\.name), ["API", "Services"])
        XCTAssertEqual(snapshot.components.map(\.name), ["Chat Completions API", "Embeddings API", "Vibe"])
        XCTAssertEqual(snapshot.components[0].status, .partialOutage)
        XCTAssertEqual(snapshot.components[0].groupId, "API")
        XCTAssertEqual(snapshot.components[0].uptimePercent, 84.864)
        XCTAssertEqual(snapshot.components[0].recentDays.count, 7)
        XCTAssertEqual(snapshot.components[0].recentDays.last?.worstImpact, .major)
        XCTAssertNil(snapshot.components[1].uptimePercent, "no history for this service")

        XCTAssertEqual(snapshot.recentIncidents.map(\.name), [
            "Completion API Degraded - mistral-vibe-cli-fast",
            "Free Tier Temporarily Disabled"
        ])
        let open = try XCTUnwrap(snapshot.recentIncidents.last)
        XCTAssertNil(open.resolvedAt)
        XCTAssertEqual(open.impact, .major)
        let resolved = try XCTUnwrap(snapshot.recentIncidents.first)
        XCTAssertEqual(resolved.impact, .minor)
        XCTAssertEqual(resolved.resolvedAt, resolved.createdAt.addingTimeInterval(97))
    }

    /// The history is best-effort: without it the current state stands.
    func testMissingHistoryKeepsTheCurrentState() throws {
        let snapshot = try ServiceStatusClient.parseChecklyStatus(
            tool: .mistralVibe, summary: summary, services: services, uptime: nil, dayCount: 90, now: now
        )
        XCTAssertEqual(snapshot.indicator, .major)
        XCTAssertTrue(snapshot.components.allSatisfy { $0.recentDays.isEmpty && $0.uptimePercent == nil })
        XCTAssertEqual(snapshot.recentIncidents.count, 1)
    }

    func testAnAllOperationalPageIsQuiet() throws {
        let quiet = Data(#"[{"id":"a","name":"Vibe","status":"OPERATIONAL","group":"Services"}]"#.utf8)
        let emptySummary = Data(#"{"page":{"status":"OPERATIONAL"},"activeIncidents":[],"activeMaintenances":[]}"#.utf8)
        let snapshot = try ServiceStatusClient.parseChecklyStatus(
            tool: .mistralVibe, summary: emptySummary, services: quiet, uptime: nil, dayCount: 90, now: now
        )
        XCTAssertEqual(snapshot.indicator, .none)
        XCTAssertEqual(snapshot.description, "")
    }

    func testNonJSONIsABadResponse() {
        XCTAssertThrowsError(try ServiceStatusClient.parseChecklyStatus(
            tool: .mistralVibe, summary: Data("<html>".utf8), services: services, uptime: nil, dayCount: 90, now: now
        ))
    }

    func testStatusURLsForTheNewCompanies() {
        XCTAssertTrue(ToolType.devin.supportsStatusPage)
        XCTAssertEqual(ToolType.devin.statusSummaryAPI.absoluteString, "https://www.devinstatus.com/api/v2/summary.json")
        XCTAssertTrue(ToolType.mistralVibe.supportsStatusPage)
        XCTAssertEqual(ToolType.mistralVibe.statusPageURL.absoluteString, "https://status.mistral.ai/")
    }
}
