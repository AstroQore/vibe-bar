import SwiftUI
import VibeBarCore

/// The Sessions page's session list.
///
/// One row per session, dense enough that a week of work fits on a screen:
/// harness mark, title, model, project, when, tokens and cost — the facts
/// that tell two similar sessions apart. Threads fold under the session that
/// started them (`SessionListModel`); headless runs sit behind the Threads
/// menu. Stats fill in as the structure sidecar answers, and a row without
/// them yet simply shows none.
struct SessionListView: View {
    let density: Theme.Density
    let controller: SessionsPageController
    let list: SessionListModel

    @ObservedObject private var model: SessionManagerModel

    init(density: Theme.Density, controller: SessionsPageController, list: SessionListModel) {
        self.density = density
        self.controller = controller
        self.list = list
        _model = ObservedObject(wrappedValue: controller.manager)
    }

    var body: some View {
        Group {
            if list.rows.isEmpty {
                // "No sessions match" is a verdict, and one frame of it while
                // the off-main rows build is still running would be a wrong
                // one. Hold the space instead.
                if model.isPreparingRows || (!model.rows.isEmpty && list.rows.isEmpty && list.hiddenCounts.isEmpty) {
                    Color.clear
                } else {
                    emptyState
                }
            } else {
                LazyScrollContainer { rowsScrollView }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if model.isLoadingSummaries && !list.rows.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .workbenchOverlaySurface(in: Capsule())
                    .padding(.bottom, 8)
            }
        }
    }

    private var rowsScrollView: some View {
                // Read once and captured, so the rows are not each an
                // observer of the selection (a few thousand of them would
                // each be woken by every click).
                let displayedID = controller.displayedID
                let lastID = list.rows.last?.id
                return ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if list.isGrouped {
                            ForEach(list.groups) { group in
                                Text(group.bucket.title.uppercased())
                                    .font(.system(size: max(9, density.subtitleFontSize - 3), weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                    .tracking(0.5)
                                    .padding(.top, 9)
                                    .padding(.bottom, 2)
                                    .padding(.horizontal, 8)
                                ForEach(group.rows) { row in
                                    rowView(row, isLast: row.id == lastID, displayedID: displayedID)
                                }
                            }
                        } else {
                            ForEach(list.rows) { row in
                                rowView(row, isLast: row.id == lastID, displayedID: displayedID)
                            }
                        }
                        if model.hasMoreSummaries, model.searchText.isEmpty {
                            moreRow
                        }
                        if model.isSummaryListCapped, model.searchText.isEmpty {
                            capNotice
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
    }

    private func rowView(_ row: SessionListModel.DisplayRow, isLast: Bool, displayedID: String?) -> some View {
        SessionRow(
            density: density,
            row: row,
            modelLabel: model.displayModel(for: row.summary),
            isSelected: displayedID == row.id,
            isDeleteMode: model.isDeleteMode,
            isChecked: model.checkedIDs.contains(row.id),
            actions: SessionRow.Actions(
                select: { controller.select(row) },
                toggleCheck: { model.toggleChecked(row.summary) },
                toggleThreads: { list.toggleExpanded(row) }
            )
        )
        .equatable()
        .onAppear {
            if isLast { model.loadMoreSummaries() }
        }
        .contextMenu { contextMenu(for: row) }
    }

    /// `resumeCommand(for:)` builds a whole shell invocation, and this asked
    /// for it twice per menu — once per item — for the same answer.
    @ViewBuilder
    private func contextMenu(for row: SessionListModel.DisplayRow) -> some View {
        let canResume = model.resumeCommand(for: row.summary) != nil
        Button(L10n.Workbench.Sessions.openInTerminal) { model.resumeInTerminal(row.summary) }
            .disabled(!canResume)
        Button(L10n.Workbench.Sessions.copyResumeCommand) {
            model.copyResumeCommand(for: row.summary)
        }
        .disabled(!canResume)
        Button(L10n.Workbench.Skills.menuRevealInFinder) { model.revealInFinder(row.summary) }
        Divider()
        Button(L10n.Workbench.Sessions.deleteEllipsis, role: .destructive) {
            model.requestDelete([row.summary])
        }
            .disabled(!SessionManagerModel.isDeletable(row.summary))
    }

    /// The list stops at `maximumLoadedSummaries` because a `LazyVStack`
    /// builds rows lazily and then keeps every one of them. Saying so beats
    /// letting the scroll quietly end short of an 11 000-session index.
    /// The next page on request, and how many loaded rows the thread
    /// filters hide: the way on when a page held nothing to show and so no
    /// new last row came into view to ask for more.
    private var moreRow: some View {
        let hidden = list.hiddenCounts.filter { $0.key != .guardian }.values.reduce(0, +)
        return HStack(spacing: 8) {
            Button(L10n.Usage.Table.loadMore(remaining: model.remainingSummaryCount)) {
                model.loadMoreSummaries()
            }
            .buttonStyle(WorkbenchPillButtonStyle())
            .disabled(model.isLoadingSummaries)
            if hidden > 0 {
                Text(L10n.Workbench.Sessions.Threads.hidden(count: AppLocale.number(hidden)))
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: max(10, density.resetCountdownFontSize)))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var capNotice: some View {
        Text(L10n.Workbench.Sessions.List.capNotice(
            shown: SessionManagerModel.maximumLoadedSummaries,
            total: model.totalSessionCount
        ))
            .font(.system(size: max(10, density.resetCountdownFontSize)))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: emptySymbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text(emptyTitle)
                .font(.system(size: density.titleFontSize, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(emptyDetail)
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .padding(density.popoverPaddingH)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var hasNoHarnessSelected: Bool {
        HarnessSelection.isNothing(model.harnessFilter)
    }

    private var emptySymbol: String {
        guard model.isIndexAvailable else { return "externaldrive.badge.exclamationmark" }
        return hasNoHarnessSelected
            ? "line.3.horizontal.decrease.circle"
            : "bubble.left.and.text.bubble.right"
    }

    /// The explicit empty selection the All chip can reach is its own state:
    /// "no sessions match" would blame the data for a filter the user set.
    private var emptyTitle: String {
        guard model.isIndexAvailable else {
            return L10n.Workbench.Sessions.Empty.indexUnavailableTitle
        }
        return hasNoHarnessSelected
            ? L10n.Usage.NoHarnessSelected.title
            : L10n.Workbench.Sessions.Empty.noMatchTitle
    }

    private var emptyDetail: String {
        guard model.isIndexAvailable else {
            return L10n.Workbench.Sessions.Empty.indexUnavailableDetail
        }
        if hasNoHarnessSelected { return L10n.Usage.NoHarnessSelected.detail }
        if model.indexProgress != nil { return L10n.Workbench.Sessions.Empty.scanningDetail }
        if !model.searchText.isEmpty {
            return L10n.Workbench.Sessions.Empty.searchNoMatchDetail
        }
        return L10n.Workbench.Sessions.Empty.noLogsDetail(count: Harness.allCases.count)
    }
}

/// One session in the list.
///
/// Equatable on everything it draws, so a stats batch that lands for other
/// rows, or a selection that moves between two other rows, does not
/// re-evaluate this one.
struct SessionRow: View, Equatable {
    struct Actions {
        let select: () -> Void
        let toggleCheck: () -> Void
        let toggleThreads: () -> Void
    }

    let density: Theme.Density
    let row: SessionListModel.DisplayRow
    /// Resolved by the model, not here: it holds the labels AntiGravity
    /// learned, and a row must not read a file to draw a chip.
    let modelLabel: String?
    let isSelected: Bool
    let isDeleteMode: Bool
    let isChecked: Bool
    let actions: Actions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    static func == (lhs: SessionRow, rhs: SessionRow) -> Bool {
        lhs.row == rhs.row
            && lhs.modelLabel == rhs.modelLabel
            && lhs.isSelected == rhs.isSelected
            && lhs.isDeleteMode == rhs.isDeleteMode
            && lhs.isChecked == rhs.isChecked
            && lhs.density.profile == rhs.density.profile
    }

    private var summary: SessionSummary { row.summary }
    private var isThread: Bool { row.depth > 0 }

    var body: some View {
        Button {
            if isDeleteMode { actions.toggleCheck() } else { actions.select() }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                if isDeleteMode {
                    checkbox
                }
                // Brand-coloured on purpose: this list is scanned for
                // "which harness was that", and colour finds a row faster
                // than a 15pt silhouette does.
                HarnessBrandBadge(
                    harness: summary.effectiveHarness,
                    iconSize: isThread ? 12 : 15,
                    containerSize: isThread ? 16 : 20,
                    brandColored: true
                )
                .padding(.top, isThread ? 1 : 0)
                VStack(alignment: .leading, spacing: 3) {
                    titleLine
                    factsLine
                    if let snippet = row.row.snippet {
                        Text(SessionSnippet.attributed(snippet))
                            .font(.system(size: density.subtitleFontSize - 1))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if row.isLoadingThreads {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text(L10n.Workbench.Sessions.List.loadingThreads)
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 9 + CGFloat(row.depth) * 16)
            .padding(.trailing, 9)
            .padding(.vertical, isThread ? 6 : 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(rowFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(rowBorder, lineWidth: isSelected ? 0.8 : Theme.Card.hairlineWidth)
            )
            .overlay(alignment: .leading) {
                if isThread {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1)
                        .padding(.leading, 9 + CGFloat(row.depth - 1) * 16 + 8)
                        .padding(.vertical, 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.vibeBar)
        // One tooltip for the row's facts rather than one per chip: every
        // tooltip is a responder the window walks on each update, and a
        // list of rows with five each was a walk of a hundred.
        .help(helpText)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
        // One label for the row, built here, instead of `.combine` over a
        // dozen child texts — combining joins them with a separator the
        // accessibility engine looks up once per child, per row, per update.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        // Ignoring the children drops the button's own press; give it back.
        .accessibilityAction {
            if isDeleteMode { actions.toggleCheck() } else { actions.select() }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isDeleteMode
            ? L10n.Workbench.Sessions.Row.toggleForDeletion
            : L10n.Workbench.Sessions.Row.showTranscript)
        // The capsule is a button inside the row's button; combined, the row
        // would swallow it, so it is offered as an action of the row too.
        .accessibilityAction(named: row.isExpanded
            ? L10n.Workbench.Sessions.List.collapseThreads
            : L10n.Workbench.Sessions.List.expandThreads) {
            if row.threadCount > 0 { actions.toggleThreads() }
        }
    }

    private var accessibilityText: String {
        var parts = [SessionRowText.title(summary: summary, listing: row.listing), summary.effectiveHarness.displayName]
        if let kind = kindChip, let label = SessionRowText.kindLabel(kind) { parts.append(label) }
        if let modelLabel { parts.append(modelLabel) }
        if !isThread, summary.projectDir != nil { parts.append(SessionManagerModel.projectTitle(for: summary)) }
        if let stamp = summary.lastActiveAt ?? summary.createdAt {
            parts.append(Self.relative.localizedString(for: stamp, relativeTo: Date()))
        }
        if row.threadCount > 0 { parts.append(L10n.Workbench.Sessions.List.threadCount(count: row.threadCount)) }
        return parts.joined(separator: ", ")
    }

    private var helpText: String {
        var lines: [String] = []
        if let model = summary.model ?? modelLabel { lines.append(model) }
        if !isThread, let project = summary.projectDir { lines.append(project) }
        if let tokens = row.listing?.displayTokens {
            lines.append(L10n.Workbench.Sessions.List.tokensHelp(tokens: UsageFormatting.compactTokens(Int64(tokens))))
        }
        if let cost = row.listing?.stats.estimatedCostUSD, cost > 0 {
            lines.append(L10n.Workbench.Sessions.List.costHelp(cost: UsageFormatting.compactUSD(Int64((cost * 1_000_000).rounded()))))
        }
        if row.row.reviewCount > 0 {
            lines.append(L10n.Workbench.Sessions.Row.autoReviewsMerged(count: row.row.reviewCount))
        }
        return lines.joined(separator: "\n")
    }

    private var rowFill: Color {
        if isSelected { return summary.provider.accent.opacity(isHovering ? 0.19 : 0.15) }
        return isHovering ? WorkbenchPorcelain.hoverFill(for: colorScheme) : .clear
    }

    private var rowBorder: Color {
        if isSelected { return summary.provider.accent.opacity(0.45) }
        return .clear
    }

    private var checkbox: some View {
        Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
            .font(.system(size: density.subtitleFontSize + 3))
            .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
            .opacity(SessionManagerModel.isDeletable(summary) ? 1 : 0.3)
            .padding(.top, 1)
            .help(SessionManagerModel.isDeletable(summary)
                ? L10n.Workbench.Sessions.Row.includeInDeletion
                : SessionDeleteError.providerIsReadOnly(summary.provider).message)
            .accessibilityLabel(L10n.Workbench.Sessions.Row.select)
    }

    // MARK: Lines

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let chip = kindChip {
                SessionKindChip(kind: chip)
            }
            Text(SessionRowText.title(summary: summary, listing: row.listing))
                .font(.system(size: isThread ? density.subtitleFontSize : density.subtitleFontSize + 1,
                              weight: isThread ? .medium : .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let stamp = summary.lastActiveAt ?? summary.createdAt {
                Text(Self.relative.localizedString(for: stamp, relativeTo: Date()))
                    .font(.system(size: max(10, density.resetCountdownFontSize - 1)))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    /// The chip that says what kind of thread a row is: always on a folded
    /// child, and on a top-level row only when its parent is not listed.
    private var kindChip: SessionStructureKind? {
        guard let kind = row.kind ?? (ClaudeSubagentFiles.isSubagentSummary(summary) ? .subagent : nil),
              kind != .interactive
        else { return nil }
        return isThread || row.isOrphanThread || SessionThreadTree.filteredKinds.contains(kind) ? kind : nil
    }

    private var factsLine: some View {
        HStack(spacing: 6) {
            // An AntiGravity model id that is still an internal enum says
            // nothing a reader can use; the row is better off without the
            // chip than with `MODEL_PLACEHOLDER_M318` on it.
            if let modelLabel {
                Text(modelLabel)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .frame(minHeight: 15)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .layoutPriority(-1)
            }
            if summary.projectDir != nil, !isThread {
                Label(SessionManagerModel.projectTitle(for: summary), systemImage: "folder")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .layoutPriority(-2)
            }
            if let tokens = row.listing?.displayTokens {
                let figure = UsageFormatting.compactTokens(Int64(tokens))
                Text(figure)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            if let cost = row.listing?.stats.estimatedCostUSD, cost > 0 {
                let figure = UsageFormatting.compactUSD(Int64((cost * 1_000_000).rounded()))
                Text(figure)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 0)
            if row.row.reviewCount > 0 {
                Label(AppLocale.number(row.row.reviewCount), systemImage: "checkmark.bubble")
                    .labelStyle(.titleAndIcon)
                    .fixedSize()
            }
            if row.threadCount > 0 {
                threadCapsule
            }
        }
        .font(.system(size: max(10, density.resetCountdownFontSize - 1)))
        .foregroundStyle(.secondary)
    }

    /// "N threads" — a button of its own inside the row's button, so it
    /// folds and unfolds without selecting the row.
    private var threadCapsule: some View {
        Button(action: actions.toggleThreads) {
            HStack(spacing: 3) {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                Text(L10n.Workbench.Sessions.List.threadCount(count: row.threadCount))
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 17)
            .foregroundStyle(row.isExpanded ? summary.provider.accent : Color.secondary)
            .background(Capsule().fill(summary.provider.accent.opacity(row.isExpanded ? 0.16 : 0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.vibeBar)
        .fixedSize()
    }

    private static var relative: RelativeDateTimeFormatter {
        AppLocale.relativeDateTimeFormatter(unitsStyle: .abbreviated)
    }
}

/// FTS5 hands back its snippet with `<b>` markers around the matched run.
///
/// Those are the only markup in the string — the excerpt itself is stored
/// verbatim — so the parse is a plain split rather than an HTML decode, and
/// anything that isn't a marker stays literal text.
enum SessionSnippet {
    static let openMarker = "<b>"
    static let closeMarker = "</b>"

    static func attributed(_ raw: String) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(raw)
        while let open = rest.range(of: openMarker) {
            out.append(AttributedString(String(rest[rest.startIndex..<open.lowerBound])))
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: closeMarker) else {
                out.append(bold(String(afterOpen)))
                return out
            }
            out.append(bold(String(afterOpen[afterOpen.startIndex..<close.lowerBound])))
            rest = afterOpen[close.upperBound...]
        }
        out.append(AttributedString(String(rest)))
        return out
    }

    private static func bold(_ text: String) -> AttributedString {
        var run = AttributedString(text)
        run.inlinePresentationIntent = .stronglyEmphasized
        run.foregroundColor = .primary
        return run
    }
}
