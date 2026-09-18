import XCTest
@testable import VibeBarCore

/// Mistral AI's status page moved from Checkly to Rootly in 2026-09, and the
/// old Checkly page is still online with months-stale contents — it was still
/// reporting a September "Free Tier Temporarily Disabled" outage while
/// `status.mistral.ai` said all systems operational.
///
/// Rootly answers `/api/v1/status.json` with the page's own state and keeps
/// the services, their bars and their percentages in the page HTML. The
/// fixtures below are trimmed from the live page of 2026-09-18.
final class MistralStatusTests: XCTestCase {
    private let now = ServiceStatusClient.flexibleDate(from: "2026-09-18T12:00:00Z")!

    private let statusJSON = Data(#"""
    {"page":{"id":"ae27f3c4","name":"Mistral AI Status","time_zone":"Etc/UTC","updated_at":"2026-09-10T09:51:19-07:00"},
     "status":{"indicator":"none","description":"All Systems Operational"},
     "incidents":[]}
    """#.utf8)

    /// Two service cards. The chart draws each day twice — a plain rect and
    /// the hover target that carries the day's index — and only the second
    /// should count.
    private func html(secondServiceRedDays: Int = 2) -> String {
        func chart(id: String, percent: String, redDays: Int, total: Int = 5) -> String {
            let rects = (0..<total).map { index -> String in
                let fill = index < redDays ? "#C73C40" : "#3CB878"
                // As the page draws it: the coloured day, then a transparent
                // hover target whose own `data-action` contains a `#`.
                return """
                <rect x="0" width="4" height="16" rx="2" style="fill: \(fill);"></rect>
                <rect data-action="mouseenter->status-pages--v2--uptime-chart-component#show" \
                data-status-pages--v2--uptime-chart-component-idx-param="\(index)" \
                data-status-pages--v2--uptime-chart-component-target="trigger" x="0" width="6"></rect>
                """
            }.joined()
            return """
            <turbo-frame id="uptime-chart-\(id)">
              <div class="flex" data-controller="status-pages--v2--uptime-chart-component" \
              data-status-pages--v2--uptime-chart-component-since-value="2026-06-19 00:00:00 UTC">
                <svg viewBox="0 0 588 16">\(rects)</svg>
                <div class="text-gray-700"><span>90 days ago</span><span>\(percent)%</span><span>Today</span></div>
              </div>
            </turbo-frame>
            """
        }
        return """
        <details><summary><div><span class="rounded"><svg></svg></span>
        <h2 class="text-primary-900">Agents API</h2></div>
        <span class="text-green-400">Operational</span></summary>
        <div class="px-5">\(chart(id: "304d5895", percent: "99.93", redDays: 0))</div></details>
        <details><summary><div><h2 class="text-primary-900">Vibe Code Web</h2></div>
        <span class="text-orange-400">Degraded</span></summary>
        <div class="px-5">\(chart(id: "719fdf28", percent: "99.02", redDays: secondServiceRedDays))</div></details>
        """
    }

    private func status(_ data: Data) throws -> RootlyStatusPageParser.StatusDTO {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            return ServiceStatusClient.flexibleDate(from: raw) ?? Date()
        }
        return try decoder.decode(RootlyStatusPageParser.StatusDTO.self, from: data)
    }

    func testServicesBarsAndPageStateComeFromTheirOwnSources() throws {
        let snapshot = try RootlyStatusPageParser.snapshot(
            tool: .mistralVibe,
            html: html(),
            status: try status(statusJSON),
            dayCount: 90,
            now: now
        )
        XCTAssertEqual(snapshot.tool, .mistralVibe)
        // The page's own words and indicator win over anything derived.
        XCTAssertEqual(snapshot.indicator, .none)
        XCTAssertEqual(snapshot.description, "All Systems Operational")
        XCTAssertEqual(snapshot.components.map(\.name), ["Agents API", "Vibe Code Web"])
        XCTAssertEqual(snapshot.components.map(\.status), [.operational, .degradedPerformance])
        XCTAssertEqual(snapshot.components[0].uptimePercent, 99.93)
        XCTAssertEqual(snapshot.components[1].uptimePercent, 99.02)

        // One entry per drawn day, oldest first, ending today.
        let vibe = snapshot.components[1]
        XCTAssertEqual(vibe.recentDays.count, 5)
        XCTAssertEqual(vibe.recentDays.compactMap(\.worstImpact), [.major, .major])
        XCTAssertEqual(vibe.recentDays.prefix(2).compactMap(\.worstImpact).count, 2, "the red days are the oldest two")
        XCTAssertTrue(snapshot.components[0].recentDays.allSatisfy { $0.worstImpact == nil })
        XCTAssertEqual(snapshot.recentIncidents, [])
    }

    /// The card asks for the window it draws; a 30-day card keeps the newest
    /// 30 of whatever the page published.
    func testAShorterWindowKeepsTheNewestDays() throws {
        let snapshot = try RootlyStatusPageParser.snapshot(
            tool: .mistralVibe, html: html(secondServiceRedDays: 5), status: nil, dayCount: 3, now: now
        )
        XCTAssertEqual(snapshot.components[1].recentDays.count, 3)
        XCTAssertEqual(snapshot.components[1].recentDays.compactMap(\.worstImpact).count, 3)
    }

    /// Gray days predate the service; they are unrecorded, not degraded.
    /// Amber is a partial day and red an outage.
    func testGrayDaysAreUnrecordedAndAmberIsPartial() throws {
        let html = """
        <details><summary><h2>New API</h2><span>Operational</span></summary>
        <turbo-frame id="uptime-chart-new">
          <svg><rect style="fill: #E5E7EB;"></rect><rect style="fill: #9CA3AF;"></rect>\
          <rect style="fill: #F5A623;"></rect><rect style="fill: #C73C40;"></rect>\
          <rect style="fill: #3CB878;"></rect></svg>
          <div><span>90 days ago</span><span>99.10%</span><span>Today</span></div>
        </turbo-frame></details>
        """
        let snapshot = try RootlyStatusPageParser.snapshot(
            tool: .mistralVibe, html: html, status: nil, dayCount: 90, now: now
        )
        XCTAssertEqual(snapshot.components.first?.recentDays.map(\.worstImpact), [nil, nil, .minor, .major, nil])
    }

    /// Without the page's own indicator, the worst service stands in.
    func testWithoutStatusJSONTheServicesDecideTheIndicator() throws {
        let snapshot = try RootlyStatusPageParser.snapshot(
            tool: .mistralVibe, html: html(), status: nil, dayCount: 90, now: now
        )
        XCTAssertEqual(snapshot.indicator, .minor)
        XCTAssertEqual(snapshot.description, "")
    }

    /// A blocked page still leaves the state the JSON reported.
    func testJSONAloneStillReportsTheState() throws {
        let snapshot = try RootlyStatusPageParser.snapshot(
            tool: .mistralVibe, html: "", status: try status(statusJSON), dayCount: 90, now: now
        )
        XCTAssertEqual(snapshot.indicator, .none)
        XCTAssertEqual(snapshot.description, "All Systems Operational")
        XCTAssertTrue(snapshot.components.isEmpty)
    }

    func testNeitherSourceIsABadResponse() throws {
        XCTAssertThrowsError(try RootlyStatusPageParser.snapshot(
            tool: .mistralVibe, html: "<html>nothing here</html>", status: nil, dayCount: 90, now: now
        ))
        // An error body decodes, but says nothing about the page's state.
        for body in [#"{}"#, #"{"error":"unavailable"}"#, #"{"status":{"description":"Unknown"}}"#] {
            XCTAssertThrowsError(try RootlyStatusPageParser.snapshot(
                tool: .mistralVibe, html: "", status: try status(Data(body.utf8)), dayCount: 90, now: now
            ), body)
        }
    }

    func testAnOpenIncidentBecomesTheCardsIncidentRow() throws {
        let json = Data(#"""
        {"page":{"name":"Mistral AI Status","updated_at":"2026-09-18T09:00:00Z"},
         "status":{"indicator":"major","description":"Partial Outage"},
         "incidents":[{"id":"inc-1","name":"Completion API degraded","impact":"major","status":"identified",
           "created_at":"2026-09-18T08:00:00Z","resolved_at":null,
           "shortlink":"https://status.mistral.ai/incidents/inc-1"}]}
        """#.utf8)
        let snapshot = try RootlyStatusPageParser.snapshot(
            tool: .mistralVibe, html: html(), status: try status(json), dayCount: 90, now: now
        )
        XCTAssertEqual(snapshot.indicator, .major)
        let incident = try XCTUnwrap(snapshot.recentIncidents.first)
        XCTAssertEqual(incident.name, "Completion API degraded")
        XCTAssertNil(incident.resolvedAt)
        XCTAssertEqual(incident.impact, .major)
        XCTAssertEqual(incident.url?.absoluteString, "https://status.mistral.ai/incidents/inc-1")
    }

    func testStatusURLsForTheNewCompanies() {
        XCTAssertTrue(ToolType.devin.supportsStatusPage)
        XCTAssertEqual(ToolType.devin.statusSummaryAPI.absoluteString, "https://www.devinstatus.com/api/v2/summary.json")
        XCTAssertTrue(ToolType.mistralVibe.supportsStatusPage)
        XCTAssertEqual(ToolType.mistralVibe.statusPageURL.absoluteString, "https://status.mistral.ai/")
        XCTAssertEqual(
            ServiceStatusClient.rootlyStatusURL(for: .mistralVibe).absoluteString,
            "https://status.mistral.ai/api/v1/status.json"
        )
    }
}
