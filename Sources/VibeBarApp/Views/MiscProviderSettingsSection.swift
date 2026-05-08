import SwiftUI
import VibeBarCore

/// Per-misc-provider Settings row.
///
/// This is the skeleton landing in Phase 4 — every provider shows
/// its name, an enable toggle backed by `MiscProviderSettings`, and
/// a "Setup pending" placeholder. Each subsequent phase replaces
/// the placeholder with the real controls (API key field, paste
/// area, source-mode picker, etc.) for that provider's auth model.
struct MiscProviderSettingsSection: View {
    let tool: ToolType

    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: tool.miscFallbackSymbol)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(tool.menuTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(tool.subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                sourceModePicker
            }
            placeholderRow
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    @ViewBuilder
    private var sourceModePicker: some View {
        Picker("", selection: sourceModeBinding) {
            ForEach(MiscProviderSettings.SourceMode.allCases, id: \.self) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: 140)
    }

    @ViewBuilder
    private var placeholderRow: some View {
        switch tool {
        case .zai:
            ApiKeyField(tool: .zai, prompt: "Paste Z.ai API key (zai-...)", helpText: "Find it under z.ai → API Keys. Stored in macOS Keychain.")
        case .copilot:
            VStack(alignment: .leading, spacing: 4) {
                ApiKeyField(
                    tool: .copilot,
                    prompt: "Paste GitHub PAT (ghp_... or github_pat_...)",
                    helpText: "Needs the read:user + copilot scopes. Stored in macOS Keychain. (Device-flow sign-in coming later.)"
                )
                EnterpriseHostField(tool: .copilot, prompt: "GitHub Enterprise host (optional, e.g. github.example.com)")
            }
        case .gemini:
            GeminiCredentialStatusRow()
        case .alibaba:
            VStack(alignment: .leading, spacing: 4) {
                ApiKeyField(
                    tool: .alibaba,
                    prompt: "Paste DashScope API key (sk-...)",
                    helpText: "Find it at bailian.console.aliyun.com → API-KEY. Stored in macOS Keychain. (Console-cookie fallback coming later.)"
                )
                AlibabaRegionPicker()
            }
        case .antigravity, .minimax, .kimi, .cursor:
            // Each one gets its own controls as the matching adapter
            // lands on this branch. For now, render the same hint
            // string the user already saw in Phase 4.
            Text(setupHint)
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .codex, .claude:
            EmptyView()
        }
    }

    private var setupHint: String {
        switch tool {
        case .alibaba:     return "API key + optional browser cookie fallback (coming soon)."
        case .gemini:      return "Reads ~/.gemini/oauth_creds.json (coming soon)."
        case .antigravity: return "Local language-server probe (coming soon)."
        case .copilot:     return "GitHub PAT (coming soon)."
        case .zai:         return ""
        case .minimax:     return "Browser cookie auto-import (coming soon)."
        case .kimi:        return "Browser cookie auto-import (coming soon)."
        case .cursor:      return "Browser cookie auto-import (coming soon)."
        case .codex, .claude:
            return ""
        }
    }

    private var sourceModeBinding: Binding<MiscProviderSettings.SourceMode> {
        Binding(
            get: { settingsStore.settings.miscProvider(tool).sourceMode },
            set: { newValue in
                var current = settingsStore.settings.miscProvider(tool)
                current.sourceMode = newValue
                settingsStore.settings.setMiscProvider(current, for: tool)
            }
        )
    }
}

/// Secure-text input for misc-provider API keys / PATs.
///
/// Reads/writes through `MiscCredentialStore` (Keychain) — the
/// pasted value never lands in `~/.vibebar/settings.json`.
/// On save we trigger a one-shot refresh of the underlying tool so
/// the misc card flips out of "Set up" state immediately.
struct ApiKeyField: View {
    let tool: ToolType
    let prompt: String
    let helpText: String

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService
    @State private var draft: String = ""
    @State private var hasStored: Bool = false
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SecureField(prompt, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save", action: save)
                    .disabled(draft.isEmpty)
                if hasStored {
                    Button(role: .destructive, action: clear) {
                        Image(systemName: "trash")
                    }
                    .help("Remove stored \(tool.menuTitle) API key")
                }
            }
            HStack(spacing: 4) {
                Image(systemName: hasStored ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(hasStored ? Color.green : Color.secondary)
                    .font(.caption)
                Text(hasStored ? "API key saved in Keychain." : helpText)
                    .font(.caption)
                    .foregroundStyle(hasStored ? .secondary : .tertiary)
            }
            if let saveError {
                Text(saveError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .onAppear { hasStored = MiscCredentialStore.hasValue(tool: tool, kind: .apiKey) }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let ok = MiscCredentialStore.writeString(trimmed, tool: tool, kind: .apiKey)
        if ok {
            saveError = nil
            hasStored = true
            draft = ""
            triggerRefresh()
        } else {
            saveError = "Could not save to Keychain."
        }
    }

    private func clear() {
        MiscCredentialStore.delete(tool: tool, kind: .apiKey)
        hasStored = false
        triggerRefresh()
    }

    private func triggerRefresh() {
        guard let account = environment.account(for: tool) else { return }
        Task { _ = await quotaService.refresh(account) }
    }
}

/// Read-only status row for Gemini.
///
/// The user authenticates via the `gemini` CLI itself, which writes
/// `~/.gemini/oauth_creds.json`. Vibe Bar reads that file and pings
/// `cloudcode-pa.googleapis.com` — there's no value to enter here,
/// just a status indicator and a "re-check" button.
struct GeminiCredentialStatusRow: View {
    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService
    @State private var status: Status = .unknown

    enum Status: Equatable {
        case unknown
        case missing
        case expired
        case fresh(email: String?, expiresIn: TimeInterval)
    }

    var body: some View {
        HStack(spacing: 6) {
            statusBadge
            Spacer(minLength: 4)
            Button("Recheck", action: refresh)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .onAppear { reload() }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .unknown:
            Label("Reading ~/.gemini/oauth_creds.json…",
                  systemImage: "ellipsis.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .missing:
            Label("Run `gemini` once to sign in. Vibe Bar reads ~/.gemini/oauth_creds.json.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .expired:
            Label("Token expired — run any `gemini` command to refresh.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        case let .fresh(email, expiresIn):
            VStack(alignment: .leading, spacing: 2) {
                Label(email ?? "Token loaded.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text("Token expires in \(formatRemaining(expiresIn)).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func reload() {
        let url = URL(fileURLWithPath: RealHomeDirectory.path)
            .appendingPathComponent(".gemini/oauth_creds.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            status = .missing
            return
        }
        guard let creds = try? GeminiCredentials.load(from: url),
              let token = creds.accessToken, !token.isEmpty else {
            status = .missing
            return
        }
        let now = Date()
        if let expiry = creds.expiry, expiry < now {
            status = .expired
            return
        }
        let remaining = creds.expiry.map { $0.timeIntervalSince(now) } ?? 0
        status = .fresh(email: GeminiCredentials.email(from: creds.idToken), expiresIn: remaining)
    }

    private func refresh() {
        reload()
        guard let account = environment.account(for: .gemini) else { return }
        Task { _ = await quotaService.refresh(account) }
    }

    private func formatRemaining(_ seconds: TimeInterval) -> String {
        let abs = max(0, Int(seconds))
        if abs >= 3600 {
            return "\(abs / 3600)h \(abs / 60 % 60)m"
        }
        return "\(abs / 60)m"
    }
}

/// Region picker for Alibaba — international (ap-southeast-1) vs.
/// china-mainland (cn-beijing). "Auto" lets the adapter try both
/// in order on each refresh.
struct AlibabaRegionPicker: View {
    @EnvironmentObject var settingsStore: SettingsStore

    enum Choice: String, CaseIterable, Identifiable {
        case auto = ""
        case international = "ap-southeast-1"
        case chinaMainland = "cn-beijing"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto:           return "Auto (try both)"
            case .international:  return "International (ap-southeast-1)"
            case .chinaMainland:  return "China mainland (cn-beijing)"
            }
        }
    }

    var body: some View {
        Picker("Region", selection: choiceBinding) {
            ForEach(Choice.allCases) { choice in
                Text(choice.label).tag(choice)
            }
        }
        .pickerStyle(.menu)
    }

    private var choiceBinding: Binding<Choice> {
        Binding(
            get: {
                let raw = settingsStore.settings.miscProvider(.alibaba).region ?? ""
                return Choice(rawValue: raw) ?? .auto
            },
            set: { newValue in
                var current = settingsStore.settings.miscProvider(.alibaba)
                current.region = newValue == .auto ? nil : newValue.rawValue
                settingsStore.settings.setMiscProvider(current, for: .alibaba)
            }
        )
    }
}

/// Plain-text input for `MiscProviderSettings.enterpriseHost`.
/// Lives in `~/.vibebar/settings.json`; adapters that support a
/// self-hosted endpoint (Copilot Enterprise, Z.ai self-host) read
/// it through `AppSettings.miscProvider(...).enterpriseHost`.
struct EnterpriseHostField: View {
    let tool: ToolType
    let prompt: String

    @EnvironmentObject var settingsStore: SettingsStore
    @State private var draft: String = ""

    var body: some View {
        HStack(spacing: 6) {
            TextField(prompt, text: $draft, onCommit: save)
                .textFieldStyle(.roundedBorder)
            Button("Save", action: save)
                .disabled(draft == currentRaw)
        }
        .onAppear { draft = currentRaw }
    }

    private var currentRaw: String {
        settingsStore.settings.miscProvider(tool).enterpriseHost?.absoluteString ?? ""
    }

    private func save() {
        var current = settingsStore.settings.miscProvider(tool)
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            current.enterpriseHost = nil
        } else if let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)") {
            current.enterpriseHost = url
        } else {
            return
        }
        settingsStore.settings.setMiscProvider(current, for: tool)
    }
}
