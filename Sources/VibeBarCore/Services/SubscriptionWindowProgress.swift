import Foundation

/// Short one-line summary describing how far into the current reset
/// window a bucket is plus the live used%. Used by
/// `SubscriptionUtilizationView` above the pace line.
///
/// Examples:
///   - "Day 6 of 7 · 56% used"            — windows with full-day grain
///   - "2h 35m of 5 Hours · 7% used"      — sub-day windows (5-hour)
///   - "Resets soon · 99% used"           — reset has technically passed
///   - "42% used"                         — no resetAt or no
///                                          rawWindowSeconds (Gemini
///                                          per-model when unset)
public enum SubscriptionWindowProgress {
    public static func summary(
        usedPercent: Double,
        resetAt: Date?,
        rawWindowSeconds: Int?,
        displayMode: DisplayMode = .used,
        now: Date = Date()
    ) -> String {
        let displayedPercent = displayMode == .used ? usedPercent : 100 - usedPercent
        let pct = formatPercent(displayedPercent)
        let unit = displayMode == .used ? "used" : "left"
        guard let resetAt, let rawWindowSeconds, rawWindowSeconds > 0 else {
            return "\(pct) \(unit)"
        }

        let windowSeconds = TimeInterval(rawWindowSeconds)
        let remaining = resetAt.timeIntervalSince(now)
        if remaining <= 0 {
            return "Resets soon · \(pct) \(unit)"
        }
        let elapsed = max(0, min(windowSeconds, windowSeconds - remaining))

        if rawWindowSeconds >= 86_400 {
            let totalDays = max(1, Int((windowSeconds / 86_400).rounded()))
            let dayNumber = clamp(Int(elapsed / 86_400) + 1, lower: 1, upper: totalDays)
            return "Day \(dayNumber) of \(totalDays) · \(pct) \(unit)"
        }

        let totalLabel = rawWindowSeconds == 18_000
            ? "5 Hours"
            : formatShortDuration(windowSeconds)
        let elapsedLabel = formatShortDuration(elapsed)
        return "\(elapsedLabel) of \(totalLabel) · \(pct) \(unit)"
    }

    private static func clamp(_ value: Int, lower: Int, upper: Int) -> Int {
        min(max(value, lower), upper)
    }

    private static func formatPercent(_ value: Double) -> String {
        let v = value.isFinite ? max(0, min(100, value)) : 0
        return "\(Int(v.rounded()))%"
    }

    private static func formatShortDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        if hours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }
}
