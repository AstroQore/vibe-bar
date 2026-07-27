import Foundation

/// Shared slot + retention policy for the adaptive usage timelines.
///
/// `UsageFillTimelineStore` and `UsageForecastTimelineStore` file samples into
/// fixed-width slots derived from the quota window, so a five-hour limit stays
/// minute-accurate while a monthly limit does not accumulate thousands of rows.
/// Chart code needs the same slot width to tell "no sample was due yet" apart
/// from "coverage actually stopped here", so the policy lives in one place
/// instead of being private to a single store.
public enum UsageTimelineSlotPolicy {
    /// Slot width for a quota window: ≤6h → 5 minutes, ≤8 days → hourly,
    /// ≤45 days → 6 hours, otherwise daily. An unknown window falls through to
    /// the daily bucket — legacy points without `rawWindowSeconds` are sparse
    /// and should not be treated as high-resolution.
    public static func slotSeconds(windowSeconds: Int?) -> TimeInterval {
        switch windowSeconds {
        case let seconds? where seconds <= 6 * 3_600:
            return 5 * 60
        case let seconds? where seconds <= 8 * 86_400:
            return 3_600
        case let seconds? where seconds <= 45 * 86_400:
            return 6 * 3_600
        default:
            return 86_400
        }
    }

    /// UTC-floored start of the slot `date` belongs to.
    public static func slotStart(for date: Date, windowSeconds: Int?) -> Date {
        let slot = slotSeconds(windowSeconds: windowSeconds)
        return Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / slot) * slot)
    }

    /// How long samples for a window stay useful even under unlimited
    /// retention. Five-hour lanes churn fast; weekly and monthly lanes need
    /// enough completed cycles to compare against.
    public static func naturalRetentionDays(windowSeconds: Int?) -> Int {
        switch windowSeconds {
        case let seconds? where seconds <= 6 * 3_600:
            return 30
        case let seconds? where seconds <= 8 * 86_400:
            return 16 * 7
        case let seconds? where seconds <= 45 * 86_400:
            return 18 * 31
        default:
            return 16 * 7
        }
    }

    /// Effective retention horizon: the natural horizon, further shortened when
    /// the user asked for a finite retention window.
    public static func retentionHorizonDays(windowSeconds: Int?, retentionDays: Int) -> Int {
        let natural = naturalRetentionDays(windowSeconds: windowSeconds)
        return CostDataSettings.isUnlimitedRetention(retentionDays)
            ? natural
            : min(natural, max(1, retentionDays))
    }
}
