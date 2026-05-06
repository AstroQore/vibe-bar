import SwiftUI
import VibeBarCore

struct SettingsView: View {
    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore
    var dismiss: () -> Void

    private let intervalOptions: [Int] = [60, 180, 300, 600, 1800]
    @State private var claudeCookieDeleteFailed: Bool = false
    @State private var launchAtLoginStatusText: String = LoginItemController.statusText
    @State private var launchAtLoginError: String?

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
                            ForEach(ToolType.allCases, id: \.self) { tool in
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
                                environment.openClaudeWebLogin()
                            } label: {
                                Label("Open claude.ai login", systemImage: "person.crop.circle.badge.key")
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
                        if claudeCookieDeleteFailed {
                            Text("Could not delete saved cookies.")
                                .font(.caption2).foregroundStyle(.orange)
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
                        Button {
                            environment.refreshCostUsage()
                        } label: {
                            Label("Rescan cost logs", systemImage: "arrow.triangle.2.circlepath")
                        }
                        Text("Pricing data: \(CostUsagePricing.pricingDataUpdatedAt)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    settingsSection("Privacy") {
                        Text("Tokens are read from local CLI credentials. Claude Web cookies are stored in Keychain. Settings, quota cache, and cost summaries are stored under ~/.vibebar.")
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
                    ProviderBrandIconView(kind: kind, size: 15)
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
            ProviderBrandIconView(kind: menuBarKind(for: tool), size: 14)
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

    private func menuBarKind(for tool: ToolType) -> MenuBarItemKind {
        switch tool {
        case .codex:  return .codex
        case .claude: return .claude
        }
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
}
