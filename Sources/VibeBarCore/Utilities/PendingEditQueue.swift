import Foundation

/// Debounced settings writes that cannot displace each other.
///
/// A control that writes on every keystroke, drag frame or stepper repeat
/// fans a settings publication out to every subscriber each time, so each one
/// holds its last change back for a moment. That moment has to be owned by
/// something longer-lived than the control — an inspector row is torn down the
/// instant another block is selected — and it has to be owned *per control*.
///
/// The per-control part is the lesson. A single pending slot looks sufficient
/// until two debounced controls are edited inside one window, at which point
/// the second `schedule` silently drops the first one's closure and the user's
/// change is gone. Keying the queue makes that unrepresentable rather than a
/// rule every future call site has to remember.
///
/// Entries are written in the order they were queued. That ordering is not
/// load-bearing — each queued write touches only the field its own control
/// owns — but it is deterministic, which matters when reading a diff.
@MainActor
public final class PendingEditQueue: ObservableObject {
    private struct Entry {
        let key: String
        let commit: () -> Void
    }

    private var entries: [Entry] = []
    private var task: Task<Void, Never>?
    private let delay: Duration

    public init(delay: Duration = .milliseconds(250)) {
        self.delay = delay
    }

    /// Queue `commit` under `key`, replacing only what that same key had
    /// queued. While the user is still moving one control, only its newest
    /// value matters; a different control's pending write is untouched.
    public func schedule(_ key: String, _ commit: @escaping () -> Void) {
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index] = Entry(key: key, commit: commit)
        } else {
            entries.append(Entry(key: key, commit: commit))
        }
        task?.cancel()
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Write everything queued, now.
    ///
    /// Safe when nothing is queued, and safe to re-enter: the queue is emptied
    /// before any of it runs, so a flush triggered from inside a commit finds
    /// nothing left to do rather than recursing.
    public func flush() {
        task?.cancel()
        task = nil
        let due = entries
        entries = []
        for entry in due { entry.commit() }
    }

    /// Keys still waiting, oldest first. The test seam; nothing in the app
    /// reads it.
    public var pendingKeys: [String] { entries.map(\.key) }

    deinit {
        // Nothing queued survives the queue. A torn-down editor must not leave
        // a timer running, and a finished test must not leave one for the next
        // one to trip over.
        task?.cancel()
    }
}
