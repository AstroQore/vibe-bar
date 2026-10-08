import Foundation

/// Reads a Claude Code session log (`~/.claude/projects/<project>/<id>.jsonl`,
/// or a `subagents/agent-<id>.jsonl` sidecar) into a `SessionStructure`.
///
/// Claude writes one line per content block, appended in time order, and
/// links them with `uuid` / `parentUuid`. A line joins the turn its parent
/// belongs to; a human prompt whose parent sits in an *earlier* turn is a
/// rewind, and the turns it skipped over are marked `abandoned` (kept for
/// the record, left out of the counts). `tool_use` pairs with the later
/// `tool_result` by id. Usage is `message.usage`, deduplicated by message
/// id + request id with the last line winning — every content block of one
/// response repeats it.
///
/// Inline sidechains (`isSidechain`, older Task subagents) roll up into
/// `SessionStructure.sidechains` instead of the main turns. A resumed or
/// forked log starts with lines copied from the earlier session(s) — they
/// carry the earlier `sessionId` — and those are skipped, the same rule the
/// Codex parser applies to inherited rollout history.
public enum ClaudeSessionStructureParser {
    public static func parse(
        fileURL: URL,
        options: SessionStructureParseOptions = SessionStructureParseOptions(),
        isCancelled: () -> Bool = { false }
    ) -> SessionStructure? {
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else { return nil }
        let builder = ClaudeStructureBuilder(url: fileURL, options: options)
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

    /// `subagents/agent-<id>.jsonl` → `<id>`.
    static func subagentID(forFile url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard url.deletingLastPathComponent().lastPathComponent == "subagents",
              stem.hasPrefix("agent-"), stem.count > "agent-".count
        else { return nil }
        return String(stem.dropFirst("agent-".count))
    }

    static func toolKind(_ name: String) -> SessionStructure.Step.Kind {
        switch name {
        case "Bash", "PowerShell": return .command
        case "Task", "Agent": return .subagent
        default: return name.hasPrefix("mcp__") ? .mcpCall : .toolCall
        }
    }

    /// `<command-name>/review</command-name> … <command-args>fix X</command-args>`
    /// → ("/review", "fix X"). Nil when the text is not a slash command.
    static func slashCommand(in text: String) -> (name: String, arguments: String)? {
        guard let name = tagContent("command-name", in: text) else { return nil }
        let arguments = tagContent("command-args", in: text) ?? ""
        return (name, arguments.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func tagContent(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        let value = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// `mcp__server__tool` → `server.tool`.
    static func displayName(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.dropFirst("mcp__".count).components(separatedBy: "__")
        guard parts.count >= 2 else { return name }
        return parts[0] + "." + parts.dropFirst().joined(separator: "__")
    }

    static func toolArgs(name: String, input: [String: Any]?) -> String? {
        guard let input else { return nil }
        switch name {
        case "Bash", "PowerShell":
            return SessionStructureText.string(input["command"])
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit":
            return SessionStructureText.string(input["file_path"]) ?? SessionStructureText.string(input["notebook_path"])
        case "Grep", "Glob":
            let pattern = SessionStructureText.string(input["pattern"]) ?? ""
            if let path = SessionStructureText.string(input["path"]) { return "\(pattern) in \(path)" }
            return pattern
        case "WebFetch":
            return SessionStructureText.string(input["url"])
        case "WebSearch":
            return SessionStructureText.string(input["query"])
        case "Task", "Agent":
            let description = SessionStructureText.string(input["description"]) ?? ""
            if let type = SessionStructureText.string(input["subagent_type"]) { return "\(type): \(description)" }
            return description
        case "TodoWrite":
            return "\((input["todos"] as? [Any])?.count ?? 0) todos"
        case "Skill":
            return SessionStructureText.string(input["skill"]) ?? SessionStructureText.string(input["command"])
        default:
            return SessionStructureText.compactJSON(input)
        }
    }
}

private final class ClaudeStructureBuilder {
    typealias Step = SessionStructure.Step

    struct UsageRecord {
        var turn: Int?
        var sidechain: String?
        var model: String?
        var usage: SessionStructure.TokenUsage
        var isFast: Bool
    }

    let url: URL
    let options: SessionStructureParseOptions
    let acc: SessionStructureAccumulator
    let pricing = CostPricingContext()
    let subagentFileID: String?
    let ownSessionID: String?

    var stats = SessionStats()
    var lineIndex = 0
    var sawOwnLine = false
    var inheritedFrom: String?
    var uuidToTurn: [String: Int] = [:]
    var keyedUsage: [String: UsageRecord] = [:]
    var keyedOrder: [String] = []
    var unkeyedUsage: [UsageRecord] = []
    var sidechains: [String: SessionStructure.SidechainRollup] = [:]
    var sidechainOrder: [String] = []
    var sidechainModels: [String: Set<String>] = [:]
    var callTimestamps: [String: Date] = [:]
    var firstTimestampRaw: String?
    var lastTimestampRaw: String?
    var parentSessionID: String?
    var lastBranchRaw: String?
    var customTitle: String?
    var summaryTitle: String?
    var entrypoint: String?
    var promptsSeen = 0
    var lastLineEnd: Int64 = 0

    init(url: URL, options: SessionStructureParseOptions) {
        self.url = url
        self.options = options
        self.acc = SessionStructureAccumulator(detail: options.detail)
        self.subagentFileID = ClaudeSessionStructureParser.subagentID(forFile: url)
        let stem = url.deletingPathExtension().lastPathComponent
        self.ownSessionID = subagentFileID == nil ? SessionStructureText.trailingUUID(in: stem) : nil
    }

    var isFull: Bool { options.detail == .full }

    // MARK: Lines

    func consume(_ line: SessionStructureLineReader.Line) {
        acc.diagnostics.linesRead += 1
        lastLineEnd = line.end
        defer { lineIndex += 1 }
        if line.isTruncated {
            acc.diagnostics.oversizedLines += 1
            consumeTruncated(line)
            return
        }
        guard let object = (try? JSONSerialization.jsonObject(with: line.data)) as? [String: Any] else {
            acc.diagnostics.undecodableLines += 1
            return
        }
        let type = object["type"] as? String
        switch type {
        case "custom-title":
            customTitle = SessionStructureText.string(object["customTitle"]) ?? customTitle
            return
        case "summary":
            summaryTitle = SessionStructureText.string(object["summary"]) ?? summaryTitle
            return
        default:
            break
        }

        // Lines copied from the session this one resumed / forked.
        if let ownSessionID, !sawOwnLine, let sid = object["sessionId"] as? String {
            if sid != ownSessionID {
                inheritedFrom = sid
                acc.diagnostics.inheritedLinesSkipped += 1
                return
            }
            sawOwnLine = true
            if inheritedFrom != nil { stats.forkStartOrdinal = lineIndex }
        } else if subagentFileID == nil, ownSessionID != nil, object["sessionId"] as? String == ownSessionID {
            sawOwnLine = true
        }

        if let timestamp = object["timestamp"] as? String {
            if firstTimestampRaw == nil { firstTimestampRaw = timestamp }
            lastTimestampRaw = timestamp
        }
        readMetadata(object)

        let isSidechain = subagentFileID == nil && (object["isSidechain"] as? Bool ?? false)
        if isSidechain {
            consumeSidechain(object, type: type)
            return
        }
        let uuid = object["uuid"] as? String
        let parent = object["parentUuid"] as? String
        var attributed: Int?
        switch type {
        case "user":
            attributed = handleUser(object, parent: parent, line: line)
        case "assistant":
            attributed = handleAssistant(object, parent: parent, line: line)
        case "system":
            if (object["subtype"] as? String) == "compact_boundary", let turn = acc.current {
                if isFull {
                    acc.addStep(Step(kind: .note, name: "compaction", timestamp: timestamp(object), byteOffset: line.offset), turn: turn)
                }
            }
            attributed = target(parent: parent)
        case "attachment":
            acc.addInjected(.attachment)
            attributed = target(parent: parent)
        default:
            attributed = uuid == nil ? nil : target(parent: parent)
        }
        if let uuid, let attributed { uuidToTurn[uuid] = attributed }
        if let attributed {
            acc.touch(lineEnd: line.end)
            if let date = timestamp(object), (acc.turns[attributed].endedAt ?? .distantPast) < date {
                acc.turns[attributed].endedAt = date
            }
        }
    }

    func readMetadata(_ object: [String: Any]) {
        if let raw = object["gitBranch"] as? String, raw != lastBranchRaw {
            lastBranchRaw = raw
            if let branch = SessionStructureText.string(raw) { stats.gitBranch = branch }
        }
        if stats.cwd == nil { stats.cwd = SessionStructureText.string(object["cwd"]) }
        if stats.cliVersion == nil { stats.cliVersion = SessionStructureText.string(object["version"]) }
        if entrypoint == nil { entrypoint = SessionStructureText.string(object["entrypoint"]) }
        if subagentFileID != nil, parentSessionID == nil {
            parentSessionID = SessionStructureText.string(object["sessionId"])
        }
    }

    /// The turn a line belongs to: its parent's, else the current one.
    func target(parent: String?) -> Int? {
        if let parent, let turn = uuidToTurn[parent], acc.turns[turn].status != .abandoned {
            return turn
        }
        return acc.current
    }

    // MARK: User lines

    func handleUser(_ object: [String: Any], parent: String?, line: SessionStructureLineReader.Line) -> Int? {
        let message = object["message"] as? [String: Any] ?? [:]
        let content = message["content"]

        if let blocks = content as? [Any], blocks.contains(where: { ($0 as? [String: Any])?["type"] as? String == "tool_result" }) {
            let turn = target(parent: parent) ?? acc.ensureTurn(offset: line.offset, timestamp: timestamp(object), model: nil)
            let resultDate = isFull ? timestamp(object) : nil
            let toolUseResult = object["toolUseResult"] as? [String: Any]
            for case let block as [String: Any] in blocks {
                switch block["type"] as? String {
                case "tool_result":
                    guard let id = block["tool_use_id"] as? String else { continue }
                    resolveToolResult(id: id, block: block, toolUseResult: toolUseResult, resultDate: resultDate)
                case "text":
                    acc.addInjected(.other)
                default:
                    break
                }
            }
            return turn
        }

        var texts: [String] = []
        var images = 0
        if let string = content as? String {
            texts.append(string)
        } else if let blocks = content as? [Any] {
            for case let block as [String: Any] in blocks {
                switch block["type"] as? String {
                case "text": if let text = block["text"] as? String { texts.append(text) }
                case "image", "document": images += 1
                default: break
                }
            }
        }
        let text = SessionStructureText.decisionPrefix(texts.joined(separator: "\n"))
        let originKind = ((object["origin"] as? [String: Any])?["kind"] as? String)?.lowercased()

        if (object["isCompactSummary"] as? Bool) == true {
            acc.addInjected(.compactionSummary)
            if isFull, let turn = acc.current {
                acc.addStep(Step(kind: .note, name: "compaction", timestamp: timestamp(object), byteOffset: line.offset), turn: turn)
            }
            return target(parent: parent)
        }
        if (object["isMeta"] as? Bool) == true || originKind == "task-notification" {
            let block = originKind == "task-notification"
                ? .taskNotification
                : (SessionStructureText.injectedBlock(for: text) ?? .other)
            acc.addInjected(block)
            return target(parent: parent)
        }

        // A slash command: `<command-name>/x</command-name>…<command-args>…`.
        // With arguments it is the person asking for something; bare, it is
        // a local command (`/model`, `/clear`) and stays out of the count.
        if let command = ClaudeSessionStructureParser.slashCommand(in: text) {
            guard !command.arguments.isEmpty else {
                acc.addInjected(.commandOutput)
                return target(parent: parent)
            }
            let display = command.name + " " + command.arguments
            return openPrompt(origin: .human, text: display, rawText: "", parent: parent, object: object, line: line)
        }

        let lowered = text.drop(while: { $0.isWhitespace }).prefix(40).lowercased()
        // A `!command` the person ran in the shell, and the interruption
        // marker Claude Code writes, are not questions to the agent.
        if lowered.hasPrefix("<bash-input>") || lowered.hasPrefix("<bash-stdout>") || lowered.hasPrefix("<bash-stderr>") {
            acc.addInjected(.commandOutput)
            return target(parent: parent)
        }
        if lowered.hasPrefix("[request interrupted by user") {
            if let turn = target(parent: parent), acc.turns[turn].status != .abandoned {
                acc.turns[turn].status = .aborted
            }
            return target(parent: parent)
        }

        let origin: SessionStructure.PromptOrigin
        if subagentFileID != nil {
            origin = .agent
        } else if originKind == "peer" {
            origin = .agent
        } else if lowered.hasPrefix("<scheduled-task") {
            origin = .automation
        } else if HumanPromptText.instruction(text) != nil || images > 0 {
            origin = .human
        } else {
            let blocks = SessionStructureText.injectedBlocks(in: text)
            if blocks.isEmpty {
                acc.addInjected(SessionStructureText.injectedBlock(for: text) ?? .other)
            } else {
                for block in blocks { acc.addInjected(block) }
            }
            return target(parent: parent)
        }
        let promptText: String = {
            if origin == .automation { return text }
            let stripped = HumanPromptText.stripMeta(text).trimmingCharacters(in: .whitespacesAndNewlines)
            return stripped.isEmpty ? "[image]" : stripped
        }()
        return openPrompt(origin: origin, text: promptText, rawText: text, parent: parent, object: object, line: line)
    }

    func openPrompt(
        origin: SessionStructure.PromptOrigin,
        text: String,
        rawText: String,
        parent: String?,
        object: [String: Any],
        line: SessionStructureLineReader.Line
    ) -> Int {
        // Rewind: the new prompt hangs off a line in an earlier turn, so the
        // turns after that one are no longer on the conversation's branch.
        if let parent, let anchor = uuidToTurn[parent], let current = acc.current, anchor < current {
            for index in (anchor + 1)...current where acc.turns[index].status != .abandoned {
                acc.turns[index].status = .abandoned
            }
        }
        let turn: Int
        if let current = acc.current, acc.turns[current].status != .abandoned,
           !acc.currentHasAgentActivity(), acc.turns[current].prompt.origin != .none {
            // Two inputs before the agent acted: one turn, one more message.
            turn = current
            if origin == .human { acc.turns[current].prompt.additionalHumanMessages += 1 }
        } else if let current = acc.current, acc.turns[current].prompt.origin == .none,
                  !acc.currentHasAgentActivity(), acc.turns[current].status != .abandoned {
            // Injected context opened an implicit turn just before the prompt.
            turn = current
            acc.setPrompt(turn: turn, origin: origin, text: text, tentative: false)
        } else {
            if let current = acc.current, acc.turns[current].status == .open {
                acc.close(status: .completed, endedAt: nil, durationMs: nil)
            }
            turn = acc.openTurn(
                offset: line.offset,
                turnID: object["uuid"] as? String,
                startedAt: timestamp(object),
                model: nil
            )
            acc.setPrompt(turn: turn, origin: origin, text: text, tentative: false)
        }
        for block in SessionStructureText.injectedBlocks(in: rawText) { acc.addInjected(block) }
        promptsSeen += 1
        return turn
    }

    func resolveToolResult(id: String, block: [String: Any], toolUseResult: [String: Any]?, resultDate: Date?) {
        let isError = block["is_error"] as? Bool ?? false
        let isFull = self.isFull
        let summary = isFull ? SessionStructureText.summary(SessionStructureText.text(block["content"])) : nil
        let callDate = callTimestamps.removeValue(forKey: id)
        let interrupted = toolUseResult?["interrupted"] as? Bool ?? false
        let reportedDuration = SessionStructureText.int(toolUseResult?["durationMs"])
            ?? SessionStructureText.int(toolUseResult?["totalDurationMs"])
        let agentID = SessionStructureText.string(toolUseResult?["agentId"])
        acc.resolveCall(id) { step in
            step.isError = isError || interrupted
            if isFull { step.resultSummary = summary }
            if let reportedDuration {
                step.durationMs = reportedDuration
            } else if let callDate, let resultDate, resultDate >= callDate {
                step.durationMs = Int((resultDate.timeIntervalSince(callDate) * 1000).rounded())
            }
            if let agentID, step.kind == .subagent { step.childSessionID = agentID }
        }
    }

    // MARK: Assistant lines

    func handleAssistant(_ object: [String: Any], parent: String?, line: SessionStructureLineReader.Line) -> Int {
        let message = object["message"] as? [String: Any] ?? [:]
        let model = SessionStructureText.string(message["model"]).flatMap { $0 == "<synthetic>" ? nil : $0 }
        let turn = target(parent: parent) ?? acc.ensureTurn(offset: line.offset, timestamp: timestamp(object), model: model)
        if let model { acc.turns[turn].model = model }
        if let usage = message["usage"] as? [String: Any] {
            recordUsage(usage, message: message, object: object, model: model, turn: turn, sidechain: nil)
        }
        if message["stop_reason"] as? String == "end_turn", acc.turns[turn].status == .open {
            acc.turns[turn].status = .completed
        }
        let stamp = isFull ? timestamp(object) : nil
        guard let blocks = message["content"] as? [Any] else {
            if let text = message["content"] as? String, !text.isEmpty {
                acc.assistantText(text, offset: line.offset, timestamp: stamp, turn: turn)
            }
            return turn
        }
        for case let block as [String: Any] in blocks {
            switch block["type"] as? String {
            case "thinking", "redacted_thinking":
                let thinking = block["thinking"] as? String ?? ""
                acc.addStep(Step(
                    kind: .thinking,
                    name: "thinking",
                    resultSummary: isFull && !thinking.isEmpty ? SessionStructureText.summary(thinking) : nil,
                    durationMs: SessionStructureText.int(object["thinkingDurationMs"]),
                    thinkingCharacters: thinking.isEmpty ? nil : SessionStructureText.length(thinking),
                    timestamp: stamp,
                    byteOffset: line.offset
                ), turn: turn)
            case "text":
                if let text = block["text"] as? String {
                    let head = SessionStructureText.nativeHead(text, maxUTF16: 2 * SessionStructure.Turn.finalAnswerLimit)
                    if !head.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        acc.assistantText(head, offset: line.offset, timestamp: stamp, turn: turn)
                    }
                }
            case "tool_use", "server_tool_use":
                let name = block["name"] as? String ?? "tool"
                let id = block["id"] as? String
                let input = block["input"] as? [String: Any]
                acc.addStep(Step(
                    kind: ClaudeSessionStructureParser.toolKind(name),
                    name: ClaudeSessionStructureParser.displayName(name),
                    argsSummary: isFull ? SessionStructureText.summary(ClaudeSessionStructureParser.toolArgs(name: name, input: input)) : nil,
                    callID: id,
                    pairing: id == nil ? .notApplicable : .pending,
                    timestamp: stamp,
                    byteOffset: line.offset
                ), turn: turn)
                if let id, let date = timestamp(object) { callTimestamps[id] = date }
            default:
                break
            }
        }
        return turn
    }

    func recordUsage(
        _ usage: [String: Any],
        message: [String: Any],
        object: [String: Any],
        model: String?,
        turn: Int?,
        sidechain: String?
    ) {
        let tokens = SessionStructure.TokenUsage(
            input: max(0, SessionStructureText.int(usage["input_tokens"]) ?? 0),
            cacheWrite: max(0, SessionStructureText.int(usage["cache_creation_input_tokens"]) ?? 0),
            cacheRead: max(0, SessionStructureText.int(usage["cache_read_input_tokens"]) ?? 0),
            output: max(0, SessionStructureText.int(usage["output_tokens"]) ?? 0)
        )
        guard !tokens.isZero else { return }
        let tier = (usage["speed"] as? String) ?? (usage["service_tier"] as? String)
        let record = UsageRecord(
            turn: turn, sidechain: sidechain, model: model, usage: tokens,
            isFast: tier == "fast" || tier == "priority"
        )
        if let messageID = message["id"] as? String, let requestID = object["requestId"] as? String {
            let key = messageID + "\u{0}" + requestID
            if keyedUsage[key] == nil { keyedOrder.append(key) }
            keyedUsage[key] = record
        } else {
            unkeyedUsage.append(record)
        }
    }

    // MARK: Sidechains

    func consumeSidechain(_ object: [String: Any], type: String?) {
        let key = SessionStructureText.string(object["agentId"]) ?? "sidechain"
        if sidechains[key] == nil {
            sidechains[key] = SessionStructure.SidechainRollup(agentID: key == "sidechain" ? nil : key)
            sidechainOrder.append(key)
        }
        sidechains[key]!.lineCount += 1
        let message = object["message"] as? [String: Any] ?? [:]
        let blocks = message["content"] as? [Any] ?? []
        if type == "assistant" {
            let model = SessionStructureText.string(message["model"]).flatMap { $0 == "<synthetic>" ? nil : $0 }
            if let model { sidechainModels[key, default: []].insert(model) }
            if let usage = message["usage"] as? [String: Any] {
                recordUsage(usage, message: message, object: object, model: model, turn: nil, sidechain: key)
            }
            for case let block as [String: Any] in blocks where block["type"] as? String == "tool_use" {
                sidechains[key]!.toolCallCount += 1
            }
        } else if type == "user" {
            for case let block as [String: Any] in blocks
            where block["type"] as? String == "tool_result" && (block["is_error"] as? Bool ?? false) {
                sidechains[key]!.failedToolCount += 1
            }
        }
    }

    // MARK: Truncated lines

    func consumeTruncated(_ line: SessionStructureLineReader.Line) {
        let head = line.data
        if let ownSessionID, !sawOwnLine,
           let sid = SessionStructureLineReader.sniffString("sessionId", in: head), sid != ownSessionID {
            acc.diagnostics.inheritedLinesSkipped += 1
            return
        }
        guard SessionStructureLineReader.sniffString("type", in: head) == "user" || SessionStructureLineReader.contains("\"tool_result\"", in: head),
              let id = SessionStructureLineReader.sniffString("tool_use_id", in: head)
        else { return }
        let isError = SessionStructureLineReader.contains("\"is_error\":true", in: head)
        let megabytes = Double(line.length) / 1_048_576
        let isFull = self.isFull
        acc.resolveCall(id) { step in
            step.isError = isError
            if isFull { step.resultSummary = String(format: "[result too large to summarize: %.1f MB]", megabytes) }
        }
        acc.touch(lineEnd: line.end)
    }

    // MARK: Finish

    func finish(outcome: SessionStructureLineReader.Outcome) -> SessionStructure {
        acc.diagnostics.bytesRead = outcome.bytesRead
        acc.diagnostics.incomplete = !outcome.completed

        var totals = SessionStructure.TokenUsage.zero
        var sidechainTotal = SessionStructure.TokenUsage.zero
        let records = keyedOrder.compactMap { keyedUsage[$0] } + unkeyedUsage
        for record in records {
            var cost: Double?
            if let model = record.model, let entry = pricing.claudeEntry(for: model) {
                cost = CostUsagePricing.claudeCostUSD(
                    pricing: entry,
                    inputTokens: record.usage.input,
                    cacheReadInputTokens: record.usage.cacheRead,
                    cacheCreationInputTokens: record.usage.cacheWrite,
                    outputTokens: record.usage.output,
                    isFast: record.isFast
                )
            }
            acc.ledger.add(model: record.model, usage: record.usage, cost: cost)
            totals += record.usage
            if let key = record.sidechain {
                sidechains[key]?.usage += record.usage
                sidechainTotal += record.usage
            } else if let turn = record.turn, turn < acc.turns.count {
                acc.turns[turn].usage += record.usage
            } else {
                acc.unattributedUsage += record.usage
            }
        }
        var turns = acc.finish(lastLineEnd: lastLineEnd)
        for index in turns.indices where turns[index].durationMs == nil {
            if let start = turns[index].startedAt, let end = turns[index].endedAt, end >= start {
                turns[index].durationMs = Int((end.timeIntervalSince(start) * 1000).rounded())
            }
        }

        if subagentFileID != nil {
            stats.kind = .subagent
            stats.relation = .spawnedBy
            stats.parentID = parentSessionID
        } else if let inheritedFrom {
            stats.kind = .fork
            stats.relation = .forkOf
            stats.parentID = inheritedFrom
        } else if let entrypoint, entrypoint.lowercased().hasPrefix("sdk") {
            stats.kind = .exec
        } else if turns.first(where: { $0.prompt.origin != .none })?.prompt.origin == .automation {
            stats.kind = .automation
        } else {
            stats.kind = .interactive
        }
        stats.title = customTitle ?? summaryTitle
        stats.startedAt = firstTimestampRaw.flatMap(SessionStructureText.date) ?? turns.first?.startedAt
        stats.endedAt = lastTimestampRaw.flatMap(SessionStructureText.date)
        SessionStatsBuilder.apply(turns: turns, ledger: acc.ledger, into: &stats)
        stats.totalUsage = totals
        stats.totalTokens = totals.total
        stats.usageSource = totals.isZero ? .none : .summedMessages
        stats.sidechainUsage = sidechainTotal

        let rollups: [SessionStructure.SidechainRollup] = sidechainOrder.compactMap { key in
            guard var rollup = sidechains[key] else { return nil }
            rollup.models = (sidechainModels[key] ?? []).sorted()
            return rollup
        }
        return SessionStructure(
            provider: .claude,
            sessionID: subagentFileID ?? ownSessionID,
            sourcePath: url.path,
            detail: options.detail,
            parsedRange: options.byteRange,
            turns: turns,
            stats: stats,
            sidechains: rollups,
            diagnostics: acc.diagnostics
        )
    }

    func timestamp(_ object: [String: Any]) -> Date? {
        SessionStructureText.date(object["timestamp"])
    }
}
