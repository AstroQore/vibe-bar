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
    /// What `EInkSyncSettings.apiKeyPresent` currently says. The Keychain is
    /// the truth; this is compared against it on appear so a `settings.json`
    /// that was reset, lost, or restored beside a Vault that still holds the
    /// key cannot leave every control disabled under a "key saved" badge.
    let mirroredPresence: Bool
    /// Called with the new presence after a successful save or clear — and on
    /// appear when the mirror disagrees with the Keychain.
    let onChange: (Bool) -> Void

    @State private var draft = ""
    @State private var hasStored = false
    @State private var saveError: String?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SecureField(L10n.Settings.Eink.apiKeyPrompt, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button(L10n.Common.save, action: save)
                    .buttonStyle(.vibeBar)
                    .disabled(isWorking || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasStored {
                    Button(role: .destructive, action: clear) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.vibeBar)
                    .help(L10n.Settings.Misc.removeApiKey(provider: "Dot."))
                    .disabled(isWorking)
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
        // Detached: the Vault read can reach the Keychain, and a settings
        // pane that blocks its first frame on that is the stall AGENTS.md § 7
        // treats as a bug.
        .task {
            let present = await Task.detached(priority: .userInitiated) {
                EInkCredentialStore.hasAPIKey()
            }.value
            hasStored = present
            if present != mirroredPresence { onChange(present) }
        }
    }

    /// Both mutations run detached. The Vault does a read-modify-write of one
    /// Keychain item, and on a locked or slow Keychain that is seconds — long
    /// enough for a Settings pane to look hung on the click that started it.
    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isWorking else { return }
        isWorking = true
        Task {
            let wrote = await Task.detached(priority: .userInitiated) {
                (try? EInkCredentialStore.writeAPIKey(trimmed)) != nil
            }.value
            isWorking = false
            guard wrote else {
                saveError = L10n.Error.keychainSave
                return
            }
            draft = ""
            hasStored = true
            saveError = nil
            onChange(true)
        }
    }

    private func clear() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            let present = await Task.detached(priority: .userInitiated) { () -> Bool in
                try? EInkCredentialStore.deleteAPIKey()
                return EInkCredentialStore.hasAPIKey()
            }.value
            isWorking = false
            draft = ""
            hasStored = present
            saveError = nil
            onChange(present)
        }
    }
}
