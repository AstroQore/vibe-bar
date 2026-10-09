import Foundation

/// What a click on a Sessions list row does to the conversation pane.
///
/// The pane follows the index model's selection through a publisher that
/// drops repeats. A thread opened from a conversation (a subagent step, a
/// Claude subagent transcript) replaces the pane's session without moving
/// that selection, so a click on the parent's row — still the selection —
/// would be dropped and the pane would stay on the thread.
public enum SessionRowClick: Sendable, Equatable {
    /// Select the row; the selection publisher opens it.
    case select
    /// The row is already selected but the pane shows another session:
    /// open the row in the pane directly.
    case reopen

    public static func route(rowID: String, selectedID: String?, shownID: String?) -> SessionRowClick {
        rowID == selectedID && shownID != rowID ? .reopen : .select
    }
}
