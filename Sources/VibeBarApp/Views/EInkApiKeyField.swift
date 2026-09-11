import SwiftUI
import VibeBarCore

/// Secure field for the Dot. API key.
///
/// Shaped like `MiscProviderSettingsSection`'s `ApiKeyField`, but that one is
/// hard-wired to `MiscCredentialStore` and a `ToolType`; the E-ink key has its
/// own Keychain service and no provider behind it. The draft never leaves this
/// view, the value is never logged, and `settings.json` only ever learns the
/// boolean that `onChange` reports.
struct EInkApiKeyField: View {
    /// Called with the new presence after a successful save or clear, so the
    /// caller can mirror it into `EInkSyncSettings.apiKeyPresent`.
    let onChange: (Bool) -> Void

    @State private var draft = ""
    @State private var hasStored = false
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SecureField(L10n.Settings.Eink.apiKeyPrompt, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button(L10n.Common.save, action: save)
                    .buttonStyle(.vibeBar)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasStored {
                    Button(role: .destructive, action: clear) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.vibeBar)
                    .help(L10n.Settings.Misc.removeApiKey(provider: "Dot."))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: hasStored ? "checkmark.circle.fill" : "info.circle")
                    .font(.caption2)
                    .foregroundStyle(hasStored ? Color.green : Color.secondary)
                Text(hasStored ? L10n.Settings.Misc.apiKeySaved : L10n.Settings.Eink.apiKeyHelp)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let saveError {
                Text(saveError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .onAppear { hasStored = EInkCredentialStore.hasAPIKey() }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try EInkCredentialStore.writeAPIKey(trimmed)
            draft = ""
            hasStored = true
            saveError = nil
            onChange(true)
        } catch {
            saveError = L10n.Error.keychainSave
        }
    }

    private func clear() {
        try? EInkCredentialStore.deleteAPIKey()
        draft = ""
        hasStored = EInkCredentialStore.hasAPIKey()
        saveError = nil
        onChange(hasStored)
    }
}
