import SwiftUI
import VibeBarCore

/// Everything that narrows the Usage Stats page: company chips, a harness
/// picker, a model picker, the date range, and how often the page re-queries.
///
/// The two narrowing axes stay separate on purpose. Companies are chips
/// because they are the filter users reach for most and because a chip can
/// carry the brand accent — which is how this app says "provider" everywhere
/// else. Harnesses are a menu below them: they are the usage axis (which CLI
/// or app produced the sessions), not another level of the quota hierarchy.
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

    // MARK: - Providers

    private var providerChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                allProvidersChip
                ForEach(model.knownCompanyRepresentatives, id: \.self) { representative in
                    providerChip(representative)
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.never)
    }

    private var allProvidersChip: some View {
        Button {
            model.setSelectedTools(nil)
        } label: {
            Text("All providers")
                .font(.system(size: max(10, density.segmentedFontSize - 1), weight: .semibold))
                .foregroundStyle(model.selectedTools == nil ? .primary : .secondary)
                .padding(.horizontal, 10)
                .frame(minHeight: 28)
        }
        .buttonStyle(.plain)
        .background(chipBackground(tint: .accentColor, selected: model.selectedTools == nil))
        .accessibilityLabel("Show every provider")
    }

    private func providerChip(_ tool: ToolType) -> some View {
        let accent = Theme.providerAccent(for: tool)
        let selected = model.isCompanySelected(tool)
        return Button {
            model.toggleCompany(tool)
        } label: {
            HStack(spacing: 5) {
                ToolBrandIconView(tool: tool, size: density.segmentedFontSize + 1)
                Text(tool.vendorName)
                    .font(.system(size: max(10, density.segmentedFontSize - 1), weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 28)
        }
        .buttonStyle(.plain)
        .background(chipBackground(tint: accent, selected: selected))
        // Unselected chips stay legible but recede — the accent is the signal
        // that a provider is in the query, so an off chip must not wear it.
        .opacity(selected ? 1 : 0.70)
        .saturation(selected ? 1 : 0.50)
        .help(companyHelp(tool))
        .accessibilityLabel(tool.vendorName)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
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
            harnessMenu
            modelMenu
            refreshMenu
            if model.selectedTools != nil
                || model.selectedHarnesses != nil
                || model.selectedModels != nil {
                Button {
                    model.setSelectedTools(nil)
                    model.setSelectedHarnesses(nil)
                    model.setSelectedModels(nil)
                } label: {
                    Label("Clear", systemImage: "xmark")
                        .font(.system(size: max(10, density.segmentedFontSize - 1), weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 22)
                }
                .buttonStyle(WorkbenchPillButtonStyle())
                .help("Clear company, harness, and model filters")
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
            Button("Edit custom range…") {
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
        }
        .accessibilityLabel("Choose the date range")
    }

    private var customRangeEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CUSTOM RANGE")
                .font(.system(size: max(8, density.subtitleFontSize - 2), weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.4)
            DatePicker(
                "From",
                selection: $model.customStart,
                in: ...Date(),
                displayedComponents: [.date, .hourAndMinute]
            )
            DatePicker(
                "To",
                selection: $model.customEnd,
                displayedComponents: [.date, .hourAndMinute]
            )
            Text("Choose hourly, daily, or weekly buckets from the chart toolbar.")
                .font(.system(size: max(9, density.resetCountdownFontSize - 1)))
                .foregroundStyle(.tertiary)
        }
        .datePickerStyle(.compact)
        .padding(14)
        .frame(width: 300)
    }

    private var modelMenu: some View {
        Menu {
            Button("All models") { model.setSelectedModels(nil) }
            if model.availableModels.isEmpty {
                Text("No models in range")
            } else {
                Divider()
                ForEach(model.availableModels, id: \.self) { name in
                    Toggle(isOn: modelBinding(name)) {
                        Text(UsageModelNaming.canonicalDisplayName(name))
                    }
                }
            }
        } label: {
            menuLabel(systemImage: "cpu", title: "Models", detail: modelSummary)
        }
        .menuStyle(.button)
        .buttonStyle(WorkbenchPillButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Choose which models to include")
    }

    /// Harnesses, not SubProviders: usage and cost surfaces speak the local
    /// tool that produced the sessions. The list follows the lit company
    /// chips so the menu never offers a combination that returns nothing.
    private var harnessMenu: some View {
        Menu {
            Button("All harnesses") { model.setSelectedHarnesses(nil) }
            if model.harnessOptions.isEmpty {
                Text("No harnesses in range")
            } else {
                Divider()
                ForEach(model.harnessOptions, id: \.self) { harness in
                    Toggle(isOn: harnessBinding(harness)) {
                        Text("\(harness.companyName) · \(harness.displayName)")
                    }
                }
            }
        } label: {
            menuLabel(
                systemImage: "terminal",
                title: "Harness",
                detail: harnessSummary
            )
        }
        .menuStyle(.button)
        .buttonStyle(WorkbenchPillButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Choose which harnesses to include")
    }

    private var refreshMenu: some View {
        Menu {
            Picker("Auto refresh", selection: $model.refreshInterval) {
                ForEach(UsageStatsViewModel.RefreshInterval.allCases) { interval in
                    Text(interval == .off ? "Off" : "Every \(interval.rawValue)s")
                        .tag(interval)
                }
            }
            .pickerStyle(.inline)
        } label: {
            menuLabel(
                systemImage: model.refreshInterval == .off ? "pause.circle" : "arrow.clockwise.circle",
                title: "Auto",
                detail: model.refreshInterval.title
            )
        }
        .menuStyle(.button)
        .buttonStyle(WorkbenchPillButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Choose how often the page re-queries")
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

    private func harnessBinding(_ harness: Harness) -> Binding<Bool> {
        Binding(
            get: { model.selectedHarnesses?.contains(harness) ?? true },
            set: { _ in model.toggleHarness(harness) }
        )
    }

    /// Company chip tooltip: the harnesses that company actually contributes
    /// to usage, which is the level this page groups by.
    private func companyHelp(_ tool: ToolType) -> String {
        let harnesses = Harness.harnesses(forCompany: tool)
            .map(\.displayName)
            .joined(separator: " + ")
        return harnesses.isEmpty ? tool.vendorName : "\(tool.vendorName) · \(harnesses)"
    }

    private var rangeSummary: String {
        if model.rangePreset == .all { return "All time" }
        let range = model.range
        let formatter = range.duration <= 86_400 ? Self.hourFormatter : Self.dayFormatter
        return "\(formatter.string(from: range.start)) – \(formatter.string(from: range.end))"
    }

    private static let hourFormatter = localizedFormatter("MMMd HH:mm")
    private static let dayFormatter = localizedFormatter("MMMd")

    private static func localizedFormatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private var modelSummary: String {
        guard let selected = model.selectedModels else { return "All" }
        if selected.count == 1, let only = selected.first {
            return UsageModelNaming.canonicalDisplayName(only)
        }
        return "\(selected.count) selected"
    }

    private var harnessSummary: String {
        guard let selected = model.selectedHarnesses else { return "All" }
        if selected.count == 1, let only = selected.first { return only.displayName }
        return "\(selected.count) selected"
    }
}
