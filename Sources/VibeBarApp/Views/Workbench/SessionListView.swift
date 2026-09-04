import SwiftUI
import VibeBarCore

/// The Sessions page's left column.
///
/// One row per session, dense enough that a week of work fits on a screen:
/// brand badge, title, the search snippet when there is one, and a footer of
/// the three facts that tell two similar sessions apart — project, when it
/// was last touched, and how long it is.
struct SessionListView: View {
    let density: Theme.Density
    @ObservedObject var model: SessionManagerModel

    var body: some View {
        Group {
            if model.rows.isEmpty {
                // "No sessions match" is a verdict, and one frame of it while
                // the off-main rows build is still running would be a wrong
                // one. Hold the space instead.
                if model.isPreparingRows {
                    Color.clear
                } else {
                    emptyState
                }
            } else {
                // This is deliberately a plain scroll surface rather than a
                // SwiftUI List: sessions are cards in a reading queue, not
                // settings rows, and the default List chrome competes with
                // the selected-provider tint.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if model.groupByProject {
                            ForEach(model.groupedRows) { group in
                                Text(group.title.uppercased())
                                    .font(.system(size: max(9, density.subtitleFontSize - 3), weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                    .tracking(0.5)
                                    .padding(.top, 7)
                                    .padding(.horizontal, 4)
                                ForEach(group.rows) { row in
                                    rowView(row)
                                }
                            }
                        } else {
                            ForEach(model.rows) { row in
                                rowView(row)
                            }
                        }
                        if model.isSummaryListCapped, model.searchText.isEmpty {
                            capNotice
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if model.isLoadingSummaries && !model.rows.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .workbenchOverlaySurface(in: Capsule())
                    .padding(.bottom, 8)
            }
        }
    }

    private func rowView(_ row: SessionManagerModel.Row) -> some View {
        SessionRow(
            density: density,
            row: row,
            isSelected: model.selection?.id == row.id,
            isDeleteMode: model.isDeleteMode,
            isChecked: model.checkedIDs.contains(row.id),
            onToggleCheck: { model.toggleChecked(row.summary) },
            onSelect: { model.select(row) }
        )
        .onAppear {
            if row.id == model.rows.last?.id { model.loadMoreSummaries() }
        }
        .contextMenu { contextMenu(for: row) }
    }

    /// `resumeCommand(for:)` builds a whole shell invocation, and this asked
    /// for it twice per menu — once per item — for the same answer.
    @ViewBuilder
    private func contextMenu(for row: SessionManagerModel.Row) -> some View {
        let canResume = model.resumeCommand(for: row.summary) != nil
        Button(L10n.Workbench.sessionsOpenInTerminal) { model.resumeInTerminal(row.summary) }
            .disabled(!canResume)
        Button(L10n.Workbench.sessionsCopyResumeCommand) {
            model.copyResumeCommand(for: row.summary)
        }
        .disabled(!canResume)
        Divider()
        Button(L10n.Workbench.sessionsDeleteEllipsis, role: .destructive) {
            model.requestDelete([row.summary])
        }
            .disabled(!SessionManagerModel.isDeletable(row.summary))
    }

    /// The list stops at `maximumLoadedSummaries` because a `LazyVStack`
    /// builds rows lazily and then keeps every one of them. Saying so beats
    /// letting the scroll quietly end short of an 11 000-session index.
    private var capNotice: some View {
        Text(L10n.Workbench.sessionsListCapNotice(
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
        CardShell(density: density, alignment: .center) {
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
                .frame(maxWidth: 320)
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
            return L10n.Workbench.sessionsEmptyIndexUnavailableTitle
        }
        return hasNoHarnessSelected
            ? L10n.Usage.noHarnessSelectedTitle
            : L10n.Workbench.sessionsEmptyNoMatchTitle
    }

    private var emptyDetail: String {
        guard model.isIndexAvailable else {
            return L10n.Workbench.sessionsEmptyIndexUnavailableDetail
        }
        if hasNoHarnessSelected { return L10n.Usage.noHarnessSelectedDetail }
        if model.indexProgress != nil { return L10n.Workbench.sessionsEmptyScanningDetail }
        if !model.searchText.isEmpty {
            return L10n.Workbench.sessionsEmptySearchNoMatchDetail
        }
        return L10n.Workbench.sessionsEmptyNoLogsDetail(count: Harness.allCases.count)
    }
}

/// One session in the list.
private struct SessionRow: View {
    let density: Theme.Density
    let row: SessionManagerModel.Row
    let isSelected: Bool
    let isDeleteMode: Bool
    let isChecked: Bool
    let onToggleCheck: () -> Void
    let onSelect: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var summary: SessionSummary { row.summary }

    var body: some View {
        Button {
            if isDeleteMode { onToggleCheck() } else { onSelect() }
        } label: {
            HStack(alignment: .top, spacing: 9) {
                if isDeleteMode {
                    checkbox
                }
                // Brand-coloured on purpose: this list is scanned for
                // "which harness was that", and colour finds a row faster
                // than a 15pt silhouette does.
                HarnessBrandBadge(
                    harness: summary.effectiveHarness,
                    iconSize: 15,
                    containerSize: 20,
                    brandColored: true
                )
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: density.subtitleFontSize + 1, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    provenance
                    if let snippet = row.snippet {
                        Text(SessionSnippet.attributed(snippet))
                            .font(.system(size: density.subtitleFontSize - 1))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else if let subtitle {
                        Text(subtitle)
                            .font(.system(size: density.subtitleFontSize - 1))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    footer
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(rowFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(rowBorder, lineWidth: isSelected || isHovering ? 0.8 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.vibeBar)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isDeleteMode
            ? L10n.Workbench.sessionsRowToggleForDeletion
            : L10n.Workbench.sessionsRowShowTranscript)
    }

    private var rowFill: Color {
        if isSelected { return summary.provider.accent.opacity(isHovering ? 0.20 : 0.16) }
        return Color.primary.opacity(isHovering ? 0.055 : 0)
    }

    private var rowBorder: Color {
        if isSelected { return summary.provider.accent.opacity(isHovering ? 0.56 : 0.45) }
        return Color.primary.opacity(isHovering ? 0.14 : 0)
    }

    private var checkbox: some View {
        Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
            .font(.system(size: density.subtitleFontSize + 3))
            .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
            .opacity(SessionManagerModel.isDeletable(summary) ? 1 : 0.3)
            .padding(.top, 2)
            .help(SessionManagerModel.isDeletable(summary)
                ? L10n.Workbench.sessionsRowIncludeInDeletion
                : SessionDeleteError.providerIsReadOnly(summary.provider).message)
            .accessibilityLabel(L10n.Workbench.sessionsRowSelect)
    }

    private var title: String {
        if let title = summary.title, !title.isEmpty { return title }
        if let summaryText = summary.summary, !summaryText.isEmpty { return summaryText }
        return summary.sessionID
    }

    private var subtitle: String? {
        guard let text = summary.summary, !text.isEmpty, text != summary.title else { return nil }
        return text
    }

    /// Which harness produced this session, and — where the log said so —
    /// which model it ran on.
    ///
    /// The harness is the label rather than the provider because they differ
    /// exactly where it matters: a `codex` rollout reads "Codex" or "ChatGPT
    /// Work" depending on its originator. The brand badge above stays on the
    /// harness's own tool, so the two never disagree about the colour.
    private var provenance: some View {
        HStack(spacing: 5) {
            Text(summary.effectiveHarness.displayName)
                .fontWeight(.medium)
                .lineLimit(1)
            if let model = summary.model, !model.isEmpty {
                Text(UsageModelNaming.canonicalDisplayName(model))
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .frame(minHeight: 14)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .help(model)
            }
        }
        .font(.system(size: max(10, density.resetCountdownFontSize - 1)))
        .foregroundStyle(.secondary)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let project = summary.projectDir {
                Label(SessionManagerModel.projectTitle(for: summary), systemImage: "folder")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .help(project)
            }
            if let stamp = summary.lastActiveAt ?? summary.createdAt {
                Text(Self.relative.localizedString(for: stamp, relativeTo: Date()))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if summary.hasKnownMessageCount {
                Text(AppLocale.number(summary.messageCount))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .frame(minHeight: 14)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .help(L10n.Workbench.sessionsRowMessageCount(count: summary.messageCount))
            }
            if row.reviewCount > 0 {
                Label(AppLocale.number(row.reviewCount), systemImage: "checkmark.bubble")
                    .help(L10n.Workbench.sessionsRowAutoReviewsMerged(count: row.reviewCount))
            }
        }
        .font(.system(size: max(10, density.resetCountdownFontSize - 1)))
        .foregroundStyle(.tertiary)
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
