import SwiftUI
import VibeBarCore

struct SettingsView: View {
    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore
    var dismiss: () -> Void

    private let intervalOptions: [Int] = [60, 180, 300, 600, 1800]
    @State private var claudeCookieDeleteFailed: Bool = false

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

            Form {
                // ───── General ─────
                Section("General") {
                    Picker("Percent shows", selection: $settingsStore.settings.displayMode) {
                        ForEach(DisplayMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Use mock data (offline demo)", isOn: $settingsStore.settings.mockEnabled)
                    Picker("Refresh every", selection: $settingsStore.settings.refreshIntervalSeconds) {
                        ForEach(intervalOptions, id: \.self) { secs in
                            Text(intervalLabel(secs)).tag(secs)
                        }
                    }
                }

                // ───── Menu Bar Items ─────
                Section("Menu Bar Items") {
                    ForEach(MenuBarItemKind.allCases) { kind in
                        DisclosureGroup {
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
                                Text("Fields shown when title text is on:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(MenuBarFieldCatalog.fields(for: kind)) { field in
                                        menuFieldRow(kind: kind, field: field)
                                    }
                                }
                            }
                        } label: {
                            Label(kind.label, systemImage: menuItemIcon(kind))
                        }
                    }
                }

                // ───── Mini Window ─────
                Section("Mini Window") {
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

                // ───── Accounts ─────
                Section("Claude account") {
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

                // ───── System ─────
                Section("System") {
                    Toggle("Launch at login", isOn: $settingsStore.settings.launchAtLogin)
                    Text("Preference only — register with launchd via System Settings → Login Items.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Section("Cost data") {
                    Text("Cost is computed from local CLI session JSONL logs at ~/.codex/sessions and ~/.claude/projects. Web/desktop usage is not tracked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Pricing data: \(CostUsagePricing.pricingDataUpdatedAt)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Section("Privacy") {
                    Text("Tokens are read from local CLI credentials. Settings, quota cache, and Claude Web cookies are stored under ~/.vibebar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .padding(20)
        .frame(width: 600, height: 740)
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
                Text(field.id)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
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

    private func menuItemIcon(_ kind: MenuBarItemKind) -> String {
        switch kind {
        case .compact: return "rectangle.compress.vertical"
        case .codex:   return "terminal"
        case .claude:  return "sparkles"
        case .status:  return "dot.radiowaves.left.and.right"
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
