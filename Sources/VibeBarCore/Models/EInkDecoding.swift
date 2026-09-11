import Foundation

/// Tolerant decoding helper shared by the E-ink settings models.
///
/// Every field in the E-ink tree is optional-with-a-default on purpose: a
/// settings file written by a newer build (or hand-edited) must never fail the
/// whole `AppSettings` decode, which would drop every unrelated preference
/// with it. `try?` collapses both "absent" and "present but malformed" into
/// the default.
extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(type, forKey: key)) ?? nil) ?? fallback
    }

    func lenientOptional<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}
