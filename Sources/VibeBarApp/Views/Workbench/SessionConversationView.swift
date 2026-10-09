import SwiftUI
import VibeBarCore

/// The Sessions page's conversation column: the session's masthead, then
/// its turns — or, for a provider the turn view cannot read (and on
/// request), the raw transcript.
///
/// The pane draws only what `SessionConversationModel` has prepared: the
/// render list is precomputed rows with stable ids, so scrolling a long
/// conversation builds the rows that come into view and nothing else, and a
/// row that did not change is never re-evaluated.
struct SessionConversationView: View {
    let density: Theme.Density
    let controller: SessionsPageController
    let conversation: SessionConversationModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let summary = conversation.summary {
                // The masthead is an inset of the content, not its sibling in
                // a stack: a stack sizes its children by asking each one what
                // it would like to be, and a scroll view answers that by
                // measuring its whole content — every row of the lazy list.
                content(for: summary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            SessionConversationHeader(
                                density: density,
                                controller: controller,
                                conversation: conversation,
                                summary: summary
                            )
                            .padding(.horizontal, density.popoverPaddingH)
                            .padding(.top, 12)
                            .padding(.bottom, 10)
                            Divider().opacity(0.5)
                        }
                        // Opaque: the turns scroll underneath it, and the
                        // window fill alone is 96 % — enough for a line of
                        // text to show through.
                        .background(WorkbenchPorcelain.windowFill(for: colorScheme))
                        .background(.background)
                    }
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: density.subtitleFontSize, initial: true) { _, size in
            conversation.setTextStyle(SessionRichTextStyle(promptSize: size + 0.5, answerSize: size + 1))
        }
        .onChange(of: conversation.notice) { _, notice in
            guard let notice else { return }
            switch notice {
            case .childNotFound:
                controller.manager.notify(L10n.Workbench.Sessions.Conversation.childNotFound)
            }
            conversation.clearNotice()
        }
    }

    private var showsRaw: Bool {
        conversation.phase == .unsupported || controller.viewMode == .raw
    }

    /// The turn list stays mounted whatever the pane shows — the raw
    /// transcript, a loading or error message — so moving between sessions
    /// never builds a new one; those states are drawn over it.
    @ViewBuilder
    private func content(for summary: SessionSummary) -> some View {
        let raw = showsRaw
        ZStack {
            SessionTurnList(
                density: density,
                conversation: conversation,
                accent: summary.provider.accent,
                actions: actions
            )
            .safeAreaInset(edge: .top, spacing: 0) {
                if conversation.phase == .ready, controller.hasSearchFocus {
                    searchHitBanner
                }
            }
            .overlay {
                SessionConversationStateOverlay(density: density, controller: controller, conversation: conversation)
            }
            .opacity(raw ? 0 : 1)
            .allowsHitTesting(!raw)
            .accessibilityHidden(raw)
            if raw {
                TranscriptView(density: density, model: controller.manager)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var actions: SessionConversationActions {
        let conversation = self.conversation
        let manager = controller.manager
        return SessionConversationActions(
            loadEarlier: { conversation.loadEarlier() },
            loadLater: { conversation.loadLater() },
            resumeLoading: { conversation.resumeLoading() },
            toggleProcess: { conversation.toggleProcess(turn: $0) },
            toggleStep: { conversation.toggleStep(turn: $0, position: $1) },
            openChild: { conversation.openChild($0) },
            copy: { text, note in manager.copyToClipboard(text, note: note) }
        )
    }

    private var searchHitBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .foregroundStyle(.secondary)
            Text(L10n.Workbench.Sessions.View.searchHit)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Button(L10n.Workbench.Sessions.View.showHit) { controller.showSearchHit() }
                .buttonStyle(WorkbenchPillButtonStyle())
        }
        .font(.system(size: density.subtitleFontSize - 0.5))
        .padding(.horizontal, density.popoverPaddingH)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.035))
        .background(.background)
    }

    private func stateMessage<Actions: View>(
        systemImage: String?,
        text: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text)
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            actions()
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text(L10n.Workbench.Sessions.Transcript.placeholderTitle)
                .font(.system(size: density.titleFontSize, weight: .semibold))
            Text(L10n.Workbench.Sessions.Transcript.placeholderDetail)
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(density.popoverPaddingH)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What covers the turn list when it has nothing current to show. Its own
/// view: it reads whether the list is empty, and the pane around it should
/// not redraw on every change of the rows. Opaque, since the list may still
/// hold the previous session's rows.
private struct SessionConversationStateOverlay: View {
    let density: Theme.Density
    let controller: SessionsPageController
    let conversation: SessionConversationModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch conversation.phase {
        case .idle, .unsupported:
            EmptyView()
        case .loading:
            covered(SessionStateMessage(density: density, systemImage: nil, text: L10n.Workbench.Sessions.Conversation.loadingOutline) {
                Button(L10n.Common.cancel) { conversation.cancelLoading() }
            })
        case .unreadable:
            covered(SessionStateMessage(
                density: density,
                systemImage: "exclamationmark.triangle",
                text: L10n.Workbench.Sessions.Conversation.unreadable
            ) {
                Button(L10n.Workbench.Sessions.Conversation.viewRaw) { controller.viewMode = .raw }
            })
        case .cancelled:
            covered(SessionStateMessage(
                density: density,
                systemImage: "pause.circle",
                text: L10n.Workbench.Sessions.Conversation.cancelled
            ) {
                Button(L10n.Common.retry) { conversation.reload() }
            })
        case .ready:
            if conversation.items.isEmpty {
                covered(SessionStateMessage(density: density, systemImage: "text.alignleft", text: L10n.Workbench.Sessions.Conversation.empty) {
                    EmptyView()
                })
            }
        }
    }

    private func covered(_ content: some View) -> some View {
        content
            .background(WorkbenchPorcelain.windowFill(for: colorScheme))
            .background(.background)
    }
}

/// A centred message with an icon (or a spinner) and its actions.
private struct SessionStateMessage<Actions: View>: View {
    let density: Theme.Density
    let systemImage: String?
    let text: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text)
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            actions()
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Turn list

/// The scrolling column of rows.
///
/// Opens on the end of the conversation; the "earlier turns" row at the top
/// pages more in when it scrolls into view (after the first settle, so
/// opening a session does not cascade through every page), and the
/// position is held on the row that was at the top while rows are added
/// above it. Which rows are on screen drives the contents column's
/// highlight.
private struct SessionTurnList: View {
    let density: Theme.Density
    let conversation: SessionConversationModel
    let accent: Color
    let actions: SessionConversationActions

    @State private var topID: String?
    @State private var pagingArmed = false
    @State private var tracker = ReadingPosition()

    /// Which turn is being read, from the headers that have scrolled up to
    /// the top edge. A plain reference, not observed state: geometry reports
    /// arrive in bursts while a conversation lays out, and the model hears
    /// about the result at most once per `settle`.
    @MainActor
    private final class ReadingPosition {
        var above: Set<Int> = []
        /// The build and session of the rows `above` describes; a report
        /// for another one starts the set over.
        var token = -1
        var session: String?
        var pending: Task<Void, Never>?
        static let settle = Duration.milliseconds(120)
        /// A header this close to the top edge counts as the turn being read.
        nonisolated static let threshold: CGFloat = 96
    }

    /// Whether the viewport is near either end of what is loaded.
    private struct Edges: Equatable {
        var nearTop: Bool
        var nearBottom: Bool
    }

    var body: some View {
        LazyScrollContainer {
            scrollView
        }
    }

    private var scrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(conversation.items) { item in
                        row(item)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, density.popoverPaddingH + 2)
                .padding(.top, 6)
                .padding(.bottom, 18)
            }
            .scrollPosition(id: $topID, anchor: .top)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // A session published whole gets a scroll view built on its
            // final rows, so the initial offset lands on the end of the
            // conversation without a scroll-to-end pass.
            .id(conversation.listToken)
            // Paging is driven by a boolean that changes only when the
            // viewport comes within reach of an end — not by a per-row
            // visibility report, which fired hundreds of times while a
            // conversation opened and cost more than drawing it.
            .onScrollGeometryChange(for: Edges.self) { geometry in
                let reach: CGFloat = 320
                return Edges(
                    nearTop: geometry.contentOffset.y < reach,
                    nearBottom: geometry.contentOffset.y + geometry.containerSize.height
                        > geometry.contentSize.height - reach
                )
            } action: { _, edges in
                guard pagingArmed else { return }
                if edges.nearTop { conversation.loadEarlier() }
                if edges.nearBottom { conversation.loadLater() }
            }
            .onChange(of: conversation.scrollRequest) { _, request in
                guard let request else { return }
                let anchor: UnitPoint = request.anchor == .top ? .top : .bottom
                if request.anchor == .top { tracker.above.removeAll() }
                proxy.scrollTo(request.itemID, anchor: anchor)
                // A lazy stack places a row it has not built yet by an
                // estimate; once the rows around it exist, a second pass
                // lands exactly.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    guard conversation.scrollRequest == request else { return }
                    proxy.scrollTo(request.itemID, anchor: anchor)
                }
            }
            .task(id: conversation.summary?.id) {
                pagingArmed = false
                try? await Task.sleep(for: .milliseconds(700))
                pagingArmed = true
            }
        }
    }

    @ViewBuilder
    private func row(_ item: SessionConversationItem) -> some View {
        let base = SessionConversationRow(item: item, density: density, accent: accent, actions: actions)
            .equatable()
            .id(item.id)
        if case let .header(header) = item {
            base.onGeometryChange(for: Bool.self) { proxy in
                proxy.frame(in: .scrollView).minY <= ReadingPosition.threshold
            } action: { isAbove in
                // Reset here rather than from a task: a task runs after the
                // first reports of the new rows and would wipe them.
                let token = conversation.listToken
                let session = conversation.summary?.id
                if tracker.token != token || tracker.session != session {
                    tracker.token = token
                    tracker.session = session
                    tracker.above.removeAll()
                }
                if isAbove { tracker.above.insert(header.turn) } else { tracker.above.remove(header.turn) }
                scheduleReadingPosition()
            }
        } else {
            base
        }
    }

    private func scheduleReadingPosition() {
        guard tracker.pending == nil else { return }
        tracker.pending = Task { @MainActor in
            try? await Task.sleep(for: ReadingPosition.settle)
            tracker.pending = nil
            if let turn = tracker.above.max() ?? conversation.window.range.first {
                conversation.noteCurrentTurn(turn)
            }
        }
    }
}

// MARK: - Header

/// The conversation's masthead: what this session is, the facts that
/// describe it, and the way back into it.
private struct SessionConversationHeader: View {
    let density: Theme.Density
    let controller: SessionsPageController
    let conversation: SessionConversationModel
    let summary: SessionSummary

    private var manager: SessionManagerModel { controller.manager }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let parent = conversation.trail.last {
                Button {
                    conversation.back()
                } label: {
                    Label(
                        L10n.Workbench.Sessions.Meta.back(title: SessionRowText.title(summary: parent, listing: controller.list.listing(for: parent))),
                        systemImage: "chevron.left"
                    )
                    .font(.system(size: density.subtitleFontSize - 1, weight: .medium))
                    .lineLimit(1)
                }
                .buttonStyle(.vibeBar)
                .foregroundStyle(summary.provider.accent)
            }
            HStack(alignment: .top, spacing: 10) {
                HarnessBrandBadge(harness: summary.effectiveHarness, iconSize: 20, containerSize: 26, brandColored: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: density.titleFontSize, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        if let kind {
                            SessionKindChip(kind: kind)
                        }
                        Text(providerLine)
                            .font(.system(size: max(10, density.resetCountdownFontSize - 1)))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SessionResumeButton(density: density, manager: manager, summary: summary)
            }
            SessionMetaStrip(density: density, controller: controller, conversation: conversation, summary: summary)
            modeBar
        }
    }

    private var title: String {
        let listing = conversation.stats.map {
            SessionStructureListing(stats: $0, firstPromptPreview: conversation.toc.first { $0.origin == .human && $0.preview != nil }?.preview)
        } ?? controller.list.listing(for: summary)
        return SessionRowText.title(summary: summary, listing: listing)
    }

    private var kind: SessionStructureKind? {
        let kind = conversation.stats?.kind ?? (ClaudeSubagentFiles.isSubagentSummary(summary) ? .subagent : nil)
        return kind == .interactive ? nil : kind
    }

    private var providerLine: String {
        guard let variant = summary.providerVariant, !variant.isEmpty,
              !ClaudeSubagentFiles.isSubagentSummary(summary)
        else { return summary.effectiveHarness.displayName }
        return "\(summary.effectiveHarness.displayName) · \(variant)"
    }

    private var iconActions: some View {
        HStack(spacing: 2) {
            BorderlessIconButton(systemImage: "number", help: L10n.Workbench.Sessions.copySessionID) {
                manager.copyToClipboard(summary.sessionID, note: L10n.Workbench.Sessions.Toast.sessionIDCopied)
            }
            BorderlessIconButton(systemImage: "doc.on.clipboard", help: L10n.Workbench.Sessions.copyResumeCommand) {
                manager.copyResumeCommand(for: summary)
            }
            .disabled(manager.resumeShellLine(for: summary) == nil)
            if let project = summary.projectDir {
                BorderlessIconButton(systemImage: "folder", help: L10n.Workbench.Sessions.Meta.openFolder) {
                    manager.openFolder(project)
                }
            }
            Menu {
                Button(L10n.Workbench.Sessions.Meta.revealLog) { manager.revealInFinder(summary) }
                Button(L10n.Workbench.Sessions.copySourcePath) {
                    manager.copyToClipboard(summary.sourcePath, note: L10n.Workbench.Sessions.Toast.sourcePathCopied)
                }
                if let project = summary.projectDir {
                    Button(L10n.Workbench.Sessions.copyWorkingDirectory) {
                        manager.copyToClipboard(project, note: L10n.Workbench.Sessions.Toast.cwdCopied)
                    }
                }
                if summary.provider == .antigravity {
                    Divider()
                    Text(L10n.Workbench.Sessions.antigravityNotice)
                }
                Divider()
                Button(L10n.Workbench.Sessions.deleteEllipsis, role: .destructive) {
                    manager.requestDelete([summary])
                }
                .disabled(!SessionManagerModel.isDeletable(summary))
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.button)
            .buttonStyle(.vibeBar)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L10n.Workbench.Sessions.Meta.more)
        }
    }

    private var modeBar: some View {
        HStack(spacing: 8) {
            if conversation.phase != .unsupported {
                turnControls
            } else {
                Spacer(minLength: 0)
            }
            iconActions
        }
    }

    @ViewBuilder
    private var turnControls: some View {
        HStack(spacing: 8) {
            SessionViewModePicker(controller: controller)
            if controller.viewMode == .turns {
                if let progress = conversation.progress {
                    ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
                        .progressViewStyle(.linear)
                        .frame(width: 70)
                    Text(L10n.Workbench.Sessions.Conversation.loadingTurns(
                        done: AppLocale.number(progress.done),
                        total: AppLocale.number(progress.total)
                    ))
                    .font(.system(size: max(10, density.resetCountdownFontSize - 1)).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    Button(L10n.Common.cancel) { conversation.cancelLoading() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                } else if conversation.isWindowed {
                    Text(L10n.Workbench.Sessions.Conversation.windowed)
                        .font(.system(size: max(10, density.resetCountdownFontSize - 1)))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if conversation.phase == .ready, !conversation.toc.isEmpty {
                    Menu {
                        Button(L10n.Workbench.Sessions.Conversation.expandAll) { conversation.setAllProcesses(expanded: true) }
                        Button(L10n.Workbench.Sessions.Conversation.collapseAll) { conversation.setAllProcesses(expanded: false) }
                        Divider()
                        Button(L10n.Workbench.Sessions.Conversation.jumpLatest) { conversation.revealLatest() }
                    } label: {
                        Image(systemName: "rectangle.expand.vertical")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 22)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.vibeBar)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(L10n.Workbench.Sessions.Conversation.expandAll)
                }
            } else {
                Spacer(minLength: 0)
            }
        }
    }
}

/// Turns or the raw transcript. Its own view, so the masthead redrawing for
/// a new session's facts does not rebuild the segmented control.
private struct SessionViewModePicker: View {
    let controller: SessionsPageController

    var body: some View {
        Picker(L10n.Workbench.Sessions.View.help, selection: Binding(
            get: { controller.viewMode },
            set: { controller.viewMode = $0 }
        )) {
            Text(L10n.Workbench.Sessions.View.turns).tag(SessionsPageController.ViewMode.turns)
            Text(L10n.Workbench.Sessions.View.raw).tag(SessionsPageController.ViewMode.raw)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(L10n.Workbench.Sessions.View.help)
    }
}

/// The page's single primary action: resume this session in the preferred
/// terminal, with a dropdown for the others and for "just copy it".
private struct SessionResumeButton: View {
    let density: Theme.Density
    let manager: SessionManagerModel
    let summary: SessionSummary

    var body: some View {
        let available = manager.resumeShellLine(for: summary) != nil
        let preferred = manager.preferredTerminal
        HStack(spacing: 0) {
            Button {
                if preferred == .copyOnly {
                    manager.copyResumeCommand(for: summary)
                } else {
                    manager.resumeInTerminal(summary)
                }
            } label: {
                Label(
                    preferred == .copyOnly
                        ? L10n.Workbench.Sessions.copyResumeCommand
                        : L10n.Workbench.Sessions.Resume.inTerminal(terminal: preferred.displayName),
                    systemImage: preferred == .copyOnly ? "doc.on.doc" : "terminal"
                )
                .font(.system(size: density.segmentedFontSize, weight: .semibold))
                .lineLimit(1)
                .padding(.leading, 12)
                .padding(.trailing, 10)
                .frame(minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.vibeBar)
            Rectangle()
                .fill(Color.white.opacity(0.35))
                .frame(width: 1, height: 16)
            Menu {
                ForEach(PreferredTerminal.allCases.filter { $0 != .copyOnly }, id: \.self) { terminal in
                    Button(L10n.Workbench.Sessions.Resume.inTerminal(terminal: terminal.displayName)) {
                        manager.resume(summary, in: terminal)
                    }
                }
                Divider()
                Button(L10n.Workbench.Sessions.copyResumeCommand) { manager.copyResumeCommand(for: summary) }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 26, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.vibeBar)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L10n.Workbench.Sessions.Resume.options)
        }
        .foregroundStyle(Color.white)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(available ? summary.provider.accent : Color.secondary.opacity(0.35))
        )
        .fixedSize()
        .disabled(!available)
        .opacity(available ? 1 : 0.7)
        .help(available ? "" : (ClaudeSubagentFiles.isSubagentSummary(summary)
            ? L10n.Workbench.Sessions.Resume.subagentHelp
            : L10n.Workbench.Sessions.Resume.none))
    }
}

/// The facts row under the title: where, when, how much, on what.
private struct SessionMetaStrip: View {
    let density: Theme.Density
    let controller: SessionsPageController
    let conversation: SessionConversationModel
    let summary: SessionSummary

    var body: some View {
        let stats = conversation.stats
        MenuBarChipFlow(spacing: 6, lineSpacing: 5) {
            if let project = summary.projectDir {
                let folder = SessionManagerModel.projectTitle(for: summary)
                Button {
                    controller.manager.revealFolder(project)
                } label: {
                    SessionMetaChip(systemImage: "folder", text: folder)
                }
                .buttonStyle(.vibeBar)
                .help(L10n.Workbench.Sessions.Meta.revealFolder(folder: project))
            }
            if let range = SessionMetaText.timeRange(stats: stats, summary: summary) {
                SessionMetaChip(systemImage: "clock", text: range.text)
                    .help(range.help)
            }
            if let stats {
                SessionMetaChip(systemImage: "text.bubble", text: L10n.Workbench.Sessions.Meta.prompts(count: stats.promptCount))
                SessionMetaChip(
                    systemImage: "wrench.and.screwdriver",
                    text: SessionMetaText.toolCalls(stats),
                    tint: stats.failedToolCount > 0 ? .red : nil
                )
                ForEach(stats.models, id: \.self) { model in
                    SessionMetaChip(systemImage: nil, text: model)
                        .help(L10n.Workbench.Sessions.Meta.modelsHelp)
                }
                if let tokens = SessionMetaText.tokens(stats) {
                    SessionMetaChip(systemImage: "sum", text: tokens.text)
                        .help(tokens.help)
                }
                if let cost = stats.estimatedCostUSD, cost > 0 {
                    let figure = UsageFormatting.formatMicroUSD(Int64((cost * 1_000_000).rounded()))
                    SessionMetaChip(
                        systemImage: "dollarsign.circle",
                        text: stats.hasUnpricedUsage
                            ? L10n.Workbench.Sessions.Meta.costLowerBound(cost: figure)
                            : L10n.Workbench.Sessions.Meta.costEstimate(cost: figure)
                    )
                    .help(stats.hasUnpricedUsage
                        ? L10n.Workbench.Sessions.Meta.costLowerBoundHelp
                        : L10n.Workbench.Sessions.Meta.costHelp)
                }
                if let branch = stats.gitBranch, !branch.isEmpty {
                    SessionMetaChip(systemImage: "arrow.triangle.branch", text: branch)
                        .help(L10n.Workbench.Sessions.Meta.branchHelp)
                }
            }
            let verdicts = conversation.verdictTotals
            if verdicts.reviews > 0 {
                // The count is the list row's and `sessions.transcript`'s;
                // the verdicts read out of those reviews are the detail.
                SessionMetaChip(
                    systemImage: "checkmark.shield",
                    text: L10n.Workbench.Sessions.Meta.reviews(count: verdicts.reviews),
                    tint: verdicts.deny > 0 ? .orange : nil
                )
                .help(L10n.Workbench.Sessions.Meta.verdicts(
                    allow: AppLocale.number(verdicts.allow),
                    deny: AppLocale.number(verdicts.deny)
                ))
            }
            if !conversation.subagentLinks.isEmpty {
                Menu {
                    ForEach(conversation.subagentLinks) { link in
                        Button(link.label) { conversation.openChild(link.childID) }
                    }
                } label: {
                    SessionMetaChip(
                        systemImage: "person.2",
                        text: L10n.Workbench.Sessions.Meta.subagents(count: conversation.subagentLinks.count)
                    )
                }
                .menuStyle(.button)
                .buttonStyle(.vibeBar)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }
}

/// One fact in the meta strip.
private struct SessionMetaChip: View {
    let systemImage: String?
    let text: String
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(tint ?? .secondary)
            }
            Text(text)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(tint ?? .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .frame(minHeight: 20)
        .background(Capsule().fill(Color.primary.opacity(0.055)))
    }
}

/// The meta strip's formatted facts. Computed per render from values, never
/// stored: they are localized, and formatting a handful of numbers is
/// cheaper than keeping a cache honest about the language.
enum SessionMetaText {
    static func timeRange(stats: SessionStats?, summary: SessionSummary) -> (text: String, help: String)? {
        let start = stats?.startedAt ?? summary.createdAt
        let end = stats?.endedAt ?? summary.lastActiveAt
        guard let start else { return nil }
        let startText = AppLocale.string(start, template: "MMMdjmm")
        guard let end, end > start else { return (startText, startText) }
        let sameDay = Calendar.current.isDate(start, inSameDayAs: end)
        let endText = AppLocale.string(end, template: sameDay ? "jmm" : "MMMdjmm")
        let duration = SessionDurationText.compact(milliseconds: stats?.durationMs ?? Int(end.timeIntervalSince(start) * 1000))
        let help = L10n.Workbench.Sessions.Meta.timeHelp(
            start: AppLocale.string(start, dateStyle: .medium, timeStyle: .short),
            end: AppLocale.string(end, dateStyle: .medium, timeStyle: .short)
        )
        return ("\(startText) – \(endText) · \(duration)", help)
    }

    static func toolCalls(_ stats: SessionStats) -> String {
        let calls = L10n.Workbench.Sessions.Meta.toolCalls(count: stats.toolCallCount)
        guard stats.failedToolCount > 0 else { return calls }
        return L10n.Workbench.Sessions.Meta.toolCallsFailed(calls: calls, failed: AppLocale.number(stats.failedToolCount))
    }

    static func tokens(_ stats: SessionStats) -> (text: String, help: String)? {
        guard stats.usageSource != .unavailable, stats.usageSource != .none, stats.totalTokens > 0 else { return nil }
        let text = UsageFormatting.compactTokens(Int64(stats.totalTokens))
        let usage = stats.totalUsage
        guard !usage.isZero else { return (text, L10n.Workbench.Sessions.Meta.tokensTotalOnly) }
        // `UsageFormatting`, the one token format the usage surfaces share.
        func figure(_ value: Int) -> String { UsageFormatting.compactTokens(Int64(value)) }
        return (text, L10n.Workbench.Sessions.Meta.tokensHelp(
            input: figure(usage.input),
            output: figure(usage.output),
            cacheRead: figure(usage.cacheRead),
            cacheWrite: figure(usage.cacheWrite)
        ))
    }
}

/// Durations at the page's two scales: a session or turn ("1h 45m") and a
/// step ("1.2s").
enum SessionDurationText {
    static func compact(milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1000)
        if seconds < 60 { return step(milliseconds: milliseconds) }
        let minutes = seconds / 60
        if minutes < 60 { return L10n.Common.Duration.minutes(minutes: minutes) }
        let hours = minutes / 60
        if hours < 24 { return L10n.Common.Duration.hoursMinutes(hours: hours, minutes: minutes % 60) }
        return L10n.Common.Duration.daysHours(days: hours / 24, hours: hours % 24)
    }

    static func step(milliseconds: Int) -> String {
        guard milliseconds >= 1000 else {
            return L10n.Workbench.Sessions.Duration.lessThanSecond
        }
        if milliseconds >= 60_000 { return compact(milliseconds: milliseconds) }
        let seconds = Double(milliseconds) / 1000
        let figure = seconds.formatted(.number.precision(.fractionLength(seconds < 10 ? 1 : 0)).locale(AppLocale.current))
        return L10n.Workbench.Sessions.Duration.seconds(seconds: figure)
    }
}
