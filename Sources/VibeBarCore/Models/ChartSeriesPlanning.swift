import Foundation

/// Uniform-stride thinning for brush minis and zoomed-out main charts.
///
/// Purely a drawing concern — the series itself keeps every observation, this
/// only decides how many of them are worth turning into marks at the current
/// scale. Both endpoints always survive: the first because slot 0 maps to index
/// 0, the last because the final slot maps to the final index. That matters
/// beyond aesthetics — a segment's endpoints are what the gap-bridging
/// connectors are anchored to.
public enum ChartSeriesThinning {
    public static func strided<Element>(_ elements: [Element], limit: Int) -> [Element] {
        guard limit > 1, elements.count > limit else { return elements }
        let step = Double(elements.count - 1) / Double(limit - 1)
        var result: [Element] = []
        result.reserveCapacity(limit)
        var lastIndex = -1
        for slot in 0..<limit {
            let index = min(elements.count - 1, Int((Double(slot) * step).rounded()))
            if index != lastIndex {
                result.append(elements[index])
                lastIndex = index
            }
        }
        // The newest sample carries the "where are we now" reading, so never
        // let rounding drop it.
        if lastIndex != elements.count - 1 {
            result.append(elements[elements.count - 1])
        }
        return result
    }
}

/// Bounded chart projection for usage buckets.
///
/// Generic striding is appropriate for sampled lines such as quota history,
/// but it can erase a usage spike entirely. This projection draws only exact
/// source buckets. Once the budget reaches two marks, endpoints win; the
/// token and cost peaks follow in that order as the third and fourth marks.
/// Any remaining time span then contributes its most significant exact point.
/// Keeping every drawn point unmodified is important because the Workbench
/// hover reads the original bucket at the same timestamp.
public enum UsageTrendSeriesDownsampling {
    public static func points(
        _ input: [UsageTrendPoint],
        limit: Int
    ) -> [UsageTrendPoint] {
        guard limit > 0, input.count > limit else { return input }
        guard limit > 1 else {
            return [input[peakIndex(in: input, by: \.totalTokens)]]
        }

        var selected: Set<Int> = [0, input.count - 1]
        let tokenPeak = peakIndex(in: input, by: \.totalTokens)
        let costPeak = peakIndex(in: input, by: \.costMicros)
        for index in [tokenPeak, costPeak] where selected.count < limit {
            selected.insert(index)
        }

        // Spend the leftover budget across contiguous spans so a busy period
        // cannot monopolize the whole path. The score is normalized by each
        // metric's global peak, making a cost spike visible even when its
        // token count is modest (and vice versa).
        let extraSlots = limit - selected.count
        if extraSlots > 0 {
            let maximumTokens = max(1, input[tokenPeak].totalTokens)
            let maximumCost = max(1, input[costPeak].costMicros)
            for slot in 0..<extraSlots {
                let lower = slot * input.count / extraSlots
                let upper = (slot + 1) * input.count / extraSlots
                let candidate = (lower..<upper)
                    .filter { !selected.contains($0) }
                    .max { lhs, rhs in
                        significance(input[lhs], tokens: maximumTokens, cost: maximumCost)
                            < significance(input[rhs], tokens: maximumTokens, cost: maximumCost)
                    }
                if let candidate { selected.insert(candidate) }
            }
        }
        return selected.sorted().map { input[$0] }
    }

    private static func peakIndex(
        in points: [UsageTrendPoint],
        by value: (UsageTrendPoint) -> Int64 = { $0.totalTokens }
    ) -> Int {
        points.indices.max { lhs, rhs in
            value(points[lhs]) == value(points[rhs])
                ? lhs > rhs
                : value(points[lhs]) < value(points[rhs])
        }!
    }

    private static func significance(
        _ point: UsageTrendPoint,
        tokens: Int64,
        cost: Int64
    ) -> Double {
        Double(point.totalTokens) / Double(tokens) + Double(point.costMicros) / Double(cost)
    }
}

/// Splitting one curve's mark budget across the segments it is drawn in.
///
/// A quota history curve is not one array but a run of segments — one per
/// window, per coverage gap. Thinning each segment to the curve's budget
/// independently means the budget is really `segmentCount × budget`, and it is
/// worse than it sounds: a five-hour quota's segments are individually *small*
/// (a window's worth of five-minute slots), so each one sits under the limit
/// and is never thinned at all. Zoomed out over months of history that is tens
/// of thousands of marks for a single curve, and Swift Charts lays out every
/// one of them on the main thread.
///
/// So the budget is allocated first, then spent: each segment gets a share
/// proportional to how much of the curve it actually is, and only then is it
/// thinned to that share.
public enum ChartMarkBudget {
    /// Fewest points a segment may be reduced to.
    ///
    /// Two, because a line needs two points — and because the two that survive
    /// striding are the segment's endpoints, which are exactly the points the
    /// bridging connectors between segments attach to. Thinning must never be
    /// able to detach a bridge from the data it bridges.
    public static let minimumSegmentPoints = 2

    /// How many points each segment may keep, given the whole curve's budget.
    ///
    /// Returns the inputs unchanged when the curve already fits — thinning a
    /// series that does not need it only costs fidelity.
    ///
    /// When the floors alone exceed the budget (a curve shattered into hundreds
    /// of tiny segments) the floors win and the result is deliberately over
    /// budget: dropping segments entirely would delete evidence, and two marks
    /// per segment is already the cheapest honest rendering of it.
    public static func allocate(segmentCounts: [Int], budget: Int) -> [Int] {
        let counts = segmentCounts.map { max(0, $0) }
        guard budget > 0 else { return counts }
        let total = counts.reduce(0, +)
        guard total > budget else { return counts }

        let floors = counts.map { min($0, minimumSegmentPoints) }
        let floorTotal = floors.reduce(0, +)
        guard floorTotal < budget else { return floors }

        var allowance = floors
        let excess = zip(counts, floors).map { $0 - $1 }
        let excessTotal = excess.reduce(0, +)
        guard excessTotal > 0 else { return allowance }

        // Proportional share of what is left after the floors, rounded down so
        // the budget can never be overshot here…
        let spare = budget - floorTotal
        var remainders: [(index: Int, fraction: Double)] = []
        for index in counts.indices where excess[index] > 0 {
            let exact = Double(spare) * Double(excess[index]) / Double(excessTotal)
            let whole = min(excess[index], Int(exact.rounded(.down)))
            allowance[index] += whole
            remainders.append((index, exact - Double(whole)))
        }

        // …and the rounding crumbs handed out by largest remainder, so the
        // budget is spent exactly instead of quietly drifting below it.
        var leftover = budget - allowance.reduce(0, +)
        if leftover > 0 {
            for (index, _) in remainders.sorted(by: { $0.fraction > $1.fraction }) {
                guard leftover > 0 else { break }
                guard allowance[index] < counts[index] else { continue }
                allowance[index] += 1
                leftover -= 1
            }
        }
        // Segments that hit their own size can refuse a crumb; give what is
        // still unspent to the densest segments that have room, since they are
        // the ones losing the most detail.
        if leftover > 0 {
            for index in counts.indices.sorted(by: { counts[$0] > counts[$1] }) {
                guard leftover > 0 else { break }
                let room = counts[index] - allowance[index]
                guard room > 0 else { continue }
                let take = min(room, leftover)
                allowance[index] += take
                leftover -= take
            }
        }
        return allowance
    }

    /// Allocate and spend in one step: the segments a curve draws, thinned so
    /// the whole curve stays inside `budget`.
    public static func thinned<Element>(
        _ segments: [[Element]],
        budget: Int
    ) -> [[Element]] {
        let allowance = allocate(segmentCounts: segments.map(\.count), budget: budget)
        return zip(segments, allowance).map { segment, limit in
            ChartSeriesThinning.strided(segment, limit: limit)
        }
    }
}

/// The slice of one segment a visible range actually has to draw.
///
/// Splitting this out of the mark builders because "which samples does this
/// window need" is a question about evidence, not about SwiftUI, and because
/// the answer has a case that is easy to get wrong: a segment can cross the
/// visible range without putting a single sample inside it.
public enum ChartSegmentClip {
    /// Samples of `segment` that `range` needs, `segment` being ascending by
    /// `time`.
    ///
    /// Three cases, and the third is the one this exists for:
    ///
    /// - Samples inside the range: they are returned with one extra sample on
    ///   each side, so a line entering the window starts at the frame border
    ///   rather than at its first visible observation.
    /// - No samples anywhere near it: nothing to draw.
    /// - **No samples inside, but samples on both sides of it.** The lane's
    ///   line runs straight through the window and has to be drawn, so the
    ///   straddling pair is returned. Dropping it was a real defect and a
    ///   lopsided one: lanes are filed into slots sized by their quota window
    ///   (`UsageTimelineSlotPolicy`), so a five-hour quota's five-minute slots
    ///   almost always land something inside a window a user would zoom to,
    ///   while an hourly-slotted weekly lane — and much worse, the daily slots
    ///   a quota with no reported window length gets — often do not. The
    ///   symptom was a chart that drew its five-hour curve and silently
    ///   dropped the weekly one.
    public static func visible<Element>(
        _ segment: [Element],
        time: (Element) -> Date,
        to range: ClosedRange<Date>
    ) -> [Element] {
        guard !segment.isEmpty else { return [] }
        var first: Int?
        var last: Int?
        for (index, element) in segment.enumerated() {
            let stamp = time(element)
            if stamp >= range.lowerBound, stamp <= range.upperBound {
                if first == nil { first = index }
                last = index
            }
        }
        if let first, let last {
            let lower = max(0, first - 1)
            let upper = min(segment.count - 1, last + 1)
            return Array(segment[lower...upper])
        }
        // Nothing inside. Keep the pair that brackets the range, if there is
        // one — that is a line crossing the window, not an absence of one.
        guard let before = segment.lastIndex(where: { time($0) < range.lowerBound }),
              segment.indices.contains(before + 1),
              time(segment[before + 1]) > range.upperBound
        else { return [] }
        return [segment[before], segment[before + 1]]
    }
}

/// How far from the crosshair one lane's nearest sample may sit and still count
/// as what that lane read there.
///
/// A quota chart overlays lanes that are deliberately *not* sampled at the same
/// rhythm: `UsageTimelineSlotPolicy` files a five-hour quota into five-minute
/// slots, a weekly one into hourly slots, a monthly one into six-hour slots,
/// and a quota whose window length the provider never reported into daily ones.
/// One tolerance sized for the densest lane therefore misses on most hover
/// positions of every sparser lane — which is how a weekly bucket sitting
/// mid-window, with its line drawn under the crosshair, came to report that it
/// had nothing to say.
///
/// So the tolerance is per lane, and it is derived from the widest spacing that
/// lane's own samples can legitimately have. Two things set that spacing: the
/// slot width the lane is filed into, and the refresh cadence, because no lane
/// is sampled more often than the app refreshes — the same pair
/// `QuotaHistorySeriesBuilder` weighs when deciding whether coverage stopped.
public enum ChartHoverTolerance {
    /// Fraction of a lane's own sampling rhythm that still counts as "here".
    ///
    /// Above a half so a cursor parked exactly between two maximally-spaced
    /// samples resolves to one of them instead of falling into a hole that
    /// only exists because of where the pointer happened to stop.
    static let cadenceFraction: Double = 0.75

    /// Zoomed far out, one pixel of plot is many minutes of history and the
    /// user cannot aim more precisely than that, so the tolerance never drops
    /// below a slice of the visible span.
    static let pointerSlopFraction: Double = 1.0 / 80.0

    public static func seconds(windowSeconds: Int?, visibleSpan: TimeInterval) -> TimeInterval {
        let slot = UsageTimelineSlotPolicy.slotSeconds(windowSeconds: windowSeconds)
        let cadence = max(slot, TimeInterval(AppSettings.slowestRefreshIntervalSeconds))
        return max(cadence * cadenceFraction, max(0, visibleSpan) * pointerSlopFraction)
    }
}

/// Finding the observation nearest a point in time.
///
/// The charts resolve a hover by asking every curve "what did you read here?".
/// Scanning each curve's samples makes that O(total samples) *per pointer
/// move* — with unlimited retention and five-minute slots, hundreds of
/// thousands of comparisons on the main thread every time the mouse twitches.
/// The samples are already time-sorted, so a binary search answers the same
/// question in O(log n).
public enum ChartSampleSearch {
    /// Nearest element to `target`, or `nil` when the closest one is farther
    /// away than `tolerance`.
    ///
    /// `sorted` must be ascending by `time`. A gap wider than the tolerance
    /// returns nothing on purpose: the absence of coverage is information, and
    /// bridging it to whichever sample happens to be nearest would invent a
    /// reading that was never taken.
    public static func nearest<Element>(
        in sorted: [Element],
        to target: Date,
        tolerance: TimeInterval,
        time: (Element) -> Date
    ) -> Element? {
        guard !sorted.isEmpty, tolerance >= 0 else { return nil }
        // First index at or after `target`.
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = low + (high - low) / 2
            if time(sorted[mid]) < target {
                low = mid + 1
            } else {
                high = mid
            }
        }
        var best: Element?
        var bestDistance = tolerance
        for index in [low - 1, low] where index >= 0 && index < sorted.count {
            let distance = abs(time(sorted[index]).timeIntervalSince(target))
            // Strictly-better after the first candidate, so a cursor sitting
            // exactly between two samples resolves to the earlier one — the
            // reading that had actually been taken at that moment — instead of
            // flickering with floating-point noise.
            guard distance <= bestDistance, best == nil || distance < bestDistance else { continue }
            best = sorted[index]
            bestDistance = distance
        }
        return best
    }
}
