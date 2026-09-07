import SwiftUI
import VibeBarCore

/// Puts the app's own language into the SwiftUI environment.
///
/// Every string Vibe Bar authors goes through `L10n`, which follows
/// `AppSettings.language`. Everything SwiftUI and Foundation format
/// themselves — `Text(date, style: .relative)`, a `DatePicker`'s month
/// names, a chart axis's dates, `.percent` and `.number` styles — resolve
/// their locale from the environment instead, and the environment's default
/// is `Locale.current`: the language macOS is set to.
///
/// So on a Chinese Mac those fields render Chinese whatever the app's
/// language is. They look right while the app is Chinese and read as
/// "stuck in Chinese" the moment it is switched back to English — which is
/// exactly what a user sees. `UsageTrendChartView` already passed
/// `AppLocale.current` by hand for its axis; this does it once, for every
/// surface, so the next `Text(_, style:)` written does not have to remember.
///
/// It reads the settings store so the value is re-derived when the language
/// changes: the modifier's body re-runs on the same publish that re-renders
/// the rest of the window. Apply it *innermost*, before the
/// `environmentObject` chain, so the store is already in the environment.
private struct AppLanguageLocaleModifier: ViewModifier {
    @EnvironmentObject private var settingsStore: SettingsStore

    func body(content: Content) -> some View {
        content.environment(\.locale, AppLocale.current)
    }
}

extension View {
    /// See `AppLanguageLocaleModifier`. Every window and popover root wears
    /// this; a surface without it formats dates in the system's language.
    func appLanguageLocale() -> some View {
        modifier(AppLanguageLocaleModifier())
    }
}
