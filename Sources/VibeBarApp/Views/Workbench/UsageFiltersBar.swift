import AppKit
import SwiftUI
import VibeBarCore

/// Everything that narrows the Usage Stats page: harness chips, a model
/// picker, the date range, and how often the page re-queries.
///
/// This is a usage surface, so the unit is the **harness** — the CLI or app
/// that produced the tokens — and the company is supplementary: a muted
/// section head that toggles its harnesses in one click. Chips, not a menu,
/// because a chip can carry the brand accent, which is how this app says
/// "provider" everywhere else. See AGENTS.md § 7.1.
struct UsageFiltersBar: View {
    let density: Theme.Density
    @ObservedObject var model: UsageStatsViewModel

    @State private var showsCustomRange = false

    var body: some View {
        Group {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    providerChips
                    Spacer(minLength: 8)
                    controls
                }
                VStack(alignment: .leading, spacing: 7) {
                    providerChips
                    controls
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .workbenchToolbarSurface()
    }

    // MARK: - Harnesses

    private var providerChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                allHarnessesChip
                ForEach(model.harnessChipGroups) { group in
                    HStack(spacing: 4) {
                        companyChip(group)
                        ForEach(group.harnesses, id: \.self) { harness in
                            harnessChip(harness, in: group)
                        }
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.never)
    }

    /// The All chip is a switch, not a shortcut: lit means every harness is
    /// in the query and clicking it clears the selection outright; anything
    /// else and it puts every harness back.
    private var allHarnessesChip: some View {
        let selected = model.selectedHarnesses == nil
        return Button {
            model.toggleAllHarnesses()
        } label: {
            Text(L10n.Usage.filtersAllHarnesses)
                .font(.system(size: max(10, density.segmentedFontSize - 1), weight: .semibold))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 10)
                .frame(minHeight: 28)
        }
        .buttonStyle(.vibeBar)
        .background(chipBackground(tint: .accentColor, selected: selected))
        .help(selected
            ? L10n.Usage.filtersAllHarnessesHelpNone
            : L10n.Usage.filtersAllHarnessesHelpEvery)
        .accessibilityLabel(selected
            ? L10n.Usage.filtersAllHarnessesSelectNone
            : L10n.Usage.filtersAllHarnessesSelectEvery)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// The company section head. Quieter than the harness chips beside it —
    /// smaller, barely any fill — because the company is context here, not
    /// another level to filter by: clicking it toggles its harnesses.
    private func companyChip(_ group: Harness.ChipGroup) -> some View {
        let accent = Theme.providerAccent(for: group.company)
        let selected = isSelected(group)
        return Button {
            model.toggleHarnesses(group.harnessSet)
        } label: {
            HStack(spacing: 4) {
                ToolBrandIconView(tool: group.company, size: max(9, density.segmentedFontSize - 1))
                Text(group.company.vendorName)
                    .font(.system(size: max(9, density.segmentedFontSize - 2), weight: .semibold))
                    .tracking(0.3)
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .frame(minHeight: 28)
        }
        .buttonStyle(.vibeBar)
        .background(Capsule().fill(accent.opacity(selected ? 0.10 : 0.035)))
        .opacity(selected ? 1 : 0.65)
        .saturation(selected ? 1 : 0.50)
        .help(companyHelp(group))
        .accessibilityLabel(
            L10n.Usage.filtersCompanyHarnesses(company: group.company.vendorName)
        )
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// One chip per harness — the axis this page actually groups by. The icon
    /// is the harness's own brand (Cursor's mark, not Grok's); the accent is
    /// the company's, so a group still reads as one block of colour.
    ///
    /// ⌥-click solos, which is the one-click way to ask "just this harness"
    /// without turning eight other chips off by hand.
    private func harnessChip(_ harness: Harness, in group: Harness.ChipGroup) -> some View {
        let selected = model.selectedHarnesses?.contains(harness) ?? true
        return Button {
            if NSEvent.modifierFlags.contains(.option) {
                model.soloHarness(harness)
            } else {
                model.toggleHarness(harness)
            }
        } label: {
            HStack(spacing: 5) {
                ToolBrandIconView(tool: harness.brandTool, size: density.segmentedFontSize + 1)
                Text(harness.displayName)
                    .font(.system(size: max(10, density.segmentedFontSize - 1), weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 28)
        }
        .buttonStyle(.vibeBar)
        .background(chipBackground(tint: Theme.providerAccent(for: group.company), selected: selected))
        // Unselected chips stay legible but recede — the accent is the signal
        // that a harness is in the query, so an off chip must not wear it.
        .opacity(selected ? 1 : 0.70)
        .saturation(selected ? 1 : 0.50)
        .help(L10n.Usage.filtersHarnessHelp(
            company: group.company.vendorName, harness: harness.displayName
        ))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func isSelected(_ group: Harness.ChipGroup) -> Bool {
        guard let selected = model.selectedHarnesses else { return true }
        return group.harnesses.allSatisfy(selected.contains)
    }

    private func chipBackground(tint: Color, selected: Bool) -> some View {
        ZStack {
            Capsule().fill(tint.opacity(selected ? 0.16 : 0.05))
            Capsule().stroke(tint.opacity(selected ? 0.55 : 0.18), lineWidth: 0.8)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 8) {
            rangeMenu
            modelMenu
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
                .help(L10n.Usage.filtersClearHelp)
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
            Button(L10n.Usage.filtersEditCustomRange) {
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
        .accessibilityLabel(L10n.Usage.filtersRangeMenu)
    }

    private var customRangeEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.Usage.filtersCustomRangeTitle)
                .font(.system(size: max(8, density.subtitleFontSize - 2), weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.4)
            DatePicker(
                L10n.Usage.filtersCustomRangeFrom,
                selection: $model.customStart,
                in: ...Date(),
                displayedComponents: [.date, .hourAndMinute]
            )
            DatePicker(
                L10n.Usage.filtersCustomRangeTo,
                selection: $model.customEnd,
                displayedComponents: [.date, .hourAndMinute]
            )
            Text(L10n.Usage.filtersCustomRangeHint)
                .font(.system(size: max(9, density.resetCountdownFontSize - 1)))
                .foregroundStyle(.tertiary)
        }
        .datePickerStyle(.compact)
        .padding(14)
        .frame(width: 300)
    }

    private var modelMenu: some View {
        Menu {
            Button(L10n.Usage.filtersAllModels) { model.setSelectedModels(nil) }
            if model.availableModels.isEmpty {
                Text(L10n.Usage.filtersNoModelsInRange)
            } else {
                Divider()
                ForEach(model.availableModels, id: \.self) { name in
                    Toggle(isOn: modelBinding(name)) {
                        Text(UsageModelNaming.canonicalDisplayName(name))
                    }
                }
            }
        } label: {
            menuLabel(
                systemImage: "cpu",
                title: L10n.Usage.filtersModelsMenu,
                detail: modelSummary
            )
        }
        .menuStyle(.button)
        .buttonStyle(WorkbenchPillButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.Usage.filtersModelsMenuLabel)
    }

    private var refreshMenu: some View {
        Menu {
            Picker(L10n.Usage.filtersAutoRefresh, selection: $model.refreshInterval) {
                ForEach(UsageStatsViewModel.RefreshInterval.allCases) { interval in
                    Text(interval == .off
                        ? L10n.Common.off
                        : L10n.Usage.filtersRefreshInterval(seconds: interval.rawValue))
                        .tag(interval)
                }
            }
            .pickerStyle(.inline)
        } label: {
            menuLabel(
                systemImage: model.refreshInterval == .off ? "pause.circle" : "arrow.clockwise.circle",
                title: L10n.Usage.filtersAutoMenu,
                detail: model.refreshInterval.title
            )
        }
        .menuStyle(.button)
        .buttonStyle(WorkbenchPillButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.Usage.filtersAutoMenuLabel)
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

    /// Company chip tooltip: the harnesses that chip actually toggles, which
    /// is the level this page groups by.
    private func companyHelp(_ group: Harness.ChipGroup) -> String {
        let harnesses = group.harnesses.map(\.displayName).joined(separator: " + ")
        return harnesses.isEmpty
            ? group.company.vendorName
            : L10n.Usage.filtersCompanyHelp(
                company: group.company.vendorName, harnesses: harnesses
            )
    }

    private var rangeSummary: String {
        if model.rangePreset == .all { return L10n.Cost.modelRankingAllTime }
        let range = model.range
        let formatter = range.duration <= 86_400 ? Self.hourFormatter : Self.dayFormatter
        return L10n.Usage.filtersRangeSpan(
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
        return L10n.Usage.filtersModelsSelected(count: selected.count)
    }

}
