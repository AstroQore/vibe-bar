import Foundation

/// A forecast interval projected onto the finite 0...100 quota-bar axis.
///
/// Forecast demand may legitimately exceed 100%. This type keeps that
/// overflow information while guaranteeing the visible marker stays inside
/// the visible confidence band in both Used and Remaining display modes.
public struct QuotaForecastBarProjection: Sendable, Equatable {
    public let lowerPercent: Double
    public let upperPercent: Double
    public let medianPercent: Double
    public let clipsLowerBound: Bool
    public let clipsUpperBound: Bool
    public let hasUncertainty: Bool

    public init(
        projectedUsedLowerPercent: Double,
        projectedUsedUpperPercent: Double,
        projectedUsedMedianPercent: Double,
        displayMode: DisplayMode
    ) {
        let usedLower = min(projectedUsedLowerPercent, projectedUsedUpperPercent)
        let usedUpper = max(projectedUsedLowerPercent, projectedUsedUpperPercent)

        let displayedLower: Double
        let displayedUpper: Double
        let displayedMedian: Double
        switch displayMode {
        case .used:
            displayedLower = usedLower
            displayedUpper = usedUpper
            displayedMedian = projectedUsedMedianPercent
        case .remaining:
            displayedLower = 100 - usedUpper
            displayedUpper = 100 - usedLower
            displayedMedian = 100 - projectedUsedMedianPercent
        }

        // Defensive inclusion keeps a malformed or rounded provider interval
        // from ever drawing its median marker outside the confidence band.
        let rawLower = min(displayedLower, displayedUpper, displayedMedian)
        let rawUpper = max(displayedLower, displayedUpper, displayedMedian)
        let visibleLower = Self.clamp(rawLower)
        let visibleUpper = Self.clamp(rawUpper)

        lowerPercent = visibleLower
        upperPercent = visibleUpper
        medianPercent = min(max(Self.clamp(displayedMedian), visibleLower), visibleUpper)
        clipsLowerBound = rawLower < 0
        clipsUpperBound = rawUpper > 100
        hasUncertainty = rawUpper > rawLower
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 100)
    }
}
