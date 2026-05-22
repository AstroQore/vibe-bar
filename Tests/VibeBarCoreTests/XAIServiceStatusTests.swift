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
        XCTAssertEqual(snapshot.description, "All services operational")
        XCTAssertEqual(snapshot.components.count, 1)
        XCTAssertEqual(snapshot.components[0].status, .operational)
        XCTAssertEqual(snapshot.recentIncidents.first?.name, "Requests Using grok-imagine Models have Reduced Success Rate")
        XCTAssertEqual(snapshot.recentIncidents.first?.impact, .minor)
    }
}
