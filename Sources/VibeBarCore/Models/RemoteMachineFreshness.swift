import Foundation

/// Health of one Probe relative to its own observed reporting cadence.
///
/// A five-minute Probe is not delayed merely because its last batch is three
/// minutes old. The Core learns the cadence from Relay receipt timestamps and
/// only warns after an expected report is actually missed. With too little
/// history to learn from, the conservative legacy 2/10 minute thresholds are
/// retained.
public enum RemoteMachineFreshness: String, Equatable, Sendable {
    case live
    case delayed
    case stale

    public static func evaluate(
        lastSeenAt: Date,
        expectedReportIntervalSeconds: TimeInterval?,
        now: Date = Date()
    ) -> Self {
        let age = max(0, now.timeIntervalSince(lastSeenAt))
        guard let learned = expectedReportIntervalSeconds, learned.isFinite, learned > 0 else {
            if age <= 120 { return .live }
            if age <= 600 { return .delayed }
            return .stale
        }

        // 40% jitter covers the Probe scan itself, network transit, and the
        // Core's 60-second fetch loop without hiding a genuinely missed cycle.
        let liveThrough = max(120, learned * 1.4)
        // A second missed report is stale. Keep ten minutes as the floor for
        // fast probes so a brief Mac sleep does not flash red immediately.
        let delayedThrough = max(600, learned * 2.5)
        if age <= liveThrough { return .live }
        if age <= delayedThrough { return .delayed }
        return .stale
    }
}
