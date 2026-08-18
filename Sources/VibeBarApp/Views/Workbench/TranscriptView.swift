import SwiftUI
import VibeBarCore

/// The Sessions page's right column: one session, read top to bottom.
///
/// The transcript is the only place in this page that touches a session file,
/// and it is deliberately a plain vertical stack of cards rather than a chat
/// mock-up — these are logs being reviewed, not a conversation being had.
struct TranscriptView: View {
    let density: Theme.Density
    @ObservedObject var model: SessionManagerModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var matches: [Int] = []
    @State private var matchIndex = 0
    @State private var expanded: Set<Int> = []
    @State private var highlighted: Int?
    @State private var showsOutline = false

    var body: some View {
        Group {
            if let summary = model.selection {
                content(for: summary)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.selection?.id) { _, _ in resetReadingState() }
    }

    // MARK: - Content

    private func content(for summary: SessionSummary) -> some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // Keep the session's identity and recovery controls in view while
                // reviewing a long log. The scroll view below is intentionally
                // limited to transcript content; the header is a stable reading
                // anchor rather than another item in the transcript.
                SessionMetadataHeader(density: density, model: model, summary: summary)
                    .padding(.horizontal, density.popoverPaddingH)
                    .padding(.top, density.popoverPaddingV)

                HStack(spacing: 8) {
                    searchBar(proxy: proxy)
                    outlineButton(proxy: proxy)
                }
                .padding(.horizontal, density.popoverPaddingH)
                .padding(.vertical, max(8, density.popoverPaddingV / 2))

                Divider().opacity(0.45)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: density.cardSpacing) {
                    if model.isLoadingTranscript {
                        loading
                    } else if let error = model.transcriptError {
                        message(error, systemImage: "exclamationmark.triangle")
                    } else if let document = model.transcript {
                        if document.messages.isEmpty {
                            message("This session's log has no readable messages.", systemImage: "text.alignleft")
                        } else {
                            ForEach(document.messages) { entry in
                                TranscriptMessageCard(
                                    density: density,
                                    message: entry,
                                    accent: summary.provider.accent,
                                    query: query,
                                    isExpanded: expanded.contains(entry.seq),
                                    isHighlighted: highlighted == entry.seq,
                                    onToggleExpanded: { toggleExpanded(entry.seq) },
                                    onCopy: { model.copyToClipboard(entry.text, note: "Message copied.") }
                                )
                                .id(entry.seq)
                            }
                        }
                    }
                    }
                    .padding(.horizontal, density.popoverPaddingH)
                    .padding(.vertical, density.popoverPaddingV)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .cardSurface(density: density)
            .padding(.trailing, density.popoverPaddingH)
            .padding(.bottom, density.popoverPaddingV)
            .onChange(of: model.transcript) { _, _ in focusOnSearchHit(proxy: proxy) }
        }
    }

    /// A row picked out of a full-text result arrives with the message that
    /// matched; land on it once the transcript is actually on screen.
    private func focusOnSearchHit(proxy: ScrollViewProxy) {
        guard let seq = model.focusSeq, model.transcript != nil else { return }
        model.clearFocus()
        expanded.insert(seq)
        // One turn of the run loop: the stack is lazy, and scrolling to an id
        // in the same pass that introduced it lands on nothing.
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            scroll(to: seq, proxy: proxy)
        }
    }

    private var placeholder: some View {
        CardShell(density: density, alignment: .center) {
            Image(systemName: "text.bubble")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("No session selected")
                .font(.system(size: density.titleFontSize, weight: .semibold))
            Text("Pick a session on the left to read its transcript, copy its resume command, "
                + "or hand it back to its CLI.")
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(density.popoverPaddingH)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Reading the session log…")
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
    }

    private func message(_ text: String, systemImage: String) -> some View {
        CardShell(density: density, alignment: .center) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - In-transcript search

    private func searchBar(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: density.segmentedFontSize - 1))
                .foregroundStyle(.secondary)
            TextField("Find in transcript", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: density.segmentedFontSize))
                .onSubmit { step(by: 1, proxy: proxy) }
            if !query.isEmpty {
                Text(matches.isEmpty ? "none" : "\(matchIndex + 1)/\(matches.count)")
                    .font(.system(size: max(9, density.resetCountdownFontSize - 1), design: .rounded)
                        .monospacedDigit())
                    .foregroundStyle(.tertiary)
                BorderlessIconButton(systemImage: "chevron.up", help: "Previous match") {
                    step(by: -1, proxy: proxy)
                }
                .disabled(matches.isEmpty)
                BorderlessIconButton(systemImage: "chevron.down", help: "Next match") {
                    step(by: 1, proxy: proxy)
                }
                .disabled(matches.isEmpty)
                BorderlessIconButton(systemImage: "xmark.circle.fill", help: "Clear") {
                    query = ""
                }
            }
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 30)
        .background(
            Capsule().fill(Color.primary.opacity(0.045))
                .overlay(Capsule().stroke(Color.primary.opacity(0.11), lineWidth: 0.6))
        )
        .accessibilityLabel("Find in transcript")
        .onChange(of: query) { _, _ in recomputeMatches(proxy: proxy) }
        .onChange(of: model.transcript) { _, _ in recomputeMatches(proxy: proxy) }
    }

    /// Matches drive three things at once: the counter, the next / previous
    /// buttons, and which collapsed cards open — a hit hidden inside a
    /// folded 40 KB tool result is a hit the user cannot see.
    private func recomputeMatches(proxy: ScrollViewProxy) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, let document = model.transcript else {
            matches = []
            matchIndex = 0
            return
        }
        matches = document.messages
            .filter { $0.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .map(\.seq)
        expanded.formUnion(matches)
        matchIndex = 0
        guard let first = matches.first else { return }
        scroll(to: first, proxy: proxy)
    }

    private func step(by offset: Int, proxy: ScrollViewProxy) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + offset + matches.count) % matches.count
        scroll(to: matches[matchIndex], proxy: proxy)
    }

    private func scroll(to seq: Int, proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo(seq, anchor: .top)
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(seq, anchor: .top)
            }
        }
        flash(seq)
    }

    /// A brief tint on arrival, because a scroll that lands mid-transcript
    /// otherwise leaves the reader hunting for what moved.
    private func flash(_ seq: Int) {
        highlighted = seq
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard highlighted == seq else { return }
            highlighted = nil
        }
    }

    private func toggleExpanded(_ seq: Int) {
        if expanded.contains(seq) { expanded.remove(seq) } else { expanded.insert(seq) }
    }

    private func resetReadingState() {
        query = ""
        matches = []
        matchIndex = 0
        expanded = []
        highlighted = nil
        showsOutline = false
    }

    // MARK: - Outline

    private func outlineButton(proxy: ScrollViewProxy) -> some View {
        Button {
            showsOutline.toggle()
        } label: {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: density.segmentedFontSize, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Jump to a prompt")
        .accessibilityLabel("Show the transcript outline")
        .popover(isPresented: $showsOutline, arrowEdge: .trailing) {
            TranscriptToCView(
                density: density,
                entries: outlineEntries,
                onSelect: { seq in
                    showsOutline = false
                    scroll(to: seq, proxy: proxy)
                }
            )
        }
    }

    /// The user's own prompts only. An outline of every assistant turn is the
    /// transcript again; the questions are what someone scrolls back for.
    private var outlineEntries: [TranscriptToCView.Entry] {
        guard let document = model.transcript else { return [] }
        return document.messages
            .filter { $0.role == .user }
            .compactMap { entry in
                let stripped = CodexSessionAdapter.strippingIDEEnvelope(entry.text)
                let line = TranscriptFormatting.singleLine(stripped)
                guard !line.isEmpty else { return nil }
                return TranscriptToCView.Entry(
                    seq: entry.seq,
                    preview: TranscriptFormatting.clip(line, limit: 50)
                )
            }
    }
}

/// The transcript's masthead: who wrote this session, where, and how to get
/// back into it.
struct SessionMetadataHeader: View {
    let density: Theme.Density
    @ObservedObject var model: SessionManagerModel
    let summary: SessionSummary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: max(7, density.cardSpacing)) {
            HStack(alignment: .center, spacing: 10) {
                ToolBrandBadge(tool: summary.provider.tool, iconSize: 20, containerSize: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: density.titleFontSize, weight: .semibold))
                        .lineLimit(1)
                    compactMetadata
                }
                Spacer(minLength: 0)
                headerActions
            }
            if showsDetails {
                Divider().opacity(0.42)
                facts
                if summary.provider == .antigravity {
                    notice
                }
                resumeRow
            }
        }
        .padding(.vertical, 2)
    }

    private var compactMetadata: some View {
        HStack(spacing: 6) {
            Text(providerLabel)
                .font(.system(size: max(10, density.subtitleFontSize - 2), weight: .semibold))
                .padding(.horizontal, 7)
                .frame(minHeight: 18)
                .background(Capsule().fill(summary.provider.accent.opacity(0.16)))
            if let project = summary.projectDir {
                Label(SessionManagerModel.projectTitle(project), systemImage: "folder")
                    .lineLimit(1)
                    .help(project)
            }
            if summary.hasKnownMessageCount {
                Text("\(summary.messageCount) messages")
                    .monospacedDigit()
            }
        }
        .font(.system(size: max(10, density.resetCountdownFontSize - 1), design: .rounded))
        .foregroundStyle(.secondary)
    }

    private var headerActions: some View {
        HStack(spacing: 6) {
            if model.resumeShellLine(for: summary) != nil {
                Button {
                    model.copyResumeCommand(for: summary)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 16, height: 16)
                }
                .help("Copy resume command")
                .accessibilityLabel("Copy resume command")

                Button {
                    model.resumeInTerminal(summary)
                } label: {
                    Label("Open", systemImage: "terminal")
                        .font(.system(size: max(10, density.segmentedFontSize - 1), weight: .semibold))
                }
                .help("Run it in \(model.preferredTerminal.displayName)")
            }

            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    showsDetails.toggle()
                }
            } label: {
                Label("Details", systemImage: "chevron.down")
                    .font(.system(size: max(10, density.segmentedFontSize - 1), weight: .semibold))
                    .labelStyle(.titleAndIcon)
            }
            .accessibilityValue(showsDetails ? "Expanded" : "Collapsed")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
    }

    private var title: String {
        if let title = summary.title, !title.isEmpty { return title }
        if let text = summary.summary, !text.isEmpty { return text }
        return summary.sessionID
    }

    private var providerLabel: String {
        guard let variant = summary.providerVariant, !variant.isEmpty else {
            return summary.provider.displayName
        }
        return "\(summary.provider.displayName) · \(variant)"
    }

    // MARK: - Facts

    private var facts: some View {
        VStack(alignment: .leading, spacing: 4) {
            factRow(label: "ID", monospaced: true, value: summary.sessionID) {
                model.copyToClipboard(summary.sessionID, note: "Session ID copied.")
            }
            if let project = summary.projectDir {
                factRow(label: "CWD", monospaced: true, value: project) {
                    model.copyToClipboard(project, note: "Working directory copied.")
                }
            }
            if let created = summary.createdAt {
                factRow(label: "Created", value: Self.stamp.string(from: created), copy: nil)
            }
            if let active = summary.lastActiveAt {
                factRow(label: "Last active", value: Self.stamp.string(from: active), copy: nil)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                factLabel("Source")
                Text(summary.sourcePath)
                    .font(.system(size: max(9, density.resetCountdownFontSize - 1), design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func factRow(
        label: String,
        monospaced: Bool = false,
        value: String,
        copy: (() -> Void)?
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            factLabel(label)
            Text(value)
                .font(.system(
                    size: density.subtitleFontSize - 1,
                    design: monospaced ? .monospaced : .default
                ))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let copy {
                BorderlessIconButton(systemImage: "doc.on.doc", help: "Copy \(label)", action: copy)
            }
            Spacer(minLength: 0)
        }
    }

    private func factLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: max(10, density.resetCountdownFontSize - 2), weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.4)
            .frame(width: 74, alignment: .leading)
    }

    private var notice: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: density.subtitleFontSize - 1))
            Text("AntiGravity stores its turns as an undocumented binary payload, so this "
                + "transcript is a partial reconstruction and its sessions cannot be deleted "
                + "from here — the IDE keeps them open.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: max(9, density.resetCountdownFontSize)))
        .foregroundStyle(.secondary)
    }

    // MARK: - Resume

    @ViewBuilder
    private var resumeRow: some View {
        if let line = model.resumeShellLine(for: summary) {
            VStack(alignment: .leading, spacing: 6) {
                Text("RESUME")
                    .font(.system(size: max(10, density.resetCountdownFontSize - 2), weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.4)
                Text(line)
                    .font(.system(size: density.subtitleFontSize - 1, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.045))
                    )
                HStack(spacing: 8) {
                    Button {
                        model.copyResumeCommand(for: summary)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.system(size: density.segmentedFontSize - 1, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 28)
                    Button {
                        model.resumeInTerminal(summary)
                    } label: {
                        Label("Open in Terminal", systemImage: "terminal")
                            .font(.system(size: density.segmentedFontSize - 1, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 28)
                    .help("Run it in \(model.preferredTerminal.displayName)")
                    Spacer(minLength: 0)
                }
            }
        } else {
            Text("This session has no command-line entry point.")
                .font(.system(size: max(9, density.resetCountdownFontSize)))
                .foregroundStyle(.tertiary)
        }
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// One turn.
struct TranscriptMessageCard: View {
    let density: Theme.Density
    let message: SessionMessage
    let accent: Color
    let query: String
    let isExpanded: Bool
    let isHighlighted: Bool
    let onToggleExpanded: () -> Void
    let onCopy: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    /// Past this a card stops being a message and starts being a document —
    /// a pasted file, a diff, a directory listing.
    static let collapseThreshold = 3_000
    /// Enough of the head to tell what the block is before opening it.
    static let collapsedLength = 1_500

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Capsule()
                .fill(edgeColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 5) {
                header
                body(text: displayedText)
                if isTruncated {
                    Button(isExpanded ? "Show less" : "Show more (\(message.text.count) chars)") {
                        onToggleExpanded()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: max(9, density.resetCountdownFontSize), weight: .semibold))
                    .foregroundStyle(accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 9)
        .background(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .fill(surfaceFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .stroke(borderColor, lineWidth: isHovering || isHighlighted ? 0.8 : 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isHighlighted)
        .contextMenu {
            Button {
                onCopy()
            } label: {
                Label("Copy Message", systemImage: "doc.on.doc")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(roleLabel.uppercased())
                .font(.system(size: max(10, density.resetCountdownFontSize - 1), weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.4)
            if let timestamp = message.timestamp {
                Text(Self.time.string(from: timestamp))
                    .font(.system(size: max(10, density.resetCountdownFontSize - 1), design: .rounded)
                        .monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(isHovering ? 0.09 : 0)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(isHovering ? .secondary : .tertiary)
            .opacity(isHovering ? 1 : 0.42)
            .help("Copy this message")
            .accessibilityLabel("Copy this message")
        }
    }

    /// `SelectableTextView` rather than `Text(...).textSelection(.enabled)`:
    /// SwiftUI's selection overlay re-lays out every bubble on each graph
    /// update and pinned the main thread at ~99 % with a transcript open.
    private func body(text: String) -> some View {
        SelectableTextView(
            text: TranscriptFormatting.highlighted(text, query: query, accent: accent),
            font: isMonospaced
                ? .monospacedSystemFont(ofSize: density.subtitleFontSize, weight: .regular)
                : .systemFont(ofSize: density.subtitleFontSize),
            textColor: message.role == .system ? .secondaryLabelColor : .labelColor
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayedText: String {
        guard isTruncated, !isExpanded else { return message.text }
        return String(message.text.prefix(Self.collapsedLength)) + "…"
    }

    private var isTruncated: Bool {
        message.text.count > Self.collapseThreshold
    }

    /// Tool output is machine text — alignment carries meaning in it that a
    /// proportional font destroys.
    private var isMonospaced: Bool {
        message.role == .tool
    }

    private var edgeColor: Color {
        switch message.role {
        case .user:      accent
        case .assistant: Color.secondary.opacity(0.45)
        case .tool:      Color.secondary.opacity(0.25)
        case .system:    Color.secondary.opacity(0.18)
        case .other:     Color.secondary.opacity(0.18)
        }
    }

    private var surfaceFill: Color {
        if isHighlighted { return accent.opacity(isHovering ? 0.18 : 0.14) }
        return Color.primary.opacity(isHovering ? 0.07 : 0.032)
    }

    private var borderColor: Color {
        if isHighlighted { return accent.opacity(isHovering ? 0.52 : 0.36) }
        return Color.primary.opacity(isHovering ? 0.18 : 0.075)
    }

    private var roleLabel: String {
        switch message.role {
        case .user:      "You"
        case .assistant: "Assistant"
        case .tool:      "Tool"
        case .system:    "System"
        case .other:     "Note"
        }
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

/// The prompts in a session, as a jump list.
struct TranscriptToCView: View {
    struct Entry: Identifiable, Hashable {
        let seq: Int
        let preview: String

        var id: Int { seq }
    }

    let density: Theme.Density
    let entries: [Entry]
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROMPTS")
                .font(.system(size: max(8, density.subtitleFontSize - 2), weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.4)
            if entries.isEmpty {
                Text("This transcript has no user prompts.")
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(entries) { entry in
                            BorderlessRowButton(action: { onSelect(entry.seq) }) {
                                HStack(alignment: .top, spacing: 7) {
                                    Text("\(entry.seq)")
                                        .font(.system(size: max(8, density.resetCountdownFontSize - 1),
                                                      design: .rounded).monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 26, alignment: .trailing)
                                    Text(entry.preview)
                                        .font(.system(size: density.subtitleFontSize))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                            }
                            .accessibilityLabel(entry.preview)
                        }
                    }
                }
                .frame(maxHeight: 340)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

/// Display-side text shaping for the transcript pane.
enum TranscriptFormatting {
    static func singleLine(_ text: String) -> String {
        text
            .split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func clip(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Tint every occurrence of the find query. Bounded on purpose: a
    /// one-character query against a 40 KB tool result would otherwise build
    /// tens of thousands of attribute runs to draw one screen.
    static let maxHighlights = 200

    static func highlighted(_ text: String, query: String, accent: Color) -> AttributedString {
        var attributed = AttributedString(text)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return attributed }

        var searchRange = attributed.startIndex..<attributed.endIndex
        var applied = 0
        while applied < maxHighlights,
              let found = attributed[searchRange].range(
                  of: needle,
                  options: [.caseInsensitive, .diacriticInsensitive]
              ) {
            attributed[found].backgroundColor = accent.opacity(0.28)
            applied += 1
            guard found.upperBound < attributed.endIndex else { break }
            searchRange = found.upperBound..<attributed.endIndex
        }
        return attributed
    }
}
