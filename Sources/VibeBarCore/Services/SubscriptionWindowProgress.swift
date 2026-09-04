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
        let value = modeValue(displayedPercent, displayMode: displayMode)
        guard let resetAt, let rawWindowSeconds, rawWindowSeconds > 0 else {
            return value
        }

        let windowSeconds = TimeInterval(rawWindowSeconds)
        let remaining = resetAt.timeIntervalSince(now)
        if remaining <= 0 {
            return L10n.Quota.Window.resetsSoon(value: value)
        }
        let elapsed = max(0, min(windowSeconds, windowSeconds - remaining))

        if rawWindowSeconds >= 86_400 {
            let totalDays = max(1, Int((windowSeconds / 86_400).rounded()))
            let dayNumber = clamp(Int(elapsed / 86_400) + 1, lower: 1, upper: totalDays)
            return L10n.Quota.Window.dayOfDays(day: dayNumber, total: totalDays, value: value)
        }

        let totalLabel = rawWindowSeconds == 18_000
            ? L10n.Quota.Group.fiveHours
            : formatShortDuration(windowSeconds)
        let elapsedLabel = formatShortDuration(elapsed)
        return L10n.Quota.Window.elapsedOfWindow(
            elapsed: elapsedLabel, window: totalLabel, value: value
        )
    }

    private static func clamp(_ value: Int, lower: Int, upper: Int) -> Int {
        min(max(value, lower), upper)
    }

    /// "42% used" / "42% left" — the same pair the forecast surfaces read.
    private static func modeValue(_ value: Double, displayMode: DisplayMode) -> String {
        let percent = Int((value.isFinite ? max(0, min(100, value)) : 0).rounded())
        switch displayMode {
        case .used: return L10n.Quota.usedPercent(percent: percent)
        case .remaining: return L10n.Quota.remainingPercent(percent: percent)
        }
    }

    private static func formatShortDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        if hours == 0 { return L10n.Common.Duration.minutes(minutes: minutes) }
        if minutes == 0 { return L10n.Common.Duration.hours(hours: hours) }
        return L10n.Common.Duration.hoursMinutes(hours: hours, minutes: minutes)
    }
}
