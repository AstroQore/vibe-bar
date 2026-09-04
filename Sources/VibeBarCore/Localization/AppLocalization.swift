import Foundation
@_exported import VibeBarLocalization

/// Which language the app shows, and the one place that decides it.
///
/// The strings themselves live in `vibe-bar-i18n` and are reached through
/// its `L10n` (re-exported here, so every file in both targets sees the same
/// `L10n.Settings.Language.system` without importing the package itself).
/// This type only chooses the language, with the rules the app has always
/// had — an explicit setting, the `VIBEBAR_LANGUAGE` diagnostic hook, a
/// `zh-Hant` reader never handed `zh-Hans` — and tells the package which
/// locale to serve.
///
/// It always tells it *explicitly*. The package can match the system
/// language on its own, but its matching is looser than ours (a bare `zh`
/// finds `zh-Hans`), so the answer is resolved here and pushed through
/// `L10n.localeOverride` every time it changes. Nothing reads the package's
/// own opinion.
///
/// **Why not `LocalizedStringKey`.** SwiftUI's automatic lookup always goes
/// through the *view's* bundle and the *system's* language, which would make
/// `AppSettings.language` unimplementable without a relaunch. The package's
/// accessors return a plain `String`, which every SwiftUI initializer also
/// accepts and renders verbatim — the string has already been localized.
///
/// **What is not routed through the catalogue.** Proper nouns and
/// identifiers: company, SubProvider, and harness names, model ids, MCP tool
/// names, every JSON key and contract value, file paths, and `SafeLog`
/// output. See `AGENTS.md` § 7.1; `Scripts/lint_localization.py` enforces
/// the split on the migrated files.
public enum AppLocalization {
    /// Languages this build ships, most-preferred spelling first. Must match
    /// `L10n.availableLocales` — `LocalizationCatalogTests` checks — and is
    /// spelled out here because `AppLanguage` and `Info.plist` name the same
    /// list and a test has to hold all three together.
    public static let supported: [String] = ["en", "zh-Hans"]

    /// The language every lookup falls back to. `en` is the authoring
    /// language, so it is the one catalogue guaranteed complete.
    public static let fallback = "en"

    // MARK: - Language selection

    /// The current override, `.system` unless the app installed one.
    ///
    /// Written from `SettingsStore` when `AppSettings.language` changes and
    /// once at load. Guarded rather than assumed main-thread: Core resolves
    /// strings from background work too (adapters building an error
    /// message, the MCP surface).
    public static var languageOverride: AppLanguage {
        get { state.withLock { $0.override } }
        set {
            state.withLock { current in
                guard current.override != newValue else { return }
                current.override = newValue
                current.resolvedCode = nil
            }
            // Pushed on every assignment, not only on a change: the first
            // one at launch is `.system` written over `.system`, and it is
            // the one that has to hand the package its locale before any
            // string is read — otherwise the package's own, looser matching
            // answers until something else happens to resolve the language.
            push()
        }
    }

    /// The `.lproj` code actually in force — the override when there is
    /// one, otherwise the first `supported` entry that matches
    /// `Locale.preferredLanguages`, otherwise `fallback`.
    ///
    /// Resolving `.system` ourselves rather than leaning on the package's
    /// bundle matching is deliberate. It is nearly the same answer — a
    /// per-app language chosen in System Settings, or `-AppleLanguages` on
    /// the command line, both land in `Locale.preferredLanguages` for this
    /// process — but it is a rule that can be read, tested, and reasoned
    /// about from one function, and it is the rule that keeps Traditional
    /// and Simplified apart.
    public static var resolvedLanguageCode: String {
        let code: String = state.withLock { current in
            if let cached = current.resolvedCode { return cached }
            let code = resolve(override: current.override)
            current.resolvedCode = code
            return code
        }
        push()
        return code
    }

    /// Recompute `.system`'s answer. Call when the process learns its
    /// preferred languages changed; harmless otherwise.
    public static func invalidateLanguageCache() {
        state.withLock { $0.resolvedCode = nil }
        push()
    }

    static func resolve(override: AppLanguage) -> String {
        if let explicit = override.localizationCode, supported.contains(explicit) {
            return explicit
        }
        // `VIBEBAR_LANGUAGE` is a diagnostic hook, not a product feature:
        // it lets a packaged-build smoke test prove a translated string
        // resolves without touching the user's settings file.
        if let environment = ProcessInfo.processInfo.environment["VIBEBAR_LANGUAGE"],
           supported.contains(environment) {
            return environment
        }
        return bestMatch(for: Locale.preferredLanguages) ?? fallback
    }

    /// First supported language that a preferred-language tag selects.
    ///
    /// Matching is on the tag's language plus script rather than on the
    /// whole tag, because macOS hands us region-qualified spellings
    /// (`zh-Hans-US`, `en-GB`) that no bundle is ever named after. A
    /// `zh-Hant` reader is deliberately *not* matched onto `zh-Hans`:
    /// Traditional and Simplified are different catalogs, and serving
    /// the wrong one is worse than serving English.
    static func bestMatch(for preferred: [String]) -> String? {
        let table: [(code: String, language: String, script: String?)] = supported.map {
            let locale = Locale(identifier: $0)
            return ($0, locale.language.languageCode?.identifier ?? $0,
                    locale.language.script?.identifier)
        }
        for tag in preferred {
            let candidate = Locale(identifier: tag).language
            guard let language = candidate.languageCode?.identifier else { continue }
            let script = candidate.script?.identifier
            if let hit = table.first(where: {
                $0.language == language && ($0.script == nil || $0.script == script)
            }) {
                return hit.code
            }
        }
        return nil
    }

    // MARK: - Handing the answer to the catalogue

    /// Tell the package which locale to serve. Idempotent and cheap: the
    /// package drops its cached bundle only when the value changes.
    private static func push() {
        let code: String = state.withLock { current in
            if let cached = current.resolvedCode { return cached }
            let code = resolve(override: current.override)
            current.resolvedCode = code
            return code
        }
        if L10n.localeOverride != code {
            L10n.localeOverride = code
        }
    }

    private struct State {
        var override: AppLanguage = .system
        var resolvedCode: String?
    }

    private static let state = Mutex(State())
}

/// Minimal lock box. Core targets the v5 language mode, so this exists to
/// make the shared mutable state above obviously guarded rather than to
/// satisfy a checker.
private final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
