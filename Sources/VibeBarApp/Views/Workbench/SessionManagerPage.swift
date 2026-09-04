import AppKit
import SwiftUI
import VibeBarCore

extension SessionProvider {
    /// The provider's identity elsewhere in the app. Every session provider
    /// is also a tool Vibe Bar tracks usage for, so brand badge, accent, and
    /// name all come from the one table rather than a second one here.
    var tool: ToolType {
        switch self {
        case .claude, .claudeCowork: .claude
        case .codex:                 .codex
        case .grok:                  .grok
        case .cursor:                .cursor
        case .gemini:                .gemini
        case .antigravity:           .antigravity
        // Grok Bot is xAI's own app; it borrows Cursor's *quota* plumbing,
        // never its brand. This is the row *tint*, so xAI's colour is the
        // right one even though the mark is Grok Bot's own — see
        // `HarnessBrandIconView`.
        case .grokBot:               .grok
        }
    }

    var accent: Color { Theme.providerAccent(for: tool) }
}

/// The Workbench's Sessions page.
///
/// A split, not a scroll: the list is a place you keep coming back to while
/// reading one transcript, so it stays put on the left instead of scrolling
/// away above the thing you selected. The toolbar above both columns is a
/// `CardShell` at the window density, which is what makes this page read as
/// the same material as Usage Stats.
struct SessionManagerPage: View {
    let density: Theme.Density
    @ObservedObject var model: SessionManagerModel

    var body: some View {
        VStack(spacing: 0) {
            SessionFiltersBar(density: density, model: model)
                .padding(.horizontal, density.popoverPaddingH)
                .padding(.top, density.popoverPaddingV)
                .padding(.bottom, density.popoverPaddingV / 2)
            HSplitView {
                SessionListView(density: density, model: model)
                    .frame(minWidth: 300, idealWidth: 380, maxWidth: 620)
                    .padding(.leading, density.popoverPaddingH)
                    .padding(.bottom, density.popoverPaddingV)
                TranscriptView(density: density, model: model)
                    .frame(minWidth: 420, maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { toastBanner }
        .confirmationDialog(
            deletionTitle,
            isPresented: deletionBinding,
            titleVisibility: .visible
        ) {
            Button(L10n.Common.delete, role: .destructive) { model.confirmDelete() }
            Button(L10n.Common.cancel, role: .cancel) { model.cancelDelete() }
        } message: {
            Text(L10n.Workbench.Sessions.Delete.message)
        }
        .task { model.activate() }
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { model.pendingDeletion != nil },
            set: { if !$0 { model.cancelDelete() } }
        )
    }

    private var deletionTitle: String {
        L10n.Workbench.Sessions.Delete.confirm(count: model.pendingDeletion?.count ?? 0)
    }

    @ViewBuilder
    private var toastBanner: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: 460)
                .workbenchOverlaySurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { model.dismissToast() }
                .accessibilityAddTraits(.isStaticText)
        }
    }
}

/// Everything that narrows the session list, plus the page's own options.
///
/// The filter unit is the **harness**, not the company: a row is labelled
/// with the harness that produced it, and two harnesses can share one adapter
/// (a Codex rollout is Codex or ChatGPT Work depending on its `originator`).
/// Company names are intentionally separated from harnesses: they are parents
/// in the billing hierarchy, not another peer filter beside Codex or Claude
/// Code. Two compact menus provide company-wide and exact-harness controls
/// without turning the toolbar into a long strip of mixed-level chips. See
/// AGENTS.md § 7.1.
struct SessionFiltersBar: View {
    let density: Theme.Density
    @ObservedObject var model: SessionManagerModel
    @State private var showsDirectoryFilters = false

    var body: some View {
        Group {
            // Keep every filter in one stable horizontal strip. A narrow
            // Workbench window scrolls this strip rather than turning it into
            // a second tall control panel above the two independently
            // scrolling columns.
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    searchField
                    searchScopeMenu
                    directoryFilterButton
                    indexStatus
                    SectionRefreshButton(isRefreshing: model.indexProgress != nil) {
                        model.refreshIndex()
                    }
                    .help(L10n.Workbench.Sessions.refreshHelp)
                    harnessPicker
                    rangeMenu
                    sortMenu
                    optionsMenu
                    deleteControls
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .workbenchToolbarSurface()
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: density.segmentedFontSize - 1))
                .foregroundStyle(.secondary)
            TextField(L10n.Workbench.Sessions.Search.placeholder, text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: max(12, density.segmentedFontSize)))
                // A text field draws nothing of its own to say keyboard focus
                // arrived; the system ring comes back for it alone.
                .vibeBarSystemControlFocus()
            if !model.searchText.isEmpty {
                BorderlessIconButton(
                    systemImage: "xmark.circle.fill",
                    help: L10n.Workbench.Sessions.Search.clearHelp
                ) {
                    model.searchText = ""
                }
            }
        }
        .padding(.horizontal, 11)
        .frame(width: 270)
        .frame(minHeight: 30)
        .workbenchFieldSurface(cornerRadius: 15)
    }

    /// What the search field covers. Titles, project folders and harness
    /// names are always searched — they are what the row shows, and a search
    /// that cannot find what is on screen is the one nobody trusts. The
    /// toggles are for what is *inside* a session, by message role, and the
    /// switch that makes those searchable at all sits right here rather than
    /// two menus away.
    private var searchScopeMenu: some View {
        let roles = SessionSearchScope.allCases.filter { $0 != .title }
        return Menu {
            Text(L10n.Workbench.Sessions.Search.metadataAlways)
            Divider()
            Section(L10n.Workbench.Sessions.Search.messagesHeading) {
                ForEach(roles, id: \.self) { scope in
                    Toggle(scopeTitle(scope), isOn: Binding(
                        get: { model.searchScopes.contains(scope) },
                        set: { _ in model.toggleSearchScope(scope) }
                    ))
                }
            }
            Divider()
            Toggle(L10n.Workbench.Sessions.Options.indexMessageText, isOn: bodyIndexingBinding)
            Text(model.isBodyIndexingEnabled
                ? L10n.Workbench.Sessions.Search.bodyIndexed
                : L10n.Workbench.Sessions.Search.bodyNotIndexed)
        } label: {
            menuLabel(
                systemImage: "text.magnifyingglass",
                title: L10n.Workbench.Sessions.Filter.scope,
                detail: AppLocale.number(roles.count(where: model.searchScopes.contains))
            )
        }
        .menuStyle(.button)
        .buttonStyle(WorkbenchPillButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var directoryFilterButton: some View {
        let active = !model.directoryIncludeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !model.directoryExcludeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button {
            showsDirectoryFilters.toggle()
        } label: {
            menuLabel(
                systemImage: "folder.badge.gearshape",
                title: L10n.Workbench.Sessions.Filter.folders,
                detail: active ? L10n.Workbench.Sessions.Filter.foldersFiltered : L10n.Common.all
            )
        }
        .buttonStyle(WorkbenchPillButtonStyle(prominent: active))
        .popover(isPresented: $showsDirectoryFilters, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.Workbench.Sessions.Folders.title)
                    .font(.headline)
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.Workbench.Sessions.Folders.include)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        L10n.Workbench.Sessions.Folders.includePlaceholder,
                        text: $model.directoryIncludeText
                    )
                    .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.Workbench.Sessions.Folders.exclude)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        L10n.Workbench.Sessions.Folders.excludePlaceholder,
                        text: $model.directoryExcludeText
                    )
                    .textFieldStyle(.roundedBorder)
                }
                Text(L10n.Workbench.Sessions.Folders.separatorHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                HStack {
                    Spacer()
                    Button(L10n.Common.clear) { model.clearDirectoryFilters() }
                    Button(L10n.Common.done) { showsDirectoryFilters = false }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .frame(width: 360)
            // A native form: no initial selection, but the system focus ring
            // comes back for its text fields and buttons.
            .vibeBarNoInitialFocus()
            .vibeBarSystemControlFocus()
        }
    }

    private func scopeTitle(_ scope: SessionSearchScope) -> String {
        switch scope {
        case .title: L10n.Workbench.Sessions.Scope.title
        case .user: L10n.Workbench.Sessions.Scope.user
        case .assistant: L10n.Workbench.Sessions.Scope.assistant
        case .system: L10n.Workbench.Sessions.Scope.system
        case .tool: L10n.Workbench.Sessions.Scope.tool
        }
    }

    @ViewBuilder
    private var indexStatus: some View {
        if let progress = model.indexProgress {
            HStack(spacing: 6) {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 70)
                Text(progress.total > 0
                    ? L10n.Workbench.Sessions.fraction(shown: progress.done, total: progress.total)
                    : L10n.Workbench.Sessions.Index.scanning)
                    .font(.system(size: max(9, density.resetCountdownFontSize - 1), design: .rounded)
                        .monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .fixedSize()
        } else {
            Text(countSummary)
                .font(.system(size: max(9, density.resetCountdownFontSize - 1), design: .rounded)
                    .monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var countSummary: String {
        guard model.isIndexAvailable else { return L10n.Workbench.Sessions.Index.unavailable }
        let shown = model.rows.count
        if model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           shown < model.totalSessionCount {
            return L10n.Workbench.Sessions.Count.shownOfTotal(
                shown: shown, total: model.totalSessionCount
            )
        }
        return L10n.Workbench.Sessions.Count.sessions(count: shown)
    }

    // MARK: - Harnesses

    /// Companies are hierarchy labels, not peers of harnesses. The filter row
    /// therefore contains only the thing it actually filters: one chip per
    /// harness, in catalog order. Empty harnesses disappear after counts load.
    private var availableHarnesses: [Harness] {
        let counts = model.harnessCounts
        guard counts.values.contains(where: { $0 > 0 }) else { return Harness.allCases }
        return Harness.allCases.filter { (counts[$0] ?? 0) > 0 }
    }

    private var availableCompanyGroups: [Harness.ChipGroup] {
        Harness.chipGroups(
            companies: ToolType.coreProviderRepresentatives,
            harnesses: availableHarnesses
        )
    }

    /// One pill, one picker: every harness grouped under its company, with
    /// the session count beside each, findable by typing any of its names.
    /// The two menus this replaces closed on every click, so narrowing to
    /// three harnesses meant opening them three times.
    private var harnessPicker: some View {
        FilterPickerButton(
            density: density,
            systemImage: "terminal",
            title: L10n.Usage.Table.Column.harness,
            detail: selectedHarnessSummary,
            prominent: model.harnessFilter != nil,
            accessibilityLabel: L10n.Usage.Table.Column.harness
        ) {
            FilterPickerList(
                density: density,
                sections: HarnessPickerRows.sections(
                    groups: availableCompanyGroups,
                    density: density,
                    detail: { AppLocale.number(model.harnessCounts[$0] ?? 0) }
                ),
                searchPlaceholder: L10n.Workbench.Filter.searchHarnesses,
                isSelected: { model.harnessFilter?.contains($0) ?? true },
                toggle: { model.toggleHarness($0) },
                solo: { model.soloHarness($0) },
                toggleGroup: { model.toggleHarnesses(Set($0)) },
                selectAll: { model.setHarnessFilter(nil) },
                selectNone: { model.setHarnessFilter([]) }
            )
        }
    }

    private var selectedHarnessSummary: String {
        guard let filter = model.harnessFilter else { return L10n.Common.all }
        let count = availableHarnesses.count(where: filter.contains)
        guard count != availableHarnesses.count else { return L10n.Common.all }
        return L10n.Workbench.Sessions.fraction(shown: count, total: availableHarnesses.count)
    }


    // MARK: - Controls

    private var rangeMenu: some View {
        Menu {
            Picker(L10n.Workbench.Sessions.Filter.dateRange, selection: $model.dateRange) {
                ForEach(SessionManagerModel.DateRange.allCases) { range in
                    Label(range.title, systemImage: range.systemImage).tag(range)
                }
            }
            .pickerStyle(.inline)
        } label: {
            menuLabel(
                systemImage: "calendar",
                title: L10n.Workbench.Sessions.Filter.when,
                detail: model.dateRange.title
            )
        }
        .menuStyle(.button)
        .buttonStyle(WorkbenchPillButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.Workbench.Sessions.Filter.whenHelp)
    }

    private var sortMenu: some View {
        Menu {
            Picker(L10n.Workbench.Sessions.Filter.sort, selection: $model.sortOrder) {
                ForEach(SessionManagerModel.SortOrder.allCases) { order in
                    Label(order.title, systemImage: order.systemImage).tag(order)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle(L10n.Workbench.Sessions.groupByProject, isOn: $model.groupByProject)
        } label: {
            menuLabel(
                systemImage: "arrow.up.arrow.down",
                title: L10n.Workbench.Sessions.Filter.sort,
                detail: model.groupByProject
                    ? L10n.Workbench.Sessions.Filter.sortGrouped(order: model.sortOrder.title)
                    : model.sortOrder.title
            )
        }
        .menuStyle(.button)
        .buttonStyle(WorkbenchPillButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.Workbench.Sessions.Filter.sortHelp)
    }

    private var optionsMenu: some View {
        Menu {
            Picker(L10n.Workbench.Sessions.Options.openIn, selection: terminalBinding) {
                ForEach(PreferredTerminal.allCases, id: \.self) { terminal in
                    Text(terminal.displayName).tag(terminal)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle(L10n.Workbench.Sessions.Options.indexMessageText, isOn: bodyIndexingBinding)
            Button(L10n.Workbench.Sessions.Options.rebuildIndex) { model.rebuildIndex() }
        } label: {
            menuLabel(
                systemImage: "slider.horizontal.3",
                title: L10n.Workbench.Sessions.Filter.options,
                detail: model.preferredTerminal.displayName
            )
        }
        .menuStyle(.button)
        .buttonStyle(WorkbenchPillButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.Workbench.Sessions.Options.help)
    }

    @ViewBuilder
    private var deleteControls: some View {
        if model.isDeleteMode {
            Button(role: .destructive) {
                model.requestDelete(model.checkedSummaries)
            } label: {
                Text(model.checkedIDs.isEmpty
                    ? L10n.Common.delete
                    : L10n.Workbench.Sessions.Delete.countButton(count: model.checkedIDs.count))
                    .font(.system(size: density.segmentedFontSize - 1, weight: .semibold))
            }
            .buttonStyle(WorkbenchPillButtonStyle(prominent: true, tint: .red))
            .disabled(model.checkedIDs.isEmpty)
            .fixedSize()
        }
        Button {
            model.isDeleteMode.toggle()
        } label: {
            Label(
                model.isDeleteMode ? L10n.Common.done : L10n.Workbench.Sessions.selectMode,
                systemImage: "checklist"
            )
                .font(.system(size: density.segmentedFontSize - 1, weight: .semibold))
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(WorkbenchPillButtonStyle())
        .fixedSize()
        .help(L10n.Workbench.Sessions.selectModeHelp)
    }

    // MARK: - Bindings and labels

    private var terminalBinding: Binding<PreferredTerminal> {
        Binding(get: { model.preferredTerminal }, set: { model.setPreferredTerminal($0) })
    }

    private var bodyIndexingBinding: Binding<Bool> {
        Binding(get: { model.isBodyIndexingEnabled }, set: { model.setBodyIndexing($0) })
    }

    private func menuLabel(systemImage: String, title: String, detail: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: max(8, density.segmentedFontSize - 2), weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title.uppercased())
                .font(.system(size: max(8, density.segmentedFontSize - 3), weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.4)
            Text(detail)
                .font(.system(size: density.segmentedFontSize - 1, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(minHeight: 28)
    }
}
