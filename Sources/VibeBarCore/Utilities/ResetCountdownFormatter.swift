import Foundation

public enum ResetCountdownFormatter {
    /// Formats a future reset date as a compact human countdown:
    /// "5d", "2d 4h", "3h 16m", "12m", "<1m", "now".
    /// Returns nil if `resetAt` is nil.
    public static func string(from resetAt: Date?, now: Date = Date()) -> String? {
        guard let resetAt else { return nil }
        let total = Int(resetAt.timeIntervalSince(now).rounded(.toNearestOrAwayFromZero))
        if total <= 0 { return "now" }

        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60

        if days >= 2 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if days == 1 {
            return hours > 0 ? "1d \(hours)h" : "1d"
        }
        if hours >= 1 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes >= 1 {
            return "\(minutes)m"
        }
        return "<1m"
    }

    /// "Updated 10 seconds ago", "Updated 3 minutes ago", "Updated just now",
    /// "Never updated". Date in the future is treated as "just now".
    public static func updatedAgo(from date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Never updated" }
        let interval = Int(now.timeIntervalSince(date))
        if interval < 5 { return "Updated just now" }
        if interval < 60 { return "Updated \(interval) seconds ago" }
        let minutes = interval / 60
        if minutes < 60 {
            return minutes == 1 ? "Updated 1 minute ago" : "Updated \(minutes) minutes ago"
        }
        let hours = minutes / 60
        if hours < 24 {
            return hours == 1 ? "Updated 1 hour ago" : "Updated \(hours) hours ago"
        }
        let days = hours / 24
        return days == 1 ? "Updated 1 day ago" : "Updated \(days) days ago"
    }
}
