import Foundation

/// Reads a Codex rollout (`~/.codex/sessions/**/rollout-*.jsonl`) into a
/// `SessionStructure`.
///
/// Turn boundaries are `event_msg` `task_started` / `task_complete` (or
/// `turn_aborted`); a rollout without them falls back to "a human message
/// after the agent has acted opens a new turn". Calls (`function_call`,
/// `custom_tool_call`, `local_shell_call`, `tool_search_call`) pair with
/// their `*_output` by `call_id`. An `item_completed` whose id *is* a call id
/// enriches that call (exit code, duration); any other completed
/// `CommandExecution` / `McpToolCall` / … becomes a step nested under the
/// innermost call still open — that is how a code-mode `exec` script's
/// commands are recorded. Usage comes from two series that are never mixed:
/// each `token_usage_record`'s per-response `usage`, and the deltas of
/// `token_count.total_token_usage` against its own previous value. Their
/// counters do not share a basis — `token_count` can restart inside a
/// thread while the records' `thread_token_usage` keeps counting — so a
/// turn is read from its records when it has any and from `token_count`
/// otherwise. Each request is priced as it arrives, with the model from
/// `turn_context`.
///
/// Inherited history: a forked / thread-spawned subagent rollout begins with
/// a copy of its parent's records; `session_meta.subagent_history_start_ordinal`
/// marks where its own begin. Lines below that ordinal are skipped. Guardian
/// rollouts carry the same field with a different meaning (measured on
/// local rollouts: every line sits below it and none is shared with the
/// parent), so they are never cut.
public enum CodexSessionStructureParser {
    /// `function_call` names that run a shell command.
    static let commandToolNames: Set<String> = [
        "exec_command", "shell", "shell_command", "container.exec", "local_shell", "unified_exec"
    ]

    static let subagentToolNames: Set<String> = ["spawn_agent", "spawn_subagent", "create_thread"]

    /// Returns `nil` only when the file cannot be opened.
    public static func parse(
        fileURL: URL,
        options: SessionStructureParseOptions = SessionStructureParseOptions(),
        isCancelled: () -> Bool = { false }
    ) -> SessionStructure? {
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else { return nil }
        let builder = CodexStructureBuilder(path: fileURL.path, options: options)
        let outcome = SessionStructureLineReader.forEachLine(
            in: fileURL,
            range: options.byteRange,
            maxLineBytes: options.maxLineBytes,
            isCancelled: isCancelled
        ) { line in
            autoreleasepool { builder.consume(line) }
            return true
        }
        return builder.finish(outcome: outcome)
    }
}

// MARK: - Builder

private final class CodexStructureBuilder {
    typealias Step = SessionStructure.Step

    let path: String
    let options: SessionStructureParseOptions
    let acc: SessionStructureAccumulator
    let pricing = CostPricingContext()

    var stats = SessionStats()
    var sessionID: String?
    var sawMeta = false
    var cutOrdinal: Int?
    var hasTaskEvents = false
    var sawUserMessageEvents = false
    var promptsSeen = 0
    var currentModel: String?
    var currentTier: String?
    /// `token_count` series: its cumulative counter and what it last read.
    var lastTotals: RawTotals?
    var lastCumulativeTotal: Int?
    /// This session's own `token_count` lines carried a counter.
    var counterSeen = false
    /// `token_usage_record` series, kept apart from `token_count` — the two
    /// counters have different bases and must never be differenced
    /// against each other.
    var lastRecordThread: RawTotals?
    var lastRecordThreadTotal: Int?
    var counterSeries = UsageSeries()
    /// The part of a `token_count` step beyond the response it reports
    /// (`last_token_usage`): growth from replies the counter skipped
    /// earlier and is only now absorbing. Kept apart so a turn that falls
    /// back to the counter can drop what records already counted.
    var counterCatchUpSeries = UsageSeries()
    var counterResetTurns: Set<Int> = []
    var recordSeries = UsageSeries()
    /// A counter was read from this session's own lines (not only from
    /// history it inherited).
    var ownCounterSeen = false
    /// Times this session's own cumulative counter went backwards.
    var counterResets = 0
    var lastTimestampRaw: String?
    var firstTimestampRaw: String?
    var humanInputs: [Int: (tentative: Int, authoritative: Int)] = [:]
    var reasoningDurations: [String: Int] = [:]
    /// Verdict-shaped assistant messages read while the thread still looked
    /// like an ordinary subagent (see `becomeGuardianIfReviewModel`).
    var verdictCandidates: [(turn: Int, offset: Int64, timestamp: Date?, text: String)] = []
    var reasoningSteps: [String: StepLocation] = [:]
    var subagentSteps: [String: StepLocation] = [:]
    var lastLineEnd: Int64 = 0

    init(path: String, options: SessionStructureParseOptions) {
        self.path = path
        self.options = options
        self.acc = SessionStructureAccumulator(detail: options.detail)
    }

    var isFull: Bool { options.detail == .full }

    // MARK: Line dispatch

    func consume(_ line: SessionStructureLineReader.Line) {
        acc.diagnostics.linesRead += 1
        lastLineEnd = line.end
        if line.isTruncated {
            acc.diagnostics.oversizedLines += 1
            consumeTruncated(line)
            acc.touch(lineEnd: line.end)
            return
        }
        // Skip what nothing here reads before paying for a decode: the
        // per-turn `world_state` snapshot and `compacted`'s replacement
        // history are the bulkiest records in a rollout.
        switch Self.cheapTopLevelType(line.data) {
        case "world_state"?:
            acc.touch(lineEnd: line.end)
            return
        case "compacted"?:
            if let cutOrdinal, let ordinal = SessionStructureLineReader.sniffInt("ordinal", in: line.data.prefix(160)),
               ordinal < cutOrdinal {
                acc.diagnostics.inheritedLinesSkipped += 1
                return
            }
            if isFull, let current = acc.current {
                let stamp = SessionStructureLineReader.sniffString("timestamp", in: line.data.prefix(160))
                acc.addStep(Step(
                    kind: .note,
                    name: "compaction",
                    timestamp: stamp.flatMap(SessionStructureText.fastISODate),
                    byteOffset: line.offset
                ), turn: current)
            }
            acc.touch(lineEnd: line.end)
            return
        default:
            break
        }
        guard let object = (try? JSONSerialization.jsonObject(with: line.data)) as? [String: Any] else {
            acc.diagnostics.undecodableLines += 1
            return
        }
        let type = object["type"] as? String
        if let timestamp = object["timestamp"] as? String {
            if firstTimestampRaw == nil { firstTimestampRaw = timestamp }
            lastTimestampRaw = timestamp
        }
        if type == "session_meta" {
            if !sawMeta { readMeta(object) }
            return
        }
        if let cutOrdinal, let ordinal = SessionStructureText.int(object["ordinal"]), ordinal < cutOrdinal {
            acc.diagnostics.inheritedLinesSkipped += 1
            trackInheritedTotals(object)
            return
        }
        let payload = object["payload"] as? [String: Any] ?? [:]
        switch type {
        case "turn_context":
            handleTurnContext(payload)
        case "event_msg":
            handleEvent(payload, object: object, line: line)
        case "response_item":
            handleResponseItem(payload, object: object, line: line)
        case "compacted":
            addNote("compaction", line: line, object: object)
        case "token_usage_record":
            applyUsageRecord(payload)
        default:
            break
        }
        acc.touch(lineEnd: line.end)
    }

    /// `{"timestamp":"…","ordinal":N,"type":"world_state",…` — the type
    /// tag sits in the first ~120 bytes of every rollout line.
    static func cheapTopLevelType(_ data: Data) -> String? {
        let head = data.prefix(160)
        return SessionStructureLineReader.sniffString("type", in: Data(head))
    }

    // MARK: session_meta

    func readMeta(_ object: [String: Any]) {
        sawMeta = true
        guard let meta = object["payload"] as? [String: Any] else { return }
        let id = SessionStructureText.string(meta["id"]) ?? SessionStructureText.string(meta["thread_id"])
        sessionID = id
        let source = meta["source"]
        let subagent = (source as? [String: Any])?["subagent"]
        let subagentDict = subagent as? [String: Any]
        let threadSpawn = subagentDict?["thread_spawn"] as? [String: Any]
        let threadSource = SessionStructureText.string(meta["thread_source"])?.lowercased()
        let forkedFrom = SessionStructureText.string(meta["forked_from_id"])
        let parentThread = SessionStructureText.string(meta["parent_thread_id"])
            ?? SessionStructureText.string(threadSpawn?["parent_thread_id"])
        let root = SessionStructureText.string(meta["session_id"])
        let rootIfOther = (root != nil && root != id) ? root : nil

        let isGuardian = SessionStructureText.string(subagentDict?["other"])?.lowercased() == "guardian"
            || threadSource == "guardian_review"
        let isSubagent = subagent != nil || threadSource == "subagent"

        if isGuardian {
            stats.kind = .guardian
            stats.relation = .reviews
            stats.parentID = parentThread ?? rootIfOther
        } else if isSubagent {
            stats.kind = .subagent
            stats.relation = .spawnedBy
            stats.parentID = parentThread ?? forkedFrom ?? rootIfOther
        } else if threadSource == "agent_created_thread" {
            stats.kind = .agentCreated
            stats.relation = .createdBy
            stats.parentID = parentThread ?? rootIfOther
        } else if let forkedFrom {
            stats.kind = .fork
            stats.relation = .forkOf
            stats.parentID = forkedFrom
        } else if threadSource == "automation" {
            stats.kind = .automation
        } else if (source as? String)?.lowercased() == "exec" {
            stats.kind = .exec
        } else {
            stats.kind = .interactive
        }
        stats.rootSessionID = rootIfOther
        stats.originator = SessionStructureText.string(meta["originator"])
        stats.cliVersion = SessionStructureText.string(meta["cli_version"])
        stats.cwd = SessionStructureText.string(meta["cwd"])
        stats.agentNickname = SessionStructureText.string(meta["agent_nickname"])
            ?? SessionStructureText.string(threadSpawn?["agent_nickname"])
        stats.agentRole = SessionStructureText.string(meta["agent_role"])
            ?? SessionStructureText.string(threadSpawn?["agent_role"])
        if let git = meta["git"] as? [String: Any] {
            stats.gitBranch = SessionStructureText.string(git["branch"])
        }
        stats.startedAt = SessionStructureText.date(meta["timestamp"]) ?? SessionStructureText.date(object["timestamp"])

        // Only a window that starts at the top of the file sees the header,
        // and only a fork / spawned subagent carries copied history.
        let copiesParentHistory = !isGuardian && (forkedFrom != nil || threadSpawn != nil)
        if copiesParentHistory,
           let start = SessionStructureText.int(meta["subagent_history_start_ordinal"]),
           start > 0 {
            cutOrdinal = start
            stats.forkStartOrdinal = start
        }
    }

    // MARK: turn_context

    func handleTurnContext(_ payload: [String: Any]) {
        if let model = SessionStructureText.string(payload["model"]) {
            currentModel = model
            if let current = acc.current, acc.turns[current].model == nil || !acc.currentIsClosed {
                acc.turns[current].model = model
            }
            becomeGuardianIfReviewModel(model)
        }
        // Same rule as the cost scanner: each turn states its tier, and a
        // turn that states none ran on the default.
        currentTier = CostUsagePricing.normalizedCodexServiceTier(payload["service_tier"] as? String)
    }

    // MARK: event_msg

    func handleEvent(_ payload: [String: Any], object: [String: Any], line: SessionStructureLineReader.Line) {
        switch payload["type"] as? String {
        case "task_started":
            hasTaskEvents = true
            // Reasoning records pair within a turn; do not carry the ids.
            reasoningSteps.removeAll(keepingCapacity: true)
            reasoningDurations.removeAll(keepingCapacity: true)
            let startedAt = SessionStructureText.date(payload["started_at"]) ?? timestamp(object)
            let turnID = SessionStructureText.string(payload["turn_id"])
            if let current = acc.current, !acc.currentIsClosed, acc.turns[current].turnID == nil,
               !acc.currentHasAgentActivity() {
                // An implicit turn opened by input that arrived just before
                // its task_started: adopt it rather than leave a husk.
                acc.turns[current].turnID = turnID
                if acc.turns[current].startedAt == nil { acc.turns[current].startedAt = startedAt }
            } else {
                acc.openTurn(offset: line.offset, turnID: turnID, startedAt: startedAt, model: currentModel)
            }
        case "task_complete":
            let endedAt = SessionStructureText.date(payload["completed_at"]) ?? timestamp(object)
            let duration = SessionStructureText.int(payload["duration_ms"])
            if let current = acc.current {
                let last = SessionStructureText.string(payload["last_agent_message"])
                acc.close(status: .completed, endedAt: endedAt, durationMs: duration)
                acc.setFinalAnswerIfMissing(last, turn: current)
            }
        case "turn_aborted":
            if acc.current != nil {
                acc.close(status: .aborted, endedAt: timestamp(object), durationMs: nil)
            }
        case "user_message":
            let text = SessionStructureText.string(payload["message"]) ?? ""
            let images = (payload["images"] as? [Any])?.count ?? 0
            handleHumanInput(raw: text, imageCount: images, authoritative: true, line: line, object: object)
        case "item_completed":
            if let item = payload["item"] as? [String: Any] {
                handleItem(item, payload: payload, object: object, line: line)
            }
        case "token_count":
            guard let info = payload["info"] as? [String: Any] else { return }
            if let tier = (info["service_tier"] as? String) ?? (payload["service_tier"] as? String) {
                currentTier = CostUsagePricing.normalizedCodexServiceTier(tier)
            }
            if let total = info["total_token_usage"] as? [String: Any] {
                applyCumulative(RawTotals(total), response: (info["last_token_usage"] as? [String: Any]).map(RawTotals.init))
            } else if let last = info["last_token_usage"] as? [String: Any] {
                applyIncrement(RawTotals(last))
            }
        default:
            break
        }
    }

    // MARK: response_item

    func handleResponseItem(_ payload: [String: Any], object: [String: Any], line: SessionStructureLineReader.Line) {
        switch payload["type"] as? String {
        case "message":
            let role = payload["role"] as? String
            let text = SessionStructureText.text(payload["content"])
            switch role {
            case "user":
                handleUserResponseItem(text, payload: payload, object: object, line: line)
            case "developer", "system":
                acc.addInjected(.developerMessage)
            case "assistant":
                handleAssistant(text, line: line, object: object)
            default:
                break
            }
        case "reasoning":
            handleReasoning(payload, line: line, object: object)
        case "function_call", "custom_tool_call", "local_shell_call", "tool_search_call":
            handleCall(payload, line: line, object: object)
        case "web_search_call", "image_generation_call":
            handleSelfContainedCall(payload, line: line, object: object)
        case "function_call_output", "custom_tool_call_output", "local_shell_call_output", "tool_search_output":
            handleOutput(payload)
        case "agent_message":
            // Inter-agent traffic. The first one a subagent receives is its task.
            let text = SessionStructureText.text(payload["content"])
            if stats.kind == .subagent || stats.kind == .agentCreated {
                let turn = acc.ensureTurn(offset: line.offset, timestamp: timestamp(object), model: currentModel)
                if acc.turns[turn].prompt.origin == .none, !text.isEmpty {
                    acc.setPrompt(turn: turn, origin: .agent, text: text, tentative: false)
                }
            }
        case "compaction":
            addNote("compaction", line: line, object: object)
        default:
            break
        }
    }

    func handleUserResponseItem(
        _ text: String,
        payload: [String: Any],
        object: [String: Any],
        line: SessionStructureLineReader.Line
    ) {
        if stats.kind == .guardian, let metadata = object["metadata"] as? [String: Any] {
            recordGuardianSource(metadata, line: line, object: object)
        }
        // Once the rollout is known to carry `UserMessage` items, a
        // response-item user message is either injected context (it starts
        // with a known marker) or a mirror of a prompt already counted —
        // no need to run the full prompt extractor over it. Guardian
        // rollouts repeat whole transcripts this way.
        if sawUserMessageEvents {
            if let block = SessionStructureText.injectedBlock(for: text) {
                acc.addInjected(block)
            }
            return
        }
        // Agent-to-agent threads never carry a human prompt; their opening
        // input is whatever non-injected message arrives first.
        if stats.kind == .guardian || stats.kind == .subagent || stats.kind == .agentCreated {
            if let block = SessionStructureText.injectedBlock(for: text) {
                acc.addInjected(block)
                return
            }
            let turn = acc.ensureTurn(offset: line.offset, timestamp: timestamp(object), model: currentModel)
            if acc.turns[turn].prompt.origin == .none {
                let head = SessionStructureText.nativeHead(text, maxUTF16: SessionStructure.Prompt.textLimit)
                acc.setPrompt(turn: turn, origin: originForNextPrompt(), text: head, tentative: true)
            }
            return
        }
        let stripped = CodexSessionAdapter.strippingIDEEnvelope(SessionStructureText.decisionPrefix(text))
        guard HumanPromptText.instruction(stripped) != nil else {
            let blocks = SessionStructureText.injectedBlocks(in: text)
            if blocks.isEmpty {
                acc.addInjected(SessionStructureText.injectedBlock(for: text) ?? .other)
            } else {
                for block in blocks { acc.addInjected(block) }
            }
            return
        }
        // Meta blocks folded into an otherwise human message.
        for block in SessionStructureText.injectedBlocks(in: text) { acc.addInjected(block) }
        handleHumanInput(raw: stripped, imageCount: 0, authoritative: false, line: line, object: object)
    }

    /// The parent turn a review is about. `guardian_sources` names it
    /// explicitly and wins; a message carrying only `retained_source` (the
    /// turn it was copied from) supplies it when nothing better has.
    func recordGuardianSource(_ metadata: [String: Any], line: SessionStructureLineReader.Line, object: [String: Any]) {
        let sources = metadata["guardian_sources"] as? [[String: Any]] ?? []
        let explicit = SessionStructureText.string((sources.last?["id"] as? [String: Any])?["turn_id"])
        let retained = SessionStructureText.string(
            ((metadata["retained_source"] as? [String: Any])?["id"] as? [String: Any])?["turn_id"]
        )
        guard let turnID = explicit ?? retained else { return }
        let turn = acc.ensureTurn(offset: line.offset, timestamp: timestamp(object), model: currentModel)
        if explicit != nil || acc.turns[turn].reviewedTurnID == nil {
            acc.turns[turn].reviewedTurnID = turnID
        }
    }

    /// One opening input. `authoritative` inputs (`UserMessage` items, the
    /// legacy `user_message` event) replace a tentative prompt taken from a
    /// response-item mirror instead of counting again.
    func handleHumanInput(
        raw: String,
        imageCount: Int,
        authoritative: Bool,
        line: SessionStructureLineReader.Line,
        object: [String: Any]
    ) {
        let bounded = SessionStructureText.decisionPrefix(raw)
        let instruction = HumanPromptText.instruction(bounded)
        guard instruction != nil || imageCount > 0 else { return }
        let text = HumanPromptText.stripMeta(bounded).trimmingCharacters(in: .whitespacesAndNewlines)
        let displayText = text.isEmpty ? "[image]" : text
        let origin = originForNextPrompt()

        let needsNewTurn: Bool
        if let current = acc.current {
            if acc.currentIsClosed {
                needsNewTurn = true
            } else if hasTaskEvents {
                needsNewTurn = false
            } else {
                needsNewTurn = acc.currentHasAgentActivity() && acc.turns[current].prompt.origin != .none
            }
        } else {
            needsNewTurn = true
        }
        let turn = needsNewTurn
            ? acc.openTurn(offset: line.offset, turnID: nil, startedAt: timestamp(object), model: currentModel)
            : acc.current!

        var tally = humanInputs[turn] ?? (tentative: 0, authoritative: 0)
        if authoritative {
            tally.authoritative += 1
            sawUserMessageEvents = true
        } else {
            tally.tentative += 1
        }
        humanInputs[turn] = tally
        if acc.turns[turn].prompt.origin == .none {
            acc.setPrompt(turn: turn, origin: origin, text: displayText, tentative: !authoritative)
            promptsSeen += 1
        } else if authoritative, tally.authoritative == 1, acc.currentPromptIsTentative, turn == acc.current {
            // The authoritative copy of a prompt first seen as a mirror.
            acc.setPrompt(turn: turn, origin: acc.turns[turn].prompt.origin, text: displayText, tentative: false)
        }
    }

    /// Settle how many human messages each turn received. Authoritative
    /// records (`UserMessage` items) are the count when a turn has any;
    /// otherwise the response-item reading stands. Decided per turn at the
    /// end because a mirror arrives *before* the record it mirrors.
    func settleHumanInputs(_ turns: inout [SessionStructure.Turn]) {
        let agentThread = stats.kind == .subagent || stats.kind == .guardian || stats.kind == .agentCreated
        for (index, tally) in humanInputs where index < turns.count {
            let inputs = tally.authoritative > 0 ? tally.authoritative : tally.tentative
            turns[index].prompt.additionalHumanMessages = agentThread ? 0 : max(0, inputs - 1)
        }
    }

    func originForNextPrompt() -> SessionStructure.PromptOrigin {
        switch stats.kind {
        case .subagent, .agentCreated: return .agent
        case .guardian: return .guardianRequest
        case .automation: return promptsSeen == 0 ? .automation : .human
        case .interactive, .exec, .fork: return .human
        }
    }

    func handleAssistant(_ text: String, line: SessionStructureLineReader.Line, object: [String: Any]) {
        let turn = acc.ensureTurn(offset: line.offset, timestamp: timestamp(object), model: currentModel)
        if stats.kind == .guardian, let verdict = Self.guardianVerdict(from: text) {
            let (step, rationale) = verdictStep(verdict, text: text, offset: line.offset, timestamp: timestamp(object))
            acc.addStep(step, turn: turn)
            countVerdict(verdict)
            acc.setFinalAnswerIfMissing(rationale ?? text, turn: turn)
            return
        }
        guard !text.isEmpty else { return }
        // A review thread without the guardian source tag is recognized by
        // its model, which can surface after a verdict was already read.
        // Remember verdict-shaped messages so they can be re-read then.
        if stats.kind == .subagent, Self.guardianVerdict(from: text) != nil {
            verdictCandidates.append((turn, line.offset, timestamp(object), text))
        }
        acc.assistantText(text, offset: line.offset, timestamp: isFull ? timestamp(object) : nil, turn: turn)
    }

    func verdictStep(
        _ verdict: SessionStructure.GuardianVerdict,
        text: String,
        offset: Int64,
        timestamp: Date?
    ) -> (Step, String?) {
        let rationale = SessionStructureText.jsonObject(fromString: text).flatMap { SessionStructureText.string($0["rationale"]) }
        let step = Step(
            kind: .guardianVerdict,
            name: "guardian",
            resultSummary: isFull ? SessionStructureText.summary(rationale) : nil,
            isError: verdict.isDenied,
            verdict: verdict,
            timestamp: isFull ? timestamp : nil,
            byteOffset: offset
        )
        return (step, rationale)
    }

    func countVerdict(_ verdict: SessionStructure.GuardianVerdict) {
        if verdict.isDenied { stats.guardianDenyCount += 1 } else { stats.guardianAllowCount += 1 }
    }

    /// The review runtime that predates the guardian source tag: a subagent
    /// thread running the auto-review model (the kit's rule). Switch to
    /// guardian semantics as soon as that model is seen, and re-read what
    /// was parsed before it with those semantics.
    func becomeGuardianIfReviewModel(_ model: String) {
        guard stats.kind == .subagent, model.lowercased() == "codex-auto-review" else { return }
        stats.kind = .guardian
        stats.relation = .reviews
        for index in acc.turns.indices where acc.turns[index].prompt.origin == .agent {
            acc.turns[index].prompt.origin = .guardianRequest
        }
        for candidate in verdictCandidates {
            guard let verdict = Self.guardianVerdict(from: candidate.text) else { continue }
            let (step, rationale) = verdictStep(verdict, text: candidate.text, offset: candidate.offset, timestamp: candidate.timestamp)
            acc.reinterpretAssistantMessage(
                turn: candidate.turn,
                offset: candidate.offset,
                originalText: candidate.text,
                as: step,
                finalAnswer: rationale ?? candidate.text
            )
            countVerdict(verdict)
        }
        verdictCandidates.removeAll()
    }

    static func guardianVerdict(from text: String) -> SessionStructure.GuardianVerdict? {
        guard let json = SessionStructureText.jsonObject(fromString: text),
              let outcome = SessionStructureText.string(json["outcome"])
        else { return nil }
        return SessionStructure.GuardianVerdict(
            outcome: outcome,
            riskLevel: SessionStructureText.string(json["risk_level"]),
            userAuthorization: SessionStructureText.string(json["user_authorization"])
        )
    }

    func handleReasoning(_ payload: [String: Any], line: SessionStructureLineReader.Line, object: [String: Any]) {
        let turn = acc.ensureTurn(offset: line.offset, timestamp: timestamp(object), model: currentModel)
        let summary = SessionStructureText.text(payload["summary"])
        let content = SessionStructureText.text(payload["content"])
        let visible = summary.isEmpty ? content : summary
        let id = SessionStructureText.string(payload["id"])
        var step = Step(
            kind: .thinking,
            name: "reasoning",
            resultSummary: isFull && !visible.isEmpty ? SessionStructureText.summary(visible) : nil,
            thinkingCharacters: visible.isEmpty ? nil : SessionStructureText.length(visible),
            timestamp: isFull ? timestamp(object) : nil,
            byteOffset: line.offset
        )
        if let id, let duration = reasoningDurations.removeValue(forKey: id) {
            step.durationMs = duration
        }
        let location = acc.addStep(step, turn: turn)
        if let id, step.durationMs == nil { reasoningSteps[id] = location }
    }

    // MARK: Calls & results

    func handleCall(_ payload: [String: Any], line: SessionStructureLineReader.Line, object: [String: Any]) {
        let type = payload["type"] as? String ?? "function_call"
        let callID = SessionStructureText.string(payload["call_id"]) ?? SessionStructureText.string(payload["id"])
        let name: String
        let kind: Step.Kind
        var args: String?
        switch type {
        case "local_shell_call":
            name = "local_shell"
            kind = .command
            if isFull { args = Self.commandText((payload["action"] as? [String: Any])?["command"]) }
        case "tool_search_call":
            name = "tool_search"
            kind = .toolCall
            if isFull { args = SessionStructureText.compactJSON(payload["arguments"] ?? payload["query"]) }
        case "custom_tool_call":
            name = SessionStructureText.string(payload["name"]) ?? "custom_tool"
            kind = .toolCall
            if isFull { args = Self.customToolArgs(name: name, input: payload["input"] as? String) }
        default:
            name = SessionStructureText.string(payload["name"]) ?? "function"
            kind = Self.functionKind(name)
            if isFull { args = Self.functionArgs(name: name, arguments: payload["arguments"]) }
        }
        let turn = acc.ensureTurn(offset: line.offset, timestamp: timestamp(object), model: currentModel)
        let step = Step(
            kind: kind,
            name: name,
            argsSummary: SessionStructureText.summary(args),
            callID: callID,
            parentCallID: nil,
            pairing: callID == nil ? .notApplicable : .pending,
            timestamp: isFull ? timestamp(object) : nil,
            byteOffset: line.offset
        )
        acc.addStep(step, turn: turn)
    }

    func handleSelfContainedCall(_ payload: [String: Any], line: SessionStructureLineReader.Line, object: [String: Any]) {
        let type = payload["type"] as? String
        let name = type == "image_generation_call" ? "image_generation" : "web_search"
        var args: String?
        if isFull, let action = payload["action"] as? [String: Any] {
            args = SessionStructureText.string(action["query"]) ?? SessionStructureText.string(action["url"])
        }
        let status = (payload["status"] as? String)?.lowercased()
        let turn = acc.ensureTurn(offset: line.offset, timestamp: timestamp(object), model: currentModel)
        acc.addStep(Step(
            kind: .toolCall,
            name: name,
            argsSummary: SessionStructureText.summary(args),
            isError: status == "failed",
            timestamp: isFull ? timestamp(object) : nil,
            byteOffset: line.offset
        ), turn: turn)
    }

    func handleOutput(_ payload: [String: Any]) {
        guard let callID = SessionStructureText.string(payload["call_id"]) else { return }
        let output = payload["output"]
        let text = Self.outputText(output)
        let result = CodexToolOutput.classify(text)
        let successFlag = (output as? [String: Any])?["success"] as? Bool
        let spawnedChild: String? = {
            guard let json = SessionStructureText.jsonObject(fromString: text) else { return nil }
            return SessionStructureText.string(json["agent_id"]) ?? SessionStructureText.string(json["thread_id"])
        }()
        let isFull = self.isFull
        acc.resolveCall(callID) { step in
            if step.exitCode == nil { step.exitCode = result.exitCode }
            if step.durationMs == nil { step.durationMs = result.durationMs }
            step.isError = step.isError || result.isError || successFlag == false
            if isFull { step.resultSummary = SessionStructureText.summary(result.body) }
            if let spawnedChild, step.kind == .subagent || step.childSessionID == nil && step.name.contains("agent") {
                step.childSessionID = spawnedChild
                if CodexSessionStructureParser.subagentToolNames.contains(step.name) { step.kind = .subagent }
            }
        }
    }

    // MARK: item_completed

    func handleItem(
        _ item: [String: Any],
        payload: [String: Any],
        object: [String: Any],
        line: SessionStructureLineReader.Line
    ) {
        let itemType = item["type"] as? String ?? ""
        let itemID = SessionStructureText.string(item["id"])
        switch itemType {
        case "UserMessage":
            let content = item["content"] as? [Any] ?? []
            var texts: [String] = []
            var images = 0
            for block in content {
                guard let dict = block as? [String: Any] else { continue }
                switch dict["type"] as? String {
                case "text", "input_text": if let text = dict["text"] as? String { texts.append(text) }
                case "image", "local_image", "input_image": images += 1
                default: break
                }
            }
            handleHumanInput(raw: texts.joined(separator: "\n"), imageCount: images, authoritative: true, line: line, object: object)
            return
        case "Reasoning":
            guard let itemID else { return }
            let started = SessionStructureText.int(payload["started_at_ms"])
            let completed = SessionStructureText.int(payload["completed_at_ms"])
            guard let started, let completed, completed >= started else { return }
            if let location = reasoningSteps.removeValue(forKey: itemID) {
                acc.update(location) { $0.durationMs = completed - started }
            } else {
                reasoningDurations[itemID] = completed - started
            }
            return
        case "AgentMessage", "ContextCompaction", "Plan", "FunctionCallOutput", "Extension":
            return
        default:
            break
        }

        var step: Step
        switch itemType {
        case "CommandExecution":
            let exit = SessionStructureText.int(item["exit_code"])
            let status = (item["status"] as? String)?.lowercased()
            step = Step(
                kind: .command,
                name: "command",
                argsSummary: isFull ? SessionStructureText.summary(Self.commandText(item["command"])) : nil,
                resultSummary: isFull ? SessionStructureText.summary(
                    (item["aggregated_output"] as? String) ?? (item["stdout"] as? String)
                ) : nil,
                isError: (exit.map { $0 != 0 } ?? false) || status == "failed" || status == "declined",
                exitCode: exit,
                durationMs: SessionStructureText.durationMs(fromRust: item["duration"])
            )
        case "McpToolCall":
            let server = SessionStructureText.string(item["server"]) ?? "mcp"
            let tool = SessionStructureText.string(item["tool"]) ?? "tool"
            let status = (item["status"] as? String)?.lowercased()
            let resultIsError = (item["result"] as? [String: Any])?["isError"] as? Bool ?? false
            step = Step(
                kind: .mcpCall,
                name: "\(server).\(tool)",
                argsSummary: isFull ? SessionStructureText.summary(Self.mcpArgs(item["arguments"])) : nil,
                isError: status == "failed" || resultIsError,
                durationMs: SessionStructureText.durationMs(fromRust: item["duration"])
            )
        case "DynamicToolCall":
            let namespace = SessionStructureText.string(item["namespace"])
            let tool = SessionStructureText.string(item["tool"]) ?? "tool"
            let status = (item["status"] as? String)?.lowercased()
            step = Step(
                kind: .toolCall,
                name: namespace.map { "\($0).\(tool)" } ?? tool,
                argsSummary: isFull ? SessionStructureText.summary(SessionStructureText.compactJSON(item["arguments"])) : nil,
                isError: status == "failed" || (item["success"] as? Bool) == false,
                durationMs: SessionStructureText.durationMs(fromRust: item["duration"])
            )
        case "FileChange":
            let status = (item["status"] as? String)?.lowercased()
            step = Step(kind: .toolCall, name: "file_change", isError: status == "failed" || status == "declined")
        case "WebSearch":
            step = Step(
                kind: .toolCall,
                name: "web_search",
                argsSummary: isFull ? SessionStructureText.summary(SessionStructureText.string(item["query"])) : nil
            )
        case "ImageView":
            step = Step(
                kind: .toolCall,
                name: "view_image",
                argsSummary: isFull ? SessionStructureText.summary(SessionStructureText.string(item["path"])) : nil
            )
        case "SubAgentActivity":
            guard let child = SessionStructureText.string(item["agent_thread_id"]) else { return }
            if subagentSteps[child] != nil { return }
            step = Step(
                kind: .subagent,
                name: "subagent",
                argsSummary: isFull ? SessionStructureText.summary(SessionStructureText.string(item["agent_path"])) : nil,
                childSessionID: child
            )
        case "CollabAgentToolCall":
            let tool = SessionStructureText.string(item["tool"]) ?? "call"
            let receivers = item["receiver_thread_ids"] as? [Any] ?? []
            let child = receivers.compactMap { $0 as? String }.first
            let status = (item["status"] as? String)?.lowercased()
            step = Step(
                kind: tool.lowercased().contains("spawn") ? .subagent : .toolCall,
                name: "collab.\(tool)",
                isError: status == "failed",
                childSessionID: child
            )
            if let child, step.kind == .subagent, subagentSteps[child] != nil { return }
        default:
            return
        }

        // An item that shares a call's id completes that call rather than
        // adding a second step for the same work — whether or not an
        // `*_output` record also arrives (before or after it).
        if let itemID, acc.location(forCall: itemID) != nil {
            let completed = step
            let location = acc.completeCall(itemID) { existing in
                if completed.kind == .command || completed.kind == .mcpCall { existing.kind = completed.kind }
                existing.exitCode = completed.exitCode ?? existing.exitCode
                existing.durationMs = completed.durationMs ?? existing.durationMs
                existing.isError = existing.isError || completed.isError
                if existing.argsSummary == nil { existing.argsSummary = completed.argsSummary }
                if existing.resultSummary == nil { existing.resultSummary = completed.resultSummary }
                if existing.childSessionID == nil { existing.childSessionID = completed.childSessionID }
            }
            if let child = completed.childSessionID, let location { subagentSteps[child] = location }
            return
        }
        let turn = acc.ensureTurn(offset: line.offset, timestamp: timestamp(object), model: currentModel)
        step.parentCallID = acc.innermostOpenCall
        step.timestamp = isFull ? timestamp(object) : nil
        step.byteOffset = line.offset
        let location = acc.addStep(step, turn: turn)
        if let itemID { acc.index(callID: itemID, at: location) }
        if let child = step.childSessionID { subagentSteps[child] = location }
    }

    func addNote(_ name: String, line: SessionStructureLineReader.Line, object: [String: Any]) {
        guard isFull, let current = acc.current else { return }
        acc.addStep(Step(kind: .note, name: name, timestamp: timestamp(object), byteOffset: line.offset), turn: current)
    }

    // MARK: Truncated lines

    func consumeTruncated(_ line: SessionStructureLineReader.Line) {
        let head = line.data
        if let ordinal = SessionStructureLineReader.sniffInt("ordinal", in: head.prefix(160)),
           let cutOrdinal, ordinal < cutOrdinal {
            acc.diagnostics.inheritedLinesSkipped += 1
            return
        }
        let payloadType = Self.sniffPayloadType(head)
        let isOutput = payloadType?.hasSuffix("_output") == true
            || ["\"function_call_output\"", "\"custom_tool_call_output\"", "\"local_shell_call_output\"", "\"tool_search_output\""]
                .contains { SessionStructureLineReader.contains($0, in: head) }
        guard let callID = SessionStructureLineReader.sniffString("call_id", in: head) else { return }
        if isOutput {
            let megabytes = Double(line.length) / 1_048_576
            let isFull = self.isFull
            acc.resolveCall(callID) { step in
                if isFull { step.resultSummary = String(format: "[output too large to summarize: %.1f MB]", megabytes) }
            }
            return
        }
        // An oversized call (a patch with a huge body): record it without
        // arguments so its output still pairs.
        guard payloadType == "function_call" || payloadType == "custom_tool_call" else { return }
        let name = SessionStructureLineReader.sniffString("name", in: head) ?? "tool"
        let kind: Step.Kind = payloadType == "function_call" ? Self.functionKind(name) : .toolCall
        let turn = acc.ensureTurn(offset: line.offset, timestamp: nil, model: currentModel)
        acc.addStep(Step(kind: kind, name: name, callID: callID, pairing: .pending, byteOffset: line.offset), turn: turn)
    }

    /// The payload's `type`: the second `"type":"…"` in a rollout line.
    static func sniffPayloadType(_ data: Data) -> String? {
        guard let marker = "\"payload\":".data(using: .utf8),
              let found = data.range(of: marker)
        else { return nil }
        return SessionStructureLineReader.sniffString("type", in: Data(data[found.upperBound...].prefix(400)))
    }

    // MARK: Usage

    struct RawTotals: Equatable {
        var input = 0
        var cached = 0
        var cacheWrite = 0
        var output = 0

        init() {}

        init(_ dict: [String: Any]) {
            input = SessionStructureText.int(dict["input_tokens"]) ?? 0
            cached = SessionStructureText.int(dict["cached_input_tokens"] ?? dict["cache_read_input_tokens"]) ?? 0
            cacheWrite = SessionStructureText.int(dict["cache_write_input_tokens"]) ?? 0
            output = SessionStructureText.int(dict["output_tokens"]) ?? 0
        }

        var total: Int { input + output }

        func minus(_ other: RawTotals) -> RawTotals {
            var delta = RawTotals()
            delta.input = max(0, input - other.input)
            delta.cached = max(0, cached - other.cached)
            delta.cacheWrite = max(0, cacheWrite - other.cacheWrite)
            delta.output = max(0, output - other.output)
            return delta
        }

        /// Each field capped at `limit`'s.
        func clamped(to limit: RawTotals) -> RawTotals {
            var capped = RawTotals()
            capped.input = min(input, max(0, limit.input))
            capped.cached = min(cached, max(0, limit.cached))
            capped.cacheWrite = min(cacheWrite, max(0, limit.cacheWrite))
            capped.output = min(output, max(0, limit.output))
            return capped
        }

        func plus(_ other: RawTotals) -> RawTotals {
            var sum = RawTotals()
            sum.input = input + other.input
            sum.cached = cached + other.cached
            sum.cacheWrite = cacheWrite + other.cacheWrite
            sum.output = output + other.output
            return sum
        }

        /// Codex counts cached and cache-write tokens inside `input_tokens`.
        var usage: SessionStructure.TokenUsage {
            let cachedPart = min(max(0, cached), max(0, input))
            let writePart = min(max(0, cacheWrite), max(0, input - cachedPart))
            return SessionStructure.TokenUsage(
                input: max(0, input - cachedPart - writePart),
                cacheWrite: writePart,
                cacheRead: cachedPart,
                output: max(0, output)
            )
        }
    }

    /// One reading of the session's usage, bucketed by turn (`-1` before
    /// the first) and model, each request priced as it arrived.
    struct UsageEntry {
        var usage = SessionStructure.TokenUsage.zero
        var cost = 0.0
        var priced = false
        var unpriced = false
    }

    struct UsageSeries {
        var byTurn: [Int: [String: UsageEntry]] = [:]

        static func total(_ entries: [String: UsageEntry]?) -> SessionStructure.TokenUsage {
            (entries ?? [:]).values.reduce(.zero) { $0 + $1.usage }
        }

        /// `entries` less `amount` (bucket by bucket, models in order), each
        /// entry's cost scaled with what is left of its tokens.
        static func removing(_ amount: SessionStructure.TokenUsage, from entries: [String: UsageEntry]) -> [String: UsageEntry] {
            guard !amount.isZero else { return entries }
            var remaining = amount
            var result = entries
            for model in entries.keys.sorted() {
                guard var entry = result[model], !entry.usage.isZero else { continue }
                let before = entry.usage.total
                let taken = entry.usage.bucketMin(remaining)
                entry.usage = entry.usage - taken
                remaining = remaining - taken
                if before > 0 { entry.cost *= Double(entry.usage.total) / Double(before) }
                result[model] = entry
            }
            return result
        }

        mutating func add(turn: Int, model: String?, usage: SessionStructure.TokenUsage, cost: Double?) {
            let key = model ?? ""
            var entry = byTurn[turn]?[key] ?? UsageEntry()
            entry.usage += usage
            if let cost, cost.isFinite {
                entry.cost += cost
                entry.priced = true
            } else {
                entry.unpriced = true
            }
            byTurn[turn, default: [:]][key] = entry
        }
    }

    enum UsageSource { case counter, counterCatchUp, record }

    /// `token_count.total_token_usage`: a cumulative counter, differenced
    /// against its own previous value only. `response` is the record's
    /// `last_token_usage`; growth beyond it is catch-up for replies the
    /// counter skipped before.
    func applyCumulative(_ totals: RawTotals, response: RawTotals? = nil) {
        let hadOwnCounter = counterSeen
        ownCounterSeen = true
        counterSeen = true
        lastCumulativeTotal = totals.total
        guard let last = lastTotals else {
            lastTotals = totals
            // A window that starts mid-file has no baseline: the first
            // counter it sees is the history before it, not one request.
            if (options.byteRange?.lowerBound ?? 0) == 0 { record(delta: totals, source: .counter) }
            return
        }
        if totals == last { return }
        if totals.total < last.total {
            // A counter that went backwards was reset; what it shows now is
            // new. (Dropping below an *inherited* baseline is a cut fork's
            // own counter starting, not a reset.)
            if hadOwnCounter {
                counterResets += 1
                counterResetTurns.insert(acc.current ?? -1)
            }
            lastTotals = totals
            record(delta: totals, source: .counter)
            return
        }
        lastTotals = totals
        let delta = totals.minus(last)
        guard let response else {
            record(delta: delta, source: .counter)
            return
        }
        let own = delta.clamped(to: response)
        record(delta: own, source: .counter)
        record(delta: delta.minus(own), source: .counterCatchUp)
    }

    func applyIncrement(_ increment: RawTotals) {
        ownCounterSeen = true
        counterSeen = true
        lastTotals = (lastTotals ?? RawTotals()).plus(increment)
        lastCumulativeTotal = lastTotals?.total
        record(delta: increment, source: .counter)
    }

    /// `token_usage_record`: its `usage` is the one response's tokens, so it
    /// needs no baseline; `thread_token_usage` is differenced only against
    /// earlier records when `usage` is missing.
    func applyUsageRecord(_ payload: [String: Any]) {
        let thread = (payload["thread_token_usage"] as? [String: Any]).map(RawTotals.init)
        if let thread { lastRecordThreadTotal = thread.total }
        if let usage = payload["usage"] as? [String: Any] {
            ownCounterSeen = true
            if let thread { lastRecordThread = thread }
            record(delta: RawTotals(usage), source: .record)
            return
        }
        guard let thread else { return }
        ownCounterSeen = true
        defer { lastRecordThread = thread }
        guard let last = lastRecordThread else {
            if (options.byteRange?.lowerBound ?? 0) == 0 { record(delta: thread, source: .record) }
            return
        }
        if thread == last { return }
        record(delta: thread.total < last.total ? thread : thread.minus(last), source: .record)
    }

    func trackInheritedTotals(_ object: [String: Any]) {
        let payload = object["payload"] as? [String: Any] ?? [:]
        if object["type"] as? String == "event_msg", payload["type"] as? String == "token_count",
           let total = (payload["info"] as? [String: Any])?["total_token_usage"] as? [String: Any] {
            lastTotals = RawTotals(total)
        } else if object["type"] as? String == "token_usage_record",
                  let total = payload["thread_token_usage"] as? [String: Any] {
            lastRecordThread = RawTotals(total)
        }
    }

    func record(delta: RawTotals, source: UsageSource) {
        let usage = delta.usage
        guard !usage.isZero else { return }
        var cost: Double?
        if let model = currentModel, let entry = pricing.codexEntry(for: model, serviceTier: currentTier) {
            cost = CostUsagePricing.codexCostUSD(
                pricing: entry,
                inputTokens: delta.input,
                cachedInputTokens: delta.cached,
                outputTokens: delta.output,
                serviceTier: currentTier
            )
        }
        let turn = acc.current ?? -1
        acc.noteUsage()
        switch source {
        case .counter: counterSeries.add(turn: turn, model: currentModel, usage: usage, cost: cost)
        case .counterCatchUp: counterCatchUpSeries.add(turn: turn, model: currentModel, usage: usage, cost: cost)
        case .record: recordSeries.add(turn: turn, model: currentModel, usage: usage, cost: cost)
        }
    }

    /// Attribute usage turn by turn: from the per-response records when the
    /// turn has any, from `token_count` otherwise. Returns whether records
    /// were used.
    ///
    /// The counter can skip a reply that a record covers and absorb it in a
    /// later step. If that later step falls in a turn read from the counter,
    /// the absorbed growth was already counted from the records, so it is
    /// dropped there. `pending` is the record-only growth the counter has
    /// not absorbed yet; a counter reset ends the epoch it could be absorbed
    /// in. Absorption is recognized only as growth beyond the step's own
    /// `last_token_usage` — a counter that never catches up (what local
    /// rollouts show) costs nothing here.
    func attributeUsage(to turns: inout [SessionStructure.Turn]) -> Bool {
        var usedRecords = false
        var pending = SessionStructure.TokenUsage.zero
        let keys = Set(counterSeries.byTurn.keys)
            .union(counterCatchUpSeries.byTurn.keys)
            .union(recordSeries.byTurn.keys)
            .sorted()
        func add(_ entries: [String: UsageEntry], turn key: Int) {
            for model in entries.keys.sorted() {
                guard let entry = entries[model], !entry.usage.isZero else { continue }
                let name = model.isEmpty ? nil : model
                if key >= 0, key < turns.count {
                    turns[key].usage += entry.usage
                    if turns[key].model == nil { turns[key].model = name }
                } else {
                    acc.unattributedUsage += entry.usage
                }
                acc.ledger.merge(model: name, usage: entry.usage, cost: entry.cost,
                                 priced: entry.priced, unpriced: entry.unpriced)
            }
        }
        for key in keys {
            if counterResetTurns.contains(key) { pending = .zero }
            let counterOwn = UsageSeries.total(counterSeries.byTurn[key])
            let catchUp = UsageSeries.total(counterCatchUpSeries.byTurn[key])
            if let fromRecords = recordSeries.byTurn[key] {
                usedRecords = true
                add(fromRecords, turn: key)
                pending = (pending - pending.bucketMin(catchUp))
                    + (UsageSeries.total(fromRecords) - counterOwn).clampedNonNegative
            } else {
                add(counterSeries.byTurn[key] ?? [:], turn: key)
                let absorbed = pending.bucketMin(catchUp)
                pending = pending - absorbed
                add(UsageSeries.removing(absorbed, from: counterCatchUpSeries.byTurn[key] ?? [:]), turn: key)
            }
        }
        return usedRecords
    }

    // MARK: Finish

    func finish(outcome: SessionStructureLineReader.Outcome) -> SessionStructure {
        acc.diagnostics.bytesRead = outcome.bytesRead
        acc.diagnostics.incomplete = !outcome.completed
        var turns = acc.finish(lastLineEnd: lastLineEnd)
        let usedRecords = attributeUsage(to: &turns)
        settleHumanInputs(&turns)
        if stats.startedAt == nil {
            stats.startedAt = turns.first?.startedAt ?? firstTimestampRaw.flatMap(SessionStructureText.date)
        }
        stats.endedAt = lastTimestampRaw.flatMap(SessionStructureText.date) ?? turns.last?.endedAt
        SessionStatsBuilder.apply(turns: turns, ledger: acc.ledger, into: &stats)
        let summed = acc.ledger.totalUsage
        stats.counterResets = counterResets
        if options.byteRange == nil, ownCounterSeen {
            // Same basis as `threads.tokens_used`: the last `token_count`
            // value as written, else the last record's thread total.
            stats.cumulativeTokensIncludingInherited = (counterSeen ? lastCumulativeTotal : nil) ?? lastRecordThreadTotal
        }
        if usedRecords {
            stats.totalUsage = summed
            stats.totalTokens = summed.total
            stats.usageSource = .responseRecords
        } else if options.byteRange == nil, counterSeen, let lastTotals {
            let cumulative = lastCumulativeTotal ?? lastTotals.total
            if cutOrdinal != nil || counterResets > 0 {
                // The last counter value is not this session's total when the
                // counter carried on from copied parent history (parent +
                // child) or restarted mid-session (only the latest epoch).
                // What the session used is the sum of its deltas — the
                // per-turn ledger.
                stats.totalUsage = summed
                stats.totalTokens = summed.total
                stats.usageSource = .ownCounterDeltas
            } else {
                stats.totalUsage = lastTotals.usage
                stats.totalTokens = cumulative
                stats.usageSource = .cumulativeCounter
            }
        } else if !summed.isZero {
            stats.totalUsage = summed
            stats.totalTokens = summed.total
            stats.usageSource = .cumulativeCounter
        }
        return SessionStructure(
            provider: .codex,
            sessionID: sessionID ?? SessionStructureText.trailingUUID(
                in: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            ),
            sourcePath: path,
            detail: options.detail,
            parsedRange: options.byteRange,
            turns: turns,
            stats: stats,
            diagnostics: acc.diagnostics
        )
    }

    // MARK: Helpers

    func timestamp(_ object: [String: Any]) -> Date? {
        SessionStructureText.date(object["timestamp"])
    }

    static func functionKind(_ name: String) -> Step.Kind {
        if CodexSessionStructureParser.commandToolNames.contains(name) { return .command }
        if CodexSessionStructureParser.subagentToolNames.contains(name) { return .subagent }
        if name.hasPrefix("mcp__") { return .mcpCall }
        return .toolCall
    }

    static func commandText(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let parts = value as? [Any] {
            let strings = parts.compactMap { $0 as? String }
            // `["bash", "-lc", "<script>"]` — the script is what was run.
            if strings.count == 3, strings[1] == "-lc" || strings[1] == "-c" { return strings[2] }
            return strings.joined(separator: " ")
        }
        return nil
    }

    static func functionArgs(name: String, arguments: Any?) -> String? {
        let dict: [String: Any]?
        if let raw = arguments as? String {
            dict = SessionStructureText.jsonObject(fromString: raw)
            if dict == nil { return raw }
        } else {
            dict = arguments as? [String: Any]
        }
        guard let dict else { return nil }
        for key in ["cmd", "command"] {
            if let command = commandText(dict[key]) { return command }
        }
        for key in ["message", "task", "prompt", "path", "query", "url"] {
            if let value = SessionStructureText.string(dict[key]) { return value }
        }
        return SessionStructureText.compactJSON(dict)
    }

    static func customToolArgs(name: String, input: String?) -> String? {
        guard let input else { return nil }
        if name == "apply_patch" {
            var files: [String] = []
            for line in input.split(separator: "\n", omittingEmptySubsequences: true).prefix(4_000) {
                for marker in ["*** Add File: ", "*** Update File: ", "*** Delete File: "] where line.hasPrefix(marker) {
                    files.append(String(line.dropFirst(marker.count)))
                }
                if files.count >= 8 { break }
            }
            if !files.isEmpty { return files.joined(separator: ", ") }
        }
        let firstLines = input.split(separator: "\n", omittingEmptySubsequences: true)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
            .prefix(3)
        return firstLines.joined(separator: " ⏎ ")
    }

    static func mcpArgs(_ value: Any?) -> String? {
        if let dict = value as? [String: Any] {
            if let title = SessionStructureText.string(dict["title"]) { return title }
            return SessionStructureText.compactJSON(dict)
        }
        return SessionStructureText.compactJSON(value)
    }

    static func outputText(_ output: Any?) -> String {
        if let string = output as? String { return string }
        if let blocks = output as? [Any] {
            for block in blocks {
                guard let dict = block as? [String: Any] else { continue }
                if let text = dict["text"] as? String { return text }
            }
            return ""
        }
        if let dict = output as? [String: Any] {
            return SessionParsing.firstNonEmptyText(dict["content"], dict["text"], dict["output"])
        }
        return ""
    }
}

// MARK: - Tool output classification

/// Reads the status header Codex puts in front of a tool's output. Five
/// shapes are in the wild (measured across local rollouts):
///
/// - `{"output": "…", "metadata": {"exit_code": 0, "duration_seconds": 0.1}}`
/// - `Exit code: N` / `Wall time: X seconds` / `Output:` (shell)
/// - `Chunk ID: …` / `Wall time: …` / `Process exited with code N` (or
///   `Process running with session ID N`) / `Original token count: …` /
///   `Output:` (unified exec)
/// - `Script completed` / `Script failed` / `Script running with cell ID N`,
///   then `Wall time X seconds` / `Output:` (code-mode `exec`)
/// - a bare error line (`apply_patch verification failed: …`).
enum CodexToolOutput {
    struct Result: Equatable {
        var exitCode: Int?
        var durationMs: Int?
        var isError: Bool
        var isRunning: Bool
        var body: String
    }

    static let errorPrefixes = [
        "apply_patch verification failed", "failed to parse", "error:", "execution error",
        "aborted", "command failed", "sandbox denied", "failed to"
    ]

    static func classify(_ fullText: String) -> Result {
        let text = SessionStructureText.nativeHead(fullText, maxUTF16: 16_384)
        var result = Result(exitCode: nil, durationMs: nil, isError: false, isRunning: false, body: text)
        let trimmed = text.drop(while: { $0.isWhitespace })
        if trimmed.first == "{", let json = SessionStructureText.jsonObject(fromString: fullText) {
            if let metadata = json["metadata"] as? [String: Any] {
                result.exitCode = SessionStructureText.int(metadata["exit_code"])
                if let seconds = (metadata["duration_seconds"] as? NSNumber)?.doubleValue {
                    result.durationMs = Int((seconds * 1000).rounded())
                }
            }
            if let output = json["output"] as? String { result.body = SessionStructureText.nativeHead(output, maxUTF16: 4_096) }
            if (json["timed_out"] as? Bool) == true { result.isError = true }
            if let exit = result.exitCode, exit != 0 { result.isError = true }
            return result
        }

        var bodyStart: String.Index?
        var index = trimmed.startIndex
        var headerLines = 0
        while index < trimmed.endIndex, headerLines < 8 {
            let lineEnd = trimmed[index...].firstIndex(of: "\n") ?? trimmed.endIndex
            let lineText = trimmed[index..<lineEnd]
            let next = lineEnd < trimmed.endIndex ? trimmed.index(after: lineEnd) : trimmed.endIndex
            headerLines += 1
            if lineText.hasPrefix("Exit code:") {
                result.exitCode = Int(lineText.dropFirst("Exit code:".count).trimmingCharacters(in: .whitespaces))
            } else if lineText.hasPrefix("Process exited with code") {
                result.exitCode = Int(lineText.dropFirst("Process exited with code".count).trimmingCharacters(in: .whitespaces))
            } else if lineText.hasPrefix("Process running with") || lineText.hasPrefix("Script running with") {
                result.isRunning = true
            } else if lineText.hasPrefix("Wall time") {
                result.durationMs = wallTimeMs(lineText)
            } else if lineText.hasPrefix("Script failed") {
                result.isError = true
            } else if lineText.hasPrefix("Script completed") || lineText.hasPrefix("Chunk ID:")
                        || lineText.hasPrefix("Original token count:") {
                // header, nothing to record
            } else if lineText.hasPrefix("Output:") {
                bodyStart = next
                break
            } else {
                if headerLines == 1 {
                    let lowered = lineText.prefix(64).lowercased()
                    if errorPrefixes.contains(where: { lowered.hasPrefix($0) }) { result.isError = true }
                }
                break
            }
            index = next
        }
        if let exit = result.exitCode, exit != 0 { result.isError = true }
        if let bodyStart { result.body = String(trimmed[bodyStart...].prefix(4_096)) }
        return result
    }

    /// `Wall time: 0.1234 seconds` / `Wall time 9.9 seconds`.
    static func wallTimeMs(_ line: Substring) -> Int? {
        let digits = line.drop(while: { !$0.isNumber })
        let number = digits.prefix(while: { $0.isNumber || $0 == "." })
        guard let seconds = Double(number) else { return nil }
        return Int((seconds * 1000).rounded())
    }
}
