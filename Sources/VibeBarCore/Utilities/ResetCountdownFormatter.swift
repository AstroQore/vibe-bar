import Foundation

public enum ResetCountdownFormatter {
    /// Formats a future reset date as a compact human countdown:
    /// "5d", "2d 4h", "3h 16m", "12m", "<1m", "now".
    /// Returns nil if `resetAt` is nil.
    /// How much room the caller has for the words.
    ///
    /// Nearly every countdown in this app sits in a dense row, tile or
    /// caption at 8.5–10pt with `lineLimit(1)` and a shrink factor, and the
    /// compact form is what makes those fit. `.full` is for the handful of
    /// places that give a countdown a whole line to itself — the forecast
    /// sentence under a quota bar — where "2 days and 19 hours" reads as
    /// English and "2d 19h" reads as a machine.
    public enum DurationStyle: Sendable {
        case compact
        case full
    }

    public static func string(
        from resetAt: Date?,
        now: Date = Date(),
        style: DurationStyle = .compact
    ) -> String? {
        guard let resetAt else { return nil }
        let total = Int(resetAt.timeIntervalSince(now).rounded(.toNearestOrAwayFromZero))
        if total <= 0 { return L10n.Common.durationNow }

        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60

        switch style {
        case .compact:
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
        case .full:
            // Each unit is a plural of its own, and the pair is a key rather
            // than a join: English wants "and" between them and Chinese wants
            // nothing, which is not something a separator constant can say.
            if days >= 1 {
                let d = L10n.Common.durationFullDays(count: days)
                guard hours > 0 else { return d }
                return L10n.Common.durationFullDaysHours(
                    days: d, hours: L10n.Common.durationFullHours(count: hours)
                )
            }
            if hours >= 1 {
                let h = L10n.Common.durationFullHours(count: hours)
                guard minutes > 0 else { return h }
                return L10n.Common.durationFullHoursMinutes(
                    hours: h, minutes: L10n.Common.durationFullMinutes(count: minutes)
                )
            }
            if minutes >= 1 {
                return L10n.Common.durationFullMinutes(count: minutes)
            }
            return L10n.Common.durationLessThanMinute
        }
    }

    /// Combines the compact countdown with the concrete local reset time.
    /// Under `ResetTimeFormat.automatic` same-day resets stay compact
    /// ("3h 16m · 18:30") and later ones name the day ("2d 4h · Fri, Jul 24
    /// at 09:00"), so the user never has to mentally derive the exact reset
    /// from a relative duration.
    public static func stringWithAbsoluteTime(
        from resetAt: Date?,
        now: Date = Date(),
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        guard let resetAt, let countdown = string(from: resetAt, now: now) else { return nil }
        let absolute = absoluteTime(for: resetAt, now: now, calendar: calendar, timeZone: timeZone)
        return "\(countdown) · \(absolute)"
    }

    /// The concrete local reset time on its own, in the shape `format` asks
    /// for — "17:05", "Fri 17:05", "Aug 17 at 17:05", "Fri, Aug 17, 2026 at
    /// 17:05".
    ///
    /// `ResetTimeFormat` decides which components appear; the year is this
    /// function's call, because a reset in another year has to say so
    /// whatever the user picked. Everything below the skeleton is CLDR's:
    /// separators, word order and where the weekday sits all differ between
    /// English and Chinese, and none of them is composed here.
    public static func absoluteTime(
        for resetAt: Date,
        now: Date,
        format: ResetTimeFormat = .default,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> String {
        var calendar = calendar
        calendar.timeZone = timeZone

        let resolved = format.resolved(for: resetAt, now: now, calendar: calendar)
        let includesYear = calendar.component(.year, from: resetAt)
            != calendar.component(.year, from: now)
        return AppLocale.dateFormatter(
            template: resolved.skeleton(includesYear: includesYear),
            timeZone: timeZone
        ).string(from: resetAt)
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
            return ResetStatus(isExpired: true, label: L10n.Quota.resetPassedAt(time: absolute))
        }
        guard let countdown = string(from: resetAt, now: now) else { return nil }
        // The interpunct join is punctuation, not a sentence: both languages
        // read it the same way, so only the frame around it is translated.
        let detail = "\(countdown) · \(absolute)"
        return ResetStatus(isExpired: false, label: L10n.Quota.bucketResetsIn(when: detail))
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
