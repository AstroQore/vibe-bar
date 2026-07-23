import SwiftUI
import VibeBarCore

enum SettingsSectionID: String {
    case menuBar
    case miniWindow
    case openAI
    case anthropic
    case googleAI
    case xAI
    case miscProviders
    case system
    case costData
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .menuBar: "Menu Bar"
        case .miniWindow: "Mini Window"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .googleAI: "Google AI"
        case .xAI: "xAI"
        case .miscProviders: "Misc Providers"
        case .system: "System"
        case .costData: "Cost Data"
        case .privacy: "Privacy"
        }
    }

    var systemImage: String {
        switch self {
        case .menuBar: "menubar.rectangle"
        case .miniWindow: "rectangle.on.rectangle"
        case .openAI: "brain.head.profile"
        case .anthropic: "sparkles"
        case .googleAI: "diamond"
        case .xAI: "circle.hexagongrid"
        case .miscProviders: "square.grid.2x2"
        case .system: "desktopcomputer"
        case .costData: "chart.bar.xaxis"
        case .privacy: "hand.raised.fill"
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
            case .grok: return "xAI"
            default: return tool.vendorName
            }
        case let .miscProvider(id):
            guard let instance = settings.miscProviderInstance(id: id) else { return "Misc Provider" }
            return instance.displayTitle(fallback: instance.tool.menuTitle)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore
    var dismiss: () -> Void

    private let intervalOptions: [Int] = [60, 180, 300, 600, 1800]
    private let popoverRefreshCooldownOptions: [Int] = [60, 120, 300, 600]
    private let costRetentionOptions = CostDataSettings.retentionOptions
    @State private var openAICookieDeleteFailed: Bool = false
    @State private var claudeCookieDeleteFailed: Bool = false
    @State private var geminiCookieDeleteFailed: Bool = false
    @State private var grokCookieDeleteFailed: Bool = false
    @State private var costDataClearStatus: String?
    @State private var launchAtLoginStatusText: String = LoginItemController.statusText
    @State private var launchAtLoginError: String?
    @State private var selectedDestination: SettingsDestination = .page(.system)

    private var selectedSection: SettingsSectionID {
        selectedDestination.sectionID
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebarView(selection: $selectedDestination)

            VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(selectedDestination.title(settings: settingsStore.settings))
                            .font(.system(size: 20, weight: .semibold))
                        Spacer()
                        BorderlessIconButton(
                            systemImage: "xmark.circle.fill",
                            help: "Close Settings",
                            size: 15,
                            action: dismiss
                        )
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)

                    Divider()

                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 18) {
                    if selectedSection == .system {
                    settingsSection("System") {
                        Toggle("Launch at login", isOn: launchAtLoginBinding())
                        Text(launchAtLoginStatusText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let launchAtLoginError {
                            Text(launchAtLoginError)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .id(SettingsSectionID.system.rawValue)

                    settingsSection("Refreshing") {
                        Picker("Percent shows", selection: $settingsStore.settings.displayMode) {
                            ForEach(DisplayMode.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Picker("Refresh every", selection: $settingsStore.settings.refreshIntervalSeconds) {
                            ForEach(intervalOptions, id: \.self) { secs in
                                Text(intervalLabel(secs)).tag(secs)
                            }
                        }
                        Toggle(
                            "Refresh when the popover opens",
                            isOn: $settingsStore.settings.refreshOnPopoverOpen
                        )
                        if settingsStore.settings.refreshOnPopoverOpen {
                            Picker(
                                "Minimum open-refresh cooldown",
                                selection: $settingsStore.settings.popoverOpenRefreshCooldownSeconds
                            ) {
                                ForEach(popoverRefreshCooldownOptions, id: \.self) { secs in
                                    Text(intervalLabel(secs)).tag(secs)
                                }
                            }
                            Text("Opening the popover refreshes all visible providers at most once per cooldown period.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .id("refreshing")

                    settingsSection("Updates") {
                        UpdateSettingsRow(updateController: environment.updateController)
                    }
                    .id("updates")
                    }

                    if selectedSection == .menuBar {
                    settingsSection("Overview") {
                        menuBarOverviewEditor()
                    }
                    .id(SettingsSectionID.menuBar.rawValue)
                    }

                    if selectedSection == .miniWindow {
                    settingsSection("Mini Window") {
                        Picker("Display mode", selection: miniWindowDisplayModeBinding()) {
                            ForEach(MiniWindowDisplayMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text("Pick which fields appear in the selected mini mode.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // The flat `allFields` list had two "5 Hours" rows
                        // and two "Weekly" rows (one for Codex, one for
                        // Claude) with no provider context — easy to
                        // mis-tick. Group by L2 product so each row sits
                        // under the brand it belongs to.
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(MiniWindowFieldProviderSection.all, id: \.tool) { section in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 6) {
                                        ToolBrandIconView(tool: section.tool, size: 13)
                                            .opacity(0.85)
                                        Text(section.title)
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(.secondary)
                                            .textCase(.uppercase)
                                            .tracking(0.4)
                                    }
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(section.fields) { field in
                                            miniFieldRow(field)
                                        }
                                    }
                                }
                            }
                        }
                        Divider()
                            .padding(.vertical, 2)
                        Text("Branch group names:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(MiniWindowGroupLabelCatalog.all) { option in
                                miniGroupLabelRow(option)
                            }
                        }
                    }
                    .id(SettingsSectionID.miniWindow.rawValue)
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
                        Picker("Usage source", selection: $settingsStore.settings.codexUsageMode) {
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
                                Label("Import from browser", systemImage: "safari")
                            }
                            .disabled(environment.isImportingOpenAIBrowserCookies)
                            Button {
                                environment.openOpenAIWebLogin()
                            } label: {
                                Label("Open WebView login", systemImage: "person.crop.circle.badge.key")
                            }
                            Button(role: .destructive) {
                                openAICookieDeleteFailed = !environment.deleteOpenAIWebCookies()
                            } label: {
                                Label("Delete cookies", systemImage: "trash")
                            }
                            .disabled(!environment.hasOpenAIWebCookies)
                        }
                        if environment.hasOpenAIWebCookies {
                            Text("Cookies saved.")
                                .font(.caption2).foregroundStyle(.green)
                        }
                        if let status = environment.openAIBrowserCookieImportStatus {
                            Text(status)
                                .font(.caption2)
                                .foregroundStyle(status.hasPrefix("Imported") ? .green : .secondary)
                        }
                        if openAICookieDeleteFailed {
                            Text("Could not delete saved cookies.")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        Divider()
                            .padding(.vertical, 2)
                        connectionHealthRows(provider: .codex)
                        Button {
                            environment.recheckPrimaryRouteHealth(provider: .codex)
                        } label: {
                            Label("Check OpenAI connections", systemImage: "checkmark.circle")
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
                        Picker("Usage source", selection: $settingsStore.settings.claudeUsageMode) {
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
                                Label("Import from browser", systemImage: "safari")
                            }
                            .disabled(environment.isImportingClaudeBrowserCookies)
                            Button {
                                environment.openClaudeWebLogin()
                            } label: {
                                Label("Open WebView login", systemImage: "person.crop.circle.badge.key")
                            }
                            Button(role: .destructive) {
                                claudeCookieDeleteFailed = !environment.deleteClaudeWebCookies()
                            } label: {
                                Label("Delete cookies", systemImage: "trash")
                            }
                            .disabled(!environment.hasClaudeWebCookies)
                        }
                        if environment.hasClaudeWebCookies {
                            Text("Cookies saved.")
                                .font(.caption2).foregroundStyle(.green)
                        }
                        if let status = environment.claudeBrowserCookieImportStatus {
                            Text(status)
                                .font(.caption2)
                                .foregroundStyle(status.hasPrefix("Imported") ? .green : .secondary)
                        }
                        if claudeCookieDeleteFailed {
                            Text("Could not delete saved cookies.")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        Divider()
                            .padding(.vertical, 2)
                        connectionHealthRows(provider: .claude)
                        Button {
                            environment.recheckPrimaryRouteHealth(provider: .claude)
                        } label: {
                            Label("Check Anthropic connections", systemImage: "checkmark.circle")
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
                        Text("Gemini and Antigravity share the same Google AI subscription quota. Cookie import is the only supported web path — there is no WebView login.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        sourceSummary(label: "Gemini source", value: "Web quota")
                        Text(GeminiUsageMode.webOnly.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button {
                                environment.importGeminiBrowserCookies()
                            } label: {
                                Label("Import Gemini cookies from browser", systemImage: "safari")
                            }
                            .disabled(environment.isImportingGeminiBrowserCookies)
                            Button(role: .destructive) {
                                geminiCookieDeleteFailed = !environment.deleteGeminiWebCookies()
                            } label: {
                                Label("Delete Gemini cookies", systemImage: "trash")
                            }
                            .disabled(!environment.hasGeminiWebCookies)
                        }
                        if environment.hasGeminiWebCookies {
                            Text("Gemini cookies saved.")
                                .font(.caption2).foregroundStyle(.green)
                        }
                        if let status = environment.geminiBrowserCookieImportStatus {
                            Text(status)
                                .font(.caption2)
                                .foregroundStyle(status.hasPrefix("Imported") ? .green : .secondary)
                        }
                        if geminiCookieDeleteFailed {
                            Text("Could not delete saved Gemini cookies.")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        Divider()
                            .padding(.vertical, 2)
                        connectionHealthRows(provider: .gemini)

                        Divider()
                            .padding(.vertical, 2)

                        Picker("Antigravity source", selection: $settingsStore.settings.antigravityUsageMode) {
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
                            Text("Antigravity cookie import is enabled — sign in at antigravity.google first.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Antigravity reads the locally running language server. Cookie import is deferred until the Antigravity Cloud endpoint ships.")
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
                            Label("Check Google AI connections", systemImage: "checkmark.circle")
                        }
                    }
                    .id(SettingsSectionID.googleAI.id)
                    }

                    if selectedSection == .xAI {
                    settingsSection("xAI") {
                        coreProviderSummary(
                            representative: .grok,
                            healthProviders: [.grok]
                        )
                        coreProviderPlanBadgeRows(for: [.grok])
                        Divider()
                            .padding(.vertical, 2)
                        Text("Vibe Bar can read Grok usage from `~/.grok/auth.json` (preferred — written by `grok login`) or from a signed-in grok.com browser session. Either source is enough.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        sourceSummary(label: "Usage source", value: "Auto")

                        if GrokCredentialsStore.hasCredentials() {
                            Label("~/.grok/auth.json detected", systemImage: "checkmark.circle")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        } else {
                            Label("No ~/.grok/auth.json yet — run `grok login` to authenticate, or import cookies below.",
                                  systemImage: "exclamationmark.circle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Button {
                                environment.importGrokBrowserCookies()
                            } label: {
                                Label("Import Grok cookies from browser", systemImage: "safari")
                            }
                            .disabled(environment.isImportingGrokBrowserCookies)
                            Button(role: .destructive) {
                                grokCookieDeleteFailed = !environment.deleteGrokWebCookies()
                            } label: {
                                Label("Delete Grok cookies", systemImage: "trash")
                            }
                            .disabled(!environment.hasGrokWebCookies)
                        }
                        if environment.hasGrokWebCookies {
                            Text("Grok cookies saved.")
                                .font(.caption2).foregroundStyle(.green)
                        }
                        if let status = environment.grokBrowserCookieImportStatus {
                            Text(status)
                                .font(.caption2)
                                .foregroundStyle(status.hasPrefix("Imported") ? .green : .secondary)
                        }
                        if grokCookieDeleteFailed {
                            Text("Could not delete saved Grok cookies.")
                                .font(.caption2).foregroundStyle(.orange)
                        }

                        Divider()
                            .padding(.vertical, 2)
                        connectionHealthRows(provider: .grok)
                        Button {
                            environment.recheckPrimaryRouteHealth(provider: .grok)
                        } label: {
                            Label("Check xAI connections", systemImage: "checkmark.circle")
                        }

                        Link("Open xAI status page",
                             destination: ToolType.grok.statusPageURL)
                            .font(.caption2)
                    }
                    .id(SettingsSectionID.xAI.id)
                    }

                    if selectedSection == .miscProviders {
                    if case let .miscProvider(instanceID) = selectedDestination,
                       let instance = settingsStore.settings.miscProviderInstance(id: instanceID) {
                        MiscProviderSettingsSection(instance: instance)
                    } else {
                        settingsSection("Misc Provider") {
                            Text("Select a provider from the sidebar. Hidden providers keep their saved setup and credentials.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    }

                    if selectedSection == .costData {
                    settingsSection("Cost Data") {
                        Text("Cost is computed from local CLI session JSONL logs at ~/.codex/sessions and ~/.claude/projects. Web/desktop usage is not tracked.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Keep history", selection: $settingsStore.settings.costData.retentionDays) {
                            ForEach(costRetentionOptions, id: \.self) { days in
                                Text(costRetentionLabel(days)).tag(days)
                            }
                        }
                        Text("Applies to cost history and subscription fill history.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Toggle("Privacy mode", isOn: $settingsStore.settings.costData.privacyModeEnabled)
                        HStack {
                            Button {
                                environment.refreshCostUsage()
                                costDataClearStatus = nil
                            } label: {
                                Label("Rescan cost logs", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .disabled(settingsStore.settings.costData.privacyModeEnabled)
                            Button(role: .destructive) {
                                environment.clearCostData()
                                costDataClearStatus = "Cost data cleared."
                            } label: {
                                Label("Clear cost data", systemImage: "trash")
                            }
                        }
                        if settingsStore.settings.costData.privacyModeEnabled {
                            Text("Privacy mode keeps cost data off disk and clears local cost history, snapshots, and scan cache.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let costDataClearStatus {
                            Text(costDataClearStatus)
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                        Text("Pricing data: \(CostUsagePricing.pricingDataUpdatedAt)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .id(SettingsSectionID.costData.id)
                    }

                    if selectedSection == .privacy {
                    settingsSection("Privacy") {
                        Text("Tokens are read from local CLI credentials. Saved OpenAI and Claude Web cookies are stored in macOS Keychain, split by browser and WebView source. Legacy plaintext cookie files under ~/.vibebar/cookies are migrated once and deleted. Settings, quota cache, and cost summaries stay under ~/.vibebar.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .id(SettingsSectionID.privacy.id)
                    }
                        }
                        .padding(22)
                    }
            }
        }
        .frame(minWidth: 820, idealWidth: 980, minHeight: 600, idealHeight: 760)
        .onAppear(perform: refreshLaunchAtLoginState)
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.6)
            )
        }
    }

    private func connectionHealthRows(provider: ToolType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connection health")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(PrimaryProviderRoute.routes(for: provider)) { route in
                let health = environment.routeHealth[route]
                    ?? PrimaryProviderRouteHealth(
                        route: route,
                        status: .missing,
                        detail: "Not checked"
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
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.72))
                .frame(width: 1)
                .offset(x: SettingsSidebarView.width)
                .ignoresSafeArea(.container, edges: .vertical)
                .allowsHitTesting(false)
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
                    Text(ready ? "Ready" : "Needs setup")
                        .font(.caption2)
                        .foregroundStyle(ready ? Color.green : Color.red)
                }
            }
            Spacer(minLength: 12)
            Toggle("Show in Overview", isOn: coreProviderVisibilityBinding(representative))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption)
        }
    }

    private func coreProviderPlanBadgeRows(for tools: [ToolType]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Plan badge")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(tools, id: \.self) { tool in
                providerBadgeRow(tool)
            }
            Text("Leave blank to use the detected account plan.")
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
        return VStack(alignment: .leading, spacing: 10) {
            Toggle("Show in menu bar", isOn: menuItemVisibleBinding(kind))
            Toggle("Show title text", isOn: menuItemTitleBinding(kind))
            Picker("Layout", selection: menuItemLayoutBinding(kind)) {
                ForEach(MenuBarLayout.allCases) { layout in
                    Text(layout.label).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            Picker("Display density", selection: popoverDensityBinding()) {
                ForEach(PopoverDensity.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(settingsStore.settings.popoverDensity.detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if !MenuBarFieldCatalog.fields(for: kind).isEmpty {
                Text("Fields")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                menuItemFieldList(for: kind)
            }
        }
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

    private func miniFieldRow(_ field: MenuBarFieldOption) -> some View {
        ViewThatFits(in: .horizontal) {
            fieldRowHorizontal(
                isOn: miniFieldSelectedBinding(field.id),
                field: field,
                label: miniFieldLabelBinding(field)
            )
            fieldRowWrapped(
                isOn: miniFieldSelectedBinding(field.id),
                field: field,
                label: miniFieldLabelBinding(field)
            )
        }
    }

    private func miniGroupLabelRow(_ option: MiniWindowGroupLabelOption) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                groupLabelText(option)
                Spacer(minLength: 8)
                TextField(option.defaultLabel, text: miniGroupLabelBinding(option))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
            }
            VStack(alignment: .leading, spacing: 6) {
                groupLabelText(option)
                TextField(option.defaultLabel, text: miniGroupLabelBinding(option))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180, alignment: .leading)
            }
        }
    }

    private func menuFieldRow(kind: MenuBarItemKind, field: MenuBarFieldOption) -> some View {
        ViewThatFits(in: .horizontal) {
            fieldRowHorizontal(
                isOn: menuFieldSelectedBinding(kind, field.id),
                field: field,
                label: menuFieldLabelBinding(kind, field)
            )
            fieldRowWrapped(
                isOn: menuFieldSelectedBinding(kind, field.id),
                field: field,
                label: menuFieldLabelBinding(kind, field)
            )
        }
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
            VStack(alignment: .leading, spacing: 12) {
                ForEach(MiniWindowFieldProviderSection.all, id: \.tool) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            ToolBrandIconView(tool: section.tool, size: 13)
                                .opacity(0.85)
                            Text(section.title)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .tracking(0.4)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(section.fields) { field in
                                menuFieldRow(kind: kind, field: field)
                            }
                        }
                    }
                }
            }
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
            TextField("Auto", text: providerPlanLabelBinding(tool))
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
        }
    }

    private func providerBadgeTitle(for tool: ToolType) -> String {
        switch tool {
        case .codex: return "ChatGPT"
        case .claude: return "Claude"
        case .gemini: return "Gemini Web"
        case .antigravity: return "AntiGravity"
        case .grok: return "Grok"
        default: return tool.menuTitle
        }
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

    private func fieldRowWrapped(
        isOn: Binding<Bool>,
        field: MenuBarFieldOption,
        label: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldToggle(isOn: isOn, field: field)
            fieldLabelTextField(field: field, label: label)
                .frame(maxWidth: 180, alignment: .leading)
        }
    }

    private func fieldToggle(isOn: Binding<Bool>, field: MenuBarFieldOption) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(field.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
            }
        }
        .help(field.id)
    }

    private func fieldLabelTextField(field: MenuBarFieldOption, label: Binding<String>) -> some View {
        TextField(field.defaultLabel, text: label)
            .textFieldStyle(.roundedBorder)
            .frame(width: 110)
    }

    private func groupLabelText(_ option: MiniWindowGroupLabelOption) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(option.title)
                .font(.system(size: 12, weight: .medium))
            Text(option.id)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
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

    private func miniFieldSelectedBinding(_ fieldId: String) -> Binding<Bool> {
        Binding(
            get: {
                let mini = settingsStore.settings.miniWindow
                return mini.fieldIds(for: mini.displayMode).contains(fieldId)
            },
            set: { value in
                var mini = settingsStore.settings.miniWindow
                var ids = mini.fieldIds(for: mini.displayMode)
                if value {
                    if !ids.contains(fieldId) {
                        ids.append(fieldId)
                    }
                } else {
                    ids.removeAll { $0 == fieldId }
                }
                mini.setFieldIds(ids, for: mini.displayMode)
                settingsStore.settings.miniWindow = mini
            }
        )
    }

    private func miniWindowDisplayModeBinding() -> Binding<MiniWindowDisplayMode> {
        Binding(
            get: { settingsStore.settings.miniWindow.displayMode },
            set: { value in
                var mini = settingsStore.settings.miniWindow
                mini.displayMode = value
                settingsStore.settings.miniWindow = mini
            }
        )
    }

    private func miniFieldLabelBinding(_ field: MenuBarFieldOption) -> Binding<String> {
        Binding(
            get: { settingsStore.settings.miniWindow.customLabels[field.id] ?? "" },
            set: { value in
                var mini = settingsStore.settings.miniWindow
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    mini.customLabels.removeValue(forKey: field.id)
                } else {
                    mini.customLabels[field.id] = value
                }
                settingsStore.settings.miniWindow = mini
            }
        )
    }

    private func miniGroupLabelBinding(_ option: MiniWindowGroupLabelOption) -> Binding<String> {
        Binding(
            get: { settingsStore.settings.miniWindow.groupLabels[option.id] ?? "" },
            set: { value in
                var mini = settingsStore.settings.miniWindow
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    mini.groupLabels.removeValue(forKey: option.id)
                } else {
                    mini.groupLabels[option.id] = value
                }
                settingsStore.settings.miniWindow = mini
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

private struct UpdateSettingsRow: View {
    @ObservedObject var updateController: AppUpdateController

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Vibe Bar \(updateController.currentVersionDescription)")
                    .font(.callout)
                Text("Checks GitHub Releases once a day and asks before installing.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                updateController.checkForUpdates()
            } label: {
                Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!updateController.canCheckForUpdates)
        }
    }
}

/// Provider-grouped slice of `MenuBarFieldCatalog.allFields` used by
/// the Mini Window field picker. Each section shows a brand icon
/// + L2 product name above its rows so a flat 20-row checklist
/// stops asking the user to remember which "5 Hours" belongs to
/// Codex and which to Claude.
private struct MiniWindowFieldProviderSection {
    let tool: ToolType
    let title: String
    let fields: [MenuBarFieldOption]

    static let all: [MiniWindowFieldProviderSection] = [
        .init(tool: .codex,       title: ToolType.codex.productName,       fields: MenuBarFieldCatalog.codexFields),
        .init(tool: .claude,      title: ToolType.claude.productName,      fields: MenuBarFieldCatalog.claudeFields),
        .init(tool: .gemini,      title: ToolType.gemini.productName + " Web", fields: MenuBarFieldCatalog.geminiFields),
        .init(tool: .antigravity, title: ToolType.antigravity.toolName,    fields: MenuBarFieldCatalog.antigravityFields),
        .init(tool: .grok,        title: ToolType.grok.productName,        fields: MenuBarFieldCatalog.grokFields)
    ]
}
