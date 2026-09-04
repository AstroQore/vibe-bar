import Foundation

/// What a reset time looks like — the one table every surface that draws one
/// reads, and the one the menu-bar composer lets a block choose from.
///
/// Before this existed the shape of a reset time was decided at the call site,
/// which is why some of them named a weekday and most did not. A format is a
/// *set of components*, and the CLDR skeleton for that set is derived here:
/// `EEE` + `MMMd` + `HHmm` becomes "Mon, Sep 7 at 12:01" in English and
/// "9月7日 周一 12:01" in Chinese from the same value. Chinese puts the
/// weekday after the date and the year before the month; a hand-assembled
/// string gets that wrong in one of the two languages, which is the reason
/// there is no pattern literal anywhere below.
///
/// The stored value is the case name, never a rendered string: settings
/// outlive the language selected when they were written.
public enum ResetTimeFormat: String, Codable, CaseIterable, Hashable, Sendable {
    /// Drops what the countdown beside it already says. A reset later today
    /// is a bare time, because "today" is not a date anyone needs told; any
    /// other reset is the weekday, the date and the time.
    ///
    /// This is what every surface outside the composer uses, and it is why
    /// a five-hour window's row is no wider than it was before weekdays
    /// existed.
    case automatic
    /// `12:01`
    case time
    /// `Mon 12:01`
    case weekdayTime
    /// `Sep 7`
    case date
    /// `Sep 7 at 12:01`
    case dateTime
    /// `Mon, Sep 7 at 12:01`
    case weekdayDateTime

    public static let `default` = ResetTimeFormat.automatic

    /// Menu label for the composer's format picker.
    public var title: String {
        switch self {
        case .automatic: return L10n.MenuBar.composerResetFormatAutomatic
        case .time: return L10n.MenuBar.composerResetFormatTime
        case .weekdayTime: return L10n.MenuBar.composerResetFormatWeekdayTime
        case .date: return L10n.MenuBar.composerResetFormatDate
        case .dateTime: return L10n.MenuBar.composerResetFormatDateTime
        case .weekdayDateTime: return L10n.MenuBar.composerResetFormatWeekdayDateTime
        }
    }

    /// What `.automatic` turns into for this particular reset. Every other
    /// case answers with itself, so the renderer never has to ask twice.
    func resolved(for resetAt: Date, now: Date, calendar: Calendar) -> ResetTimeFormat {
        guard self == .automatic else { return self }
        return calendar.isDate(resetAt, inSameDayAs: now) ? .time : .weekdayDateTime
    }

    // MARK: - Components

    var showsWeekday: Bool {
        switch self {
        case .weekdayTime, .weekdayDateTime: return true
        case .automatic, .time, .date, .dateTime: return false
        }
    }

    var showsDate: Bool {
        switch self {
        case .date, .dateTime, .weekdayDateTime: return true
        case .automatic, .time, .weekdayTime: return false
        }
    }

    var showsTime: Bool {
        switch self {
        case .time, .weekdayTime, .dateTime, .weekdayDateTime: return true
        case .automatic, .date: return false
        }
    }

    /// The CLDR skeleton for this format. `includesYear` is the renderer's
    /// call, not the user's: a reset in another year has to say so, and a
    /// format that carries no date has nowhere to put one.
    ///
    /// `HHmm` rather than `jmm` on purpose — every other absolute time in the
    /// app is a 24-hour clock, and a reset line that disagrees with the
    /// chart tooltip above it reads as two different numbers.
    func skeleton(includesYear: Bool) -> String {
        var skeleton = ""
        if showsWeekday { skeleton += "EEE" }
        if showsDate {
            skeleton += "MMMd"
            if includesYear { skeleton += "yyyy" }
        }
        if showsTime { skeleton += "HHmm" }
        // `.automatic` never reaches here — `resolved(for:now:calendar:)` has
        // already turned it into one of the others — but a skeleton has to be
        // non-empty for `setLocalizedDateFormatFromTemplate`, so a format with
        // no components falls back to the time.
        return skeleton.isEmpty ? "HHmm" : skeleton
    }
}
