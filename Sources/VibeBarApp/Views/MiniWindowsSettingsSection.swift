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
    /// Whether name edits below write the shared names or this window's
    /// overrides. Overrides fall back to the shared name when empty.
    @State private var namingScope: NamingScope = .shared
    /// Registry-derived structures are rebuilt when the registry changes,
    /// never during a body render — a debounced name edit republishes
    /// AppSettings and re-renders this whole section, and rebuilding the
    /// merged catalog tree on each of those violates the fluency budget.
    @State private var cachedSections: [PickerSection] = []
    @State private var mergedOptionsById: [String: MenuBarFieldOption] = [:]
    /// Field ids whose bucket the live quota cache currently returns.
    @State private var liveFieldIds: Set<String> = []

    private enum NamingScope: Hashable {
        case shared
        case window
        /// The selected window's *current display style* only — a tile can
        /// carry a terse name while the ledger keeps the full one.
        case style
    }

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
        }
        .onAppear {
            rebuildRegistryCaches()
            rebuildLiveness()
        }
        .onChange(of: quotaService.fieldRegistry) { _, _ in
            rebuildRegistryCaches()
            rebuildLiveness()
        }
        .onReceive(quotaService.$lastSuccessByAccount) { _ in
            rebuildLiveness()
        }
    }

    private func rebuildRegistryCaches() {
        cachedSections = pickerSections()
        mergedOptionsById = Dictionary(
            MenuBarFieldCatalog.mergedFields(registry: quotaService.fieldRegistry).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func rebuildLiveness() {
        var quotas: [ToolType: AccountQuota] = [:]
        for tool in ToolType.dedicatedCardProviders {
            if let quota = environment.quota(for: tool) { quotas[tool] = quota }
        }
        var live: Set<String> = []
        for option in mergedOptionsById.values
        where quotas[option.tool]?.bucket(id: option.bucketId) != nil {
            live.insert(option.id)
        }
        liveFieldIds = live
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
        if config.displayMode == .strip {
            Picker("Strip density", selection: Binding(
                get: { selectedWindow?.stripDensity ?? .roomy },
                set: { value in update { $0.stripDensity = value } }
            )) {
                ForEach(MiniStripDensity.allCases) { density in
                    Text(density.label).tag(density)
                }
            }
            .pickerStyle(.segmented)
            Text((selectedWindow?.stripDensity ?? .roomy).detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Text("Double-click on the window cycles its style. Tap a style to include it — the badge is its turn in the cycle. Nothing selected means every style, in this order.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        cycleEditor(config)

        Text("One tree for the window — grouped exactly as it folds them (company → SubProvider → quota group → bucket). Drag a row to reorder, ✕ to remove, and rename any level in place. First field renders leftmost (or topmost).")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 4) {
            namingScopeButton(.shared, label: "Names: all windows")
            namingScopeButton(.window, label: "Only “\(config.name)”")
            namingScopeButton(.style, label: "Only \(config.displayMode.label) here")
            Spacer(minLength: 0)
        }
        .padding(3)
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.045)))
        if namingScope == .window {
            Text("Name overrides for this window only. An empty field inherits the shared name — shown as the placeholder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if namingScope == .style {
            Text("Overrides for the \(config.displayMode.label) style of this window only. An empty field inherits the window name, then the shared one — shown as the placeholder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        arrangementList(config)

        Text("Not in “\(config.name)” — tick a bucket to add it. Buckets the adapters discover at runtime appear here automatically; a dimmed row is remembered but not in the account's current response, and ✕ dismisses it until the provider returns it.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        notShownList(config)
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

    private func cycleEditor(_ config: MiniWindowConfig) -> some View {
        let columns = [GridItem(.adaptive(minimum: 78), spacing: 5)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
            ForEach(MiniWindowDisplayMode.allCases) { mode in
                let position = config.cycleModes.firstIndex(of: mode)
                Button {
                    update { cfg in
                        if let index = cfg.cycleModes.firstIndex(of: mode) {
                            cfg.cycleModes.remove(at: index)
                        } else {
                            cfg.cycleModes.append(mode)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        if let position {
                            Text("\(position + 1)")
                                .font(.system(size: 8.5, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 12, height: 12)
                                .background(Circle().fill(Color.accentColor.opacity(0.16)))
                        }
                        Text(mode.label)
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(position != nil ? Color.primary : Color.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 21)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(position != nil ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(
                                position != nil ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.08),
                                lineWidth: 0.7
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.vibeBar(cornerRadius: 6))
                .help("Include \(mode.label) in the double-click cycle")
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
        var id: String { option.id }
    }

    private struct PickerSection: Identifiable {
        let tool: ToolType
        let title: String
        var entries: [PickerEntry]
        var id: String { title }
    }

    private func pickerSections() -> [PickerSection] {
        let registry = quotaService.fieldRegistry
        var sections = MiniWindowFieldProviderSection.all.map { section in
            PickerSection(
                tool: section.tool,
                title: section.title,
                entries: section.fields.map { PickerEntry(option: $0, discovered: nil) }
            )
        }
        // Runtime-discovered fields join the first section of their tool. A
        // field a later release promoted into the static catalog is already
        // listed above — appending it again would duplicate a SwiftUI id.
        for discovered in registry.fields where MenuBarFieldCatalog.field(id: discovered.id) == nil {
            let option = MenuBarFieldCatalog.option(for: discovered)
            guard let index = sections.firstIndex(where: { $0.tool == discovered.tool }) else { continue }
            sections[index].entries.append(PickerEntry(option: option, discovered: discovered))
        }
        return sections
    }

    /// The unified tree above holds everything the window shows; this list is
    /// only what it does not — candidates to tick in, and remembered-but-gone
    /// rows to dismiss.
    private func notShownList(_ config: MiniWindowConfig) -> some View {
        let hidden = settingsStore.settings.miniWindow.hiddenStaleFieldIds
        let sections: [PickerSection] = cachedSections.compactMap { section in
            let remaining = section.entries.filter { entry in
                guard !config.fieldIds.contains(entry.option.id) else { return false }
                // A dismissed built-in row stays out only while the provider
                // is not returning it.
                if entry.discovered == nil,
                   hidden.contains(entry.option.id),
                   !liveFieldIds.contains(entry.option.id) {
                    return false
                }
                return true
            }
            guard !remaining.isEmpty else { return nil }
            return PickerSection(tool: section.tool, title: section.title, entries: remaining)
        }
        return VStack(alignment: .leading, spacing: 12) {
            if sections.isEmpty {
                Text("Every known bucket is already in this window.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ForEach(sections) { section in
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
        let isLive = liveFieldIds.contains(entry.option.id)
        return HStack(spacing: 10) {
            Toggle(isOn: fieldSelectedBinding(entry.option.id)) {
                Text(entry.option.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
            }
            .help(entry.option.id)
            Spacer(minLength: 8)
            if !isLive {
                Text(lastSeenCaption(entry))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Button {
                    if entry.discovered != nil {
                        forgetDiscoveredField(entry.option.id)
                    } else {
                        hideStaleField(entry.option.id)
                    }
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.vibeBar)
                .help(
                    entry.discovered != nil
                        ? "Forget this discovered bucket — drops it from the list and from every window that selected it."
                        : "Dismiss this built-in bucket while the provider is not returning it. It comes back the moment the provider does."
                )
            }
        }
        .opacity(isLive ? 1 : 0.55)
    }

    /// Dismiss a built-in catalog bucket while its provider is not returning
    /// it. Selection state is untouched — the row only leaves the candidate
    /// list, and returns on its own once the bucket goes live again.
    private func hideStaleField(_ fieldId: String) {
        var settings = settingsStore.settings
        settings.miniWindow.hiddenStaleFieldIds.insert(fieldId)
        settingsStore.settings = settings
    }

    /// Forget a discovered bucket the provider no longer returns: registry
    /// entry, every window's selection of it, and any names it was given.
    private func forgetDiscoveredField(_ fieldId: String) {
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
        settingsStore.settings = settings
    }

    // Static: this caption renders once per dimmed picker row, and the picker
    // re-renders on every settings or quota publish — a formatter per call is
    // the classic per-row allocation.
    private static let lastSeenFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        formatter.timeZone = .autoupdatingCurrent
        return formatter
    }()

    private func lastSeenCaption(_ entry: PickerEntry) -> String {
        guard let discovered = entry.discovered else { return "not in current response" }
        return "not returned · last seen \(Self.lastSeenFormatter.string(from: discovered.lastSeen))"
    }

    // MARK: - Arrangement

    private struct ArrangeRow: Identifiable {
        let option: MenuBarFieldOption
        var id: String { option.id }
        /// Canonical L2 identity — what the tree groups by. Display names
        /// come from the label chain at render time.
        var subProviderName: String {
            option.tool.quotaSubProviderName(bucketID: option.bucketId)
        }
    }

    /// One consecutive run of fields billing the same SubProvider, under a
    /// company header when the vendor changes — the same folding the mini
    /// window itself performs, so the editor's grouping is the layout's.
    private struct ArrangeGroup: Identifiable {
        let companyName: String?
        let tool: ToolType
        let subProviderName: String
        var rows: [ArrangeRow]
        let firstIndex: Int
        var id: String { "\(firstIndex)" }
    }

    private func arrangeRows(_ config: MiniWindowConfig) -> [ArrangeRow] {
        config.fieldIds.compactMap { fieldId in
            mergedOptionsById[fieldId].map { ArrangeRow(option: $0) }
        }
    }

    private func arrangeGroups(_ rows: [ArrangeRow]) -> [ArrangeGroup] {
        var groups: [ArrangeGroup] = []
        var index = 0
        for row in rows {
            let vendor = row.option.tool.vendorName
            if var last = groups.last,
               last.tool == row.option.tool,
               last.subProviderName == row.subProviderName {
                last.rows.append(row)
                groups[groups.count - 1] = last
            } else {
                let previousVendor = groups.last?.tool.vendorName
                groups.append(ArrangeGroup(
                    companyName: vendor == previousVendor ? nil : vendor,
                    tool: row.option.tool,
                    subProviderName: row.subProviderName,
                    rows: [row],
                    firstIndex: index
                ))
            }
            index += 1
        }
        return groups
    }

    @ViewBuilder
    private func arrangementList(_ config: MiniWindowConfig) -> some View {
        let rows = arrangeRows(config)
        if rows.isEmpty {
            Text("No fields selected — tick some above.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            let groups = arrangeGroups(rows)
            let insertion = insertionIndex(rows: rows)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(groups) { group in
                    if let company = group.companyName {
                        HStack(spacing: 6) {
                            ToolBrandIconView(tool: group.tool, size: 12)
                                .opacity(0.85)
                            Text(company)
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .tracking(0.4)
                        }
                        .padding(.top, group.firstIndex == 0 ? 0 : 5)
                    }
                    subProviderHeader(group)
                    ForEach(groupRuns(group)) { run in
                        if let groupKey = run.groupKey {
                            groupHeader(groupKey: groupKey, run: run)
                        }
                        ForEach(Array(run.rows.enumerated()), id: \.element.id) { offset, row in
                            arrangeRowView(row, index: run.firstIndex + offset, count: rows.count)
                                .opacity(drag?.engaged == true && drag?.fieldID == row.id ? 0.3 : 1)
                        }
                    }
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

    /// One consecutive run of buckets sharing an L3 quota group inside a
    /// SubProvider run — the level between the SubProvider header and its
    /// bucket rows. `nil` groupKey buckets (Grok Bot's single Weekly) render
    /// without the extra header.
    private struct GroupRun: Identifiable {
        let groupKey: String?
        var rows: [ArrangeRow]
        let firstIndex: Int
        var id: String { "\(firstIndex)" }
    }

    private func groupRuns(_ group: ArrangeGroup) -> [GroupRun] {
        var runs: [GroupRun] = []
        var index = group.firstIndex
        for row in group.rows {
            let key = Self.namingGroupKey(for: row.option)
            if var last = runs.last, last.groupKey == key {
                last.rows.append(row)
                runs[runs.count - 1] = last
            } else {
                runs.append(GroupRun(groupKey: key, rows: [row], firstIndex: index))
            }
            index += 1
        }
        return runs
    }

    private func subProviderHeader(_ group: ArrangeGroup) -> some View {
        let key = MiniWindowGroupLabelCatalog.subProviderKey(tool: group.tool, name: group.subProviderName)
        return HStack(spacing: 8) {
            Text(subProviderDisplayName(group).uppercased())
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(1.0)
            Spacer(minLength: 8)
            nameField(NamingRow(
                kind: .subProvider, key: key,
                title: group.subProviderName, defaultLabel: group.subProviderName
            ))
        }
        .padding(.leading, 14)
    }

    private func groupHeader(groupKey: String, run: GroupRun) -> some View {
        let fallback = run.rows.first.map { row in
            row.option.dynamicGroupTitle ?? MenuBarFieldCatalog.bucketGroupStem(row.option.bucketId)
        } ?? groupKey
        let defaultLabel = MiniWindowGroupLabelCatalog.defaultLabel(for: groupKey) ?? fallback
        let resolved = settingsStore.settings.miniWindow
            .resolvedGroupLabel(config: selectedWindow, key: groupKey) ?? defaultLabel
        return HStack(spacing: 8) {
            Text(resolved.uppercased())
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
                .tracking(0.8)
            Spacer(minLength: 8)
            nameField(NamingRow(
                kind: .group, key: groupKey,
                title: defaultLabel, defaultLabel: defaultLabel
            ))
        }
        .padding(.leading, 26)
    }

    private func nameField(_ row: NamingRow) -> some View {
        DebouncedSettingsTextField(prompt: namingPrompt(row), value: namingBinding(row))
            .frame(width: 108)
            .help(row.key)
    }

    private func subProviderDisplayName(_ group: ArrangeGroup) -> String {
        let key = MiniWindowGroupLabelCatalog.subProviderKey(tool: group.tool, name: group.subProviderName)
        return settingsStore.settings.miniWindow.resolvedGroupLabel(config: selectedWindow, key: key)
            ?? group.subProviderName
    }

    private func arrangeRowView(_ row: ArrangeRow, index: Int, count: Int) -> some View {
        let isLive = liveFieldIds.contains(row.id)
        let percent = livePercent(row)
        return HStack(spacing: 8) {
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
            if !isLive {
                Text("offline")
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            nameField(NamingRow(
                kind: .field, key: row.id,
                title: row.option.title, defaultLabel: row.option.defaultLabel
            ))
            if let percent {
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.barColor(percent: percent, mode: settingsStore.displayMode))
            }
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
        .padding(.leading, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isLive ? 0.05 : 0.03))
                .padding(.leading, 8)
        )
        .opacity(isLive ? 1 : 0.6)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(Self.arrangeSpace))
        } action: { frame in
            arrangeFrames[row.id] = frame
        }
    }

    private func livePercent(_ row: ArrangeRow) -> Double? {
        guard liveFieldIds.contains(row.id),
              let bucket = environment.quota(for: row.option.tool)?.bucket(id: row.option.bucketId)
        else { return nil }
        return bucket.displayPercent(settingsStore.displayMode, tool: row.option.tool)
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

    // MARK: - Names, as the hierarchy they belong to

    /// One renamable thing in the L1 → L2 → L3 → bucket tree.
    private struct NamingRow: Identifiable {
        enum Kind {
            case subProvider
            case group
            case field
        }
        let kind: Kind
        /// `groupLabels` key for sub-providers and groups; field id for fields.
        let key: String
        let title: String
        let defaultLabel: String
        var id: String { key }
    }

    private static func namingGroupKey(for option: MenuBarFieldOption) -> String? {
        MiniWindowGroupLabelCatalog.namingGroupKey(for: option)
    }

    private func namingScopeButton(_ scope: NamingScope, label: String) -> some View {
        let isSelected = namingScope == scope
        return Button {
            namingScope = scope
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, 11)
                .frame(height: 22)
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
        .buttonStyle(.vibeBar(cornerRadius: 11))
    }

    /// What an empty field falls back to — in window scope that is the shared
    /// name when one is set, so the placeholder always shows what will render.
    private func namingPrompt(_ row: NamingRow) -> String {
        let mini = settingsStore.settings.miniWindow
        let shared: String?
        let window: String?
        switch row.kind {
        case .field:
            shared = mini.customLabels[row.key]
            window = selectedWindow?.customLabels[row.key]
        case .subProvider, .group:
            shared = mini.groupLabels[row.key]
            window = selectedWindow?.groupLabels[row.key]
        }
        let candidates: [String?]
        switch namingScope {
        case .shared: candidates = []
        case .window: candidates = [shared]
        case .style:  candidates = [window, shared]
        }
        for candidate in candidates {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !trimmed.isEmpty {
                return trimmed
            }
        }
        return row.defaultLabel
    }

    private func namingBinding(_ row: NamingRow) -> Binding<String> {
        // Captured at construction: a debounced commit may fire after the
        // user switches scope or window, and the draft belongs to the target
        // it was typed for — same discipline as the window-name editor.
        let scope = namingScope
        let windowID = selectedWindow?.id
        // The style scope binds to the mode the window showed when the field
        // was constructed — a debounced commit after a mode switch must land
        // on the style it was typed for.
        let modeKey = selectedWindow?.displayMode.rawValue ?? MiniWindowDisplayMode.regular.rawValue
        return Binding(
            get: {
                let mini = settingsStore.settings.miniWindow
                switch (scope, row.kind) {
                case (.shared, .field):
                    return mini.customLabels[row.key] ?? ""
                case (.shared, _):
                    return mini.groupLabels[row.key] ?? ""
                case (.window, .field):
                    return windowID.flatMap { mini.config(id: $0)?.customLabels[row.key] } ?? ""
                case (.window, _):
                    return windowID.flatMap { mini.config(id: $0)?.groupLabels[row.key] } ?? ""
                case (.style, .field):
                    return windowID.flatMap { mini.config(id: $0)?.modeCustomLabels[modeKey]?[row.key] } ?? ""
                case (.style, _):
                    return windowID.flatMap { mini.config(id: $0)?.modeGroupLabels[modeKey]?[row.key] } ?? ""
                }
            },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                switch scope {
                case .shared:
                    var mini = settingsStore.settings.miniWindow
                    if row.kind == .field {
                        if trimmed.isEmpty {
                            mini.customLabels.removeValue(forKey: row.key)
                        } else {
                            mini.customLabels[row.key] = value
                        }
                    } else {
                        if trimmed.isEmpty {
                            mini.groupLabels.removeValue(forKey: row.key)
                        } else {
                            mini.groupLabels[row.key] = value
                        }
                    }
                    settingsStore.settings.miniWindow = mini
                case .window:
                    guard let windowID else { return }
                    update(id: windowID) { config in
                        if row.kind == .field {
                            if trimmed.isEmpty {
                                config.customLabels.removeValue(forKey: row.key)
                            } else {
                                config.customLabels[row.key] = value
                            }
                        } else {
                            if trimmed.isEmpty {
                                config.groupLabels.removeValue(forKey: row.key)
                            } else {
                                config.groupLabels[row.key] = value
                            }
                        }
                    }
                case .style:
                    guard let windowID else { return }
                    update(id: windowID) { config in
                        if row.kind == .field {
                            var labels = config.modeCustomLabels[modeKey] ?? [:]
                            if trimmed.isEmpty {
                                labels.removeValue(forKey: row.key)
                            } else {
                                labels[row.key] = value
                            }
                            config.modeCustomLabels[modeKey] = labels.isEmpty ? nil : labels
                        } else {
                            var labels = config.modeGroupLabels[modeKey] ?? [:]
                            if trimmed.isEmpty {
                                labels.removeValue(forKey: row.key)
                            } else {
                                labels[row.key] = value
                            }
                            config.modeGroupLabels[modeKey] = labels.isEmpty ? nil : labels
                        }
                    }
                }
            }
        )
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

}
