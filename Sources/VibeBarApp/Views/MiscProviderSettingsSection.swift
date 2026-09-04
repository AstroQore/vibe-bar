import AppKit
import SwiftUI
import VibeBarCore

/// Per-misc-provider Settings block.
///
/// Each provider shows its name and the auth controls that match the
/// provider's current integration path (API key, device login, local
/// CLI/OAuth status, browser-cookie import, or local process probe).
///
/// Content only: the caller wraps this in the page's `SettingsSectionCard`,
/// so it must not draw a surface of its own.
struct MiscProviderSettingsSection: View {
    let instance: MiscProviderInstance

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore

    @State private var isConfirmingRemoval = false

    private var tool: ToolType { instance.tool }
    private var instanceID: String { instance.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                    .help(L10n.Common.dragToReorder)
                Toggle(isOn: visibilityBinding) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(L10n.Onboarding.apiKeysShowOnMiscPage(provider: tool.menuTitle))
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
                    help: L10n.Settings.miscClone(provider: tool.menuTitle),
                    size: 10
                ) {
                    _ = settingsStore.settings.cloneMiscProviderInstance(id: instanceID)
                }
                if !instance.isDefault {
                    BorderlessIconButton(
                        systemImage: "trash",
                        help: L10n.Settings.miscRemoveCopy(provider: tool.menuTitle),
                        size: 10
                    ) {
                        isConfirmingRemoval = true
                    }
                }
            }
            MiscProviderCredentialRows(instance: instance)
        }
        // Removing a copy also deletes its Keychain entries — the API key
        // or AK/SK and every stored cookie slot — and none of that comes
        // back. A one-click trash icon next to a Clone button is too easy
        // to hit for something irreversible.
        .confirmationDialog(
            L10n.Settings.miscRemoveCopyTitle(provider: tool.menuTitle),
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button(L10n.Settings.miscRemoveCopyButton, role: .destructive, action: removeClone)
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Settings.miscRemoveCopyDetail)
        }
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

}

/// The credential and configuration controls for one misc-provider instance —
/// API-key and AK/SK fields, cookie slots, region and variant pickers, web
/// login rows. Every Keychain write happens in the field views this composes;
/// nothing here touches a secret itself. Shared by the Misc Providers settings
/// page and the setup assistant so the two can never offer different ways to
/// enter the same credential.
struct MiscProviderCredentialRows: View {
    let instance: MiscProviderInstance

    @EnvironmentObject var settingsStore: SettingsStore

    private var tool: ToolType { instance.tool }
    private var instanceID: String { instance.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            credentialControls
            MiscProviderSetupNote(tool: tool, instanceID: instanceID)
        }
    }

    @ViewBuilder
    private var credentialControls: some View {
        switch tool {
        case .zai:
            VStack(alignment: .leading, spacing: 4) {
                ApiKeyField(
                    tool: .zai,
                    instanceID: instanceID,
                    prompt: L10n.Settings.miscPromptZai,
                    helpText: "Find it under API Keys on z.ai (Global) or open.bigmodel.cn (China mainland). Stored in macOS Keychain."
                )
                ZaiRegionPicker(instanceID: instanceID)
            }
        case .copilot:
            VStack(alignment: .leading, spacing: 4) {
                CopilotDeviceLoginRow(instanceID: instanceID)
                EnterpriseHostField(tool: .copilot, instanceID: instanceID, prompt: L10n.Settings.miscPromptCopilotHost)
            }
        case .gemini:
            EmptyView()
        case .alibaba:
            VStack(alignment: .leading, spacing: 4) {
                ApiKeyField(
                    tool: .alibaba,
                    instanceID: instanceID,
                    prompt: L10n.Settings.miscPromptDashscope,
                    helpText: "If you have a DashScope key, paste it here. Otherwise sign in via Web below to use console cookies. Stored in macOS Keychain."
                )
                AlibabaRegionPicker(instanceID: instanceID)
                CookieSourceControls(
                    tool: .alibaba,
                    instanceID: instanceID,
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
                AlibabaTokenPlanVariantPicker(instanceID: instanceID)
                if AlibabaTokenPlanVariant.from(
                    settingsValue: settingsStore.settings
                        .miscProviderSettings(forInstanceID: instanceID)
                        .planVariant
                ) == .team {
                    AlibabaRegionPicker(instanceID: instanceID)
                } else {
                    Text(L10n.Settings.miscTencentTokenPlanNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                CookieSourceControls(
                    tool: .alibabaTokenPlan,
                    instanceID: instanceID,
                    manualPrompt: "Paste console.aliyun.com Cookie header (login_aliyunid_csrf=…; cna=…; …)"
                )
                MiscWebLoginRow(
                    tool: .alibabaTokenPlan,
                    instanceID: instanceID,
                    helpText: "Sign in to bailian.console.aliyun.com once on the Aliyun account that owns this Token Plan. Existing cards default to Team; choose Personal above for the new rolling-window plan."
                )
            }
        case .minimax:
            VStack(alignment: .leading, spacing: 4) {
                ApiKeyField(
                    tool: .minimax,
                    instanceID: instanceID,
                    prompt: L10n.Settings.miscPromptMinimax,
                    helpText: "Find it under Billing → Token Plan. Stored in macOS Keychain. Env fallback: MINIMAX_CODING_API_KEY, then MINIMAX_API_KEY."
                )
                MiniMaxRegionPicker(instanceID: instanceID)
            }
        case .kimi:
            CookieSourceControls(
                tool: .kimi,
                instanceID: instanceID,
                manualPrompt: "Paste www.kimi.com Cookie header (kimi-auth=eyJ...)"
            )
        case .mimo:
            VStack(alignment: .leading, spacing: 4) {
                CookieSourceControls(
                    tool: .mimo,
                    instanceID: instanceID,
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
                manualPrompt: "Paste maas.xfyun.cn Cookie header (atp-auth-token=…; account_id=…; ssoSessionId=…; tenantToken=…)"
            )
        case .tencentHunyuan:
            VStack(alignment: .leading, spacing: 4) {
                CookieSourceControls(
                    tool: .tencentHunyuan,
                    instanceID: instanceID,
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
                    manualPrompt: "Paste console.volcengine.com Cookie header (csrfToken=…; AccountID=…; …)"
                )
                MiscWebLoginRow(
                    tool: .volcengine,
                    instanceID: instanceID,
                    helpText: "Coding Plan reads a Volcengine console session — there is no API key for it. Sign in here, or paste the header above; either way it must carry csrfToken, which the Ark console sets on its first request. Console cookies expire after a few hours."
                )
            }
        case .volcengineAgentPlan:
            VStack(alignment: .leading, spacing: 4) {
                AkSkField(
                    tool: .volcengineAgentPlan,
                    instanceID: instanceID,
                    helpText: "Agent Plan reads usage through Volcengine's signed OpenAPI, so it needs an Access Key pair from Console → Access Control (访问控制) → API Access Key — not the sk-… Ark inference key, and not a console login. A sub-user key with Ark read access is enough."
                )
            }
        case .baiduQianfan:
            VStack(alignment: .leading, spacing: 4) {
                CookieSourceControls(
                    tool: .baiduQianfan,
                    instanceID: instanceID,
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
                    manualPrompt: "Paste opencode.ai Cookie header (__Host-auth=... or auth=...)"
                )
                WorkspaceIDField(
                    tool: .openCodeGo,
                    instanceID: instanceID,
                    prompt: L10n.Settings.miscPromptWorkspace
                )
                Text(L10n.Settings.miscWorkspaceNote)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        case .kilo:
            ApiKeyField(
                tool: .kilo,
                instanceID: instanceID,
                prompt: L10n.Settings.miscPromptKilo,
                helpText: "From app.kilo.ai → API Keys, and optional: Vibe Bar also reads the auth file `kilo login` writes under ~/.local/share/kilo/. Env fallback: KILO_API_KEY."
            )
        case .kiro:
            KiroStatusRow(instanceID: instanceID)
        case .ollama:
            CookieSourceControls(
                tool: .ollama,
                instanceID: instanceID,
                manualPrompt: "Paste ollama.com Cookie header (session=... or next-auth.session-token=...)"
            )
        case .openRouter:
            VStack(alignment: .leading, spacing: 4) {
                ApiKeyField(
                    tool: .openRouter,
                    instanceID: instanceID,
                    prompt: L10n.Settings.miscPromptOpenRouter,
                    helpText: "From openrouter.ai → Keys; credit-read access is enough. Stored in macOS Keychain. Env fallback: OPENROUTER_API_KEY."
                )
                EnterpriseHostField(tool: .openRouter, instanceID: instanceID, prompt: L10n.Settings.miscPromptOpenRouterHost)
            }
        case .warp:
            ApiKeyField(
                tool: .warp,
                instanceID: instanceID,
                prompt: L10n.Settings.miscPromptWarp,
                helpText: "Open Warp → Settings → AI → API Keys to mint one. Stored in macOS Keychain. Env fallback: WARP_API_KEY, then WARP_TOKEN."
            )
        case .codex, .claude, .gemini, .antigravity, .grok, .cursor:
            // Partial-primary and primary providers don't ship a misc-card
            // UI: `AppSettings` only builds instances for
            // `isMiscPageProvider` tools, and their credentials live in the
            // dedicated SettingsView panel. These cases exist purely to
            // keep the switch exhaustive.
            EmptyView()
        }
    }
}

/// One line per provider saying where its credential comes from, what
/// Vibe Bar actually reads, and whether an API key exists for usage at
/// all — plus a click-through to the page that issues it.
///
/// This lives beside the credential controls rather than inside them
/// because several providers have two entry points (a key *and* a cookie
/// jar) and the "which one do I need?" answer belongs to the provider, not
/// to one field.
struct MiscProviderSetupNote: View {
    let tool: ToolType
    /// Read live from the store rather than from a snapshot, so switching
    /// the Region picker re-points the console link in the same frame.
    let instanceID: String

    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        if let note = tool.miscSetupNote {
            VStack(alignment: .leading, spacing: 2) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Two links when a region-aware provider is on "Auto":
                // either console could be the one holding the credential.
                ForEach(consoleLinks) { link in
                    Link(destination: link.url) {
                        Text(L10n.Settings.miscConsoleLink(title: link.title))
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help(link.url.absoluteString)
                }
            }
            .padding(.top, 2)
        }
    }

    private var consoleLinks: [MiscProviderConsole.Link] {
        MiscProviderConsole.links(
            for: tool,
            settings: settingsStore.settings.miscProviderSettings(forInstanceID: instanceID)
        )
    }
}

extension ToolType {
    /// nil for the providers that have no misc-card credential row.
    var miscSetupNote: String? {
        switch self {
        case .alibaba:
            return "The console session is read from bailian.console.aliyun.com (or modelstudio.console.alibabacloud.com internationally); Region has to match the account that owns the plan. A DashScope key is optional and is tried first when present."
        case .alibabaTokenPlan:
            return "Same Aliyun login as the Coding Plan card, a different subscription. Token Plan usage is only exposed to the console session — there is no DashScope key for it."
        case .copilot:
            return "Sign-in runs GitHub's device flow and Vibe Bar keeps only the OAuth token it returns; no cookies are read. Set the Enterprise host if the seat lives on GitHub Enterprise Server."
        case .zai:
            return "Mint the key under API Keys on z.ai (Global) or on open.bigmodel.cn (China mainland), then set Region to match — a key issued on one host returns nothing on the other. \"Auto\" tries both."
        case .minimax:
            return "The Token Plan key is under Billing → Token Plan (platform.minimax.io, or minimaxi.com in China mainland). A general MiniMax platform key authenticates but reports no Token Plan quota."
        case .kimi:
            return "Sign in at www.kimi.com in your browser, then import: Vibe Bar keeps the kimi-auth and kimi-refresh values (Chrome stores them in localStorage, which the importer also reads). Kimi publishes no API key for Coding Plan usage."
        case .mimo:
            return "Sign in at platform.xiaomimimo.com; Vibe Bar keeps userId, api-platform_slh, api-platform_ph and api-platform_serviceToken. There is no API key for Token Plan usage."
        case .iflytek:
            return "Sign in at maas.xfyun.cn with the account that owns the Coding Plan. The usage API checks HttpOnly tickets, so the whole maas.xfyun.cn / passport.xfyun.cn jar is kept rather than a few named cookies. No API key exposes this usage."
        case .tencentHunyuan:
            return "Sign in at console.cloud.tencent.com. The usage call needs the console's skey and uin cookies, and skey expires within hours — expect to refresh the session more often than other providers. No API key exposes Coding Plan usage."
        case .tencentTokenPlan:
            return "Same Tencent Cloud login as the Coding Plan card, a different subscription. It needs the same skey and uin console cookies, and there is no API key for Token Plan usage."
        case .volcengine:
            return "Coding Plan is read from a Volcengine console session (Sign in via Web, or paste the console.volcengine.com Cookie header) and the header must include csrfToken, which only appears once the Ark console has been opened in that browser. There is no API key for it. The Agent Plan is a separate subscription with a separate credential — set it up on the Volcengine Agent Plan card."
        case .volcengineAgentPlan:
            return "Agent Plan is read through Volcengine's signed OpenAPI, so it needs an Access Key pair (Console → Access Control (访问控制) → API Access Key) — not the sk-… Ark inference key, and not a console login. The Coding Plan is a separate subscription read from console cookies — set it up on the Volcengine Coding Plan card."
        case .baiduQianfan:
            return "Sign in at console.bce.baidu.com with the Baidu Cloud account that owns the Coding Plan; Vibe Bar keeps the BCE console jar. There is no API key for this usage endpoint."
        case .openCodeGo:
            return "Sign in at opencode.ai in your browser, then import: Vibe Bar keeps the __Host-auth (or auth) cookie. There is no API key for Go usage."
        case .kilo:
            return "The key comes from app.kilo.ai → API Keys and is optional — `kilo login` writes an auth file Vibe Bar reads instead."
        case .kiro:
            return "Kiro has neither a key to paste nor a cookie to import: Vibe Bar shells out to the locally installed kiro-cli. Install it from kiro.dev, run `kiro-cli login` in Terminal, then Probe."
        case .ollama:
            return "Ollama Cloud usage is only exposed to a signed-in web session — there is no API key for it. Sign in at ollama.com, then import; Vibe Bar keeps the session (or next-auth.session-token) cookie."
        case .openRouter:
            return "The key comes from openrouter.ai → Keys and only needs to read credits. Set the API URL when you route OpenRouter through a proxy."
        case .warp:
            return "The key is minted inside Warp itself: Warp → Settings → AI → API Keys."
        case .codex, .claude, .gemini, .antigravity, .grok, .cursor:
            return nil
        }
    }
}

/// Alibaba Token Plan commercial edition. This uses a dedicated
/// settings field because Team also has its own independent region
/// selector. Missing values map to Team for backward compatibility.
struct AlibabaTokenPlanVariantPicker: View {
    let instanceID: String

    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        Picker(L10n.Settings.miscEdition, selection: choiceBinding) {
            ForEach(AlibabaTokenPlanVariant.allCases, id: \.rawValue) { choice in
                Text(choice.displayLabel).tag(choice)
            }
        }
        .pickerStyle(.menu)
    }

    private var choiceBinding: Binding<AlibabaTokenPlanVariant> {
        Binding(
            get: {
                let raw = settingsStore.settings
                    .miscProviderSettings(forInstanceID: instanceID)
                    .planVariant
                return AlibabaTokenPlanVariant.from(settingsValue: raw)
            },
            set: { newValue in
                var current = settingsStore.settings.miscProviderSettings(forInstanceID: instanceID)
                current.planVariant = newValue.rawValue
                settingsStore.settings.setMiscProviderInstanceSettings(current, forID: instanceID)
            }
        )
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
            .help(L10n.Settings.miscRename)
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
    @State private var saveWarning: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SecureField(prompt, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button(L10n.Common.save, action: save)
                    .disabled(draft.isEmpty)
                if hasStored {
                    Button(role: .destructive, action: clear) {
                        Image(systemName: "trash")
                    }
                    .help(L10n.Settings.miscRemoveApiKey(provider: tool.menuTitle))
                }
            }
            HStack(spacing: 4) {
                Image(systemName: hasStored ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(hasStored ? Color.green : Color.secondary)
                    .font(.caption)
                Text(hasStored ? L10n.Settings.miscApiKeySaved : helpText)
                    .font(.caption)
                    .foregroundStyle(hasStored ? .secondary : .tertiary)
            }
            if let saveError {
                Text(saveError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let saveWarning {
                Text(saveWarning)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { hasStored = MiscCredentialStore.hasValue(tool: tool, kind: .apiKey, instanceID: instanceID) }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Shape-check before writing: a key that is silently the wrong kind
        // used to be stored, shown as saved, and only fail later on a
        // different screen.
        let verdict = MiscCredentialFieldRules.check(tool: tool, kind: .apiKey, value: trimmed)
        guard verdict.allowsSave else {
            saveWarning = nil
            saveError = verdict.message
            return
        }
        let ok = MiscCredentialStore.writeString(trimmed, tool: tool, kind: .apiKey, instanceID: instanceID)
        if ok {
            saveError = nil
            saveWarning = verdict.message
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
        saveError = nil
        saveWarning = nil
        triggerRefresh()
    }

    private func triggerRefresh() {
        guard let account = environment.accountStore.account(forMiscProviderInstanceID: instanceID) else { return }
        Task { _ = await quotaService.refresh(account) }
    }
}

/// Two-field AK/SK entry for Volcengine's signed OpenAPI — an optional
/// alternative to the console cookie jar. The Access Key ID and Secret
/// Access Key both persist in Keychain (`MiscCredentialStore`), never in
/// `~/.vibebar/settings.json`. Saving triggers a one-shot refresh.
struct AkSkField: View {
    let tool: ToolType
    let instanceID: String
    let helpText: String

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService
    @State private var akDraft: String = ""
    @State private var skDraft: String = ""
    @State private var hasStored: Bool = false
    @State private var saveError: String?
    @State private var saveWarning: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(L10n.Settings.miscAccessKeyId, text: $akDraft)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                SecureField(L10n.Settings.miscSecretAccessKey, text: $skDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button(L10n.Common.save, action: save)
                    .disabled(akDraft.isEmpty || skDraft.isEmpty)
                if hasStored {
                    Button(role: .destructive, action: clear) {
                        Image(systemName: "trash")
                    }
                    .help(L10n.Settings.miscRemoveAkSk(provider: tool.menuTitle))
                }
            }
            HStack(spacing: 4) {
                Image(systemName: hasStored ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(hasStored ? Color.green : Color.secondary)
                    .font(.caption)
                Text(hasStored ? L10n.Settings.miscAkSkSaved : helpText)
                    .font(.caption)
                    .foregroundStyle(hasStored ? .secondary : .tertiary)
            }
            if let saveError {
                Text(saveError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let saveWarning {
                Text(saveWarning)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            hasStored = MiscCredentialStore.hasValue(tool: tool, kind: .accessKeyID, instanceID: instanceID)
                && MiscCredentialStore.hasValue(tool: tool, kind: .secretAccessKey, instanceID: instanceID)
        }
    }

    private func save() {
        let ak = akDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let sk = skDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ak.isEmpty, !sk.isEmpty else { return }
        // Pasting the `sk-…` Ark inference key here is the single most
        // common Agent Plan setup mistake, and it used to look like a
        // success until the card came back with an auth error.
        let verdict = MiscCredentialFieldRules.check(tool: tool, kind: .accessKeyID, value: ak)
        guard verdict.allowsSave else {
            saveWarning = nil
            saveError = verdict.message
            return
        }
        let savedAK = MiscCredentialStore.writeString(ak, tool: tool, kind: .accessKeyID, instanceID: instanceID)
        let savedSK = MiscCredentialStore.writeString(sk, tool: tool, kind: .secretAccessKey, instanceID: instanceID)
        if savedAK && savedSK {
            saveError = nil
            saveWarning = verdict.message
            hasStored = true
            akDraft = ""
            skDraft = ""
            triggerRefresh()
        } else {
            saveError = "Could not save to Keychain."
        }
    }

    private func clear() {
        MiscCredentialStore.delete(tool: tool, kind: .accessKeyID, instanceID: instanceID)
        MiscCredentialStore.delete(tool: tool, kind: .secretAccessKey, instanceID: instanceID)
        hasStored = false
        saveError = nil
        saveWarning = nil
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
                    hasStoredToken ? L10n.Settings.miscGithubTokenSaved : L10n.Settings.miscGithubSignInHint,
                    systemImage: hasStoredToken ? "checkmark.circle.fill" : "person.crop.circle.badge.key"
                )
                .font(.caption)
                .foregroundStyle(hasStoredToken ? Color.green : Color.secondary)

                Spacer(minLength: 4)

                Button(isSigningIn ? L10n.Settings.miscWaiting : L10n.Settings.miscSignIn) {
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
                    .help(L10n.Settings.miscRemoveGithubToken)
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
            Text(L10n.Settings.miscKiroHint)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            Button(L10n.Settings.miscProbe, action: probe)
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
    /// How much visual weight the import button carries.
    ///
    /// The misc-providers list packs a dozen providers into one scroll and
    /// keeps every control small; a core-provider page puts this button
    /// directly under full-size ones, where a small text-only button reads
    /// as a lesser class of control rather than the same action.
    enum Emphasis {
        case compact
        case standard
    }

    let tool: ToolType
    let instanceID: String
    let manualPrompt: String
    var emphasis: Emphasis = .compact

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService

    @State private var slots: [MiscCookieSlot] = []
    @State private var manualDraft: String = ""
    @State private var importStatus: String?
    /// Set when the last import found nothing because macOS Keychain
    /// access for a browser had been declined. Carries its own row with a
    /// "Retry now" button, because the fix is a gate reset rather than
    /// anything the user can do in the browser.
    @State private var keychainCooldown: KeychainCooldownNotice?

    struct KeychainCooldownNotice: Equatable {
        let browser: String
        let until: Date

        var message: String {
            "macOS Keychain access for \(browser) was declined. Vibe Bar will not ask again until \(Self.formatter.string(from: until))."
        }

        // Built per language rather than once per process: a formatter
        // parked in a `static let` keeps the language it was created in.
        private static var formatter: DateFormatter {
            AppLocale.dateFormatter(dateStyle: .short, timeStyle: .short)
        }
    }

    /// Which cookies to look for. Comes from `MiscCookieSpecCatalog`
    /// rather than the caller so this row and the all-providers batch
    /// import can never disagree about a provider's domains. `nil` means
    /// a provider row was wired up without registering a spec, which is
    /// a programmer error rather than a user-facing state.
    private var spec: MiscCookieResolver.Spec? {
        MiscCookieSpecCatalog.spec(for: tool)
    }

    var body: some View {
        if spec == nil {
            Text(L10n.Settings.miscNoCookieSpec(provider: tool.menuTitle))
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            controls
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if slots.isEmpty {
                Text(L10n.Settings.miscNoCookiesYet)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(slots) { slot in
                        CookieSlotRow(slot: slot) { deleteSlot(slot) }
                    }
                }
            }
            switch emphasis {
            case .compact:
                HStack(alignment: .top, spacing: 6) {
                    importButton
                    importDetail
                }
            case .standard:
                // Button on its own line, caption beneath — the rhythm the
                // rest of a core-provider page already uses.
                importButton
                importDetail
            }
            HStack(spacing: 6) {
                SecureField(manualPrompt, text: $manualDraft)
                    .textFieldStyle(.roundedBorder)
                Button(L10n.Common.add, action: saveManual)
                    .disabled(manualDraft.isEmpty)
            }
            if let keychainCooldown {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "lock.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(keychainCooldown.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.Common.retryNow, action: resetCooldownAndRetry)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            if let importStatus {
                Text(importStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        let snapshotTool = tool
        let snapshotInstanceID = instanceID
        DispatchQueue.global(qos: .utility).async {
            let loaded = MiscCookieSlotStore.slots(
                for: snapshotTool,
                instanceID: snapshotInstanceID
            )
            DispatchQueue.main.async {
                slots = loaded
            }
        }
    }

    private func importNow() {
        guard let snapshotSpec = spec else { return }
        importStatus = "Importing…"
        keychainCooldown = nil
        let snapshotInstanceID = instanceID
        DispatchQueue.global(qos: .userInitiated).async {
            let result = MiscCookieResolver.appendBrowserImportOutcome(
                for: snapshotSpec,
                instanceID: snapshotInstanceID
            )
            DispatchQueue.main.async {
                apply(result)
            }
        }
    }

    private func apply(_ result: MiscCookieResolver.BatchImportOutcome.Result) {
        switch result {
        case .imported(let sourceLabel):
            keychainCooldown = nil
            importStatus = "Imported from \(sourceLabel)."
            reloadSlots()
            triggerRefresh()
        case .noSessionFound:
            keychainCooldown = nil
            importStatus = "No cookies found. Sign in at the provider in your browser, then retry."
        case let .keychainCooldown(browser, until):
            importStatus = nil
            keychainCooldown = KeychainCooldownNotice(browser: browser, until: until)
        case .cookiesDisabled:
            keychainCooldown = nil
            importStatus = "Cookie sources are turned off for this provider in settings.json."
        case .saveFailed:
            keychainCooldown = nil
            importStatus = "Found a session, but could not save it to Keychain."
        }
    }

    private func resetCooldownAndRetry() {
        BrowserCookieAccessGate.reset()
        keychainCooldown = nil
        importNow()
    }

    private func saveManual() {
        let trimmed = manualDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let normalised = normalizedManualCookie(from: trimmed), !normalised.isEmpty else {
            importStatus = missingCookieMessage
            return
        }
        // Providers that ship the whole jar can't lean on `requiredNames`
        // to reject a useless paste, so check the one cookie their adapter
        // actually reads out of the header before storing it.
        if let rejection = MiscManualCookieRules.rejectionMessage(for: tool, header: normalised) {
            importStatus = rejection
            return
        }
        let slot = MiscCookieSlot(
            cookieHeader: normalised,
            sourceLabel: "Manual paste",
            importedAt: Date(),
            origin: .manual
        )
        importStatus = "Saving…"
        let snapshotTool = tool
        let snapshotInstanceID = instanceID
        DispatchQueue.global(qos: .userInitiated).async {
            let saved = MiscCookieSlotStore.append(
                slot,
                for: snapshotTool,
                instanceID: snapshotInstanceID
            )
            DispatchQueue.main.async {
                guard saved else {
                    importStatus = "Could not save to Keychain."
                    return
                }
                importStatus = "Pasted cookie saved."
                manualDraft = ""
                reloadSlots()
                triggerRefresh()
            }
        }
    }

    @ViewBuilder
    private var importButton: some View {
        switch emphasis {
        case .compact:
            Button(L10n.Onboarding.cookiesImportFromBrowser, action: importNow)
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .standard:
            Button(action: importNow) {
                Label(L10n.Onboarding.cookiesImportFromBrowser, systemImage: "safari")
            }
        }
    }

    private var importDetail: some View {
        Text(L10n.Settings.miscImportDetail)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func deleteSlot(_ slot: MiscCookieSlot) {
        let snapshotTool = tool
        let snapshotInstanceID = instanceID
        let snapshotSlot = slot
        DispatchQueue.global(qos: .userInitiated).async {
            let deleted = MiscCookieSlotStore.delete(
                slotID: snapshotSlot.id,
                for: snapshotTool,
                instanceID: snapshotInstanceID
            )
            DispatchQueue.main.async {
                guard deleted else { return }
                importStatus = "Removed \(snapshotSlot.sourceLabel)."
                reloadSlots()
                triggerRefresh()
            }
        }
    }

    private func normalizedManualCookie(from raw: String) -> String? {
        guard let spec, !spec.requiredNames.isEmpty else {
            return CookieHeaderNormalizer.normalize(raw)
        }
        return CookieHeaderNormalizer.filteredHeader(from: raw, allowedNames: spec.requiredNames)
    }

    private var missingCookieMessage: String {
        guard let spec, !spec.requiredNames.isEmpty else {
            let names = MiscManualCookieRules.requiredCookieNames(for: tool)
            if !names.isEmpty {
                return "No \(names.joined(separator: " or ")) cookie found in the pasted text — copy the whole Cookie header from the provider's console tab."
            }
            return "No usable cookie found in the pasted text — copy the whole Cookie header from the provider's console tab."
        }
        return "No \(spec.requiredNames.sorted().joined(separator: ", ")) cookie found in the pasted text."
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
            // Where this slot's header came from. That is the slot state
            // Settings actually has: per-slot quota outcomes are merged by
            // `MiscQuotaAggregator` before they reach any store, so a
            // per-slot health badge would have to be invented here.
            Text(originLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                )
                .help(originHelp)
            Spacer(minLength: 4)
            Text(Self.dateFormatter.string(from: slot.importedAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L10n.Settings.miscRemoveCookieSlot)
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

    private var originLabel: String {
        switch slot.origin {
        case .manual:         return "Pasted"
        case .browserImport:  return "Browser"
        case .autoRefresh:    return "Auto-refreshed"
        }
    }

    private var originHelp: String {
        switch slot.origin {
        case .manual:
            return "Pasted by hand. Auto re-import never overwrites this slot."
        case .browserImport:
            return "Imported from this browser profile. \"Import from browser\" refreshes it in place."
        case .autoRefresh:
            return "Re-read from the browser automatically after the stored header stopped working."
        }
    }

    // Built per language rather than once per process: a formatter
    // parked in a `static let` keeps the language it was created in.
    private static var dateFormatter: DateFormatter {
        AppLocale.dateFormatter(dateStyle: .medium, timeStyle: .short)
    }
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
            case .auto:           return L10n.Settings.miscRegionAuto
            case .international:  return L10n.Settings.miscRegionInternational
            case .chinaMainland:  return L10n.Settings.miscRegionChinaMainland
            }
        }
    }

    var body: some View {
        Picker(L10n.Settings.miscRegion, selection: choiceBinding) {
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
        Picker(L10n.Settings.miscVariant, selection: choiceBinding) {
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

/// Z.ai has separate international and mainland China quota hosts, and a
/// key issued on one returns 401 on the other — indistinguishable from a
/// bad key. "Auto" lets the adapter try the second host before giving up.
struct ZaiRegionPicker: View {
    let instanceID: String

    @EnvironmentObject var settingsStore: SettingsStore

    enum Choice: String, CaseIterable, Identifiable {
        case auto = ""
        case global
        case bigmodelCN = "bigmodel-cn"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto:       return L10n.Settings.miscRegionAuto
            case .global:     return L10n.Settings.miscRegionZaiGlobal
            case .bigmodelCN: return L10n.Settings.miscRegionZaiChina
            }
        }
    }

    var body: some View {
        Picker(L10n.Settings.miscRegion, selection: choiceBinding) {
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
            case .global:        return L10n.Settings.miscRegionMinimaxGlobal
            case .chinaMainland: return L10n.Settings.miscRegionMinimaxChina
            }
        }
    }

    var body: some View {
        Picker(L10n.Settings.miscRegion, selection: choiceBinding) {
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
            Button(L10n.Common.save, action: save)
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
            Button(L10n.Common.save, action: save)
                .disabled(draft == currentRaw)
            if !currentRaw.isEmpty {
                Button(role: .destructive, action: clear) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(L10n.Settings.miscClearWorkspace)
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
                Button(L10n.Settings.miscSignInViaWeb) {
                    environment.openMiscWebLogin(for: tool, instanceID: instanceID)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        )
    }
}
