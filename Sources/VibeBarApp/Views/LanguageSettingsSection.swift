import SwiftUI
import VibeBarCore

/// The in-app language override.
///
/// Self-contained on purpose, in the shape the other `*SettingsSection`
/// files already use, so the System section mounts it with one line:
///
/// ```swift
/// LanguageSettingsSection(density: density)
/// ```
///
/// Changing the value takes effect immediately, with no relaunch.
/// `SettingsStore` mirrors `settings.language` into `L10n` on every
/// assignment, and the same assignment publishes to every `$settings`
/// subscriber — so the pass that redraws this picker redraws every label
/// around it. The only surfaces that would need a restart are ones AppKit
/// builds once and never re-evaluates; none of them is reached from here.
struct LanguageSettingsSection: View {
    let density: Theme.Density

    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        SettingsSectionCard(title: L10n.Settings.languageTitle, density: density) {
            Picker(L10n.Settings.languageTitle, selection: languageBinding) {
                ForEach(AppLanguage.allCases, id: \.self) { language in
                    // Each language is labelled in itself — 简体中文, not
                    // "Simplified Chinese". Someone looking for their own
                    // language should not have to read the one they are
                    // trying to leave to find it.
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 220, alignment: .leading)

            Text(L10n.Settings.languageCaption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { settingsStore.settings.language },
            set: { settingsStore.settings.language = $0 }
        )
    }
}
