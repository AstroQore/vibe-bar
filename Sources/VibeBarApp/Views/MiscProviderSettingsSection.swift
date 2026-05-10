import AppKit
import SwiftUI
import VibeBarCore

/// Per-misc-provider Settings row.
///
/// Each provider shows its name and the auth controls that match the
/// provider's current integration path (API key, device login, local
/// CLI/OAuth status, browser-cookie import, or local process probe).
struct MiscProviderSettingsSection: View {
    let tool: ToolType

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
    private var placeholderRow: some View {
        switch tool {
        case .zai:
            VStack(alignment: .leading, spacing: 4) {
                ApiKeyField(tool: .zai, prompt: "Paste Z.ai API key (zai-...)", helpText: "Find it under z.ai → API Keys. Stored in macOS Keychain.")
                ZaiRegionPicker()
            }
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
            VStack(alignment: .leading, spacing: 4) {
                ApiKeyField(
                    tool: .minimax,
                    prompt: "Paste MiniMax Token Plan API key (sk-cp-...)",
                    helpText: "Find it under Billing → Token Plan. Stored in macOS Keychain."
                )
                MiniMaxRegionPicker()
            }
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
            VStack(alignment: .leading, spacing: 4) {
                CookieSourceControls(
                    tool: .mimo,
                    spec: MimoQuotaAdapter.cookieSpec,
                    manualPrompt: "Paste platform.xiaomimimo.com Cookie header (userId=...; api-platform_slh=...; api-platform_ph=...; api-platform_serviceToken=...)"
                )
                MiscWebLoginRow(
                    tool: .mimo,
                    helpText: "Chrome's newer cookie encryption blocks the browser-import path on macOS. Sign in via the in-app webview to capture cookies cleanly."
                )
            }
        case .iflytek:
            CookieSourceControls(
                tool: .iflytek,
                spec: IFlyTekQuotaAdapter.cookieSpec,
                manualPrompt: "Paste maas.xfyun.cn Cookie header (atp-auth-token=...)"
            )
        case .tencentHunyuan:
            TencentSubAccountLoginRow()
        case .volcengine:
            VolcengineSubAccountLoginRow()
        case .antigravity:
            AntigravityStatusRow()
        case .codex, .claude:
            EmptyView()
        }
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
            Label("Token expired — Vibe Bar will try a headless `gemini` keepalive on refresh.",
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

/// Browser-cookie controls for the misc providers. Import/manual source
/// selection is automatic; the UI only exposes recovery actions.
struct CookieSourceControls: View {
    let tool: ToolType
    let spec: MiscCookieResolver.Spec
    let manualPrompt: String

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService

    @State private var manualDraft: String = ""
    @State private var importStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button("Import now", action: importNow)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Text("Vibe Bar tries cached, browser, then pasted cookies automatically.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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

/// Z.ai has separate international and mainland China quota hosts.
struct ZaiRegionPicker: View {
    @EnvironmentObject var settingsStore: SettingsStore

    enum Choice: String, CaseIterable, Identifiable {
        case global
        case bigmodelCN = "bigmodel-cn"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .global:     return "Global (api.z.ai)"
            case .bigmodelCN: return "China mainland (open.bigmodel.cn)"
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
                let raw = settingsStore.settings.miscProvider(.zai).region ?? Choice.global.rawValue
                return Choice(rawValue: raw) ?? .global
            },
            set: { newValue in
                var current = settingsStore.settings.miscProvider(.zai)
                current.region = newValue.rawValue
                settingsStore.settings.setMiscProvider(current, for: .zai)
            }
        )
    }
}

/// MiniMax has separate minimax.io and minimaxi.com Token Plan hosts.
/// The adapter still falls back across both, but this picker controls
/// the preferred region tried first.
struct MiniMaxRegionPicker: View {
    @EnvironmentObject var settingsStore: SettingsStore

    enum Choice: String, CaseIterable, Identifiable {
        case global
        case chinaMainland = "cn"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .global:        return "Global (minimax.io)"
            case .chinaMainland: return "China mainland (minimaxi.com)"
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
                let raw = settingsStore.settings.miscProvider(.minimax).region ?? Choice.global.rawValue
                return Choice(rawValue: raw) ?? .global
            },
            set: { newValue in
                var current = settingsStore.settings.miscProvider(.minimax)
                current.region = newValue.rawValue
                settingsStore.settings.setMiscProvider(current, for: .minimax)
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

/// Sub-account password login form for Tencent Cloud Hunyuan.
///
/// Tencent's console exposes only a username/password sign-in path —
/// no API key or OAuth — so the user creates a permission-restricted
/// CAM sub-user, types `<sub-user>@<owner-uin-or-alias>` plus the
/// password here, and Vibe Bar runs the login flow on demand.
/// Username and password are stored in Keychain via
/// `MiscCredentialStore`; `~/.vibebar/settings.json` never sees them.
struct TencentSubAccountLoginRow: View {
    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService

    @State private var loginDraft: String = ""
    @State private var passwordDraft: String = ""
    @State private var hasStored: Bool = false
    @State private var status: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("sub-user@<main-UID or alias>", text: $loginDraft)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .autocorrectionDisabled(true)
                SecureField("Password", text: $passwordDraft)
                    .textFieldStyle(.roundedBorder)
                Button(isSaving ? "Saving…" : "Save", action: save)
                    .disabled(loginDraft.isEmpty || passwordDraft.isEmpty || isSaving)
                if hasStored {
                    Button(role: .destructive, action: clear) {
                        Image(systemName: "trash")
                    }
                    .help("Remove stored Tencent sub-account credentials")
                }
            }
            HStack(spacing: 4) {
                Image(systemName: hasStored ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(hasStored ? Color.green : Color.secondary)
                    .font(.caption)
                Text(hasStored
                     ? "Sub-account credentials saved in Keychain."
                     : "Create a CAM sub-user with read-only Hunyuan access. Plain text over HTTPS — Tencent does not RSA-encrypt the password.")
                    .font(.caption)
                    .foregroundStyle(hasStored ? .secondary : .tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .onAppear { reloadStoredFlag() }
    }

    private func save() {
        let trimmedLogin = loginDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPass = passwordDraft  // intentionally NOT trimmed — passwords may have padding
        guard !trimmedLogin.isEmpty, !trimmedPass.isEmpty else { return }

        // Accept either `<subUser>@<mainUID>`, `<subUser>@<alias>`, or just
        // a sub-user. The owner part is required — we surface the error
        // up-front rather than letting the login flow fail with a vague
        // backend message.
        guard let parsed = parseLogin(trimmedLogin) else {
            status = "Format expected: sub-user@<main-account-UID or alias>."
            return
        }

        isSaving = true
        defer { isSaving = false }
        let okMain = MiscCredentialStore.writeString(parsed.mainAccountId, tool: .tencentHunyuan, kind: .mainAccountId)
        let okUser = MiscCredentialStore.writeString(parsed.subUsername, tool: .tencentHunyuan, kind: .subUsername)
        let okPass = MiscCredentialStore.writeString(trimmedPass, tool: .tencentHunyuan, kind: .subPassword)
        guard okMain, okUser, okPass else {
            status = "Could not save credentials to Keychain."
            return
        }
        status = nil
        loginDraft = ""
        passwordDraft = ""
        hasStored = true

        // Wipe any in-memory cookies from a prior account so the next
        // refresh re-runs the login with the new credentials.
        Task {
            await TencentSessionManager.shared.wipeSession()
            triggerRefresh()
        }
    }

    private func clear() {
        MiscCredentialStore.delete(tool: .tencentHunyuan, kind: .mainAccountId)
        MiscCredentialStore.delete(tool: .tencentHunyuan, kind: .subUsername)
        MiscCredentialStore.delete(tool: .tencentHunyuan, kind: .subPassword)
        Task { await TencentSessionManager.shared.wipeSession() }
        hasStored = false
        status = "Credentials cleared."
    }

    private func reloadStoredFlag() {
        hasStored = MiscCredentialStore.hasValue(tool: .tencentHunyuan, kind: .mainAccountId)
            && MiscCredentialStore.hasValue(tool: .tencentHunyuan, kind: .subUsername)
            && MiscCredentialStore.hasValue(tool: .tencentHunyuan, kind: .subPassword)
    }

    private func triggerRefresh() {
        guard let account = environment.account(for: .tencentHunyuan) else { return }
        Task { _ = await quotaService.refresh(account) }
    }

    private struct ParsedLogin {
        let subUsername: String
        let mainAccountId: String
    }

    private func parseLogin(_ raw: String) -> ParsedLogin? {
        let parts = raw.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let user = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let main = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !main.isEmpty else { return nil }
        return ParsedLogin(subUsername: user, mainAccountId: main)
    }
}

/// Sub-account password login form for Volcengine / Doubao.
///
/// Volcengine's IAM uses a numeric main account UID and a sub-user
/// name; the user types both plus the password. Vibe Bar runs the
/// `encCerts` → RSA-encrypt → `mixtureLogin` flow on demand and
/// caches the resulting session cookies in
/// `VolcengineSessionManager`. Keychain stores the three Kind values
/// (`mainAccountId`, `subUsername`, `subPassword`); settings.json
/// never sees the password.
struct VolcengineSubAccountLoginRow: View {
    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService

    @State private var mainIdDraft: String = ""
    @State private var usernameDraft: String = ""
    @State private var passwordDraft: String = ""
    @State private var hasStored: Bool = false
    @State private var status: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Main account UID", text: $mainIdDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 130)
                    .disableAutocorrection(true)
                TextField("Sub-user name", text: $usernameDraft)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                SecureField("Password", text: $passwordDraft)
                    .textFieldStyle(.roundedBorder)
                Button(isSaving ? "Saving…" : "Save", action: save)
                    .disabled(mainIdDraft.isEmpty || usernameDraft.isEmpty || passwordDraft.isEmpty || isSaving)
                if hasStored {
                    Button(role: .destructive, action: clear) {
                        Image(systemName: "trash")
                    }
                    .help("Remove stored Volcengine sub-account credentials")
                }
            }
            HStack(spacing: 4) {
                Image(systemName: hasStored ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(hasStored ? Color.green : Color.secondary)
                    .font(.caption)
                Text(hasStored
                     ? "Sub-account credentials saved in Keychain."
                     : "Create a CAM sub-user with read-only Doubao access. Password is RSA-encrypted before transit; only the encrypted blob hits Volcengine's API.")
                    .font(.caption)
                    .foregroundStyle(hasStored ? .secondary : .tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .onAppear { reloadStoredFlag() }
    }

    private func save() {
        let trimmedMainId = mainIdDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = usernameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPass = passwordDraft  // intentionally not trimmed
        guard !trimmedMainId.isEmpty, !trimmedUser.isEmpty, !trimmedPass.isEmpty else { return }
        guard trimmedMainId.allSatisfy(\.isNumber) else {
            status = "Main account UID must be all digits."
            return
        }

        isSaving = true
        defer { isSaving = false }
        let okMain = MiscCredentialStore.writeString(trimmedMainId, tool: .volcengine, kind: .mainAccountId)
        let okUser = MiscCredentialStore.writeString(trimmedUser, tool: .volcengine, kind: .subUsername)
        let okPass = MiscCredentialStore.writeString(trimmedPass, tool: .volcengine, kind: .subPassword)
        guard okMain, okUser, okPass else {
            status = "Could not save credentials to Keychain."
            return
        }
        status = nil
        passwordDraft = ""
        hasStored = true
        Task {
            await VolcengineSessionManager.shared.wipeSession()
            triggerRefresh()
        }
    }

    private func clear() {
        MiscCredentialStore.delete(tool: .volcengine, kind: .mainAccountId)
        MiscCredentialStore.delete(tool: .volcengine, kind: .subUsername)
        MiscCredentialStore.delete(tool: .volcengine, kind: .subPassword)
        Task { await VolcengineSessionManager.shared.wipeSession() }
        hasStored = false
        status = "Credentials cleared."
    }

    private func reloadStoredFlag() {
        hasStored = MiscCredentialStore.hasValue(tool: .volcengine, kind: .mainAccountId)
            && MiscCredentialStore.hasValue(tool: .volcengine, kind: .subUsername)
            && MiscCredentialStore.hasValue(tool: .volcengine, kind: .subPassword)
    }

    private func triggerRefresh() {
        guard let account = environment.account(for: .volcengine) else { return }
        Task { _ = await quotaService.refresh(account) }
    }
}

/// "Sign in via Web" affordance for cookie-based misc providers whose
/// auto-import path is unreliable on the user's browser. Currently
/// renders for any tool that `MiscWebLoginRegistry` knows how to drive.
struct MiscWebLoginRow: View {
    let tool: ToolType
    let helpText: String

    @EnvironmentObject var environment: AppEnvironment

    var body: some View {
        guard MiscWebLoginRegistry.isSupported(for: tool) else {
            return AnyView(EmptyView())
        }
        return AnyView(
            HStack(spacing: 6) {
                Image(systemName: "safari")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text(helpText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Sign in via Web") {
                    environment.openMiscWebLogin(for: tool)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        )
    }
}
