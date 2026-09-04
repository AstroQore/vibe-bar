import SwiftUI
import VibeBarCore

/// The menu bar's field editor, aligned with the mini windows' unified tree:
/// what's shown is one ordered list grouped by the quota hierarchy with
/// inline renaming, what isn't is a candidate list underneath — including
/// runtime-discovered buckets, which the old static checklist never offered
/// the menu bar at all.
struct MenuBarFieldsEditor: View {
    let kind: MenuBarItemKind

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var quotaService: QuotaService

    // Rebuilt when the registry or quota data changes, never per body pass —
    // every settings publication re-renders this editor, and the merge plus
    // per-field bucket lookups are O(fields · buckets). Same discipline as
    // the mini-window editor next door.
    @State private var mergedOptionsById: [String: MenuBarFieldOption] = [:]
    @State private var liveIds: Set<String> = []

    private func rebuildCaches() {
        mergedOptionsById = Dictionary(
            MenuBarFieldCatalog.mergedFields(registry: quotaService.fieldRegistry).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        liveIds = liveFieldIds(merged: mergedOptionsById)
    }

    var body: some View {
        let merged = mergedOptionsById
        let live = liveIds
        let item = settingsStore.settings.menuBarItem(kind)
        let shown = item.selectedFieldIds.compactMap { merged[$0] }
        VStack(alignment: .leading, spacing: 10) {
            Text("Shown, in this order — first renders leftmost. Rename any field for the menu bar only; empty inherits the default.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if shown.isEmpty {
                Text("Nothing selected — tick a bucket below.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                shownList(shown, live: live)
            }
            Text("Not in the menu bar — tick a bucket to add it. Discovered buckets appear here automatically; a dimmed row is remembered but absent from the current response, and ✕ dismisses it until the provider returns it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            candidateList(merged: merged, live: live, selected: Set(item.selectedFieldIds))
        }
        .onAppear { rebuildCaches() }
        .onChange(of: quotaService.fieldRegistry) { _, _ in rebuildCaches() }
        .onReceive(quotaService.$lastSuccessByAccount) { _ in
            liveIds = liveFieldIds(merged: mergedOptionsById)
        }
    }

    private func liveFieldIds(merged: [String: MenuBarFieldOption]) -> Set<String> {
        var quotas: [ToolType: AccountQuota] = [:]
        for tool in ToolType.dedicatedCardProviders {
            if let quota = environment.quota(for: tool) { quotas[tool] = quota }
        }
        var live: Set<String> = []
        for option in merged.values
        where quotas[option.tool]?.bucket(id: option.bucketId) != nil {
            live.insert(option.id)
        }
        return live
    }

    // MARK: - Shown

    private struct ShownRun: Identifiable {
        let companyName: String?
        let tool: ToolType
        let subProviderName: String
        var options: [MenuBarFieldOption]
        let firstIndex: Int
        var id: String { "\(firstIndex)" }
    }

    private func runs(_ shown: [MenuBarFieldOption]) -> [ShownRun] {
        var runs: [ShownRun] = []
        var index = 0
        for option in shown {
            let sub = option.tool.quotaSubProviderName(bucketID: option.bucketId)
            let vendor = option.tool.vendorName
            if var last = runs.last, last.tool == option.tool, last.subProviderName == sub {
                last.options.append(option)
                runs[runs.count - 1] = last
            } else {
                let previousVendor = runs.last?.tool.vendorName
                runs.append(ShownRun(
                    companyName: vendor == previousVendor ? nil : vendor,
                    tool: option.tool,
                    subProviderName: sub,
                    options: [option],
                    firstIndex: index
                ))
            }
            index += 1
        }
        return runs
    }

    private func shownList(_ shown: [MenuBarFieldOption], live: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(runs(shown)) { run in
                if let company = run.companyName {
                    HStack(spacing: 6) {
                        // `companyName` is `vendorName` — an L1 heading.
                        CompanyBrandIconView(tool: run.tool, size: 12)
                            .opacity(0.85)
                        Text(company)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.4)
                    }
                    .padding(.top, run.firstIndex == 0 ? 0 : 5)
                }
                Text(run.subProviderName.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .tracking(1.0)
                    .padding(.leading, 14)
                ForEach(Array(run.options.enumerated()), id: \.element.id) { offset, option in
                    shownRow(option, index: run.firstIndex + offset, count: shown.count, live: live)
                }
            }
        }
    }

    private func shownRow(_ option: MenuBarFieldOption, index: Int, count: Int, live: Set<String>) -> some View {
        let isLive = live.contains(option.id)
        return HStack(spacing: 8) {
            Circle()
                .fill(Theme.providerAccent(for: option.tool))
                .frame(width: 6, height: 6)
            Text(option.displayTitle)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if !isLive {
                Text("offline")
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            Picker("", selection: styleBinding(option)) {
                ForEach(MenuBarFieldStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 108)
            .help("How this field draws on the menu bar: its label, the provider's logo, or both — each beside the percent.")
            DebouncedSettingsTextField(
                prompt: option.displayDefaultLabel,
                value: labelBinding(option)
            )
            .frame(width: 108)
            Button {
                move(option.id, by: -1)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.vibeBar)
            .disabled(index == 0)
            Button {
                move(option.id, by: 1)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.vibeBar)
            .disabled(index >= count - 1)
            Button {
                setSelected(option.id, false)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.vibeBar)
            .help("Remove from the menu bar")
        }
        .padding(.horizontal, 8)
        .padding(.leading, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isLive ? 0.05 : 0.03))
                .padding(.leading, 8)
        )
        .opacity(isLive ? 1 : 0.6)
        .help(option.id)
    }

    // MARK: - Candidates

    private func candidateList(
        merged: [String: MenuBarFieldOption],
        live: Set<String>,
        selected: Set<String>
    ) -> some View {
        let hidden = settingsStore.settings.miniWindow.hiddenStaleFieldIds
        let registry = quotaService.fieldRegistry
        let discoveredIds = Set(registry.fields.map(\.id))
        var sections: [(section: MiniWindowFieldProviderSection, options: [MenuBarFieldOption])] = []
        for section in MiniWindowFieldProviderSection.all {
            var options = section.fields.filter { !selected.contains($0.id) }
            for discovered in registry.fields
            where discovered.tool == section.tool
                && MenuBarFieldCatalog.field(id: discovered.id) == nil
                && !selected.contains(discovered.id)
                && sections.allSatisfy({ $0.section.tool != section.tool }) {
                options.append(MenuBarFieldCatalog.option(for: discovered))
            }
            options.removeAll { option in
                !discoveredIds.contains(option.id)
                    && hidden.contains(option.id)
                    && !live.contains(option.id)
            }
            guard !options.isEmpty else { continue }
            sections.append((section, options))
        }
        return VStack(alignment: .leading, spacing: 12) {
            if sections.isEmpty {
                Text("Every known bucket is already in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ForEach(Array(sections.enumerated()), id: \.offset) { _, pair in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        QuotaBrandIconView(
                            tool: pair.section.tool,
                            bucketID: pair.section.fields.first?.bucketId,
                            size: 13
                        )
                            .opacity(0.85)
                        Text(pair.section.title)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.4)
                    }
                    ForEach(pair.options) { option in
                        candidateRow(option, live: live, isDiscovered: discoveredIds.contains(option.id))
                    }
                }
            }
        }
    }

    private func candidateRow(_ option: MenuBarFieldOption, live: Set<String>, isDiscovered: Bool) -> some View {
        let isLive = live.contains(option.id)
        return HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { settingsStore.settings.menuBarItem(kind).selectedFieldIds.contains(option.id) },
                set: { setSelected(option.id, $0) }
            )) {
                Text(option.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
            }
            .help(option.id)
            Spacer(minLength: 8)
            if !isLive {
                Text("not in current response")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Button {
                    if isDiscovered {
                        forgetDiscovered(option.id)
                    } else {
                        var settings = settingsStore.settings
                        settings.miniWindow.hiddenStaleFieldIds.insert(option.id)
                        settingsStore.settings = settings
                    }
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.vibeBar)
                .help(
                    isDiscovered
                        ? "Forget this discovered bucket — drops it everywhere it was selected."
                        : "Dismiss this built-in bucket while the provider is not returning it."
                )
            }
        }
        .opacity(isLive ? 1 : 0.55)
    }

    // MARK: - Mutations

    private func updateItem(_ mutate: (inout MenuBarItemSettings) -> Void) {
        var item = settingsStore.settings.menuBarItem(kind)
        mutate(&item)
        settingsStore.settings.setMenuBarItem(item)
    }

    private func setSelected(_ fieldId: String, _ selected: Bool) {
        updateItem { item in
            if selected {
                if !item.selectedFieldIds.contains(fieldId) {
                    item.selectedFieldIds.append(fieldId)
                }
            } else {
                item.selectedFieldIds.removeAll { $0 == fieldId }
            }
        }
    }

    private func move(_ fieldId: String, by offset: Int) {
        updateItem { item in
            guard let index = item.selectedFieldIds.firstIndex(of: fieldId) else { return }
            let target = index + offset
            guard item.selectedFieldIds.indices.contains(target) else { return }
            item.selectedFieldIds.swapAt(index, target)
        }
    }

    private func styleBinding(_ option: MenuBarFieldOption) -> Binding<MenuBarFieldStyle> {
        Binding(
            get: { settingsStore.settings.menuBarItem(kind).style(for: option.id) },
            set: { style in
                updateItem { item in
                    if style == .labelAndPercent {
                        item.fieldStyles.removeValue(forKey: option.id)
                    } else {
                        item.fieldStyles[option.id] = style
                    }
                }
            }
        )
    }

    private func labelBinding(_ option: MenuBarFieldOption) -> Binding<String> {
        Binding(
            get: { settingsStore.settings.menuBarItem(kind).customLabels[option.id] ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                updateItem { item in
                    if trimmed.isEmpty {
                        item.customLabels.removeValue(forKey: option.id)
                    } else {
                        item.customLabels[option.id] = value
                    }
                }
            }
        )
    }

    private func forgetDiscovered(_ fieldId: String) {
        quotaService.forgetDiscoveredField(id: fieldId)
        var settings = settingsStore.settings
        settings.miniWindow.customLabels.removeValue(forKey: fieldId)
        for index in settings.miniWindow.windows.indices {
            settings.miniWindow.windows[index].fieldIds.removeAll { $0 == fieldId }
            settings.miniWindow.windows[index].customLabels.removeValue(forKey: fieldId)
            for mode in settings.miniWindow.windows[index].modeCustomLabels.keys {
                settings.miniWindow.windows[index].modeCustomLabels[mode]?.removeValue(forKey: fieldId)
            }
        }
        for kind in MenuBarItemKind.allCases {
            var item = settings.menuBarItem(kind)
            item.selectedFieldIds.removeAll { $0 == fieldId }
            item.customLabels.removeValue(forKey: fieldId)
            settings.setMenuBarItem(item)
        }
        settingsStore.settings = settings
    }
}
