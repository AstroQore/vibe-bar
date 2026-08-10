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
                emptyState
            } else if model.groupByProject {
                List {
                    ForEach(model.groupedRows) { group in
                        Section {
                            ForEach(group.rows) { row in
                                rowView(row)
                            }
                        } header: {
                            Text(group.title)
                                .font(.system(size: max(8, density.subtitleFontSize - 2), weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .tracking(0.4)
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                List {
                    ForEach(model.rows) { row in
                        rowView(row)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if model.isLoadingSummaries && !model.rows.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
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
        .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
        .listRowSeparator(.hidden)
        .onAppear {
            if row.id == model.rows.last?.id { model.loadMoreSummaries() }
        }
        .contextMenu {
            Button("Open in Terminal") { model.resumeInTerminal(row.summary) }
                .disabled(model.resumeCommand(for: row.summary) == nil)
            Button("Copy resume command") { model.copyResumeCommand(for: row.summary) }
                .disabled(model.resumeCommand(for: row.summary) == nil)
            Divider()
            Button("Delete…", role: .destructive) { model.requestDelete([row.summary]) }
                .disabled(!SessionManagerModel.isDeletable(row.summary))
        }
    }

    private var emptyState: some View {
        CardShell(density: density, alignment: .center) {
            Image(systemName: model.isIndexAvailable ? "bubble.left.and.text.bubble.right" : "externaldrive.badge.exclamationmark")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text(model.isIndexAvailable ? "No sessions match" : "Session index unavailable")
                .font(.system(size: density.titleFontSize, weight: .semibold))
            Text(emptyDetail)
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(density.popoverPaddingH)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var emptyDetail: String {
        guard model.isIndexAvailable else {
            return "The index under ~/.vibebar could not be opened, so sessions cannot be listed this session."
        }
        if model.indexProgress != nil { return "Still scanning the session logs on disk." }
        if !model.searchText.isEmpty { return "Nothing in the indexed sessions matches that search." }
        return "No Codex, Claude Code, Grok, Gemini, or AntiGravity session logs were found on this Mac."
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

    private var summary: SessionSummary { row.summary }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if isDeleteMode {
                checkbox
            }
            ToolBrandBadge(tool: summary.provider.tool, iconSize: 15, containerSize: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: density.subtitleFontSize + 1, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
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
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(summary.provider.accent.opacity(isSelected ? 0.16 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(summary.provider.accent.opacity(isSelected ? 0.45 : 0), lineWidth: 0.8)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isDeleteMode { onToggleCheck() } else { onSelect() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var checkbox: some View {
        Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
            .font(.system(size: density.subtitleFontSize + 3))
            .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
            .opacity(SessionManagerModel.isDeletable(summary) ? 1 : 0.3)
            .padding(.top, 2)
            .onTapGesture { onToggleCheck() }
            .help(SessionManagerModel.isDeletable(summary)
                ? "Include this session in the deletion"
                : "AntiGravity sessions are managed by the IDE")
            .accessibilityLabel("Select this session")
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

    private var footer: some View {
        HStack(spacing: 6) {
            if let project = summary.projectDir {
                Label(SessionManagerModel.projectTitle(project), systemImage: "folder")
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
                Text("\(summary.messageCount)")
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .frame(minHeight: 14)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .help("\(summary.messageCount) messages")
            }
        }
        .font(.system(size: max(9, density.resetCountdownFontSize - 1)))
        .foregroundStyle(.tertiary)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
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
