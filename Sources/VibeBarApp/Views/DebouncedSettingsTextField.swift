import SwiftUI
import VibeBarCore

/// A Settings text field that types into its own draft and writes back later.
///
/// The label editors used to bind straight at `AppSettings`. Every character
/// therefore mutated the settings value, and every mutation fans a
/// `@Published` change out to every settings observer that is currently
/// alive — the popover, the mini window, the status-item render pipeline, and
/// this page's own long field list — before the next keystroke could be drawn.
/// Disk writes are already coalesced in `SettingsStore`; this coalesces the
/// render fan-out the same way.
///
/// The draft is committed on submit, after `idleDelay` of no typing, and on
/// disappear — so closing the window or switching Settings section
/// immediately after typing still keeps what was typed. Focus loss is
/// deliberately *not* a synchronous commit: clicking from one of the many
/// label fields into another must not publish global settings in the middle
/// of AppKit's first-responder hand-off.
///
/// Value semantics stay entirely with the binding: "" still means "remove the
/// override", trimming still happens where it happened before. This view only
/// decides *when* the binding is written.
struct DebouncedSettingsTextField: View {
    let prompt: String
    @Binding var value: String
    /// How long the field waits after the last keystroke before writing.
    let idleDelay: Duration
    /// A queue this field's pending write joins, so a caller that flushes
    /// before doing something else picks this field's draft up too.
    ///
    /// Without it the field owns its own timer, which nothing outside can
    /// reach: acting on the block while a draft is in flight — duplicating it,
    /// say — copies the pre-edit value, and the original then receives the new
    /// text while the copy keeps the old. Optional, so every existing call
    /// site keeps the self-contained behaviour it was written against.
    let pending: PendingEditQueue?
    let pendingKey: String

    @FocusState private var isFocused: Bool
    @State private var draft: String = ""

    init(
        prompt: String,
        pending: PendingEditQueue? = nil,
        pendingKey: String = "",
        value: Binding<String>,
        idleDelay: Duration = .milliseconds(400)
    ) {
        self.prompt = prompt
        self._value = value
        self.idleDelay = idleDelay
        self.pending = pending
        self.pendingKey = pendingKey
    }

    var body: some View {
        TextField(prompt, text: $draft)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onAppear { draft = value }
            .onSubmit(commit)
            // One timer per idle window: `task(id:)` cancels the pending
            // commit when another character arrives, and again when the field
            // leaves the view tree.
            .task(id: draft) {
                guard draft != value else { return }
                // With a queue, the wait is the queue's and the write is
                // reachable from outside; without one, this timer is the only
                // thing holding the keystroke back.
                if let pending {
                    let text = draft
                    pending.schedule(pendingKey) { value = text }
                    return
                }
                try? await Task.sleep(for: idleDelay)
                guard !Task.isCancelled else { return }
                commit()
            }
            // An external write — a reset, a migration, another window — may
            // only replace text the user is not currently editing.
            .onChange(of: value) { _, newValue in
                if !isFocused, newValue != draft { draft = newValue }
            }
            .onDisappear(perform: commit)
    }

    private func commit() {
        if draft != value { value = draft }
        // The binding may normalize what it stored (trim, drop an override).
        // Once the field is no longer being edited, show what was kept.
        if !isFocused, draft != value { draft = value }
    }
}
