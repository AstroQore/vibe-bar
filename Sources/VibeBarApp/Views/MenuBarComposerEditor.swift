import SwiftUI
import UniformTypeIdentifiers
import VibeBarCore

/// The menu-bar strip composer.
///
/// Template, then a live preview on both menu-bar grounds, then the strip as
/// draggable chips over a remove target, then a palette of blocks to add, then
/// an inspector for whichever chip is selected.
///
/// The view owns no list logic: every insert, move, duplicate and delete is a
/// `MenuBarComposition` mutation, so what the editor does to a strip is
/// testable without a gesture. It also owns no quota resolution — the preview
/// draws `MenuBarStripView` from the same plan the status item draws, and the
/// snapshots behind it are cached per data change rather than rebuilt while
/// the user types (`AGENTS.md` § 7).
struct MenuBarComposerEditor: View {
    let kind: MenuBarItemKind
    let density: Theme.Density

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var quotaService: QuotaService

    /// Holds the subscription to the one list of things a composed strip
    /// depends on. Without it the preview drifts a generation behind the bar.
    @StateObject private var inputs = MenuBarStripInputObserver()
    @State private var selection: UUID?
    @State private var draggedTokenId: UUID?
    /// The order the strip *would* have if the drag ended here.
    ///
    /// A drag crosses several chips, and writing each crossing through
    /// `settingsStore.settings` fanned every intermediate order out to every
    /// settings subscriber and re-rendered the menu bar mid-gesture — exactly
    /// the per-tick settings write `AGENTS.md` § 7 forbids on an interaction
    /// path. The reorder is kept here while the drag is live and committed
    /// once, on drop.
    @State private var dragComposition: MenuBarComposition?
    @State private var isOverRemoveTarget = false
    @State private var isConfirmingReseed = false

    // Everything expensive is cached and rebuilt on a data change, never on a
    // keystroke: resolving a quota can compute a personal forecast, and this
    // editor re-renders on every character typed into a text block.
    @State private var snapshots: [MenuBarQuotaSnapshot] = []
    @State private var liveFieldIds: Set<String> = []
    @State private var optionsById: [String: MenuBarFieldOption] = [:]
    @State private var paletteQuotaSections: [PaletteQuotaSection] = []
    @State private var paletteLogoTools: [ToolType] = []

    private struct PaletteQuotaSection: Identifiable {
        let tool: ToolType
        let title: String
        let options: [MenuBarFieldOption]
        var id: String { "\(tool.rawValue).\(title)" }
    }

    private var item: MenuBarItemSettings { settingsStore.settings.menuBarItem(kind) }
    private var composition: MenuBarComposition { item.composition ?? MenuBarComposition() }

    /// What the editor draws: the provisional order while a drag is in
    /// flight, the committed one otherwise. The preview follows it too, so the
    /// user sees the arrangement they are about to get.
    private var displayedComposition: MenuBarComposition {
        guard draggedTokenId != nil, let dragComposition else { return composition }
        return dragComposition
    }

    /// Everything the cached snapshots are derived from.
    ///
    /// Keyed on the *requirements*, not the referenced field ids: switching a
    /// block from `.displayPercent` to `.pace` leaves the field set identical
    /// while changing the work the preview needs, and the stale snapshot would
    /// drop the block until the next quota publication even though the status
    /// item renders it at once. The display mode and colour basis are in here
    /// for the same reason — both change what a snapshot holds, and both are
    /// editable a few controls above this one.
    private struct SnapshotKey: Equatable {
        var requirements: [MenuBarQuotaRequirement]
        var displayMode: DisplayMode
        var colorBasis: MenuBarColorBasis
        var customLabels: [String: String]
    }

    private var snapshotKey: SnapshotKey {
        SnapshotKey(
            requirements: composition.quotaRequirements,
            displayMode: settingsStore.settings.displayMode,
            colorBasis: settingsStore.settings.menuBarColorBasis,
            customLabels: item.customLabels
        )
    }

    var body: some View {
        let composition = displayedComposition
        let availability = composition.availability(liveFieldIds: liveFieldIds)

        VStack(alignment: .leading, spacing: density.cardSpacing + 4) {
            templateRow(composition)
            previewRow(composition)
            stripRow(composition, availability: availability)
            paletteRow(composition)
            inspectorRow(composition, availability: availability)
            footerRow(availability: availability)
        }
        .onAppear {
            inputs.start(environment: environment)
            rebuildCatalog()
            rebuildSnapshots()
        }
        // Exactly what the status item re-renders on — one list, two
        // consumers. Subscribing to a subset of it is how the preview ended up
        // a generation behind the bar for forecasts, colours and rules.
        .onReceive(inputs.$generation) { _ in
            rebuildCatalog()
            rebuildSnapshots()
        }
        // Changing what the strip asks of a quota rebuilds; editing a word
        // does not. That is what keeps a forecast off the typing path while
        // still letting a metric swap show up immediately.
        .onChange(of: snapshotKey) { _, _ in rebuildSnapshots() }
    }

    // MARK: - Template

    private func templateRow(_ composition: MenuBarComposition) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Template", selection: templateBinding()) {
                ForEach(MenuBarComposition.Template.allCases, id: \.self) { template in
                    Text(template.title).tag(template)
                }
            }
            .pickerStyle(.segmented)
            Text(composition.template.detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Preview

    private func previewRow(_ composition: MenuBarComposition) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            caption("Preview")
            // A countdown block is wrong a minute later with no new data
            // behind it, and nothing else here invalidates the view. Gated on
            // the strip actually printing one: `QuotaClockSchedule` yields a
            // single entry and starts no timer when inactive, so a strip of
            // percentages still costs nothing. Same phase anchor the popover's
            // clocks and the status item's tick use, so the preview and the
            // bar never show two different countdowns for one quota.
            TimelineView(
                QuotaClockSchedule(
                    isActive: composition.hasTimeBasedBlock,
                    interval: MenuBarCountdownClock.interval
                )
            ) { context in
                let plan = composition.plan(
                    quotas: snapshots,
                    displayMode: settingsStore.settings.displayMode,
                    colorBasis: settingsStore.settings.menuBarColorBasis,
                    now: context.date
                )
                VStack(alignment: .leading, spacing: 4) {
                    MenuBarStripPreview(
                        plan: plan,
                        quotas: snapshots,
                        displayMode: settingsStore.settings.displayMode,
                        highlighted: selection
                    )
                    Text("Light and dark menu bars, side by side — a fixed colour that reads well on one can vanish on the other.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if plan.rows.filter({ !$0.isEmpty }).count >= 2 {
                        Text("Two rows share the menu bar's height, so large sizes are scaled down to fit — the preview scales with them.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Strip

    private func stripRow(
        _ composition: MenuBarComposition,
        availability: MenuBarComposition.Availability
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            caption("Blocks — drag to reorder")
            if composition.tokens.isEmpty {
                Text("No blocks yet. Add one from the palette below.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                MenuBarChipFlow(spacing: 5, lineSpacing: 5) {
                    ForEach(composition.tokens) { token in
                        chip(token, availability: availability)
                            .onDrag {
                                draggedTokenId = token.id
                                // Snapshot the committed order; every crossing
                                // reorders this copy, and only the drop writes.
                                dragComposition = self.composition
                                return NSItemProvider(object: token.id.uuidString as NSString)
                            }
                            .onDrop(
                                of: [.text],
                                delegate: MenuBarChipDropDelegate(
                                    target: token.id,
                                    dragged: $draggedTokenId,
                                    provisional: $dragComposition,
                                    commit: { commitDrag() }
                                )
                            )
                    }
                    // Trailing landing strip, so a block can be dragged to the
                    // very end without having to hit the last chip exactly.
                    Color.clear
                        .frame(width: 16, height: 22)
                        .contentShape(Rectangle())
                        .onDrop(
                            of: [.text],
                            delegate: MenuBarChipDropDelegate(
                                target: nil,
                                dragged: $draggedTokenId,
                                provisional: $dragComposition,
                                commit: { commitDrag() }
                            )
                        )
                }
            }
            removeTarget
        }
    }

    private var removeTarget: some View {
        HStack(spacing: 6) {
            Image(systemName: "trash")
                .font(.system(size: 10, weight: .semibold))
            Text("Drag here to remove")
                .font(.caption)
        }
        .foregroundStyle(isOverRemoveTarget ? Color.red : Color.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.red.opacity(isOverRemoveTarget ? 0.16 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    Color.red.opacity(isOverRemoveTarget ? 0.55 : 0.2),
                    style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])
                )
        )
        .onDrop(
            of: [.text],
            delegate: MenuBarChipRemoveDelegate(
                dragged: $draggedTokenId,
                isTargeted: $isOverRemoveTarget,
                selection: $selection,
                remove: { removeDragged($0) }
            )
        )
    }

    private func chip(
        _ token: MenuBarToken,
        availability: MenuBarComposition.Availability
    ) -> some View {
        let isSelected = selection == token.id
        let isSilent = availability.silentTokenIds.contains(token.id)
        let isDegraded = availability.degradedTokenIds.contains(token.id)
        return Button {
            selection = isSelected ? nil : token.id
        } label: {
            HStack(spacing: 4) {
                if case let .logo(tool) = token.kind {
                    ToolBrandIconView(tool: tool, size: 11)
                } else {
                    Image(systemName: symbol(for: token.kind))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(chipTitle(token))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                if isSilent || isDegraded {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(isSilent ? Color.orange : Color.secondary)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.14 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.10),
                        lineWidth: 0.5
                    )
            )
            .opacity(isSilent ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .help(chipHelp(token, isSilent: isSilent, isDegraded: isDegraded))
    }

    private func symbol(for kind: MenuBarToken.Kind) -> String {
        switch kind {
        case .logo: return "app.badge"
        case .text: return "textformat"
        case .quota: return "percent"
        case .space: return "space"
        case .separator: return "line.diagonal"
        case .lineBreak: return "return"
        case .appIcon: return "menubar.rectangle"
        }
    }

    private func chipTitle(_ token: MenuBarToken) -> String {
        switch token.kind {
        case let .logo(tool):
            return tool.menuTitle
        case let .text(text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Empty text" : MenuBarToken.truncated(trimmed)
        case let .quota(fieldId, metric):
            let name = optionsById[fieldId]?.defaultLabel ?? fieldId
            return "\(name) · \(metric.title)"
        case .space:
            return "Space"
        case let .separator(separator):
            let trimmed = separator.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Gap" : trimmed
        case .lineBreak:
            return "New row"
        case .appIcon:
            return "Vibe Bar icon"
        }
    }

    private func chipHelp(_ token: MenuBarToken, isSilent: Bool, isDegraded: Bool) -> String {
        if isSilent {
            return "This quota is not being returned right now, so this block draws nothing. "
                + "It stays here and comes back on its own."
        }
        if isDegraded {
            return "This block still draws, but a colour or a rule on it points at a quota "
                + "that is not being returned right now."
        }
        return chipTitle(token)
    }

    // MARK: - Palette

    private func paletteRow(_ composition: MenuBarComposition) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            caption("Add a block")
            paletteGroup("Logo") {
                paletteButton(title: "Vibe Bar", icon: "menubar.rectangle") {
                    add(MenuBarToken(kind: .appIcon, style: .label))
                }
                ForEach(paletteLogoTools, id: \.self) { tool in
                    paletteButton(title: tool.menuTitle, icon: nil, tool: tool) {
                        add(MenuBarToken(kind: .logo(tool), style: .label))
                    }
                }
            }
            paletteGroup("Text") {
                paletteButton(title: "Text", icon: "textformat") {
                    add(MenuBarToken(kind: .text("Label"), style: .label))
                }
            }
            paletteGroup("Quota") {
                ForEach(paletteQuotaSections) { section in
                    Menu {
                        ForEach(section.options) { option in
                            Button(option.title) {
                                add(MenuBarToken(
                                    kind: .quota(fieldId: option.id, metric: .displayPercent),
                                    style: .percent
                                ))
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            ToolBrandIconView(tool: section.tool, size: 11)
                            Text(section.title).font(.system(size: 11, weight: .medium))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            paletteGroup("Structure") {
                paletteButton(title: "Space", icon: "space") {
                    add(MenuBarToken(kind: .space))
                }
                paletteButton(title: "Separator", icon: "line.diagonal") {
                    add(MenuBarToken(kind: .separator(" · "), style: .divider))
                }
                paletteButton(title: "New row", icon: "return") {
                    add(MenuBarToken(kind: .lineBreak))
                }
                // Two rows is all the status item can draw; offering a third
                // break would build a row the bar silently folds away.
                .disabled(!composition.canAddLineBreak)
                .help(
                    composition.canAddLineBreak
                        ? "Split the strip into a second row."
                        : "The menu bar can only draw two rows."
                )
            }
        }
    }

    private func paletteGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .leading)
                .padding(.top, 4)
            MenuBarChipFlow(spacing: 5, lineSpacing: 5) {
                content()
            }
        }
    }

    private func paletteButton(
        title: String,
        icon: String?,
        tool: ToolType? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let tool {
                    ToolBrandIconView(tool: tool, size: 11)
                } else if let icon {
                    Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                }
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Inspector

    @ViewBuilder
    private func inspectorRow(
        _ composition: MenuBarComposition,
        availability: MenuBarComposition.Availability
    ) -> some View {
        if let id = selection, let token = composition.token(id) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    caption("Selected block")
                    Spacer(minLength: 8)
                    Button("Duplicate") { mutate { $0.duplicate(id) } }
                        .buttonStyle(.vibeBar)
                    Button("Remove") {
                        selection = nil
                        mutate { $0.remove(id) }
                    }
                    .buttonStyle(.vibeBar)
                }
                if availability.silentTokenIds.contains(id) {
                    warning("This quota is not being returned right now, so the block draws nothing. Nothing is broken — it reappears when the provider answers again.")
                } else if availability.degradedTokenIds.contains(id) {
                    warning("A colour or rule on this block points at a quota that is not being returned right now, so that part falls back.")
                }
                MenuBarTokenInspector(
                    token: token,
                    options: sortedOptions,
                    liveFieldIds: liveFieldIds,
                    apply: { updated in
                        mutate { composed in
                            guard let index = composed.index(of: updated.id) else { return }
                            composed.tokens[index] = updated
                        }
                    }
                )
                // Selecting a different chip is a different inspector, so its
                // colour-well draft starts from that block rather than from
                // whatever the last one was.
                .id(token.id)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    private func footerRow(availability: MenuBarComposition.Availability) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !availability.isFullyAvailable {
                warning(
                    "Not answering right now: "
                        + availability.missingFieldIds
                            .map { optionsById[$0]?.title ?? $0 }
                            .joined(separator: ", ")
                        + "."
                )
            }
            HStack(spacing: 8) {
                Button("Start over from the current strip…") { isConfirmingReseed = true }
                    .buttonStyle(.vibeBar)
                Spacer(minLength: 8)
            }
            Text("Starting over replaces every block with a fresh copy of the default strip. There is no undo.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog(
            "Replace your blocks?",
            isPresented: $isConfirmingReseed,
            titleVisibility: .visible
        ) {
            Button("Start over", role: .destructive) {
                selection = nil
                var updated = item
                updated.reseedComposedStrip(
                    template: composition.template,
                    registry: quotaService.fieldRegistry,
                    groupCatalogLabel: MiniWindowGroupLabelCatalog.defaultLabel(for:)
                )
                settingsStore.settings.setMenuBarItem(updated)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every block you arranged is discarded and rebuilt from the default strip.")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .tracking(0.4)
    }

    // MARK: - Mutations

    private func mutate(_ change: (inout MenuBarComposition) -> Void) {
        // A real edit ends any drag state: the provisional order must never
        // outlive the arrangement it was based on.
        dragComposition = nil
        draggedTokenId = nil
        var updated = item
        var composed = updated.composition ?? MenuBarComposition(isEnabled: true)
        change(&composed)
        updated.composition = composed
        settingsStore.settings.setMenuBarItem(updated)
    }

    /// The one settings write a completed drag performs.
    private func commitDrag() {
        guard let reordered = dragComposition else {
            draggedTokenId = nil
            return
        }
        let tokens = reordered.tokens
        // `mutate` clears the drag state before writing.
        mutate { $0.tokens = tokens }
    }

    private func removeDragged(_ id: UUID) {
        if selection == id { selection = nil }
        // Start from the provisional order when there is one, so a block that
        // was dragged across the strip and then onto the bin does not
        // resurrect the intermediate order it passed through.
        let base = dragComposition ?? composition
        var tokens = base.tokens
        tokens.removeAll { $0.id == id }
        mutate { $0.tokens = tokens }
    }

    private func add(_ token: MenuBarToken) {
        mutate { $0.append(token) }
        selection = token.id
    }

    private func templateBinding() -> Binding<MenuBarComposition.Template> {
        Binding(
            get: { composition.template },
            // Changing the template re-styles the strip, never its contents:
            // the blocks the user arranged are theirs. "Start over" is the
            // control that rebuilds them, and it asks first.
            set: { template in mutate { $0.template = template } }
        )
    }

    // MARK: - Caches

    private var sortedOptions: [MenuBarFieldOption] {
        paletteQuotaSections.flatMap(\.options)
    }

    private func rebuildCatalog() {
        let merged = MenuBarFieldCatalog.mergedFields(registry: quotaService.fieldRegistry)
        optionsById = Dictionary(merged.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        liveFieldIds = MenuBarStripResolver.liveFieldIds(environment: environment)

        var sections: [PaletteQuotaSection] = []
        for tool in ToolType.dedicatedCardProviders {
            let options = merged.filter { $0.tool == tool }
            guard !options.isEmpty else { continue }
            // One entry per L2 SubProvider, so Grok Bot is not filed under
            // Cursor — the quota axis, as `AGENTS.md` § 7.1 requires.
            var bySubProvider: [(name: String, options: [MenuBarFieldOption])] = []
            for option in options {
                let name = tool.quotaSubProviderName(bucketID: option.bucketId)
                if let index = bySubProvider.firstIndex(where: { $0.name == name }) {
                    bySubProvider[index].options.append(option)
                } else {
                    bySubProvider.append((name, [option]))
                }
            }
            for group in bySubProvider {
                sections.append(PaletteQuotaSection(
                    tool: tool,
                    title: group.name,
                    options: group.options
                ))
            }
        }
        paletteQuotaSections = sections
        paletteLogoTools = ToolType.dedicatedCardProviders
    }

    private func rebuildSnapshots() {
        snapshots = MenuBarStripResolver.snapshots(
            for: composition,
            itemSettings: item,
            settings: settingsStore.settings,
            environment: environment
        )
        liveFieldIds = MenuBarStripResolver.liveFieldIds(environment: environment)
    }
}

// MARK: - Inspector

/// Controls for one block. Split out so the editor's own body does not
/// re-evaluate every palette section and every chip when a slider moves.
private struct MenuBarTokenInspector: View {
    let token: MenuBarToken
    let options: [MenuBarFieldOption]
    let liveFieldIds: Set<String>
    let apply: (MenuBarToken) -> Void

    @State private var fixedDraft: Color = .accentColor

    private enum ColorChoice: String, CaseIterable, Identifiable {
        case automatic, forecast, followsQuota, brand, primary, secondary, tertiary, fixed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .forecast: return "Forecast"
            case .followsQuota: return "Follow a quota"
            case .brand: return "Brand"
            case .primary: return "Primary"
            case .secondary: return "Secondary"
            case .tertiary: return "Tertiary"
            case .fixed: return "Custom…"
            }
        }
    }

    private enum RuleChoice: String, CaseIterable, Identifiable {
        case always, whenUsedAtLeast, whenRemainingAtMost, whenForecast
        var id: String { rawValue }
        var title: String {
            switch self {
            case .always: return "Always"
            case .whenUsedAtLeast: return "When used is at least"
            case .whenRemainingAtMost: return "When remaining is at most"
            case .whenForecast: return "When the forecast says"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            contentControls
            Divider().opacity(0.4)
            colorControls
            HStack(spacing: 10) {
                Picker("Size", selection: sizeBinding) {
                    ForEach(MenuBarToken.SizeStep.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .frame(width: 150)
                Picker("Weight", selection: weightBinding) {
                    ForEach(MenuBarToken.Weight.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .frame(width: 165)
            }
            Toggle("Monospaced digits", isOn: monospacedBinding)
                .help("Keeps a changing number from shifting the blocks beside it.")
            Divider().opacity(0.4)
            ruleControls
        }
        .font(.system(size: 11.5))
    }

    // MARK: Content

    @ViewBuilder
    private var contentControls: some View {
        switch token.kind {
        case let .text(text):
            HStack(spacing: 8) {
                Text("Text").frame(width: 62, alignment: .leading)
                DebouncedSettingsTextField(
                    prompt: "Label",
                    value: Binding(
                        get: { text },
                        set: { value in
                            // Truncation is a drawing rule, not an input rule:
                            // the block keeps what was typed and the bar shows
                            // as much of it as fits.
                            update { $0.kind = .text(value) }
                        }
                    )
                )
            }
            Text("Blocks longer than \(MenuBarToken.maximumTextLength) characters are cut short with an ellipsis in the bar.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case let .separator(separator):
            HStack(spacing: 8) {
                Text("Separator").frame(width: 62, alignment: .leading)
                DebouncedSettingsTextField(
                    prompt: " · ",
                    value: Binding(
                        get: { separator },
                        set: { value in update { $0.kind = .separator(value) } }
                    )
                )
            }
        case let .quota(fieldId, metric):
            HStack(spacing: 8) {
                Text("Quota").frame(width: 62, alignment: .leading)
                fieldPicker(selected: fieldId) { newId in
                    update { $0.kind = .quota(fieldId: newId, metric: metric) }
                }
            }
            HStack(spacing: 8) {
                Text("Shows").frame(width: 62, alignment: .leading)
                Picker("", selection: Binding(
                    get: { metric },
                    set: { value in update { $0.kind = .quota(fieldId: fieldId, metric: value) } }
                )) {
                    ForEach(MenuBarQuotaMetric.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 220)
            }
        case let .logo(tool):
            HStack(spacing: 8) {
                Text("Provider").frame(width: 62, alignment: .leading)
                Picker("", selection: Binding(
                    get: { tool },
                    set: { value in update { $0.kind = .logo(value) } }
                )) {
                    ForEach(ToolType.dedicatedCardProviders, id: \.self) {
                        Text($0.menuTitle).tag($0)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
        case .space:
            // Nothing to configure until the model grows a width; size and
            // colour below still apply to the gap it draws.
            Text("A gap one space wide. Size changes how wide.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .lineBreak:
            Text("Ends the first row and starts the second.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .appIcon:
            Text("Vibe Bar's own icon — what the Icon Only layout shows.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Colour

    @ViewBuilder
    private var colorControls: some View {
        HStack(spacing: 8) {
            Text("Colour").frame(width: 62, alignment: .leading)
            Picker("", selection: colorChoiceBinding) {
                ForEach(ColorChoice.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 165)
            switch token.style.color {
            case let .brand(tool):
                Picker("", selection: Binding(
                    get: { tool },
                    set: { value in update { $0.style.color = .brand(value) } }
                )) {
                    // The same table `.brand` resolves through, so a swatch
                    // here cannot promise a colour the bar will not paint.
                    ForEach(ToolType.dedicatedCardProviders, id: \.self) { candidate in
                        Label {
                            Text(candidate.menuTitle)
                        } icon: {
                            Circle().fill(Theme.providerAccent(for: candidate))
                        }
                        .tag(candidate)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            case .fixed:
                ColorPicker("", selection: $fixedDraft, supportsOpacity: false)
                    .labelsHidden()
                    // Dragging inside a colour well fires continuously; commit
                    // on an idle window so a drag is one settings write rather
                    // than a hundred.
                    .task(id: fixedDraft) {
                        try? await Task.sleep(for: .milliseconds(250))
                        guard !Task.isCancelled else { return }
                        commitFixedColor()
                    }
            case let .followsQuota(fieldId, basis):
                fieldPicker(selected: fieldId) { newId in
                    update { $0.style.color = .followsQuota(fieldId: newId, basis: basis) }
                }
                Picker("", selection: Binding(
                    get: { basis },
                    set: { value in
                        update { $0.style.color = .followsQuota(fieldId: fieldId, basis: value) }
                    }
                )) {
                    ForEach(MenuBarColorBasis.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
            default:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
        .onAppear(perform: syncFixedDraft)
        // Switching the colour role to Custom writes a starting hex; the well
        // has to follow it, or it would show one colour while the block wears
        // another.
        .onChange(of: token.style.color) { _, _ in syncFixedDraft() }
    }

    private func syncFixedDraft() {
        guard case let .fixed(hex) = token.style.color,
              let parts = MenuBarHexColor.components(hex)
        else { return }
        fixedDraft = Color(.sRGB, red: parts.r, green: parts.g, blue: parts.b, opacity: parts.a)
    }

    private func commitFixedColor() {
        guard case .fixed = token.style.color else { return }
        let resolved = NSColor(fixedDraft).usingColorSpace(.sRGB) ?? NSColor(fixedDraft)
        let hex = String(
            format: "#%02x%02x%02x",
            Int((resolved.redComponent * 255).rounded()),
            Int((resolved.greenComponent * 255).rounded()),
            Int((resolved.blueComponent * 255).rounded())
        )
        guard case let .fixed(current) = token.style.color, current != hex else { return }
        update { $0.style.color = .hex(hex) }
    }

    // MARK: Rule

    @ViewBuilder
    private var ruleControls: some View {
        HStack(spacing: 8) {
            Text("Show").frame(width: 62, alignment: .leading)
            Picker("", selection: ruleChoiceBinding) {
                ForEach(RuleChoice.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 210)
            Spacer(minLength: 0)
        }
        switch token.visibility {
        case .always:
            EmptyView()
        case let .whenUsedAtLeast(fieldId, percent):
            thresholdRow(fieldId: fieldId, percent: percent) { newId, newPercent in
                update { $0.visibility = .whenUsedAtLeast(fieldId: newId, percent: newPercent) }
            }
        case let .whenRemainingAtMost(fieldId, percent):
            thresholdRow(fieldId: fieldId, percent: percent) { newId, newPercent in
                update { $0.visibility = .whenRemainingAtMost(fieldId: newId, percent: newPercent) }
            }
        case let .whenForecast(fieldId, verdicts):
            HStack(spacing: 8) {
                Text("Quota").frame(width: 62, alignment: .leading)
                fieldPicker(selected: fieldId) { newId in
                    update { $0.visibility = .whenForecast(fieldId: newId, verdicts: verdicts) }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Text("Verdicts").frame(width: 62, alignment: .leading)
                ForEach(Self.selectableVerdicts, id: \.self) { verdict in
                    Toggle(Self.verdictTitle(verdict), isOn: Binding(
                        get: { verdicts.contains(verdict) },
                        set: { on in
                            var next = verdicts
                            if on { next.insert(verdict) } else { next.remove(verdict) }
                            // An empty set would hide the block forever, which
                            // is not a state the editor should let anyone
                            // build; it reads as "no rule" instead.
                            update {
                                $0.visibility = next.isEmpty
                                    ? .always
                                    : .whenForecast(fieldId: fieldId, verdicts: next)
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private static let selectableVerdicts: [QuotaPaceForecast.Verdict] =
        [.atRisk, .watch, .enough, .surplus]

    private static func verdictTitle(_ verdict: QuotaPaceForecast.Verdict) -> String {
        switch verdict {
        case .atRisk: return "At risk"
        case .watch: return "Watch"
        case .enough: return "Enough"
        case .surplus: return "Surplus"
        case .learning: return "Learning"
        }
    }

    private func thresholdRow(
        fieldId: String,
        percent: Double,
        set: @escaping (String, Double) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text("Quota").frame(width: 62, alignment: .leading)
            fieldPicker(selected: fieldId) { newId in set(newId, percent) }
            DebouncedPercentStepper(percent: percent) { set(fieldId, $0) }
            Spacer(minLength: 0)
        }
    }

    private func fieldPicker(
        selected: String,
        set: @escaping (String) -> Void
    ) -> some View {
        Picker("", selection: Binding(get: { selected }, set: set)) {
            // A field the strip names but the catalog no longer lists still
            // needs a row, or selecting it would silently jump elsewhere.
            if !options.contains(where: { $0.id == selected }) {
                Text(selected).tag(selected)
            }
            ForEach(options) { option in
                Text(liveFieldIds.contains(option.id) ? option.title : "\(option.title) (offline)")
                    .tag(option.id)
            }
        }
        .labelsHidden()
        .frame(width: 210)
    }

    // MARK: Bindings

    private func update(_ change: (inout MenuBarToken) -> Void) {
        var updated = token
        change(&updated)
        guard updated != token else { return }
        apply(updated)
    }

    private var colorChoiceBinding: Binding<ColorChoice> {
        Binding(
            get: {
                switch token.style.color {
                case .automatic: return .automatic
                case .forecast: return .forecast
                case .followsQuota: return .followsQuota
                case .brand: return .brand
                case .primary: return .primary
                case .secondary: return .secondary
                case .tertiary: return .tertiary
                case .fixed: return .fixed
                }
            },
            set: { choice in
                let fallbackField = token.quotaFieldId ?? options.first?.id
                update { edited in
                    switch choice {
                    case .automatic: edited.style.color = .automatic
                    case .forecast: edited.style.color = .forecast
                    case .followsQuota:
                        guard let fallbackField else { return }
                        edited.style.color = .followsQuota(fieldId: fallbackField, basis: .forecast)
                    case .brand:
                        if case let .logo(tool) = edited.kind {
                            edited.style.color = .brand(tool)
                        } else {
                            edited.style.color = .brand(ToolType.dedicatedCardProviders.first ?? .claude)
                        }
                    case .primary: edited.style.color = .primary
                    case .secondary: edited.style.color = .secondary
                    case .tertiary: edited.style.color = .tertiary
                    case .fixed: edited.style.color = .hex("#7f7f7f")
                    }
                }
            }
        )
    }

    private var ruleChoiceBinding: Binding<RuleChoice> {
        Binding(
            get: {
                switch token.visibility {
                case .always: return .always
                case .whenUsedAtLeast: return .whenUsedAtLeast
                case .whenRemainingAtMost: return .whenRemainingAtMost
                case .whenForecast: return .whenForecast
                }
            },
            set: { choice in
                let field = token.visibility.fieldId ?? token.quotaFieldId ?? options.first?.id
                update { edited in
                    switch choice {
                    case .always:
                        edited.visibility = .always
                    case .whenUsedAtLeast:
                        guard let field else { return }
                        edited.visibility = .whenUsedAtLeast(fieldId: field, percent: 80)
                    case .whenRemainingAtMost:
                        guard let field else { return }
                        edited.visibility = .whenRemainingAtMost(fieldId: field, percent: 20)
                    case .whenForecast:
                        guard let field else { return }
                        edited.visibility = .whenForecast(fieldId: field, verdicts: [.atRisk, .watch])
                    }
                }
            }
        )
    }

    private var sizeBinding: Binding<MenuBarToken.SizeStep> {
        Binding(get: { token.style.size }, set: { value in update { $0.style.size = value } })
    }

    private var weightBinding: Binding<MenuBarToken.Weight> {
        Binding(get: { token.style.weight }, set: { value in update { $0.style.weight = value } })
    }

    private var monospacedBinding: Binding<Bool> {
        Binding(
            get: { token.style.monospacedDigits },
            set: { value in update { $0.style.monospacedDigits = value } }
        )
    }
}

/// A percent stepper that writes settings on an idle window rather than on
/// every repeat.
///
/// A held stepper auto-repeats, and each repeat used to publish `AppSettings`
/// — a fan-out to every subscriber, plus a menu-bar re-render, ten times a
/// second. Same discipline as `DebouncedSettingsTextField` and the colour
/// well: the control tracks its own draft and commits once the user stops.
private struct DebouncedPercentStepper: View {
    let percent: Double
    let commit: (Double) -> Void

    @State private var draft: Double = 0

    var body: some View {
        Stepper(value: $draft, in: 0...100, step: 5) {
            Text("\(Int(draft.rounded()))%")
                .font(.system(size: 11.5).monospacedDigit())
                .frame(width: 42, alignment: .trailing)
        }
        .onAppear { draft = percent }
        // An external write — selecting another block, a reset — replaces a
        // draft the user is not in the middle of changing.
        .onChange(of: percent) { _, updated in
            if updated != draft { draft = updated }
        }
        .task(id: draft) {
            guard draft != percent else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            commit(draft)
        }
    }
}

// MARK: - Drag and drop

/// Reorder onto a chip, or onto the trailing landing strip when `target` is
/// nil. The move itself is `MenuBarComposition.move`, so the delegate decides
/// only *where*, never *how*.
private struct MenuBarChipDropDelegate: DropDelegate {
    let target: UUID?
    @Binding var dragged: UUID?
    /// Reordered in place on every crossing. Local state, not settings.
    @Binding var provisional: MenuBarComposition?
    let commit: () -> Void

    func dropEntered(info: DropInfo) {
        guard let dragged, provisional != nil else { return }
        if let target {
            provisional?.move(dragged, before: target)
        } else {
            provisional?.move(dragged, to: provisional?.tokens.count ?? 0)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        commit()
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

private struct MenuBarChipRemoveDelegate: DropDelegate {
    @Binding var dragged: UUID?
    @Binding var isTargeted: Bool
    @Binding var selection: UUID?
    let remove: (UUID) -> Void

    func dropEntered(info: DropInfo) { isTargeted = true }

    func dropExited(info: DropInfo) { isTargeted = false }

    func performDrop(info: DropInfo) -> Bool {
        defer { isTargeted = false }
        guard let dragged else { return false }
        remove(dragged)
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - Layout

/// Left-to-right wrapping row of chips.
///
/// The strip and the palette are both "as many small things as fit, then wrap"
/// — a `LazyVGrid` would force a column width every chip has to live inside,
/// which is wrong for labels that range from "Space" to "Claude Weekly · Runs
/// out in".
struct MenuBarChipFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        // An unspecified *or* infinite proposal means "how wide do you want to
        // be" — answering `.infinity` there makes the whole settings column
        // grow without bound.
        let proposed = proposal.width
        let maxWidth = (proposed?.isFinite ?? false) ? proposed! : .infinity
        let rows = lines(subviews: subviews, maxWidth: maxWidth)
        let height = rows.reduce(0) { $0 + $1.height } +
            lineSpacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: maxWidth.isFinite ? maxWidth : widest, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        var y = bounds.minY
        for row in lines(subviews: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(subviews: Subviews, maxWidth: CGFloat) -> [Line] {
        var rows: [Line] = []
        var current = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let advance = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, advance > maxWidth {
                rows.append(current)
                current = Line()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = advance
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
