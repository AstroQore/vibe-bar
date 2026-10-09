import Foundation

// MARK: - Outline (table of contents)

/// One entry of the conversation outline: a turn, by its prompt.
public struct SessionConversationTOCEntry: Sendable, Hashable, Identifiable {
    public var turnIndex: Int
    /// 1-based, as the page numbers turns.
    public var ordinal: Int
    /// The prompt preview; nil for a turn nobody typed (the view labels it by
    /// `origin`).
    public var preview: String?
    public var origin: SessionStructure.PromptOrigin
    public var startedAt: Date?
    public var steps: Int
    public var failed: Int
    /// Human prompts the turn contributes to `SessionStats.promptCount`.
    public var humanPrompts: Int
    public var status: SessionStructure.TurnStatus
    /// The preview's width on one line in the contents column's font,
    /// measured off the main actor with the entries (`measuredEntries`, by
    /// the pane's `SessionConversationRendering`); the column sizes its rows
    /// from it. 0 when not measured.
    public var previewWidth: Double = 0

    public var id: Int { turnIndex }

    /// The outline's sums, on the same rule `SessionStats` is built by (a
    /// rewound turn counts as a turn but adds no prompts or steps), so the
    /// contents column and the masthead state the same numbers.
    public struct Totals: Sendable, Hashable {
        public var turns = 0
        public var prompts = 0
        public var steps = 0
        public var failed = 0
    }

    public static func totals(_ entries: [SessionConversationTOCEntry]) -> Totals {
        var out = Totals(turns: entries.count)
        for entry in entries where entry.status != .abandoned {
            out.prompts += entry.humanPrompts
            out.steps += entry.steps
            out.failed += entry.failed
        }
        return out
    }

    public init(outline: SessionTurnOutline) {
        turnIndex = outline.index
        ordinal = outline.index + 1
        let trimmed = outline.promptPreview?.trimmingCharacters(in: .whitespacesAndNewlines)
        preview = (trimmed?.isEmpty ?? true) ? nil : trimmed
        origin = outline.origin
        startedAt = outline.startedAt
        steps = outline.counts.steps
        failed = outline.counts.failed
        humanPrompts = (outline.origin == .human ? 1 : 0) + outline.additionalHumanMessages
        status = outline.status
    }

    /// One entry per turn, in order. Abandoned turns are kept — they are
    /// part of what happened — and the view dims them.
    public static func entries(from outline: [SessionTurnOutline]) -> [SessionConversationTOCEntry] {
        outline.map(SessionConversationTOCEntry.init(outline:))
    }
}

// MARK: - Materialized turns

/// One step as the page lists it.
public struct SessionStepRow: Sendable, Hashable, Identifiable {
    /// Position among the turn's steps.
    public var position: Int
    public var step: SessionStructure.Step
    /// 1 for a call made from inside another (a command run by a code-mode
    /// script), else 0.
    public var depth: Int

    public var id: Int { position }
}

/// A full-detail turn, prepared for drawing: Markdown parsed, steps
/// filtered. Built off the main actor, once per turn.
public struct SessionTurnPresentation: Sendable, Hashable {
    /// A prompt longer than this (characters or lines) opens folded: a
    /// pasted log is a page of text the reader usually came to skip, and
    /// laying all of it out is the most expensive thing a turn draws.
    public static let longPromptCharacters = 700
    public static let longPromptLines = 12

    public var index: Int
    public var prompt: SessionMarkdownDocument?
    /// Whether the prompt is long enough to open folded.
    public var isPromptLong = false
    public var steps: [SessionStepRow]
    public var answer: SessionMarkdownDocument?
    /// `prompt` and `answer` as the pane draws them, at the model's
    /// `SessionRichTextStyle`; nil without a renderer.
    public var promptText: SessionRenderedText?
    public var answerText: SessionRenderedText?

    /// Notes the parser records only as markers, with nothing to read in
    /// them, are not listed: a Codex rollout has one `commentary` note per
    /// interim message and a hundred of them say nothing.
    static let silentNotes: Set<String> = ["commentary"]

    public static func make(
        _ turn: SessionStructure.Turn,
        markdown: SessionMarkdownCache,
        style: SessionRichTextStyle = SessionRichTextStyle(),
        render: (@Sendable (SessionMarkdownDocument, CGFloat) -> AnyObject)? = nil
    ) -> SessionTurnPresentation {
        let promptText = turn.prompt.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let answerText = turn.finalAnswer?.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [SessionStepRow] = []
        rows.reserveCapacity(turn.steps.count)
        for (position, step) in turn.steps.enumerated() {
            if step.kind == .note, silentNotes.contains(step.name) { continue }
            rows.append(SessionStepRow(position: position, step: step, depth: step.parentCallID == nil ? 0 : 1))
        }
        let isLong = promptText.map {
            $0.count > longPromptCharacters || $0.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } >= longPromptLines
        } ?? false
        let prompt = promptText.flatMap { $0.isEmpty ? nil : $0 }
        let answer = answerText.flatMap { $0.isEmpty ? nil : $0 }
        return SessionTurnPresentation(
            index: turn.index,
            prompt: prompt.map { markdown.document(for: $0) },
            isPromptLong: isLong,
            steps: rows,
            answer: answer.map { markdown.document(for: $0) },
            promptText: render.flatMap { render in prompt.map { markdown.rendered(for: $0, size: style.promptSize, render: render) } },
            answerText: render.flatMap { render in answer.map { markdown.rendered(for: $0, size: style.answerSize, render: render) } }
        )
    }
}

// MARK: - Render list

/// What one turn's header says.
public struct SessionTurnHeader: Sendable, Hashable {
    public var turn: Int
    public var ordinal: Int
    public var startedAt: Date?
    public var durationMs: Int?
    public var status: SessionStructure.TurnStatus
    public var origin: SessionStructure.PromptOrigin
    public var injectedCount: Int
    public var additionalHumanMessages: Int
    /// Set only when the session ran on more than one model.
    public var model: String?
    public var verdicts: [SessionStructure.GuardianVerdict]
}

public struct SessionTurnPrompt: Sendable, Hashable {
    public var turn: Int
    public var origin: SessionStructure.PromptOrigin
    public var document: SessionMarkdownDocument?
    /// The outline's one-line preview, shown while the turn loads.
    public var preview: String?
    /// Long enough to open folded (`SessionTurnPresentation.isPromptLong`).
    public var isLong: Bool = false
    /// `document` as drawn; nil while the turn loads.
    public var text: SessionRenderedText?
}

/// The collapsible "what the agent did" row.
public struct SessionTurnProcess: Sendable, Hashable {
    public var turn: Int
    public var counts: SessionStructure.TurnCounts
    public var durationMs: Int?
    public var isExpanded: Bool
    /// False while the turn is outline-only (steps not read yet).
    public var isAvailable: Bool
    /// Rows the expansion lists (actions plus thinking and notes).
    public var rowCount: Int
}

public struct SessionTurnStep: Sendable, Hashable {
    public var turn: Int
    public var row: SessionStepRow
    public var isExpanded: Bool
}

public struct SessionTurnAnswer: Sendable, Hashable {
    public var turn: Int
    public var document: SessionMarkdownDocument
    /// `document` as drawn.
    public var text: SessionRenderedText?
}

/// A turn in the window whose full detail has not arrived.
public struct SessionTurnPending: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        case loading
        /// Loading was stopped; the view offers to resume.
        case stopped
        /// The read came back empty (the file changed under it).
        case unavailable
    }

    public var turn: Int
    public var state: State
}

public struct SessionConversationEdge: Sendable, Hashable {
    public var remaining: Int
    public var isLoading: Bool
}

/// One lazily drawn row of the conversation. A turn is several rows — its
/// header, prompt, process, each expanded step, its answer — so a turn with
/// three hundred steps is three hundred lazy rows rather than one row that
/// lays all of them out.
public enum SessionConversationItem: Sendable, Hashable, Identifiable {
    case earlier(SessionConversationEdge)
    case header(SessionTurnHeader)
    case prompt(SessionTurnPrompt)
    case process(SessionTurnProcess)
    case step(SessionTurnStep)
    case answer(SessionTurnAnswer)
    case pending(SessionTurnPending)
    case later(SessionConversationEdge)

    public var id: String {
        switch self {
        case .earlier: "earlier"
        case let .header(header): Self.headerID(header.turn)
        case let .prompt(prompt): "p\(prompt.turn)"
        case let .process(process): "x\(process.turn)"
        case let .step(step): "s\(step.turn).\(step.row.position)"
        case let .answer(answer): "a\(answer.turn)"
        case let .pending(pending): "w\(pending.turn)"
        case .later: "later"
        }
    }

    public var turnIndex: Int? {
        switch self {
        case .earlier, .later: nil
        case let .header(header): header.turn
        case let .prompt(prompt): prompt.turn
        case let .process(process): process.turn
        case let .step(step): step.turn
        case let .answer(answer): answer.turn
        case let .pending(pending): pending.turn
        }
    }

    public static func headerID(_ turn: Int) -> String { "h\(turn)" }

    /// The turn an item id belongs to, without the item.
    public static func turnIndex(forID id: String) -> Int? {
        guard let first = id.first, "hpxsaw".contains(first) else { return nil }
        let digits = id.dropFirst().prefix(while: \.isNumber)
        return Int(digits)
    }
}

/// Everything the render list depends on, so it can be rebuilt in one pass
/// whenever any of it changes.
public struct SessionConversationLayoutInput: Sendable {
    public var window: SessionTurnWindow
    public var outline: [SessionTurnOutline]
    public var presentations: [Int: SessionTurnPresentation]
    public var expandedTurns: Set<Int>
    public var expandedSteps: Set<String>
    /// For a process being opened, how many of its steps to list yet (the
    /// rest follow a frame later).
    public var stepLimits: [Int: Int]
    public var verdictsByTurnID: [String: [SessionStructure.GuardianVerdict]]
    public var showsModelPerTurn: Bool
    public var isLoadingEarlier: Bool
    public var isLoadingLater: Bool
    public var pendingState: SessionTurnPending.State
    public var unavailableTurns: Set<Int>

    public init(
        window: SessionTurnWindow,
        outline: [SessionTurnOutline],
        presentations: [Int: SessionTurnPresentation] = [:],
        expandedTurns: Set<Int> = [],
        expandedSteps: Set<String> = [],
        stepLimits: [Int: Int] = [:],
        verdictsByTurnID: [String: [SessionStructure.GuardianVerdict]] = [:],
        showsModelPerTurn: Bool = false,
        isLoadingEarlier: Bool = false,
        isLoadingLater: Bool = false,
        pendingState: SessionTurnPending.State = .loading,
        unavailableTurns: Set<Int> = []
    ) {
        self.window = window
        self.outline = outline
        self.presentations = presentations
        self.expandedTurns = expandedTurns
        self.expandedSteps = expandedSteps
        self.stepLimits = stepLimits
        self.verdictsByTurnID = verdictsByTurnID
        self.showsModelPerTurn = showsModelPerTurn
        self.isLoadingEarlier = isLoadingEarlier
        self.isLoadingLater = isLoadingLater
        self.pendingState = pendingState
        self.unavailableTurns = unavailableTurns
    }
}

public enum SessionConversationLayout {
    public static func stepKey(turn: Int, position: Int) -> String { "\(turn).\(position)" }

    /// The render list for the window. O(rows); no parsing, no formatting.
    public static func items(_ input: SessionConversationLayoutInput) -> [SessionConversationItem] {
        var out: [SessionConversationItem] = []
        let window = input.window
        if window.hasEarlier {
            out.append(.earlier(SessionConversationEdge(remaining: window.earlierCount, isLoading: input.isLoadingEarlier)))
        }
        for index in window.range where input.outline.indices.contains(index) {
            let outline = input.outline[index]
            let presentation = input.presentations[index]
            let verdicts = outline.turnID.flatMap { input.verdictsByTurnID[$0] } ?? []
            out.append(.header(SessionTurnHeader(
                turn: index,
                ordinal: index + 1,
                startedAt: outline.startedAt,
                durationMs: outline.durationMs,
                status: outline.status,
                origin: outline.origin,
                injectedCount: outline.injected.values.reduce(0, +),
                additionalHumanMessages: outline.additionalHumanMessages,
                model: input.showsModelPerTurn ? outline.model : nil,
                verdicts: verdicts
            )))
            if outline.origin != .none || presentation?.prompt != nil {
                out.append(.prompt(SessionTurnPrompt(
                    turn: index,
                    origin: outline.origin,
                    document: presentation?.prompt,
                    preview: outline.promptPreview,
                    isLong: presentation?.isPromptLong ?? false,
                    text: presentation?.promptText
                )))
            }
            guard let presentation else {
                let state: SessionTurnPending.State = input.unavailableTurns.contains(index) ? .unavailable : input.pendingState
                out.append(.pending(SessionTurnPending(turn: index, state: state)))
                continue
            }
            if !presentation.steps.isEmpty {
                let expanded = input.expandedTurns.contains(index)
                out.append(.process(SessionTurnProcess(
                    turn: index,
                    counts: outline.counts,
                    durationMs: outline.durationMs,
                    isExpanded: expanded,
                    isAvailable: true,
                    rowCount: presentation.steps.count
                )))
                if expanded {
                    let limit = input.stepLimits[index] ?? presentation.steps.count
                    for row in presentation.steps.prefix(limit) {
                        out.append(.step(SessionTurnStep(
                            turn: index,
                            row: row,
                            isExpanded: input.expandedSteps.contains(stepKey(turn: index, position: row.position))
                        )))
                    }
                }
            }
            if let answer = presentation.answer {
                out.append(.answer(SessionTurnAnswer(turn: index, document: answer, text: presentation.answerText)))
            }
        }
        if window.hasLater {
            out.append(.later(SessionConversationEdge(remaining: window.laterCount, isLoading: input.isLoadingLater)))
        }
        return out
    }
}
