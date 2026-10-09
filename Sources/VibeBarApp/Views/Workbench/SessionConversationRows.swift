import SwiftUI
import VibeBarCore

/// What a conversation row can ask the page to do. Closures, so rows stay
/// plain values; never compared (`SessionConversationRow.==` ignores them).
struct SessionConversationActions {
    let loadEarlier: () -> Void
    let loadLater: () -> Void
    let resumeLoading: () -> Void
    let toggleProcess: (Int) -> Void
    let toggleStep: (Int, Int) -> Void
    let openChild: (String) -> Void
    let copy: (String, String) -> Void
}

/// One row of the conversation. Equatable on the item it draws, so a
/// rebuilt render list re-evaluates only the rows whose values changed.
struct SessionConversationRow: View, Equatable {
    let item: SessionConversationItem
    let density: Theme.Density
    let accent: Color
    let actions: SessionConversationActions

    static func == (lhs: SessionConversationRow, rhs: SessionConversationRow) -> Bool {
        lhs.item == rhs.item && lhs.accent == rhs.accent && lhs.density.profile == rhs.density.profile
    }

    var body: some View {
        switch item {
        case let .earlier(edge):
            SessionEdgeRow(
                edge: edge,
                title: L10n.Workbench.Sessions.Conversation.loadEarlier(count: AppLocale.number(edge.remaining)),
                systemImage: "arrow.up",
                action: actions.loadEarlier
            )
            .padding(.vertical, 8)
        case let .later(edge):
            SessionEdgeRow(
                edge: edge,
                title: L10n.Workbench.Sessions.Conversation.loadLater(count: AppLocale.number(edge.remaining)),
                systemImage: "arrow.down",
                action: actions.loadLater
            )
            .padding(.vertical, 8)
        case let .header(header):
            SessionTurnHeaderRow(header: header, density: density)
        case let .prompt(prompt):
            SessionPromptRow(prompt: prompt, density: density, accent: accent, copy: actions.copy)
        case let .process(process):
            SessionProcessRow(process: process, density: density) { actions.toggleProcess(process.turn) }
                .padding(.top, 8)
        case let .step(step):
            SessionStepRowView(step: step, density: density, accent: accent) {
                actions.toggleStep(step.turn, step.row.position)
            } openChild: { actions.openChild($0) }
        case let .answer(answer):
            SessionAnswerRow(answer: answer, density: density, copy: actions.copy)
                .padding(.top, 10)
        case let .pending(pending):
            SessionPendingRow(pending: pending, density: density, resume: actions.resumeLoading)
                .padding(.top, 8)
        }
    }
}

// MARK: - Edges

private struct SessionEdgeRow: View {
    let edge: SessionConversationEdge
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            if edge.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button(action: action) {
                    Label(title, systemImage: systemImage)
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(WorkbenchPillButtonStyle())
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 30)
    }
}

// MARK: - Turn header

private struct SessionTurnHeaderRow: View {
    let header: SessionTurnHeader
    let density: Theme.Density

    var body: some View {
        HStack(spacing: 7) {
            Text(L10n.Workbench.Sessions.Turn.ordinal(number: AppLocale.number(header.ordinal)))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            if let started = header.startedAt {
                Text(AppLocale.string(started, template: "MMMdjmm"))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if let duration = header.durationMs, duration > 0 {
                Text(SessionDurationText.compact(milliseconds: duration))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if let status = statusLabel {
                Text(status.text)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(status.color)
                    .padding(.horizontal, 5)
                    .frame(minHeight: 15)
                    .background(Capsule().fill(status.color.opacity(0.12)))
                    .help(status.help ?? "")
            }
            if header.injectedCount > 0 {
                Text(L10n.Workbench.Sessions.Turn.injected(count: header.injectedCount))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if header.additionalHumanMessages > 0 {
                Text(L10n.Workbench.Sessions.Turn.followUps(count: header.additionalHumanMessages))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if let model = header.model {
                Text(model)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .frame(minHeight: 15)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            ForEach(Array(header.verdicts.enumerated()), id: \.offset) { _, verdict in
                SessionVerdictBadge(verdict: verdict)
            }
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
                .frame(maxWidth: .infinity)
        }
        .lineLimit(1)
        .padding(.top, header.ordinal == 1 ? 6 : 22)
        .padding(.bottom, 6)
        .opacity(header.status == .abandoned ? 0.55 : 1)
        // Tooltips only where they explain something rare (an abandoned
        // turn): each one is a responder, and a header is drawn per turn.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.Workbench.Sessions.Turn.ordinal(number: AppLocale.number(header.ordinal)))
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(.isHeader)
    }

    private var accessibilityHint: String {
        var parts: [String] = []
        if header.injectedCount > 0 { parts.append(L10n.Workbench.Sessions.Turn.injectedHelp) }
        if !header.verdicts.isEmpty { parts.append(L10n.Workbench.Sessions.Verdict.help) }
        return parts.joined(separator: " ")
    }

    private var statusLabel: (text: String, color: Color, help: String?)? {
        switch header.status {
        case .completed: nil
        case .aborted: (L10n.Workbench.Sessions.Turn.Status.aborted, .orange, nil)
        case .open: (L10n.Workbench.Sessions.Turn.Status.open, .secondary, nil)
        case .abandoned: (
            L10n.Workbench.Sessions.Turn.Status.abandoned,
            .secondary,
            L10n.Workbench.Sessions.Turn.Status.abandonedHelp
        )
        }
    }
}

/// An Auto Review verdict: allowed or denied, and the risk the reviewer saw.
private struct SessionVerdictBadge: View {
    let verdict: SessionStructure.GuardianVerdict

    var body: some View {
        let color: Color = verdict.isDenied ? .red : .green
        HStack(spacing: 3) {
            Image(systemName: verdict.isDenied ? "xmark.shield.fill" : "checkmark.shield.fill")
                .font(.system(size: 9))
            Text(verdict.isDenied ? L10n.Workbench.Sessions.Verdict.deny : L10n.Workbench.Sessions.Verdict.allow)
            if let risk = verdict.riskLevel, !risk.isEmpty {
                Text(L10n.Workbench.Sessions.Verdict.risk(level: risk))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .frame(minHeight: 15)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - Prompt

/// The person's prompt, as a bubble on the right; anything that was not
/// typed by the person — an automation, another agent, a review request —
/// is labelled for what it is and kept on the left.
private struct SessionPromptRow: View {
    let prompt: SessionTurnPrompt
    let density: Theme.Density
    let accent: Color
    let copy: (String, String) -> Void

    @State private var isUnfolded = false

    var body: some View {
        if prompt.origin == .human {
            // A trailing frame, not an `HStack` with a spacer: the stack would
            // measure the bubble's text at several widths to settle the
            // spacer.
            content(hugging: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(accent.opacity(0.13))
                )
                .padding(.leading, 56)
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Label(originLabel, systemImage: originSymbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                if prompt.text != nil || prompt.preview != nil {
                    content(hugging: false)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                }
            }
        }
    }

    @ViewBuilder
    private func content(hugging: Bool) -> some View {
        if let text = prompt.text {
            // Folded, a long prompt shows its first lines: a pasted log is a
            // page the reader usually came to skip.
            let folded = prompt.isLong && !isUnfolded
            VStack(alignment: .trailing, spacing: 5) {
                SessionRichTextView(
                    text: text,
                    hugsWidth: hugging,
                    maximumLines: folded ? 8 : 0,
                    copyTitle: L10n.Workbench.Sessions.Turn.copyPrompt
                ) { copy($0, L10n.Workbench.Sessions.Turn.promptCopied) }
                if prompt.isLong { foldButton(count: text.source.count) }
            }
        } else if let preview = prompt.preview {
            Text(preview)
                .font(.system(size: density.subtitleFontSize + 0.5))
                .foregroundStyle(.secondary)
        }
    }

    private func foldButton(count: Int) -> some View {
        Button(isUnfolded
            ? L10n.Workbench.Sessions.Message.showLess
            : L10n.Workbench.Sessions.Message.showMore(count: count)) {
            isUnfolded.toggle()
        }
        .buttonStyle(.vibeBar)
        .font(.system(size: max(9, density.resetCountdownFontSize), weight: .semibold))
        .foregroundStyle(accent)
    }

    private var originLabel: String {
        switch prompt.origin {
        case .automation: L10n.Workbench.Sessions.Turn.Origin.automation
        case .agent: L10n.Workbench.Sessions.Turn.Origin.agent
        case .guardianRequest: L10n.Workbench.Sessions.Turn.Origin.guardianRequest
        case .none, .human: L10n.Workbench.Sessions.Turn.Origin.none
        }
    }

    private var originSymbol: String {
        switch prompt.origin {
        case .automation: "clock.arrow.circlepath"
        case .agent: "person.2"
        case .guardianRequest: "checkmark.shield"
        case .none, .human: "arrow.turn.down.right"
        }
    }
}

// MARK: - Process

private struct SessionProcessRow: View {
    let process: SessionTurnProcess
    let density: Theme.Density
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(process.isExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Text(L10n.Workbench.Sessions.Turn.process)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                ForEach(facts, id: \.self) { fact in
                    separator
                    Text(fact)
                }
                if process.counts.failed > 0 {
                    separator
                    Text(L10n.Workbench.Sessions.Turn.failures(count: process.counts.failed))
                        .foregroundStyle(.red)
                }
                if let duration = process.durationMs, duration > 0 {
                    separator
                    Text(SessionDurationText.compact(milliseconds: duration))
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(process.isExpanded ? 0.055 : 0.035))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.vibeBar)
        // One string rather than the label's texts joined by the
        // accessibility engine, which looks a separator up per child.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
        .accessibilityHint(process.isExpanded ? L10n.Workbench.Sessions.Turn.hideSteps : L10n.Workbench.Sessions.Turn.showSteps)
        .accessibilityValue(process.isExpanded
            ? L10n.Workbench.Sessions.Details.expanded
            : L10n.Workbench.Sessions.Details.collapsed)
    }

    private var accessibilityText: String {
        var parts = [L10n.Workbench.Sessions.Turn.process] + facts
        if process.counts.failed > 0 { parts.append(L10n.Workbench.Sessions.Turn.failures(count: process.counts.failed)) }
        return parts.joined(separator: " · ")
    }

    private var separator: some View {
        // Verbatim: a literal `Text("·")` is a LocalizedStringKey, and its
        // bundle lookup showed up as the single largest cost of opening a
        // conversation.
        Text(verbatim: "·").foregroundStyle(.quaternary).accessibilityHidden(true)
    }

    private var facts: [String] {
        let counts = process.counts
        guard counts.steps > 0 else { return [L10n.Workbench.Sessions.Turn.thinking] }
        var out = [L10n.Workbench.Sessions.Turn.steps(count: counts.steps)]
        if counts.commands > 0 { out.append(L10n.Workbench.Sessions.Turn.commands(count: counts.commands)) }
        return out
    }
}

// MARK: - Step

/// One step of a turn's process: what ran, with what, how it went.
private struct SessionStepRowView: View {
    let step: SessionTurnStep
    let density: Theme.Density
    let accent: Color
    let toggle: () -> Void
    let openChild: (String) -> Void

    private var value: SessionStructure.Step { step.row.step }

    /// The parsers' marker name for a context compaction — an identifier,
    /// not copy.
    private static let compactionNote = "compaction"
    private var isCompaction: Bool { value.name == Self.compactionNote }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch value.kind {
            case .thinking:
                quietLine(
                    systemImage: "brain",
                    text: value.thinkingCharacters.map {
                        L10n.Workbench.Sessions.Step.thinking(count: AppLocale.number($0))
                    } ?? L10n.Workbench.Sessions.Step.thinkingHidden
                )
            case .note:
                quietLine(
                    systemImage: isCompaction ? "arrow.triangle.2.circlepath" : "text.alignleft",
                    text: isCompaction ? L10n.Workbench.Sessions.Step.compaction : value.name
                )
            default:
                actionLine
                if step.isExpanded {
                    detail
                        .padding(.leading, 34)
                        .padding(.trailing, 8)
                        .padding(.bottom, 6)
                }
            }
        }
        .padding(.leading, 14 + CGFloat(step.row.depth) * 18)
    }

    private func quietLine(systemImage: String, text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 10))
                .frame(width: 16)
            Text(verbatim: text)
                .lineLimit(1)
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 8)
        .frame(minHeight: 22, alignment: .leading)
    }

    /// Two marks and one text — the name and arguments are runs of one
    /// attributed string — and the duration: a process opens a screenful
    /// of these at once, and a stack of separate texts and shapes per row
    /// was most of what that cost.
    private var actionLine: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Image(systemName: value.pairing == .pending ? "circle" : "circle.fill")
                    .font(.system(size: 6.5))
                    .foregroundStyle(value.pairing == .pending ? Color.secondary.opacity(0.6) : statusColor)
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(summaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if let duration = value.durationMs {
                    Text(verbatim: SessionDurationText.step(milliseconds: duration))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
                Image(systemName: step.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.vibeBar)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value.name + " " + (value.argsSummary ?? ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
        .accessibilityValue(value.isError ? L10n.Workbench.Sessions.Step.failed : L10n.Workbench.Sessions.Step.succeeded)
    }

    private var summaryText: AttributedString {
        var name = AttributedString(value.name)
        name.font = .system(size: 11.5, weight: .semibold)
        name.foregroundColor = Color.primary.opacity(0.85)
        guard let args = value.argsSummary else { return name }
        var rest = AttributedString("  " + args)
        rest.font = .system(size: 11, design: .monospaced)
        rest.foregroundColor = .secondary
        return name + rest
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let args = value.argsSummary {
                detailBlock(caption: L10n.Workbench.Sessions.Step.arguments, text: args)
            }
            if let result = value.resultSummary {
                detailBlock(caption: L10n.Workbench.Sessions.Step.result, text: result, isError: value.isError)
            }
            HStack(spacing: 8) {
                if let exit = value.exitCode {
                    Text(L10n.Workbench.Sessions.Step.exitCode(code: String(exit)))
                        .foregroundStyle(exit == 0 ? Color.secondary : Color.red)
                }
                switch value.pairing {
                case .pending: Text(L10n.Workbench.Sessions.Step.pending).foregroundStyle(.tertiary)
                case .orphanResult: Text(L10n.Workbench.Sessions.Step.orphan).foregroundStyle(.tertiary)
                case .paired, .notApplicable: EmptyView()
                }
                if let verdict = value.verdict {
                    SessionVerdictBadge(verdict: verdict)
                }
            }
            .font(.system(size: 10.5))
            if let child = value.childSessionID {
                Button {
                    openChild(child)
                } label: {
                    Label(L10n.Workbench.Sessions.Step.openThread, systemImage: "arrow.right.circle")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(WorkbenchPillButtonStyle())
            }
            if value.argsSummary == nil, value.resultSummary == nil, value.exitCode == nil, value.childSessionID == nil {
                Text(L10n.Workbench.Sessions.Step.noDetail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func detailBlock(caption: String, text: String, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(caption.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isError ? Color.red.opacity(0.9) : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                )
        }
    }

    private var statusColor: Color {
        if value.isError { return .red }
        switch value.pairing {
        case .pending: return .clear
        case .orphanResult: return .orange
        case .paired, .notApplicable: return .green.opacity(0.8)
        }
    }

    private var symbol: String {
        switch value.kind {
        case .toolCall: value.name == "file_change" || value.name == "apply_patch" ? "doc.badge.gearshape" : "wrench.and.screwdriver"
        case .command: "terminal"
        case .mcpCall: "puzzlepiece.extension"
        case .subagent: "person.2"
        case .guardianVerdict: "checkmark.shield"
        case .thinking: "brain"
        case .note: "text.alignleft"
        }
    }
}

// MARK: - Answer

private struct SessionAnswerRow: View {
    let answer: SessionTurnAnswer
    let density: Theme.Density
    let copy: (String, String) -> Void

    var body: some View {
        Group {
            if let text = answer.text {
                SessionRichTextView(text: text, copyTitle: L10n.Workbench.Sessions.Turn.copyAnswer) {
                    copy($0, L10n.Workbench.Sessions.Turn.answerCopied)
                }
            } else {
                Text(answer.document.source)
                    .font(.system(size: density.subtitleFontSize + 1))
            }
        }
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Pending

private struct SessionPendingRow: View {
    let pending: SessionTurnPending
    let density: Theme.Density
    let resume: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch pending.state {
            case .loading:
                ProgressView().controlSize(.mini)
                Text(L10n.Workbench.Sessions.Turn.loading)
            case .stopped:
                Image(systemName: "pause.circle")
                Text(L10n.Workbench.Sessions.Turn.stopped)
                Button(L10n.Workbench.Sessions.Turn.continueLoading, action: resume)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            case .unavailable:
                Image(systemName: "exclamationmark.triangle")
                Text(L10n.Workbench.Sessions.Turn.unavailable)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 10)
        .frame(minHeight: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }
}
