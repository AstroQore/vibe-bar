import XCTest
@testable import VibeBarCore

final class QuotaPaceForecastTests: XCTestCase {
    private let week = 7 * 86_400

    private func bucket(used: Double, resetAt: Date) -> QuotaBucket {
        QuotaBucket(
            id: "weekly",
            title: "Weekly",
            shortLabel: "Weekly",
            usedPercent: used,
            resetAt: resetAt,
            rawWindowSeconds: week
        )
    }

    private func point(_ used: Double, at date: Date, resetAt: Date) -> FillTimelinePoint {
        FillTimelinePoint(
            accountId: "account",
            tool: .codex,
            bucketId: "weekly",
            slotStart: UsageFillTimelineStore.hourSlotStart(for: date),
            usedPercent: used,
            sampledAt: date,
            resetAt: resetAt,
            rawWindowSeconds: week
        )
    }

    func testColdStartFallsBackToBehavioralLinearAndLabelsLearning() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(TimeInterval(week) / 2)
        let forecast = try XCTUnwrap(QuotaPaceForecast.compute(
            bucket: bucket(used: 30, resetAt: reset),
            observations: [],
            cycles: [],
            now: now
        ))
        XCTAssertEqual(forecast.confidence, .learning)
        XCTAssertEqual(forecast.verdict, .learning)
        XCTAssertEqual(forecast.projectedUsedPercent, 60, accuracy: 0.5)
        XCTAssertGreaterThan(forecast.targetRemainingPercent, 10)
        XCTAssertEqual(forecast.diagnostics.behavioralProjectionUsedPercent, 60, accuracy: 0.5)
        XCTAssertFalse(forecast.diagnostics.hasActivityTrendBaseline)
        XCTAssertEqual(forecast.diagnostics.recentSampleCount, 0)
    }

    func testRecentAccelerationPredictsRunOutBeforeReset() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(2 * 86_400)
        let observations = (0..<10).map { index in
            point(
                44 + Double(index) * 4,
                at: now.addingTimeInterval(TimeInterval(index - 9) * 3_600),
                resetAt: reset
            )
        }
        let forecast = try XCTUnwrap(QuotaPaceForecast.compute(
            bucket: bucket(used: 80, resetAt: reset),
            observations: observations,
            cycles: [],
            now: now
        ))
        XCTAssertEqual(forecast.verdict, .atRisk)
        XCTAssertGreaterThanOrEqual(forecast.projectedUsedPercent, 100)
        XCTAssertNotNil(forecast.diagnostics.recentProjectionUsedPercent)
        XCTAssertGreaterThan(forecast.diagnostics.recentSampleCount, 0)
        XCTAssertNotNil(forecast.runOutAt)
        XCTAssertLessThan(try XCTUnwrap(forecast.runOutAt), reset)
    }

    func testHistoricalLowUtilizationSurfacesPotentialWaste() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(TimeInterval(week) / 2)
        let start = reset.addingTimeInterval(-TimeInterval(week))
        let currentPoints = (0..<12).map { index in
            point(
                Double(index) * 10 / 11,
                at: start.addingTimeInterval(TimeInterval(index) * (TimeInterval(week) / 24)),
                resetAt: reset
            )
        }
        let cycles = (0..<6).map { index in
            let end = start.addingTimeInterval(-TimeInterval(index + 1) * TimeInterval(week))
            return SubscriptionWindowSample(
                accountId: "account",
                tool: .codex,
                bucketId: "weekly",
                windowEnd: end,
                windowStart: end.addingTimeInterval(-TimeInterval(week)),
                rawWindowSeconds: week,
                peakUsedPercent: 28 + Double(index % 3),
                lastUsedPercent: 28 + Double(index % 3),
                observationCount: 12,
                firstSeenAt: end.addingTimeInterval(-TimeInterval(week)),
                lastSeenAt: end.addingTimeInterval(-60),
                completedAt: end,
                completionReason: .scheduledReset
            )
        }
        let forecast = try XCTUnwrap(QuotaPaceForecast.compute(
            bucket: bucket(used: 10, resetAt: reset),
            observations: currentPoints,
            cycles: cycles,
            now: now
        ))
        XCTAssertEqual(forecast.verdict, .surplus)
        XCTAssertEqual(forecast.verdictLabel, "Surplus")
        XCTAssertTrue(forecast.resetSummary.hasPrefix("Likely surplus"))
        XCTAssertTrue(forecast.guidanceSummary.contains("likely unused"))
        XCTAssertGreaterThan(forecast.potentialUnusedPercent, 30)
        XCTAssertGreaterThan(forecast.projectedRemainingPercent, forecast.targetRemainingPercent)
        XCTAssertGreaterThanOrEqual(
            forecast.projectedRemainingRange.lowerBound - forecast.targetRemainingPercent,
            10
        )
    }

    func testForecastKeepsEveryBucketIndependent() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(2 * 86_400)
        let first = try XCTUnwrap(QuotaPaceForecast.compute(
            bucket: bucket(used: 20, resetAt: reset),
            observations: [point(20, at: now, resetAt: reset)],
            cycles: [],
            now: now
        ))
        var secondBucket = bucket(used: 70, resetAt: reset)
        secondBucket.id = "weekly_spark"
        let second = try XCTUnwrap(QuotaPaceForecast.compute(
            bucket: secondBucket,
            observations: [],
            cycles: [],
            now: now
        ))
        XCTAssertNotEqual(first.projectedUsedPercent, second.projectedUsedPercent)
    }

    func testPlanUsesWeekdayAndHourActivityShapeInsteadOfWallClockOnly() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 20, hour: 0
        ))! // Monday
        let now = start.addingTimeInterval(2 * 86_400)
        let reset = start.addingTimeInterval(TimeInterval(week))
        var cells = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        cells[1] = Array(repeating: 100, count: 24) // Monday
        cells[2] = Array(repeating: 100, count: 24) // Tuesday
        let heatmap = UsageHeatmap(
            tool: .codex,
            cells: cells,
            totalTokens: cells.flatMap { $0 }.reduce(0, +)
        )
        let uniform = try XCTUnwrap(QuotaPaceForecast.compute(
            bucket: bucket(used: 20, resetAt: reset),
            observations: [],
            cycles: [],
            now: now,
            calendar: calendar
        ))
        let habitual = try XCTUnwrap(QuotaPaceForecast.compute(
            bucket: bucket(used: 20, resetAt: reset),
            observations: [],
            cycles: [],
            activityHeatmap: heatmap,
            now: now,
            calendar: calendar
        ))
        XCTAssertGreaterThan(habitual.plannedUsedPercent, uniform.plannedUsedPercent + 20)
        XCTAssertEqual(habitual.diagnostics.activityCoveragePercent, 100)
        XCTAssertGreaterThan(habitual.diagnostics.behavioralProgressPercent, 70)
    }
}
