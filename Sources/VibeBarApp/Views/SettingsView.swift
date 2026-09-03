import SwiftUI
import VibeBarCore

enum SettingsSectionID: String {
    case menuBar
    case menuBarHealth
    case miniWindow
    case layout
    case openAI
    case anthropic
    case googleAI
    case xAI
    case miscProviders
    case system
    case costData
    case pricing
    case privacy
    case remote
    case mcp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .menuBar: L10n.Settings.sectionMenuBar
        case .menuBarHealth: L10n.Settings.sectionMenuBarHealth
        case .miniWindow: L10n.Settings.sectionMiniWindows
        case .layout: L10n.Settings.sectionLayout
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .googleAI: "Google AI"
        case .xAI: "SpaceXAI"
        case .miscProviders: L10n.Popover.tabMisc
        case .system: L10n.Settings.sectionSystem
        case .costData: L10n.Settings.sectionCostData
        case .pricing: L10n.Onboarding.stepPricingTitle
        case .privacy: L10n.Settings.sectionPrivacy
        case .remote: L10n.Settings.sectionRemoteProbes
        case .mcp: L10n.Settings.mcpTitle
        }
    }

    var systemImage: String {
        switch self {
        case .menuBar: "menubar.rectangle"
        case .menuBarHealth: "stethoscope"
        case .miniWindow: "rectangle.on.rectangle"
        case .layout: "rectangle.split.2x1"
        case .openAI: "brain.head.profile"
        case .anthropic: "sparkles"
        case .googleAI: "diamond"
        case .xAI: "circle.hexagongrid"
        case .miscProviders: "square.grid.2x2"
        case .system: "desktopcomputer"
        case .costData: "chart.bar.xaxis"
        case .pricing: "dollarsign.circle"
        case .privacy: "hand.raised.fill"
        case .remote: "antenna.radiowaves.left.and.right"
        case .mcp: "point.3.connected.trianglepath.dotted"
        }
    }
}

enum SettingsDestination: Hashable {
    case page(SettingsSectionID)
    case coreProvider(ToolType)
    case miscProvider(String)

    var sectionID: SettingsSectionID {
        switch self {
        case let .page(section): section
        case let .coreProvider(tool):
            switch tool.coreProviderRepresentative {
            case .codex: .openAI
            case .claude: .anthropic
            case .gemini: .googleAI
            case .grok: .xAI
            default: .openAI
            }
        case .miscProvider: .miscProviders
        }
    }

    func title(settings: AppSettings) -> String {
        switch self {
        case let .page(section): return section.title
        case let .coreProvider(tool):
            switch tool.coreProviderRepresentative {
            case .codex: return "OpenAI"
            case .claude: return "Anthropic"
            case .gemini: return "Google AI"
            case .grok: return "SpaceXAI"
            default: return tool.vendorName
            }
        case let .miscProvider(id):
            guard let instance = settings.miscProviderInstance(id: id) else { return "Misc Provider" }
            return instance.displayTitle(fallback: instance.tool.menuTitle)
        }
    }
}

/// The Workbench's Settings page.
///
/// It is a page, not a window: the Workbench's own sidebar, header and
/// density own the chrome, and everything here is content. The section
/// column on the left is a navigator inside the page — no fill and no title
/// of its own — so Settings reads as the fourth Workbench page rather than a
/// second application bolted into the detail pane.
struct SettingsView: View {
    let density: Theme.Density
    @Binding var selection: SettingsDestination

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var quotaService: QuotaService

    private let intervalOptions = AppSettings.refreshIntervalOptions
    private let popoverRefreshCooldownOptions: [Int] = [60, 120, 300, 600]
    private let costRetentionOptions = CostDataSettings.retentionOptions
    @State private var openAICookieDeleteFailed: Bool = false
    @State private var claudeCookieDeleteFailed: Bool = false
    @State private var geminiCookieDeleteFailed: Bool = false
    @State private var grokCookieDeleteFailed: Bool = false
    @State private var costDataClearStatus: String?
    @State private var launchAtLoginStatusText: String = LoginItemController.statusText
    @State private var launchAtLoginError: String?

    private var selectedDestination: SettingsDestination { selection }

    private var selectedSection: SettingsSectionID {
        selectedDestination.sectionID
    }

    /// `settings.json` is shared with Vibe Bar Desktop and with a second copy
    /// of this app, and the last writer wins per setting. When that costs the
    /// user a choice they made here, say so where they made it — the
    /// alternative is a control that silently springs back.
    @ViewBuilder
    private var externalChangeBanner: some View {
        if let change = settingsStore.replacedByAnotherWriter {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.Settings.externalChangeTitle)
                        .font(.callout.weight(.medium))
                    Text(change.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(L10n.Common.dismiss) { settingsStore.acknowledgeExternalChange() }
                    .buttonStyle(.vibeBar)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
            )
            .transition(.opacity)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebarView(selection: $selection)

            Divider().opacity(0.45)

            ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: density.interSectionSpacing) {
                    externalChangeBanner
                    if selectedSection == .system {
                    LanguageSettingsSection(density: density)
                    settingsSection(L10n.Settings.sectionSystem) {
                        Toggle(L10n.Platform.macosLaunchAtLoginTitle, isOn: launchAtLoginBinding())
                        Text(launchAtLoginStatusText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let launchAtLoginError {
                            Text(launchAtLoginError)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        Divider()
                            .padding(.vertical, 2)
                        Button {
                            environment.showOnboarding()
                        } label: {
                            Label(L10n.Settings.showAssistant, systemImage: "wand.and.stars")
                        }
                        Text(L10n.Settings.showAssistantDetail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .id(SettingsSectionID.system.rawValue)

                    settingsSection(L10n.Settings.sectionRefreshing) {
                        Picker(L10n.Settings.percentShows, selection: $settingsStore.settings.displayMode) {
                            ForEach(DisplayMode.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Picker(L10n.Settings.refreshEvery, selection: $settingsStore.settings.refreshIntervalSeconds) {
                            ForEach(intervalOptions, id: \.self) { secs in
                                Text(intervalLabel(secs)).tag(secs)
                            }
                        }
                        Toggle(
                            L10n.Settings.refreshOnPopoverOpen,
                            isOn: $settingsStore.settings.refreshOnPopoverOpen
                        )
                        if settingsStore.settings.refreshOnPopoverOpen {
                            Picker(
                                L10n.Settings.openRefreshCooldown,
                                selection: $settingsStore.settings.popoverOpenRefreshCooldownSeconds
                            ) {
                                ForEach(popoverRefreshCooldownOptions, id: \.self) { secs in
                                    Text(intervalLabel(secs)).tag(secs)
                                }
                            }
                            Text(L10n.Settings.openRefreshDetail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .id("refreshing")

                    settingsSection(L10n.Settings.sectionUpdates) {
                        UpdateSettingsRow(updateController: environment.updateController)
                    }
                    .id("updates")

                    settingsSection(L10n.Settings.sectionComponents) {
                        AgentSessionKitComponentRow()
                    }
                    .id("components")
                    }

                    if selectedSection == .menuBar {
                    settingsSection(L10n.Settings.sectionOverview) {
                        menuBarOverviewEditor()
                    }
                    .id(SettingsSectionID.menuBar.rawValue)
                    }

                    if selectedSection == .menuBarHealth {
                    settingsSection(L10n.Settings.sectionMenuBarHealth) {
                        if let watchdog = environment.menuBarWatchdog {
                            MenuBarHealthSettingsSection(watchdog: watchdog)
                        } else {
                            Text(L10n.Settings.menuBarHealthUnavailable)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .id(SettingsSectionID.menuBarHealth.rawValue)
                    }

                    if selectedSection == .miniWindow {
                    settingsSection(L10n.Settings.sectionMiniWindows) {
                        MiniWindowsSettingsSection()
                    }
                    .id(SettingsSectionID.miniWindow.rawValue)
                    }

                    if selectedSection == .layout {
                    settingsSection(L10n.Settings.sectionLayout) {
                        LayoutEditorView()
                    }
                    .id(SettingsSectionID.layout.rawValue)
                    }

                    if selectedSection == .openAI {
                    settingsSection("OpenAI") {
                        coreProviderSummary(
                            representative: .codex,
                            healthProviders: [.codex]
                        )
                        coreProviderPlanBadgeRows(for: [.codex])
                        Divider()
                            .padding(.vertical, 2)
                        Picker(L10n.Settings.usageSource, selection: $settingsStore.settings.codexUsageMode) {
                            ForEach(CodexUsageMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        Text(settingsStore.settings.codexUsageMode.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button {
                                environment.importOpenAIBrowserCookies()
                            } label: {
                                Label(L10n.Onboarding.cookiesImportFromBrowser, systemImage: "safari")
                            }
                            .disabled(environment.isImportingOpenAIBrowserCookies)
                            Button {
                                environment.openOpenAIWebLogin()
                            } label: {
                                Label(L10n.Onboarding.cookiesOpenWebViewLogin, systemImage: "person.crop.circle.badge.key")
                            }
                            Button(role: .destructive) {
                                openAICookieDeleteFailed = !environment.deleteOpenAIWebCookies()
                            } label: {
                                Label(L10n.Settings.deleteCookies, systemImage: "trash")
                            }
                            .disabled(!environment.hasOpenAIWebCookies)
                        }
                        if environment.hasOpenAIWebCookies {
                            Text(L10n.Onboarding.cookiesSaved)
                                .font(.caption2).foregroundStyle(.green)
                        }
                        if let status = environment.openAIBrowserCookieImportStatus {
                            Text(status)
                                .font(.caption2)
                                .foregroundStyle(status.hasPrefix("Imported") ? .green : .secondary)
                        }
                        if openAICookieDeleteFailed {
                            Text(L10n.Settings.couldNotDeleteCookies)
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        Divider()
                            .padding(.vertical, 2)
                        connectionHealthRows(provider: .codex)
                        Button {
                            environment.recheckPrimaryRouteHealth(provider: .codex)
                        } label: {
                            Label(L10n.Settings.checkConnections(company: "OpenAI"), systemImage: "checkmark.circle")
                        }
                    }
                    .id(SettingsSectionID.openAI.id)
                    }

                    if selectedSection == .anthropic {
                    settingsSection("Anthropic") {
                        coreProviderSummary(
                            representative: .claude,
                            healthProviders: [.claude]
                        )
                        coreProviderPlanBadgeRows(for: [.claude])
                        Divider()
                            .padding(.vertical, 2)
                        Picker(L10n.Settings.usageSource, selection: $settingsStore.settings.claudeUsageMode) {
                            ForEach(ClaudeUsageMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        Text(settingsStore.settings.claudeUsageMode.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button {
                                environment.importClaudeBrowserCookies()
                            } label: {
                                Label(L10n.Onboarding.cookiesImportFromBrowser, systemImage: "safari")
                            }
                            .disabled(environment.isImportingClaudeBrowserCookies)
                            Button {
                                environment.openClaudeWebLogin()
                            } label: {
                                Label(L10n.Onboarding.cookiesOpenWebViewLogin, systemImage: "person.crop.circle.badge.key")
                            }
                            Button(role: .destructive) {
                                claudeCookieDeleteFailed = !environment.deleteClaudeWebCookies()
                            } label: {
                                Label(L10n.Settings.deleteCookies, systemImage: "trash")
                            }
                            .disabled(!environment.hasClaudeWebCookies)
                        }
                        if environment.hasClaudeWebCookies {
                            Text(L10n.Onboarding.cookiesSaved)
                                .font(.caption2).foregroundStyle(.green)
                        }
                        if let status = environment.claudeBrowserCookieImportStatus {
                            Text(status)
                                .font(.caption2)
                                .foregroundStyle(status.hasPrefix("Imported") ? .green : .secondary)
                        }
                        if claudeCookieDeleteFailed {
                            Text(L10n.Settings.couldNotDeleteCookies)
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        Divider()
                            .padding(.vertical, 2)
                        connectionHealthRows(provider: .claude)
                        Button {
                            environment.recheckPrimaryRouteHealth(provider: .claude)
                        } label: {
                            Label(L10n.Settings.checkConnections(company: "Anthropic"), systemImage: "checkmark.circle")
                        }
                    }
                    .id(SettingsSectionID.anthropic.id)
                    }

                    if selectedSection == .googleAI {
                    settingsSection("Google AI") {
                        coreProviderSummary(
                            representative: .gemini,
                            healthProviders: [.gemini, .antigravity]
                        )
                        coreProviderPlanBadgeRows(for: [.gemini, .antigravity])
                        Divider()
                            .padding(.vertical, 2)
                        Text(L10n.Settings.geminiShared)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        sourceSummary(label: L10n.Settings.geminiSource, value: L10n.Settings.webQuota)
                        Text(GeminiUsageMode.webOnly.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button {
                                environment.importGeminiBrowserCookies()
                            } label: {
                                Label(L10n.Onboarding.cookiesImportGemini, systemImage: "safari")
                            }
                            .disabled(environment.isImportingGeminiBrowserCookies)
                            Button(role: .destructive) {
                                geminiCookieDeleteFailed = !environment.deleteGeminiWebCookies()
                            } label: {
                                Label(L10n.Settings.deleteGeminiCookies, systemImage: "trash")
                            }
                            .disabled(!environment.hasGeminiWebCookies)
                        }
                        if environment.hasGeminiWebCookies {
                            Text(L10n.Settings.geminiCookiesSaved)
                                .font(.caption2).foregroundStyle(.green)
                        }
                        if let status = environment.geminiBrowserCookieImportStatus {
                            Text(status)
                                .font(.caption2)
                                .foregroundStyle(status.hasPrefix("Imported") ? .green : .secondary)
                        }
                        if geminiCookieDeleteFailed {
                            Text(L10n.Settings.couldNotDeleteGeminiCookies)
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        Divider()
                            .padding(.vertical, 2)
                        connectionHealthRows(provider: .gemini)

                        Divider()
                            .padding(.vertical, 2)

                        Picker(L10n.Settings.antigravitySource, selection: $settingsStore.settings.antigravityUsageMode) {
                            ForEach(AntigravityUsageMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        Text(settingsStore.settings.antigravityUsageMode.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // Antigravity web-cookie controls are gated on the
                        // spike outcome (plan §9). When the planner has the
                        // flag off, only the local LSP probe runs and the
                        // cookie controls would be dead UI.
                        if AntigravitySourcePlanner.antigravityWebSourceAvailable {
                            Text(L10n.Settings.antigravityCookieEnabled)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(L10n.Settings.antigravityLocalOnly)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Divider()
                            .padding(.vertical, 2)
                        connectionHealthRows(provider: .antigravity)
                        Button {
                            environment.recheckPrimaryRouteHealth(provider: .gemini)
                            environment.recheckPrimaryRouteHealth(provider: .antigravity)
                        } label: {
                            Label(L10n.Settings.checkConnections(company: "Google AI"), systemImage: "checkmark.circle")
                        }
                    }
                    .id(SettingsSectionID.googleAI.id)
                    }

                    if selectedSection == .xAI {
                    settingsSection("SpaceXAI") {
                        coreProviderSummary(
                            representative: .grok,
                            healthProviders: [.grok]
                        )
                        coreProviderPlanBadgeRows(for: [.grok, .cursor])
                        Divider()
                            .padding(.vertical, 2)
                        Text(L10n.Settings.spaceXAIIntro)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        sourceSummary(label: L10n.Settings.usageSource, value: L10n.Common.auto)

                        if GrokCredentialsStore.hasCredentials() {
                            Label(L10n.Settings.grokAuthDetected, systemImage: "checkmark.circle")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        } else {
                            Label(L10n.Onboarding.subscriptionsGrokMissing,
                                  systemImage: "exclamationmark.circle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Button {
                                environment.importGrokBrowserCookies()
                            } label: {
                                Label(L10n.Onboarding.cookiesImportGrok, systemImage: "safari")
                            }
                            .disabled(environment.isImportingGrokBrowserCookies)
                            Button(role: .destructive) {
                                grokCookieDeleteFailed = !environment.deleteGrokWebCookies()
                            } label: {
                                Label(L10n.Settings.deleteGrokCookies, systemImage: "trash")
                            }
                            .disabled(!environment.hasGrokWebCookies)
                        }
                        if environment.hasGrokWebCookies {
                            Text(L10n.Settings.grokCookiesSaved)
                                .font(.caption2).foregroundStyle(.green)
                        }
                        if let status = environment.grokBrowserCookieImportStatus {
                            Text(status)
                                .font(.caption2)
                                .foregroundStyle(status.hasPrefix("Imported") ? .green : .secondary)
                        }
                        if grokCookieDeleteFailed {
                            Text(L10n.Settings.couldNotDeleteGrokCookies)
                                .font(.caption2).foregroundStyle(.orange)
                        }

                        Divider()
                            .padding(.vertical, 2)

                        sourceSummary(label: L10n.Settings.cursorSource, value: L10n.Settings.cursorSourceValue)
                        if environment.account(for: .cursor)?.source == .cliDetected {
                            Label(L10n.Settings.cursorSessionDetected, systemImage: "checkmark.circle")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        } else {
                            Label(L10n.Settings.cursorNoSession,
                                  systemImage: "exclamationmark.circle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        CookieSourceControls(
                            tool: .cursor,
                            instanceID: ToolType.cursor.rawValue,
                            manualPrompt: "Paste cursor.com Cookie header (WorkosCursorSessionToken=...)"
                        )

                        Divider()
                            .padding(.vertical, 2)
                        connectionHealthRows(provider: .grok)
                        Button {
                            environment.recheckPrimaryRouteHealth(provider: .grok)
                        } label: {
                            Label(L10n.Settings.checkConnections(company: "SpaceXAI"), systemImage: "checkmark.circle")
                        }

                        Link(L10n.Settings.openStatusPage(company: "SpaceXAI"),
                             destination: ToolType.grok.statusPageURL)
                            .font(.caption2)
                    }
                    .id(SettingsSectionID.xAI.id)
                    }

                    if selectedSection == .miscProviders {
                    if case let .miscProvider(instanceID) = selectedDestination,
                       let instance = settingsStore.settings.miscProviderInstance(id: instanceID) {
                        settingsSection(instance.displayTitle(fallback: instance.tool.menuTitle)) {
                            MiscProviderSettingsSection(instance: instance)
                        }
                    } else {
                        settingsSection(L10n.Onboarding.doneBrowserCookies) {
                            MiscProviderLandingView()
                        }
                    }
                    }

                    if selectedSection == .costData {
                    settingsSection(L10n.Settings.sectionCostData) {
                        Text(L10n.Settings.costDataIntro)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker(L10n.Settings.keepHistory, selection: $settingsStore.settings.costData.retentionDays) {
                            ForEach(costRetentionOptions, id: \.self) { days in
                                Text(costRetentionLabel(days)).tag(days)
                            }
                        }
                        Text(L10n.Settings.keepHistoryDetail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Toggle(L10n.Settings.privacyMode, isOn: $settingsStore.settings.costData.privacyModeEnabled)
                        HStack {
                            Button {
                                environment.refreshCostUsage()
                                costDataClearStatus = nil
                            } label: {
                                Label(L10n.Settings.rescanCostLogs, systemImage: "arrow.triangle.2.circlepath")
                            }
                            .disabled(settingsStore.settings.costData.privacyModeEnabled)
                            Button(role: .destructive) {
                                environment.clearCostData()
                                costDataClearStatus = "Cost data cleared."
                            } label: {
                                Label(L10n.Settings.clearCostData, systemImage: "trash")
                            }
                        }
                        if settingsStore.settings.costData.privacyModeEnabled {
                            Text(L10n.Settings.privacyModeDetail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let costDataClearStatus {
                            Text(costDataClearStatus)
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                        Text(L10n.Settings.pricingDataDate(date: CostUsagePricing.pricingDataUpdatedAt))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .id(SettingsSectionID.costData.id)
                    }

                    if selectedSection == .pricing {
                    PricingSettingsSection(density: density)
                        .id(SettingsSectionID.pricing.id)
                    }

                    if selectedSection == .remote {
                    RemoteSettingsSection(density: density, service: environment.remoteProbeService)
                        .id(SettingsSectionID.remote.id)
                    }

                    if selectedSection == .mcp, let mcp = environment.mcp {
                    MCPSettingsSection(density: density, controller: mcp)
                        .id(SettingsSectionID.mcp.id)
                    }

                    if selectedSection == .privacy {
                    settingsSection(L10n.Settings.sectionPrivacy) {
                        Text(L10n.Settings.privacyDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .id(SettingsSectionID.privacy.id)
                    }
                        }
                        .padding(.horizontal, density.popoverPaddingH)
                        .padding(.vertical, density.popoverPaddingV)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The detail pane is native toggles, pickers, and text fields:
            // their system focus ring is the only thing telling a keyboard
            // user where they are, so the window-wide switch-off is undone
            // here. Hand-drawn regions inside (the Layout editor) switch it
            // off again for themselves.
            .vibeBarSystemControlFocus()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: refreshLaunchAtLoginState)
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        SettingsSectionCard(title: title, density: density, content: content)
    }

    private func connectionHealthRows(provider: ToolType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.Settings.connectionHealth)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(PrimaryProviderRoute.routes(for: provider)) { route in
                let health = environment.routeHealth[route]
                    ?? PrimaryProviderRouteHealth(
                        route: route,
                        status: .missing,
                        detail: L10n.Settings.notChecked
                    )
                HStack(spacing: 8) {
                    Circle()
                        .fill(healthColor(health.status))
                        .frame(width: 8, height: 8)
                    Text(route.label)
                        .font(.caption2)
                        .fontWeight(.medium)
                    Spacer(minLength: 12)
                    Text(health.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(health.checkedAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(healthColor(health.status).opacity(health.status == .ok ? 0.08 : 0.04))
                )
            }
        }
    }

    private func coreProviderSummary(
        representative: ToolType,
        healthProviders: [ToolType]
    ) -> some View {
        let routes = healthProviders.flatMap(PrimaryProviderRoute.routes(for:))
        let ready = routes.contains { route in
            environment.routeHealth[route]?.status == .ok
        }
        return HStack(spacing: 10) {
            ToolBrandIconView(tool: representative, size: 20)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(representative.statusProviderName)
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(ready ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                    Text(ready ? L10n.Settings.ready : L10n.Settings.needsSetup)
                        .font(.caption2)
                        .foregroundStyle(ready ? Color.green : Color.red)
                }
            }
            Spacer(minLength: 12)
            Toggle(L10n.Onboarding.subscriptionsShowInOverview, isOn: coreProviderVisibilityBinding(representative))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption)
        }
    }

    private func coreProviderPlanBadgeRows(for tools: [ToolType]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.Settings.planBadge)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(tools, id: \.self) { tool in
                providerBadgeRow(tool)
            }
            Text(L10n.Settings.planBadgeDetail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func sourceSummary(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
        }
        .font(.body)
    }

    private func coreProviderVisibilityBinding(_ tool: ToolType) -> Binding<Bool> {
        Binding(
            get: { settingsStore.settings.isCoreProviderVisible(tool) },
            set: { settingsStore.settings.setCoreProviderVisible($0, for: tool) }
        )
    }

    private func healthColor(_ status: PrimaryProviderRouteHealthStatus) -> Color {
        switch status {
        case .ok: return .green
        case .missing: return .secondary
        case .blocked, .failed: return .red
        }
    }

    private func menuBarOverviewEditor() -> some View {
        let kind = MenuBarItemKind.compact
        let isCustom = settingsStore.settings.menuBarItem(kind).usesComposedStrip
        return VStack(alignment: .leading, spacing: 10) {
            Toggle(L10n.Platform.macosMenuBarShowInMenuBar, isOn: menuItemVisibleBinding(kind))

            // The way back to the plain strip is the second control in the
            // section, not something to hunt for inside the composer.
            Picker("Strip", selection: menuBarStripModeBinding(kind)) {
                Text("Default").tag(false)
                Text("Custom").tag(true)
            }
            .pickerStyle(.segmented)
            Text(
                isCustom
                    ? "Switching back to Default keeps every block you built — you can return to Custom and find it exactly as you left it."
                    : "Default shows the fields you tick below. Custom lets you build the strip out of blocks: logos, words, and any quota."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            if isCustom {
                MenuBarComposerEditor(kind: kind, density: density)
            } else {
                Toggle(L10n.Platform.macosMenuBarShowTitleText, isOn: menuItemTitleBinding(kind))
                Picker(L10n.Platform.macosMenuBarLayout, selection: menuItemLayoutBinding(kind)) {
                    ForEach(MenuBarLayout.allCases) { layout in
                        Text(layout.label).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                Toggle(L10n.Platform.macosMenuBarMergeGroupWindows, isOn: menuItemMergeGroupWindowsBinding(kind))
                Text(L10n.Platform.macosMenuBarMergeGroupWindowsDetail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Picker(L10n.Platform.macosMenuBarDisplayDensity, selection: popoverDensityBinding()) {
                ForEach(PopoverDensity.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(settingsStore.settings.popoverDensity.detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Picker(L10n.Platform.macosMenuBarPercentColor, selection: menuBarColorBasisBinding()) {
                ForEach(MenuBarColorBasis.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(settingsStore.settings.menuBarColorBasis.detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if !isCustom, !MenuBarFieldCatalog.fields(for: kind).isEmpty {
                Text(L10n.Platform.macosMenuBarFields)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                menuItemFieldList(for: kind)
            }
        }
    }

    /// Default ↔ Custom. Off never destroys anything: the composed strip is
    /// kept on the item and only its `isEnabled` flag moves, so the field
    /// selection and the block arrangement coexist rather than overwriting
    /// each other. Seeding happens once, the first time Custom is chosen.
    private func menuBarStripModeBinding(_ kind: MenuBarItemKind) -> Binding<Bool> {
        Binding(
            get: { settingsStore.settings.menuBarItem(kind).usesComposedStrip },
            set: { enabled in
                var item = settingsStore.settings.menuBarItem(kind)
                item.setComposedStripEnabled(
                    enabled,
                    // Match the layout the user is looking at, so the seed
                    // starts with their spacing as well as their blocks.
                    template: .matching(item.layout),
                    registry: quotaService.fieldRegistry,
                    groupCatalogLabel: MiniWindowGroupLabelCatalog.defaultLabel(for:)
                )
                settingsStore.settings.setMenuBarItem(item)
            }
        )
    }

    private func launchAtLoginBinding() -> Binding<Bool> {
        Binding(
            get: { settingsStore.settings.launchAtLogin },
            set: { enabled in
                do {
                    try LoginItemController.setEnabled(enabled)
                    settingsStore.settings.launchAtLogin = enabled
                    launchAtLoginError = nil
                } catch {
                    launchAtLoginError = error.localizedDescription
                }
                refreshLaunchAtLoginState()
            }
        )
    }

    private func refreshLaunchAtLoginState() {
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
        launchAtLoginStatusText = LoginItemController.statusText
    }

    private func menuFieldRow(kind: MenuBarItemKind, field: MenuBarFieldOption) -> some View {
        fieldRowHorizontal(
            isOn: menuFieldSelectedBinding(kind, field.id),
            field: field,
            label: menuFieldLabelBinding(kind, field)
        )
    }

    /// Field-picker layout for a `MenuBarItemKind`. Overview lists
    /// every provider's fields, which used to render as a flat 20-row
    /// checklist with two unlabelled "5 Hours" rows and no Gemini Web
    /// section — the same readability problem the Mini Window picker
    /// already solved with L2-product section headers. Re-use that
    /// grouping for Overview; the per-tool kinds (.codex / .claude)
    /// already render a single provider, so they keep the flat list.
    @ViewBuilder
    private func menuItemFieldList(for kind: MenuBarItemKind) -> some View {
        if kind == .compact {
            MenuBarFieldsEditor(kind: kind)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(MenuBarFieldCatalog.fields(for: kind)) { field in
                    menuFieldRow(kind: kind, field: field)
                }
            }
        }
    }

    private func providerBadgeRow(_ tool: ToolType) -> some View {
        HStack(spacing: 10) {
            ToolBrandIconView(tool: tool, size: 16)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(providerBadgeTitle(for: tool))
                    .font(.system(size: 12, weight: .medium))
                Text(autoPlanLabel(for: tool))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            DebouncedSettingsTextField(
                prompt: L10n.Common.auto,
                value: providerPlanLabelBinding(tool)
            )
            .frame(width: 130)
        }
    }

    private func providerBadgeTitle(for tool: ToolType) -> String {
        tool.quotaSubProviderName()
    }

    private func fieldRowHorizontal(
        isOn: Binding<Bool>,
        field: MenuBarFieldOption,
        label: Binding<String>
    ) -> some View {
        HStack(spacing: 10) {
            fieldToggle(isOn: isOn, field: field)
            Spacer(minLength: 8)
            fieldLabelTextField(field: field, label: label)
        }
    }

    private func fieldToggle(isOn: Binding<Bool>, field: MenuBarFieldOption) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(field.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
            }
        }
        .help(field.id)
    }

    /// Label editors never write per keystroke. See
    /// `DebouncedSettingsTextField`: a settings mutation fans out to every
    /// open surface, and this page alone shows two dozen of these fields.
    private func fieldLabelTextField(field: MenuBarFieldOption, label: Binding<String>) -> some View {
        DebouncedSettingsTextField(prompt: field.displayDefaultLabel, value: label)
            .frame(width: 110)
    }

    private func menuItemVisibleBinding(_ kind: MenuBarItemKind) -> Binding<Bool> {
        Binding(
            get: { settingsStore.settings.menuBarItem(kind).isVisible },
            set: { value in
                var item = settingsStore.settings.menuBarItem(kind)
                item.isVisible = value
                settingsStore.settings.setMenuBarItem(item)
            }
        )
    }

    private func menuItemTitleBinding(_ kind: MenuBarItemKind) -> Binding<Bool> {
        Binding(
            get: { settingsStore.settings.menuBarItem(kind).showTitle },
            set: { value in
                var item = settingsStore.settings.menuBarItem(kind)
                item.showTitle = value
                settingsStore.settings.setMenuBarItem(item)
            }
        )
    }

    private func menuItemLayoutBinding(_ kind: MenuBarItemKind) -> Binding<MenuBarLayout> {
        Binding(
            get: { settingsStore.settings.menuBarItem(kind).layout },
            set: { value in
                var item = settingsStore.settings.menuBarItem(kind)
                item.layout = value
                settingsStore.settings.setMenuBarItem(item)
            }
        )
    }

    /// Opt-in group merging. Written only from this toggle — the renderer
    /// never touches it, so the menu bar's 120 ms redraw can't fan a settings
    /// write out to every subscriber.
    private func menuItemMergeGroupWindowsBinding(_ kind: MenuBarItemKind) -> Binding<Bool> {
        Binding(
            get: { settingsStore.settings.menuBarItem(kind).mergesGroupWindows },
            set: { value in
                var item = settingsStore.settings.menuBarItem(kind)
                item.mergesGroupWindows = value
                settingsStore.settings.setMenuBarItem(item)
            }
        )
    }

    private func menuBarColorBasisBinding() -> Binding<MenuBarColorBasis> {
        Binding(
            get: { settingsStore.settings.menuBarColorBasis },
            set: { settingsStore.settings.menuBarColorBasis = $0 }
        )
    }

    private func popoverDensityBinding() -> Binding<PopoverDensity> {
        Binding(
            get: { settingsStore.settings.popoverDensity },
            set: { settingsStore.settings.popoverDensity = $0 }
        )
    }

    private func menuFieldSelectedBinding(_ kind: MenuBarItemKind, _ fieldId: String) -> Binding<Bool> {
        Binding(
            get: { settingsStore.settings.menuBarItem(kind).selectedFieldIds.contains(fieldId) },
            set: { value in
                var item = settingsStore.settings.menuBarItem(kind)
                if value {
                    if !item.selectedFieldIds.contains(fieldId) {
                        item.selectedFieldIds.append(fieldId)
                    }
                } else {
                    item.selectedFieldIds.removeAll { $0 == fieldId }
                }
                settingsStore.settings.setMenuBarItem(item)
            }
        )
    }

    private func menuFieldLabelBinding(_ kind: MenuBarItemKind, _ field: MenuBarFieldOption) -> Binding<String> {
        Binding(
            get: { settingsStore.settings.menuBarItem(kind).customLabels[field.id] ?? "" },
            set: { value in
                var item = settingsStore.settings.menuBarItem(kind)
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    item.customLabels.removeValue(forKey: field.id)
                } else {
                    item.customLabels[field.id] = value
                }
                settingsStore.settings.setMenuBarItem(item)
            }
        )
    }

    private func providerPlanLabelBinding(_ tool: ToolType) -> Binding<String> {
        Binding(
            get: { settingsStore.settings.providerPlanLabels[tool] ?? "" },
            set: { value in
                settingsStore.settings.setProviderPlanLabel(value, for: tool)
            }
        )
    }

    private func autoPlanLabel(for tool: ToolType) -> String {
        let label = settingsStore.settings.planBadgeLabel(
            for: tool,
            quotaPlan: environment.quota(for: tool)?.plan,
            accountPlan: environment.account(for: tool)?.plan
        )
        return label.map { "Auto: \($0)" } ?? "Auto: hidden until detected"
    }

    private func intervalLabel(_ seconds: Int) -> String {
        switch seconds {
        case 60: return "1 minute"
        case 180: return "3 minutes"
        case 300: return "5 minutes"
        case 600: return "10 minutes"
        case 1800: return "30 minutes"
        default:
            if seconds % 60 == 0 { return "\(seconds / 60) minutes" }
            return "\(seconds)s"
        }
    }

    private func costRetentionLabel(_ days: Int) -> String {
        switch days {
        case CostDataSettings.unlimitedRetentionDays: return "Forever"
        case 30: return "30 days"
        case 90: return "90 days"
        case 365: return "1 year"
        case 365 * 3: return "3 years"
        default: return "\(days) days"
        }
    }
}

/// What is *inside* this build, as opposed to what build it is.
///
/// `agent-session-kit` is a separate public repository with its own tags and
/// its own release notes, pinned to an exact version in `Package.swift` and
/// compiled — statically — into this binary. So the version below is a fact
/// about the app you are running, and a newer kit release is not something
/// this pane can install. The wording says "ships with the next Vibe Bar
/// build" for that reason; anything that sounds like an available download
/// would be a lie.
///
/// The check is manual. Nothing here fires on launch, on a timer, or when
/// this pane appears — the button is the only thing that opens a connection,
/// and `ComponentUpdateChecker` remembers the answer for six hours so a
/// second press costs nothing.
private struct AgentSessionKitComponentRow: View {
    @State private var status: ComponentUpdateStatus?
    @State private var isChecking = false

    private let checker = ComponentUpdateChecker.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("agent-session-kit")
                    .font(.callout)
                Text(AgentSessionKitInfo.version)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                bundledBadge
                Spacer(minLength: 12)
                Button {
                    check()
                } label: {
                    Label(L10n.Settings.checkKitUpdates, systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isChecking)
            }

            Text(L10n.Settings.kitDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)

            statusLine

            HStack(spacing: 12) {
                Link(L10n.Settings.releaseNotes, destination: AgentSessionKitInfo.bundledReleaseNotesURL)
                Link(L10n.Settings.repository, destination: AgentSessionKitInfo.repositoryURL)
            }
            .font(.caption2)
        }
        .task {
            // Only ever reads what a previous button press already learned;
            // never opens a connection of its own.
            status = await checker.cachedAgentSessionKitStatus()
        }
    }

    private var bundledBadge: some View {
        Text(L10n.Settings.bundled)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    @ViewBuilder
    private var statusLine: some View {
        if isChecking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.Settings.checkingGitHub)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else if let status {
            VStack(alignment: .leading, spacing: 3) {
                Text(status.message)
                    .font(.caption2)
                    .foregroundStyle(statusColor(status))
                if let url = status.releaseNotesURL {
                    Link(L10n.Settings.whatChangedIn(version: url.lastPathComponent), destination: url)
                        .font(.caption2)
                }
            }
        } else {
            Text(L10n.Settings.notCheckedYet)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func statusColor(_ status: ComponentUpdateStatus) -> Color {
        switch status {
        case .upToDate: return .secondary
        case .updateAvailable: return .accentColor
        case .aheadOfLatestRelease: return .secondary
        case .failed: return .orange
        }
    }

    private func check() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            // Not forced: a second press inside the six-hour window reuses
            // the answer already in memory rather than asking GitHub again.
            // Six hours is far shorter than the interval at which a kit
            // release could matter here — it cannot arrive without a new
            // build of this app anyway.
            let result = await checker.checkAgentSessionKit()
            await MainActor.run {
                status = result
                isChecking = false
            }
        }
    }
}

private struct UpdateSettingsRow: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @ObservedObject var updateController: AppUpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.Settings.appVersion(version: updateController.currentVersionDescription))
                        .font(.callout)
                    Text(L10n.Settings.updateCheckDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    updateController.checkForUpdates()
                } label: {
                    Label(L10n.Settings.checkForUpdates, systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!updateController.canCheckForUpdates)
            }

            Picker(L10n.Settings.updateChannel, selection: $settingsStore.settings.updateChannel) {
                ForEach(UpdateChannel.allCases) { channel in
                    Text(channel.label).tag(channel)
                }
            }
            .pickerStyle(.segmented)

            Text(settingsStore.settings.updateChannel.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Provider-grouped slice of `MenuBarFieldCatalog.allFields` used by
/// the Mini Window field picker. Each section shows a brand icon
/// + L2 product name above its rows so a flat 20-row checklist
/// stops asking the user to remember which "5 Hours" belongs to
/// Codex and which to Claude.
struct MiniWindowFieldProviderSection: Identifiable {
    let tool: ToolType
    let title: String
    let fields: [MenuBarFieldOption]

    var id: String { title }

    static let all: [MiniWindowFieldProviderSection] = [
        .init(tool: .codex,       title: ToolType.codex.productName,       fields: MenuBarFieldCatalog.codexFields),
        .init(tool: .claude,      title: ToolType.claude.productName,      fields: MenuBarFieldCatalog.claudeFields),
        .init(tool: .gemini,      title: ToolType.gemini.productName, fields: MenuBarFieldCatalog.geminiFields),
        .init(tool: .antigravity, title: ToolType.antigravity.toolName,    fields: MenuBarFieldCatalog.antigravityFields),
        .init(tool: .grok,        title: ToolType.grok.toolName,           fields: MenuBarFieldCatalog.grokFields),
        .init(tool: .cursor,      title: ToolType.cursor.toolName,         fields: MenuBarFieldCatalog.cursorFields),
        // Grok Bot shares Cursor's adapter and brand icon but is a separate
        // L2 SubProvider, so it gets its own header rather than an unexplained
        // third row under Cursor. Sectioning is keyed by title, not by tool,
        // because two sections legitimately share `.cursor`.
        .init(
            tool: .cursor,
            title: ToolType.cursor.quotaSubProviderName(bucketID: "grok_bot_weekly"),
            fields: MenuBarFieldCatalog.grokBotFields
        )
    ]
}
