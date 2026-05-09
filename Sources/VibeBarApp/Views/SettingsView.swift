import SwiftUI
import VibeBarCore

struct SettingsView: View {
    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore
    var dismiss: () -> Void

    private let intervalOptions: [Int] = [60, 180, 300, 600, 1800]
    private let costRetentionOptions = CostDataSettings.retentionOptions
    @State private var openAICookieDeleteFailed: Bool = false
    @State private var claudeCookieDeleteFailed: Bool = false
    @State private var costDataClearStatus: String?
    @State private var launchAtLoginStatusText: String = LoginItemController.statusText
    @State private var launchAtLoginError: String?
    @State private var keychainPassword: String = ""
    @State private var isAuthorizingKeychain: Bool = false
    @State private var keychainAuthorizationStatus: String?
    @State private var keychainAuthorizationSucceeded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 12)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    settingsSection("General") {
                        Picker("Percent shows", selection: $settingsStore.settings.displayMode) {
                            ForEach(DisplayMode.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Picker("Refresh every", selection: $settingsStore.settings.refreshIntervalSeconds) {
                            ForEach(intervalOptions, id: \.self) { secs in
                                Text(intervalLabel(secs)).tag(secs)
                            }
                        }
                    }

                    settingsSection("Provider Badges") {
                        Text("Leave a badge blank to use the detected account plan.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 8) {
                            // Plan badges only meaningful for primary
                            // providers (Codex, Claude). Misc providers
                            // expose their plan inline on the misc card.
                            ForEach(ToolType.primaryProviders, id: \.self) { tool in
                                providerBadgeRow(tool)
                            }
                        }
                    }

                    settingsSection("Menu Bar Items") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(MenuBarItemKind.allCases) { kind in
                                menuBarItemEditor(kind)
                            }
                        }
                    }

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
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(MenuBarFieldCatalog.allFields) { field in
                                miniFieldRow(field)
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

                    settingsSection("OpenAI Account") {
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
                            Label("Check connections", systemImage: "checkmark.circle")
                        }
                    }

                    settingsSection("Claude Account") {
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
                            Label("Check connections", systemImage: "checkmark.circle")
                        }
                    }

                    settingsSection("Misc Providers") {
                        Text("Usage-only integrations. Each provider stays in setup mode until a credential is configured below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(ToolType.miscProviders, id: \.self) { tool in
                                MiscProviderSettingsSection(tool: tool)
                            }
                        }
                    }

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

                    settingsSection("Cost Data") {
                        Text("Cost is computed from local CLI session JSONL logs at ~/.codex/sessions and ~/.claude/projects. Web/desktop usage is not tracked.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Keep history", selection: $settingsStore.settings.costData.retentionDays) {
                            ForEach(costRetentionOptions, id: \.self) { days in
                                Text(costRetentionLabel(days)).tag(days)
                            }
                        }
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

                    settingsSection("Keychain Access") {
                        keychainAuthorizationControls
                    }

                    settingsSection("Privacy") {
                        Text("Tokens are read from local CLI credentials. Saved OpenAI and Claude Web cookies are stored in macOS Keychain, split by browser and WebView source. Legacy plaintext cookie files under ~/.vibebar/cookies are migrated once and deleted. Settings, quota cache, and cost summaries stay under ~/.vibebar.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 560, idealHeight: 720)
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
            }
        }
    }

    private var keychainAuthorizationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("If macOS repeatedly asks for Vibe Bar's Keychain items after a rebuild, enter the login keychain password once to re-authorize Vibe Bar-owned cookies and misc-provider secrets. The password is used only for this operation.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                SecureField("Login keychain password", text: $keychainPassword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(authorizeKeychainAccess)
                    .disabled(isAuthorizingKeychain)
                Button {
                    authorizeKeychainAccess()
                } label: {
                    Label(
                        isAuthorizingKeychain ? "Authorizing..." : "Authorize",
                        systemImage: "key.fill"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(keychainPassword.isEmpty || isAuthorizingKeychain)
            }
            if let keychainAuthorizationStatus {
                Text(keychainAuthorizationStatus)
                    .font(.caption2)
                    .foregroundStyle(keychainAuthorizationSucceeded ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func healthColor(_ status: PrimaryProviderRouteHealthStatus) -> Color {
        switch status {
        case .ok: return .green
        case .missing: return .red
        case .blocked, .failed: return .orange
        }
    }

    private func menuBarItemEditor(_ kind: MenuBarItemKind) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Show in menu bar", isOn: menuItemVisibleBinding(kind))
                Toggle("Show title text", isOn: menuItemTitleBinding(kind))
                Picker("Layout", selection: menuItemLayoutBinding(kind)) {
                    ForEach(MenuBarLayout.allCases) { layout in
                        Text(layout.label).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Popover density", selection: popoverDensityBinding(kind)) {
                    ForEach(PopoverDensity.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(settingsStore.settings.popoverDensity(for: kind).detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if !MenuBarFieldCatalog.fields(for: kind).isEmpty {
                    Text("Fields")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(MenuBarFieldCatalog.fields(for: kind)) { field in
                            menuFieldRow(kind: kind, field: field)
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                if settingsStore.settings.menuBarItem(kind).layout.showsMenuBarIcon {
                    ProviderBrandIconView(kind: kind, size: 16)
                }
                Text(kind.label)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Text(settingsStore.settings.menuBarItem(kind).layout.label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }

    private func launchAtLoginBinding() -> Binding<Bool> {
        Binding(
            get: { settingsStore.settings.launchAtLogin },
            set: { enabled in
                do {
                    try LoginItemController.setEnabled(enabled)
                    launchAtLoginError = nil
                } catch {
                    launchAtLoginError = error.localizedDescription
                }
                refreshLaunchAtLoginState()
            }
        )
    }

    private func refreshLaunchAtLoginState() {
        settingsStore.settings.launchAtLogin = LoginItemController.isEnabled
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

    private func providerBadgeRow(_ tool: ToolType) -> some View {
        HStack(spacing: 10) {
            ToolBrandIconView(tool: tool, size: 16)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.menuTitle)
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

    private func popoverDensityBinding(_ kind: MenuBarItemKind) -> Binding<PopoverDensity> {
        Binding(
            get: { settingsStore.settings.popoverDensity(for: kind) },
            set: { value in
                settingsStore.settings.setPopoverDensity(value, for: kind)
            }
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

    private func authorizeKeychainAccess() {
        guard !isAuthorizingKeychain, !keychainPassword.isEmpty else { return }
        let password = keychainPassword
        keychainPassword = ""
        keychainAuthorizationSucceeded = false
        keychainAuthorizationStatus = "Authorizing Keychain access..."
        isAuthorizingKeychain = true

        Task.detached {
            do {
                let report = try VibeBarKeychainAccessAuthorizer.authorizeExistingOwnedItems(
                    loginKeychainPassword: password
                )
                await MainActor.run {
                    isAuthorizingKeychain = false
                    keychainAuthorizationSucceeded = report.failureCount == 0
                    keychainAuthorizationStatus = keychainAuthorizationMessage(for: report)
                }
            } catch {
                await MainActor.run {
                    isAuthorizingKeychain = false
                    keychainAuthorizationSucceeded = false
                    keychainAuthorizationStatus = keychainAuthorizationFailureMessage(error)
                }
            }
        }
    }

    private func keychainAuthorizationMessage(
        for report: VibeBarKeychainAccessAuthorizer.Report
    ) -> String {
        if report.failureCount == 0 {
            return "Authorized \(report.authorizedCount) existing Keychain item(s). \(report.missingCount) item(s) have not been created yet."
        }
        let firstStatus = report.failures.first.map { String($0.status) } ?? "unknown"
        return "Partially authorized \(report.authorizedCount) item(s); \(report.failureCount) failed with OSStatus \(firstStatus)."
    }

    private func keychainAuthorizationFailureMessage(_ error: Error) -> String {
        if let authError = error as? VibeBarKeychainAccessAuthorizer.AuthorizationError {
            switch authError {
            case .emptyPassword:
                return "Enter the login keychain password first."
            case .unlockFailed(let status):
                return "Could not unlock the login keychain. OSStatus \(status)."
            case .trustedApplicationFailed(let status):
                return "Could not identify the current Vibe Bar app for Keychain access. OSStatus \(status)."
            case .accessCreateFailed(let status):
                return "Could not create the Keychain access rule. OSStatus \(status)."
            }
        }
        return "Could not authorize Keychain access: \(error)"
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
