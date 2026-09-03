import SwiftUI
import VibeBarCore

/// What the Misc Providers pane shows before the user picks a provider
/// from the sidebar.
///
/// It hosts the two controls that are about *all* cookie-sourced
/// providers at once rather than any single one: a batch browser import,
/// and the opt-in silent re-import setting. Per-provider controls stay
/// in `MiscProviderSettingsSection`.
struct MiscProviderLandingView: View {
    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore

    @State private var isImporting = false
    @State private var outcomes: [MiscCookieResolver.BatchImportOutcome] = []
    @State private var cooldowns: [BrowserCookieAccessGate.Cooldown] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Select a provider from the sidebar. Hidden providers keep their saved setup and credentials.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Text("Browser Cookies")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            if cookieTargets.isEmpty {
                Text("No cookie-based providers are configured.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 8) {
                    Button(action: importAll) {
                        Label(
                            "Import Browser Cookies for All Providers",
                            systemImage: "safari"
                        )
                    }
                    .disabled(isImporting)
                    if isImporting {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                Text("Reads your browsers once for all \(cookieTargets.count) cookie-based providers and adds or refreshes the first signed-in profile found for each. Existing slots from other profiles stay stacked; quotas are averaged across them. macOS may ask for your login-keychain password once per Chromium-family browser involved.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if isImporting {
                    Text("Importing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !outcomes.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(outcomes, id: \.instanceID) { outcome in
                            OutcomeRow(
                                title: displayName(forInstanceID: outcome.instanceID, tool: outcome.tool),
                                outcome: outcome.result
                            )
                        }
                    }
                }

                cooldownControls
            }

            Divider()

            Toggle(
                "Auto re-import from browser when cookies expire",
                isOn: autoImportBinding
            )
            Text("Off by default. When on, a provider that reports \"Needs re-login\" gets one silent re-read of your browser cookie store before the error is shown. It never asks for your Keychain password on its own — pasted cookies are left untouched.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .onAppear { cooldowns = BrowserCookieAccessGate.activeCooldowns() }
    }

    /// Declining a Chromium "Safe Storage" prompt parks that browser for
    /// six hours, and every import in the meantime honestly finds nothing —
    /// which used to be reported as "no signed-in session found". Show the
    /// suppression and the way out of it.
    @ViewBuilder
    private var cooldownControls: some View {
        if !cooldowns.isEmpty {
            Divider()
                .padding(.vertical, 2)
            ForEach(cooldowns, id: \.browserName) { cooldown in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "lock.slash")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .frame(width: 12)
                    Text("macOS Keychain access for \(cooldown.browserName) was declined. Vibe Bar will not ask again until \(Self.timeFormatter.string(from: cooldown.until)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                }
            }
            Button("Reset browser-cookie cooldown") {
                BrowserCookieAccessGate.reset()
                cooldowns = []
            }
            .controlSize(.small)
        }
    }

    // Built per language rather than once per process: a formatter
    // parked in a `static let` keeps the language it was created in.
    private static var timeFormatter: DateFormatter {
        AppLocale.dateFormatter(dateStyle: .none, timeStyle: .short)
    }

    private var autoImportBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.miscCookieAutoImportEnabled },
            set: { settingsStore.settings.miscCookieAutoImportEnabled = $0 }
        )
    }

    /// Every configured provider instance whose credentials are browser
    /// cookies, in sidebar order.
    private var cookieTargets: [MiscCookieResolver.BatchImportTarget] {
        settingsStore.settings.miscProviderInstances.compactMap { instance in
            guard let spec = MiscCookieSpecCatalog.spec(for: instance.tool) else { return nil }
            return MiscCookieResolver.BatchImportTarget(spec: spec, instanceID: instance.id)
        }
    }

    private func displayName(forInstanceID instanceID: String, tool: ToolType) -> String {
        let instance = settingsStore.settings.miscProviderInstance(id: instanceID)
        let copies = settingsStore.settings.miscProviderInstances.filter { $0.tool == tool }
        guard copies.count > 1 else { return instance?.displayName ?? tool.menuTitle }
        let index = (copies.firstIndex { $0.id == instanceID } ?? 0) + 1
        return instance?.displayName ?? "\(tool.menuTitle) (Copy \(index))"
    }

    private func importAll() {
        let targets = cookieTargets
        guard !targets.isEmpty else { return }
        isImporting = true
        outcomes = []
        // Off the main thread: this walks browser cookie stores and
        // writes the Keychain once per provider.
        DispatchQueue.global(qos: .userInitiated).async {
            let results = MiscCookieResolver.appendBrowserImports(for: targets)
            DispatchQueue.main.async {
                isImporting = false
                outcomes = results
                cooldowns = BrowserCookieAccessGate.activeCooldowns()
                // One refresh for the whole batch rather than one per
                // provider — the quota service fans out on its own.
                environment.refreshAll()
            }
        }
    }
}

/// One provider's line in the batch-import result list.
private struct OutcomeRow: View {
    let title: String
    let outcome: MiscCookieResolver.BatchImportOutcome.Result

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(tint)
                .frame(width: 12)
            Text(title)
                .font(.caption)
            Spacer(minLength: 6)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var symbol: String {
        switch outcome {
        case .imported:         return "checkmark.circle"
        case .noSessionFound:   return "minus.circle"
        case .keychainCooldown: return "lock.slash"
        case .cookiesDisabled:  return "slash.circle"
        case .saveFailed:       return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch outcome {
        case .imported:                         return .green
        case .noSessionFound, .cookiesDisabled: return .secondary
        case .keychainCooldown, .saveFailed:    return .orange
        }
    }

    private var detail: String {
        switch outcome {
        case .imported(let sourceLabel):
            return "Imported from \(sourceLabel)"
        case .noSessionFound:
            return "No signed-in session found"
        case let .keychainCooldown(browser, until):
            return "\(browser) Keychain access declined until \(Self.timeFormatter.string(from: until))"
        case .cookiesDisabled:
            // Reachable only through a hand-edited settings.json: the
            // source-mode fields have no UI and every instance is created
            // with `automaticSourceSelection`.
            return "Cookie sources turned off in settings.json"
        case .saveFailed:
            return "Could not save to Keychain"
        }
    }

    // Built per language rather than once per process: a formatter
    // parked in a `static let` keeps the language it was created in.
    private static var timeFormatter: DateFormatter {
        AppLocale.dateFormatter(dateStyle: .none, timeStyle: .short)
    }
}
