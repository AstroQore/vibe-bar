import XCTest
@testable import VibeBarCore

/// Meta AI's status row reads `GET https://api.meta.ai/v1/status`, the
/// unauthenticated status endpoint of the Model API Muse Code calls.
final class MetaModelAPIStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_600_000)

    private func parse(_ json: String) throws -> ServiceStatusSnapshot {
        try ServiceStatusClient.parseMetaModelAPIStatus(data: Data(json.utf8), now: now)
    }

    /// The live answer on a quiet day: empty strings where a date and a
    /// message would be, and no per-model rows.
    func testQuietDayIsOperationalDespiteEmptyStrings() throws {
        let snapshot = try parse("""
        {"is_alive":true,"service_status":"operational","service_message":"","updated_at":"","model_statuses":[]}
        """)
        XCTAssertEqual(snapshot.tool, .muse)
        XCTAssertEqual(snapshot.indicator, .none)
        XCTAssertEqual(snapshot.description, "")
        XCTAssertEqual(snapshot.updatedAt, now)
        XCTAssertEqual(snapshot.components.map(\.name), ["Model API"])
        XCTAssertEqual(snapshot.components.first?.status, .operational)
        XCTAssertNil(snapshot.components.first?.uptimePercent, "the feed has no durations to derive uptime from")
        XCTAssertEqual(snapshot.components.first?.recentDays, [])
        XCTAssertEqual(snapshot.recentIncidents, [])
    }

    func testDegradedModelRaisesTheIndicatorAndIncidentsAreNewestFirst() throws {
        let snapshot = try parse("""
        {
          "is_alive": true,
          "service_status": "operational",
          "service_message": "Elevated latency on Muse Spark 1.3",
          "updated_at": "2026-09-16T10:00:00Z",
          "model_statuses": [
            {"id": "muse-spark-1.3", "status": "degraded", "message": "Slow"},
            {"id": "muse-spark-1.2", "status": "operational"}
          ],
          "incident_history": [
            {"date": "2026-09-01", "title": "Model API outage", "status": "resolved", "message": "Fixed"},
            {"date": "2026-09-15", "title": "Latency", "status": "investigating"},
            {"date": "not a date", "title": "Dropped"}
          ]
        }
        """)
        XCTAssertEqual(snapshot.indicator, .minor)
        XCTAssertEqual(snapshot.description, "Elevated latency on Muse Spark 1.3")
        XCTAssertEqual(snapshot.updatedAt, ServiceStatusClient.flexibleDate(from: "2026-09-16T10:00:00Z"))
        XCTAssertEqual(snapshot.components.map(\.name), ["Model API", "muse-spark-1.3", "muse-spark-1.2"])
        XCTAssertEqual(snapshot.components[1].status, .degradedPerformance)

        XCTAssertEqual(snapshot.recentIncidents.map(\.name), ["Latency", "Model API outage"])
        XCTAssertNil(snapshot.recentIncidents[0].resolvedAt, "an investigating incident is still open")
        XCTAssertNotNil(snapshot.recentIncidents[1].resolvedAt)
        XCTAssertEqual(snapshot.recentIncidents[1].impact, .major)
        XCTAssertEqual(snapshot.recentIncidents[1].url?.absoluteString, "https://dev.meta.ai/status")
    }

    func testNotAliveIsAMajorOutageWhateverTheStatusSays() throws {
        let snapshot = try parse(#"{"is_alive":false,"service_status":"operational"}"#)
        XCTAssertEqual(snapshot.indicator, .critical)
        XCTAssertEqual(snapshot.components.first?.status, .majorOutage)
    }

    func testOutageAndUnknownSpellings() throws {
        XCTAssertEqual(try parse(#"{"service_status":"outage"}"#).indicator, .critical)
        XCTAssertEqual(try parse(#"{"service_status":"partial_outage"}"#).indicator, .major)
        XCTAssertEqual(try parse(#"{"service_status":"maintenance"}"#).indicator, .maintenance)
        XCTAssertEqual(
            try parse(#"{"service_status":"wobbly"}"#).indicator, .minor,
            "a spelling the docs never listed must not read as healthy"
        )
    }

    func testNonJSONIsABadResponse() {
        XCTAssertThrowsError(try parse("<html>Service Unavailable</html>"))
    }

    /// Every field is optional, so an error body decodes; with no health
    /// signal in it, it must not become a green snapshot.
    func testAPayloadWithoutAnyHealthSignalIsABadResponse() {
        XCTAssertThrowsError(try parse("{}"))
        XCTAssertThrowsError(try parse(#"{"error":"unavailable","incident_history":[]}"#))
        XCTAssertNoThrow(try parse(#"{"model_statuses":[{"id":"muse-spark-1.3","status":"operational"}]}"#))
    }
}
