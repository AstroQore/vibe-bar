import Foundation

/// A navigable visible time range inside a fixed domain.
///
/// The history charts share one interaction model: the full data extent is the
/// *domain*, the user sees a *visible* sub-range, and every gesture — drag to
/// pan, pinch to zoom, tap a preset span — maps to one operation here. Each
/// operation clamps back inside the domain and respects `minimumSpan`, so the
/// view layer never re-derives the same edge cases (and never ends up scrolled
/// into empty space past the newest sample).
///
/// Pure `Date`/`TimeInterval` arithmetic: no calendar, no formatting, no
/// timezone assumptions.
public struct ChartTimeWindow: Equatable, Sendable {
    /// Oldest instant the user can scroll to.
    public private(set) var domainStart: Date
    /// Newest instant the user can scroll to.
    public private(set) var domainEnd: Date
    /// Shortest span the user may zoom to. Automatically capped at the domain
    /// span — a two-hour domain cannot enforce a one-day floor.
    public private(set) var minimumSpan: TimeInterval
    public private(set) var visibleStart: Date
    public private(set) var visibleEnd: Date

    public init(
        domainStart: Date,
        domainEnd: Date,
        minimumSpan: TimeInterval,
        visibleStart: Date,
        visibleEnd: Date
    ) {
        self.domainStart = domainStart
        self.domainEnd = max(domainStart, domainEnd)
        self.minimumSpan = max(0, minimumSpan)
        self.visibleStart = visibleStart
        self.visibleEnd = max(visibleStart, visibleEnd)
        self = clamped()
    }

    /// Start at the newest edge showing `visibleSpan` worth of history — the
    /// state a freshly opened chart wants.
    public init(
        domainStart: Date,
        domainEnd: Date,
        minimumSpan: TimeInterval,
        visibleSpan: TimeInterval
    ) {
        let end = max(domainStart, domainEnd)
        self.init(
            domainStart: domainStart,
            domainEnd: end,
            minimumSpan: minimumSpan,
            visibleStart: end.addingTimeInterval(-max(0, visibleSpan)),
            visibleEnd: end
        )
    }

    // MARK: - Derived geometry

    public var domainSpan: TimeInterval { domainEnd.timeIntervalSince(domainStart) }
    public var visibleSpan: TimeInterval { visibleEnd.timeIntervalSince(visibleStart) }

    /// `minimumSpan` as it can actually be enforced in this domain.
    public var effectiveMinimumSpan: TimeInterval { min(minimumSpan, domainSpan) }

    public var visibleRange: ClosedRange<Date> { visibleStart...visibleEnd }
    public var domainRange: ClosedRange<Date> { domainStart...domainEnd }
    public var visibleMidpoint: Date { visibleStart.addingTimeInterval(visibleSpan / 2) }

    public var isAtDomainStart: Bool { visibleStart <= domainStart }
    public var isAtDomainEnd: Bool { visibleEnd >= domainEnd }
    public var coversDomain: Bool { isAtDomainStart && isAtDomainEnd }

    /// How far into the domain the visible range sits, 0 (oldest) to 1
    /// (newest). Useful for positioning a scrubber thumb.
    public var scrollProgress: Double {
        let slack = domainSpan - visibleSpan
        guard slack > 0 else { return 1 }
        return min(1, max(0, visibleStart.timeIntervalSince(domainStart) / slack))
    }

    // MARK: - Pure operations

    /// Pull the visible range back inside the domain, widening or narrowing it
    /// to satisfy `minimumSpan` and the domain span. Shifts before it squeezes,
    /// so panning past an edge parks against the edge instead of zooming.
    public func clamped() -> ChartTimeWindow {
        var window = self
        let domain = domainSpan
        guard domain > 0 else {
            window.visibleStart = domainStart
            window.visibleEnd = domainStart
            return window
        }
        let span = min(max(visibleSpan, effectiveMinimumSpan), domain)
        var start = visibleStart
        if start.addingTimeInterval(span) > domainEnd {
            start = domainEnd.addingTimeInterval(-span)
        }
        if start < domainStart { start = domainStart }
        window.visibleStart = start
        window.visibleEnd = start.addingTimeInterval(span)
        return window
    }

    /// Slide the visible range by `delta` seconds, keeping its span.
    public func panned(by delta: TimeInterval) -> ChartTimeWindow {
        guard delta.isFinite, delta != 0 else { return clamped() }
        var window = self
        window.visibleStart = visibleStart.addingTimeInterval(delta)
        window.visibleEnd = visibleEnd.addingTimeInterval(delta)
        return window.clamped()
    }

    /// Zoom around `anchor`, keeping the anchor's relative x position.
    ///
    /// `scale` is a magnification factor, matching a pinch gesture: `2` shows
    /// half as much time (zoom in), `0.5` shows twice as much (zoom out).
    public func zoomed(scale: Double, around anchor: Date) -> ChartTimeWindow {
        guard scale.isFinite, scale > 0, visibleSpan > 0, domainSpan > 0 else {
            return clamped()
        }
        let targetSpan = min(max(visibleSpan / scale, effectiveMinimumSpan), domainSpan)
        let clampedAnchor = min(max(anchor, visibleStart), visibleEnd)
        let fraction = clampedAnchor.timeIntervalSince(visibleStart) / visibleSpan
        var window = self
        window.visibleStart = clampedAnchor.addingTimeInterval(-fraction * targetSpan)
        window.visibleEnd = window.visibleStart.addingTimeInterval(targetSpan)
        return window.clamped()
    }

    /// Snap to a preset span, anchored at the newest edge of the domain — what
    /// a "24h / 7d / 30d" selector does.
    public func jumped(toSpan span: TimeInterval) -> ChartTimeWindow {
        guard span.isFinite, domainSpan > 0 else { return clamped() }
        let targetSpan = min(max(span, effectiveMinimumSpan), domainSpan)
        var window = self
        window.visibleStart = domainEnd.addingTimeInterval(-targetSpan)
        window.visibleEnd = domainEnd
        return window.clamped()
    }

    // MARK: - Mutating operations

    public mutating func clamp() { self = clamped() }

    public mutating func pan(by delta: TimeInterval) { self = panned(by: delta) }

    public mutating func zoom(scale: Double, around anchor: Date) {
        self = zoomed(scale: scale, around: anchor)
    }

    public mutating func jump(toSpan span: TimeInterval) { self = jumped(toSpan: span) }
}
