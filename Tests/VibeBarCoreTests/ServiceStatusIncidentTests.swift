import XCTest
@testable import VibeBarCore

/// Anthropic's status page posts incidents without flipping any component to
/// degraded, so the scraped component uptime stays a 100% green wall. These
/// tests cover the incident-aware overlay that keeps the card honest.
final class ServiceStatusIncidentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func incident(
        impact: IncidentImpact = .minor,
        createdOffset: TimeInterval,
        resolvedOffset: TimeInterval?
    ) -> IncidentSummary {
        IncidentSummary(
            id: "i-\(Int(createdOffset))",
            name: "Elevated errors on Opus",
            impact: impact,
            createdAt: now.addingTimeInterval(createdOffset),
            resolvedAt: resolvedOffset.map { now.addingTimeInterval($0) },
            url: nil
        )
    }

    private func snapshot(
        indicator: StatusIndicator,
        incidents: [IncidentSummary],
        adjustedUptime: Double? = nil
    ) -> ServiceStatusSnapshot {
        ServiceStatusSnapshot(
            tool: .claude,
            indicator: indicator,
            description: "All Systems Operational",
            updatedAt: now,
            groups: [],
            components: [
                ServiceComponentSummary(id: "c1", name: "claude.ai", status: .operational, uptimePercent: 100),
                ServiceComponentSummary(id: "c2", name: "Claude Code", status: .operational, uptimePercent: 100)
            ],
            recentIncidents: incidents,
            incidentDays: nil,
            incidentAdjustedUptimePercent: adjustedUptime
        )
    }

    func testUnresolvedIncidentUpgradesIndicatorAndDescription() {
        let snap = snapshot(
            indicator: .none,
            incidents: [incident(impact: .minor, createdOffset: -1_800, resolvedOffset: nil)]
        )
        XCTAssertEqual(snap.effectiveIndicator, .minor)
        XCTAssertEqual(snap.effectiveDescription, "Active incident")
    }

    func testResolvedIncidentKeepsPageIndicator() {
        let snap = snapshot(
            indicator: .none,
            incidents: [incident(impact: .major, createdOffset: -7_200, resolvedOffset: -3_600)]
        )
        XCTAssertEqual(snap.effectiveIndicator, .none)
        XCTAssertEqual(snap.effectiveDescription, "All Systems Operational")
    }

    func testPageIndicatorOutrankingIncidentWins() {
        let snap = snapshot(
            indicator: .critical,
            incidents: [incident(impact: .minor, createdOffset: -600, resolvedOffset: nil)]
        )
        XCTAssertEqual(snap.effectiveIndicator, .critical)
        XCTAssertEqual(snap.effectiveDescription, "All Systems Operational")
    }

    func testDisplayUptimePrefersAdjustedWhenLower() {
        let dented = snapshot(indicator: .none, incidents: [], adjustedUptime: 99.83)
        XCTAssertEqual(dented.displayUptimePercent, 99.83, accuracy: 0.001)
        let clean = snapshot(indicator: .none, incidents: [], adjustedUptime: nil)
        XCTAssertEqual(clean.displayUptimePercent, 100, accuracy: 0.001)
    }

    func testIncidentAdjustedUptimeMergesOverlaps() {
        // Two incidents: 60min and an overlapping 30min inside it, plus a
        // separate 30min — union is 90min of downtime over a 90-day window.
        let intervals: [(start: Date, end: Date)] = [
            (now.addingTimeInterval(-7_200), now.addingTimeInterval(-3_600)),   // 60 min
            (now.addingTimeInterval(-5_400), now.addingTimeInterval(-4_500)),   // inside previous
            (now.addingTimeInterval(-90_000), now.addingTimeInterval(-88_200))  // separate 30 min
        ]
        let uptime = ServiceStatusClient.incidentAdjustedUptime(
            officialPercent: 100,
            intervals: intervals,
            dayCount: 90,
            now: now
        )
        let expected = (1.0 - (5_400.0 / (90.0 * 86_400.0))) * 100
        XCTAssertEqual(uptime ?? -1, expected, accuracy: 0.0001)
    }

    func testIncidentAdjustedUptimeClampsToWindowAndTakesOfficialMin() {
        // Interval mostly before the window — only the in-window slice counts.
        let intervals: [(start: Date, end: Date)] = [
            (now.addingTimeInterval(-91 * 86_400), now.addingTimeInterval(-90 * 86_400 + 3_600))
        ]
        let uptime = ServiceStatusClient.incidentAdjustedUptime(
            officialPercent: 99.0,
            intervals: intervals,
            dayCount: 90,
            now: now
        )
        XCTAssertEqual(uptime ?? -1, 99.0, accuracy: 0.0001)

        XCTAssertNil(ServiceStatusClient.incidentAdjustedUptime(
            officialPercent: 100,
            intervals: [],
            dayCount: 90,
            now: now
        ))
    }

    /// Cached snapshots from before the incident-overlay schema must still
    /// decode (the new stored fields are optional).
    func testSnapshotDecodesLegacyCacheWithoutNewFields() throws {
        let legacy = snapshot(indicator: .none, incidents: [])
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(legacy)
        ) as! [String: Any]
        json.removeValue(forKey: "incidentDays")
        json.removeValue(forKey: "incidentAdjustedUptimePercent")
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(ServiceStatusSnapshot.self, from: data)
        XCTAssertNil(decoded.incidentDays)
        XCTAssertNil(decoded.incidentAdjustedUptimePercent)
        XCTAssertEqual(decoded.tool, .claude)
    }
}
