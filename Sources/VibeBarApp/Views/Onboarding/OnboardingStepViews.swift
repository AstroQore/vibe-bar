import SwiftUI
import VibeBarCore

// MARK: - Welcome

struct OnboardingWelcomeStep: View {
    let density: Theme.Density

    var body: some View {
        CardShell(density: density) {
            Text("Vibe Bar sits in your menu bar and shows, at a glance, how much of each AI subscription you have left, what your coding agents are spending, and which sessions and skills live on this Mac. It reads the credentials the Codex, Claude Code, Gemini and Grok CLIs already keep here, adds web quotas from your browser's cookies when you ask it to, and never sends any of it anywhere but the provider it came from.")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            OnboardingFeatureRow(
                systemImage: "gauge.with.dots.needle.33percent",
                title: "Subscription quotas",
                detail: "Codex, Claude Code, Gemini, Grok and a shelf of API-key plans, each with its reset countdown."
            )
            OnboardingFeatureRow(
                systemImage: "dollarsign.circle",
                title: "Token cost",
                detail: "Priced locally from the agents' own session logs against a merged model price catalog."
            )
            OnboardingFeatureRow(
                systemImage: "rectangle.stack",
                title: "Sessions and skills",
                detail: "Browse, search and tidy agent sessions and shared skills from the Workbench."
            )
            OnboardingFeatureRow(
                systemImage: "point.3.connected.trianglepath.dotted",
                title: "Local MCP server",
                detail: "Your agents can ask Vibe Bar for quota and cost over a Unix socket in your home directory."
            )
        }
        Text("This takes about two minutes. Every choice here can be changed later in Settings, and the assistant is one click away under Settings → System.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct OnboardingFeatureRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(WorkbenchPorcelain.accent)
                .frame(width: 20, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Subscriptions

struct OnboardingSubscriptionsStep: View {
    let density: Theme.Density

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        Text("Turn on the subscriptions you use. A provider that is off stays out of the Overview and the menu bar; turning one off later keeps its credentials and history.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        ForEach(ToolType.coreProviderRepresentatives, id: \.self) { tool in
            OnboardingCoreProviderCard(tool: tool, density: density)
        }
    }
}

/// One core provider: the Overview switch, what credential is already on
/// this Mac, and the same import / login actions the provider's Settings
/// page offers.
private struct OnboardingCoreProviderCard: View {
    let tool: ToolType
    let density: Theme.Density

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        CardShell(density: density) {
            HStack(spacing: 10) {
                ToolBrandBadge(tool: tool, iconSize: 20, containerSize: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tool.vendorName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(productLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Toggle("Show in Overview", isOn: visibilityBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.caption)
            }
            credentialHint
            actions
            statusLines
        }
    }

    private var productLine: String {
        switch tool {
        case .codex: "Codex CLI · ChatGPT web"
        case .claude: "Claude Code · claude.ai web"
        case .gemini: "Gemini web · AntiGravity"
        case .grok: "Grok CLI · grok.com · Cursor"
        default: tool.subtitle
        }
    }

    private var visibilityBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.isCoreProviderVisible(tool) },
            set: { settingsStore.settings.setCoreProviderVisible($0, for: tool) }
        )
    }

    @ViewBuilder
    private var credentialHint: some View {
        switch tool {
        case .codex:
            cliHint(
                account: environment.account(for: .codex),
                detected: "Codex CLI login detected — quota will come from it.",
                web: "ChatGPT web cookies saved — quota will come from them.",
                missing: "No Codex CLI login found. Run `codex login`, or import ChatGPT cookies from your browser below."
            )
        case .claude:
            cliHint(
                account: environment.account(for: .claude),
                detected: "Claude Code login detected — quota will come from it.",
                web: "claude.ai cookies saved — quota will come from them.",
                missing: "No Claude Code login found. Run `claude login`, or import claude.ai cookies from your browser below."
            )
        case .gemini:
            hintLabel(
                "Gemini quota is read from gemini.google.com cookies; there is no CLI login or WebView path. AntiGravity is probed locally when it is running.",
                systemImage: "info.circle",
                tint: .secondary
            )
        case .grok:
            if GrokCredentialsStore.hasCredentials() {
                hintLabel("~/.grok/auth.json detected — quota will come from it.", systemImage: "checkmark.circle", tint: .green)
            } else {
                hintLabel(
                    "No ~/.grok/auth.json yet. Run `grok login`, or import grok.com cookies from your browser below.",
                    systemImage: "exclamationmark.circle",
                    tint: .secondary
                )
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func cliHint(account: AccountIdentity?, detected: String, web: String, missing: String) -> some View {
        switch account?.source {
        case .cliDetected, .oauthCLI:
            hintLabel(detected, systemImage: "checkmark.circle", tint: .green)
        case .webCookie:
            hintLabel(web, systemImage: "checkmark.circle", tint: .green)
        case .some:
            hintLabel(detected, systemImage: "checkmark.circle", tint: .green)
        case .none:
            hintLabel(missing, systemImage: "exclamationmark.circle", tint: .secondary)
        }
    }

    private func hintLabel(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var actions: some View {
        HStack {
            switch tool {
            case .codex:
                Button {
                    environment.importOpenAIBrowserCookies()
                } label: {
                    Label("Import from browser", systemImage: "safari")
                }
                .disabled(environment.isImportingOpenAIBrowserCookies)
                Button {
                    environment.openOpenAIWebLogin()
                } label: {
                    Label("Open WebView login", systemImage: "person.crop.circle.badge.key")
                }
            case .claude:
                Button {
                    environment.importClaudeBrowserCookies()
                } label: {
                    Label("Import from browser", systemImage: "safari")
                }
                .disabled(environment.isImportingClaudeBrowserCookies)
                Button {
                    environment.openClaudeWebLogin()
                } label: {
                    Label("Open WebView login", systemImage: "person.crop.circle.badge.key")
                }
            case .gemini:
                Button {
                    environment.importGeminiBrowserCookies()
                } label: {
                    Label("Import Gemini cookies from browser", systemImage: "safari")
                }
                .disabled(environment.isImportingGeminiBrowserCookies)
            case .grok:
                Button {
                    environment.importGrokBrowserCookies()
                } label: {
                    Label("Import Grok cookies from browser", systemImage: "safari")
                }
                .disabled(environment.isImportingGrokBrowserCookies)
            default:
                EmptyView()
            }
        }
    }

    /// Whether this provider's web cookies are in the Keychain, and the
    /// last import's status line, if any.
    private var cookieState: (saved: Bool, status: String?) {
        switch tool {
        case .codex:
            (environment.hasOpenAIWebCookies, environment.openAIBrowserCookieImportStatus)
        case .claude:
            (environment.hasClaudeWebCookies, environment.claudeBrowserCookieImportStatus)
        case .gemini:
            (environment.hasGeminiWebCookies, environment.geminiBrowserCookieImportStatus)
        case .grok:
            (environment.hasGrokWebCookies, environment.grokBrowserCookieImportStatus)
        default:
            (false, nil)
        }
    }

    @ViewBuilder
    private var statusLines: some View {
        let (saved, status) = cookieState
        if saved {
            Text("Cookies saved.")
                .font(.caption2)
                .foregroundStyle(.green)
        }
        if let status {
            Text(status)
                .font(.caption2)
                .foregroundStyle(status.hasPrefix("Imported") ? .green : .secondary)
        }
    }
}

// MARK: - Browser cookies

struct OnboardingBrowserCookiesStep: View {
    let density: Theme.Density

    @EnvironmentObject private var environment: AppEnvironment

    private var isImportingAny: Bool {
        environment.isImportingOpenAIBrowserCookies
            || environment.isImportingClaudeBrowserCookies
            || environment.isImportingGeminiBrowserCookies
            || environment.isImportingGrokBrowserCookies
    }

    var body: some View {
        CardShell(density: density) {
            Text("Web quotas — the ones the provider shows on its own site — come from the session your browser already has. Vibe Bar reads the cookie stores of the browsers on this Mac (Chrome and other Chromium browsers, Safari, Firefox), keeps only the few cookies each provider needs, and stores them in your login Keychain, never in a plaintext file. macOS may ask once for permission to read a browser's cookie key.")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Button {
                environment.importOpenAIBrowserCookies()
                environment.importClaudeBrowserCookies()
                environment.importGeminiBrowserCookies()
                environment.importGrokBrowserCookies()
            } label: {
                Label(isImportingAny ? "Importing…" : "Import from all browsers now", systemImage: "safari")
            }
            .disabled(isImportingAny)
            Divider()
            providerRow(
                .codex,
                importing: environment.isImportingOpenAIBrowserCookies,
                saved: environment.hasOpenAIWebCookies,
                status: environment.openAIBrowserCookieImportStatus
            )
            providerRow(
                .claude,
                importing: environment.isImportingClaudeBrowserCookies,
                saved: environment.hasClaudeWebCookies,
                status: environment.claudeBrowserCookieImportStatus
            )
            providerRow(
                .gemini,
                importing: environment.isImportingGeminiBrowserCookies,
                saved: environment.hasGeminiWebCookies,
                status: environment.geminiBrowserCookieImportStatus
            )
            providerRow(
                .grok,
                importing: environment.isImportingGrokBrowserCookies,
                saved: environment.hasGrokWebCookies,
                status: environment.grokBrowserCookieImportStatus
            )
        }
        Text("Sign in to chatgpt.com, claude.ai, gemini.google.com or grok.com in your browser first — an import can only find a session that exists. Providers you have not signed in to simply report nothing.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Text("This button covers the four plans above. The console-cookie plans on the next step have their own one-click batch import later, under Settings → Browser Cookies.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func providerRow(_ tool: ToolType, importing: Bool, saved: Bool, status: String?) -> some View {
        HStack(spacing: 10) {
            ToolBrandBadge(tool: tool, iconSize: 17, containerSize: 24)
            Text(tool.vendorName)
                .font(.system(size: 13, weight: .medium))
            Spacer(minLength: 12)
            statusText(importing: importing, saved: saved, status: status)
                .font(.caption2)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func statusText(importing: Bool, saved: Bool, status: String?) -> some View {
        if importing {
            Text("Importing…")
                .foregroundStyle(.secondary)
        } else if let status {
            Text(status)
                .foregroundStyle(status.hasPrefix("Imported") ? .green : .secondary)
        } else if saved {
            Text("Cookies saved.")
                .foregroundStyle(.green)
        } else {
            Text("Not imported yet")
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - API-key providers

struct OnboardingAPIKeyProvidersStep: View {
    let density: Theme.Density

    @EnvironmentObject private var settingsStore: SettingsStore
    /// Rows whose credential controls are unfolded. Kept apart from
    /// visibility so a page with every provider on (the default) does not
    /// open twenty credential forms at once.
    @State private var expanded: Set<String> = []

    var body: some View {
        Text("These plans are tracked with an API key or a console cookie rather than a CLI login. Tick the ones you have — a ticked provider gets a card on the Misc page — and unfold a row to enter its credential now. Keys and cookies go to your login Keychain.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        CardShell(density: density, spacing: 0) {
            let instances = settingsStore.settings.miscProviderInstances
                .filter { $0.tool.isMiscPageProvider }
            ForEach(Array(instances.enumerated()), id: \.element.id) { index, instance in
                if index > 0 {
                    Divider()
                        .padding(.vertical, 6)
                }
                providerRow(instance)
            }
        }
    }

    private func providerRow(_ instance: MiscProviderInstance) -> some View {
        let visible = instance.isVisible
        let unfolded = visible && expanded.contains(instance.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle(isOn: visibilityBinding(instance.id)) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Show \(instance.tool.menuTitle) on the Misc page")
                ToolBrandBadge(tool: instance.tool, iconSize: 17, containerSize: 24)
                    .opacity(visible ? 1 : 0.55)
                // `menuTitle` alone renders both Volcengine plans as
                // "Volcengine"; the subtitle beside it is what separates
                // Coding Plan from Agent Plan.
                Text(instance.displayTitle(fallback: instance.tool.menuTitle))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(visible ? Color.primary : Color.secondary)
                Text(instance.tool.subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                Button {
                    if unfolded {
                        expanded.remove(instance.id)
                    } else {
                        expanded.insert(instance.id)
                    }
                } label: {
                    Label(unfolded ? "Hide" : "Set up", systemImage: unfolded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .buttonStyle(WorkbenchPillButtonStyle())
                .controlSize(.small)
                .disabled(!visible)
                // The pill draws no disabled state of its own.
                .opacity(visible ? 1 : 0.4)
            }
            if unfolded {
                MiscProviderCredentialRows(instance: instance)
                    .padding(.leading, 32)
            }
        }
    }

    private func visibilityBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { settingsStore.settings.miscProviderInstance(id: id)?.isVisible ?? false },
            set: { settingsStore.settings.setMiscProviderInstanceVisible($0, forID: id) }
        )
    }
}

// MARK: - Model pricing

struct OnboardingPricingStep: View {
    let density: Theme.Density

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        CardShell(density: density) {
            Text("Token cost is computed on this Mac from your agents' session logs, priced with a catalog merged from several public price lists — higher-priority entries win when a model appears in more than one, your own overrides beat them all, and a bundled table is the offline floor. Catalogs refresh in the background every \(intervalLabel(settingsStore.settings.pricingRefreshIntervalSeconds)); fetching now gives the first cost numbers current prices.")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(action: environment.refreshPricingNow) {
                    Label(
                        environment.isRefreshingPricing ? "Fetching…" : "Fetch prices now",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .disabled(environment.isRefreshingPricing)
                if let date = environment.pricingRefreshStatus.mergedAt {
                    Text("Merged \(date.formatted(date: .abbreviated, time: .shortened)) · \(environment.pricingRefreshStatus.mergedModelCount) models")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not fetched yet — the bundled table is in use.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            ForEach(PricingSourceID.allCases, id: \.self) { source in
                sourceRow(source)
            }
        }
        Text("Prices are USD per one million tokens. Local overrides live under Settings → Model Pricing.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func sourceRow(_ source: PricingSourceID) -> some View {
        let status = environment.pricingRefreshStatus.sources.first { $0.source == source }
        return HStack(spacing: 10) {
            Circle()
                .fill(statusColor(status?.result ?? .never))
                .frame(width: 7, height: 7)
            Text(source.label)
                .font(.system(size: 13))
            Spacer()
            Text(sourceDetail(status))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func sourceDetail(_ status: PricingSourceStatus?) -> String {
        guard let status else { return "Not refreshed" }
        switch status.result {
        case .ready: return "\(status.modelCount) models"
        case .unchanged: return "\(status.modelCount) models · unchanged"
        case .failed: return "Cached \(status.modelCount) · refresh failed"
        case .never: return "Not refreshed"
        }
    }

    private func statusColor(_ result: PricingSourceRefreshResult) -> Color {
        switch result {
        case .ready, .unchanged: .green
        case .failed: .orange
        case .never: .secondary
        }
    }

    private func intervalLabel(_ seconds: Int) -> String {
        let hours = seconds / 3600
        return hours == 1 ? "hour" : "\(hours) hours"
    }
}

// MARK: - Launch at login

struct OnboardingLaunchAtLoginStep: View {
    let density: Theme.Density

    @EnvironmentObject private var settingsStore: SettingsStore
    // A demo launch registers nothing with the system and must not read the
    // real login item either: the captured state is the settings file's.
    @State private var statusText: String = DemoMode.isEnabled ? "Off." : LoginItemController.statusText
    @State private var errorText: String?

    var body: some View {
        CardShell(density: density) {
            Toggle("Launch Vibe Bar at login", isOn: binding)
                .toggleStyle(.switch)
            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let errorText {
                Text(errorText)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Divider()
            Text("Vibe Bar is a menu-bar app with no Dock icon. Starting it at login keeps the quota readout and the local MCP server available from the moment you sign in; macOS may ask you to approve the login item in System Settings the first time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: refreshState)
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.launchAtLogin },
            set: { enabled in
                if DemoMode.isEnabled {
                    settingsStore.settings.launchAtLogin = enabled
                    statusText = enabled ? "Enabled in macOS Login Items." : "Off."
                    return
                }
                do {
                    try LoginItemController.reconcileDesiredState(enabled)
                    settingsStore.settings.launchAtLogin = enabled
                    errorText = nil
                } catch {
                    errorText = error.localizedDescription
                }
                refreshState()
            }
        )
    }

    private func refreshState() {
        guard !DemoMode.isEnabled else { return }
        switch LoginItemController.status {
        case .enabled, .requiresApproval:
            settingsStore.settings.launchAtLogin = true
        case .notRegistered:
            settingsStore.settings.launchAtLogin = false
        case .notFound:
            break
        @unknown default:
            break
        }
        statusText = LoginItemController.statusText
    }
}

// MARK: - Done

struct OnboardingDoneStep: View {
    let density: Theme.Density

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        CardShell(density: density) {
            Text("That is everything the menu bar needs. Finish opens the popover with whatever quota is already readable; the rest fills in on the first refresh.")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            summaryRow("Subscriptions", value: visibleCoreProviders)
            summaryRow("Browser cookies", value: "\(savedCookieCount) of 4 providers saved")
            summaryRow("API-key providers", value: "\(visibleMiscCount) on the Misc page")
            summaryRow("Model pricing", value: pricingSummary)
            summaryRow("Launch at login", value: settingsStore.settings.launchAtLogin ? "On" : "Off")
        }
        Text("Every one of these lives in Settings, and the assistant is one click away under Settings → System.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func summaryRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 13))
            Spacer(minLength: 12)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var visibleCoreProviders: String {
        let names = ToolType.coreProviderRepresentatives
            .filter { settingsStore.settings.isCoreProviderVisible($0) }
            .map(\.vendorName)
        return names.isEmpty ? "None shown" : names.joined(separator: ", ")
    }

    private var savedCookieCount: Int {
        [
            environment.hasOpenAIWebCookies,
            environment.hasClaudeWebCookies,
            environment.hasGeminiWebCookies,
            environment.hasGrokWebCookies,
        ].filter { $0 }.count
    }

    private var visibleMiscCount: Int {
        settingsStore.settings.miscProviderInstances
            .filter { $0.tool.isMiscPageProvider && $0.isVisible }
            .count
    }

    private var pricingSummary: String {
        if let date = environment.pricingRefreshStatus.mergedAt {
            return "Merged \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        return "Bundled table until the first fetch"
    }
}
