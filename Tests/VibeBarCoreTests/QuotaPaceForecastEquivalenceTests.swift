import XCTest
@testable import VibeBarCore

/// `QuotaPaceForecast.historicalRemainingUsage` used to re-filter the entire
/// observation lane once per completed cycle, copying every `FillTimelinePoint`
/// it looked at. On real data — a Claude five-hour bucket retains ~200
/// completed cycles against ~7 300 observations — that is ~1.5 M struct copies
/// per call, and the struct carries three `String`s, so each copy is six ARC
/// operations. It ran inside a SwiftUI `body`.
///
/// It now binary-searches the time-ordered lane once per cycle and scans only
/// that cycle's slice, addressing points by index instead of copying them.
/// These tests pin the new walk against `referenceHistoricalRemainingUsage`
/// below — a verbatim copy of the retired algorithm — so the swap stays a
/// performance change rather than a behaviour change.
final class QuotaPaceForecastEquivalenceTests: XCTestCase {
    // MARK: - The retired algorithm, kept as the equivalence oracle

    private func referenceHistoricalRemainingUsage(
        cycles: [SubscriptionWindowSample],
        observations: [FillTimelinePoint],
        currentProgress: Double,
        profile: QuotaPaceForecast.ActivityProfile
    ) -> [Double] {
        func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
            min(max(value, lower), upper)
        }
        return cycles.compactMap { cycle in
            let cycleStart = cycle.windowStart ?? cycle.firstSeenAt
            let cycleEnd = cycle.completedAt ?? cycle.windowEnd
            guard cycleEnd > cycleStart else { return nil }
            let total = max(0.001, profile.weight(from: cycleStart, to: cycleEnd))
            let observationEnd = cycle.lastSeenAt
            let matching = observations
                .filter { $0.sampledAt >= cycleStart && $0.sampledAt <= observationEnd }
                .map { point -> (distance: Double, used: Double) in
                    let progress = clamp(profile.weight(from: cycleStart, to: point.sampledAt) / total, 0, 1)
                    return (abs(progress - currentProgress), point.usedPercent)
                }
                .min { $0.distance < $1.distance }
            if let matching, matching.distance <= 0.22 {
                return max(0, cycle.peakUsedPercent - matching.used)
            }
            return max(0, cycle.peakUsedPercent * (1 - currentProgress))
        }
    }

    /// The retired shape of `compute`'s current-window slice, kept so the
    /// index range that replaced it can be checked against it.
    private func referenceCurrentPoints(
        observations: [FillTimelinePoint],
        windowStart: Date,
        evaluationDate: Date
    ) -> [FillTimelinePoint] {
        observations
            .filter {
                $0.sampledAt >= windowStart.addingTimeInterval(-300)
                    && $0.sampledAt <= evaluationDate.addingTimeInterval(60)
            }
            .sorted { $0.sampledAt < $1.sampledAt }
    }

    // MARK: - Deterministic synthetic data

    /// A seeded generator, so a failure is reproducible and CI never flakes.
    private struct Random {
        private var state: UInt64

        init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }

        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }

        mutating func double(_ lower: Double, _ upper: Double) -> Double {
            let unit = Double(next() % 1_000_000) / 1_000_000
            return lower + unit * (upper - lower)
        }

        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.count))
        }

        mutating func bool(_ probability: Double) -> Bool { double(0, 1) < probability }
    }

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func point(_ used: Double, at date: Date) -> FillTimelinePoint {
        FillTimelinePoint(
            accountId: "account",
            tool: .claude,
            bucketId: "five_hour",
            slotStart: UsageFillTimelineStore.hourSlotStart(for: date),
            usedPercent: used,
            sampledAt: date,
            resetAt: nil,
            rawWindowSeconds: 5 * 3_600
        )
    }

    private func cycle(
        start: Date?,
        firstSeenAt: Date,
        lastSeenAt: Date,
        windowEnd: Date,
        completedAt: Date?,
        peak: Double
    ) -> SubscriptionWindowSample {
        SubscriptionWindowSample(
            accountId: "account",
            tool: .claude,
            bucketId: "five_hour",
            windowEnd: windowEnd,
            windowStart: start,
            rawWindowSeconds: 5 * 3_600,
            peakUsedPercent: peak,
            lastUsedPercent: peak,
            observationCount: 4,
            firstSeenAt: firstSeenAt,
            lastSeenAt: lastSeenAt,
            completedAt: completedAt,
            completionReason: completedAt == nil ? nil : .refillDetected
        )
    }

    /// A lane shaped like the real thing: back-to-back five-hour cycles that
    /// mostly refill on schedule, some early, some with no observations at
    /// all, and one degenerate cycle whose end precedes its start.
    private func syntheticLane(
        seed: UInt64,
        cycleCount: Int,
        shuffled: Bool
    ) -> (cycles: [SubscriptionWindowSample], observations: [FillTimelinePoint]) {
        var random = Random(seed: seed)
        var cycles: [SubscriptionWindowSample] = []
        var observations: [FillTimelinePoint] = []
        var cursor = epoch.addingTimeInterval(-Double(cycleCount) * 5 * 3_600)

        for index in 0..<cycleCount {
            // Some cycles refill early — a stated five-hour window that
            // actually closes after two or three.
            let span = random.bool(0.3)
                ? random.double(2 * 3_600, 4 * 3_600)
                : 5 * 3_600
            let start = cursor
            let end = start.addingTimeInterval(span)
            let emptyCycle = random.bool(0.12)
            var peak = 0.0
            var lastSeenAt = start
            if !emptyCycle {
                let sampleCount = random.int(3...40)
                var used = random.double(0, 8)
                for sample in 0..<sampleCount {
                    let offset = span * (Double(sample) + random.double(0.05, 0.9)) / Double(sampleCount)
                    let at = start.addingTimeInterval(offset)
                    used = min(100, used + random.double(0, 6))
                    peak = max(peak, used)
                    lastSeenAt = max(lastSeenAt, at)
                    observations.append(point(used, at: at))
                }
            }
            // A degenerate cycle in the middle: `compactMap` used to drop it
            // and the new loop must drop it too, or every later element of
            // the result array shifts.
            if index == cycleCount / 2 {
                cycles.append(cycle(
                    start: end,
                    firstSeenAt: end,
                    lastSeenAt: end,
                    windowEnd: start,
                    completedAt: start,
                    peak: 42
                ))
            }
            cycles.append(cycle(
                start: random.bool(0.15) ? nil : start,
                firstSeenAt: start,
                lastSeenAt: lastSeenAt,
                windowEnd: start.addingTimeInterval(5 * 3_600),
                completedAt: end,
                peak: peak
            ))
            cursor = end
        }

        if shuffled {
            // Deliberately out of order, including exact-duplicate timestamps,
            // which is where "first minimum wins" has to keep meaning the same
            // point as before.
            if let first = observations.first {
                observations.append(first)
            }
            var shuffledPoints = observations
            for index in stride(from: shuffledPoints.count - 1, to: 0, by: -1) {
                let swapWith = random.int(0...index)
                shuffledPoints.swapAt(index, swapWith)
            }
            observations = shuffledPoints
        }

        return (cycles, observations)
    }

    private func heatmap() -> UsageHeatmap {
        var cells = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        var random = Random(seed: 99)
        for weekday in 0..<7 {
            for hour in 0..<24 {
                cells[weekday][hour] = hour >= 9 && hour <= 20 ? random.int(400...9_000) : random.int(0...200)
            }
        }
        let total = cells.reduce(0) { $0 + $1.reduce(0, +) }
        return UsageHeatmap(tool: .claude, cells: cells, totalTokens: total)
    }

    // MARK: - Tests

    /// The reference and the new walk share one *prepared* profile, so the
    /// hour table underneath them is byte-identical and any difference in the
    /// result is a difference in the algorithm rather than in floating-point
    /// association.
    private func assertEquivalent(
        cycles: [SubscriptionWindowSample],
        observations: [FillTimelinePoint],
        currentProgress: Double,
        activityHeatmap: UsageHeatmap?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let profile = QuotaPaceForecast.ActivityProfile(
            heatmap: activityHeatmap,
            calendar: Calendar(identifier: .gregorian)
        )
        let earliest = cycles.map { $0.windowStart ?? $0.firstSeenAt }.min() ?? epoch
        let latest = cycles.map { max($0.completedAt ?? $0.windowEnd, $0.lastSeenAt) }.max() ?? epoch
        profile.prepare(from: earliest.addingTimeInterval(-86_400), to: latest.addingTimeInterval(86_400))

        let expected = referenceHistoricalRemainingUsage(
            cycles: cycles,
            observations: observations,
            currentProgress: currentProgress,
            profile: profile
        )
        let actual = QuotaPaceForecast.historicalRemainingUsage(
            cycles: cycles,
            lane: QuotaPaceForecast.ObservationLane(observations),
            currentProgress: currentProgress,
            profile: profile
        )
        XCTAssertEqual(actual.count, expected.count, "cycle count differs", file: file, line: line)
        guard actual.count == expected.count else { return }
        for index in actual.indices {
            XCTAssertEqual(
                actual[index],
                expected[index],
                accuracy: 1e-12,
                "cycle \(index) differs",
                file: file,
                line: line
            )
        }
    }

    func testHistoricalRemainingUsageMatchesRetiredAlgorithmOnSortedLanes() {
        let map = heatmap()
        for seed in UInt64(1)...6 {
            let lane = syntheticLane(seed: seed, cycleCount: 24, shuffled: false)
            for progress in [0.0, 0.05, 0.31, 0.5, 0.78, 1.0] {
                assertEquivalent(
                    cycles: lane.cycles,
                    observations: lane.observations,
                    currentProgress: progress,
                    activityHeatmap: map
                )
            }
        }
    }

    func testHistoricalRemainingUsageMatchesRetiredAlgorithmWithoutAHeatmap() {
        for seed in UInt64(11)...14 {
            let lane = syntheticLane(seed: seed, cycleCount: 18, shuffled: false)
            for progress in [0.0, 0.22, 0.63, 1.0] {
                assertEquivalent(
                    cycles: lane.cycles,
                    observations: lane.observations,
                    currentProgress: progress,
                    activityHeatmap: nil
                )
            }
        }
    }

    /// The retired code filtered the lane in whatever order it arrived, so an
    /// out-of-order lane picked the first minimum in *input* order. The new
    /// walk sorts once and breaks distance ties on the original position for
    /// exactly that reason.
    func testHistoricalRemainingUsageMatchesRetiredAlgorithmOnOutOfOrderLanes() {
        let map = heatmap()
        for seed in UInt64(21)...26 {
            let lane = syntheticLane(seed: seed, cycleCount: 20, shuffled: true)
            for progress in [0.0, 0.17, 0.5, 0.91, 1.0] {
                assertEquivalent(
                    cycles: lane.cycles,
                    observations: lane.observations,
                    currentProgress: progress,
                    activityHeatmap: map
                )
                assertEquivalent(
                    cycles: lane.cycles,
                    observations: lane.observations,
                    currentProgress: progress,
                    activityHeatmap: nil
                )
            }
        }
    }

    func testHistoricalRemainingUsageMatchesOnEmptyAndDegenerateInputs() {
        let lane = syntheticLane(seed: 31, cycleCount: 6, shuffled: false)
        assertEquivalent(cycles: [], observations: lane.observations, currentProgress: 0.4, activityHeatmap: nil)
        assertEquivalent(cycles: lane.cycles, observations: [], currentProgress: 0.4, activityHeatmap: nil)
        assertEquivalent(cycles: [], observations: [], currentProgress: 0.4, activityHeatmap: nil)
        // Cycles whose observations were all pruned away fall back to
        // `peak * (1 - progress)`; keep that path covered explicitly.
        let shift: TimeInterval = -90 * 86_400
        let orphaned = lane.cycles.map { sample -> SubscriptionWindowSample in
            cycle(
                start: sample.windowStart.map { start in start.addingTimeInterval(shift) },
                firstSeenAt: sample.firstSeenAt.addingTimeInterval(shift),
                lastSeenAt: sample.lastSeenAt.addingTimeInterval(shift),
                windowEnd: sample.windowEnd.addingTimeInterval(shift),
                completedAt: sample.completedAt?.addingTimeInterval(shift),
                peak: sample.peakUsedPercent
            )
        }
        assertEquivalent(
            cycles: orphaned,
            observations: lane.observations,
            currentProgress: 0.4,
            activityHeatmap: nil
        )
    }

    /// A refill inside the retention window: the point that *detected* the
    /// refill is stamped a shade before `completedAt` and belongs to the next
    /// cycle, which is why the scan is bounded by `lastSeenAt`. Both
    /// implementations must agree about that boundary.
    func testHistoricalRemainingUsageAgreesAcrossARefillBoundary() {
        let start = epoch.addingTimeInterval(-5 * 3_600)
        let lastSeen = start.addingTimeInterval(4 * 3_600)
        let completed = lastSeen.addingTimeInterval(60)
        let observations = [
            point(5, at: start.addingTimeInterval(600)),
            point(28, at: start.addingTimeInterval(2 * 3_600)),
            point(60, at: lastSeen),
            // The refill reading: after `lastSeenAt`, before `completedAt`.
            point(5, at: lastSeen.addingTimeInterval(30))
        ]
        let cycles = [cycle(
            start: start,
            firstSeenAt: start,
            lastSeenAt: lastSeen,
            windowEnd: start.addingTimeInterval(5 * 3_600),
            completedAt: completed,
            peak: 60
        )]
        for progress in [0.0, 0.25, 0.5, 0.75, 1.0] {
            assertEquivalent(
                cycles: cycles,
                observations: observations,
                currentProgress: progress,
                activityHeatmap: nil
            )
        }
    }

    // MARK: - The rest of the pass

    /// `compute` replaced `observations.filter { … }.sorted { … }` with an
    /// index range over the same lane. It has to select the same points.
    func testCurrentWindowSliceMatchesTheRetiredFilter() {
        for shuffled in [false, true] {
            let lane = syntheticLane(seed: 41, cycleCount: 12, shuffled: shuffled)
            let observationLane = QuotaPaceForecast.ObservationLane(lane.observations)
            let windowStart = epoch.addingTimeInterval(-5 * 3_600)
            let evaluationDate = epoch.addingTimeInterval(-1_800)
            let lower = observationLane.lowerBound(windowStart.addingTimeInterval(-300))
            let upper = observationLane.upperBound(evaluationDate.addingTimeInterval(60))
            let ranks = lower..<max(lower, upper)
            let expected = referenceCurrentPoints(
                observations: lane.observations,
                windowStart: windowStart,
                evaluationDate: evaluationDate
            )
            XCTAssertEqual(ranks.count, expected.count)
            guard ranks.count == expected.count else { continue }
            for (offset, rank) in ranks.enumerated() {
                XCTAssertEqual(observationLane.sampledAt(atRank: rank), expected[offset].sampledAt)
            }
        }
    }

    /// End-to-end: the lane's storage order must not reach the forecast. A
    /// shuffled lane and its sorted twin have to produce the same forecast.
    func testForecastIsIndependentOfObservationStorageOrder() throws {
        let lane = syntheticLane(seed: 51, cycleCount: 20, shuffled: false)
        var shuffledPoints = lane.observations
        var random = Random(seed: 777)
        for index in stride(from: shuffledPoints.count - 1, to: 0, by: -1) {
            shuffledPoints.swapAt(index, random.int(0...index))
        }
        let bucket = QuotaBucket(
            id: "five_hour",
            title: "5-hour",
            shortLabel: "5h",
            usedPercent: 46,
            resetAt: epoch.addingTimeInterval(2 * 3_600),
            rawWindowSeconds: 5 * 3_600
        )
        let sorted = try XCTUnwrap(QuotaPaceForecast.compute(
            bucket: bucket,
            observations: lane.observations,
            cycles: lane.cycles,
            activityHeatmap: heatmap(),
            now: epoch,
            calendar: Calendar(identifier: .gregorian)
        ))
        let shuffled = try XCTUnwrap(QuotaPaceForecast.compute(
            bucket: bucket,
            observations: shuffledPoints,
            cycles: lane.cycles,
            activityHeatmap: heatmap(),
            now: epoch,
            calendar: Calendar(identifier: .gregorian)
        ))
        XCTAssertEqual(sorted, shuffled)
    }

    /// Prewarming the hour table is a performance change, so a profile that
    /// was prepared over a wide span must answer exactly like one that grew on
    /// demand, to within the association error of the prefix sums it walks.
    func testPreparingTheHourTableDoesNotChangeWeights() {
        let map = heatmap()
        let calendar = Calendar(identifier: .gregorian)
        let lazyProfile = QuotaPaceForecast.ActivityProfile(heatmap: map, calendar: calendar)
        let eagerProfile = QuotaPaceForecast.ActivityProfile(heatmap: map, calendar: calendar)
        eagerProfile.prepare(
            from: epoch.addingTimeInterval(-60 * 86_400),
            to: epoch.addingTimeInterval(86_400)
        )
        var random = Random(seed: 123)
        for _ in 0..<200 {
            let start = epoch.addingTimeInterval(-random.double(0, 55 * 86_400))
            let end = start.addingTimeInterval(random.double(60, 6 * 86_400))
            XCTAssertEqual(
                eagerProfile.weight(from: start, to: end),
                lazyProfile.weight(from: start, to: end),
                accuracy: 1e-9
            )
        }
    }

    /// A span wider than one table falls back to the chunked path, which is
    /// what keeps a corrupt stored date from asking for a giant array.
    func testPreparingAnAbsurdSpanIsIgnored() {
        let profile = QuotaPaceForecast.ActivityProfile(
            heatmap: heatmap(),
            calendar: Calendar(identifier: .gregorian)
        )
        profile.prepare(from: Date(timeIntervalSince1970: 0), to: epoch)
        // Still answers, via the chunked walk in `weight(from:to:)`.
        XCTAssertGreaterThan(
            profile.weight(from: epoch.addingTimeInterval(-3_600), to: epoch),
            0
        )
    }

    // MARK: - The quantized forecast clock

    func testForecastClockFloorsToFiveMinutes() {
        let quantum = QuotaService.paceForecastClockQuantumSeconds
        XCTAssertEqual(quantum, 300)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(QuotaService.quantizedForecastClock(base), base)
        for offset in [1.0, 59.0, 299.0, 299.999] {
            XCTAssertEqual(
                QuotaService.quantizedForecastClock(base.addingTimeInterval(offset)),
                base
            )
        }
        XCTAssertEqual(
            QuotaService.quantizedForecastClock(base.addingTimeInterval(300)),
            base.addingTimeInterval(300)
        )
        // Never rounds forward, including before the epoch.
        let negative = Date(timeIntervalSince1970: -1)
        XCTAssertLessThanOrEqual(QuotaService.quantizedForecastClock(negative), negative)
    }
}
