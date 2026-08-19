import SwiftUI

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
/// The draft is committed on submit, on focus loss, after `idleDelay` of no
/// typing, and on disappear — so closing the window or switching Settings
/// section immediately after typing still keeps what was typed.
///
/// Value semantics stay entirely with the binding: "" still means "remove the
/// override", trimming still happens where it happened before. This view only
/// decides *when* the binding is written.
struct DebouncedSettingsTextField: View {
    let prompt: String
    @Binding var value: String
    /// How long the field waits after the last keystroke before writing.
    let idleDelay: Duration

    @FocusState private var isFocused: Bool
    @State private var draft: String = ""

    init(
        prompt: String,
        value: Binding<String>,
        idleDelay: Duration = .milliseconds(400)
    ) {
        self.prompt = prompt
        self._value = value
        self.idleDelay = idleDelay
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
                try? await Task.sleep(for: idleDelay)
                guard !Task.isCancelled else { return }
                commit()
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
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
