import AppKit
import SwiftUI
import VibeBarCore

/// Per-misc-provider Settings row.
///
/// Each provider shows its name and the auth controls that match the
/// provider's current integration path (API key, device login, local
/// CLI/OAuth status, browser-cookie import, or local process probe).
struct MiscProviderSettingsSection: View {
    let instance: MiscProviderInstance

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore

    private var tool: ToolType { instance.tool }
    private var instanceID: String { instance.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                    .help("Drag to reorder")
                Toggle(isOn: visibilityBinding) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Show \(tool.menuTitle) on the Misc page")
                ToolBrandBadge(tool: tool, iconSize: 17, containerSize: 24)
                Text(tool.menuTitle)
                    .font(.system(size: 13, weight: .semibold))
                if copyCount > 1 {
                    CopyNameField(
                        instanceID: instanceID,
                        fallback: "Copy \(copyIndex)"
                    )
                }
                Text(tool.subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                BorderlessIconButton(
                    systemImage: "doc.on.doc",
                    help: "Clone \(tool.menuTitle)",
                    size: 10
                ) {
                    _ = settingsStore.settings.cloneMiscProviderInstance(id: instanceID)
                }
                if !instance.isDefault {
                    BorderlessIconButton(
                        systemImage: "trash",
                        help: "Remove this \(tool.menuTitle) copy",
                        size: 10
                    ) {
                        removeClone()
                    }
                }
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

    private var visibilityBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.miscProviderInstance(id: instanceID)?.isVisible ?? false },
            set: { value in
                settingsStore.settings.setMiscProviderInstanceVisible(value, forID: instanceID)
            }
        )
    }

    private var copyCount: Int {
        settingsStore.settings.miscProviderInstances.filter { $0.tool == tool }.count
    }

    private var copyIndex: Int {
        let sameTool = settingsStore.settings.miscProviderInstances.filter { $0.tool == tool }
        return (sameTool.firstIndex { $0.id == instanceID } ?? 0) + 1
    }

    private func removeClone() {
        guard let removed = settingsStore.settings.removeMiscProviderInstance(id: instanceID) else { return }
        MiscCookieSlotStore.deleteAll(for: removed.tool, instanceID: removed.id)
        MiscCredentialStore.clearAll(for: removed.tool, instanceID: removed.id)
        if let account = environment.accountStore.account(forMiscProviderInstanceID: removed.id) {
            environment.quotaService.clear(accountId: account.id)
        }
    }

    @ViewBuilder
    private var placeholderRow: some View {
        switch tool {
        case .zai:
            VStack(alignment: .leading, spacing: 4) {
                ApiKeyField(tool: .zai, instanceID: instanceID, prompt: "Paste Z.ai API key (zai-...)", helpText: "Find it under z.ai → API Keys. Stored in macOS Keychain.")
                ZaiRegionPicker(instanceID: instanceID)
            }
        case .copilot:
            VStack(alignment: .leading, spacing: 4) {
                CopilotDeviceLoginRow(instanceID: instanceID)
                EnterpriseHostField(tool: .copilot, instanceID: instanceID, prompt: "GitHub Enterprise host (optional, e.g. github.example.com)")
            }
        case .gemini:
            GeminiCredentialStatusRow(instanceID: instanceID)
        case .alibaba:
            VStack(alignment: .leading, spacing: 4) {
                ApiKeyField(
                    tool: .alibaba,
                    instanceID: instanceID,
                    prompt: "Paste DashScope API key (sk-...) — optional",
                    helpText: "If you have a DashScope key, paste it here. Otherwise sign in via Web below to use console cookies. Stored in macOS Keychain."
                )
                AlibabaRegionPicker(instanceID: instanceID)
                CookieSourceControls(
                    tool: .alibaba,
                    instanceID: instanceID,
                    spec: AlibabaQuotaAdapter.cookieSpec,
                    manualPrompt: "Paste console.aliyun.com Cookie header (login_aliyunid_csrf=…; cna=…; …)"
                )
                MiscWebLoginRow(
                    tool: .alibaba,
                    instanceID: instanceID,
                    helpText: "No DashScope key? Sign in to bailian.console.aliyun.com or modelstudio.console.alibabacloud.com once via Web; Vibe Bar refreshes the console session in the background after that."
                )
            }
        case .alibabaTokenPlan:
            VStack(alignment: .leading, spacing: 4) {
                AlibabaRegionPicker(instanceID: instanceID)
                CookieSourceControls(
                    tool: .alibabaTokenPlan,
                    instanceID: instanceID,
                    spec: AlibabaTokenPlanQuotaAdapter.cookieSpec,
                    manualPrompt: "Paste console.aliyun.com Cookie header (login_aliyunid_csrf=…; cna=…; …)"
                )
                MiscWebLoginRow(
                    tool: .alibabaTokenPlan,
                    instanceID: instanceID,
                    helpText: "Sign in to bailian.console.aliyun.com once on the Aliyun account that owns the Token Plan. Same login as the Coding Plan card — you can sign in on either."
                )
            }
        case .minimax:
            VStack(alignment: .leading, spacing: 4) {
                ApiKeyField(
                    tool: .minimax,
                    instanceID: instanceID,
                    prompt: "Paste MiniMax Token Plan API key (sk-cp-... or MINIMAX_CODING_API_KEY)",
                    helpText: "Find it under Billing → Token Plan. Stored in macOS Keychain. Env fallback: MINIMAX_CODING_API_KEY, then MINIMAX_API_KEY."
                )
                MiniMaxRegionPicker(instanceID: instanceID)
            }
        case .kimi:
            CookieSourceControls(
                tool: .kimi,
                instanceID: instanceID,
                spec: KimiQuotaAdapter.cookieSpec,
                manualPrompt: "Paste www.kimi.com Cookie header (kimi-auth=eyJ...)"
            )
        case .cursor:
            CookieSourceControls(
                tool: .cursor,
                instanceID: instanceID,
                spec: CursorQuotaAdapter.cookieSpec,
                manualPrompt: "Paste cursor.com Cookie header (WorkosCursorSessionToken=...)"
            )
        case .mimo:
            VStack(alignment: .leading, spacing: 4) {
                CookieSourceControls(
                    tool: .mimo,
                    instanceID: instanceID,
                    spec: MimoQuotaAdapter.cookieSpec,
                    manualPrompt: "Paste platform.xiaomimimo.com Cookie header (userId=...; api-platform_slh=...; api-platform_ph=...; api-platform_serviceToken=...)"
                )
                MiscWebLoginRow(
                    tool: .mimo,
                    instanceID: instanceID,
                    helpText: "Chrome's newer cookie encryption blocks the browser-import path on macOS. Sign in via the in-app webview to capture cookies cleanly."
                )
            }
        case .iflytek:
            CookieSourceControls(
                tool: .iflytek,
                instanceID: instanceID,
                spec: IFlyTekQuotaAdapter.cookieSpec,
                manualPrompt: "Paste maas.xfyun.cn Cookie header (atp-auth-token=…; account_id=…; ssoSessionId=…; tenantToken=…)"
            )
        case .tencentHunyuan:
            VStack(alignment: .leading, spacing: 4) {
                CookieSourceControls(
                    tool: .tencentHunyuan,
                    instanceID: instanceID,
                    spec: TencentHunyuanQuotaAdapter.cookieSpec,
                    manualPrompt: "Paste cloud.tencent.com Cookie header (skey=…; uin=…; …)"
                )
                MiscWebLoginRow(
                    tool: .tencentHunyuan,
                    instanceID: instanceID,
                    helpText: "Tencent's `skey` cookie expires within hours. When the card flips to \"Needs re-login\", click here to refresh the session."
                )
            }
        case .tencentTokenPlan:
            VStack(alignment: .leading, spacing: 4) {
                TencentTokenPlanVariantPicker(instanceID: instanceID)
                CookieSourceControls(
                    tool: .tencentTokenPlan,
                    instanceID: instanceID,
                    spec: TencentTokenPlanQuotaAdapter.cookieSpec,
                    manualPrompt: "Paste cloud.tencent.com Cookie header (skey=…; uin=…; …)"
                )
                MiscWebLoginRow(
                    tool: .tencentTokenPlan,
                    instanceID: instanceID,
                    helpText: "Same Tencent Cloud login as the Coding Plan card. Pick the variant above (generic or HY3) — clone this row to track both at once."
                )
            }
        case .volcengine:
            VStack(alignment: .leading, spacing: 4) {
                CookieSourceControls(
                    tool: .volcengine,
                    instanceID: instanceID,
                    spec: VolcengineQuotaAdapter.cookieSpec,
                    manualPrompt: "Paste console.volcengine.com Cookie header (csrfToken=…; AccountID=…; …)"
                )
                MiscWebLoginRow(
                    tool: .volcengine,
                    instanceID: instanceID,
                    helpText: "Volcengine console session cookies expire after a few hours. When the card flips to \"Needs re-login\", click here to refresh."
                )
            }
        case .baiduQianfan:
            VStack(alignment: .leading, spacing: 4) {
                CookieSourceControls(
                    tool: .baiduQianfan,
                    instanceID: instanceID,
                    spec: BaiduQianfanQuotaAdapter.cookieSpec,
                    manualPrompt: "Paste console.bce.baidu.com Cookie header (BDUSS=…; STOKEN=…; __bid_n=…; …)"
                )
                MiscWebLoginRow(
                    tool: .baiduQianfan,
                    instanceID: instanceID,
                    helpText: "Sign in to console.bce.baidu.com once with the Baidu Cloud account that owns the Qianfan Coding Plan. Vibe Bar then refreshes the BCE console session in the background."
                )
            }
        case .openCodeGo:
            VStack(alignment: .leading, spacing: 4) {
                CookieSourceControls(
                    tool: .openCodeGo,
                    instanceID: instanceID,
                    spec: OpenCodeGoQuotaAdapter.cookieSpec,
                    manualPrompt: "Paste opencode.ai Cookie header (__Host-auth=... or auth=...)"
                )
                WorkspaceIDField(
                    tool: .openCodeGo,
                    instanceID: instanceID,
                    prompt: "Workspace ID or URL (optional, wrk_... or /workspace/wrk_.../go)"
                )
            }
        case .kilo:
            ApiKeyField(
                tool: .kilo,
                instanceID: instanceID,
                prompt: "Paste Kilo API key (optional)",
                helpText: "Optional. Vibe Bar also reads ~/.local/share/kilo/auth.json after `kilo login`. Env fallback: KILO_API_KEY."
            )
        case .kiro:
            KiroStatusRow(instanceID: instanceID)
        case .ollama:
            CookieSourceControls(
                tool: .ollama,
                instanceID: instanceID,
                spec: OllamaQuotaAdapter.cookieSpec,
                manualPrompt: "Paste ollama.com Cookie header (session=... or next-auth.session-token=...)"
            )
        case .openRouter:
            VStack(alignment: .leading, spacing: 4) {
                ApiKeyField(
                    tool: .openRouter,
                    instanceID: instanceID,
                    prompt: "Paste OpenRouter API key (sk-or-v1-...)",
                    helpText: "Stored in macOS Keychain. Env fallback: OPENROUTER_API_KEY."
                )
                EnterpriseHostField(tool: .openRouter, instanceID: instanceID, prompt: "OpenRouter API URL (optional, defaults to https://openrouter.ai/api/v1)")
            }
        case .antigravity:
            AntigravityStatusRow(instanceID: instanceID)
        case .warp:
            ApiKeyField(
                tool: .warp,
                instanceID: instanceID,
                prompt: "Paste Warp API key (wk-...)",
                helpText: "Open Warp → Settings → AI → API Keys to mint one. Stored in macOS Keychain. Env fallback: WARP_API_KEY, then WARP_TOKEN."
            )
        case .grok:
            // Partial-primary providers don't ship a misc-card UI;
            // their settings live in the dedicated SettingsView panel.
            EmptyView()
        case .codex, .claude:
            EmptyView()
        }
    }

}

private struct CopyNameField: View {
    let instanceID: String
    let fallback: String

    @EnvironmentObject var settingsStore: SettingsStore
    @FocusState private var isFocused: Bool
    @State private var draft: String = ""

    var body: some View {
        TextField(fallback, text: $draft)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(.caption2)
            .frame(width: 120)
            .focused($isFocused)
            .help("Rename this copy")
            .onAppear(perform: syncDraft)
            .onSubmit(save)
            .onChange(of: isFocused) { _, focused in
                if !focused { save() }
            }
            .onChange(of: currentDisplayName) { _, _ in
                if !isFocused { syncDraft() }
            }
    }

    private var currentDisplayName: String {
        settingsStore.settings.miscProviderInstance(id: instanceID)?.displayName ?? ""
    }

    private func syncDraft() {
        draft = currentDisplayName
    }

    private func save() {
        settingsStore.settings.setMiscProviderInstanceDisplayName(draft, forID: instanceID)
        syncDraft()
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
    let instanceID: String
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
        .onAppear { hasStored = MiscCredentialStore.hasValue(tool: tool, kind: .apiKey, instanceID: instanceID) }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let ok = MiscCredentialStore.writeString(trimmed, tool: tool, kind: .apiKey, instanceID: instanceID)
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
        MiscCredentialStore.delete(tool: tool, kind: .apiKey, instanceID: instanceID)
        hasStored = false
        triggerRefresh()
    }

    private func triggerRefresh() {
        guard let account = environment.accountStore.account(forMiscProviderInstanceID: instanceID) else { return }
        Task { _ = await quotaService.refresh(account) }
    }
}

/// GitHub Copilot sign-in via OAuth device flow. This replaces the
/// old PAT-first setup while keeping legacy PATs readable in Core as
/// a migration fallback.
struct CopilotDeviceLoginRow: View {
    let instanceID: String

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

            let host = settingsStore.settings.miscProviderSettings(forInstanceID: instanceID).enterpriseHost?.absoluteString
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
                    kind: .oauthAccessToken,
                    instanceID: instanceID
                ) else {
                    status = "GitHub login succeeded, but Vibe Bar could not save the token."
                    return
                }
                guard MiscCredentialStore.hasValue(tool: .copilot, kind: .oauthAccessToken, instanceID: instanceID) else {
                    status = "GitHub login succeeded, but saved token could not be read back."
                    return
                }

                // Hide the old PAT path once device auth succeeds.
                MiscCredentialStore.delete(tool: .copilot, kind: .apiKey, instanceID: instanceID)
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
        MiscCredentialStore.delete(tool: .copilot, kind: .oauthAccessToken, instanceID: instanceID)
        MiscCredentialStore.delete(tool: .copilot, kind: .apiKey, instanceID: instanceID)
        hasStoredToken = false
        status = "GitHub token cleared."
        triggerRefresh()
    }

    private func reloadStoredToken() {
        hasStoredToken =
            MiscCredentialStore.hasValue(tool: .copilot, kind: .oauthAccessToken, instanceID: instanceID) ||
            MiscCredentialStore.hasValue(tool: .copilot, kind: .apiKey, instanceID: instanceID)
    }

    private func triggerRefresh() {
        guard let account = environment.accountStore.account(forMiscProviderInstanceID: instanceID) else { return }
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
    let instanceID: String

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
        guard let account = environment.accountStore.account(forMiscProviderInstanceID: instanceID) else { return }
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
    let instanceID: String

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
        guard let account = environment.accountStore.account(forMiscProviderInstanceID: instanceID) else { return }
        Task { _ = await quotaService.refresh(account) }
    }
}

/// Kiro is local-CLI only. The row mirrors AntiGravity's probe style
/// but points users at the login command that creates the usable
/// session.
struct KiroStatusRow: View {
    let instanceID: String

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text("Run `kiro-cli login`, then Vibe Bar probes `kiro-cli chat --no-interactive /usage`.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            Button("Probe", action: probe)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func probe() {
        guard let account = environment.accountStore.account(forMiscProviderInstanceID: instanceID) else { return }
        Task { _ = await quotaService.refresh(account) }
    }
}

/// Browser-cookie controls for the misc providers.
///
/// Each provider can stack multiple cookie sessions — one per account.
/// The section shows the current list of imported slots (with source
/// label, import time, and a delete button) plus two additive entry
/// points: "Import from browser" and a manual paste field. Quota
/// queries fan out across every slot and the bucket percentages are
/// averaged; see `MiscQuotaAggregator`.
struct CookieSourceControls: View {
    let tool: ToolType
    let instanceID: String
    let spec: MiscCookieResolver.Spec
    let manualPrompt: String

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService

    @State private var slots: [MiscCookieSlot] = []
    @State private var manualDraft: String = ""
    @State private var importStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if slots.isEmpty {
                Text("No cookies imported yet — import from your browser or paste below.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(slots) { slot in
                        CookieSlotRow(slot: slot) { deleteSlot(slot) }
                    }
                }
            }
            HStack(spacing: 6) {
                Button("Import from browser", action: importNow)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Text("Adds a new slot. Existing cookies stay; quotas are averaged across all slots.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                SecureField(manualPrompt, text: $manualDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Add", action: saveManual)
                    .disabled(manualDraft.isEmpty)
            }
            if let importStatus {
                Text(importStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: reloadSlots)
        .onReceive(NotificationCenter.default.publisher(
            for: MiscCookieSlotStore.didChangeNotification
        )) { note in
            guard let raw = note.userInfo?["tool"] as? String,
                  raw == tool.rawValue,
                  let changedInstanceID = note.userInfo?["instanceID"] as? String,
                  changedInstanceID == instanceID else { return }
            reloadSlots()
        }
    }

    private func reloadSlots() {
        slots = MiscCookieSlotStore.slots(for: tool, instanceID: instanceID)
    }

    private func importNow() {
        importStatus = "Importing…"
        let snapshotSpec = spec
        let snapshotInstanceID = instanceID
        DispatchQueue.global(qos: .userInitiated).async {
            let result = MiscCookieResolver.appendBrowserImport(for: snapshotSpec, instanceID: snapshotInstanceID)
            DispatchQueue.main.async {
                if let result {
                    importStatus = "Imported from \(result.sourceLabel)."
                    reloadSlots()
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
        let slot = MiscCookieSlot(
            cookieHeader: normalised,
            sourceLabel: "Manual paste",
            importedAt: Date(),
            origin: .manual
        )
        guard MiscCookieSlotStore.append(slot, for: tool, instanceID: instanceID) else {
            importStatus = "Could not save to Keychain."
            return
        }
        importStatus = "Pasted cookie saved."
        manualDraft = ""
        reloadSlots()
        triggerRefresh()
    }

    private func deleteSlot(_ slot: MiscCookieSlot) {
        guard MiscCookieSlotStore.delete(slotID: slot.id, for: tool, instanceID: instanceID) else { return }
        importStatus = "Removed \(slot.sourceLabel)."
        reloadSlots()
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
        guard let account = environment.accountStore.account(forMiscProviderInstanceID: instanceID) else { return }
        Task { _ = await quotaService.refresh(account) }
    }
}

/// One row in the cookie slot list. Shows the source label + import
/// time and a trash button.
private struct CookieSlotRow: View {
    let slot: MiscCookieSlot
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .font(.caption)
                .frame(width: 14)
            Text(slot.sourceLabel)
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            Text(Self.dateFormatter.string(from: slot.importedAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this cookie slot")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var icon: String {
        switch slot.origin {
        case .manual:         return "doc.on.clipboard"
        case .browserImport:  return "safari"
        case .autoRefresh:    return "arrow.clockwise.circle"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}

/// Region picker for Alibaba — international (ap-southeast-1) vs.
/// china-mainland (cn-beijing). "Auto" lets the adapter try both
/// in order on each refresh.
struct AlibabaRegionPicker: View {
    let instanceID: String

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
                let raw = settingsStore.settings.miscProviderSettings(forInstanceID: instanceID).region ?? ""
                return Choice(rawValue: raw) ?? .auto
            },
            set: { newValue in
                var current = settingsStore.settings.miscProviderSettings(forInstanceID: instanceID)
                current.region = newValue == .auto ? nil : newValue.rawValue
                settingsStore.settings.setMiscProviderInstanceSettings(current, forID: instanceID)
            }
        )
    }
}

/// Tencent Token Plan variant picker — choose between the generic
/// TokenHub Token Plan (`/tokenhub/tokenplan`) and the HY3-only
/// Token Plan (`/tokenhub/tokenplan/hy`). Stored as the
/// `region` field on `MiscProviderSettings`; values map back to
/// `TencentTokenPlanVariant`.
struct TencentTokenPlanVariantPicker: View {
    let instanceID: String

    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        Picker("Variant", selection: choiceBinding) {
            ForEach(TencentTokenPlanVariant.allCases, id: \.rawValue) { choice in
                Text(choice.displayLabel).tag(choice)
            }
        }
        .pickerStyle(.menu)
    }

    private var choiceBinding: Binding<TencentTokenPlanVariant> {
        Binding(
            get: {
                let raw = settingsStore.settings.miscProviderSettings(forInstanceID: instanceID).region
                return TencentTokenPlanVariant.from(settingsRegion: raw)
            },
            set: { newValue in
                var current = settingsStore.settings.miscProviderSettings(forInstanceID: instanceID)
                current.region = newValue.settingsRegionID
                settingsStore.settings.setMiscProviderInstanceSettings(current, forID: instanceID)
            }
        )
    }
}

/// Z.ai has separate international and mainland China quota hosts.
struct ZaiRegionPicker: View {
    let instanceID: String

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
                let raw = settingsStore.settings.miscProviderSettings(forInstanceID: instanceID).region ?? Choice.global.rawValue
                return Choice(rawValue: raw) ?? .global
            },
            set: { newValue in
                var current = settingsStore.settings.miscProviderSettings(forInstanceID: instanceID)
                current.region = newValue.rawValue
                settingsStore.settings.setMiscProviderInstanceSettings(current, forID: instanceID)
            }
        )
    }
}

/// MiniMax has separate minimax.io and minimaxi.com Token Plan hosts.
/// The adapter still falls back across both, but this picker controls
/// the preferred region tried first.
struct MiniMaxRegionPicker: View {
    let instanceID: String

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
                let raw = settingsStore.settings.miscProviderSettings(forInstanceID: instanceID).region ?? Choice.global.rawValue
                return Choice(rawValue: raw) ?? .global
            },
            set: { newValue in
                var current = settingsStore.settings.miscProviderSettings(forInstanceID: instanceID)
                current.region = newValue.rawValue
                settingsStore.settings.setMiscProviderInstanceSettings(current, forID: instanceID)
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
    let instanceID: String
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
        settingsStore.settings.miscProviderSettings(forInstanceID: instanceID).enterpriseHost?.absoluteString ?? ""
    }

    private func save() {
        var current = settingsStore.settings.miscProviderSettings(forInstanceID: instanceID)
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            current.enterpriseHost = nil
        } else if let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)") {
            current.enterpriseHost = url
        } else {
            return
        }
        settingsStore.settings.setMiscProviderInstanceSettings(current, forID: instanceID)
    }
}

/// Plain-text workspace/project id stored in non-sensitive misc
/// settings. OpenCode Go accepts either `wrk_...` or the full dashboard
/// URL; the adapter normalizes it at fetch time.
struct WorkspaceIDField: View {
    let tool: ToolType
    let instanceID: String
    let prompt: String

    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService
    @State private var draft: String = ""

    var body: some View {
        HStack(spacing: 6) {
            TextField(prompt, text: $draft, onCommit: save)
                .textFieldStyle(.roundedBorder)
            Button("Save", action: save)
                .disabled(draft == currentRaw)
            if !currentRaw.isEmpty {
                Button(role: .destructive, action: clear) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Clear saved workspace")
            }
        }
        .onAppear { draft = currentRaw }
    }

    private var currentRaw: String {
        settingsStore.settings.miscProviderSettings(forInstanceID: instanceID).workspaceID ?? ""
    }

    private func save() {
        var current = settingsStore.settings.miscProviderSettings(forInstanceID: instanceID)
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        current.workspaceID = trimmed.isEmpty ? nil : trimmed
        settingsStore.settings.setMiscProviderInstanceSettings(current, forID: instanceID)
        triggerRefresh()
    }

    private func clear() {
        draft = ""
        save()
    }

    private func triggerRefresh() {
        guard let account = environment.accountStore.account(forMiscProviderInstanceID: instanceID) else { return }
        Task { _ = await quotaService.refresh(account) }
    }
}

/// "Sign in via Web" affordance for cookie-based misc providers whose
/// auto-import path is unreliable on the user's browser. Currently
/// renders for any tool that `MiscWebLoginRegistry` knows how to drive.
struct MiscWebLoginRow: View {
    let tool: ToolType
    let instanceID: String
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
                    environment.openMiscWebLogin(for: tool, instanceID: instanceID)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        )
    }
}
