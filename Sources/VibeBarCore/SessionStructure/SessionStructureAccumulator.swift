import Foundation

/// Options for one parse.
public struct SessionStructureParseOptions: Sendable, Hashable {
    public var detail: SessionStructure.Detail
    /// Only lines that *start* inside this window are read. Turn indices in
    /// the result are then relative to the window.
    public var byteRange: SessionStructure.ByteRange?
    /// Lines longer than this are inspected by their head only.
    public var maxLineBytes: Int

    public init(
        detail: SessionStructure.Detail = .full,
        byteRange: SessionStructure.ByteRange? = nil,
        maxLineBytes: Int = 8 * 1024 * 1024
    ) {
        self.detail = detail
        self.byteRange = byteRange
        self.maxLineBytes = maxLineBytes
    }
}

/// Where a step lives inside the turn list.
struct StepLocation: Hashable {
    let turn: Int
    let step: Int
}

/// Per-model usage and cost, priced per request so long-context thresholds
/// apply to the request that crossed them rather than to a session sum.
struct SessionModelLedger {
    private var order: [String] = []
    private var entries: [String: (usage: SessionStructure.TokenUsage, cost: Double, priced: Bool, unpriced: Bool)] = [:]

    mutating func add(model: String?, usage: SessionStructure.TokenUsage, cost: Double?) {
        guard !usage.isZero else { return }
        let key = model ?? "unknown"
        if entries[key] == nil {
            order.append(key)
            entries[key] = (.zero, 0, false, false)
        }
        entries[key]!.usage += usage
        if let cost, cost.isFinite {
            entries[key]!.cost += cost
            entries[key]!.priced = true
        } else {
            entries[key]!.unpriced = true
        }
    }

    var modelUsage: [SessionModelUsage] {
        order.compactMap { key in
            guard let entry = entries[key] else { return nil }
            return SessionModelUsage(model: key, usage: entry.usage, costUSD: entry.priced ? entry.cost : nil)
        }
    }

    var totalCost: Double? {
        let priced = entries.values.filter(\.priced)
        guard !priced.isEmpty else { return nil }
        return priced.reduce(0) { $0 + $1.cost }
    }

    var hasUnpriced: Bool { entries.values.contains(where: \.unpriced) }

    var totalUsage: SessionStructure.TokenUsage {
        entries.values.reduce(.zero) { $0 + $1.usage }
    }
}

/// Turn/step bookkeeping shared by the Codex and Claude parsers: opening and
/// closing turns, attaching steps, pairing calls with results by id,
/// buffering the last assistant message until it is known to be the final
/// answer rather than commentary, and — in outline detail — dropping a
/// finished turn's step array once its counters are final, so a multi-GB
/// rollout's outline costs one counter block per turn.
final class SessionStructureAccumulator {
    typealias Turn = SessionStructure.Turn
    typealias Step = SessionStructure.Step

    let detail: SessionStructure.Detail
    var turns: [Turn] = []
    private(set) var current: Int?
    private(set) var currentClosed = false
    var diagnostics = SessionStructure.Diagnostics()
    var ledger = SessionModelLedger()
    /// Usage that arrived before the first turn opened.
    var unattributedUsage = SessionStructure.TokenUsage.zero

    private var pendingInjected: [String: Int] = [:]
    private var callIndex: [String: StepLocation] = [:]
    private var openCalls: [String] = []
    private var callIDsByTurn: [Int: [String]] = [:]
    private var droppedTurns: Set<Int> = []
    private var pendingAssistant: (text: String, offset: Int64, timestamp: Date?, turn: Int)?
    /// Whether the current turn's prompt came from a mirror record that a
    /// later, more authoritative record may replace without counting twice.
    var currentPromptIsTentative = false

    init(detail: SessionStructure.Detail) {
        self.detail = detail
    }

    var isFull: Bool { detail == .full }

    // MARK: Turns

    @discardableResult
    func openTurn(offset: Int64, turnID: String?, startedAt: Date?, model: String?) -> Int {
        if let current { finalize(current) }
        var turn = Turn(index: turns.count, turnID: turnID, startedAt: startedAt, byteOffset: offset, byteEnd: offset)
        turn.model = model
        for (key, count) in pendingInjected {
            turn.prompt.injected[key, default: 0] += count
        }
        pendingInjected.removeAll()
        turns.append(turn)
        current = turns.count - 1
        currentClosed = false
        currentPromptIsTentative = false
        return turns.count - 1
    }

    /// The current turn, opening an implicit one when there is none.
    @discardableResult
    func ensureTurn(offset: Int64, timestamp: Date?, model: String?) -> Int {
        if let current { return current }
        return openTurn(offset: offset, turnID: nil, startedAt: timestamp, model: model)
    }

    func touch(lineEnd: Int64) {
        guard let current else { return }
        if turns[current].byteEnd < lineEnd { turns[current].byteEnd = lineEnd }
    }

    func close(status: SessionStructure.TurnStatus, endedAt: Date?, durationMs: Int?) {
        guard let current else { return }
        turns[current].status = status
        if let endedAt { turns[current].endedAt = endedAt }
        if let durationMs { turns[current].durationMs = durationMs }
        currentClosed = true
        settleAssistant(into: current)
    }

    var currentIsClosed: Bool { currentClosed }

    /// Whether the current turn has anything beyond an opening prompt.
    func currentHasAgentActivity() -> Bool {
        guard let current else { return false }
        let turn = turns[current]
        return !turn.steps.isEmpty || turn.finalAnswer != nil || pendingAssistant?.turn == current
            || turn.counts.steps > 0 || !turn.usage.isZero
    }

    // MARK: Prompt & injected context

    func addInjected(_ block: SessionStructure.InjectedBlock, count: Int = 1) {
        guard count > 0 else { return }
        if let current {
            turns[current].prompt.addInjected(block, count: count)
        } else {
            pendingInjected[block.rawValue, default: 0] += count
        }
    }

    func setPrompt(turn: Int, origin: SessionStructure.PromptOrigin, text: String?, tentative: Bool) {
        turns[turn].prompt.origin = origin
        if let text {
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            turns[turn].prompt.preview = SessionStructureText.preview(cleaned, limit: SessionStructure.Prompt.previewLimit)
            if isFull {
                turns[turn].prompt.text = SessionStructureText.capped(cleaned, limit: SessionStructure.Prompt.textLimit)
            }
        }
        if turn == current { currentPromptIsTentative = tentative }
    }

    // MARK: Assistant text

    /// Record an assistant message. The previous one, if any, becomes a
    /// commentary note: only the *last* message of a turn is its answer.
    func assistantText(_ text: String, offset: Int64, timestamp: Date?, turn: Int) {
        guard isFull else {
            pendingAssistant = ("", offset, timestamp, turn)
            return
        }
        flushAssistantAsNote()
        pendingAssistant = (text, offset, timestamp, turn)
    }

    func flushAssistantAsNote() {
        guard let pending = pendingAssistant else { return }
        pendingAssistant = nil
        guard isFull, !pending.text.isEmpty, pending.turn < turns.count, !droppedTurns.contains(pending.turn) else { return }
        let note = Step(
            kind: .note,
            name: "commentary",
            resultSummary: SessionStructureText.summary(pending.text, limit: 400),
            timestamp: pending.timestamp,
            byteOffset: pending.offset
        )
        turns[pending.turn].steps.append(note)
    }

    private func settleAssistant(into turn: Int) {
        guard let pending = pendingAssistant, pending.turn == turn else { return }
        pendingAssistant = nil
        if isFull, !pending.text.isEmpty {
            turns[turn].finalAnswer = SessionStructureText.capped(
                pending.text.trimmingCharacters(in: .whitespacesAndNewlines),
                limit: Turn.finalAnswerLimit
            )
        }
    }

    func setFinalAnswerIfMissing(_ text: String?, turn: Int) {
        guard isFull, let text, !text.isEmpty, turns[turn].finalAnswer == nil else { return }
        if pendingAssistant?.turn == turn { return }
        turns[turn].finalAnswer = SessionStructureText.capped(
            text.trimmingCharacters(in: .whitespacesAndNewlines),
            limit: Turn.finalAnswerLimit
        )
    }

    // MARK: Steps

    @discardableResult
    func addStep(_ step: Step, turn: Int) -> StepLocation {
        // Anything that follows an assistant message makes it commentary;
        // flushing first keeps the steps in file order.
        flushAssistantAsNote()
        var stored = step
        if !isFull {
            stored.argsSummary = nil
            stored.resultSummary = nil
        }
        turns[turn].steps.append(stored)
        let location = StepLocation(turn: turn, step: turns[turn].steps.count - 1)
        if let callID = step.callID, step.pairing == .pending {
            callIndex[callID] = location
            openCalls.append(callID)
            callIDsByTurn[turn, default: []].append(callID)
        }
        return location
    }

    /// Register a step that can be *enriched* by id later (a completed item
    /// that shares a call's id) without expecting a result.
    func index(callID: String, at location: StepLocation) {
        callIndex[callID] = location
        callIDsByTurn[location.turn, default: []].append(callID)
    }

    func location(forCall callID: String) -> StepLocation? {
        guard let location = callIndex[callID],
              location.turn < turns.count,
              location.step < turns[location.turn].steps.count
        else { return nil }
        return location
    }

    func update(_ location: StepLocation, _ mutate: (inout Step) -> Void) {
        guard location.turn < turns.count, location.step < turns[location.turn].steps.count else { return }
        mutate(&turns[location.turn].steps[location.step])
        if !isFull {
            turns[location.turn].steps[location.step].argsSummary = nil
            turns[location.turn].steps[location.step].resultSummary = nil
        }
    }

    /// Mark a call answered. Returns its location, or nil for an orphan.
    @discardableResult
    func resolveCall(_ callID: String, _ mutate: (inout Step) -> Void) -> StepLocation? {
        guard let location = location(forCall: callID) else {
            diagnostics.orphanResults += 1
            return nil
        }
        if let open = openCalls.lastIndex(of: callID) { openCalls.remove(at: open) }
        update(location) { step in
            step.pairing = .paired
            mutate(&step)
        }
        return location
    }

    /// Mark a call finished by a record that is not its result proper (a
    /// completed item sharing its id). Unlike `resolveCall` an unknown id
    /// is not an orphan — the caller adds a step instead — and a result
    /// that still arrives later merges into the same step.
    @discardableResult
    func completeCall(_ callID: String, _ mutate: (inout Step) -> Void) -> StepLocation? {
        guard let location = location(forCall: callID) else { return nil }
        if let open = openCalls.lastIndex(of: callID) { openCalls.remove(at: open) }
        update(location) { step in
            if step.pairing == .pending { step.pairing = .paired }
            mutate(&step)
        }
        return location
    }

    /// The innermost call still waiting for its result — the parent of an
    /// `item_completed` that ran inside it.
    var innermostOpenCall: String? { openCalls.last }

    // MARK: Usage

    func addUsage(_ usage: SessionStructure.TokenUsage, model: String?, cost: Double?) {
        guard !usage.isZero else { return }
        if let current {
            turns[current].usage += usage
            if turns[current].model == nil { turns[current].model = model }
        } else {
            unattributedUsage += usage
        }
        ledger.add(model: model, usage: usage, cost: cost)
    }

    // MARK: Finalization

    /// Fix a turn's counters from its steps; in outline detail, drop the
    /// steps once nothing can still pair into them.
    func finalize(_ index: Int) {
        guard index < turns.count, !droppedTurns.contains(index) else { return }
        settleAssistant(into: index)
        recount(index)
        guard !isFull else { return }
        let stillOpen = (callIDsByTurn[index] ?? []).contains { openCalls.contains($0) }
        guard !stillOpen else { return }
        for callID in callIDsByTurn[index] ?? [] { callIndex.removeValue(forKey: callID) }
        callIDsByTurn.removeValue(forKey: index)
        turns[index].steps.removeAll()
        droppedTurns.insert(index)
    }

    private func recount(_ index: Int) {
        var counts = SessionStructure.TurnCounts()
        for step in turns[index].steps {
            switch step.kind {
            case .toolCall: counts.toolCalls += 1
            case .command: counts.commands += 1
            case .mcpCall: counts.mcpCalls += 1
            case .subagent: counts.subagents += 1
            case .thinking: counts.thinking += 1
            case .guardianVerdict, .note: break
            }
            if step.kind.isAction {
                counts.steps += 1
                if step.isError { counts.failed += 1 }
            }
        }
        turns[index].counts = counts
    }

    func finish(lastLineEnd: Int64) -> [Turn] {
        if let current {
            settleAssistant(into: current)
            touch(lineEnd: lastLineEnd)
        }
        for index in turns.indices where !droppedTurns.contains(index) {
            settleAssistant(into: index)
            recount(index)
            if !isFull { turns[index].steps.removeAll() }
        }
        diagnostics.pendingCalls = openCalls.count
        return turns
    }
}

extension SessionStructure.Turn {
    var isLive: Bool { status != .abandoned }
}

/// Shared stats assembly over finished turns.
enum SessionStatsBuilder {
    static func apply(turns: [SessionStructure.Turn], ledger: SessionModelLedger, into stats: inout SessionStats) {
        var models = Set<String>()
        for turn in turns {
            if let model = turn.model, !model.isEmpty { models.insert(model) }
            guard turn.isLive else { continue }
            stats.promptCount += turn.prompt.humanPromptCount
            stats.toolCallCount += turn.counts.steps
            stats.commandCount += turn.counts.commands
            stats.mcpCallCount += turn.counts.mcpCalls
            stats.subagentCount += turn.counts.subagents
            stats.thinkingCount += turn.counts.thinking
            stats.failedToolCount += turn.counts.failed
            stats.injectedBlockCount += turn.prompt.injectedCount
        }
        stats.turnCount = turns.count
        let modelUsage = ledger.modelUsage
        for usage in modelUsage where usage.model != "unknown" { models.insert(usage.model) }
        stats.models = models.sorted()
        stats.modelUsage = modelUsage
        stats.estimatedCostUSD = ledger.totalCost
        stats.hasUnpricedUsage = ledger.hasUnpriced
        if let startedAt = stats.startedAt, let endedAt = stats.endedAt, endedAt >= startedAt {
            stats.durationMs = Int((endedAt.timeIntervalSince(startedAt) * 1000).rounded())
        }
    }
}
