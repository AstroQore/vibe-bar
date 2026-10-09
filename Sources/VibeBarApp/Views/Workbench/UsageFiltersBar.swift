import AppKit
import SwiftUI
import VibeBarCore

/// Everything that narrows the Usage page: the range, one chip per harness,
/// and pickers for a model and a project.
///
/// This is a usage surface, so the unit is the **harness** — the CLI or app
/// that produced the tokens (AGENTS.md § 7.1). Chips come from the snapshot's
/// options, which are computed before the harness filter, so narrowing to one
/// harness never retires the others. ⌥-click keeps only the clicked harness.
struct UsageFiltersBar: View {
    let density: Theme.Density
    let model: UsageStatsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                UsagePillPicker(
                    options: UsageDashboardRange.allCases,
                    title: Self.title(for:),
                    selection: Binding(get: { model.range }, set: { model.setRange($0) }),
                    accessibilityLabel: L10n.Usage.Filters.rangeMenu
                )
                Spacer(minLength: 8)
                modelPicker
                projectPicker
                if model.hasActiveFilters {
                    Button {
                        model.clearFilters()
                    } label: {
                        Label(L10n.Common.clear, systemImage: "xmark")
                            .font(.system(size: max(10, density.segmentedFontSize - 1), weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(minHeight: 22)
                    }
                    .buttonStyle(WorkbenchPillButtonStyle())
                    .help(L10n.Workbench.Usage.Filter.clearHelp)
                }
            }
            ScrollView(.horizontal) {
                harnessChips
                    .padding(.vertical, 1)
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .workbenchToolbarSurface()
    }

    static func title(for range: UsageDashboardRange) -> String {
        switch range {
        case .today: L10n.Cost.Timeframe.today
        case .week: L10n.Cost.Timeframe.week
        case .month: L10n.Cost.Timeframe.month
        case .quarter: L10n.Workbench.Usage.Range.quarter
        case .all: L10n.Cost.ModelRanking.allTime
        }
    }

    // MARK: Harness chips

    private var harnessChips: some View {
        let options = model.snapshot.options.harnesses
        let allSelected = model.selectedHarnesses == nil
        return HStack(spacing: 6) {
            UsageHarnessChip(
                title: L10n.Common.all,
                icon: nil,
                detail: nil,
                isSelected: allSelected,
                tint: WorkbenchPorcelain.accent
            ) { _ in
                model.toggleAllHarnesses()
            }
            .help(allSelected ? L10n.Usage.Filters.allHarnessesHelpNone : L10n.Usage.Filters.allHarnessesHelpEvery)
            ForEach(options) { option in
                UsageHarnessChip(
                    title: option.harness.displayName,
                    icon: option.harness,
                    detail: option.tokens > 0 ? UsageDashboardFormat.tokens(option.tokens) : nil,
                    // `nil` is every harness, so every chip is lit until one is narrowed.
                    isSelected: model.isHarnessSelected(option.harness),
                    tint: option.harness.usageTint
                ) { solo in
                    if solo { model.soloHarness(option.harness) } else { model.toggleHarness(option.harness) }
                }
                .help(L10n.Usage.Filters.harnessHelp(company: option.harness.companyName, harness: option.harness.displayName))
            }
        }
    }

    // MARK: Pickers

    private var modelPicker: some View {
        let selected = model.selectedModel
        return FilterPickerButton(
            density: density,
            systemImage: "cpu",
            title: L10n.Usage.Table.Column.model,
            detail: selected.map(UsageDashboardFormat.modelName) ?? L10n.Common.all,
            prominent: selected != nil,
            accessibilityLabel: L10n.Usage.Filters.modelsMenuLabel
        ) {
            FilterPickerList(
                density: density,
                sections: [
                    FilterPickerSection(
                        id: "models",
                        rows: model.snapshot.options.models.map { name in
                            FilterPickerRow(
                                id: name,
                                title: UsageDashboardFormat.modelName(name),
                                accent: .accentColor,
                                icon: AnyView(
                                    Image(systemName: "cpu")
                                        .font(.system(size: density.segmentedFontSize - 1))
                                        .foregroundStyle(.secondary)
                                ),
                                searchKeys: [name, UsageDashboardFormat.modelName(name)]
                            )
                        }
                    )
                ],
                searchPlaceholder: L10n.Workbench.Filter.searchModels,
                emptyMessage: L10n.Usage.Filters.noModelsInRange,
                showsNone: false,
                isSelected: { selected == nil || selected == $0 },
                toggle: { name in model.setModel(selected == name ? nil : name) },
                solo: { model.setModel($0) },
                toggleGroup: { _ in },
                selectAll: { model.setModel(nil) },
                selectNone: {}
            )
        }
    }

    private var projectPicker: some View {
        let selected = model.selectedProject
        let options = model.snapshot.options.projects
        return FilterPickerButton(
            density: density,
            systemImage: "folder",
            title: L10n.Workbench.Usage.Filter.project,
            detail: selected.map(UsageProjectIdentity.displayName(for:)) ?? L10n.Common.all,
            prominent: selected != nil,
            accessibilityLabel: L10n.Workbench.Usage.Filter.project
        ) {
            FilterPickerList(
                density: density,
                sections: [
                    FilterPickerSection(
                        id: "projects",
                        rows: options.map { option in
                            FilterPickerRow(
                                id: option.path,
                                title: option.name,
                                detail: option.tokens > 0 ? UsageDashboardFormat.tokens(option.tokens) : nil,
                                accent: .accentColor,
                                icon: AnyView(
                                    Image(systemName: "folder")
                                        .font(.system(size: density.segmentedFontSize - 1))
                                        .foregroundStyle(.secondary)
                                ),
                                searchKeys: [option.name, option.path]
                            )
                        }
                    )
                ],
                searchPlaceholder: L10n.Workbench.Usage.Filter.searchProjects,
                emptyMessage: L10n.Workbench.Usage.Ranking.emptyProjects,
                showsNone: false,
                isSelected: { selected == nil || selected == $0 },
                toggle: { path in model.setProject(selected == path ? nil : path) },
                solo: { model.setProject($0) },
                toggleGroup: { _ in },
                selectAll: { model.setProject(nil) },
                selectNone: {}
            )
        }
        .help(L10n.Workbench.Usage.Filter.projectHelp)
    }
}

/// One harness chip: mark, name, tokens in the range. Selection is a tint
/// fill; the click hands back whether ⌥ was held.
private struct UsageHarnessChip: View {
    let title: String
    let icon: Harness?
    let detail: String?
    let isSelected: Bool
    let tint: Color
    let action: (_ solo: Bool) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {
            action(NSEvent.modifierFlags.contains(.option))
        } label: {
            HStack(spacing: 5) {
                if let icon {
                    HarnessBrandIconView(harness: icon, size: 12, brandColored: isSelected)
                        .opacity(isSelected ? 1 : 0.7)
                }
                Text(title)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(minHeight: 24)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? tint.opacity(colorScheme == .dark ? 0.24 : 0.14) : WorkbenchPorcelain.toolbarFill(for: colorScheme))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(isSelected ? tint.opacity(0.5) : WorkbenchPorcelain.hairline(for: colorScheme), lineWidth: Theme.Card.hairlineWidth)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.vibeBar(cornerRadius: 12))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
