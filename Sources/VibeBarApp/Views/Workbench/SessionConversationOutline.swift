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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            totals
            // The table stays mounted while a session loads (an empty one
            // costs nothing): taking it down and building a new one on each
            // open was most of what opening a session cost.
            let conversation = self.conversation
            let isEmpty = conversation.toc.isEmpty
            SessionOutlineTable(
                entries: conversation.toc,
                currentTurn: conversation.currentTurn,
                contentToken: conversation.contentToken
            ) { conversation.reveal(turn: $0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if isEmpty {
                    Text(emptyText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .padding(14)
                }
            }
            footer
                .opacity(isEmpty ? 0 : 1)
                .disabled(isEmpty)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WorkbenchPorcelain.sidebarFill(for: colorScheme))
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
