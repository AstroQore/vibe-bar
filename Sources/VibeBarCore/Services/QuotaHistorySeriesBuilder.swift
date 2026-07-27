import Foundation

/// One point on the actual or pace remaining-percent line.
public struct QuotaHistorySample: Sendable, Equatable {
    public let time: Date
    public let remainingPercent: Double

    public init(time: Date, remainingPercent: Double) {
        self.time = time
        self.remainingPercent = remainingPercent
    }
}

/// One point on the forecast line, with the band around it.
///
/// `lowerRemainingPercent` is the pessimistic edge (most demand projected,
/// least quota left) and `upperRemainingPercent` the optimistic one — the same
/// orientation as `QuotaPaceForecast.projectedRemainingRange`, flipped relative
/// to the stored *used* bounds.
public struct QuotaHistoryForecastSample: Sendable, Equatable {
    public let time: Date
    public let remainingPercent: Double
    public let lowerRemainingPercent: Double
    public let upperRemainingPercent: Double

    public init(
        time: Date,
        remainingPercent: Double,
        lowerRemainingPercent: Double,
        upperRemainingPercent: Double
    ) {
        self.time = time
        self.remainingPercent = remainingPercent
        self.lowerRemainingPercent = lowerRemainingPercent
        self.upperRemainingPercent = upperRemainingPercent
    }
}

/// The three lines a quota history chart draws, already split into drawable
/// segments.
///
/// Segments matter because a single continuous line across a reset would draw a
/// vertical jump that reads as usage, and a line across a week the app was not
/// running would invent data that was never observed.
public struct QuotaHistorySeries: Sendable, Equatable {
    /// Observed remaining quota (`100 - usedPercent`).
    public let actual: [[QuotaHistorySample]]
    /// Time-only expected remaining, replayed from each observation's own
    /// window. This is the "if you burned evenly" reference line.
    public let pace: [[QuotaHistorySample]]
    /// Remaining quota the forecast projected at reset, as recorded at the
    /// time of each observation.
    public let forecast: [[QuotaHistoryForecastSample]]
    /// Distinct reset instants inside the requested range, oldest first.
    public let resetBoundaries: [Date]

    public static let empty = QuotaHistorySeries(
        actual: [],
        pace: [],
        forecast: [],
        resetBoundaries: []
    )

    public init(
        actual: [[QuotaHistorySample]],
        pace: [[QuotaHistorySample]],
        forecast: [[QuotaHistoryForecastSample]],
        resetBoundaries: [Date]
    ) {
        self.actual = actual
        self.pace = pace
        self.forecast = forecast
        self.resetBoundaries = resetBoundaries
    }

    public var isEmpty: Bool {
        actual.isEmpty && pace.isEmpty && forecast.isEmpty
    }
}

/// Turns stored timeline points into chart-ready series.
///
/// Pure and synchronous: the caller pulls points out of the actor-isolated
/// stores once, then reshapes them here as the visible range changes.
public enum QuotaHistorySeriesBuilder {
    /// A gap larger than this many slot widths means coverage actually stopped
    /// (app quit, machine asleep) rather than a sample merely being due.
    private static let gapSlotMultiplier: Double = 2

    /// Build the three series for one `(accountId, tool, bucketId)`.
    ///
    /// Inputs must already be scoped to a single bucket — the builder filters
    /// by time only, never by account or bucket, so a caller that passes mixed
    /// points gets meaningless segmentation rather than a silent split.
    public static func build(
        fillPoints: [FillTimelinePoint],
        forecastPoints: [ForecastTimelinePoint] = [],
        range: ClosedRange<Date>
    ) -> QuotaHistorySeries {
        let fills = fillPoints
            .filter { range.contains($0.sampledAt) }
            .sorted { $0.sampledAt < $1.sampledAt }
        let forecasts = forecastPoints
            .filter { range.contains($0.sampledAt) }
            .sorted { $0.sampledAt < $1.sampledAt }

        let fillSegments = segmented(
            fills,
            time: { $0.sampledAt },
            resetAt: { $0.resetAt },
            windowSeconds: { $0.rawWindowSeconds }
        )
        let forecastSegments = segmented(
            forecasts,
            time: { $0.sampledAt },
            resetAt: { $0.resetAt },
            windowSeconds: { $0.rawWindowSeconds }
        )

        let actual = fillSegments.map { segment in
            segment.map {
                QuotaHistorySample(
                    time: $0.sampledAt,
                    remainingPercent: clampPercent(100 - $0.usedPercent)
                )
            }
        }

        // Points without reset metadata cannot be replayed; they thin a pace
        // segment out rather than splitting it, so the actual and pace lines
        // stay segment-aligned.
        let pace = fillSegments.compactMap { segment -> [QuotaHistorySample]? in
            let samples = segment.compactMap { point -> QuotaHistorySample? in
                guard let resetAt = point.resetAt,
                      let windowSeconds = point.rawWindowSeconds,
                      windowSeconds > 0
                else { return nil }
                let expected = expectedUsedPercent(
                    at: point.sampledAt,
                    resetAt: resetAt,
                    windowSeconds: windowSeconds
                )
                return QuotaHistorySample(
                    time: point.sampledAt,
                    remainingPercent: clampPercent(100 - expected)
                )
            }
            return samples.isEmpty ? nil : samples
        }

        let forecast = forecastSegments.map { segment in
            segment.map {
                QuotaHistoryForecastSample(
                    time: $0.sampledAt,
                    remainingPercent: clampPercent(100 - $0.projectedUsedPercent),
                    lowerRemainingPercent: clampPercent(100 - $0.projectedUsedUpperPercent),
                    upperRemainingPercent: clampPercent(100 - $0.projectedUsedLowerPercent)
                )
            }
        }

        return QuotaHistorySeries(
            actual: actual,
            pace: pace,
            forecast: forecast,
            resetBoundaries: resetBoundaries(
                fillPoints: fillPoints,
                forecastPoints: forecastPoints,
                range: range
            )
        )
    }

    /// Elapsed-time expectation for one observation, replayed from the window
    /// that observation itself recorded. Mirrors `UsagePace.expectedUsedPercent`
    /// without the live-only guards — a historical sample past its reset is a
    /// normal thing to draw.
    public static func expectedUsedPercent(
        at time: Date,
        resetAt: Date,
        windowSeconds: Int
    ) -> Double {
        guard windowSeconds > 0 else { return 0 }
        let duration = TimeInterval(windowSeconds)
        let elapsed = duration - resetAt.timeIntervalSince(time)
        return clampPercent(elapsed / duration * 100)
    }

    // MARK: - Private

    private static func resetBoundaries(
        fillPoints: [FillTimelinePoint],
        forecastPoints: [ForecastTimelinePoint],
        range: ClosedRange<Date>
    ) -> [Date] {
        // Deliberately scans the unfiltered inputs: a sample taken before the
        // visible range can still carry a reset that lands inside it.
        var boundaries: Set<Date> = []
        for point in fillPoints {
            if let resetAt = point.resetAt, range.contains(resetAt) { boundaries.insert(resetAt) }
        }
        for point in forecastPoints {
            if let resetAt = point.resetAt, range.contains(resetAt) { boundaries.insert(resetAt) }
        }
        return boundaries.sorted()
    }

    /// Split a time-sorted run of points wherever the underlying window changed
    /// or coverage lapsed.
    private static func segmented<Element>(
        _ elements: [Element],
        time: (Element) -> Date,
        resetAt: (Element) -> Date?,
        windowSeconds: (Element) -> Int?
    ) -> [[Element]] {
        var segments: [[Element]] = []
        var current: [Element] = []
        var previous: Element?
        for element in elements {
            if let previous {
                let windowChanged = resetAt(previous) != resetAt(element)
                let slot = UsageTimelineSlotPolicy.slotSeconds(
                    windowSeconds: windowSeconds(previous)
                )
                let gap = time(element).timeIntervalSince(time(previous))
                if windowChanged || gap > slot * gapSlotMultiplier {
                    if !current.isEmpty { segments.append(current) }
                    current = []
                }
            }
            current.append(element)
            previous = element
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    private static func clampPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(100, max(0, value))
    }
}
