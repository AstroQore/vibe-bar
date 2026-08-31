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

    func testForecastSurvivesTheBoundaryRefreshGrace() throws {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(QuotaPaceForecast.compute(
            bucket: bucket(used: 30, resetAt: reset),
            observations: [],
            cycles: [],
            now: reset.addingTimeInterval(120)
        ))
        let forecast = QuotaPaceForecast.compute(
            bucket: bucket(used: 30, resetAt: reset),
            observations: [],
            cycles: [],
            now: reset.addingTimeInterval(120),
            allowsPostResetGrace: true
        )
        XCTAssertNotNil(forecast)
    }

    func testForecastStopsAfterTheBoundaryRefreshGrace() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let forecast = QuotaPaceForecast.compute(
            bucket: bucket(used: 30, resetAt: reset),
            observations: [],
            cycles: [],
            now: reset.addingTimeInterval(181)
        )
        XCTAssertNil(forecast)
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

    /// A cycle whose stored `windowStart` collapsed still contributes a
    /// measured figure.
    ///
    /// `SubscriptionHistoryStore` moves `windowStart` forward on every
    /// observation of a rolling window and stops when the cycle closes, so a
    /// finished cycle can claim a span of one polling interval. The historical
    /// projection filters observations by that span and derives their progress
    /// from it, so a collapsed cycle used to contribute nothing measured —
    /// either ~0 or the whole peak, depending on which end it matched.
    func testACollapsedStoredSpanStillYieldsAMeasuredHistory() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(TimeInterval(week) / 2)
        let start = reset.addingTimeInterval(-TimeInterval(week))
        let currentPoints = (0..<12).map { index in
            point(
                Double(index) * 20 / 11,
                at: start.addingTimeInterval(TimeInterval(index) * (TimeInterval(week) / 24)),
                resetAt: reset
            )
        }

        // One past cycle, fully observed, that climbed from 0 to 80%.
        let end = start.addingTimeInterval(-TimeInterval(week))
        let history = (0..<12).map { index in
            point(
                Double(index) * 80 / 11,
                at: end.addingTimeInterval(-TimeInterval(week) + TimeInterval(index) * (TimeInterval(week) / 12)),
                resetAt: end
            )
        }
        func sample(windowStart: Date) -> SubscriptionWindowSample {
            SubscriptionWindowSample(
                accountId: "account",
                tool: .codex,
                bucketId: "weekly",
                windowEnd: end,
                windowStart: windowStart,
                rawWindowSeconds: week,
                peakUsedPercent: 80,
                lastUsedPercent: 80,
                observationCount: 12,
                firstSeenAt: end.addingTimeInterval(-TimeInterval(week)),
                lastSeenAt: end.addingTimeInterval(-600),
                completedAt: end,
                completionReason: .scheduledReset
            )
        }

        let honest = try XCTUnwrap(QuotaPaceForecast.compute(
            bucket: bucket(used: 20, resetAt: reset),
            observations: currentPoints + history,
            cycles: [sample(windowStart: end.addingTimeInterval(-TimeInterval(week)))],
            now: now
        ))
        // The same cycle, with the span a rolling window would have left behind.
        let collapsed = try XCTUnwrap(QuotaPaceForecast.compute(
            bucket: bucket(used: 20, resetAt: reset),
            observations: currentPoints + history,
            cycles: [sample(windowStart: end.addingTimeInterval(-900))],
            now: now
        ))

        XCTAssertEqual(honest.diagnostics.comparableCycleCount, 1)
        XCTAssertEqual(
            try XCTUnwrap(collapsed.diagnostics.historicalProjectionUsedPercent),
            try XCTUnwrap(honest.diagnostics.historicalProjectionUsedPercent),
            accuracy: 0.000_001,
            "the window length the provider reported decides the span, not a stale windowStart"
        )
    }

    /// The observation that detected a refill belongs to the cycle that
    /// follows, not the one that ended.
    ///
    /// It is stamped exactly `completedAt`, so an end-inclusive filter put it
    /// inside the finished cycle — and at progress 1.0, which is where a
    /// nearly-finished current window looks for its comparison. A visible
    /// 60% → 5% refill was then read as 55 further points of consumption in a
    /// window that was already over.
    ///
    /// Stated as an A/B: adding a sample that belongs to the next cycle must
    /// not change what this one contributes.
    func testTheRefillObservationDoesNotCountAgainstTheCycleItEnded() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Current window nearly over, so the closest comparable progress is
        // exactly where the stray sample sits.
        let reset = now.addingTimeInterval(TimeInterval(week) / 40)
        let start = reset.addingTimeInterval(-TimeInterval(week))
        let currentPoints = (0..<24).map { index in
            point(
                Double(index) * 55 / 23,
                at: start.addingTimeInterval(TimeInterval(index) * (TimeInterval(week) / 24)),
                resetAt: reset
            )
        }

        let end = start.addingTimeInterval(-TimeInterval(week))
        let cycleStart = end.addingTimeInterval(-TimeInterval(week))
        // A past cycle that climbed to 60%, last seen a little before it reset.
        let history = (0..<12).map { index in
            point(
                Double(index) * 60 / 11,
                at: cycleStart.addingTimeInterval(TimeInterval(index) * (TimeInterval(week) / 12)),
                resetAt: end
            )
        }
        // The reading that detected the refill: 5%, stamped at the reset, and
        // already part of the next window.
        let afterRefill = point(5, at: end, resetAt: end.addingTimeInterval(TimeInterval(week)))

        let cycle = SubscriptionWindowSample(
            accountId: "account",
            tool: .codex,
            bucketId: "weekly",
            windowEnd: end,
            windowStart: cycleStart,
            rawWindowSeconds: week,
            peakUsedPercent: 60,
            lastUsedPercent: 60,
            observationCount: 12,
            firstSeenAt: cycleStart,
            lastSeenAt: end.addingTimeInterval(-600),
            completedAt: end,
            completionReason: .refillDetected
        )
        func historicalProjection(with observations: [FillTimelinePoint]) throws -> Double {
            let forecast = try XCTUnwrap(QuotaPaceForecast.compute(
                bucket: bucket(used: 55, resetAt: reset),
                observations: observations,
                cycles: [cycle],
                now: now
            ))
            return try XCTUnwrap(forecast.diagnostics.historicalProjectionUsedPercent)
        }

        let without = try historicalProjection(with: currentPoints + history)
        let with = try historicalProjection(with: currentPoints + history + [afterRefill])

        XCTAssertEqual(
            with, without, accuracy: 0.000_001,
            "a reading from the next cycle changed what the previous one contributed"
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
