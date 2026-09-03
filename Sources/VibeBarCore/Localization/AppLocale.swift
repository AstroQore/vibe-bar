import Foundation

/// The `Locale` every user-visible date, time and number is formatted in.
///
/// `AppSettings.language` decides what language Vibe Bar renders in, and
/// `Locale.current` does not know about it: a user reading the app in
/// Simplified Chinese on an English macOS gets `Locale.current == en_US`,
/// so `date.formatted(...)` drops "Aug 17, 2026" into the middle of a
/// Chinese sentence. Everything the user reads therefore formats against
/// this, not against the process locale.
///
/// **This is only for display.** Wire formats, parsed API payloads, cache
/// keys and backup filenames must stay pinned to `en_US_POSIX` — they are
/// data, and a date that changes shape with the user's language is a
/// corrupt file, not a translated one. Core's adapters and stores already
/// pin it and must keep doing so.
///
/// **Formatters are memoized on the language, not stored.** A
/// `static let formatter = { … }()` is built once for the lifetime of the
/// process and would keep the old language after a change — the same
/// staleness that made `ResetHistoryComparison.verdict` a computed
/// property. Keying the cache on the resolved language means a change is
/// simply a miss, with no invalidation to remember.
public enum AppLocale {
    /// The app's locale, following `AppSettings.language`.
    public static var current: Locale { Locale(identifier: L10n.resolvedLanguageCode) }

    // MARK: - Dates

    /// A formatter for a CLDR skeleton — "MMMd", "EEEMMMdHHmm" — rendered
    /// the way the app's language spells it.
    ///
    /// A skeleton rather than a fixed `dateFormat` is the whole point:
    /// `"MMM d"` hardcodes an English word order and an English month
    /// name, while `"MMMd"` becomes "Aug 17" in English and "8月17日" in
    /// Chinese from the same call.
    public static func dateFormatter(
        template: String, timeZone: TimeZone? = nil
    ) -> DateFormatter {
        formatter(key: "t:\(template):\(timeZone?.identifier ?? "-")") {
            let formatter = DateFormatter()
            formatter.locale = current
            formatter.setLocalizedDateFormatFromTemplate(template)
            if let timeZone { formatter.timeZone = timeZone }
            return formatter
        }
    }

    /// A formatter for the system's own date/time styles.
    public static func dateFormatter(
        dateStyle: DateFormatter.Style, timeStyle: DateFormatter.Style
    ) -> DateFormatter {
        formatter(key: "s:\(dateStyle.rawValue):\(timeStyle.rawValue)") {
            let formatter = DateFormatter()
            formatter.locale = current
            formatter.dateStyle = dateStyle
            formatter.timeStyle = timeStyle
            return formatter
        }
    }

    /// A fixed numeric pattern — "yyyy-MM-dd", "HH:mm" — that still needs
    /// the app's locale for its calendar and numbering system.
    ///
    /// Use this only when the pattern contains no month or weekday name;
    /// anything with `MMM`, `EEE` or `a` in it belongs in a template, or
    /// it renders an English word inside a Chinese line.
    public static func dateFormatter(
        numericFormat: String, timeZone: TimeZone? = nil
    ) -> DateFormatter {
        formatter(key: "n:\(numericFormat):\(timeZone?.identifier ?? "-")") {
            let formatter = DateFormatter()
            formatter.locale = current
            formatter.dateFormat = numericFormat
            if let timeZone { formatter.timeZone = timeZone }
            return formatter
        }
    }

    public static func string(_ date: Date, template: String) -> String {
        dateFormatter(template: template).string(from: date)
    }

    public static func string(
        _ date: Date, dateStyle: DateFormatter.Style, timeStyle: DateFormatter.Style
    ) -> String {
        dateFormatter(dateStyle: dateStyle, timeStyle: timeStyle).string(from: date)
    }

    /// "3 min ago" / "3 分钟前", in the app's language.
    public static func relativeDateTimeFormatter(
        unitsStyle: RelativeDateTimeFormatter.UnitsStyle = .abbreviated
    ) -> RelativeDateTimeFormatter {
        let code = L10n.resolvedLanguageCode
        return relatives.withLock { cache in
            let key = "\(code):\(unitsStyle.rawValue)"
            if let cached = cache[key] { return cached }
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = current
            formatter.unitsStyle = unitsStyle
            cache[key] = formatter
            return formatter
        }
    }

    // MARK: - Numbers

    /// A grouped integer — "1,234" / "1,234" — in the app's language.
    public static func number(_ value: some BinaryInteger) -> String {
        Int(value).formatted(.number.grouping(.automatic).locale(current))
    }

    /// A percentage with `fractionDigits` decimals.
    public static func percent(_ fraction: Double, fractionDigits: Int = 0) -> String {
        fraction.formatted(
            .percent.precision(.fractionLength(fractionDigits)).locale(current)
        )
    }

    // MARK: - Storage

    private static func formatter(
        key: String, build: () -> DateFormatter
    ) -> DateFormatter {
        let code = L10n.resolvedLanguageCode
        return dates.withLock { cache in
            let full = "\(code)|\(key)"
            if let cached = cache[full] { return cached }
            let formatter = build()
            cache[full] = formatter
            return formatter
        }
    }

    private static let dates = FormatterBox([String: DateFormatter]())
    private static let relatives = FormatterBox([String: RelativeDateTimeFormatter]())
}

/// `DateFormatter` is not `Sendable`, and these are shared across the
/// surfaces that render dates. Access stays behind a lock; every use is a
/// synchronous `string(from:)` on the caller's thread.
private final class FormatterBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
