import XCTest
@testable import VibeBarCore

/// `QuotaPaceForecast.ActivityProfile.weight` used to walk a window hour by
/// hour, asking `Calendar` for the next hour boundary and for the weekday/hour
/// of every step — two round trips per hour, per query, and the forecast issues
/// one query per stored observation per completed cycle. It now integrates a
/// precomputed hour table instead.
///
/// These tests pin the new implementation against the retired walk
/// (`referenceWeight` below, a faithful copy of it) so the swap stays a
/// performance change rather than a behaviour change.
final class QuotaActivityProfileTests: XCTestCase {
    /// The retired hour-by-hour walk, kept here as the equivalence oracle.
    private func referenceWeight(
        from start: Date,
        to end: Date,
        heatmap: UsageHeatmap?,
        calendar: Calendar
    ) -> Double {
        guard end > start else { return 0 }
        let maximumCell = Double(heatmap?.cells.flatMap { $0 }.max() ?? 0)
        func hourWeight(at date: Date) -> Double {
            guard let heatmap, heatmap.totalTokens > 0, maximumCell > 0 else { return 1 }
            let weekday = max(0, min(6, calendar.component(.weekday, from: date) - 1))
            let hour = max(0, min(23, calendar.component(.hour, from: date)))
            guard heatmap.cells.indices.contains(weekday),
                  heatmap.cells[weekday].indices.contains(hour) else { return 1 }
            let normalized = sqrt(Double(heatmap.cells[weekday][hour]) / maximumCell)
            return 0.15 + normalized * 0.85
        }

        var cursor = start
        var total = 0.0
        while cursor < end {
            let nextHour = calendar.date(
                byAdding: .hour,
                value: 1,
                to: calendar.dateInterval(of: .hour, for: cursor)?.start ?? cursor
            ) ?? cursor.addingTimeInterval(3_600)
            let next = min(end, max(cursor.addingTimeInterval(60), nextHour))
            total += hourWeight(at: cursor) * next.timeIntervalSince(cursor) / 3_600
            cursor = next
        }
        return total
    }

    /// A lumpy but realistic week: heavy weekday afternoons, quiet nights, one
    /// completely empty day so the 0.15 floor is exercised.
    private func shapedHeatmap() -> UsageHeatmap {
        var cells = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        for weekday in 1...5 {
            for hour in 0..<24 {
                cells[weekday][hour] = hour >= 9 && hour <= 18 ? 400 + hour * 37 : hour % 5
            }
        }
        cells[6] = (0..<24).map { $0 * 11 }
        return UsageHeatmap(
            tool: .codex,
            cells: cells,
            totalTokens: cells.flatMap { $0 }.reduce(0, +)
        )
    }

    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    /// The retired walk attributed up to one minute of a window to the wrong
    /// side of an hour boundary (its step had a 60s floor), so equivalence is
    /// asserted to within that much weight — one minute of the widest possible
    /// weight gap, 1 minus the 0.15 floor.
    private let tolerance = 0.02

    private func assertMatchesReference(
        from start: Date,
        to end: Date,
        heatmap: UsageHeatmap?,
        calendar: Calendar,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let profile = QuotaPaceForecast.ActivityProfile(heatmap: heatmap, calendar: calendar)
        XCTAssertEqual(
            profile.weight(from: start, to: end),
            referenceWeight(from: start, to: end, heatmap: heatmap, calendar: calendar),
            accuracy: tolerance,
            message,
            file: file,
            line: line
        )
    }

    func testUniformProfileIsExactlyElapsedHours() {
        let calendar = calendar("America/Los_Angeles")
        let start = calendar.date(from: DateComponents(year: 2026, month: 7, day: 30, hour: 3, minute: 17))!
        let profile = QuotaPaceForecast.ActivityProfile(heatmap: nil, calendar: calendar)
        XCTAssertEqual(profile.weight(from: start, to: start.addingTimeInterval(9_000)), 2.5, accuracy: 1e-9)
        XCTAssertEqual(profile.weight(from: start, to: start), 0)
        XCTAssertEqual(profile.weight(from: start, to: start.addingTimeInterval(-3_600)), 0)
        // An all-zero heatmap carries no shape, so it must stay on the uniform
        // path rather than weighting every hour at the 0.15 floor.
        let empty = UsageHeatmap(
            tool: .codex,
            cells: Array(repeating: Array(repeating: 0, count: 24), count: 7),
            totalTokens: 0
        )
        let emptyProfile = QuotaPaceForecast.ActivityProfile(heatmap: empty, calendar: calendar)
        XCTAssertEqual(emptyProfile.weight(from: start, to: start.addingTimeInterval(7_200)), 2, accuracy: 1e-9)
    }

    func testMatchesRetiredWalkOverAlignedAndPartialWindows() {
        let calendar = calendar("America/Los_Angeles")
        let heatmap = shapedHeatmap()
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 7, day: 27, hour: 0))!

        assertMatchesReference(
            from: midnight,
            to: midnight.addingTimeInterval(7 * 86_400),
            heatmap: heatmap,
            calendar: calendar,
            "a whole hour-aligned week"
        )
        assertMatchesReference(
            from: midnight.addingTimeInterval(13 * 3_600 + 1_237),
            to: midnight.addingTimeInterval(5 * 86_400 + 47 * 60 + 12),
            heatmap: heatmap,
            calendar: calendar,
            "partial hours at both ends"
        )
        assertMatchesReference(
            from: midnight.addingTimeInterval(3_600 + 900),
            to: midnight.addingTimeInterval(3_600 + 2_700),
            heatmap: heatmap,
            calendar: calendar,
            "entirely inside one hour"
        )
        assertMatchesReference(
            from: midnight.addingTimeInterval(9 * 3_600 - 30),
            to: midnight.addingTimeInterval(9 * 3_600 + 30),
            heatmap: heatmap,
            calendar: calendar,
            "one minute straddling the boundary into the busiest hour"
        )
        assertMatchesReference(
            from: midnight.addingTimeInterval(-21 * 86_400),
            to: midnight.addingTimeInterval(30 * 86_400),
            heatmap: heatmap,
            calendar: calendar,
            "seven weeks, the span a monthly bucket with history asks for"
        )
    }

    func testMatchesRetiredWalkAcrossDaylightSavingTransitions() {
        let calendar = calendar("America/Los_Angeles")
        let heatmap = shapedHeatmap()
        // Spring forward: 2026-03-08 02:00 local does not exist.
        let beforeSpring = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 20))!
        assertMatchesReference(
            from: beforeSpring,
            to: beforeSpring.addingTimeInterval(2 * 86_400),
            heatmap: heatmap,
            calendar: calendar,
            "across spring forward"
        )
        // Fall back: 2026-11-01 01:00 local happens twice.
        let beforeFall = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 20))!
        assertMatchesReference(
            from: beforeFall,
            to: beforeFall.addingTimeInterval(2 * 86_400),
            heatmap: heatmap,
            calendar: calendar,
            "across fall back"
        )
        // And a window that contains both, so the table has to follow two
        // offset changes while it is being built.
        assertMatchesReference(
            from: beforeSpring,
            to: beforeFall.addingTimeInterval(2 * 86_400),
            heatmap: heatmap,
            calendar: calendar,
            "a span containing both transitions"
        )
    }

    func testMatchesRetiredWalkInHalfHourOffsetZones() {
        // India is UTC+5:30 with no DST: local hour boundaries sit half an hour
        // off the epoch grid, which is exactly what the table's phase is for.
        let calendar = calendar("Asia/Kolkata")
        let heatmap = shapedHeatmap()
        let start = calendar.date(from: DateComponents(year: 2026, month: 7, day: 27, hour: 6, minute: 41))!
        assertMatchesReference(
            from: start,
            to: start.addingTimeInterval(4 * 86_400 + 1_111),
            heatmap: heatmap,
            calendar: calendar,
            "half-hour zone offset"
        )
    }

    func testWeightIsAdditiveAcrossSplitPoints() {
        let calendar = calendar("Europe/Amsterdam")
        let heatmap = shapedHeatmap()
        let profile = QuotaPaceForecast.ActivityProfile(heatmap: heatmap, calendar: calendar)
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 21, minute: 5))!
        let end = start.addingTimeInterval(3 * 86_400 + 4_321)
        let splits: [TimeInterval] = [60, 3_600, 42_000, 90_000, 200_000]
        let whole = profile.weight(from: start, to: end)
        for split in splits {
            let middle = start.addingTimeInterval(split)
            XCTAssertEqual(
                profile.weight(from: start, to: middle) + profile.weight(from: middle, to: end),
                whole,
                accuracy: 1e-9,
                "splitting at \(split)s must not change the integral"
            )
        }
    }

    /// The forecast asks for the same profile over widening ranges as it walks
    /// back through completed cycles, so growing the table must not move the
    /// grid underneath the values already handed out.
    func testGrowingTheTableKeepsEarlierAnswersStable() {
        let calendar = calendar("America/Los_Angeles")
        let heatmap = shapedHeatmap()
        let profile = QuotaPaceForecast.ActivityProfile(heatmap: heatmap, calendar: calendar)
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 7, day: 30, hour: 11, minute: 23))!
        let near = profile.weight(from: anchor, to: anchor.addingTimeInterval(6 * 3_600))
        // Force several rebuilds, forwards and backwards.
        _ = profile.weight(from: anchor.addingTimeInterval(-40 * 86_400), to: anchor)
        _ = profile.weight(from: anchor, to: anchor.addingTimeInterval(40 * 86_400))
        _ = profile.weight(from: anchor.addingTimeInterval(-200 * 86_400), to: anchor)
        XCTAssertEqual(
            profile.weight(from: anchor, to: anchor.addingTimeInterval(6 * 3_600)),
            near,
            accuracy: 1e-9
        )
    }

    /// A stored date far outside the retention horizon must not turn into a
    /// hundred-million-entry table; the answer is chunked instead.
    func testAbsurdlyWideSpanStaysBoundedAndMonotonic() {
        let calendar = calendar("America/Los_Angeles")
        let profile = QuotaPaceForecast.ActivityProfile(heatmap: shapedHeatmap(), calendar: calendar)
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 7, day: 30, hour: 11))!
        let wide = profile.weight(from: anchor.addingTimeInterval(-4_000 * 86_400), to: anchor)
        let narrow = profile.weight(from: anchor.addingTimeInterval(-40 * 86_400), to: anchor)
        XCTAssertGreaterThan(wide, narrow)
        // Every hour weighs between the 0.15 floor and 1, so the integral is
        // bounded by the elapsed hours either way.
        XCTAssertLessThanOrEqual(wide, 4_000 * 24)
        XCTAssertGreaterThanOrEqual(wide, 4_000 * 24 * 0.15)
    }
}
