import Foundation

/// The one place a user-visible string is resolved.
///
/// **Runtime is Apple-native, authoring is JSON.** Views call
/// `L10n.string("popover.tab.overview")`; the value comes out of a
/// standard `<lang>.lproj/Localizable.strings` through
/// `Bundle.localizedString`, so Foundation's own cached string table is
/// what serves the render path and no custom loader sits in a SwiftUI
/// `body`. Those `.strings` files are *generated* — the source of truth
/// is `Resources/i18n/<lang>.json`, compiled by
/// `Scripts/build_localizations.py`, and `LocalizationCatalogTests`
/// fails if the checked-in output has drifted from the JSON.
///
/// **Why not `LocalizedStringKey`.** SwiftUI's automatic lookup always
/// goes through the *view's* bundle and the *system's* language, which
/// would make `AppSettings.language` unimplementable without a relaunch.
/// Resolving here returns a plain `String`, which every SwiftUI
/// initializer also accepts (`Text`, `Button`, `Toggle`, `.help`, …) via
/// its `StringProtocol` overload, and which renders verbatim — the
/// string has already been localized, so a second pass would be wrong.
///
/// **How a caller reaches a string.** Through `L10n+Generated.swift`:
/// `L10n.Quota.resetsIn(duration:)`, `L10n.Common.refresh`. The raw
/// `string(_:)` below is *internal to VibeBarCore* on purpose, so no
/// call site outside Core can pull a key's format string out as text and
/// fill the arguments in by hand — the positional order is the
/// generator's business and differs per language. Core itself uses it
/// for the handful of genuinely computed keys (a month index), which is
/// reviewable in one place.
///
/// **What is not routed through here.** Proper nouns and identifiers:
/// company, SubProvider, and harness names, model ids, MCP tool names,
/// every JSON key and contract value, file paths, and `SafeLog` output.
/// See `AGENTS.md` § 7.1 — the naming-axis values keep coming from
/// `ToolType` and the naming contract untranslated, and this translated
/// layer wraps around them. `Scripts/lint_localization.py` enforces the
/// split on the migrated files.
public enum L10n {
    /// Languages this build ships, most-preferred spelling first. The
    /// generator writes exactly these `.lproj` directories.
    public static let supported: [String] = ["en", "zh-Hans"]

    /// The language every lookup falls back to. `en.json` is the
    /// authoring language, so it is the one catalog guaranteed complete.
    public static let fallback = "en"

    // MARK: - Language selection

    /// The current override, `.system` unless the app installed one.
    ///
    /// Written from `AppEnvironment` when `AppSettings.language` changes
    /// and read on every lookup, so it is guarded rather than assumed
    /// main-thread: Core resolves strings from background work too
    /// (adapters building an error message, the MCP surface).
    public static var languageOverride: AppLanguage {
        get { state.withLock { $0.override } }
        set {
            state.withLock { current in
                guard current.override != newValue else { return }
                current.override = newValue
                current.resolvedCode = nil
            }
        }
    }

    /// The `.lproj` code actually in force — the override when there is
    /// one, otherwise the first `supported` entry that matches
    /// `Locale.preferredLanguages`, otherwise `fallback`.
    ///
    /// Resolving `.system` ourselves rather than leaning on
    /// `Bundle.preferredLocalizations` is deliberate. It is the same
    /// answer — a per-app language chosen in System Settings, or
    /// `-AppleLanguages` on the command line, both land in
    /// `Locale.preferredLanguages` for this process — but it is a rule
    /// that can be read, tested, and reasoned about from one function
    /// instead of from bundle-resolution behaviour that differs between
    /// a packaged `.app` and an `xctest` run.
    public static var resolvedLanguageCode: String {
        state.withLock { current in
            if let cached = current.resolvedCode { return cached }
            let code = resolve(override: current.override)
            current.resolvedCode = code
            return code
        }
    }

    /// Recompute `.system`'s answer. Call when the process learns its
    /// preferred languages changed; harmless otherwise.
    public static func invalidateLanguageCache() {
        state.withLock { $0.resolvedCode = nil }
        bundles.withLock { $0.removeAll() }
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

    // MARK: - Lookup

    /// The localized value for `key`, or the key itself when no catalog
    /// has it (which `LocalizationCatalogTests` makes a build-time
    /// failure rather than something a user can reach).
    static func string(_ key: String) -> String {
        let code = resolvedLanguageCode
        if let hit = lookup(key, in: code) { return hit }
        if code != fallback, let hit = lookup(key, in: fallback) { return hit }
        return key
    }

    /// `string(_:)` with the arguments substituted.
    ///
    /// Composed sentences come through here rather than through
    /// concatenation at the call site: Chinese word order does not
    /// survive `"resets in " + countdown`, and a translator cannot move
    /// a fragment they never see. The catalog spells its arguments by
    /// name (`{days}`, `{provider}`); the generator turns those into the
    /// positional specifiers Foundation wants and emits an accessor that
    /// passes them in the English order, so a language that reorders the
    /// sentence needs no code change.
    ///
    /// The `locale:` argument is what selects a plural category out of
    /// the `.stringsdict`, so it follows the app's resolved language
    /// rather than the process locale.
    static func string(_ key: String, _ arguments: any CVarArg...) -> String {
        String(format: string(key), locale: Locale(identifier: resolvedLanguageCode),
               arguments: arguments)
    }

    private static func lookup(_ key: String, in code: String) -> String? {
        guard let bundle = bundle(for: code) else { return nil }
        // A miss returns the sentinel rather than the key, so a key whose
        // value legitimately *is* its own text is not mistaken for one.
        let value = bundle.localizedString(forKey: key, value: missSentinel, table: nil)
        return value == missSentinel ? nil : value
    }

    private static let missSentinel = "\u{0}vibebar.l10n.miss"

    /// The `.lproj` sub-bundle for `code`, memoized.
    ///
    /// Two hosts, one lookup: a packaged `Vibe Bar.app` carries the
    /// `.lproj` directories in `Contents/Resources` (`Bundle.main`),
    /// while `swift test`, `swift run`, and the SwiftPM build products
    /// have them inside `VibeBar_VibeBarCore.bundle` (`Bundle.module`).
    /// `Bundle.main` is checked first so an installed app always answers
    /// from its own resources.
    private static func bundle(for code: String) -> Bundle? {
        bundles.withLock { cache in
            if let cached = cache[code] { return cached.bundle }
            let resolved = [Bundle.main, Bundle.module]
                .compactMap { host -> String? in
                    if let exact = host.path(forResource: code, ofType: "lproj") {
                        return exact
                    }
                    // SwiftPM lowercases a locale directory when it builds a
                    // resource bundle, so Core's copy is `zh-hans.lproj` while
                    // the packaged app carries the conventional `zh-Hans.lproj`.
                    // Both name the same language; only a case-sensitive volume
                    // would ever tell them apart, and that is not a difference
                    // the user should be able to feel.
                    return host.localizations
                        .first { $0.caseInsensitiveCompare(code) == .orderedSame }
                        .flatMap { host.path(forResource: $0, ofType: "lproj") }
                }
                .compactMap(Bundle.init(path:))
                .first
            cache[code] = Box(bundle: resolved)
            return resolved
        }
    }

    private struct Box { let bundle: Bundle? }

    private struct State {
        var override: AppLanguage = .system
        var resolvedCode: String?
    }

    private static let state = Mutex(State())
    private static let bundles = Mutex([String: Box]())
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
