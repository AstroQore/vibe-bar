import Foundation

public enum ResetCountdownFormatter {
    /// 1-based month index → its abbreviated name in the current language.
    /// A `DateFormatter` would also do this, but it would do it with the
    /// *system* locale, which is not necessarily the language the user
    /// picked for this app (`AppSettings.language`). One catalog keeps the
    /// month name and the sentence it sits inside speaking together.
    static func shortMonthName(_ month: Int) -> String? {
        guard (1...12).contains(month) else { return nil }
        return L10n.string("common.date.month.\(month)")
    }

    /// Formats a future reset date as a compact human countdown:
    /// "5d", "2d 4h", "3h 16m", "12m", "<1m", "now".
    /// Returns nil if `resetAt` is nil.
    public static func string(from resetAt: Date?, now: Date = Date()) -> String? {
        guard let resetAt else { return nil }
        let total = Int(resetAt.timeIntervalSince(now).rounded(.toNearestOrAwayFromZero))
        if total <= 0 { return L10n.Common.durationNow }

        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60

        if days >= 1 {
            return hours > 0
                ? L10n.Common.durationDaysHours(days: days, hours: hours)
                : L10n.Common.durationDays(days: days)
        }
        if hours >= 1 {
            return minutes > 0
                ? L10n.Common.durationHoursMinutes(hours: hours, minutes: minutes)
                : L10n.Common.durationHours(hours: hours)
        }
        if minutes >= 1 {
            return L10n.Common.durationMinutes(minutes: minutes)
        }
        return L10n.Common.durationLessThanMinute
    }

    /// Combines the compact countdown with the concrete local reset time.
    /// Same-day resets stay compact ("3h 16m · 18:30"); later resets include
    /// the calendar date ("2d 4h · Jul 24, 09:00") so the user never has to
    /// mentally derive the exact reset from a relative duration.
    public static func stringWithAbsoluteTime(
        from resetAt: Date?,
        now: Date = Date(),
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        guard let resetAt, let countdown = string(from: resetAt, now: now) else { return nil }
        guard let absolute = absoluteTime(
            for: resetAt,
            now: now,
            calendar: calendar,
            timeZone: timeZone
        ) else { return countdown }
        return "\(countdown) · \(absolute)"
    }

    /// The concrete local reset time on its own — "17:05" for a same-day
    /// reset, "Aug 17, 17:05" later in the same year, "Aug 17, 2026, 17:05"
    /// beyond it. Returns nil only when the date cannot be decomposed.
    public static func absoluteTime(
        for resetAt: Date,
        now: Date,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        var calendar = calendar
        calendar.timeZone = timeZone

        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: resetAt)
        guard let year = components.year,
              let month = components.month,
              let day = components.day,
              let hour = components.hour,
              let minute = components.minute,
              let monthName = shortMonthName(month) else { return nil }
        let time = String(format: "%02d:%02d", hour, minute)
        if calendar.isDate(resetAt, inSameDayAs: now) {
            return time
        } else if calendar.component(.year, from: resetAt) == calendar.component(.year, from: now) {
            return L10n.Common.dateMonthDayTime(month: monthName, day: day, time: time)
        }
        return L10n.Common.dateMonthDayYearTime(
            month: monthName, day: day, year: String(year), time: time
        )
    }

    /// One bucket's reset line, decided here so every surface treats a window
    /// that already rolled over the same way.
    ///
    /// `string(from:)` collapses to "now" the moment the countdown reaches
    /// zero and never distinguishes "about to reset" from "reset hours ago".
    /// A snapshot whose window expired is not live: its fill belongs to a
    /// cycle that no longer exists, so a row that keeps rendering "resets in
    /// now" next to a full bar reads as current data when it is not. Past the
    /// boundary-refresh grace, say so and let the caller de-emphasise the
    /// percentage it is still showing.
    public static func resetStatus(
        resetAt: Date?,
        now: Date = Date(),
        graceSeconds: TimeInterval = QuotaWindowEvaluation.postResetGraceSeconds,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> ResetStatus? {
        guard let resetAt else { return nil }
        let absolute = absoluteTime(for: resetAt, now: now, calendar: calendar, timeZone: timeZone)
        if now.timeIntervalSince(resetAt) > max(0, graceSeconds) {
            return ResetStatus(
                isExpired: true,
                label: absolute.map { L10n.Quota.resetPassedAt(time: $0) }
                    ?? L10n.Quota.resetPassed
            )
        }
        guard let countdown = string(from: resetAt, now: now) else { return nil }
        // The interpunct join is punctuation, not a sentence: both languages
        // read it the same way, so only the frame around it is translated.
        let detail = absolute.map { "\(countdown) · \($0)" } ?? countdown
        return ResetStatus(isExpired: false, label: L10n.Quota.resetIn(duration: detail))
    }

    /// Whether a bucket's reset already passed, plus the line to render for it.
    public struct ResetStatus: Equatable, Sendable {
        public let isExpired: Bool
        public let label: String

        public init(isExpired: Bool, label: String) {
            self.isExpired = isExpired
            self.label = label
        }
    }

    /// "Updated 10 seconds ago", "Updated 3 minutes ago", "Updated just now",
    /// "Never updated". Date in the future is treated as "just now".
    public static func updatedAgo(from date: Date?, now: Date = Date()) -> String {
        guard let date else { return L10n.Common.updatedNever }
        let interval = Int(now.timeIntervalSince(date))
        if interval < 5 { return L10n.Common.updatedJustNow }
        if interval < 60 { return L10n.Common.updatedSecondsAgo(seconds: interval) }
        // No `== 1` branch: the catalog carries the plural, so English gets
        // "1 minute" from its `one` category and Chinese — which has only
        // `other` — never has to pretend the distinction exists.
        let minutes = interval / 60
        if minutes < 60 { return L10n.Common.updatedMinutesAgo(minutes: minutes) }
        let hours = minutes / 60
        if hours < 24 { return L10n.Common.updatedHoursAgo(hours: hours) }
        return L10n.Common.updatedDaysAgo(days: hours / 24)
    }
}
