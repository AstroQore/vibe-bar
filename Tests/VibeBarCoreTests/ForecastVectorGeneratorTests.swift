import XCTest
@testable import VibeBarCore

/// Emits cross-language forecast vectors covering completed cycles.
///
/// Not a test: a generator, skipped unless `VIBEBAR_EMIT_FORECAST_VECTORS`
/// names an output file. It lives in the test target because that is the only
/// place that can call the real implementation.
final class ForecastVectorGeneratorTests: XCTestCase {
    private let week = 7 * 86_400

    func testEmitCycleVectors() throws {
        guard let destination = ProcessInfo.processInfo
            .environment["VIBEBAR_EMIT_FORECAST_VECTORS"] else {
            throw XCTSkip("set VIBEBAR_EMIT_FORECAST_VECTORS to regenerate")
        }

        let fractions = [0.25, 0.5, 0.75, 0.95]
        var cases: [[String: Any]] = []

        for scenario in Self.scenarios() {
            var expectations: [[String: Any]] = []
            let window = TimeInterval(week)
            for fraction in fractions {
                let now = scenario.resetAt.addingTimeInterval(-window * (1 - fraction))
                let visible = scenario.observations.filter { $0.sampledAt <= now }
                guard let last = visible.last else { continue }
                guard let forecast = QuotaPaceForecast.compute(
                    bucket: QuotaBucket(
                        id: "weekly",
                        title: "Weekly",
                        shortLabel: "Weekly",
                        usedPercent: last.usedPercent,
                        resetAt: scenario.resetAt,
                        rawWindowSeconds: week
                    ),
                    observations: visible + scenario.history,
                    cycles: scenario.cycles,
                    now: now
                ) else { continue }
                var row: [String: Any] = [
                    "verdict": forecast.verdict.rawValue,
                    "confidence": forecast.confidence.rawValue,
                    "confidenceScore": forecast.confidenceScore,
                    "planned": forecast.plannedUsedPercent,
                    "projected": forecast.projectedUsedPercent,
                    "lower": forecast.projectedUsedLowerPercent,
                    "upper": forecast.projectedUsedUpperPercent,
                    "target": forecast.targetRemainingPercent,
                    "observationCount": forecast.currentObservationCount,
                    "recentSampleCount": forecast.diagnostics.recentSampleCount,
                    "completedCycleCount": forecast.completedCycleCount,
                ]
                if let runOut = forecast.runOutAt {
                    row["runOutAt"] = runOut.timeIntervalSince1970
                }
                if let historical = forecast.diagnostics.historicalProjectionUsedPercent {
                    row["historicalProjection"] = historical
                }
                expectations.append(row)
            }
            cases.append([
                "name": scenario.name,
                "description": scenario.description,
                "input": [
                    "rawWindowSeconds": week,
                    "resetAt": scenario.resetAt.timeIntervalSince1970,
                    // Sorted: a consumer takes the last entry at or before the
                    // evaluation moment as the current reading.
                    "observations": (scenario.observations + scenario.history)
                        .sorted { $0.sampledAt < $1.sampledAt }
                        .map {
                        ["sampledAt": $0.sampledAt.timeIntervalSince1970,
                         "usedPercent": $0.usedPercent]
                    },
                    "completedCycles": scenario.cycles.map { cycle -> [String: Any] in
                        var out: [String: Any] = [
                            "windowStart": (cycle.windowStart ?? cycle.firstSeenAt)
                                .timeIntervalSince1970,
                            "windowEnd": (cycle.completedAt ?? cycle.windowEnd)
                                .timeIntervalSince1970,
                            // The bound on which observations belong to this
                            // cycle. Not derivable from the boundaries: it is
                            // wherever the last reading before the refill
                            // happened to land.
                            "lastSeenAt": cycle.lastSeenAt.timeIntervalSince1970,
                            "peakUsedPercent": cycle.peakUsedPercent,
                        ]
                        if let raw = cycle.rawWindowSeconds { out["rawWindowSeconds"] = raw }
                        return out
                    },
                ],
                "expected": expectations,
            ])
        }

        let data = try JSONSerialization.data(
            withJSONObject: cases, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: destination))
        print("wrote \(cases.count) cases to \(destination)")
    }

    private struct Scenario {
        let name: String
        let description: String
        let resetAt: Date
        let observations: [FillTimelinePoint]
        let history: [FillTimelinePoint]
        let cycles: [SubscriptionWindowSample]
    }

    private static func point(_ used: Double, at date: Date, resetAt: Date) -> FillTimelinePoint {
        FillTimelinePoint(
            accountId: "account",
            tool: .codex,
            bucketId: "weekly",
            slotStart: UsageFillTimelineStore.hourSlotStart(for: date),
            usedPercent: used,
            sampledAt: date,
            resetAt: resetAt,
            rawWindowSeconds: 7 * 86_400
        )
    }

    private static func ramp(
        _ from: Double, _ to: Double, start: Date, end: Date, count: Int, resetAt: Date
    ) -> [FillTimelinePoint] {
        (0..<count).map { index in
            let t = Double(index) / Double(count - 1)
            return point(
                from + (to - from) * t,
                at: start.addingTimeInterval(end.timeIntervalSince(start) * t),
                resetAt: resetAt
            )
        }
    }

    private static func sample(
        windowStart: Date, windowEnd: Date, peak: Double, rawWindowSeconds: Int?
    ) -> SubscriptionWindowSample {
        SubscriptionWindowSample(
            accountId: "account",
            tool: .codex,
            bucketId: "weekly",
            windowEnd: windowEnd,
            windowStart: windowStart,
            rawWindowSeconds: rawWindowSeconds,
            peakUsedPercent: peak,
            lastUsedPercent: peak,
            observationCount: 12,
            firstSeenAt: windowStart,
            lastSeenAt: windowEnd.addingTimeInterval(-600),
            completedAt: windowEnd,
            completionReason: .scheduledReset
        )
    }

    private static func scenarios() -> [Scenario] {
        let week = TimeInterval(7 * 86_400)
        let reset = Date(timeIntervalSince1970: 1_800_500_000)
        let start = reset.addingTimeInterval(-week)

        // Three finished weeks, each fully observed, peaking near 70%.
        var history: [FillTimelinePoint] = []
        var cycles: [SubscriptionWindowSample] = []
        for index in 1...3 {
            let end = start.addingTimeInterval(-week * Double(index - 1))
            let begin = end.addingTimeInterval(-week)
            let peak = 66 + Double(index) * 2
            history += ramp(0, peak, start: begin, end: end.addingTimeInterval(-600),
                            count: 12, resetAt: end)
            cycles.append(sample(windowStart: begin, windowEnd: end, peak: peak,
                                 rawWindowSeconds: 7 * 86_400))
        }

        let measured = Scenario(
            name: "cycles_measured",
            description: "Three fully observed weekly cycles behind a window on a similar pace.",
            resetAt: reset,
            observations: ramp(0, 62, start: start, end: reset.addingTimeInterval(-600),
                               count: 24, resetAt: reset),
            history: history,
            cycles: cycles
        )

        // One cycle whose stored start collapsed to a single polling interval,
        // the way a rolling window leaves it, plus the post-refill reading that
        // shares its completion timestamp.
        let end = start.addingTimeInterval(-week)
        var stray = ramp(0, 60, start: end.addingTimeInterval(-week),
                         end: end.addingTimeInterval(-week / 12), count: 12, resetAt: end)
        stray.append(point(5, at: end, resetAt: start))
        let awkward = Scenario(
            name: "cycles_collapsed_start_and_refill_sample",
            description: """
                A cycle whose stored windowStart is far shorter than its window, \
                and a post-refill reading at its end. Both clients must take the \
                stored start as it stands — many buckets refill more often than \
                the window they advertise, so a short span is usually the truth \
                — and must leave the stray reading to the cycle it opened.
                """,
            resetAt: reset,
            observations: ramp(0, 58, start: start, end: reset.addingTimeInterval(-600),
                               count: 24, resetAt: reset),
            history: stray,
            cycles: [sample(windowStart: end.addingTimeInterval(-900), windowEnd: end,
                            peak: 60, rawWindowSeconds: 7 * 86_400)]
        )

        // A cycle observed only through its first 60%, plus the post-refill
        // reading stamped at its end. A current window past 60% then finds the
        // stray reading closer than any real one, which is the shape that made
        // an end-inclusive filter read a 60% to 5% refill as 55 further points.
        let sparseEnd = start.addingTimeInterval(-week)
        let sparseStart = sparseEnd.addingTimeInterval(-week)
        var sparse = ramp(0, 36, start: sparseStart,
                          end: sparseStart.addingTimeInterval(week * 0.6),
                          count: 8, resetAt: sparseEnd)
        sparse.append(point(4, at: sparseEnd, resetAt: start))
        let boundary = Scenario(
            name: "cycles_refill_sample_at_the_boundary",
            description: """
                A past cycle seen only through its first 60%, and a post-refill \
                reading stamped at its exact end. Past that progress the stray \
                reading is the closest comparable moment, so a client that keeps \
                it inside the finished cycle reads the refill as consumption.
                """,
            resetAt: reset,
            observations: ramp(0, 70, start: start, end: reset.addingTimeInterval(-600),
                               count: 24, resetAt: reset),
            history: sparse,
            cycles: [sample(windowStart: sparseStart, windowEnd: sparseEnd,
                            peak: 60, rawWindowSeconds: 7 * 86_400)]
        )

        return [measured, awkward, boundary]
    }
}
