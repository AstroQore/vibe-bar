import Foundation

/// The app's language, as a value a cache key or an `Equatable` guard can
/// hold.
///
/// **Why this exists.** A cache keyed on data is wrong the moment its value
/// depends on the language too. `AppLocale` learned this for formatters —
/// twenty `static let` formatters were frozen at launch language until it
/// memoized on `AppLocalization.resolvedLanguageCode`, which turns a language change
/// into an ordinary cache miss rather than something a person has to
/// remember to invalidate. Every cache that holds a *localized string* has
/// the same defect and needs the same cure.
///
/// The three shapes it turns up in, and what to do about each:
///
/// - **A `static let` holding a localized value** is frozen for the life of
///   the process. Where the value is cheap — a handful of pill labels — the
///   answer is to derive it at render and cache nothing, which deletes the
///   question instead of answering it. `Scripts/lint_localization.py` fails
///   on this shape in a migrated file so it cannot come back.
/// - **A cache that genuinely earns its keep** — a 365-day walk, a
///   re-segmented chart — keeps its cache and puts this in the stamp, next
///   to the calendar and time-zone identity that are there for exactly the
///   same reason.
/// - **An `Equatable` guard** (`.equatable()`, a data signature) has to let
///   the language participate in the comparison, or the guard goes on doing
///   its job and goes on being wrong.
///
/// Prefer caching the *number* and deriving the sentence where the two can be
/// separated: a total is data, and "{amount} total" is a rendering of it.
public struct LanguageStamp: Equatable, Sendable {
    /// The `.lproj` code in force when this was taken.
    public let code: String

    private init(code: String) { self.code = code }

    /// The language in force right now.
    public static var current: LanguageStamp {
        LanguageStamp(code: AppLocalization.resolvedLanguageCode)
    }
}
