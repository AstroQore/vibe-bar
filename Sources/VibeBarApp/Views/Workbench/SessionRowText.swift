import SwiftUI
import VibeBarCore

/// Titles and labels shared by the list and the conversation header.
enum SessionRowText {
    /// The session's own title, then what the parse found (its title, its
    /// first prompt), then the index's summary line — and, failing all of
    /// those, "Untitled session". Never the bare id: the id is one click
    /// away in the conversation header.
    static func title(summary: SessionSummary, listing: SessionStructureListing?) -> String {
        if let title = summary.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
           title != summary.sessionID {
            return title
        }
        if let title = listing?.title { return title }
        if let text = summary.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
           text != summary.sessionID {
            return text
        }
        return L10n.Workbench.Sessions.List.untitled
    }

    static func kindLabel(_ kind: SessionStructureKind) -> String? {
        switch kind {
        case .interactive: nil
        case .subagent: L10n.Workbench.Sessions.Kind.subagent
        case .fork: L10n.Workbench.Sessions.Kind.fork
        case .agentCreated: L10n.Workbench.Sessions.Kind.agentCreated
        case .exec: L10n.Workbench.Sessions.Kind.exec
        case .automation: L10n.Workbench.Sessions.Kind.automation
        case .guardian: L10n.Workbench.Sessions.Transcript.autoReviewDivider
        }
    }
}

/// A small label naming what kind of thread a session is.
struct SessionKindChip: View {
    let kind: SessionStructureKind

    var body: some View {
        if let label = SessionRowText.kindLabel(kind) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .frame(minHeight: 15)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .fixedSize()
        }
    }
}
