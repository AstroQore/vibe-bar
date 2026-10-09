import SwiftUI
import VibeBarCore

/// The Sessions page's right column: the open conversation's contents, one
/// entry per turn — its number, what was asked, when, and how much ran.
///
/// A click jumps the conversation there (loading that part of a long log
/// first); the entry for the turn at the top of the conversation is
/// highlighted and kept in view as the conversation scrolls, unless the
/// pointer is over this column, where an auto-scroll would fight the
/// reader.
struct SessionConversationOutline: View {
    let density: Theme.Density
    let conversation: SessionConversationModel
    let onHide: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false
    @State private var shown = ShownRows()

    /// Entries the lazy list has built — on screen or just beyond it. Not
    /// observed: it only answers "is the current entry already in view".
    @MainActor
    private final class ShownRows {
        var rows: Set<Int> = []

        /// Built and not at the very edge of what is built (the edges are
        /// the overscan, possibly off screen).
        func isComfortablyVisible(_ turn: Int) -> Bool {
            guard rows.contains(turn), let first = rows.min(), let last = rows.max() else { return false }
            // The list's own last entry is on screen whenever it is built:
            // nothing below it can push it into the overscan.
            return (turn > first + 1 && turn < last - 1) || turn == last
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            totals
            if conversation.toc.isEmpty {
                Text(emptyText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .padding(14)
                Spacer(minLength: 0)
            } else {
                LazyScrollContainer { entries }
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WorkbenchPorcelain.sidebarFill(for: colorScheme))
        .onHover { isHovering = $0 }
    }

    private var entries: some View {
        // Read once here and captured: a read inside the row closure would
        // make every built row an observer of the current turn.
        let current = conversation.currentTurn
        let conversation = self.conversation
        let shown = self.shown
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(conversation.toc) { entry in
                        SessionOutlineRow(
                            entry: entry,
                            isCurrent: entry.turnIndex == current
                        ) {
                            conversation.reveal(turn: entry.turnIndex)
                        }
                        .equatable()
                        .id(entry.turnIndex)
                        .onAppear { shown.rows.insert(entry.turnIndex) }
                        .onDisappear { shown.rows.remove(entry.turnIndex) }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.automatic)
            // The conversation opens on its last turn, so the contents do
            // too — by the initial offset of a scroll view built per
            // session, not by a scroll-to-end that measures every entry.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .id(conversation.contentToken)
            // Follows the conversation once it settles, and only when the
            // current entry is out of sight: each scroll-to in a lazy list
            // is a layout pass, and a fast scroll crosses several turns a
            // second.
            .task(id: conversation.currentTurn) {
                guard let current = conversation.currentTurn, !isHovering else { return }
                try? await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled, !isHovering, !shown.isComfortablyVisible(current) else { return }
                proxy.scrollTo(current, anchor: .center)
            }
        }
    }

    private var emptyText: String {
        switch conversation.phase {
        case .ready: L10n.Workbench.Sessions.Conversation.empty
        case .unsupported: L10n.Workbench.Sessions.Toc.unsupported
        case .loading: L10n.Workbench.Sessions.Conversation.loadingOutline
        case .idle, .unreadable, .cancelled: L10n.Workbench.Sessions.Transcript.placeholderTitle
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(L10n.Workbench.Sessions.Toc.heading)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            if !conversation.toc.isEmpty {
                Text(AppLocale.number(conversation.toc.count))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.quaternary)
            }
            Spacer(minLength: 0)
            BorderlessIconButton(systemImage: "sidebar.trailing", help: L10n.Workbench.Sessions.Toc.hide, action: onHide)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    /// The outline's sums in the masthead's words, so the two can be
    /// checked against each other at a glance.
    @ViewBuilder
    private var totals: some View {
        let totals = conversation.tocTotals
        if totals.turns > 0 {
            Text(L10n.Workbench.Sessions.Meta.prompts(count: totals.prompts)
                + " · " + L10n.Workbench.Sessions.Meta.toolCalls(count: totals.steps))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
        }
    }

    private var footer: some View {
        Button {
            conversation.revealLatest()
        } label: {
            Label(L10n.Workbench.Sessions.Conversation.jumpLatest, systemImage: "arrow.down.to.line")
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(WorkbenchPillButtonStyle())
        .padding(8)
    }
}

/// One entry. No hover state of its own: every hover region is a responder
/// the accessibility engine walks on each update, and a long session has a
/// thousand of these; the press state and the current-turn fill carry the
/// feedback.
private struct SessionOutlineRow: View, Equatable {
    let entry: SessionConversationTOCEntry
    let isCurrent: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: SessionOutlineRow, rhs: SessionOutlineRow) -> Bool {
        lhs.entry == rhs.entry && lhs.isCurrent == rhs.isCurrent
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 7) {
                Text(AppLocale.number(entry.ordinal))
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(isCurrent ? WorkbenchPorcelain.accent : Color.secondary.opacity(0.8))
                    .frame(minWidth: 20, alignment: .trailing)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview)
                        .font(.system(size: 11.5, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(entry.preview == nil ? .secondary : .primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 5) {
                        if let started = entry.startedAt {
                            Text(AppLocale.string(started, template: "jmm"))
                                .monospacedDigit()
                        }
                        if entry.steps > 0 {
                            Text(L10n.Workbench.Sessions.Turn.steps(count: entry.steps))
                        }
                        if entry.failed > 0 {
                            Text(L10n.Workbench.Sessions.Turn.failures(count: entry.failed))
                                .foregroundStyle(.red)
                        }
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(fill)
            )
            .contentShape(Rectangle())
            .opacity(entry.status == .abandoned ? 0.5 : 1)
        }
        .buttonStyle(.vibeBar)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(traits)
        .accessibilityAction { action() }
    }

    private var accessibilityText: String {
        AppLocale.number(entry.ordinal) + ". " + preview
    }

    private var traits: AccessibilityTraits {
        isCurrent ? [.isButton, .isSelected] : .isButton
    }

    private var fill: Color {
        isCurrent ? WorkbenchPorcelain.accent.opacity(0.12) : .clear
    }

    private var preview: String {
        if let preview = entry.preview { return preview }
        switch entry.origin {
        case .automation: return L10n.Workbench.Sessions.Turn.Origin.automation
        case .agent: return L10n.Workbench.Sessions.Turn.Origin.agent
        case .guardianRequest: return L10n.Workbench.Sessions.Turn.Origin.guardianRequest
        case .none, .human: return L10n.Workbench.Sessions.Turn.Origin.none
        }
    }
}
