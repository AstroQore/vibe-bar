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

    public var verdictLabel: String {
        switch verdict {
        case .enough: "Enough"
        case .surplus: "Surplus"
        case .watch: "Watch"
        case .atRisk: "At risk"
        case .learning: "Learning"
        }
    }

    public var confidenceLabel: String {
        switch confidence {
        case .learning: "Learning"
        case .medium: "Medium confidence"
        case .high: "High confidence"
        }
    }

    public var resetSummary: String {
        let left = Int(projectedRemainingPercent.rounded())
        switch verdict {
        case .enough:
            return "Forecast \(left)% left at reset"
        case .surplus:
            return "Likely surplus · forecast \(left)% left"
        case .watch:
            return "May run short · forecast \(left)% left"
        case .atRisk:
            return "Likely to run out before reset"
        case .learning:
            return "Learning your pattern · about \(left)% left"
        }
    }

    public var guidanceSummary: String {
        let target = Int(targetRemainingPercent.rounded())
        let unused = Int(potentialUnusedPercent.rounded())
        if verdict == .atRisk { return "Slow down or shift work to another quota" }
        if verdict == .watch { return "Recent usage is above the safe range" }
        if verdict == .surplus {
            return "About \(unused)% likely unused beyond the \(target)% safety target"
        }
        if unused >= 3 {
            return "Target \(target)% left · about \(unused)% available"
        }
        return "Within the \(target)% safety target"
    }

    public static func compute(
        bucket: QuotaBucket,
        observations: [FillTimelinePoint],
        cycles: [SubscriptionWindowSample],
        activityHeatmap: UsageHeatmap? = nil,
        dailyActivity: [DailyCostPoint] = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> QuotaPaceForecast? {
        guard let resetAt = bucket.resetAt,
              let rawWindowSeconds = bucket.rawWindowSeconds,
              rawWindowSeconds > 0
        else { return nil }

        let duration = TimeInterval(rawWindowSeconds)
        let remainingTime = resetAt.timeIntervalSince(now)
        guard remainingTime > 0, remainingTime <= duration * 1.1 else { return nil }

        let windowStart = resetAt.addingTimeInterval(-duration)
        let actual = clamp(bucket.usedPercent, 0, 100)
        let profile = ActivityProfile(heatmap: activityHeatmap, calendar: calendar)
        let totalActivity = max(0.001, profile.weight(from: windowStart, to: resetAt))
        let elapsedActivity = clamp(profile.weight(from: windowStart, to: now), 0, totalActivity)
        let futureActivity = max(0, totalActivity - elapsedActivity)
        let behavioralProgress = clamp(elapsedActivity / totalActivity, 0, 1)

        let currentPoints = observations
            .filter { $0.sampledAt >= windowStart.addingTimeInterval(-300) && $0.sampledAt <= now.addingTimeInterval(60) }
            .sorted { $0.sampledAt < $1.sampledAt }

        let recent = recentSlope(points: currentPoints, profile: profile)
        let completed = cycles.filter(\.isCompleted)
        let historicalAdditions = historicalRemainingUsage(
            cycles: completed,
            observations: observations,
            currentProgress: behavioralProgress,
            profile: profile
        )
        let trendResult = activityTrend(dailyActivity, now: now, calendar: calendar)
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
            guard let first = currentPoints.first, let last = currentPoints.last else { return 0 }
            let span = max(0, last.sampledAt.timeIntervalSince(first.sampledAt))
            let elapsed = max(1, now.timeIntervalSince(windowStart))
            let countScore = min(1, Double(currentPoints.count) / 10)
            let spanScore = min(1, span / elapsed)
            return countScore * 0.65 + spanScore * 0.35
        }()
        let historyCoverage = min(1, Double(completed.count) / 5)
        let freshness: Double = {
            guard let last = currentPoints.last else { return 0 }
            let naturalSlot: TimeInterval = rawWindowSeconds <= 6 * 3_600 ? 5 * 60 : 3_600
            return clamp(1 - now.timeIntervalSince(last.sampledAt) / max(60, naturalSlot * 3), 0, 1)
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
            guard upper >= 100, actual < 100 else { return actual >= 100 ? now : nil }
            if let recentRate = recent.rate, recentRate > 0 {
                let neededWeight = (100 - actual) / recentRate
                return profile.date(after: now, accumulating: neededWeight, noLaterThan: resetAt)
            }
            let additional = projected - actual
            guard additional > 0 else { return nil }
            let fraction = clamp((100 - actual) / additional, 0, 1)
            return profile.date(after: now, accumulating: futureActivity * fraction, noLaterThan: resetAt)
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
            currentObservationCount: currentPoints.count,
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

    private static func recentSlope(points: [FillTimelinePoint], profile: ActivityProfile) -> RecentSlope {
        guard points.count >= 2 else { return RecentSlope(rate: nil, spread: 0, sampleCount: 0) }
        let recentPoints = Array(points.suffix(18))
        var slopes: [Double] = []
        for pair in zip(recentPoints, recentPoints.dropFirst()) {
            let delta = pair.1.usedPercent - pair.0.usedPercent
            guard delta >= 0, delta <= 45 else { continue }
            let activity = profile.weight(from: pair.0.sampledAt, to: pair.1.sampledAt)
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

    private static func historicalRemainingUsage(
        cycles: [SubscriptionWindowSample],
        observations: [FillTimelinePoint],
        currentProgress: Double,
        profile: ActivityProfile
    ) -> [Double] {
        cycles.compactMap { cycle in
            let cycleStart = cycle.windowStart ?? cycle.firstSeenAt
            let cycleEnd = cycle.completedAt ?? cycle.windowEnd
            guard cycleEnd > cycleStart else { return nil }
            let total = max(0.001, profile.weight(from: cycleStart, to: cycleEnd))
            let matching = observations
                .filter { $0.sampledAt >= cycleStart && $0.sampledAt <= cycleEnd }
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

    private struct ActivityProfile {
        let heatmap: UsageHeatmap?
        let calendar: Calendar
        let maximumCell: Double

        init(heatmap: UsageHeatmap?, calendar: Calendar) {
            self.heatmap = heatmap
            self.calendar = calendar
            self.maximumCell = Double(heatmap?.cells.flatMap { $0 }.max() ?? 0)
        }

        func weight(from start: Date, to end: Date) -> Double {
            guard end > start else { return 0 }
            var cursor = start
            var total = 0.0
            while cursor < end {
                let nextHour = calendar.date(byAdding: .hour, value: 1, to: calendar.dateInterval(of: .hour, for: cursor)?.start ?? cursor)
                    ?? cursor.addingTimeInterval(3_600)
                let next = min(end, max(cursor.addingTimeInterval(60), nextHour))
                let hours = next.timeIntervalSince(cursor) / 3_600
                total += hourWeight(at: cursor) * hours
                cursor = next
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

        private func hourWeight(at date: Date) -> Double {
            guard let heatmap, heatmap.totalTokens > 0, maximumCell > 0 else { return 1 }
            let weekday = max(0, min(6, calendar.component(.weekday, from: date) - 1))
            let hour = max(0, min(23, calendar.component(.hour, from: date)))
            guard heatmap.cells.indices.contains(weekday), heatmap.cells[weekday].indices.contains(hour) else { return 1 }
            let normalized = sqrt(Double(heatmap.cells[weekday][hour]) / maximumCell)
            // Laplace-like floor prevents an empty historical cell from
            // asserting that future work there is impossible.
            return 0.15 + normalized * 0.85
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
