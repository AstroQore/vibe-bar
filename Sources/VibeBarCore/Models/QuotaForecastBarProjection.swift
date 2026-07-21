import Foundation

/// A forecast interval projected onto the finite 0...100 quota-bar axis.
///
/// Forecast demand may legitimately exceed 100%. This type keeps that
/// overflow information while guaranteeing the visible marker stays inside
/// the visible confidence band in both Used and Remaining display modes.
public struct QuotaForecastBarProjection: Sendable, Equatable {
    public let displayMode: DisplayMode
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
        self.displayMode = displayMode
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

    /// Resolves the visible interval independently from the current fill.
    /// `overlapPercent` is only the portion that receives the mixed bridge;
    /// it never shortens `widthPercent`, so the interval may extend freely
    /// beyond the actual-fill endpoint.
    public func confidenceBandLayout(
        actualDisplayedPercent: Double,
        minimumVisibleWidthPercent: Double,
        contactTolerancePercent: Double = 0.1,
        axisPileupThresholdPercent: Double = 12
    ) -> QuotaForecastBandLayout {
        let minimumWidth = min(max(minimumVisibleWidthPercent, 0), 100)
        let naturalWidth = max(0, upperPercent - lowerPercent)
        let bandWidth: Double
        let start: Double

        if naturalWidth >= minimumWidth {
            bandWidth = naturalWidth
            start = lowerPercent
        } else {
            bandWidth = minimumWidth
            if lowerPercent <= 0 {
                start = 0
            } else if upperPercent >= 100 {
                start = max(0, 100 - bandWidth)
            } else {
                let center = (lowerPercent + upperPercent) / 2
                start = min(max(center - bandWidth / 2, 0), 100 - bandWidth)
            }
        }

        let actualEnd = min(max(actualDisplayedPercent, 0), 100)
        let overlap = max(0, min(bandWidth, actualEnd - start))
        let tolerance = max(0, contactTolerancePercent)
        let pileupThreshold = min(max(axisPileupThresholdPercent, 0), 100)
        let style: QuotaForecastBandStyle

        if actualEnd <= pileupThreshold,
           upperPercent <= pileupThreshold,
           medianPercent <= pileupThreshold
        {
            // Near the lower axis, the current fill, interval and median can
            // collapse into only a handful of pixels. Use one translucent,
            // fully outlined pill in both display modes so all boundaries
            // remain legible without adding an artificial gap.
            style = .outlinedTint
        } else if displayMode == .used,
                  abs(actualEnd - lowerPercent) <= tolerance
        {
            // The interval starts exactly where observed usage ends. A small
            // visual cap overlap is cleaner than a dark contact seam.
            style = .softJoin
        } else if displayMode == .used,
                  actualEnd > lowerPercent + tolerance,
                  actualEnd < upperPercent - tolerance
        {
            // Observed usage ends inside the interval. Preserve the interval's
            // rounded lower bound and mark only the actual endpoint with the
            // curved seam.
            style = .curvedSeam
        } else {
            style = .opaque
        }

        let showsGapConnector = displayMode == .used
            && style == .opaque
            && start > actualEnd + tolerance

        return QuotaForecastBandLayout(
            startPercent: start,
            widthPercent: bandWidth,
            overlapPercent: overlap,
            style: style,
            showsGapConnector: showsGapConnector
        )
    }
}

public enum QuotaForecastBandStyle: Sendable, Equatable {
    case opaque
    case softJoin
    case curvedSeam
    case outlinedTint
}

public struct QuotaForecastBandLayout: Sendable, Equatable {
    public let startPercent: Double
    public let widthPercent: Double
    public let overlapPercent: Double
    public let style: QuotaForecastBandStyle
    public let showsGapConnector: Bool

    public init(
        startPercent: Double,
        widthPercent: Double,
        overlapPercent: Double,
        style: QuotaForecastBandStyle,
        showsGapConnector: Bool
    ) {
        self.startPercent = startPercent
        self.widthPercent = widthPercent
        self.overlapPercent = overlapPercent
        self.style = style
        self.showsGapConnector = showsGapConnector
    }
}
