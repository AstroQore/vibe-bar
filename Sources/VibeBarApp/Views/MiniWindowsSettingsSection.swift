import SwiftUI
import VibeBarCore

extension Notification.Name {
    /// Posted by Settings to open/close one mini window; the status-item
    /// controller owns the panels and observes this. `userInfo["configID"]`
    /// is the window's UUID string.
    static let vibeBarToggleMiniWindow = Notification.Name("VibeBarToggleMiniWindow")
}

/// Settings → Mini Window: manage the mini windows (several allowed), each
/// with its own display mode, its own field selection — static catalog plus
/// runtime-discovered buckets — and its own arrangement, reordered by drag
/// the way the Layout editor arranges popover cards.
struct MiniWindowsSettingsSection: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var quotaService: QuotaService

    @State private var selectedWindowID: UUID?
    @State private var arrangeFrames: [String: CGRect] = [:]
    @State private var drag: DragState?

    private static let arrangeSpace = "vibebar.mini.arrange"
    private static let dragThreshold: CGFloat = 5

    private struct DragState {
        let fieldID: String
        var location: CGPoint
        var engaged: Bool
    }

    private var windows: [MiniWindowConfig] {
        settingsStore.settings.miniWindow.windows
    }

    private var selectedWindow: MiniWindowConfig? {
        let windows = self.windows
        if let selectedWindowID, let config = windows.first(where: { $0.id == selectedWindowID }) {
            return config
        }
        return windows.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            windowChips()
            if let config = selectedWindow {
                windowDetail(config)
            }
            Divider()
                .padding(.vertical, 2)
            sharedNameEditors()
        }
    }

    // MARK: - Window list

    private func windowChips() -> some View {
        HStack(spacing: 4) {
            ForEach(windows) { config in
                let isSelected = config.id == (selectedWindow?.id)
                Button {
                    selectedWindowID = config.id
                    drag = nil
                } label: {
                    HStack(spacing: 5) {
                        Text(config.name)
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        Text(config.displayMode.label)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .padding(.horizontal, 11)
                    .frame(height: 24)
                    .background {
                        if isSelected {
                            Capsule(style: .continuous)
                                .fill(Color.accentColor.opacity(0.20))
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(Color.accentColor.opacity(0.34), lineWidth: 0.7)
                                )
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.vibeBar(cornerRadius: 12))
            }
            Button {
                addWindow()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.vibeBar)
            .help("Add a mini window")
            Spacer(minLength: 0)
        }
        .padding(3)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private func addWindow() {
        var settings = settingsStore.settings
        let config = MiniWindowConfig(
            name: MiniWindowSettings.defaultWindowName(index: settings.miniWindow.windows.count),
            displayMode: .regular,
            fieldIds: AppSettings.defaultMiniWindow.selectedFieldIds
        )
        settings.miniWindow.windows.append(config)
        settingsStore.settings = settings
        selectedWindowID = config.id
    }

    // MARK: - Per-window detail

    @ViewBuilder
    private func windowDetail(_ config: MiniWindowConfig) -> some View {
        HStack(spacing: 8) {
            DebouncedSettingsTextField(
                prompt: "Name",
                value: Binding(
                    get: { selectedWindow?.name ?? "" },
                    set: { [configID = config.id] value in
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        // Keyed to the window this field was typed for — the
                        // debounced commit may fire after the user selects
                        // another chip, and it must not rename that one.
                        update(id: configID) { $0.name = trimmed }
                    }
                )
            )
            .frame(width: 140)
            Button("Open / Close") {
                NotificationCenter.default.post(
                    name: .vibeBarToggleMiniWindow,
                    object: nil,
                    userInfo: ["configID": config.id.uuidString]
                )
            }
            .help("Toggle this mini window on screen")
            Spacer(minLength: 8)
            Button(role: .destructive) {
                removeWindow(config.id)
            } label: {
                Label("Remove", systemImage: "trash")
                    .font(.system(size: 11))
            }
            .disabled(windows.count <= 1)
            .help(windows.count <= 1 ? "The last mini window cannot be removed." : "Remove this mini window")
        }

        modePicker(config)
        Text(config.displayMode.detail)
            .font(.caption)
            .foregroundStyle(.secondary)

        Text("Fields shown in “\(config.name)”. Buckets the adapters discover at runtime appear here automatically; a dimmed row is remembered but not in the account's current response.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        fieldPicker(config)

        Text("Arrangement — drag to reorder. The order decides the layout: first field leftmost (or topmost).")
            .font(.caption)
            .foregroundStyle(.secondary)
        arrangementList(config)
    }

    private func modePicker(_ config: MiniWindowConfig) -> some View {
        let columns = [GridItem(.adaptive(minimum: 78), spacing: 5)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
            ForEach(MiniWindowDisplayMode.allCases) { mode in
                let isSelected = config.displayMode == mode
                Button {
                    update { $0.displayMode = mode }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: modeIcon(mode))
                            .font(.system(size: 9.5, weight: .medium))
                        Text(mode.label)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(
                                isSelected ? Color.accentColor.opacity(0.34) : Color.primary.opacity(0.08),
                                lineWidth: 0.7
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.vibeBar(cornerRadius: 7))
                .help(mode.detail)
            }
        }
    }

    private func modeIcon(_ mode: MiniWindowDisplayMode) -> String {
        switch mode {
        case .regular: return "circle.grid.2x2"
        case .compact: return "chart.bar"
        case .ledger:  return "list.bullet"
        case .strip:   return "rectangle.split.3x1"
        case .tile:    return "square.grid.3x2"
        case .focus:   return "scope"
        case .rail:    return "timeline.selection"
        }
    }

    // MARK: - Field picker

    private struct PickerEntry: Identifiable {
        let option: MenuBarFieldOption
        let discovered: DiscoveredQuotaField?
        let isLive: Bool
        var id: String { option.id }
        var isNew: Bool {
            guard let discovered else { return false }
            return Date().timeIntervalSince(discovered.firstSeen) < 14 * 86_400
        }
    }

    private struct PickerSection: Identifiable {
        let tool: ToolType
        let title: String
        var entries: [PickerEntry]
        var id: String { title }
    }

    private func pickerSections() -> [PickerSection] {
        let registry = quotaService.fieldRegistry
        var quotas: [ToolType: AccountQuota] = [:]
        for tool in ToolType.dedicatedCardProviders {
            if let quota = environment.quota(for: tool) { quotas[tool] = quota }
        }
        func isLive(_ option: MenuBarFieldOption) -> Bool {
            quotas[option.tool]?.bucket(id: option.bucketId) != nil
        }
        var sections = MiniWindowFieldProviderSection.all.map { section in
            PickerSection(
                tool: section.tool,
                title: section.title,
                entries: section.fields.map {
                    PickerEntry(option: $0, discovered: nil, isLive: isLive($0))
                }
            )
        }
        // Runtime-discovered fields join the first section of their tool. A
        // field a later release promoted into the static catalog is already
        // listed above — appending it again would duplicate a SwiftUI id.
        for discovered in registry.fields where MenuBarFieldCatalog.field(id: discovered.id) == nil {
            let option = MenuBarFieldCatalog.option(for: discovered)
            guard let index = sections.firstIndex(where: { $0.tool == discovered.tool }) else { continue }
            sections[index].entries.append(
                PickerEntry(option: option, discovered: discovered, isLive: isLive(option))
            )
        }
        return sections
    }

    private func fieldPicker(_ config: MiniWindowConfig) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(pickerSections()) { section in
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
                        ForEach(section.entries) { entry in
                            pickerRow(entry, config: config)
                        }
                    }
                }
            }
        }
    }

    private func pickerRow(_ entry: PickerEntry, config: MiniWindowConfig) -> some View {
        HStack(spacing: 10) {
            Toggle(isOn: fieldSelectedBinding(entry.option.id)) {
                HStack(spacing: 6) {
                    Text(entry.option.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                    if entry.isNew {
                        Text("NEW")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.black.opacity(0.8))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.85)))
                    }
                }
            }
            .help(entry.option.id)
            Spacer(minLength: 8)
            if !entry.isLive {
                Text(lastSeenCaption(entry))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            DebouncedSettingsTextField(
                prompt: entry.option.defaultLabel,
                value: fieldLabelBinding(entry.option)
            )
            .frame(width: 110)
        }
        .opacity(entry.isLive ? 1 : 0.55)
    }

    // Static: this caption renders once per dimmed picker row, and the picker
    // re-renders on every settings or quota publish — a formatter per call is
    // the classic per-row allocation.
    private static let lastSeenFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter
    }()

    private func lastSeenCaption(_ entry: PickerEntry) -> String {
        guard let discovered = entry.discovered else { return "not in current response" }
        return "not returned · last seen \(Self.lastSeenFormatter.string(from: discovered.lastSeen))"
    }

    // MARK: - Arrangement

    private struct ArrangeRow: Identifiable {
        let option: MenuBarFieldOption
        let isLive: Bool
        var id: String { option.id }
    }

    private func arrangeRows(_ config: MiniWindowConfig) -> [ArrangeRow] {
        let registry = quotaService.fieldRegistry
        var quotas: [ToolType: AccountQuota] = [:]
        for tool in ToolType.dedicatedCardProviders {
            if let quota = environment.quota(for: tool) { quotas[tool] = quota }
        }
        return config.fieldIds.compactMap { fieldId in
            guard let option = MenuBarFieldCatalog.field(id: fieldId, registry: registry) else { return nil }
            return ArrangeRow(
                option: option,
                isLive: quotas[option.tool]?.bucket(id: option.bucketId) != nil
            )
        }
    }

    @ViewBuilder
    private func arrangementList(_ config: MiniWindowConfig) -> some View {
        let rows = arrangeRows(config)
        if rows.isEmpty {
            Text("No fields selected — tick some above.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            let insertion = insertionIndex(rows: rows)
            VStack(spacing: 3) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    arrangeRowView(row, index: index, count: rows.count)
                        .opacity(drag?.engaged == true && drag?.fieldID == row.id ? 0.3 : 1)
                }
            }
            .coordinateSpace(.named(Self.arrangeSpace))
            .overlay(alignment: .topLeading) {
                if let insertion, let offset = insertionOffset(rows: rows, at: insertion) {
                    Capsule(style: .continuous)
                        .fill(Color.accentColor)
                        .frame(height: 2.5)
                        .offset(y: offset)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func arrangeRowView(_ row: ArrangeRow, index: Int, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 20)
                .contentShape(Rectangle())
                .gesture(dragGesture(fieldID: row.id))
            Circle()
                .fill(Theme.providerAccent(for: row.option.tool))
                .frame(width: 6, height: 6)
            Text(row.option.title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if !row.isLive {
                Text("offline")
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            Button {
                moveField(row.id, by: -1)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.vibeBar)
            .disabled(index == 0)
            Button {
                moveField(row.id, by: 1)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.vibeBar)
            .disabled(index >= count - 1)
            Button {
                setFieldSelected(row.id, false)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.vibeBar)
            .help("Remove from this window")
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(row.isLive ? 0.05 : 0.03))
        )
        .opacity(row.isLive ? 1 : 0.6)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(Self.arrangeSpace))
        } action: { frame in
            arrangeFrames[row.id] = frame
        }
    }

    private func dragGesture(fieldID: String) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.arrangeSpace))
            .onChanged { value in
                var state = drag ?? DragState(fieldID: fieldID, location: value.location, engaged: false)
                guard state.fieldID == fieldID else { return }
                state.location = value.location
                if !state.engaged,
                   hypot(value.translation.width, value.translation.height) >= Self.dragThreshold {
                    state.engaged = true
                }
                drag = state
            }
            .onEnded { _ in
                defer { drag = nil }
                guard let state = drag, state.fieldID == fieldID, state.engaged,
                      let config = selectedWindow
                else { return }
                let rows = arrangeRows(config)
                guard let target = insertionIndex(rows: rows) else { return }
                applyMove(fieldID: fieldID, to: target, rows: rows)
            }
    }

    /// Index among the *other* rows where the dragged row would insert.
    private func insertionIndex(rows: [ArrangeRow]) -> Int? {
        guard let drag, drag.engaged else { return nil }
        let others = rows.filter { $0.id != drag.fieldID }
        var index = others.count
        for (offset, row) in others.enumerated() {
            guard let frame = arrangeFrames[row.id] else { continue }
            if drag.location.y < frame.midY {
                index = offset
                break
            }
        }
        return index
    }

    private func insertionOffset(rows: [ArrangeRow], at index: Int) -> CGFloat? {
        guard let drag else { return nil }
        let others = rows.filter { $0.id != drag.fieldID }
        guard !others.isEmpty else { return 0 }
        guard let firstFrame = arrangeFrames[others[0].id] else { return nil }
        if index >= others.count {
            guard let lastFrame = arrangeFrames[others[others.count - 1].id] else { return nil }
            return lastFrame.maxY - firstFrame.minY + 1.5
        }
        guard let frame = arrangeFrames[others[index].id] else { return nil }
        return frame.minY - firstFrame.minY - 1.5
    }

    private func applyMove(fieldID: String, to index: Int, rows: [ArrangeRow]) {
        // Reorder the *resolvable* rows, then keep any unresolvable ids
        // (fields of a build this one doesn't know) at the tail unchanged.
        var ordered = rows.map(\.id).filter { $0 != fieldID }
        ordered.insert(fieldID, at: min(index, ordered.count))
        update { config in
            let leftovers = config.fieldIds.filter { !ordered.contains($0) }
            config.fieldIds = ordered + leftovers
        }
    }

    private func moveField(_ fieldID: String, by offset: Int) {
        guard let config = selectedWindow else { return }
        let rows = arrangeRows(config).map(\.id)
        guard let index = rows.firstIndex(of: fieldID) else { return }
        let target = index + offset
        guard rows.indices.contains(target) else { return }
        var ordered = rows
        ordered.swapAt(index, target)
        update { config in
            let leftovers = config.fieldIds.filter { !ordered.contains($0) }
            config.fieldIds = ordered + leftovers
        }
    }

    // MARK: - Shared name editors

    @ViewBuilder
    private func sharedNameEditors() -> some View {
        Text("SubProvider names:")
            .font(.caption)
            .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(MiniWindowGroupLabelCatalog.subProviderOptions) { option in
                groupLabelRow(option)
            }
        }
        Text("Model group names:")
            .font(.caption)
            .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(groupLabelOptions) { option in
                groupLabelRow(option)
            }
        }
    }

    private var groupLabelOptions: [MiniWindowGroupLabelOption] {
        var quotas: [ToolType: AccountQuota] = [:]
        for tool in ToolType.dedicatedCardProviders {
            if let quota = environment.quota(for: tool) { quotas[tool] = quota }
        }
        return MiniWindowGroupLabelCatalog.options(liveQuotas: quotas)
    }

    private func groupLabelRow(_ option: MiniWindowGroupLabelOption) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(option.title)
                    .font(.system(size: 12, weight: .medium))
                Text(option.id)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            DebouncedSettingsTextField(
                prompt: option.defaultLabel,
                value: groupLabelBinding(option)
            )
            .frame(width: 130)
        }
    }

    // MARK: - Bindings

    private func update(_ mutate: (inout MiniWindowConfig) -> Void) {
        guard let config = selectedWindow else { return }
        update(id: config.id, mutate)
    }

    private func update(id: UUID, _ mutate: (inout MiniWindowConfig) -> Void) {
        var settings = settingsStore.settings
        guard var config = settings.miniWindow.config(id: id) else { return }
        mutate(&config)
        settings.miniWindow.upsert(config)
        settingsStore.settings = settings
    }

    private func removeWindow(_ id: UUID) {
        var settings = settingsStore.settings
        guard settings.miniWindow.windows.count > 1 else { return }
        settings.miniWindow.windows.removeAll { $0.id == id }
        settingsStore.settings = settings
        if selectedWindowID == id {
            selectedWindowID = settings.miniWindow.windows.first?.id
        }
    }

    private func fieldSelectedBinding(_ fieldId: String) -> Binding<Bool> {
        Binding(
            get: { selectedWindow?.fieldIds.contains(fieldId) ?? false },
            set: { setFieldSelected(fieldId, $0) }
        )
    }

    private func setFieldSelected(_ fieldId: String, _ selected: Bool) {
        update { config in
            if selected {
                if !config.fieldIds.contains(fieldId) {
                    config.fieldIds.append(fieldId)
                }
            } else {
                config.fieldIds.removeAll { $0 == fieldId }
            }
        }
    }

    private func fieldLabelBinding(_ field: MenuBarFieldOption) -> Binding<String> {
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

    private func groupLabelBinding(_ option: MiniWindowGroupLabelOption) -> Binding<String> {
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
}
