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
        case .muse:                  .muse
        case .museAgent:             .museAgent
        case .devin:                 .devin
        case .mistralVibe:           .mistralVibe
        }
    }

    var accent: Color { Theme.providerAccent(for: tool) }
}

/// The Workbench's Sessions page: four columns under one toolbar.
///
/// Harnesses on the left (`SessionHarnessRail`), the session list beside
/// them, the conversation in the middle, its contents on the right. The two
/// outer columns give way first when the window narrows — the harness
/// column folds to its icons, the contents column hides behind a toolbar
/// button — so the list and the conversation keep their reading widths down
/// to the window's minimum size. A split, not a scroll: the list is a place
/// you keep coming back to while reading one conversation, so it stays put.
struct SessionManagerPage: View {
    let density: Theme.Density
    let controller: SessionsPageController
    @ObservedObject private var model: SessionManagerModel
    @Environment(\.colorScheme) private var colorScheme

    init(density: Theme.Density, controller: SessionsPageController) {
        self.density = density
        self.controller = controller
        _model = ObservedObject(wrappedValue: controller.manager)
    }

    var body: some View {
        VStack(spacing: 0) {
            SessionFiltersBar(density: density, model: model, controller: controller)
                .padding(.horizontal, density.popoverPaddingH)
                .padding(.top, density.popoverPaddingV)
                .padding(.bottom, density.popoverPaddingV / 2)
            Rectangle()
                .fill(WorkbenchPorcelain.hairline(for: colorScheme))
                .frame(height: Theme.Card.hairlineWidth)
            GeometryReader { proxy in
                let layout = SessionPageLayout(
                    width: proxy.size.width,
                    railChoice: controller.railCollapsedChoice,
                    outlineChoice: controller.outlineVisibleChoice
                )
                HStack(spacing: 0) {
                    SessionHarnessRail(
                        density: density,
                        controller: controller,
                        navigation: controller.navigation,
                        isCollapsed: layout.isRailCollapsed
                    )
                    .frame(width: layout.railWidth)
                    divider
                    SessionListView(density: density, controller: controller, list: controller.list)
                        .frame(width: layout.listWidth)
                    divider
                    SessionConversationView(density: density, controller: controller, conversation: controller.conversation)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if layout.showsOutline {
                        divider
                        SessionConversationOutline(density: density, conversation: controller.conversation) {
                            controller.outlineVisibleChoice = false
                        }
                        .frame(width: SessionPageLayout.outlineWidth)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .onAppear { controller.pageWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in controller.pageWidth = width }
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
            Text(deletionMessage)
        }
        .task { controller.activate() }
    }

    private var divider: some View {
        Rectangle()
            .fill(WorkbenchPorcelain.hairline(for: colorScheme))
            .frame(width: Theme.Card.hairlineWidth)
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { model.pendingDeletion != nil },
            set: { if !$0 { model.cancelDelete() } }
        )
    }

    /// Counts every log that goes, Auto Reviews included: they are removed
    /// from disk with the session they belong to.
    private var deletionTitle: String {
        L10n.Workbench.Sessions.Delete.confirm(count: model.pendingDeletion?.count ?? 0)
    }

    /// The usual warning, plus — when the selection takes Auto Reviews with
    /// it — how many and how much disk they hold. The plan sums the bytes
    /// once, so this is string assembly, not a pass over the reviews.
    private var deletionMessage: String {
        guard let plan = model.pendingDeletion, !plan.reviews.isEmpty else {
            return L10n.Workbench.Sessions.Delete.message
        }
        return L10n.Workbench.Sessions.Delete.message
            + "\n"
            + L10n.Workbench.Sessions.Row.autoReviewsMerged(count: plan.reviews.count)
            + " · "
            + plan.reviewBytes.formatted(.byteCount(style: .file).locale(AppLocale.current))
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

/// How wide each of the page's columns is at a given page width.
///
/// The conversation keeps at least `conversationMinimum`; the contents
/// column is shown before the harness column gets its labels back, because
/// a jump list is worth more to a reader than a harness name next to an
/// icon that already says it. A reader's own toggle wins over both rules.
struct SessionPageLayout: Equatable {
    static let railExpandedWidth: CGFloat = 180
    static let railCollapsedWidth: CGFloat = 44
    static let outlineWidth: CGFloat = 220
    static let listMinimum: CGFloat = 300
    static let listMaximum: CGFloat = 400
    static let conversationMinimum: CGFloat = 520

    let isRailCollapsed: Bool
    let showsOutline: Bool
    let railWidth: CGFloat
    let listWidth: CGFloat

    /// Whether a contents column fits beside a list and a conversation at
    /// their minimum widths; narrower than this it opens as a popover.
    static func canShowOutline(width: CGFloat) -> Bool {
        width >= railCollapsedWidth + listMinimum + 440 + outlineWidth
    }

    init(width: CGFloat, railChoice: Bool?, outlineChoice: Bool?) {
        let list = min(Self.listMaximum, max(Self.listMinimum, (width * 0.32).rounded()))
        let outline = (outlineChoice ?? (width >= Self.railCollapsedWidth + list + Self.conversationMinimum + Self.outlineWidth))
            && Self.canShowOutline(width: width)
        let collapsed = railChoice
            ?? (width < Self.railExpandedWidth + list + Self.conversationMinimum + (outline ? Self.outlineWidth : 0))
        isRailCollapsed = collapsed
        showsOutline = outline
        railWidth = collapsed ? Self.railCollapsedWidth : Self.railExpandedWidth
        listWidth = list
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
    let controller: SessionsPageController
    @State private var showsDirectoryFilters = false
    @State private var showsOutlinePopover = false

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
                    rangeMenu
                    sortMenu
                    threadsMenu
                    optionsMenu
                    deleteControls
                    outlineToggle
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

    // MARK: - Threads

    /// How threads and headless runs are listed. Subagents and forks are
    /// always folded under the session that started them — the menu says so
    /// — while headless and automated runs, which nobody typed into, are
    /// switched in or out with their loaded counts beside them.
    private var threadsMenu: some View {
        let list = controller.list
        let hidden = list.hiddenCounts
        let exec = hidden[.exec] ?? 0
        let automation = hidden[.automation] ?? 0
        let totalHidden = hidden.values.reduce(0, +) - (hidden[.guardian] ?? 0)
        return Menu {
            Text(L10n.Workbench.Sessions.Threads.foldedNote)
            Divider()
            Toggle(
                L10n.Workbench.Sessions.Threads.showExec(count: AppLocale.number(list.showsExec ? execShown : exec)),
                isOn: Binding(get: { list.showsExec }, set: { list.showsExec = $0 })
            )
            Toggle(
                L10n.Workbench.Sessions.Threads.showAutomation(
                    count: AppLocale.number(list.showsAutomation ? automationShown : automation)
                ),
                isOn: Binding(get: { list.showsAutomation }, set: { list.showsAutomation = $0 })
            )
            if list.hasThreads {
                Divider()
                Button(L10n.Workbench.Sessions.Threads.expandAll) { list.setAllExpanded(true) }
                Button(L10n.Workbench.Sessions.Threads.collapseAll) { list.setAllExpanded(false) }
            }
        } label: {
            menuLabel(
                systemImage: "point.3.connected.trianglepath.dotted",
                title: L10n.Workbench.Sessions.Threads.menu,
                detail: totalHidden > 0
                    ? L10n.Workbench.Sessions.Threads.hidden(count: AppLocale.number(totalHidden))
                    : L10n.Common.all
            )
        }
        .menuStyle(.button)
        .buttonStyle(WorkbenchPillButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.Workbench.Sessions.Threads.menuHelp)
    }

    /// Rows a switched-on filter is showing, for the toggle's own count.
    private var execShown: Int { controller.list.rows.count(where: { $0.kind == .exec }) }
    private var automationShown: Int { controller.list.rows.count(where: { $0.kind == .automation }) }

    /// The contents column, from the toolbar: a toggle while there is room
    /// for it, a popover of the same list when there is not.
    private var outlineToggle: some View {
        Button {
            let layout = SessionPageLayout(
                width: controller.pageWidth,
                railChoice: controller.railCollapsedChoice,
                outlineChoice: controller.outlineVisibleChoice
            )
            if layout.showsOutline {
                controller.outlineVisibleChoice = false
            } else if SessionPageLayout.canShowOutline(width: controller.pageWidth) {
                controller.outlineVisibleChoice = true
            } else {
                showsOutlinePopover.toggle()
            }
        } label: {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: density.segmentedFontSize, weight: .semibold))
                .frame(minWidth: 18, minHeight: 26)
        }
        .buttonStyle(WorkbenchPillButtonStyle(prominent: controller.outlineVisibleChoice == true))
        .help(L10n.Workbench.Sessions.Layout.outlineHelp)
        .accessibilityLabel(L10n.Workbench.Sessions.Layout.outlineHelp)
        .popover(isPresented: $showsOutlinePopover, arrowEdge: .bottom) {
            SessionConversationOutline(density: density, conversation: controller.conversation) {
                showsOutlinePopover = false
            }
            .frame(width: 300, height: 460)
            .vibeBarNoInitialFocus()
        }
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
