import Foundation

/// Burn-rate / pace projection for a single quota bucket.
///
/// Given a bucket's current `usedPercent`, its `resetAt`, and the total window
/// size (`rawWindowSeconds`), this computes:
/// - how the actual usage compares to the linear "expected" pace,
/// - an ETA until the bucket would hit 100% at the current rate,
/// - whether the bucket will last to its reset at the current rate.
///
/// Linear burn-rate projection for quota reset windows.
public struct UsagePace: Sendable, Equatable {
    public enum Stage: String, Sendable, Equatable {
        case onTrack
        case slightlyAhead
        case ahead
        case farAhead
        case slightlyBehind
        case behind
        case farBehind
    }

    public let stage: Stage
    public let deltaPercent: Double           // actual - expected (positive = ahead = burning faster than linear)
    public let expectedUsedPercent: Double
    public let actualUsedPercent: Double
    public let etaSeconds: TimeInterval?      // seconds until 100% at current rate; nil if N/A or willLastToReset
    public let willLastToReset: Bool

    public init(
        stage: Stage,
        deltaPercent: Double,
        expectedUsedPercent: Double,
        actualUsedPercent: Double,
        etaSeconds: TimeInterval?,
        willLastToReset: Bool
    ) {
        self.stage = stage
        self.deltaPercent = deltaPercent
        self.expectedUsedPercent = expectedUsedPercent
        self.actualUsedPercent = actualUsedPercent
        self.etaSeconds = etaSeconds
        self.willLastToReset = willLastToReset
    }

    /// Compute pace for a quota bucket. Returns nil when there isn't enough
    /// information (no reset time, no window size, reset already passed, etc.).
    public static func compute(bucket: QuotaBucket, now: Date = Date()) -> UsagePace? {
        guard let resetsAt = bucket.resetAt else { return nil }
        guard let windowSeconds = bucket.rawWindowSeconds, windowSeconds > 0 else { return nil }
        let duration = TimeInterval(windowSeconds)
        let timeUntilReset = resetsAt.timeIntervalSince(now)
        guard timeUntilReset > 0 else { return nil }
        guard timeUntilReset <= duration else { return nil }

        let elapsed = clamp(duration - timeUntilReset, lower: 0, upper: duration)
        let expected = clamp((elapsed / duration) * 100, lower: 0, upper: 100)
        let actual = clamp(bucket.usedPercent, lower: 0, upper: 100)

        // Edge case: zero elapsed but non-zero usage means a fresh window with backfilled state — bail out.
        if elapsed == 0, actual > 0 { return nil }

        let delta = actual - expected
        let stage = stageFor(delta: delta)

        var etaSeconds: TimeInterval?
        var willLastToReset = false

        if elapsed > 0, actual > 0 {
            let rate = actual / elapsed
            if rate > 0 {
                let remaining = max(0, 100 - actual)
                let candidate = remaining / rate
                if candidate >= timeUntilReset {
                    willLastToReset = true
                } else {
                    etaSeconds = candidate
                }
            }
        } else if elapsed > 0, actual == 0 {
            willLastToReset = true
        }

        return UsagePace(
            stage: stage,
            deltaPercent: delta,
            expectedUsedPercent: expected,
            actualUsedPercent: actual,
            etaSeconds: etaSeconds,
            willLastToReset: willLastToReset
        )
    }

    private static func stageFor(delta: Double) -> Stage {
        let absDelta = abs(delta)
        if absDelta <= 2 { return .onTrack }
        if absDelta <= 6 { return delta >= 0 ? .slightlyAhead : .slightlyBehind }
        if absDelta <= 12 { return delta >= 0 ? .ahead : .behind }
        return delta >= 0 ? .farAhead : .farBehind
    }

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}

public extension UsagePace {
    /// Short user-facing summary: "On pace", "5% in deficit", "8% in reserve".
    /// "in deficit" = burning faster than linear (ahead); "in reserve" = slower than linear (behind).
    var stageSummary: String {
        let value = Int(abs(deltaPercent).rounded())
        switch stage {
        case .onTrack:
            return "On pace"
        case .slightlyAhead, .ahead, .farAhead:
            return "\(value)% in deficit"
        case .slightlyBehind, .behind, .farBehind:
            return "\(value)% in reserve"
        }
    }
}
