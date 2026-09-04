import SwiftUI
import VibeBarCore

/// Everything that narrows the Usage Stats page: harness chips, a model
/// picker, the date range, and how often the page re-queries.
///
/// This is a usage surface, so the unit is the **harness** — the CLI or app
/// that produced the tokens — and the company is a section head inside the
/// picker that toggles its harnesses in one click. The picker is the same
/// one the Sessions page opens (`FilterPickerList`): type to find a harness
/// by any of its names, tick several without the list closing, ⌥-click to
/// keep only one. See AGENTS.md § 7.1.
struct UsageFiltersBar: View {
    let density: Theme.Density
    @ObservedObject var model: UsageStatsViewModel

    @State private var showsCustomRange = false

    var body: some View {
        Group {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    harnessPicker
                    modelPicker
                    controls
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .workbenchToolbarSurface()
    }

    // MARK: - Harnesses and models

    private var harnessPicker: some View {
        let stats = Dictionary(model.harnessStats.map { ($0.harness, $0) }, uniquingKeysWith: { first, _ in first })
        return FilterPickerButton(
            density: density,
            systemImage: "terminal",
            title: L10n.Usage.Table.Column.harness,
            detail: harnessSummary,
            prominent: model.selectedHarnesses != nil,
            accessibilityLabel: L10n.Usage.Table.Column.harness
        ) {
            FilterPickerList(
                density: density,
                sections: HarnessPickerRows.sections(
                    groups: model.harnessChipGroups,
                    density: density,
                    // Tokens in the current range, for the harnesses the query
                    // already covers; a harness outside it has no number yet.
                    detail: { stats[$0].map { UsageFormatting.compactTokens($0.totalTokens) } }
                ),
                searchPlaceholder: L10n.Workbench.Filter.searchHarnesses,
                isSelected: { model.selectedHarnesses?.contains($0) ?? true },
                toggle: { model.toggleHarness($0) },
                solo: { model.soloHarness($0) },
                toggleGroup: { model.toggleHarnesses(Set($0)) },
                selectAll: { model.setSelectedHarnesses(nil) },
                selectNone: { model.setSelectedHarnesses([]) }
            )
        }
    }

    private var harnessSummary: String {
        let options = model.harnessOptions
        guard let selected = model.selectedHarnesses else { return L10n.Common.all }
        return L10n.Workbench.Sessions.fraction(
            shown: options.count(where: selected.contains), total: options.count
        )
    }

    /// The model picker is one flat list; models have no company head.
    private var modelPicker: some View {
        FilterPickerButton(
            density: density,
            systemImage: "cpu",
            title: L10n.Usage.Breakdown.models,
            detail: modelSummary,
            prominent: model.selectedModels != nil,
            accessibilityLabel: L10n.Usage.Filters.modelsMenuLabel
        ) {
            FilterPickerList(
                density: density,
                sections: [
                    FilterPickerSection(
                        id: "models",
                        rows: model.availableModels.map { name in
                            FilterPickerRow(
                                id: name,
                                title: UsageModelNaming.canonicalDisplayName(name),
                                accent: .accentColor,
                                icon: AnyView(
                                    Image(systemName: "cpu")
                                        .font(.system(size: density.segmentedFontSize - 1))
                                        .foregroundStyle(.secondary)
                                ),
                                searchKeys: [name, UsageModelNaming.canonicalDisplayName(name)]
                            )
                        }
                    )
                ],
                searchPlaceholder: L10n.Workbench.Filter.searchModels,
                emptyMessage: L10n.Usage.Filters.noModelsInRange,
                showsNone: false,
                isSelected: { model.selectedModels?.contains($0) ?? true },
                toggle: { model.toggleModel($0) },
                solo: { model.setSelectedModels([$0]) },
                toggleGroup: { _ in },
                selectAll: { model.setSelectedModels(nil) },
                selectNone: {}
            )
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 8) {
            rangeMenu
            refreshMenu
            if model.selectedTools != nil
                || model.selectedHarnesses != nil
                || model.selectedModels != nil {
                Button {
                    // Harnesses first: `setSelectedTools` prunes any harness
                    // whose company just left the query, so clearing tools
                    // ahead of it would leave a stale, half-applied filter.
                    model.setSelectedHarnesses(nil)
                    model.setSelectedTools(nil)
                    model.setSelectedModels(nil)
                } label: {
                    Label(L10n.Common.clear, systemImage: "xmark")
                        .font(.system(size: max(10, density.segmentedFontSize - 1), weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 22)
                }
                .buttonStyle(WorkbenchPillButtonStyle())
                .help(L10n.Usage.Filters.clearHelp)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var rangeMenu: some View {
        Menu {
            ForEach(UsageStatsViewModel.RangePreset.allCases) { preset in
                Button {
                    model.rangePreset = preset
                    if preset == .custom { showsCustomRange = true }
                } label: {
                    Label(preset.title, systemImage: preset.systemImage)
                }
            }
            Divider()
            Button(L10n.Usage.Filters.editCustomRange) {
                model.rangePreset = .custom
                showsCustomRange = true
            }
        } label: {
            menuLabel(systemImage: "calendar", title: model.rangePreset.title, detail: rangeSummary)
        }
        .menuStyle(.button)
        .buttonStyle(WorkbenchPillButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .popover(isPresented: $showsCustomRange, arrowEdge: .bottom) {
            customRangeEditor
                // A native form: no initial selection, but the system focus
                // ring comes back for its date pickers.
                .vibeBarNoInitialFocus()
                .vibeBarSystemControlFocus()
        }
        .accessibilityLabel(L10n.Usage.Filters.rangeMenu)
    }

    private var customRangeEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.Usage.Filters.customRangeTitle)
                .font(.system(size: max(8, density.subtitleFontSize - 2), weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.4)
            DatePicker(
                L10n.Usage.Filters.customRangeFrom,
                selection: $model.customStart,
                in: ...Date(),
                displayedComponents: [.date, .hourAndMinute]
            )
            DatePicker(
                L10n.Usage.Filters.customRangeTo,
                selection: $model.customEnd,
                displayedComponents: [.date, .hourAndMinute]
            )
            Text(L10n.Usage.Filters.customRangeHint)
                .font(.system(size: max(9, density.resetCountdownFontSize - 1)))
                .foregroundStyle(.tertiary)
        }
        .datePickerStyle(.compact)
        .padding(14)
        .frame(width: 300)
    }

    private var refreshMenu: some View {
        Menu {
            Picker(L10n.Usage.Filters.autoRefresh, selection: $model.refreshInterval) {
                ForEach(UsageStatsViewModel.RefreshInterval.allCases) { interval in
                    Text(interval == .off
                        ? L10n.Common.off
                        : L10n.Usage.Filters.refreshInterval(seconds: interval.rawValue))
                        .tag(interval)
                }
            }
            .pickerStyle(.inline)
        } label: {
            menuLabel(
                systemImage: model.refreshInterval == .off ? "pause.circle" : "arrow.clockwise.circle",
                title: L10n.Common.auto,
                detail: model.refreshInterval.title
            )
        }
        .menuStyle(.button)
        .buttonStyle(WorkbenchPillButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.Usage.Filters.autoMenuLabel)
    }

    // MARK: - Labels

    private func menuLabel(systemImage: String, title: String, detail: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: max(10, density.segmentedFontSize - 2), weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title.uppercased())
                .font(.system(size: max(10, density.segmentedFontSize - 3), weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.4)
            Text(detail)
                .font(.system(size: max(10, density.segmentedFontSize - 1), weight: .semibold, design: .rounded)
                    .monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(minHeight: 22)
    }

    private func modelBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { model.selectedModels?.contains(name) ?? true },
            set: { _ in model.toggleModel(name) }
        )
    }

    private var rangeSummary: String {
        if model.rangePreset == .all { return L10n.Cost.ModelRanking.allTime }
        let range = model.range
        let formatter = range.duration <= 86_400 ? Self.hourFormatter : Self.dayFormatter
        return L10n.Usage.Filters.rangeSpan(
            start: formatter.string(from: range.start),
            end: formatter.string(from: range.end)
        )
    }

    private static var hourFormatter: DateFormatter {
        AppLocale.dateFormatter(template: "MMMdHHmm")
    }
    private static var dayFormatter: DateFormatter {
        AppLocale.dateFormatter(template: "MMMd")
    }


    private var modelSummary: String {
        guard let selected = model.selectedModels else { return L10n.Common.all }
        if selected.count == 1, let only = selected.first {
            return UsageModelNaming.canonicalDisplayName(only)
        }
        return L10n.Usage.Filters.modelsSelected(count: selected.count)
    }

}
