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
/// So each company contributes a muted section-head chip that toggles all of
/// its harnesses at once, followed by one chip per harness. Chips carry the
/// brand accent for the same reason the usage filters do — colour is how this
/// app says "provider" — and the rest is glass menus so a rarely-used control
/// never outweighs the list. See AGENTS.md § 7.1.
struct SessionFiltersBar: View {
    let density: Theme.Density
    @ObservedObject var model: SessionManagerModel

    var body: some View {
        Group {
            // Keep every filter in one stable horizontal strip. A narrow
            // Workbench window scrolls this strip rather than turning it into
            // a second tall control panel above the two independently
            // scrolling columns.
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    searchField
                    indexStatus
                    SectionRefreshButton(isRefreshing: model.indexProgress != nil) {
                        model.refreshIndex()
                    }
                    .help("Rescan the session logs on disk")
                    allProvidersChip
                    ForEach(chipGroups) { group in
                        HStack(spacing: 4) {
                            companyChip(group)
                            ForEach(group.harnesses, id: \.self) { harness in
                                harnessChip(harness, in: group)
                            }
                        }
                    }
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
            TextField("Search titles, projects, and message text", text: $model.searchText)
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

    /// A company disappears from the row once the index proves it has no
    /// sessions at all — but only once there *are* counts. Before the first
    /// page lands, and whenever the index is unavailable, every company shows:
    /// an empty filter row the user cannot recover from is worse than four
    /// chips that turn out to be empty.
    private var chipGroups: [Harness.ChipGroup] {
        let groups = Harness.chipGroups(companies: ToolType.coreProviderRepresentatives)
        let counts = model.harnessCounts
        guard counts.values.contains(where: { $0 > 0 }) else { return groups }
        return groups.filter { group in
            group.harnesses.contains { (counts[$0] ?? 0) > 0 }
        }
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

    /// The company section head. Deliberately quieter than the harness chips
    /// beside it — smaller, no count, barely any fill — because it is not one
    /// more thing to filter by, it is a shortcut for the harnesses it covers.
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
        .buttonStyle(.plain)
        .background(Capsule().fill(accent.opacity(selected ? 0.10 : 0.035)))
        .opacity(selected ? 1 : 0.65)
        .saturation(selected ? 1 : 0.50)
        .help(companyHelp(group))
        .accessibilityLabel("\(group.company.vendorName), every harness")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// One chip per harness — the unit a session row is actually labelled
    /// with. The icon is the harness's own brand (Cursor's mark, not Grok's,
    /// matching the badge in the list); the accent is the company's, so a
    /// group still reads as one block of colour.
    ///
    /// ⌥-click solos, which is the one-click way to ask "just this harness"
    /// without turning eight other chips off by hand.
    private func harnessChip(_ harness: Harness, in group: Harness.ChipGroup) -> some View {
        let selected = model.harnessFilter?.contains(harness) ?? true
        let count = model.harnessCounts[harness] ?? 0
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
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: max(8, density.segmentedFontSize - 3), design: .rounded)
                            .monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 28)
        }
        .buttonStyle(.plain)
        .background(chipBackground(tint: Theme.providerAccent(for: group.company), selected: selected))
        .opacity(selected ? 1 : 0.70)
        .saturation(selected ? 1 : 0.50)
        .help("\(group.company.vendorName) · \(harness.displayName)\nClick to toggle · ⌥-click to solo")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func isSelected(_ group: Harness.ChipGroup) -> Bool {
        guard let filter = model.harnessFilter else { return true }
        return group.harnesses.allSatisfy(filter.contains)
    }

    private func companyHelp(_ group: Harness.ChipGroup) -> String {
        let names = group.harnesses.map(\.displayName).joined(separator: " + ")
        return "\(group.company.vendorName) · \(names)"
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
