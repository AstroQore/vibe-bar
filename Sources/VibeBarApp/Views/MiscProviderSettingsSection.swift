import AppKit
import SwiftUI
import VibeBarCore

/// Per-misc-provider Settings row.
///
/// Each provider shows its name, source-mode picker, and the auth
/// controls that match the provider's current integration path
/// (API key, device login, local CLI/OAuth status, browser-cookie
/// import, or local process probe).
struct MiscProviderSettingsSection: View {
    let tool: ToolType

    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                ToolBrandBadge(tool: tool, iconSize: 17, containerSize: 24)
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
                CopilotDeviceLoginRow()
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
        case .minimax:
            CookieSourceControls(
                tool: .minimax,
                spec: MiniMaxQuotaAdapter.cookieSpec,
                manualPrompt: "Paste platform.minimax.io Cookie header (HERTZ-SESSION=...)"
            )
        case .kimi:
            CookieSourceControls(
                tool: .kimi,
                spec: KimiQuotaAdapter.cookieSpec,
                manualPrompt: "Paste www.kimi.com Cookie header (kimi-auth=eyJ...)"
            )
        case .cursor:
            CookieSourceControls(
                tool: .cursor,
                spec: CursorQuotaAdapter.cookieSpec,
                manualPrompt: "Paste cursor.com Cookie header (WorkosCursorSessionToken=...)"
            )
        case .mimo:
            CookieSourceControls(
                tool: .mimo,
                spec: MimoQuotaAdapter.cookieSpec,
                manualPrompt: "Paste platform.xiaomimimo.com Cookie header (userId=...; api-platform_slh=...; api-platform_ph=...)"
            )
        case .antigravity:
            AntigravityStatusRow()
        case .codex, .claude:
            EmptyView()
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

/// GitHub Copilot sign-in via OAuth device flow. This replaces the
/// old PAT-first setup while keeping legacy PATs readable in Core as
/// a migration fallback.
struct CopilotDeviceLoginRow: View {
    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService
    @EnvironmentObject var settingsStore: SettingsStore

    @State private var isSigningIn = false
    @State private var hasStoredToken = false
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(
                    hasStoredToken ? "GitHub device token saved in Keychain." : "Sign in with GitHub device flow.",
                    systemImage: hasStoredToken ? "checkmark.circle.fill" : "person.crop.circle.badge.key"
                )
                .font(.caption)
                .foregroundStyle(hasStoredToken ? Color.green : Color.secondary)

                Spacer(minLength: 4)

                Button(isSigningIn ? "Waiting..." : "Sign in") {
                    startLogin()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isSigningIn)

                if hasStoredToken {
                    Button(role: .destructive, action: clearToken) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove stored GitHub device token")
                }
            }

            if let status {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(status.hasPrefix("GitHub signed in") ? .green : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: reloadStoredToken)
    }

    private func startLogin() {
        guard !isSigningIn else { return }
        isSigningIn = true
        status = "Requesting GitHub device code..."

        Task { @MainActor in
            defer {
                isSigningIn = false
                reloadStoredToken()
            }

            let host = settingsStore.settings.miscProvider(.copilot).enterpriseHost?.absoluteString
            let flow = CopilotDeviceFlow(enterpriseHost: host)
            do {
                let code = try await flow.requestDeviceCode()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code.userCode, forType: .string)

                status = "Code \(code.userCode) copied. Complete GitHub authorization in the browser."
                if let url = URL(string: code.verificationURLToOpen) {
                    NSWorkspace.shared.open(url)
                }

                let token = try await flow.pollForToken(
                    deviceCode: code.deviceCode,
                    interval: code.interval
                )
                guard MiscCredentialStore.writeString(
                    token,
                    tool: .copilot,
                    kind: .oauthAccessToken
                ) else {
                    status = "GitHub login succeeded, but Vibe Bar could not save the token."
                    return
                }
                guard MiscCredentialStore.hasValue(tool: .copilot, kind: .oauthAccessToken) else {
                    status = "GitHub login succeeded, but saved token could not be read back."
                    return
                }

                // Hide the old PAT path once device auth succeeds.
                MiscCredentialStore.delete(tool: .copilot, kind: .apiKey)
                status = "GitHub signed in."
                triggerRefresh()
            } catch is CancellationError {
                status = "GitHub login cancelled."
            } catch {
                status = "GitHub login failed: \(SafeLog.sanitize(error.localizedDescription))"
            }
        }
    }

    private func clearToken() {
        MiscCredentialStore.delete(tool: .copilot, kind: .oauthAccessToken)
        MiscCredentialStore.delete(tool: .copilot, kind: .apiKey)
        hasStoredToken = false
        status = "GitHub token cleared."
        triggerRefresh()
    }

    private func reloadStoredToken() {
        hasStoredToken =
            MiscCredentialStore.hasValue(tool: .copilot, kind: .oauthAccessToken) ||
            MiscCredentialStore.hasValue(tool: .copilot, kind: .apiKey)
    }

    private func triggerRefresh() {
        guard let account = environment.account(for: .copilot) else { return }
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

/// AntiGravity has no remote credential — it talks to a locally
/// running language server. The settings row is a tiny status
/// indicator + manual refresh; the real action happens on the misc
/// card itself.
struct AntigravityStatusRow: View {
    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text("Reads the locally running language_server_macos process. Open AntiGravity, then refresh.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            Button("Probe", action: probe)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func probe() {
        guard let account = environment.account(for: .antigravity) else { return }
        Task { _ = await quotaService.refresh(account) }
    }
}

/// Cookie-source picker + Import / Manual paste controls for the
/// browser-cookie misc providers (MiniMax, Kimi). Wraps three
/// concerns:
///
/// 1. `MiscProviderSettings.cookieSource` — auto / manual / off
/// 2. "Import from browser now" button — re-runs the cookie pipeline
///    immediately, useful after the user signs in to the provider
///    in their browser.
/// 3. Manual paste field — for users who prefer copying the
///    `Cookie:` header by hand or whose browser cookie store is
///    locked.
struct CookieSourceControls: View {
    let tool: ToolType
    let spec: MiscCookieResolver.Spec
    let manualPrompt: String

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService
    @EnvironmentObject var settingsStore: SettingsStore

    @State private var manualDraft: String = ""
    @State private var importStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Picker("Cookie source", selection: cookieSourceBinding) {
                    ForEach(ProviderCookieSource.allCases, id: \.self) { mode in
                        Text(modeLabel(mode)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(maxWidth: 280)

                Button("Import now", action: importNow)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(cookieSourceBinding.wrappedValue == .off ||
                              cookieSourceBinding.wrappedValue == .manual)
            }
            HStack(spacing: 6) {
                SecureField(manualPrompt, text: $manualDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Save", action: saveManual)
                    .disabled(manualDraft.isEmpty)
                if hasManualValue {
                    Button(role: .destructive, action: clearManual) {
                        Image(systemName: "trash")
                    }
                    .help("Remove pasted cookie")
                }
            }
            if let importStatus {
                Text(importStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hasManualValue: Bool {
        MiscCredentialStore.hasValue(tool: tool, kind: .manualCookieHeader)
    }

    private var cookieSourceBinding: Binding<ProviderCookieSource> {
        Binding(
            get: { settingsStore.settings.miscProvider(tool).cookieSource },
            set: { newValue in
                var current = settingsStore.settings.miscProvider(tool)
                current.cookieSource = newValue
                settingsStore.settings.setMiscProvider(current, for: tool)
            }
        )
    }

    private func modeLabel(_ mode: ProviderCookieSource) -> String {
        switch mode {
        case .auto:   return "Auto"
        case .manual: return "Manual"
        case .off:    return "Off"
        }
    }

    private func importNow() {
        importStatus = "Importing…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = MiscCookieResolver.forceBrowserImport(for: spec)
            DispatchQueue.main.async {
                if let result {
                    importStatus = "Imported from \(result.sourceLabel)."
                    triggerRefresh()
                } else {
                    importStatus = "No cookies found. Sign in at the provider in your browser, then retry."
                }
            }
        }
    }

    private func saveManual() {
        let trimmed = manualDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let normalised = normalizedManualCookie(from: trimmed), !normalised.isEmpty else {
            importStatus = missingCookieMessage
            return
        }
        MiscCredentialStore.writeString(normalised, tool: tool, kind: .manualCookieHeader)
        CookieHeaderCache.clear(for: tool)
        importStatus = "Manual cookie saved."
        manualDraft = ""
        triggerRefresh()
    }

    private func clearManual() {
        MiscCredentialStore.delete(tool: tool, kind: .manualCookieHeader)
        CookieHeaderCache.clear(for: tool)
        importStatus = "Manual cookie cleared."
        triggerRefresh()
    }

    private func normalizedManualCookie(from raw: String) -> String? {
        if spec.requiredNames.isEmpty {
            return CookieHeaderNormalizer.normalize(raw)
        }
        return CookieHeaderNormalizer.filteredHeader(from: raw, allowedNames: spec.requiredNames)
    }

    private var missingCookieMessage: String {
        if spec.requiredNames.isEmpty {
            return "No usable cookie found in pasted text."
        }
        return "No \(spec.requiredNames.sorted().joined(separator: ", ")) cookie found in pasted text."
    }

    private func triggerRefresh() {
        guard let account = environment.account(for: tool) else { return }
        Task { _ = await quotaService.refresh(account) }
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
