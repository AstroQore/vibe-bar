import XCTest
@testable import VibeBarCore

final class XAIServiceStatusTests: XCTestCase {
    func testParsesOverviewAndComponentHistory() throws {
        let overview = """
        <html>
          <body>
            <h1>Service Status</h1>
            <h3>No incidents declared</h3>
            <a>Grok (Web) available</a>
            <a>API (us-east-1.api.x.ai) available</a>
          </body>
        </html>
        """
        let component = """
        <html>
          <body>
            <h1>API (us-east-1.api.x.ai)</h1>
            <h3>Service fully operational</h3>
            <h2>Past Issues</h2>
            <a>May 13, 2026, 03:50 PM UTC Requests Using grok-imagine Models have Reduced Success Rate Resolved · Duration: 47 minutes · disruption</a>
          </body>
        </html>
        """
        let now = try XCTUnwrap(ServiceStatusClient.parseXAIStatusDate("May 22, 2026, 12:00 PM UTC"))
        let snapshot = ServiceStatusClient.parseXAIStatusPages(
            tool: .grok,
            overviewHTML: overview,
            componentPages: [
                (id: "api-us-east-1", name: "API (us-east-1.api.x.ai)", url: URL(string: "https://status.x.ai/api-us-east-1")!, html: component)
            ],
            dayCount: 30,
            now: now
        )

        XCTAssertEqual(snapshot.tool, .grok)
        XCTAssertEqual(snapshot.indicator, .none)
        // status.x.ai publishes no page-level wording, so nothing goes into
        // the field that is cached to disk; our own (translated) summary is
        // derived on read instead.
        XCTAssertEqual(snapshot.description, "")
        XCTAssertEqual(snapshot.effectiveDescription, "All services operational")
        XCTAssertEqual(snapshot.components.count, 2)
        XCTAssertEqual(
            snapshot.components.first { $0.name == "API (us-east-1.api.x.ai)" }?.status,
            .operational
        )
        XCTAssertEqual(snapshot.recentIncidents.first?.name, "Requests Using grok-imagine Models have Reduced Success Rate")
        XCTAssertEqual(snapshot.recentIncidents.first?.impact, .minor)
        let incident = try XCTUnwrap(snapshot.recentIncidents.first)
        XCTAssertEqual(
            try XCTUnwrap(incident.resolvedAt).timeIntervalSince(incident.createdAt),
            47 * 60,
            accuracy: 0.001
        )
    }

    func testUnavailableComponentIsNotConfusedWithAvailable() throws {
        let now = try XCTUnwrap(ServiceStatusClient.parseXAIStatusDate("May 22, 2026, 12:00 PM UTC"))
        let snapshot = ServiceStatusClient.parseXAIStatusPages(
            tool: .grok,
            overviewHTML: "<h3>Incident declared</h3>",
            componentPages: [(
                id: "grok-com",
                name: "Grok (Web)",
                url: URL(string: "https://status.x.ai/grok-com")!,
                html: "<h1>Grok (Web)</h1><h3>Service unavailable</h3>"
            )],
            dayCount: 30,
            now: now
        )

        XCTAssertEqual(snapshot.indicator, .critical)
        XCTAssertEqual(snapshot.components.first?.status, .majorOutage)
    }

    func testIncidentDurationMarksEveryAffectedUTCDate() throws {
        let now = try XCTUnwrap(ServiceStatusClient.parseXAIStatusDate("May 15, 2026, 12:00 PM UTC"))
        let snapshot = ServiceStatusClient.parseXAIStatusPages(
            tool: .grok,
            overviewHTML: "<h3>No incidents declared</h3>",
            componentPages: [(
                id: "api-us-east-1",
                name: "API (us-east-1.api.x.ai)",
                url: URL(string: "https://status.x.ai/api-us-east-1")!,
                html: """
                <h3>Service fully operational</h3>
                <a>May 13, 2026, 11:30 PM UTC Cross-day incident Resolved · Duration: 2 hours 15 minutes · outage</a>
                """
            )],
            dayCount: 3,
            now: now
        )

        let incident = try XCTUnwrap(snapshot.recentIncidents.first)
        XCTAssertEqual(
            try XCTUnwrap(incident.resolvedAt).timeIntervalSince(incident.createdAt),
            2 * 3_600 + 15 * 60,
            accuracy: 0.001
        )
        let affectedDays = try XCTUnwrap(snapshot.components.first).recentDays
            .filter { $0.worstImpact != nil }
        XCTAssertEqual(affectedDays.count, 2)
    }

    func testOverviewBackfillsAComponentWhoseDetailRequestFailed() throws {
        let now = try XCTUnwrap(ServiceStatusClient.parseXAIStatusDate("May 22, 2026, 12:00 PM UTC"))
        let snapshot = ServiceStatusClient.parseXAIStatusPages(
            tool: .grok,
            overviewHTML: """
            <a>Grok (Web) unavailable</a>
            <a>API (us-east-1.api.x.ai) available</a>
            """,
            componentPages: [(
                id: "api-us-east-1",
                name: "API (us-east-1.api.x.ai)",
                url: URL(string: "https://status.x.ai/api-us-east-1")!,
                html: "<h3>Service fully operational</h3>"
            )],
            dayCount: 30,
            now: now
        )

        XCTAssertEqual(snapshot.components.count, 2)
        XCTAssertEqual(snapshot.indicator, .critical)
        XCTAssertEqual(
            snapshot.components.first { $0.name == "Grok (Web)" }?.status,
            .majorOutage
        )
        XCTAssertEqual(
            snapshot.components.first { $0.name == "API (us-east-1.api.x.ai)" }?.status,
            .operational
        )
    }
}
