import Foundation

/// The *shape* of one session log: who asked what, what the agent did about
/// it step by step, what it cost, and how this session relates to others.
///
/// `SessionMessage` (agent-session-kit) keeps a flat `(seq, role, text)` list,
/// which is enough to search and to print a transcript but not to draw one:
/// a Codex rollout's `custom_tool_call`s, `item_completed` exit codes,
/// `token_count` usage, `turn_context` model and `task_started` /
/// `task_complete` boundaries never reach it, and neither do a Claude log's
/// thinking blocks, `message.usage`, or `parentUuid` graph. This is the host-
/// side reading of those records. It is derived data — every field can be
/// recomputed from the source file — and it carries no message body beyond
/// capped previews, so it can be cached next to the session index.
///
/// Pure values: `Sendable`, `Codable`, `Hashable`, no I/O. Parsers live in
/// `CodexSessionStructureParser` / `ClaudeSessionStructureParser`; caching in
/// `SessionStructureStore`; orchestration in `SessionStructureService`.
public struct SessionStructure: Codable, Sendable, Hashable {
    /// Bump whenever a parser change alters what an already-parsed file
    /// should say. `SessionStructureStore` drops every row stamped with an
    /// older version, so the next read re-parses.
    ///
    /// v2: a Codex session cut at its inherited-history ordinal reports its
    /// own counter deltas as `totalTokens` (`SessionUsageSource.ownCounterDeltas`).
    /// v3: `SessionTurnOutline` keeps every per-turn counter and prompt tally.
    /// v4: a cut session with no counter of its own no longer takes the
    /// Codex state database's inherited-inclusive total (`.unavailable`).
    /// v5: a Codex counter that resets mid-session sums its epochs.
    /// v6: a review thread recognized only by its model gets guardian
    /// verdicts and prompt origins, not just the guardian kind.
    /// v7: a guardian request with only `retained_source` keeps its
    /// reviewed turn.
    /// v8: Codex `token_usage_record` and `token_count` are read as two
    /// separate usage series, never as one counter (see
    /// `SessionUsageSource.responseRecords`).
    /// v9: a turn read from `token_count` drops catch-up growth for replies
    /// already counted from an earlier turn's records.
    public static let parserVersion = 9

    /// How much of each turn was materialized.
    public enum Detail: String, Codable, Sendable, Hashable {
        /// Steps, summaries and the final answer are present.
        case full
        /// Counts, usage, boundaries and a prompt preview only — `steps` is
        /// empty and `finalAnswer` is nil. What a large file gets on a
        /// background pass and what the sidecar can reconstruct.
        case outline
    }

    public var provider: SessionProvider
    /// The session id this file declares for itself (`session_meta.id`, the
    /// Claude file stem), when one could be read.
    public var sessionID: String?
    public var sourcePath: String
    public var detail: Detail
    /// `nil` when the whole file was read; otherwise the byte window asked for.
    public var parsedRange: ByteRange?
    public var turns: [Turn]
    public var stats: SessionStats
    /// Claude sidechains (older logs keep a Task subagent's conversation
    /// inline, flagged `isSidechain`). Rolled up here instead of being
    /// counted into the main turns.
    public var sidechains: [SidechainRollup]
    public var diagnostics: Diagnostics

    public init(
        provider: SessionProvider,
        sessionID: String?,
        sourcePath: String,
        detail: Detail,
        parsedRange: ByteRange? = nil,
        turns: [Turn] = [],
        stats: SessionStats = SessionStats(),
        sidechains: [SidechainRollup] = [],
        diagnostics: Diagnostics = Diagnostics()
    ) {
        self.provider = provider
        self.sessionID = sessionID
        self.sourcePath = sourcePath
        self.detail = detail
        self.parsedRange = parsedRange
        self.turns = turns
        self.stats = stats
        self.sidechains = sidechains
        self.diagnostics = diagnostics
    }
}

// MARK: - Byte range

extension SessionStructure {
    /// A half-open byte window into the source file. Its own type rather
    /// than `Range<Int64>` so the JSON shape is stable and explicit.
    public struct ByteRange: Codable, Sendable, Hashable {
        public var lowerBound: Int64
        public var upperBound: Int64

        public init(_ lowerBound: Int64, _ upperBound: Int64) {
            self.lowerBound = max(0, lowerBound)
            self.upperBound = max(self.lowerBound, upperBound)
        }

        public var count: Int64 { upperBound - lowerBound }
    }
}

// MARK: - Token usage

extension SessionStructure {
    /// Tokens in four disjoint buckets, so `total` is a plain sum.
    ///
    /// Codex reports `input_tokens` *including* the cached part; the parser
    /// splits it so `input` here is always the uncached, non-cache-write
    /// remainder, matching Claude's `input_tokens`.
    public struct TokenUsage: Codable, Sendable, Hashable {
        public var input: Int
        public var cacheWrite: Int
        public var cacheRead: Int
        public var output: Int

        public init(input: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0, output: Int = 0) {
            self.input = input
            self.cacheWrite = cacheWrite
            self.cacheRead = cacheRead
            self.output = output
        }

        public static let zero = TokenUsage()

        public var total: Int { input + cacheWrite + cacheRead + output }
        public var isZero: Bool { total == 0 }

        public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
            TokenUsage(
                input: lhs.input + rhs.input,
                cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
                cacheRead: lhs.cacheRead + rhs.cacheRead,
                output: lhs.output + rhs.output
            )
        }

        public static func += (lhs: inout TokenUsage, rhs: TokenUsage) { lhs = lhs + rhs }

        public static func - (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
            TokenUsage(
                input: lhs.input - rhs.input,
                cacheWrite: lhs.cacheWrite - rhs.cacheWrite,
                cacheRead: lhs.cacheRead - rhs.cacheRead,
                output: lhs.output - rhs.output
            )
        }

        /// The smaller of each bucket.
        public func bucketMin(_ other: TokenUsage) -> TokenUsage {
            TokenUsage(
                input: min(input, other.input), cacheWrite: min(cacheWrite, other.cacheWrite),
                cacheRead: min(cacheRead, other.cacheRead), output: min(output, other.output)
            )
        }

        /// Every bucket floored at zero — a reset counter must not subtract.
        public var clampedNonNegative: TokenUsage {
            TokenUsage(
                input: max(0, input), cacheWrite: max(0, cacheWrite),
                cacheRead: max(0, cacheRead), output: max(0, output)
            )
        }
    }
}

// MARK: - Prompt

extension SessionStructure {
    /// Machine context a harness files under the `user` (or `developer`)
    /// role. Counted per turn so a UI can say "3 injected blocks" without
    /// showing them as if the person had typed them.
    public enum InjectedBlock: String, Codable, Sendable, Hashable, CaseIterable {
        case agentsInstructions
        case environmentContext
        case developerMessage
        case systemReminder
        case taskNotification
        case commandOutput
        case skill
        case compactionSummary
        case attachment
        case other
    }

    /// Who produced the input that opened a turn.
    public enum PromptOrigin: String, Codable, Sendable, Hashable {
        /// Typed by the person.
        case human
        /// A scheduled task / Codex automation fired it.
        case automation
        /// Another agent: a subagent's task from its parent, a peer message.
        case agent
        /// A Codex guardian (Auto Review) request.
        case guardianRequest
        /// No opening input was seen (a continuation, an injected-only turn).
        case none
    }

    public struct Prompt: Codable, Sendable, Hashable {
        public static let textLimit = 4_000
        public static let previewLimit = 120

        public var origin: PromptOrigin
        /// The cleaned prompt (injected blocks stripped), capped at
        /// `textLimit`. `nil` in outline detail.
        public var text: String?
        /// One line, at most `previewLimit` characters.
        public var preview: String?
        /// Further human messages that arrived while this turn was running
        /// (Codex steering, Claude queued input). Each counts toward
        /// `SessionStats.promptCount`.
        public var additionalHumanMessages: Int
        /// Injected block counts keyed by `InjectedBlock.rawValue`.
        public var injected: [String: Int]

        public init(
            origin: PromptOrigin = .none,
            text: String? = nil,
            preview: String? = nil,
            additionalHumanMessages: Int = 0,
            injected: [String: Int] = [:]
        ) {
            self.origin = origin
            self.text = text
            self.preview = preview
            self.additionalHumanMessages = additionalHumanMessages
            self.injected = injected
        }

        public var injectedCount: Int { injected.values.reduce(0, +) }

        public func injectedCount(_ block: InjectedBlock) -> Int { injected[block.rawValue] ?? 0 }

        public mutating func addInjected(_ block: InjectedBlock, count: Int = 1) {
            guard count > 0 else { return }
            injected[block.rawValue, default: 0] += count
        }

        /// How many human prompts this turn contributes to `promptCount`.
        public var humanPromptCount: Int {
            (origin == .human ? 1 : 0) + additionalHumanMessages
        }
    }
}

// MARK: - Step

extension SessionStructure {
    public struct GuardianVerdict: Codable, Sendable, Hashable {
        /// `allow` / `deny` as the reviewer wrote it.
        public var outcome: String
        public var riskLevel: String?
        public var userAuthorization: String?

        public init(outcome: String, riskLevel: String? = nil, userAuthorization: String? = nil) {
            self.outcome = outcome
            self.riskLevel = riskLevel
            self.userAuthorization = userAuthorization
        }

        public var isDenied: Bool { outcome.lowercased() == "deny" }
    }

    public struct Step: Codable, Sendable, Hashable {
        public static let summaryLimit = 200

        public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
            /// A model-issued tool call that is neither a shell command nor
            /// an MCP call (`apply_patch`, `Read`, Codex code-mode `exec`, …).
            case toolCall
            /// A shell command (`exec_command`, `Bash`, a `CommandExecution`).
            case command
            case mcpCall
            case thinking
            /// Spawned or messaged another agent thread.
            case subagent
            case guardianVerdict
            /// Commentary between actions, a compaction marker, an injected
            /// notification — context, not an action.
            case note

            /// Whether the step is an *action* the agent took, i.e. counted
            /// by "N steps".
            public var isAction: Bool {
                switch self {
                case .toolCall, .command, .mcpCall, .subagent, .guardianVerdict: return true
                case .thinking, .note: return false
                }
            }
        }

        /// Whether a call found its result.
        public enum Pairing: String, Codable, Sendable, Hashable {
            /// Call and result were matched by id.
            case paired
            /// The call has no result (yet): still running, or the log ended.
            case pending
            /// A result whose call was never seen (cut history, truncated log).
            case orphanResult
            /// The step is not a call/result pair (thinking, a note, a
            /// self-contained `item_completed`).
            case notApplicable
        }

        public var kind: Kind
        public var name: String
        /// Arguments, one line, at most `summaryLimit` characters, paths kept
        /// and credential-shaped values masked (`VisibleSecretRedactor`).
        public var argsSummary: String?
        /// Same treatment for the result / output / rationale.
        public var resultSummary: String?
        public var isError: Bool
        public var exitCode: Int?
        public var durationMs: Int?
        public var callID: String?
        /// Set when this step ran *inside* another call — a command or MCP
        /// call made from a Codex code-mode `exec` script.
        public var parentCallID: String?
        public var pairing: Pairing
        /// The agent thread / Claude subagent id a `subagent` step points at.
        public var childSessionID: String?
        public var verdict: GuardianVerdict?
        /// Visible length of a thinking step's text (summary for Codex, the
        /// thinking block for Claude). `nil` when only encrypted content exists.
        public var thinkingCharacters: Int?
        public var timestamp: Date?
        /// Offset of the line that produced the step.
        public var byteOffset: Int64

        public init(
            kind: Kind,
            name: String,
            argsSummary: String? = nil,
            resultSummary: String? = nil,
            isError: Bool = false,
            exitCode: Int? = nil,
            durationMs: Int? = nil,
            callID: String? = nil,
            parentCallID: String? = nil,
            pairing: Pairing = .notApplicable,
            childSessionID: String? = nil,
            verdict: GuardianVerdict? = nil,
            thinkingCharacters: Int? = nil,
            timestamp: Date? = nil,
            byteOffset: Int64 = 0
        ) {
            self.kind = kind
            self.name = name
            self.argsSummary = argsSummary
            self.resultSummary = resultSummary
            self.isError = isError
            self.exitCode = exitCode
            self.durationMs = durationMs
            self.callID = callID
            self.parentCallID = parentCallID
            self.pairing = pairing
            self.childSessionID = childSessionID
            self.verdict = verdict
            self.thinkingCharacters = thinkingCharacters
            self.timestamp = timestamp
            self.byteOffset = byteOffset
        }
    }
}

// MARK: - Turn

extension SessionStructure {
    public enum TurnStatus: String, Codable, Sendable, Hashable {
        case completed
        case aborted
        /// The log ended (or the next turn began) without a completion record.
        case open
        /// Claude: the conversation was rewound past this turn, so it is no
        /// longer on the active branch.
        case abandoned
    }

    /// Per-turn counters, kept even in outline detail (where `steps` is empty).
    public struct TurnCounts: Codable, Sendable, Hashable {
        /// Actions: tool calls, commands, MCP calls, subagent and verdict steps.
        public var steps: Int
        public var toolCalls: Int
        public var commands: Int
        public var mcpCalls: Int
        public var subagents: Int
        public var thinking: Int
        /// Actions whose result reported failure.
        public var failed: Int

        public init(
            steps: Int = 0, toolCalls: Int = 0, commands: Int = 0, mcpCalls: Int = 0,
            subagents: Int = 0, thinking: Int = 0, failed: Int = 0
        ) {
            self.steps = steps
            self.toolCalls = toolCalls
            self.commands = commands
            self.mcpCalls = mcpCalls
            self.subagents = subagents
            self.thinking = thinking
            self.failed = failed
        }
    }

    public struct Turn: Codable, Sendable, Hashable {
        public static let finalAnswerLimit = 4_000

        public var index: Int
        /// Codex `turn_id`; Claude: the opening line's `uuid`.
        public var turnID: String?
        public var startedAt: Date?
        public var endedAt: Date?
        public var status: TurnStatus
        public var prompt: Prompt
        public var steps: [Step]
        public var counts: TurnCounts
        /// The last assistant message of the turn, capped; nil in outline.
        public var finalAnswer: String?
        /// The model in effect when the turn ran (Codex `turn_context.model`,
        /// Claude's last assistant `message.model`).
        public var model: String?
        public var usage: TokenUsage
        public var durationMs: Int?
        /// Offset of the first line of the turn, for windowed re-reads.
        public var byteOffset: Int64
        /// Offset just past the turn's last line.
        public var byteEnd: Int64
        /// Guardian: the parent turn the review request pointed at.
        public var reviewedTurnID: String?

        public init(
            index: Int,
            turnID: String? = nil,
            startedAt: Date? = nil,
            endedAt: Date? = nil,
            status: TurnStatus = .open,
            prompt: Prompt = Prompt(),
            steps: [Step] = [],
            counts: TurnCounts = TurnCounts(),
            finalAnswer: String? = nil,
            model: String? = nil,
            usage: TokenUsage = .zero,
            durationMs: Int? = nil,
            byteOffset: Int64 = 0,
            byteEnd: Int64 = 0,
            reviewedTurnID: String? = nil
        ) {
            self.index = index
            self.turnID = turnID
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.status = status
            self.prompt = prompt
            self.steps = steps
            self.counts = counts
            self.finalAnswer = finalAnswer
            self.model = model
            self.usage = usage
            self.durationMs = durationMs
            self.byteOffset = byteOffset
            self.byteEnd = byteEnd
            self.reviewedTurnID = reviewedTurnID
        }

        public var byteRange: ByteRange { ByteRange(byteOffset, byteEnd) }
    }
}

// MARK: - Sidechains & diagnostics

extension SessionStructure {
    /// One inline Claude sidechain (a Task subagent whose conversation the
    /// parent log kept), keyed by `agentId` when the lines carry one.
    public struct SidechainRollup: Codable, Sendable, Hashable {
        public var agentID: String?
        public var lineCount: Int
        public var toolCallCount: Int
        public var failedToolCount: Int
        public var usage: TokenUsage
        public var models: [String]

        public init(
            agentID: String?, lineCount: Int = 0, toolCallCount: Int = 0,
            failedToolCount: Int = 0, usage: TokenUsage = .zero, models: [String] = []
        ) {
            self.agentID = agentID
            self.lineCount = lineCount
            self.toolCallCount = toolCallCount
            self.failedToolCount = failedToolCount
            self.usage = usage
            self.models = models
        }
    }

    public struct Diagnostics: Codable, Sendable, Hashable {
        public var linesRead: Int
        public var bytesRead: Int64
        /// Lines that did not decode as a JSON object (skipped, never fatal).
        public var undecodableLines: Int
        /// Lines over the decode cap; only their head was inspected.
        public var oversizedLines: Int
        /// Lines skipped because they were copied from a parent session.
        public var inheritedLinesSkipped: Int
        public var pendingCalls: Int
        public var orphanResults: Int
        /// The read stopped early (I/O error or cancellation).
        public var incomplete: Bool

        public init(
            linesRead: Int = 0, bytesRead: Int64 = 0, undecodableLines: Int = 0,
            oversizedLines: Int = 0, inheritedLinesSkipped: Int = 0,
            pendingCalls: Int = 0, orphanResults: Int = 0, incomplete: Bool = false
        ) {
            self.linesRead = linesRead
            self.bytesRead = bytesRead
            self.undecodableLines = undecodableLines
            self.oversizedLines = oversizedLines
            self.inheritedLinesSkipped = inheritedLinesSkipped
            self.pendingCalls = pendingCalls
            self.orphanResults = orphanResults
            self.incomplete = incomplete
        }
    }
}

// MARK: - Session kind & stats

/// What kind of thread produced the file.
public enum SessionStructureKind: String, Codable, Sendable, Hashable, CaseIterable {
    case interactive
    /// Headless / SDK runs (`codex exec`, Claude SDK entrypoints).
    case exec
    case automation
    case subagent
    /// Codex guardian (Auto Review) reviewer thread.
    case guardian
    /// A user-initiated fork / resume that copied a parent's history.
    case fork
    /// A thread another agent created as a peer (`agent_created_thread`).
    case agentCreated
}

/// How `parentID` relates to this session.
public enum SessionStructureRelation: String, Codable, Sendable, Hashable {
    case forkOf
    case spawnedBy
    case reviews
    case createdBy
}

/// Where `SessionStats.totalUsage` / `totalTokens` came from.
public enum SessionUsageSource: String, Codable, Sendable, Hashable {
    /// Codex: the last cumulative `token_count` / `token_usage_record`.
    case cumulativeCounter
    /// Codex: the sum of counter deltas, used when the last counter value
    /// is not the session's own total — a fork / spawned subagent cut at
    /// `subagent_history_start_ordinal` (its counters continue from the
    /// copied parent history), or a counter that reset mid-session
    /// (`SessionStats.counterResets > 0`, the last value covers only the
    /// latest epoch). The raw last value stays in
    /// `SessionStats.cumulativeTokensIncludingInherited`.
    case ownCounterDeltas
    /// Codex: per-response `token_usage_record.usage`, summed. Newer
    /// rollouts write one record per response next to `token_count`, but
    /// the two counters do not share a basis: `token_count.total_token_usage`
    /// can restart inside a thread (measured after a resume) and can lag
    /// responses it never reported, while `thread_token_usage` keeps
    /// counting. A turn with records is read from them; `token_count`
    /// fills only turns that have none.
    case responseRecords
    /// Claude: per-message `usage`, deduplicated by message + request id.
    case summedMessages
    /// Codex: `threads.tokens_used` in `~/.codex/state_5.sqlite` (total only).
    case codexStateDatabase
    /// Codex: a session cut at its inherited-history ordinal that wrote no
    /// counter of its own. The only total on record (`tokens_used`) includes
    /// the copied parent history, so it is kept in
    /// `cumulativeTokensIncludingInherited` and `totalTokens` stays 0 —
    /// read it as unknown, not as zero.
    case unavailable
    case none
}

public struct SessionModelUsage: Codable, Sendable, Hashable {
    public var model: String
    public var usage: SessionStructure.TokenUsage
    /// `nil` when no price is known for the model (or a tier it ran on).
    public var costUSD: Double?

    public init(model: String, usage: SessionStructure.TokenUsage, costUSD: Double?) {
        self.model = model
        self.usage = usage
        self.costUSD = costUSD
    }
}

public struct SessionStats: Codable, Sendable, Hashable {
    /// Human prompts (`Prompt.humanPromptCount` summed over live turns).
    public var promptCount: Int
    public var turnCount: Int
    /// Every action step: tool calls + commands + MCP + subagent + verdicts.
    public var toolCallCount: Int
    public var commandCount: Int
    public var mcpCallCount: Int
    public var subagentCount: Int
    public var thinkingCount: Int
    public var failedToolCount: Int
    public var injectedBlockCount: Int
    /// Distinct models seen, sorted.
    public var models: [String]
    public var modelUsage: [SessionModelUsage]
    public var totalUsage: SessionStructure.TokenUsage
    /// Canonical token total. Equals `totalUsage.total` unless the only
    /// source was a total-only counter (Codex state database).
    public var totalTokens: Int
    public var usageSource: SessionUsageSource
    /// Codex: the last cumulative counter value as the rollout wrote it —
    /// the same basis as `threads.tokens_used` in `~/.codex/state_5.sqlite`.
    /// Equals `totalTokens` for an ordinary session; for one cut at its
    /// inherited-history ordinal it also counts the parent history the
    /// counter started from, which `totalTokens` leaves out. `nil` when no
    /// counter was read (Claude, a byte-window parse).
    public var cumulativeTokensIncludingInherited: Int?
    /// Codex: how many times the session's own cumulative counter went
    /// backwards. Each reset starts a new epoch; `totalTokens` sums them.
    public var counterResets: Int
    /// Sum of priced model segments; `nil` when no segment had a price.
    public var estimatedCostUSD: Double?
    /// Whether some usage could not be priced (cost is then a lower bound).
    public var hasUnpricedUsage: Bool
    public var startedAt: Date?
    public var endedAt: Date?
    /// `endedAt - startedAt` in milliseconds.
    public var durationMs: Int?
    public var gitBranch: String?
    public var cwd: String?
    public var title: String?
    public var kind: SessionStructureKind
    public var parentID: String?
    public var relation: SessionStructureRelation?
    /// The root of the thread tree when it differs from `parentID` (Codex
    /// `session_meta.session_id`).
    public var rootSessionID: String?
    /// First line (Codex `ordinal`, Claude line index) that belongs to this
    /// session rather than to the parent history it copied.
    public var forkStartOrdinal: Int?
    public var originator: String?
    public var cliVersion: String?
    public var agentNickname: String?
    public var agentRole: String?
    public var guardianAllowCount: Int
    public var guardianDenyCount: Int
    /// Claude only: usage that came from inline sidechain lines (already
    /// included in `totalUsage`).
    public var sidechainUsage: SessionStructure.TokenUsage

    public init(
        promptCount: Int = 0,
        turnCount: Int = 0,
        toolCallCount: Int = 0,
        commandCount: Int = 0,
        mcpCallCount: Int = 0,
        subagentCount: Int = 0,
        thinkingCount: Int = 0,
        failedToolCount: Int = 0,
        injectedBlockCount: Int = 0,
        models: [String] = [],
        modelUsage: [SessionModelUsage] = [],
        totalUsage: SessionStructure.TokenUsage = .zero,
        totalTokens: Int = 0,
        usageSource: SessionUsageSource = .none,
        cumulativeTokensIncludingInherited: Int? = nil,
        counterResets: Int = 0,
        estimatedCostUSD: Double? = nil,
        hasUnpricedUsage: Bool = false,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        durationMs: Int? = nil,
        gitBranch: String? = nil,
        cwd: String? = nil,
        title: String? = nil,
        kind: SessionStructureKind = .interactive,
        parentID: String? = nil,
        relation: SessionStructureRelation? = nil,
        rootSessionID: String? = nil,
        forkStartOrdinal: Int? = nil,
        originator: String? = nil,
        cliVersion: String? = nil,
        agentNickname: String? = nil,
        agentRole: String? = nil,
        guardianAllowCount: Int = 0,
        guardianDenyCount: Int = 0,
        sidechainUsage: SessionStructure.TokenUsage = .zero
    ) {
        self.promptCount = promptCount
        self.turnCount = turnCount
        self.toolCallCount = toolCallCount
        self.commandCount = commandCount
        self.mcpCallCount = mcpCallCount
        self.subagentCount = subagentCount
        self.thinkingCount = thinkingCount
        self.failedToolCount = failedToolCount
        self.injectedBlockCount = injectedBlockCount
        self.models = models
        self.modelUsage = modelUsage
        self.totalUsage = totalUsage
        self.totalTokens = totalTokens
        self.usageSource = usageSource
        self.cumulativeTokensIncludingInherited = cumulativeTokensIncludingInherited
        self.counterResets = counterResets
        self.estimatedCostUSD = estimatedCostUSD
        self.hasUnpricedUsage = hasUnpricedUsage
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMs = durationMs
        self.gitBranch = gitBranch
        self.cwd = cwd
        self.title = title
        self.kind = kind
        self.parentID = parentID
        self.relation = relation
        self.rootSessionID = rootSessionID
        self.forkStartOrdinal = forkStartOrdinal
        self.originator = originator
        self.cliVersion = cliVersion
        self.agentNickname = agentNickname
        self.agentRole = agentRole
        self.guardianAllowCount = guardianAllowCount
        self.guardianDenyCount = guardianDenyCount
        self.sidechainUsage = sidechainUsage
    }
}

// MARK: - Outline

/// The compact per-turn record the sidecar stores (`outline_json`). Numbers,
/// ids, boundaries and a ≤ 120-character prompt preview — never a message
/// body. Everything a turn carries except its steps, prompt text and final
/// answer survives the round trip, so an outline read back from the sidecar
/// reports the same per-turn breakdown as the parse that wrote it.
public struct SessionTurnOutline: Codable, Sendable, Hashable {
    public var index: Int
    public var turnID: String?
    public var startedAt: Date?
    public var endedAt: Date?
    public var promptPreview: String?
    public var origin: SessionStructure.PromptOrigin
    public var additionalHumanMessages: Int
    /// Injected-block counts keyed by `InjectedBlock.rawValue`.
    public var injected: [String: Int]
    /// Every counter, not only the headline ones.
    public var counts: SessionStructure.TurnCounts
    public var byteOffset: Int64
    public var byteEnd: Int64
    public var durationMs: Int?
    public var model: String?
    public var usage: SessionStructure.TokenUsage
    public var status: SessionStructure.TurnStatus
    public var reviewedTurnID: String?

    public var stepCount: Int { counts.steps }
    public var failedCount: Int { counts.failed }
    public var commandCount: Int { counts.commands }

    public init(turn: SessionStructure.Turn) {
        index = turn.index
        turnID = turn.turnID
        startedAt = turn.startedAt
        endedAt = turn.endedAt
        promptPreview = turn.prompt.preview.map { SessionStructureText.preview($0, limit: SessionStructure.Prompt.previewLimit) }
        origin = turn.prompt.origin
        additionalHumanMessages = turn.prompt.additionalHumanMessages
        injected = turn.prompt.injected
        counts = turn.counts
        byteOffset = turn.byteOffset
        byteEnd = turn.byteEnd
        durationMs = turn.durationMs
        model = turn.model
        usage = turn.usage
        status = turn.status
        reviewedTurnID = turn.reviewedTurnID
    }

    /// Rebuild an outline-detail turn (no steps, no text) from the record.
    public var turn: SessionStructure.Turn {
        SessionStructure.Turn(
            index: index,
            turnID: turnID,
            startedAt: startedAt,
            endedAt: endedAt,
            status: status,
            prompt: SessionStructure.Prompt(
                origin: origin,
                preview: promptPreview,
                additionalHumanMessages: additionalHumanMessages,
                injected: injected
            ),
            counts: counts,
            model: model,
            usage: usage,
            durationMs: durationMs,
            byteOffset: byteOffset,
            byteEnd: byteEnd,
            reviewedTurnID: reviewedTurnID
        )
    }
}

extension SessionStructure {
    public var outline: [SessionTurnOutline] { turns.map(SessionTurnOutline.init(turn:)) }

    /// The same structure with steps and text dropped — what the sidecar
    /// can hand back without re-reading the file.
    public var outlineOnly: SessionStructure {
        var copy = self
        copy.detail = .outline
        copy.turns = outline.map(\.turn)
        return copy
    }
}
