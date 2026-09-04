import Foundation

/// The in-app language override.
///
/// `.system` is the default and means "whatever macOS resolves for this
/// app" — the per-app choice in System Settings › General › Language &
/// Region › Applications, or the login language when the user made no
/// per-app choice. The two explicit cases exist because a menu-bar
/// utility is often read alongside terminals and consoles the user
/// deliberately keeps in one language, and forcing them through the
/// system-wide control to change only this app is a worse answer.
///
/// The raw value of an explicit case is also the name of its `.lproj`
/// directory, so `L10n` can resolve a bundle from it without a second
/// mapping table to keep in step.
public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    /// The `.lproj` basename, or nil for `.system` (which has none —
    /// the language is resolved from `Locale.preferredLanguages`).
    public var localizationCode: String? {
        self == .system ? nil : rawValue
    }

    /// The language's own endonym. A language picker that labels 简体中文
    /// as "Simplified Chinese" is only readable by someone who already
    /// reads the language they are trying to leave, so the explicit cases
    /// are never translated; only "System" is.
    public var displayName: String {
        switch self {
        case .system:            return L10n.Settings.Language.system
        case .english:          return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }
}
