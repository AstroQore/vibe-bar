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
        // never its brand. See `Harness.brandTool`.
        case .grokBot:               .grok
        }
    }

    var accent: Color { Theme.providerAccent(for: tool) }
}

extension Harness {
    /// The brand this harness is drawn as — its own L2 tool, not the L1
    /// company. Cursor gets the Cursor mark rather than Grok's, and
    /// AntiGravity its own rather than Gemini's, while the *chip* that
    /// groups them still says "SpaceXAI" / "Google AI".
    ///
    /// Grok Bot is the one harness whose quota tool is the wrong answer: its
    /// weekly bucket rides in on Cursor's adapter, but a Grok Bot session was
    /// produced by an xAI app and drawing it with Cursor's mark would say it
    /// came from Cursor. There is no Grok Bot asset in `Resources/ProviderIcons`,
    /// so it wears the Grok mark — the nearest brand that is actually true.
    var brandTool: ToolType {
        self == .grokBot ? .grok : quotaTool
    }
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
            Button("Delete", role: .destructive) { model.confirmDelete() }
            Button("Cancel", role: .cancel) { model.cancelDelete() }
        } message: {
            Text("The session logs are removed from disk. This cannot be undone.")
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
        let count = model.pendingDeletion?.count ?? 0
        return count == 1 ? "Delete this session?" : "Delete \(count) sessions?"
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
                    .help("Rescan the session logs on disk")
                    allProvidersChip
                    companyFilterMenu
                    harnessFilterMenu
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
            TextField("Search sessions", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: max(12, density.segmentedFontSize)))
            if !model.searchText.isEmpty {
                BorderlessIconButton(systemImage: "xmark.circle.fill", help: "Clear the search") {
                    model.searchText = ""
                }
            }
        }
        .padding(.horizontal, 11)
        .frame(width: 270)
        .frame(minHeight: 30)
        .workbenchFieldSurface(cornerRadius: 15)
    }

    private var searchScopeMenu: some View {
        Menu {
            ForEach(SessionSearchScope.allCases, id: \.self) { scope in
                Toggle(scopeTitle(scope), isOn: Binding(
                    get: { model.searchScopes.contains(scope) },
                    set: { _ in model.toggleSearchScope(scope) }
                ))
            }
            Divider()
            Text(model.isBodyIndexingEnabled
                ? "Message text is indexed locally."
                : "Enable message indexing in Options to search transcript content.")
        } label: {
            menuLabel(
                systemImage: "text.magnifyingglass",
                title: "Scope",
                detail: "\(model.searchScopes.count)"
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
            menuLabel(systemImage: "folder.badge.gearshape", title: "Folders", detail: active ? "Filtered" : "All")
        }
        .buttonStyle(WorkbenchPillButtonStyle(prominent: active))
        .popover(isPresented: $showsDirectoryFilters, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Directory filters")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Include paths containing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("/project/a, /project/b", text: $model.directoryIncludeText)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Exclude paths containing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("/archive, /vendor", text: $model.directoryExcludeText)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Separate multiple paths with commas, semicolons, or new lines.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                HStack {
                    Spacer()
                    Button("Clear") { model.clearDirectoryFilters() }
                    Button("Done") { showsDirectoryFilters = false }
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
        case .title: "Titles and session IDs"
        case .user: "User prompts"
        case .assistant: "Assistant replies"
        case .system: "System prompts"
        case .tool: "Tool and file operations"
        }
    }

    @ViewBuilder
    private var indexStatus: some View {
        if let progress = model.indexProgress {
            HStack(spacing: 6) {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 70)
                Text(progress.total > 0 ? "\(progress.done)/\(progress.total)" : "scanning…")
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
        guard model.isIndexAvailable else { return "index unavailable" }
        let shown = model.rows.count
        if model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           shown < model.totalSessionCount {
            return "\(shown) of \(model.totalSessionCount) sessions"
        }
        return shown == 1 ? "1 session" : "\(shown) sessions"
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

    /// The All chip is a switch, not a shortcut: lit means every harness is
    /// listed and clicking it clears the selection outright; anything else
    /// and it puts every harness back.
    private var allProvidersChip: some View {
        let selected = model.harnessFilter == nil
        return Button {
            model.toggleAllHarnesses()
        } label: {
            Text("All")
                .font(.system(size: max(10, density.segmentedFontSize - 1), weight: .semibold))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 10)
                .frame(minHeight: 28)
        }
        .buttonStyle(.plain)
        .background(chipBackground(tint: .accentColor, selected: selected))
        .help(selected ? "Click to select no harness" : "Click to show sessions from every harness")
        .accessibilityLabel(selected ? "Select no harness" : "Show every session source")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// L1 companies and harnesses are separate compact menus: the company
    /// remains a batch control, while the row no longer pretends OpenAI and
    /// Codex are peers or consumes the entire toolbar with nine chips.
    private var companyFilterMenu: some View {
        Menu {
            ForEach(availableCompanyGroups) { group in
                Toggle(group.company.vendorName, isOn: Binding(
                    get: { isSelected(group) },
                    set: { _ in model.toggleHarnesses(group.harnessSet) }
                ))
            }
        } label: {
            menuLabel(
                systemImage: "building.2",
                title: "Company",
                detail: selectedCompanySummary
            )
        }
        .menuStyle(.button)
        .buttonStyle(WorkbenchPillButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var harnessFilterMenu: some View {
        Menu {
            ForEach(availableHarnesses, id: \.self) { harness in
                Toggle(isOn: Binding(
                    get: { model.harnessFilter?.contains(harness) ?? true },
                    set: { _ in model.toggleHarness(harness) }
                )) {
                    Label {
                        Text("\(harness.displayName)  \(model.harnessCounts[harness] ?? 0)")
                    } icon: {
                        ToolBrandIconView(tool: harness.brandTool, size: 12)
                    }
                }
            }
        } label: {
            menuLabel(
                systemImage: "terminal",
                title: "Harness",
                detail: selectedHarnessSummary
            )
        }
        .menuStyle(.button)
        .buttonStyle(WorkbenchPillButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func isSelected(_ group: Harness.ChipGroup) -> Bool {
        guard let filter = model.harnessFilter else { return true }
        return group.harnesses.allSatisfy(filter.contains)
    }

    private var selectedCompanySummary: String {
        let selected = availableCompanyGroups.count(where: isSelected)
        return selected == availableCompanyGroups.count ? "All" : "\(selected)/\(availableCompanyGroups.count)"
    }

    private var selectedHarnessSummary: String {
        guard let filter = model.harnessFilter else { return "All" }
        let count = availableHarnesses.count(where: filter.contains)
        return count == availableHarnesses.count ? "All" : "\(count)/\(availableHarnesses.count)"
    }

    private func chipBackground(tint: Color, selected: Bool) -> some View {
        ZStack {
            Capsule().fill(tint.opacity(selected ? 0.16 : 0.05))
            Capsule().stroke(tint.opacity(selected ? 0.55 : 0.18), lineWidth: 0.8)
        }
    }

    // MARK: - Controls

    private var rangeMenu: some View {
        Menu {
            Picker("Date range", selection: $model.dateRange) {
                ForEach(SessionManagerModel.DateRange.allCases) { range in
                    Label(range.title, systemImage: range.systemImage).tag(range)
                }
            }
            .pickerStyle(.inline)
        } label: {
            menuLabel(systemImage: "calendar", title: "When", detail: model.dateRange.title)
        }
        .menuStyle(.button)
        .buttonStyle(WorkbenchPillButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Choose how far back to list sessions")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $model.sortOrder) {
                ForEach(SessionManagerModel.SortOrder.allCases) { order in
                    Label(order.title, systemImage: order.systemImage).tag(order)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Group by project", isOn: $model.groupByProject)
        } label: {
            menuLabel(
                systemImage: "arrow.up.arrow.down",
                title: "Sort",
                detail: model.groupByProject ? "\(model.sortOrder.title) · grouped" : model.sortOrder.title
            )
        }
        .menuStyle(.button)
        .buttonStyle(WorkbenchPillButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Choose how the list is ordered")
    }

    private var optionsMenu: some View {
        Menu {
            Picker("Open in", selection: terminalBinding) {
                ForEach(PreferredTerminal.allCases, id: \.self) { terminal in
                    Text(terminal.displayName).tag(terminal)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Index message text", isOn: bodyIndexingBinding)
            Button("Rebuild index…") { model.rebuildIndex() }
        } label: {
            menuLabel(systemImage: "slider.horizontal.3", title: "Options", detail: model.preferredTerminal.displayName)
        }
        .menuStyle(.button)
        .buttonStyle(WorkbenchPillButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Terminal and index options")
    }

    @ViewBuilder
    private var deleteControls: some View {
        if model.isDeleteMode {
            Button(role: .destructive) {
                model.requestDelete(model.checkedSummaries)
            } label: {
                Text(model.checkedIDs.isEmpty ? "Delete" : "Delete \(model.checkedIDs.count)")
                    .font(.system(size: density.segmentedFontSize - 1, weight: .semibold))
            }
            .buttonStyle(WorkbenchPillButtonStyle(prominent: true, tint: .red))
            .disabled(model.checkedIDs.isEmpty)
            .fixedSize()
        }
        Button {
            model.isDeleteMode.toggle()
        } label: {
            Label(model.isDeleteMode ? "Done" : "Select", systemImage: "checklist")
                .font(.system(size: density.segmentedFontSize - 1, weight: .semibold))
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(WorkbenchPillButtonStyle())
        .fixedSize()
        .help("Pick sessions to delete")
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
