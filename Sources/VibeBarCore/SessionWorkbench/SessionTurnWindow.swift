import Foundation

/// Which turns of an open conversation are materialized, as one contiguous
/// window.
///
/// A conversation opens on its *end* — the last `pageSize` turns, which is
/// what someone coming back to a session wants to see — and grows a page at
/// a time in either direction as the reader scrolls. A jump from the outline
/// to a turn far outside the window replaces it with a window around that
/// turn rather than materializing everything in between: on a 1 500-turn
/// rollout read one byte window per turn, "everything between here and the
/// end" is the read this type exists to avoid.
///
/// `maxSpan` bounds how much one window can hold. Growing past it gives up
/// turns on the far side, so a reader who scrolls all the way back through a
/// long session does not end up holding every turn of it.
public struct SessionTurnWindow: Sendable, Hashable {
    public private(set) var total: Int
    public private(set) var lowerBound: Int
    public private(set) var upperBound: Int
    public let pageSize: Int
    public let maxSpan: Int

    public init(total: Int, lowerBound: Int, upperBound: Int, pageSize: Int, maxSpan: Int) {
        let total = max(0, total)
        let pageSize = max(1, pageSize)
        self.total = total
        self.pageSize = pageSize
        self.maxSpan = max(pageSize, maxSpan)
        let lower = min(max(0, lowerBound), total)
        self.lowerBound = lower
        self.upperBound = min(max(lower, upperBound), total)
    }

    /// The last `initial` turns (a page, unless told otherwise); later pages
    /// are `pageSize` each.
    public static func tail(total: Int, pageSize: Int, maxSpan: Int = 60, initial: Int? = nil) -> SessionTurnWindow {
        SessionTurnWindow(
            total: total,
            lowerBound: max(0, total - max(1, initial ?? pageSize)),
            upperBound: total,
            pageSize: pageSize,
            maxSpan: maxSpan
        )
    }

    public var range: Range<Int> { lowerBound..<upperBound }
    public var isEmpty: Bool { lowerBound == upperBound }
    public var count: Int { upperBound - lowerBound }
    public var hasEarlier: Bool { lowerBound > 0 }
    public var hasLater: Bool { upperBound < total }
    public var earlierCount: Int { lowerBound }
    public var laterCount: Int { total - upperBound }
    public var isAtTail: Bool { upperBound == total }

    public func contains(_ index: Int) -> Bool { range.contains(index) }

    /// Grow one page (or `turns` turns) toward the start. Returns the turns
    /// that joined.
    @discardableResult
    public mutating func extendEarlier(by turns: Int? = nil) -> Range<Int> {
        let newLower = max(0, lowerBound - max(1, turns ?? pageSize))
        let added = newLower..<lowerBound
        lowerBound = newLower
        if count > maxSpan { upperBound = lowerBound + maxSpan }
        return added
    }

    /// Grow one page (or `turns` turns) toward the end. Returns the turns
    /// that joined.
    @discardableResult
    public mutating func extendLater(by turns: Int? = nil) -> Range<Int> {
        let newUpper = min(total, upperBound + max(1, turns ?? pageSize))
        let added = upperBound..<newUpper
        upperBound = newUpper
        if count > maxSpan { lowerBound = upperBound - maxSpan }
        return added
    }

    /// Make `index` part of the window. A turn within one page of either
    /// edge extends the window to it; anything further away replaces the
    /// window with one that opens a couple of turns before it, so the jump
    /// lands with a little context above. Returns the turns the caller has
    /// to load, or an empty range when `index` was already in the window or
    /// is out of bounds.
    @discardableResult
    public mutating func reveal(_ index: Int) -> Range<Int> {
        guard index >= 0, index < total else { return 0..<0 }
        if contains(index) { return 0..<0 }
        if index < lowerBound, lowerBound - index <= pageSize {
            let added = index..<lowerBound
            lowerBound = index
            if count > maxSpan { upperBound = lowerBound + maxSpan }
            return added
        }
        if index >= upperBound, index - upperBound < pageSize {
            let added = upperBound..<(index + 1)
            upperBound = index + 1
            if count > maxSpan { lowerBound = upperBound - maxSpan }
            return added
        }
        let lead = min(2, index)
        lowerBound = index - lead
        upperBound = min(total, lowerBound + pageSize)
        return range
    }

    /// The conversation grew or shrank on disk. A window that was showing
    /// the end keeps showing it; any other window is clamped.
    public mutating func resize(total newTotal: Int) {
        let newTotal = max(0, newTotal)
        let wasAtTail = isAtTail
        total = newTotal
        if wasAtTail {
            let span = max(count, min(pageSize, newTotal))
            upperBound = newTotal
            lowerBound = max(0, newTotal - span)
        } else {
            upperBound = min(upperBound, newTotal)
            lowerBound = min(lowerBound, upperBound)
        }
    }
}
