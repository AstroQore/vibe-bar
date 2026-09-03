import Foundation

/// Personal quota forecast for one independently resettable bucket.
///
/// The forecast separates two questions that a linear elapsed-time marker
/// cannot answer on its own:
/// 1. Is the quota likely to survive until the provider refills it?
/// 2. If it survives, how much useful capacity is likely to be left unused?
///
/// Quota observations are the only source used to estimate consumption.
/// Token/cost history contributes calendar weights (when the user tends to be
/// active), never a token-to-quota conversion.
public struct QuotaPaceForecast: Sendable, Equatable {
    public enum Verdict: String, Sendable, Equatable {
        case enough
        case surplus
        case watch
        case atRisk
        case learning

        /// The verdict in words. On the enum rather than on the forecast so a
        /// surface that only has a verdict in hand — the menu-bar composer's
        /// visibility rule, say — reads the same key the quota bar does
        /// instead of spelling the five words again.
        public var label: String {
            switch self {
            case .enough: L10n.Quota.forecastVerdictEnough
            case .surplus: L10n.Quota.forecastVerdictSurplus
            case .watch: L10n.Quota.forecastVerdictWatch
            case .atRisk: L10n.Quota.forecastVerdictAtRisk
            case .learning: L10n.Quota.forecastVerdictLearning
            }
        }
    }

    public enum Confidence: String, Sendable, Equatable {
        case learning
        case medium
        case high
    }

    /// Explainable inputs and component projections used by the blended
    /// forecast. These values are intentionally retained so detailed product
    /// surfaces can show their work instead of presenting a black-box verdict.
    public struct Diagnostics: Sendable, Equatable {
        public let recentProjectionUsedPercent: Double?
        public let historicalProjectionUsedPercent: Double?
        public let behavioralProjectionUsedPercent: Double
        public let behavioralProgressPercent: Double
        public let activityTrendMultiplier: Double
        public let hasActivityTrendBaseline: Bool
        public let observationCoveragePercent: Double
        public let historyCoveragePercent: Double
        public let freshnessPercent: Double
        public let activityCoveragePercent: Double
        public let recentSampleCount: Int
        public let comparableCycleCount: Int
    }

    public let verdict: Verdict
    public let confidence: Confidence
    public let confidenceScore: Double
    public let currentUsedPercent: Double
    public let plannedUsedPercent: Double
    /// Median projected demand at reset. May exceed 100 to preserve shortage
    /// severity even though the visible quota itself is capped at 100%.
    public let projectedUsedPercent: Double
    public let projectedUsedLowerPercent: Double
    public let projectedUsedUpperPercent: Double
    public let targetRemainingPercent: Double
    public let runOutAt: Date?
    public let completedCycleCount: Int
    public let currentObservationCount: Int
    public let diagnostics: Diagnostics

    public var projectedRemainingPercent: Double {
        max(0, 100 - projectedUsedPercent)
    }

    /// Remaining-at-reset interval, low first and high second.
    public var projectedRemainingRange: ClosedRange<Double> {
        max(0, 100 - projectedUsedUpperPercent)...max(0, 100 - projectedUsedLowerPercent)
    }

    /// Median capacity above the adaptive safety target. Positive values are
    /// potential waste, not an instruction to manufacture unnecessary work.
    public var potentialUnusedPercent: Double {
        max(0, projectedRemainingPercent - targetRemainingPercent)
    }

    public var verdictLabel: String { verdict.label }

    public var confidenceLabel: String {
        switch confidence {
        case .learning: L10n.Quota.forecastConfidenceLearning
        case .medium: L10n.Quota.forecastConfidenceMedium
        case .high: L10n.Quota.forecastConfidenceHigh
        }
    }

    public var resetSummary: String {
        let left = Int(projectedRemainingPercent.rounded())
        switch verdict {
        case .enough:
            return L10n.Quota.forecastResetEnough(remaining: left)
        case .surplus:
            return L10n.Quota.forecastResetSurplus(remaining: left)
        case .watch:
            return L10n.Quota.forecastResetWatch(remaining: left)
        case .atRisk:
            return L10n.Quota.forecastResetAtRisk
        case .learning:
            return L10n.Quota.forecastResetLearning(remaining: left)
        }
    }

    public var guidanceSummary: String {
        let target = Int(targetRemainingPercent.rounded())
        let unused = Int(potentialUnusedPercent.rounded())
        if verdict == .atRisk { return L10n.Quota.forecastGuidanceAtRisk }
        if verdict == .watch { return L10n.Quota.forecastGuidanceWatch }
        if verdict == .surplus {
            return L10n.Quota.forecastGuidanceSurplus(unused: unused, target: target)
        }
        if unused >= 3 {
            return L10n.Quota.forecastGuidanceAvailable(target: target, unused: unused)
        }
        return L10n.Quota.forecastGuidanceWithinTarget(target: target)
    }

    public static func compute(
        bucket: QuotaBucket,
        observations: [FillTimelinePoint],
        cycles: [SubscriptionWindowSample],
        activityHeatmap: UsageHeatmap? = nil,
        dailyActivity: [DailyCostPoint] = [],
        now: Date = Date(),
        calendar: Calendar = .current,
        allowsPostResetGrace: Bool = false
    ) -> QuotaPaceForecast? {
        guard let resetAt = bucket.resetAt,
              let rawWindowSeconds = bucket.rawWindowSeconds,
              rawWindowSeconds > 0
        else { return nil }

        guard let evaluationDate = QuotaWindowEvaluation.date(
            resetAt: resetAt,
            now: now,
            allowsPostResetGrace: allowsPostResetGrace
        ) else {
            return nil
        }

        let duration = TimeInterval(rawWindowSeconds)
        let remainingTime = resetAt.timeIntervalSince(evaluationDate)
        guard remainingTime <= duration * 1.1 else { return nil }

        let windowStart = resetAt.addingTimeInterval(-duration)
        let actual = clamp(bucket.usedPercent, 0, 100)
        let profile = ActivityProfile(heatmap: activityHeatmap, calendar: calendar)
        let completed = cycles.filter(\.isCompleted)
        // Build the hour table once, covering everything this pass will ask
        // about. `weight(from:to:)` grows the table on demand, and the store
        // hands completed cycles over newest-first, so the previous shape
        // rebuilt an ever-widening table once per cycle on the way back
        // through history — quadratic in the number of retained cycles for a
        // table that only ever needed building once.
        let span = activitySpan(
            windowStart: windowStart,
            evaluationDate: evaluationDate,
            resetAt: resetAt,
            cycles: completed
        )
        profile.prepare(from: span.start, to: span.end)
        let totalActivity = max(0.001, profile.weight(from: windowStart, to: resetAt))
        let elapsedActivity = clamp(profile.weight(from: windowStart, to: evaluationDate), 0, totalActivity)
        let futureActivity = max(0, totalActivity - elapsedActivity)
        let behavioralProgress = clamp(elapsedActivity / totalActivity, 0, 1)

        // The observation lane is already in time order everywhere the app
        // uses it, so the current window is a contiguous slice of it: two
        // binary searches instead of a `filter { … }.sorted { … }` that copied
        // every point in the lane.
        let lane = ObservationLane(observations)
        let currentLower = lane.lowerBound(windowStart.addingTimeInterval(-300))
        let currentUpper = lane.upperBound(evaluationDate.addingTimeInterval(60))
        // A window that has not opened yet (the `1.1 * duration` grace above
        // admits one) inverts the two bounds; that is an empty slice, exactly
        // as the old predicate was unsatisfiable there.
        let currentRanks = currentLower..<max(currentLower, currentUpper)

        let recent = recentSlope(lane: lane, ranks: currentRanks, profile: profile)
        let historicalAdditions = historicalRemainingUsage(
            cycles: completed,
            lane: lane,
            currentProgress: behavioralProgress,
            profile: profile
        )
        let trendResult = activityTrend(dailyActivity, now: evaluationDate, calendar: calendar)
        let trend = trendResult.multiplier

        let recentProjection = recent.rate.flatMap { recentRate in
            recentRate > 0 ? actual + recentRate * futureActivity : nil
        }
        let historicalProjection = median(historicalAdditions).map {
            actual + $0 * trend
        }

        var candidates: [(value: Double, weight: Double)] = []
        if let recentProjection {
            let reliability = min(1, Double(recent.sampleCount) / 6)
            candidates.append((recentProjection, 0.52 * reliability))
        }
        if let historicalProjection {
            let reliability = min(1, Double(historicalAdditions.count) / 5)
            candidates.append((historicalProjection, 0.34 * reliability))
        }

        // Always retain a low-weight behavioral-time fallback. It behaves like
        // the old linear model when no activity profile exists, but switches to
        // the user's actual weekday/hour shape as soon as a heatmap is present.
        let fallback: Double
        if behavioralProgress > 0.015 {
            fallback = actual / behavioralProgress
        } else {
            fallback = actual
        }
        let behavioralProjection = fallback * trend
        candidates.append((behavioralProjection, 0.14))

        let weightSum = candidates.reduce(0) { $0 + $1.weight }
        let rawProjection = weightSum > 0
            ? candidates.reduce(0) { $0 + $1.value * $1.weight } / weightSum
            : actual
        let projected = max(actual, rawProjection)

        let observationCoverage: Double = {
            guard let firstRank = currentRanks.first, let lastRank = currentRanks.last else { return 0 }
            let observedSpan = max(
                0,
                lane.sampledAt(atRank: lastRank).timeIntervalSince(lane.sampledAt(atRank: firstRank))
            )
            let elapsed = max(1, evaluationDate.timeIntervalSince(windowStart))
            let countScore = min(1, Double(currentRanks.count) / 10)
            let spanScore = min(1, observedSpan / elapsed)
            return countScore * 0.65 + spanScore * 0.35
        }()
        let historyCoverage = min(1, Double(completed.count) / 5)
        let freshness: Double = {
            guard let lastRank = currentRanks.last else { return 0 }
            let naturalSlot: TimeInterval = rawWindowSeconds <= 6 * 3_600 ? 5 * 60 : 3_600
            return clamp(
                1 - evaluationDate.timeIntervalSince(lane.sampledAt(atRank: lastRank)) / max(60, naturalSlot * 3),
                0,
                1
            )
        }()
        let activityCoverage = (activityHeatmap?.totalTokens ?? 0) > 0 ? 1.0 : 0.0
        let confidenceScore = clamp(
            observationCoverage * 0.38
                + historyCoverage * 0.30
                + freshness * 0.20
                + activityCoverage * 0.12,
            0,
            1
        )
        let confidence: Confidence
        if confidenceScore >= 0.72 { confidence = .high }
        else if confidenceScore >= 0.35 { confidence = .medium }
        else { confidence = .learning }

        let targetRemaining = clamp(5 + (1 - confidenceScore) * 8, 5, 13)
        let historicalSpread = medianAbsoluteDeviation(completed.map(\.peakUsedPercent)) * 1.4826
        let recentSpread = recent.spread * futureActivity
        let uncertainty = clamp(
            max(4, 18 * (1 - confidenceScore)) + min(12, historicalSpread * 0.35 + recentSpread * 0.5),
            4,
            28
        )
        let lower = max(actual, projected - uncertainty)
        let upper = projected + uncertainty
        // A high remaining estimate alone is not enough to call quota waste:
        // require both a material median surplus and a pessimistic bound that
        // still clears the adaptive safety target.
        let medianSurplus = max(0, 100 - projected - targetRemaining)
        let conservativeSurplus = max(0, 100 - upper - targetRemaining)

        let verdict: Verdict
        if projected >= 100 {
            verdict = .atRisk
        } else if upper >= 100 {
            verdict = .watch
        } else if confidence == .learning {
            verdict = .learning
        } else if medianSurplus >= 25, conservativeSurplus >= 10 {
            verdict = .surplus
        } else {
            verdict = .enough
        }

        let targetUsed = 100 - targetRemaining
        let planned = clamp(targetUsed * behavioralProgress, 0, targetUsed)
        let runOutAt: Date? = {
            guard upper >= 100, actual < 100 else { return actual >= 100 ? evaluationDate : nil }
            if let recentRate = recent.rate, recentRate > 0 {
                let neededWeight = (100 - actual) / recentRate
                return profile.date(after: evaluationDate, accumulating: neededWeight, noLaterThan: resetAt)
            }
            let additional = projected - actual
            guard additional > 0 else { return nil }
            let fraction = clamp((100 - actual) / additional, 0, 1)
            return profile.date(
                after: evaluationDate,
                accumulating: futureActivity * fraction,
                noLaterThan: resetAt
            )
        }()

        return QuotaPaceForecast(
            verdict: verdict,
            confidence: confidence,
            confidenceScore: confidenceScore,
            currentUsedPercent: actual,
            plannedUsedPercent: planned,
            projectedUsedPercent: projected,
            projectedUsedLowerPercent: lower,
            projectedUsedUpperPercent: upper,
            targetRemainingPercent: targetRemaining,
            runOutAt: runOutAt,
            completedCycleCount: completed.count,
            currentObservationCount: currentRanks.count,
            diagnostics: Diagnostics(
                recentProjectionUsedPercent: recentProjection,
                historicalProjectionUsedPercent: historicalProjection,
                behavioralProjectionUsedPercent: behavioralProjection,
                behavioralProgressPercent: behavioralProgress * 100,
                activityTrendMultiplier: trend,
                hasActivityTrendBaseline: trendResult.hasBaseline,
                observationCoveragePercent: observationCoverage * 100,
                historyCoveragePercent: historyCoverage * 100,
                freshnessPercent: freshness * 100,
                activityCoveragePercent: activityCoverage * 100,
                recentSampleCount: recent.sampleCount,
                comparableCycleCount: historicalAdditions.count
            )
        )
    }

    private struct RecentSlope {
        let rate: Double?
        let spread: Double
        let sampleCount: Int
    }

    private static func recentSlope(
        lane: ObservationLane,
        ranks: Range<Int>,
        profile: ActivityProfile
    ) -> RecentSlope {
        guard ranks.count >= 2 else { return RecentSlope(rate: nil, spread: 0, sampleCount: 0) }
        // The old shape materialised `Array(points.suffix(18))`; the pairs it
        // walked are the same, addressed by rank instead of copied out.
        let start = max(ranks.lowerBound, ranks.upperBound - 18)
        var slopes: [Double] = []
        slopes.reserveCapacity(ranks.upperBound - start)
        for rank in (start + 1)..<ranks.upperBound {
            let earlier = lane.index(atRank: rank - 1)
            let later = lane.index(atRank: rank)
            let delta = lane.points[later].usedPercent - lane.points[earlier].usedPercent
            guard delta >= 0, delta <= 45 else { continue }
            let activity = profile.weight(
                from: lane.points[earlier].sampledAt,
                to: lane.points[later].sampledAt
            )
            guard activity > 0.002 else { continue }
            slopes.append(delta / activity)
        }
        guard let rate = median(slopes) else { return RecentSlope(rate: nil, spread: 0, sampleCount: 0) }
        return RecentSlope(
            rate: rate,
            spread: medianAbsoluteDeviation(slopes) * 1.4826,
            sampleCount: slopes.count
        )
    }

    /// How much more each completed cycle consumed from the point it was as
    /// far along as the current one.
    ///
    /// This used to re-filter the whole observation lane once per cycle. On
    /// real data — a Claude five-hour bucket retains ~200 completed cycles and
    /// ~7 300 observations — that is ~1.5 M `FillTimelinePoint` copies per
    /// call, and the struct carries three `String`s, so each copy is six ARC
    /// operations. It ran inside a SwiftUI `body`.
    ///
    /// Each cycle's observations are a contiguous slice of the time-ordered
    /// lane, so the same answer comes from one binary search plus a scan
    /// bounded by that slice: linear in the lane, not in lane × cycles, and
    /// nothing is copied out of the array.
    ///
    /// Internal rather than private so `QuotaPaceForecastEquivalenceTests` can
    /// pin it against a verbatim copy of the retired algorithm.
    static func historicalRemainingUsage(
        cycles: [SubscriptionWindowSample],
        lane: ObservationLane,
        currentProgress: Double,
        profile: ActivityProfile
    ) -> [Double] {
        var additions: [Double] = []
        additions.reserveCapacity(cycles.count)
        for cycleIndex in cycles.indices {
            // `windowStart` tracks what the provider reported, and measurement
            // says to leave it alone. Several buckets refill far more often
            // than their stated window — two Codex weeklies have a median gap
            // of 57 hours against a 168-hour window — so a short span is
            // usually the truth, not a stale value. Checked against the
            // interval between observed refills, the stored start is right for
            // 86-100% of cycles on every bucket; reconstructing it from the
            // window length instead drops that to 14% on the worst.
            let cycleStart = cycles[cycleIndex].windowStart ?? cycles[cycleIndex].firstSeenAt
            let cycleEnd = cycles[cycleIndex].completedAt ?? cycles[cycleIndex].windowEnd
            guard cycleEnd > cycleStart else { continue }
            let total = max(0.001, profile.weight(from: cycleStart, to: cycleEnd))
            // Bounded by the last observation this cycle actually absorbed,
            // not by its end. The observation that detected the refill belongs
            // to the cycle that follows, and comparing timestamps cannot
            // separate them: `UsageFillTimelineStore.observe` and this store
            // are told separately and each takes its own `Date()`, so the
            // refill point is stamped a shade *before* `completedAt` and slips
            // through any end bound. `lastSeenAt` is the cycle's own answer to
            // "the last reading that was mine". Without it a 60% → 5% refill
            // contributed 55 points of consumption to a window that had
            // already finished.
            let observationEnd = cycles[cycleIndex].lastSeenAt
            var bestDistance = Double.infinity
            // `min(by:)` kept the *first* element of a tie in the order the
            // filter produced, which was the lane's own order. Ties are broken
            // on the original position for exactly that reason, so a caller
            // that hands `compute` an unsorted lane still gets the old answer.
            var bestOriginal = Int.max
            var bestUsed = 0.0
            var rank = lane.lowerBound(cycleStart)
            while rank < lane.count {
                let original = lane.index(atRank: rank)
                let sampledAt = lane.points[original].sampledAt
                if sampledAt > observationEnd { break }
                let progress = clamp(profile.weight(from: cycleStart, to: sampledAt) / total, 0, 1)
                let distance = abs(progress - currentProgress)
                if distance < bestDistance || (distance == bestDistance && original < bestOriginal) {
                    bestDistance = distance
                    bestOriginal = original
                    bestUsed = lane.points[original].usedPercent
                }
                rank += 1
            }
            if bestOriginal != Int.max, bestDistance <= 0.22 {
                additions.append(max(0, cycles[cycleIndex].peakUsedPercent - bestUsed))
            } else {
                additions.append(max(0, cycles[cycleIndex].peakUsedPercent * (1 - currentProgress)))
            }
        }
        return additions
    }

    /// Widest instant range this pass will ask the activity profile about, so
    /// the hour table can be built once instead of grown per cycle.
    private static func activitySpan(
        windowStart: Date,
        evaluationDate: Date,
        resetAt: Date,
        cycles: [SubscriptionWindowSample]
    ) -> (start: Date, end: Date) {
        var start = min(windowStart.addingTimeInterval(-300), evaluationDate)
        var end = max(resetAt, evaluationDate.addingTimeInterval(60))
        for index in cycles.indices {
            let cycleStart = cycles[index].windowStart ?? cycles[index].firstSeenAt
            let cycleEnd = max(cycles[index].completedAt ?? cycles[index].windowEnd, cycles[index].lastSeenAt)
            if cycleStart < start { start = cycleStart }
            if cycleEnd > end { end = cycleEnd }
        }
        return (start, end)
    }

    /// A read-only, time-ordered view over one bucket's observation lane.
    ///
    /// `QuotaService` keeps every lane sorted ascending by `sampledAt`
    /// (`applyInitialObservations` sorts, and `UsageFillTimelineStore` returns
    /// sorted points), so the common case builds no storage at all: `order` is
    /// `nil` and a rank *is* an index. Only a caller that hands `compute` an
    /// out-of-order array pays for one permutation — once, not once per cycle.
    ///
    /// Callers address points by *rank* (position in time order) and read
    /// fields through `points[index]`, which borrows the element rather than
    /// copying it out of the array.
    struct ObservationLane {
        let points: [FillTimelinePoint]
        /// Indices into `points` in time order, or `nil` when `points` is
        /// already in that order.
        private let order: [Int]?

        init(_ points: [FillTimelinePoint]) {
            self.points = points
            var ascending = true
            var index = 1
            while index < points.count {
                if points[index].sampledAt < points[index - 1].sampledAt {
                    ascending = false
                    break
                }
                index += 1
            }
            guard !ascending else {
                self.order = nil
                return
            }
            // Ties broken on the original position, so this is the stable
            // ordering the old `filter { … }.sorted { … }` produced.
            self.order = points.indices.sorted { lhs, rhs in
                let left = points[lhs].sampledAt
                let right = points[rhs].sampledAt
                if left == right { return lhs < rhs }
                return left < right
            }
        }

        var count: Int { points.count }

        @inline(__always)
        func index(atRank rank: Int) -> Int { order?[rank] ?? rank }

        @inline(__always)
        func sampledAt(atRank rank: Int) -> Date { points[index(atRank: rank)].sampledAt }

        /// First rank whose `sampledAt` is at or after `date`.
        func lowerBound(_ date: Date) -> Int {
            var low = 0
            var high = count
            while low < high {
                let middle = low + (high - low) / 2
                if sampledAt(atRank: middle) < date { low = middle + 1 } else { high = middle }
            }
            return low
        }

        /// First rank whose `sampledAt` is strictly after `date`.
        func upperBound(_ date: Date) -> Int {
            var low = 0
            var high = count
            while low < high {
                let middle = low + (high - low) / 2
                if sampledAt(atRank: middle) <= date { low = middle + 1 } else { high = middle }
            }
            return low
        }
    }

    private struct ActivityTrendResult {
        let multiplier: Double
        let hasBaseline: Bool
    }

    private static func activityTrend(
        _ days: [DailyCostPoint],
        now: Date,
        calendar: Calendar
    ) -> ActivityTrendResult {
        guard !days.isEmpty else { return ActivityTrendResult(multiplier: 1, hasBaseline: false) }
        let today = calendar.startOfDay(for: now)
        let recentStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let baselineStart = calendar.date(byAdding: .day, value: -27, to: today) ?? today
        let baselineEnd = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        let recentTotal = days.filter { $0.date >= recentStart && $0.date <= now }.reduce(0.0) { $0 + Double($1.totalTokens) }
        let baselineTotal = days.filter { $0.date >= baselineStart && $0.date < baselineEnd }.reduce(0.0) { $0 + Double($1.totalTokens) }
        guard baselineTotal > 0 else { return ActivityTrendResult(multiplier: 1, hasBaseline: false) }
        let recentAverage = recentTotal / 7
        let baselineAverage = baselineTotal / 21
        return ActivityTrendResult(
            multiplier: clamp(recentAverage / baselineAverage, 0.5, 1.8),
            hasBaseline: true
        )
    }

    /// Time-of-week activity weighting, evaluated as the integral of a per-hour
    /// weight curve.
    ///
    /// `weight(from:to:)` is asked for once per completed cycle **and** once per
    /// stored observation by `historicalRemainingUsage`, and the profile is
    /// rebuilt per bucket. Walking the window hour by hour therefore cost two
    /// `Calendar` round trips per hour of every window it was asked about —
    /// six figures of them for a monthly bucket, sometimes from inside a
    /// SwiftUI `body`. This version answers a query with integer arithmetic
    /// against a table built once per profile.
    ///
    /// **The hour grid, and where it approximates.** Blocks are laid out
    /// uniformly 3600s apart, phased so a boundary lands on a local hour
    /// boundary at the table's anchor. That is exact, not approximate, for
    /// every zone whose DST shift is a whole hour: changing the UTC offset by
    /// 3600 leaves `offset % 3600` alone, so local hour boundaries stay on the
    /// same epoch grid and only their (weekday, hour) *labels* move — which is
    /// all the weight depends on. A spring-forward day simply has no block
    /// labelled 02:00, and a fall-back day has two labelled 01:00; both are the
    /// honest reading of a weekday×hour habit curve. Only the half-hour DST
    /// oddities (Lord Howe Island) shift the grid: there a block straddles two
    /// local hours across the transition and takes the weight of the hour its
    /// start falls in — at most half an hour of misattribution, twice a year,
    /// on a curve whose entire job is to say "this person tends to work around
    /// this time of week".
    final class ActivityProfile {
        let calendar: Calendar

        /// Flattened 7×24 weights, or `nil` when the heatmap carries no usable
        /// shape and every hour weighs the same. The uniform case then needs no
        /// table at all — the integral is just the elapsed duration.
        private let cellWeights: [Double]?
        /// Offset of every block boundary from the epoch, in `[0, 3600)`.
        /// Resolved on the first table build and then frozen, so growing the
        /// table never moves the grid underneath cached values.
        private var phase: TimeInterval?
        private var table: HourTable?

        /// Widest span one table may cover. Real spans are bounded by the
        /// retention horizon (weeks), so this only exists to keep a corrupt
        /// stored date from asking for a hundred-million-entry array; wider
        /// queries are answered chunk by chunk instead.
        private static let maximumTableSeconds: TimeInterval = 400 * 86_400
        /// Slack added around a requested span so the usual sequence of queries
        /// (this window, then each older cycle) grows the table a few times
        /// rather than once per query.
        private static let tablePaddingSeconds: TimeInterval = 2 * 86_400

        init(heatmap: UsageHeatmap?, calendar: Calendar) {
            self.calendar = calendar
            // Scanned rather than `flatMap { $0 }.max()`: the flatten
            // allocated a 168-element array on a path the forecast runs per
            // bucket per data generation.
            var peak = 0
            if let heatmap {
                for row in heatmap.cells {
                    for value in row where value > peak { peak = value }
                }
            }
            let maximum = Double(peak)
            guard let heatmap, heatmap.totalTokens > 0, maximum > 0 else {
                self.cellWeights = nil
                return
            }
            var weights = [Double](repeating: 1, count: 7 * 24)
            for weekday in 0..<7 where heatmap.cells.indices.contains(weekday) {
                let row = heatmap.cells[weekday]
                for hour in 0..<24 where row.indices.contains(hour) {
                    let normalized = sqrt(Double(row[hour]) / maximum)
                    // Laplace-like floor prevents an empty historical cell from
                    // asserting that future work there is impossible.
                    weights[weekday * 24 + hour] = 0.15 + normalized * 0.85
                }
            }
            self.cellWeights = weights
        }

        /// Build the hour table once for a span the caller is about to walk.
        ///
        /// The table grows on demand, which is right for a single query and
        /// wrong for a pass that walks two hundred completed cycles from
        /// newest to oldest: each older cycle fell outside the table and paid
        /// for a rebuild of everything already covered. A span wider than one
        /// table is left to the chunked path in `weight(from:to:)`, which is
        /// what keeps a corrupt stored date from asking for a
        /// hundred-million-entry array.
        func prepare(from start: Date, to end: Date) {
            guard cellWeights != nil else { return }
            let lower = start.timeIntervalSince1970
            let upper = end.timeIntervalSince1970
            guard upper >= lower, upper - lower <= Self.maximumTableSeconds else { return }
            _ = table(covering: lower, upper)
        }

        func weight(from start: Date, to end: Date) -> Double {
            guard end > start else { return 0 }
            guard cellWeights != nil else {
                return end.timeIntervalSince(start) / 3_600
            }
            let upper = end.timeIntervalSince1970
            var lower = start.timeIntervalSince1970
            var total = 0.0
            while lower < upper {
                let chunkEnd = min(upper, lower + Self.maximumTableSeconds)
                total += table(covering: lower, chunkEnd).integral(from: lower, to: chunkEnd)
                lower = chunkEnd
            }
            return total
        }

        func date(after start: Date, accumulating targetWeight: Double, noLaterThan end: Date) -> Date? {
            guard targetWeight > 0, end > start else { return nil }
            let step: TimeInterval = end.timeIntervalSince(start) <= 6 * 3_600 ? 5 * 60 : 30 * 60
            var cursor = start
            var accumulated = 0.0
            while cursor < end {
                let next = min(end, cursor.addingTimeInterval(step))
                let weight = hourWeight(at: cursor) * next.timeIntervalSince(cursor) / 3_600
                if accumulated + weight >= targetWeight, weight > 0 {
                    let fraction = (targetWeight - accumulated) / weight
                    return cursor.addingTimeInterval(next.timeIntervalSince(cursor) * clamp(fraction, 0, 1))
                }
                accumulated += weight
                cursor = next
            }
            return nil
        }

        func hourWeight(at date: Date) -> Double {
            guard cellWeights != nil else { return 1 }
            let time = date.timeIntervalSince1970
            return table(covering: time, time).weight(at: time)
        }

        // MARK: - Hour table

        /// Per-block weights with prefix sums, so a query costs two block
        /// lookups and one subtraction whatever its span.
        private struct HourTable {
            let phase: TimeInterval
            let firstIndex: Int
            let weights: [Double]
            /// `cumulative[i]` is the total weight, in weight-hours, of the
            /// blocks `[firstIndex, firstIndex + i)`.
            let cumulative: [Double]

            func index(for time: TimeInterval) -> Int {
                Int(((time - phase) / 3_600).rounded(.down))
            }

            func blockStart(_ index: Int) -> TimeInterval {
                Double(index) * 3_600 + phase
            }

            func covers(_ time: TimeInterval) -> Bool {
                let index = index(for: time) - firstIndex
                return index >= 0 && index < weights.count
            }

            func weight(at time: TimeInterval) -> Double {
                let index = index(for: time) - firstIndex
                guard weights.indices.contains(index) else { return 1 }
                return weights[index]
            }

            func integral(from lower: TimeInterval, to upper: TimeInterval) -> Double {
                guard upper > lower else { return 0 }
                let lowerBlock = index(for: lower)
                let upperBlock = index(for: upper)
                if lowerBlock == upperBlock {
                    return weight(at: lower) * (upper - lower) / 3_600
                }
                var total = weight(at: lower) * (blockStart(lowerBlock + 1) - lower) / 3_600
                total += weight(at: upper) * (upper - blockStart(upperBlock)) / 3_600
                let from = lowerBlock + 1 - firstIndex
                let to = upperBlock - firstIndex
                if to > from, cumulative.indices.contains(from), cumulative.indices.contains(to) {
                    total += cumulative[to] - cumulative[from]
                }
                return total
            }
        }

        private func table(covering lower: TimeInterval, _ upper: TimeInterval) -> HourTable {
            if let table, table.covers(lower), table.covers(upper) { return table }
            let phase = self.phase ?? Self.hourPhase(
                for: Date(timeIntervalSince1970: lower),
                timeZone: calendar.timeZone
            )
            self.phase = phase

            var from = min(lower, upper) - Self.tablePaddingSeconds
            var to = max(lower, upper) + Self.tablePaddingSeconds
            // Grow to cover what the table already answered so a query that
            // walks backwards through history does not thrash the build.
            if let table {
                let existingFrom = table.blockStart(table.firstIndex)
                let existingTo = table.blockStart(table.firstIndex + table.weights.count)
                if max(to, existingTo) - min(from, existingFrom) <= Self.maximumTableSeconds {
                    from = min(from, existingFrom)
                    to = max(to, existingTo)
                }
            }
            let built = buildTable(phase: phase, from: from, to: to)
            table = built
            return built
        }

        private func buildTable(phase: TimeInterval, from: TimeInterval, to: TimeInterval) -> HourTable {
            let firstIndex = Int(((from - phase) / 3_600).rounded(.down))
            let lastIndex = Int(((to - phase) / 3_600).rounded(.down))
            let count = max(1, lastIndex - firstIndex + 1)
            let cells = cellWeights ?? [Double](repeating: 1, count: 7 * 24)

            let timeZone = calendar.timeZone
            let anchorStart = Double(firstIndex) * 3_600 + phase
            let anchorDate = Date(timeIntervalSince1970: anchorStart)
            var offset = timeZone.secondsFromGMT(for: anchorDate)
            // Weekday numbering is read off the calendar once and then advanced
            // by whole days, instead of hardcoding "epoch day zero was a
            // Thursday" — a non-Gregorian calendar still lands on the heatmap
            // row it was written with.
            let anchorWeekday = max(0, min(6, calendar.component(.weekday, from: anchorDate) - 1))
            let anchorDay = Self.floorDiv(Int(anchorStart.rounded(.down)) + offset, 86_400)
            var nextTransition = timeZone
                .nextDaylightSavingTimeTransition(after: anchorDate)?
                .timeIntervalSince1970

            var weights = [Double](repeating: 1, count: count)
            var cumulative = [Double](repeating: 0, count: count + 1)
            for step in 0..<count {
                let blockStart = Double(firstIndex + step) * 3_600 + phase
                while let transition = nextTransition, blockStart >= transition {
                    offset = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: blockStart))
                    nextTransition = timeZone
                        .nextDaylightSavingTimeTransition(after: Date(timeIntervalSince1970: transition))?
                        .timeIntervalSince1970
                }
                let local = Int(blockStart.rounded(.down)) + offset
                let hour = Self.floorMod(Self.floorDiv(local, 3_600), 24)
                let weekday = Self.floorMod(
                    anchorWeekday + Self.floorDiv(local, 86_400) - anchorDay,
                    7
                )
                weights[step] = cells[weekday * 24 + hour]
                cumulative[step + 1] = cumulative[step] + weights[step]
            }
            return HourTable(
                phase: phase,
                firstIndex: firstIndex,
                weights: weights,
                cumulative: cumulative
            )
        }

        /// Where the local hour boundaries sit on the epoch grid, for the
        /// offset in force at `date`. Zones offset by a half or quarter hour
        /// (India, Nepal) land on a non-zero phase; that is the point.
        private static func hourPhase(for date: Date, timeZone: TimeZone) -> TimeInterval {
            TimeInterval(floorMod(-timeZone.secondsFromGMT(for: date), 3_600))
        }

        private static func floorDiv(_ value: Int, _ divisor: Int) -> Int {
            let quotient = value / divisor
            return (value % divisor != 0 && (value < 0) != (divisor < 0)) ? quotient - 1 : quotient
        }

        private static func floorMod(_ value: Int, _ divisor: Int) -> Int {
            let remainder = value % divisor
            return remainder < 0 ? remainder + divisor : remainder
        }
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func medianAbsoluteDeviation(_ values: [Double]) -> Double {
        guard let center = median(values) else { return 0 }
        return median(values.map { abs($0 - center) }) ?? 0
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
