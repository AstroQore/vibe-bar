import Foundation

/// Scans local CLI session JSONL logs to compute per-tool cost / token usage
/// across multiple windows (today / 7d / 30d / all-time) plus a per-day history
/// and a weekday × hour heatmap.
///
/// Codex: `~/.codex/sessions/**/*.jsonl` + `~/.codex/archived_sessions/`.
///   We track running `total_token_usage` snapshots and treat consecutive
///   snapshots in the SAME file as a delta sequence so the same session's
///   cumulative tokens aren't double-counted into multiple days.
///
/// Claude: `~/.claude/projects/**/*.jsonl` (also `~/.config/claude/projects`).
///   Each assistant message has `message.usage`; we sum per-message and bucket
///   by message timestamp.
public enum CostUsageScanner {
    /// - Parameter eventSink: Optional receiver for the per-request events
    ///   behind the returned snapshot. One batch is emitted per source file,
    ///   for cache-reused files as well as freshly parsed ones, so a sink
    ///   attached to an empty store backfills from a warm scan cache on its
    ///   first pass. Each event carries the same cost the aggregator used,
    ///   converted once to `Int64` micro-USD (`nil` when unpriceable). When
    ///   the sink is `nil` the scan behaves exactly as before.
    public static func scan(
        tool: ToolType,
        homeDirectory: String = RealHomeDirectory.path,
        now: Date = Date(),
        retentionDays: Int? = nil,
        eventSink: (any CostUsageEventSink)? = nil
    ) async -> CostSnapshot? {
        switch tool {
        case .codex:
            return await scanCodex(homeDirectory: homeDirectory, now: now, retentionDays: retentionDays, eventSink: eventSink)
        case .claude:
            return await scanClaude(homeDirectory: homeDirectory, now: now, retentionDays: retentionDays, eventSink: eventSink)
        case .gemini:
            return await scanGemini(homeDirectory: homeDirectory, now: now, retentionDays: retentionDays, eventSink: eventSink)
        case .grok:
            return await scanGrok(homeDirectory: homeDirectory, now: now, retentionDays: retentionDays, eventSink: eventSink)
        case .antigravity:
            return await scanAntigravity(homeDirectory: homeDirectory, now: now, retentionDays: retentionDays, eventSink: eventSink)
        case .alibaba, .alibabaTokenPlan, .copilot, .zai, .minimax, .kimi, .cursor, .mimo, .iflytek, .tencentHunyuan, .tencentTokenPlan, .volcengine, .volcengineAgentPlan, .baiduQianfan, .openCodeGo, .kilo, .kiro, .ollama, .openRouter, .warp:
            // Misc providers don't expose token-level cost data through
            // any documented public protocol. The cost-history pipeline
            // is gated by `tool.supportsTokenCost` upstream. Returning
            // `nil` here is a defensive belt: anything that does call
            // us by accident gets an empty snapshot, not a crash.
            return nil
        }
    }

    // MARK: - Codex

    private static func scanCodex(
        homeDirectory: String,
        now: Date,
        retentionDays: Int?,
        eventSink: (any CostUsageEventSink)? = nil
    ) async -> CostSnapshot {
        let roots = [
            URL(fileURLWithPath: homeDirectory).appendingPathComponent(".codex/sessions"),
            URL(fileURLWithPath: homeDirectory).appendingPathComponent(".codex/archived_sessions")
        ]
        let files = roots.flatMap { collectJSONL(under: $0) }
        // Codex bills the whole install at one service tier; it isn't
        // stamped on each token event, so resolve it once and apply it
        // to every codex event in this scan (mirrors ccusage).
        let codexFastTier = codexFastServiceTier(homeDirectory: homeDirectory)
        var aggregator = CostAggregator(tool: .codex, now: now)
        var cache = CostUsageScanCache.load(homeDirectory: homeDirectory, tool: .codex, retentionDays: retentionDays)
        let cutoff = retentionCutoff(now: now, retentionDays: retentionDays)

        for file in files {
            let (mtime, size) = fileFingerprint(file)
            if let cached = cache.reusable(for: file.path, mtime: mtime, size: size) {
                let retained = retainedEvents(cached, cutoff: cutoff)
                if retained.count != cached.count {
                    cache.store(retained, for: file.path, mtime: mtime, size: size)
                }
                var priced: [PricedUsageEvent] = []
                priced.reserveCapacity(eventSink == nil ? 0 : retained.count)
                for event in retained {
                    let optionalCost = costUSDIfPriceable(tool: .codex, event: event, codexFastTier: codexFastTier)
                    let cost = optionalCost ?? 0
                    if eventSink != nil {
                        priced.append(PricedUsageEvent(event: event, costUSD: optionalCost))
                    }
                    aggregator.add(at: event.date, model: event.model, input: event.input,
                                   output: event.output, cache: event.cache, costUSD: cost)
                }
                await emit(eventSink, tool: .codex, file: file, mtime: mtime, size: size, events: priced)
                continue
            }

            let (raw, originator) = parseCodexFile(file: file)
            let harness = codexHarness(originator: originator)
            // Delta from one snapshot to the next is what was used in that interval.
            var previous: CodexEvent.Totals? = nil
            var parsed: [CostUsageScanCache.ParsedEvent] = []
            var priced: [PricedUsageEvent] = []
            parsed.reserveCapacity(raw.count)
            for event in raw {
                let delta: CodexEvent.Totals
                if let previous {
                    delta = CodexEvent.Totals(
                        input: max(0, event.totals.input - previous.input),
                        cached: max(0, event.totals.cached - previous.cached),
                        output: max(0, event.totals.output - previous.output)
                    )
                } else {
                    delta = event.totals
                }
                previous = event.totals
                if delta.isEmpty { continue }
                let optionalCost = CostUsagePricing.codexCostUSD(
                    model: event.model,
                    inputTokens: delta.input,
                    cachedInputTokens: delta.cached,
                    outputTokens: delta.output,
                    isFast: codexFastTier
                )
                let cost = optionalCost ?? 0
                let parsedEvent = CostUsageScanCache.ParsedEvent(
                    date: event.date,
                    model: event.model,
                    input: max(0, delta.input - delta.cached),
                    output: delta.output,
                    cache: delta.cached,
                    harness: harness
                )
                guard isRetained(parsedEvent.date, cutoff: cutoff) else { continue }
                parsed.append(parsedEvent)
                if eventSink != nil {
                    priced.append(PricedUsageEvent(event: parsedEvent, costUSD: optionalCost))
                }
                aggregator.add(at: parsedEvent.date, model: parsedEvent.model,
                               input: parsedEvent.input, output: parsedEvent.output,
                               cache: parsedEvent.cache, costUSD: cost)
            }
            cache.store(parsed, for: file.path, mtime: mtime, size: size)
            await emit(eventSink, tool: .codex, file: file, mtime: mtime, size: size, events: priced)
        }
        cache.prune(known: Set(files.map(\.path)))
        cache.save(homeDirectory: homeDirectory, tool: .codex)
        return aggregator.snapshot(jsonlFilesFound: files.count)
    }

    private struct CodexEvent {
        struct Totals {
            let input: Int
            let cached: Int
            let output: Int
            var isEmpty: Bool { input == 0 && cached == 0 && output == 0 }
        }
        let date: Date
        let model: String
        let totals: Totals
    }

    /// Every Codex surface writes into the same `~/.codex/sessions` tree, and
    /// `session_meta.payload.originator` is the only stable thing that tells
    /// them apart — the instructions, tools, turn context, model and sandbox
    /// are identical across all of them.
    ///
    /// Exactly one originator is *not* Codex: `codex_work_desktop`, written by
    /// ChatGPT **Work** mode in the desktop app. Everything else we have seen —
    /// `Codex Desktop` (the desktop app's Codex tab), `codex-tui`,
    /// `codex_cli_rs`, `codex_exec`, `codex_vscode` — is ordinary Codex, so
    /// anything unrecognised, including a missing header, stays on the Codex
    /// harness rather than being invented as ChatGPT Work usage.
    static let chatgptWorkOriginator = "codex_work_desktop"

    static func codexHarness(originator: String?) -> Harness {
        originator == chatgptWorkOriginator ? .chatgptWork : .codex
    }

    /// Returns the file's token events plus its `session_meta` originator.
    /// Both come out of the *same* single pass — the header is the first
    /// line, so reading it costs nothing and keeps the scan O(n).
    private static func parseCodexFile(file: URL) -> ([CodexEvent], String?) {
        var events: [CodexEvent] = []
        var originator: String?
        var currentModel = "gpt-5"
        var runningTotals = CodexEvent.Totals(input: 0, cached: 0, output: 0)
        let didRead = forEachJSONLLine(in: file) { lineData in
            guard !lineData.isEmpty else { return }
            guard lineData.contains(asciiSequence: "token_count") ||
                    lineData.contains(asciiSequence: "model") ||
                    lineData.contains(asciiSequence: "originator") else { return }
            guard let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else { return }

            if originator == nil,
               obj["type"] as? String == "session_meta",
               let payload = obj["payload"] as? [String: Any] {
                originator = normalizedNonEmpty(payload["originator"] as? String)
            }
            if let payload = obj["payload"] as? [String: Any] {
                if let m = payload["model"] as? String { currentModel = m }
                if let info = payload["info"] as? [String: Any],
                   let m = info["model"] as? String ?? info["model_name"] as? String {
                    currentModel = m
                }
            }
            if let m = obj["model"] as? String { currentModel = m }

            guard obj["type"] as? String == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any]
            else { return }
            let totals: CodexEvent.Totals
            if let total = info["total_token_usage"] as? [String: Any] {
                totals = CodexEvent.Totals(
                    input: anyInt(total["input_tokens"]),
                    cached: anyInt(total["cached_input_tokens"] ?? total["cache_read_input_tokens"]),
                    output: anyInt(total["output_tokens"])
                )
                runningTotals = totals
            } else if let last = info["last_token_usage"] as? [String: Any] {
                runningTotals = CodexEvent.Totals(
                    input: runningTotals.input + max(0, anyInt(last["input_tokens"])),
                    cached: runningTotals.cached + max(0, anyInt(last["cached_input_tokens"] ?? last["cache_read_input_tokens"])),
                    output: runningTotals.output + max(0, anyInt(last["output_tokens"]))
                )
                totals = runningTotals
            } else {
                return
            }
            let timestamp = (obj["timestamp"] as? String).flatMap(parseISO) ?? fileMTime(file) ?? Date()
            events.append(CodexEvent(date: timestamp, model: currentModel, totals: totals))
        }
        return didRead ? (events, originator) : ([], originator)
    }

    // MARK: - Claude

    private static func scanClaude(
        homeDirectory: String,
        now: Date,
        retentionDays: Int?,
        eventSink: (any CostUsageEventSink)? = nil
    ) async -> CostSnapshot {
        let projectsRoot = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".claude/projects")
        let altRoot = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".config/claude/projects")
        let coworkRoot = claudeCoworkRoot(homeDirectory: homeDirectory)
        let files = collectJSONL(under: projectsRoot)
            + collectJSONL(under: altRoot)
            + collectClaudeCoworkJSONL(under: coworkRoot)
        var aggregator = CostAggregator(tool: .claude, now: now)
        var cache = CostUsageScanCache.load(homeDirectory: homeDirectory, tool: .claude, retentionDays: retentionDays)
        let cutoff = retentionCutoff(now: now, retentionDays: retentionDays)
        var allEvents: [CostUsageScanCache.ParsedEvent] = []

        for file in files {
            let (mtime, size) = fileFingerprint(file)
            if let cached = cache.reusable(for: file.path, mtime: mtime, size: size) {
                let retained = retainedEvents(cached, cutoff: cutoff)
                if retained.count != cached.count {
                    cache.store(retained, for: file.path, mtime: mtime, size: size)
                }
                allEvents.append(contentsOf: retained)
                await emitClaude(eventSink, file: file, mtime: mtime, size: size, events: retained)
                continue
            }

            let sourceKey = CostUsageScanCache.entryKey(for: file.path)
            let pathRole = claudePathRole(file: file)
            let harness = claudeHarness(file: file)
            var keyedRows: [String: CostUsageScanCache.ParsedEvent] = [:]
            var unkeyedRows: [CostUsageScanCache.ParsedEvent] = []
            let didRead = forEachJSONLLine(in: file) { lineData in
                guard !lineData.isEmpty,
                      lineData.contains(asciiSequence: "assistant"),
                      lineData.contains(asciiSequence: "usage")
                else { return }
                guard let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
                      obj["type"] as? String == "assistant",
                      let message = obj["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any]
                else { return }

                let model = (message["model"] as? String) ?? "claude-sonnet-4-5"
                let input = anyInt(usage["input_tokens"])
                let cacheRead = anyInt(usage["cache_read_input_tokens"])
                let cacheCreation = anyInt(usage["cache_creation_input_tokens"])
                let output = anyInt(usage["output_tokens"])
                if input == 0, cacheRead == 0, cacheCreation == 0, output == 0 { return }
                // Per-message billing tier. Claude Code writes
                // `usage.speed` ("standard"/"fast"); `service_tier` is a
                // fallback. A fast/priority value applies the model's
                // fast-tier multiplier at costing time.
                let serviceTier = (usage["speed"] as? String) ?? (usage["service_tier"] as? String)
                let date = (obj["timestamp"] as? String).flatMap(parseISO) ?? fileMTime(file) ?? Date()
                let messageId = message["id"] as? String
                let requestId = obj["requestId"] as? String
                let sessionId = obj["sessionId"] as? String
                    ?? obj["session_id"] as? String
                    ?? (obj["metadata"] as? [String: Any])?["sessionId"] as? String
                    ?? (message["metadata"] as? [String: Any])?["sessionId"] as? String
                let parsedEvent = CostUsageScanCache.ParsedEvent(
                    date: date,
                    model: model,
                    input: input,
                    output: output,
                    cache: cacheRead + cacheCreation,
                    cacheCreation: cacheCreation,
                    sessionId: sessionId,
                    messageId: messageId,
                    requestId: requestId,
                    isSidechain: anyBool(obj["isSidechain"]),
                    pathRole: pathRole,
                    sourceKey: sourceKey,
                    serviceTier: serviceTier,
                    harness: harness
                )
                guard isRetained(parsedEvent.date, cutoff: cutoff) else { return }
                if let messageId, let requestId {
                    keyedRows["\(messageId)\u{0}\(requestId)"] = parsedEvent
                } else {
                    unkeyedRows.append(parsedEvent)
                }
            }
            guard didRead else {
                cache.store([], for: file.path, mtime: mtime, size: size)
                await emitClaude(eventSink, file: file, mtime: mtime, size: size, events: [])
                continue
            }
            let parsed = keyedRows.keys.sorted().compactMap { keyedRows[$0] } + unkeyedRows
            cache.store(parsed, for: file.path, mtime: mtime, size: size)
            allEvents.append(contentsOf: parsed)
            await emitClaude(eventSink, file: file, mtime: mtime, size: size, events: parsed)
        }
        cache.prune(known: Set(files.map(\.path)))
        cache.save(homeDirectory: homeDirectory, tool: .claude)
        let deduped = deduplicateClaudeEvents(allEvents)
        for event in deduped {
            let cost = costUSD(tool: .claude, event: event)
            aggregator.add(
                at: event.date,
                model: event.model,
                input: event.input,
                output: event.output,
                cache: event.cache,
                costUSD: cost
            )
        }
        return aggregator.snapshot(jsonlFilesFound: files.count)
    }

    // MARK: - Gemini CLI (OpenTelemetry log file)
    //
    // Gemini CLI writes telemetry as **newline-delimited JSON** to
    // `~/.gemini/telemetry.log` when the user opts in via
    // `~/.gemini/settings.json` (`{"telemetry":{"enabled":true,"target":
    // "local","outfile":".gemini/telemetry.log"}}`). Each line is one
    // OpenTelemetry log record. The event we care about is
    // `gemini_cli.api_response` — its attributes carry per-call
    // `input_token_count`, `output_token_count`,
    // `cached_content_token_count`, `model`, `prompt_id`, and a
    // session-wide `session.id`. We aggregate into the same
    // `CostSnapshot` shape Codex / Claude produce.
    //
    // OpenTelemetry SDKs serialise log records in several shapes; we
    // probe `attributes`, `body`, and top-level fallback keys so the
    // scanner survives version drift. When the file isn't there yet
    // (user hasn't enabled telemetry) we return an empty snapshot —
    // the UI will show "no Gemini CLI cost data yet, enable telemetry"
    // copy.

    private static let geminiCLIEventName = "gemini_cli.api_response"
    private static let geminiCLIFallbackBodies: Set<String> = [
        "gemini_cli.api_response",
        "ApiResponse",
        "api_response"
    ]

    private static func scanGemini(
        homeDirectory: String,
        now: Date,
        retentionDays: Int?,
        eventSink: (any CostUsageEventSink)? = nil
    ) async -> CostSnapshot {
        let telemetryCandidates = geminiTelemetryFileCandidates(homeDirectory: homeDirectory)
        let chatCandidates = geminiChatFileCandidates(homeDirectory: homeDirectory)
        let telemetryFiles = telemetryCandidates.filter { FileManager.default.fileExists(atPath: $0.path) }
        let chatFiles = chatCandidates // chat enumerator only returns existing files
        let allFiles = telemetryFiles + chatFiles
        var aggregator = CostAggregator(tool: .gemini, now: now)
        var cache = CostUsageScanCache.load(homeDirectory: homeDirectory, tool: .gemini, retentionDays: retentionDays)
        let cutoff = retentionCutoff(now: now, retentionDays: retentionDays)

        for file in allFiles {
            let (mtime, size) = fileFingerprint(file)
            if let cached = cache.reusable(for: file.path, mtime: mtime, size: size) {
                let retained = retainedEvents(cached, cutoff: cutoff)
                if retained.count != cached.count {
                    cache.store(retained, for: file.path, mtime: mtime, size: size)
                }
                var priced: [PricedUsageEvent] = []
                priced.reserveCapacity(eventSink == nil ? 0 : retained.count)
                for event in retained {
                    let optionalCost = costUSDIfPriceable(tool: .gemini, event: event)
                    if eventSink != nil {
                        priced.append(PricedUsageEvent(event: event, costUSD: optionalCost))
                    }
                    aggregator.add(at: event.date, model: event.model, input: event.input,
                                   output: event.output, cache: event.cache, costUSD: optionalCost ?? 0)
                }
                await emit(eventSink, tool: .gemini, file: file, mtime: mtime, size: size, events: priced)
                continue
            }

            let isChatFile = file.path.contains("/chats/")
            let priced: [PricedUsageEvent]
            let didRead: Bool
            if isChatFile {
                (priced, didRead) = parseGeminiChatFile(file: file, cutoff: cutoff, aggregator: &aggregator)
            } else {
                (priced, didRead) = parseGeminiTelemetryFile(file: file, now: now, cutoff: cutoff, aggregator: &aggregator)
            }
            if didRead {
                cache.store(priced.map(\.event), for: file.path, mtime: mtime, size: size)
                await emit(eventSink, tool: .gemini, file: file, mtime: mtime, size: size, events: priced)
            }
        }
        cache.prune(known: Set(allFiles.map(\.path)))
        cache.save(homeDirectory: homeDirectory, tool: .gemini)
        return aggregator.snapshot(jsonlFilesFound: allFiles.count)
    }

    /// Parse the original Gemini CLI OpenTelemetry telemetry-log
    /// format — `gemini_cli.api_response` events whose attributes
    /// carry per-call token counts. Returns the cached events
    /// (still subject to retention) plus a `didRead` bool the
    /// caller uses to decide whether to update the per-file cache.
    private static func parseGeminiTelemetryFile(
        file: URL,
        now: Date,
        cutoff: Date?,
        aggregator: inout CostAggregator
    ) -> ([PricedUsageEvent], Bool) {
        var parsed: [PricedUsageEvent] = []
        let fileMTimeFallback = fileMTime(file) ?? now
        let didRead = forEachJSONLLine(in: file) { lineData in
            guard !lineData.isEmpty,
                  lineData.contains(asciiSequence: "gemini_cli")
            else { return }
            guard let raw = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else { return }
            guard isGeminiApiResponse(raw) else { return }
            let attributes = geminiAttributes(raw)
            let model = (attributes["model"] as? String)
                ?? (attributes["gen_ai.request.model"] as? String)
                ?? (attributes["gen_ai.response.model"] as? String)
                ?? "gemini-unknown"
            let input = anyInt(attributes["input_token_count"]
                               ?? attributes["gen_ai.usage.input_tokens"]
                               ?? attributes["prompt_token_count"])
            let cached = anyInt(attributes["cached_content_token_count"]
                                ?? attributes["gen_ai.usage.cached_tokens"])
            let output = anyInt(attributes["output_token_count"]
                                ?? attributes["gen_ai.usage.output_tokens"]
                                ?? attributes["candidates_token_count"])
            if input == 0, cached == 0, output == 0 { return }
            let timestamp = geminiTimestamp(raw) ?? fileMTimeFallback
            let promptId = attributes["prompt_id"] as? String
                ?? attributes["gen_ai.prompt_id"] as? String
            let sessionId = attributes["session.id"] as? String
                ?? attributes["session_id"] as? String
            let inputNonCached = max(0, input - cached)
            let parsedEvent = CostUsageScanCache.ParsedEvent(
                date: timestamp,
                model: model,
                input: inputNonCached,
                output: output,
                cache: cached,
                sessionId: sessionId,
                messageId: promptId,
                harness: .geminiCLI
            )
            guard isRetained(parsedEvent.date, cutoff: cutoff) else { return }
            let optionalCost = CostUsagePricing.geminiCostUSD(
                model: model,
                inputTokens: input,
                cacheReadInputTokens: cached,
                outputTokens: output
            )
            parsed.append(PricedUsageEvent(event: parsedEvent, costUSD: optionalCost))
            aggregator.add(at: parsedEvent.date, model: parsedEvent.model,
                           input: parsedEvent.input, output: parsedEvent.output,
                           cache: parsedEvent.cache, costUSD: optionalCost ?? 0)
        }
        return (parsed, didRead)
    }

    /// Parse a Gemini CLI chat-history JSONL file from
    /// `~/.gemini/tmp/<project>/chats/session-*.jsonl`. Each line is
    /// one chat message; the `type: "gemini"` records carry a
    /// `tokens` object with `input` / `output` / `cached` / `thoughts`
    /// / `tool` / `total`. This is the format AQ's installation uses
    /// instead of the OpenTelemetry log; once a project enables
    /// telemetry the OTLP path takes over again.
    private static func parseGeminiChatFile(
        file: URL,
        cutoff: Date?,
        aggregator: inout CostAggregator
    ) -> ([PricedUsageEvent], Bool) {
        var parsed: [PricedUsageEvent] = []
        var sessionIdFromHeader: String? = nil
        let didRead = forEachJSONLLine(in: file) { lineData in
            guard !lineData.isEmpty,
                  lineData.contains(asciiSequence: "\"tokens\"")
                    || lineData.contains(asciiSequence: "\"sessionId\"")
            else { return }
            guard let raw = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else { return }
            if let sid = raw["sessionId"] as? String, sessionIdFromHeader == nil {
                sessionIdFromHeader = sid
            }
            guard raw["type"] as? String == "gemini",
                  let tokens = raw["tokens"] as? [String: Any]
            else { return }
            let model = (raw["model"] as? String) ?? "gemini-unknown"
            let inputTotal = anyInt(tokens["input"])
            let cached = anyInt(tokens["cached"])
            let output = anyInt(tokens["output"])
            let thoughts = anyInt(tokens["thoughts"])
            let tool = anyInt(tokens["tool"])
            if inputTotal == 0, cached == 0, output == 0, thoughts == 0, tool == 0 { return }
            let timestamp = (raw["timestamp"] as? String).flatMap(parseISO)
                ?? fileMTime(file) ?? Date()
            let inputNonCached = max(0, inputTotal - cached)
            // Gemini bills reasoning ("thoughts") and tool tokens at
            // output rates, so fold them into output for cost — matches
            // the CLI's own usage page totals.
            let outputBilled = output + thoughts + tool
            let parsedEvent = CostUsageScanCache.ParsedEvent(
                date: timestamp,
                model: model,
                input: inputNonCached,
                output: outputBilled,
                cache: cached,
                sessionId: sessionIdFromHeader,
                messageId: raw["id"] as? String,
                harness: .geminiCLI
            )
            guard isRetained(parsedEvent.date, cutoff: cutoff) else { return }
            let optionalCost = CostUsagePricing.geminiCostUSD(
                model: model,
                inputTokens: inputTotal,
                cacheReadInputTokens: cached,
                outputTokens: outputBilled
            )
            parsed.append(PricedUsageEvent(event: parsedEvent, costUSD: optionalCost))
            aggregator.add(at: parsedEvent.date, model: parsedEvent.model,
                           input: parsedEvent.input, output: parsedEvent.output,
                           cache: parsedEvent.cache, costUSD: optionalCost ?? 0)
        }
        return (parsed, didRead)
    }

    /// Gather all `~/.gemini/tmp/<project>/chats/session-*.jsonl`
    /// files. Each chat file is one conversation; an installation
    /// can have hundreds across multiple project hashes.
    private static func geminiChatFileCandidates(homeDirectory: String) -> [URL] {
        let tmp = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".gemini/tmp")
        guard let projects = try? FileManager.default.contentsOfDirectory(atPath: tmp.path) else {
            return []
        }
        var out: [URL] = []
        for project in projects {
            let chats = tmp.appendingPathComponent(project).appendingPathComponent("chats")
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: chats,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in entries
            where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("session-")
            {
                let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                if values?.isSymbolicLink == true { continue }
                if values?.isRegularFile == false { continue }
                out.append(url)
            }
        }
        return out
    }

    private static func geminiTelemetryFileCandidates(homeDirectory: String) -> [URL] {
        // Default outfile is `.gemini/telemetry.log` (configurable in
        // settings.json). The OTLP-via-local-collector setup also drops
        // a per-project `tmp/<projectHash>/otel/collector-gcp.log`.
        let root = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".gemini")
        var out: [URL] = [root.appendingPathComponent("telemetry.log")]
        let tmp = root.appendingPathComponent("tmp")
        if let projects = try? FileManager.default.contentsOfDirectory(atPath: tmp.path) {
            for project in projects {
                let otel = tmp.appendingPathComponent(project).appendingPathComponent("otel")
                let log = otel.appendingPathComponent("collector-gcp.log")
                out.append(log)
            }
        }
        return out
    }

    private static func isGeminiApiResponse(_ raw: [String: Any]) -> Bool {
        if let name = raw["name"] as? String, name == geminiCLIEventName { return true }
        if let eventName = raw["event_name"] as? String, eventName == geminiCLIEventName { return true }
        if let body = raw["body"] as? String, geminiCLIFallbackBodies.contains(body) { return true }
        if let body = raw["body"] as? [String: Any] {
            if let n = body["name"] as? String, n == geminiCLIEventName { return true }
            if let n = body["event_name"] as? String, n == geminiCLIEventName { return true }
        }
        // OTLP-style: `attributes` may carry an `event.name` key.
        let attrs = geminiAttributes(raw)
        if let n = attrs["event.name"] as? String, n == geminiCLIEventName { return true }
        if let n = attrs["event_name"] as? String, n == geminiCLIEventName { return true }
        return false
    }

    /// Flatten OpenTelemetry attribute representations into a plain
    /// `[String: Any]` dictionary. OTel attributes may be a flat object
    /// (`{"key":value}`) or an OTLP-style array
    /// (`[{"key":"foo","value":{"intValue":42}}]`).
    private static func geminiAttributes(_ raw: [String: Any]) -> [String: Any] {
        if let attrs = raw["attributes"] as? [String: Any] { return attrs }
        if let array = raw["attributes"] as? [[String: Any]] {
            var out: [String: Any] = [:]
            for entry in array {
                guard let key = entry["key"] as? String else { continue }
                if let v = entry["value"] as? [String: Any] {
                    if let i = v["intValue"] as? Int { out[key] = i }
                    else if let s = v["intValue"] as? String, let i = Int(s) { out[key] = i }
                    else if let d = v["doubleValue"] as? Double { out[key] = d }
                    else if let s = v["stringValue"] as? String { out[key] = s }
                    else if let b = v["boolValue"] as? Bool { out[key] = b }
                } else if let v = entry["value"] {
                    out[key] = v
                }
            }
            return out
        }
        // Some SDKs embed flat top-level attribute keys; fall back
        // to the raw envelope so callers see `input_token_count`
        // even if the writer didn't put them under `attributes`.
        return raw
    }

    private static func geminiTimestamp(_ raw: [String: Any]) -> Date? {
        if let s = raw["timestamp"] as? String, let d = parseISO(s) { return d }
        if let s = raw["time"] as? String, let d = parseISO(s) { return d }
        if let n = raw["observedTimeUnixNano"] as? Int {
            return Date(timeIntervalSince1970: TimeInterval(n) / 1_000_000_000)
        }
        if let n = raw["timeUnixNano"] as? Int {
            return Date(timeIntervalSince1970: TimeInterval(n) / 1_000_000_000)
        }
        if let s = raw["observedTimeUnixNano"] as? String, let n = Int(s) {
            return Date(timeIntervalSince1970: TimeInterval(n) / 1_000_000_000)
        }
        return nil
    }

    // MARK: - Grok (per-session updates.jsonl)
    //
    // Grok CLI stores each session as a directory under
    // `~/.grok/sessions/<urlEncodedCwd>/<sessionUUID>/` and writes
    // three JSONL streams (chat_history, events, updates). Per-call
    // token counts are not exposed — what we get is a cumulative
    // `_meta.totalTokens` on every `updates.jsonl` record, paired
    // with an `_meta.agentTimestampMs`. Per-turn deltas of that
    // running total tell us how many tokens the turn cost; the
    // first row's value is the floor.
    //
    // We split each delta 70 / 30 between input and output before
    // costing — Grok's pricing tables charge input and output at
    // different rates and a session-total figure can't be billed
    // precisely without the split. 70 / 30 is the rough chat-assistant
    // average and lines up with how Grok's own dashboard summarises
    // sessions.

    private static func scanGrok(
        homeDirectory: String,
        now: Date,
        retentionDays: Int?,
        eventSink: (any CostUsageEventSink)? = nil
    ) async -> CostSnapshot {
        let root = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".grok/sessions")
        let files = collectGrokUpdatesFiles(under: root)
        var aggregator = CostAggregator(tool: .grok, now: now)
        var cache = CostUsageScanCache.load(homeDirectory: homeDirectory, tool: .grok, retentionDays: retentionDays)
        let cutoff = retentionCutoff(now: now, retentionDays: retentionDays)

        for file in files {
            let (mtime, size) = grokFingerprint(file)
            if let cached = cache.reusable(for: file.path, mtime: mtime, size: size) {
                let retained = retainedEvents(cached, cutoff: cutoff)
                if retained.count != cached.count {
                    cache.store(retained, for: file.path, mtime: mtime, size: size)
                }
                var priced: [PricedUsageEvent] = []
                priced.reserveCapacity(eventSink == nil ? 0 : retained.count)
                for event in retained {
                    let optionalCost = costUSDIfPriceable(tool: .grok, event: event)
                    if eventSink != nil {
                        priced.append(PricedUsageEvent(event: event, costUSD: optionalCost))
                    }
                    aggregator.add(at: event.date, model: event.model, input: event.input,
                                   output: event.output, cache: event.cache, costUSD: optionalCost ?? 0)
                }
                await emit(eventSink, tool: .grok, file: file, mtime: mtime, size: size, events: priced)
                continue
            }

            let raw = parseGrokUpdatesFile(file: file)
            var parsed: [CostUsageScanCache.ParsedEvent] = []
            var priced: [PricedUsageEvent] = []
            parsed.reserveCapacity(raw.count)
            var previousTotal: Int? = nil
            for snapshot in raw {
                let delta: Int
                if let previousTotal {
                    delta = max(0, snapshot.totalTokens - previousTotal)
                } else {
                    delta = max(0, snapshot.totalTokens)
                }
                previousTotal = snapshot.totalTokens
                guard delta > 0 else { continue }
                let inputTokens = Int((Double(delta) * 0.7).rounded())
                let outputTokens = max(0, delta - inputTokens)
                let parsedEvent = CostUsageScanCache.ParsedEvent(
                    date: snapshot.date,
                    model: snapshot.model,
                    input: inputTokens,
                    output: outputTokens,
                    cache: 0,
                    sessionId: snapshot.sessionId,
                    harness: .grokBuild
                )
                guard isRetained(parsedEvent.date, cutoff: cutoff) else { continue }
                parsed.append(parsedEvent)
                let optionalCost = costUSDIfPriceable(tool: .grok, event: parsedEvent)
                if eventSink != nil {
                    priced.append(PricedUsageEvent(event: parsedEvent, costUSD: optionalCost))
                }
                aggregator.add(at: parsedEvent.date, model: parsedEvent.model,
                               input: parsedEvent.input, output: parsedEvent.output,
                               cache: parsedEvent.cache, costUSD: optionalCost ?? 0)
            }
            cache.store(parsed, for: file.path, mtime: mtime, size: size)
            await emit(eventSink, tool: .grok, file: file, mtime: mtime, size: size, events: priced)
        }
        cache.prune(known: Set(files.map(\.path)))
        cache.save(homeDirectory: homeDirectory, tool: .grok)
        return aggregator.snapshot(jsonlFilesFound: files.count)
    }

    private struct GrokSnapshot {
        let date: Date
        let model: String
        let totalTokens: Int
        let sessionId: String?
    }

    private struct GrokModelChange {
        let date: Date
        let model: String
    }

    private static func collectGrokUpdatesFiles(under root: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator
        where url.lastPathComponent == "updates.jsonl"
            || url.lastPathComponent == "events.jsonl"
        {
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isRegularFile == false { continue }
            // Prefer updates.jsonl when both exist for the same session.
            if url.lastPathComponent == "events.jsonl" {
                let sibling = url.deletingLastPathComponent()
                    .appendingPathComponent("updates.jsonl")
                if FileManager.default.fileExists(atPath: sibling.path) { continue }
            }
            out.append(url)
        }
        return out
    }

    private static func parseGrokUpdatesFile(file: URL) -> [GrokSnapshot] {
        var events: [GrokSnapshot] = []
        let sessionDirectory = file.deletingLastPathComponent()
        let fallbackSessionId = sessionDirectory.lastPathComponent
        let modelTimeline = grokModelTimeline(in: sessionDirectory)
        let fallbackModel = grokSessionModel(in: sessionDirectory) ?? "grok-build"
        let didRead = forEachJSONLLine(in: file) { lineData in
            guard !lineData.isEmpty,
                  lineData.contains(asciiSequence: "totalTokens")
            else { return }
            guard let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else { return }
            let params = obj["params"] as? [String: Any]
            let meta = (obj["_meta"] as? [String: Any])
                ?? (params?["_meta"] as? [String: Any])
            guard let meta else { return }
            let total = anyInt(meta["totalTokens"])
            guard total >= 0 else { return }
            let timestamp: Date
            if let ms = meta["agentTimestampMs"] as? Double {
                timestamp = Date(timeIntervalSince1970: ms / 1000)
            } else if let ms = meta["agentTimestampMs"] as? Int {
                timestamp = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
            } else if let s = meta["agentTimestampMs"] as? String, let ms = Double(s) {
                timestamp = Date(timeIntervalSince1970: ms / 1000)
            } else if let iso = obj["timestamp"] as? String, let d = parseISO(iso) {
                timestamp = d
            } else {
                timestamp = fileMTime(file) ?? Date()
            }
            let sessionId = firstNonEmptyString(
                params?["sessionId"],
                obj["sessionId"],
                meta["sessionId"]
            ) ?? fallbackSessionId
            let model = grokModel(
                at: timestamp,
                timeline: modelTimeline,
                fallback: firstNonEmptyString(
                    meta["model_id"],
                    meta["modelId"],
                    obj["model_id"],
                    obj["modelId"]
                ) ?? fallbackModel
            )
            events.append(GrokSnapshot(
                date: timestamp,
                model: model,
                totalTokens: total,
                sessionId: sessionId
            ))
        }
        // Stable order: sessions written by Grok CLI are append-only but we
        // still sort by timestamp to absorb out-of-order writes.
        return didRead ? events.sorted { $0.date < $1.date } : []
    }

    private static func grokFingerprint(_ file: URL) -> (Date, Int64) {
        let sessionDirectory = file.deletingLastPathComponent()
        let siblings = [
            file,
            sessionDirectory.appendingPathComponent("events.jsonl"),
            sessionDirectory.appendingPathComponent("summary.json"),
            sessionDirectory.appendingPathComponent("signals.json")
        ]
        var latest = Date.distantPast
        var totalSize: Int64 = 0
        var seen: Set<String> = []
        for sibling in siblings where !seen.contains(sibling.path) {
            seen.insert(sibling.path)
            guard FileManager.default.fileExists(atPath: sibling.path) else { continue }
            let (mtime, size) = fileFingerprint(sibling)
            if mtime > latest { latest = mtime }
            totalSize += size
        }
        return (latest, totalSize)
    }

    private static func grokModelTimeline(in sessionDirectory: URL) -> [GrokModelChange] {
        let eventsFile = sessionDirectory.appendingPathComponent("events.jsonl")
        guard FileManager.default.fileExists(atPath: eventsFile.path) else { return [] }
        var changes: [GrokModelChange] = []
        _ = forEachJSONLLine(in: eventsFile) { lineData in
            guard !lineData.isEmpty,
                  lineData.contains(asciiSequence: "model")
            else { return }
            guard let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
                  let model = firstNonEmptyString(
                    obj["model_id"],
                    obj["modelId"],
                    obj["current_model_id"],
                    obj["currentModelId"]
                  )
            else { return }
            guard let date = firstDate(from: obj["ts"], obj["timestamp"], obj["createdAt"]) else {
                return
            }
            changes.append(GrokModelChange(date: date, model: model))
        }
        return changes.sorted { $0.date < $1.date }
    }

    private static func grokSessionModel(in sessionDirectory: URL) -> String? {
        if let model = grokModelFromJSON(
            sessionDirectory.appendingPathComponent("summary.json"),
            keys: ["current_model_id", "currentModelId", "model_id", "modelId"]
        ) {
            return model
        }
        if let model = grokModelFromJSON(
            sessionDirectory.appendingPathComponent("signals.json"),
            keys: ["primaryModelId", "primary_model_id", "current_model_id", "currentModelId"]
        ) {
            return model
        }
        if let model = grokModelFromJSONArray(
            sessionDirectory.appendingPathComponent("signals.json"),
            key: "modelsUsed"
        ) {
            return model
        }
        return grokModelTimeline(in: sessionDirectory).last?.model
    }

    private static func grokModelFromJSON(_ file: URL, keys: [String]) -> String? {
        guard let data = try? Data(contentsOf: file),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        for key in keys {
            if let value = firstNonEmptyString(obj[key]) {
                return value
            }
        }
        return nil
    }

    private static func grokModelFromJSONArray(_ file: URL, key: String) -> String? {
        guard let data = try? Data(contentsOf: file),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let values = obj[key] as? [Any]
        else { return nil }
        for value in values {
            if let model = firstNonEmptyString(value) {
                return model
            }
        }
        return nil
    }

    private static func grokModel(
        at date: Date,
        timeline: [GrokModelChange],
        fallback: String
    ) -> String {
        guard !timeline.isEmpty else { return fallback }
        var current: String?
        for change in timeline {
            if change.date <= date {
                current = change.model
            } else {
                break
            }
        }
        return current ?? timeline.first?.model ?? fallback
    }

    // MARK: - AntiGravity (per-trajectory SQLite + protobuf blobs / live RPC)
    //
    // The AntiGravity IDE / CLI write one conversation file per cascade
    // under `~/.gemini/antigravity{,-cli,-ide}/conversations/<UUID>.{db,pb}`.
    //
    // `.db` is a SQLite store whose `gen_metadata.data` BLOB is a
    // protobuf message we decode offline with a raw varint scanner
    // (`AntigravitySessionReader`, no SwiftProtobuf dependency). Per-row
    // token fields under path `1.4`:
    //   - field 1: constant system-prompt size (cached after turn 1)
    //   - field 2: non-cached input tokens this turn
    //   - field 3: output tokens this turn
    //   - field 5: cumulative cache-read pool size
    //   - field 9: reasoning / thinking tokens (counted as output)
    //   - field 10: tool tokens (counted as output)
    // Model id lives at path `1.19`, timestamp at `1.9.4` (sec + nanos).
    //
    // `.pb` is an encrypted / opaque container we can't decode offline
    // (neither can codeburn). For those cascades we fall back to the
    // running language server's `GetCascadeTrajectoryGeneratorMetadata`
    // RPC (`AntigravityCascadeUsageFetcher`) and cache the result so it
    // survives Antigravity being closed. `.db` is always preferred when
    // it yields turns — it's authoritative and carries cache tokens the
    // RPC doesn't expose.

    /// Conversation roots scanned for AntiGravity usage. All three may
    /// coexist on one machine (IDE, CLI, and the legacy `-ide` layout).
    private static let antigravityConversationDirs = [
        ".gemini/antigravity/conversations",
        ".gemini/antigravity-cli/conversations",
        ".gemini/antigravity-ide/conversations"
    ]
    /// v2 reads the precise field-21 model label (or field-20
    /// `model_enum`) instead of grouping every routed field-19 alias such as
    /// `gemini-default`. The scan cache keeps this independent of its global
    /// schema so only `.db` events are reparsed once; `.pb` RPC events survive.
    private static let antigravityDBParserVersion = 2

    private static func scanAntigravity(
        homeDirectory: String,
        now: Date,
        retentionDays: Int?,
        eventSink: (any CostUsageEventSink)? = nil
    ) async -> CostSnapshot {
        let roots = antigravityConversationDirs.map {
            URL(fileURLWithPath: homeDirectory).appendingPathComponent($0)
        }
        let cascades = collectAntigravityCascades(under: roots)
        var aggregator = CostAggregator(tool: .antigravity, now: now)
        var cache = CostUsageScanCache.load(homeDirectory: homeDirectory, tool: .antigravity, retentionDays: retentionDays)
        let cutoff = retentionCutoff(now: now, retentionDays: retentionDays)
        let shouldReparseDatabases =
            cache.antigravityDBParserVersion != antigravityDBParserVersion
        // Resolve placeholder model ids (e.g. MODEL_PLACEHOLDER_M132) to
        // real names + rates using labels learned from GetUserStatus.
        let labels = AntigravityModelLabelStore.load(homeDirectory: homeDirectory)

        // The language server is probed lazily — only if a `.pb`-only
        // cascade actually needs an RPC, and at most once per scan.
        let lsClient = AntigravityLanguageServerClient()
        var endpoints: [AntigravityLanguageServerClient.Endpoint]?
        var serverUnavailable = false

        var knownPaths: Set<String> = []
        var fileCount = 0
        var completedRequiredDatabaseReparses = true

        for cascade in cascades {
            // 1. Prefer the offline `.db` decode.
            var handledByDB = false
            for dbFile in cascade.dbFiles {
                fileCount += 1
                knownPaths.insert(dbFile.path)
                let (mtime, size) = fileFingerprint(dbFile)
                let cached = cache.reusable(for: dbFile.path, mtime: mtime, size: size)
                if let cached, !shouldReparseDatabases {
                    let retained = retainedEvents(cached, cutoff: cutoff)
                    if retained.count != cached.count {
                        cache.store(retained, for: dbFile.path, mtime: mtime, size: size)
                    }
                    let priced = aggregateAntigravity(
                        retained, labels: labels, into: &aggregator, collecting: eventSink != nil
                    )
                    await emit(eventSink, tool: .antigravity, file: dbFile, mtime: mtime, size: size, events: priced)
                    if !cached.isEmpty { handledByDB = true }
                    continue
                }
                let readResult = AntigravitySessionReader.readGenMetadataResult(at: dbFile)
                if case let .success(turns) = readResult, !turns.isEmpty {
                    let parsed = antigravityEvents(fromDB: turns, sessionId: cascade.id, cutoff: cutoff)
                    cache.store(parsed, for: dbFile.path, mtime: mtime, size: size)
                    let priced = aggregateAntigravity(
                        parsed, labels: labels, into: &aggregator, collecting: eventSink != nil
                    )
                    await emit(eventSink, tool: .antigravity, file: dbFile, mtime: mtime, size: size, events: priced)
                    handledByDB = true
                    continue
                }
                if case .failure = readResult {
                    if shouldReparseDatabases {
                        completedRequiredDatabaseReparses = false
                    }
                    // A parser migration must never erase a previously
                    // readable conversation if SQLite is temporarily locked
                    // or malformed. Keep the old parser version so the next
                    // scan retries this database.
                    if let cached {
                        let retained = retainedEvents(cached, cutoff: cutoff)
                        let priced = aggregateAntigravity(
                            retained, labels: labels, into: &aggregator, collecting: eventSink != nil
                        )
                        // Stale fingerprint: the cached rows did not come
                        // from the file as it exists right now, so record
                        // them under the sentinel size rather than blessing
                        // the current fingerprint as ingested.
                        await emit(
                            eventSink, tool: .antigravity, file: dbFile, mtime: mtime,
                            size: UsageEventFileBatch.staleFallbackSize, events: priced
                        )
                        if !cached.isEmpty { handledByDB = true }
                    }
                    continue
                }
                // A parser migration must never erase a previously readable
                // conversation. A successful empty decode is authoritative,
                // so cache it and allow a `.pb` sibling to provide usage.
                cache.store([], for: dbFile.path, mtime: mtime, size: size)
                await emit(eventSink, tool: .antigravity, file: dbFile, mtime: mtime, size: size, events: [])
            }
            if handledByDB { continue }

            // 2. `.pb`-only (or empty `.db`): live-RPC fallback, cached
            //    so it persists across Antigravity restarts.
            for pbFile in cascade.pbFiles {
                fileCount += 1
                knownPaths.insert(pbFile.path)
                let (mtime, size) = fileFingerprint(pbFile)
                if let cached = cache.reusable(for: pbFile.path, mtime: mtime, size: size) {
                    let retained = retainedEvents(cached, cutoff: cutoff)
                    if retained.count != cached.count {
                        cache.store(retained, for: pbFile.path, mtime: mtime, size: size)
                    }
                    let priced = aggregateAntigravity(
                        retained, labels: labels, into: &aggregator, collecting: eventSink != nil
                    )
                    await emit(eventSink, tool: .antigravity, file: pbFile, mtime: mtime, size: size, events: priced)
                    continue
                }
                if endpoints == nil && !serverUnavailable {
                    do { endpoints = try await lsClient.connectedEndpoints() }
                    catch { serverUnavailable = true }
                }
                if let endpoints, !serverUnavailable,
                   let turns = try? await AntigravityCascadeUsageFetcher.fetchTurns(
                       cascadeId: cascade.id, client: lsClient, endpoints: endpoints
                   ) {
                    let parsed = antigravityEvents(
                        fromRPC: turns,
                        sessionId: cascade.id,
                        fallbackDate: fileMTime(pbFile) ?? now,
                        cutoff: cutoff
                    )
                    cache.store(parsed, for: pbFile.path, mtime: mtime, size: size)
                    let priced = aggregateAntigravity(
                        parsed, labels: labels, into: &aggregator, collecting: eventSink != nil
                    )
                    await emit(eventSink, tool: .antigravity, file: pbFile, mtime: mtime, size: size, events: priced)
                    continue
                }
                // 3. RPC unavailable / failed → reuse the last good fetch
                //    (ignoring the fingerprint) so usage doesn't vanish
                //    while Antigravity is closed.
                if let stale = cache.lastKnownEvents(for: pbFile.path) {
                    let priced = aggregateAntigravity(
                        retainedEvents(stale, cutoff: cutoff), labels: labels,
                        into: &aggregator, collecting: eventSink != nil
                    )
                    // Sentinel size: these rows predate the file's current
                    // fingerprint, so the next successful RPC must still be
                    // allowed to ingest.
                    await emit(
                        eventSink, tool: .antigravity, file: pbFile, mtime: mtime,
                        size: UsageEventFileBatch.staleFallbackSize, events: priced
                    )
                }
            }
        }
        cache.prune(known: knownPaths)
        if !shouldReparseDatabases || completedRequiredDatabaseReparses {
            cache.antigravityDBParserVersion = antigravityDBParserVersion
        }
        cache.save(homeDirectory: homeDirectory, tool: .antigravity)
        return aggregator.snapshot(jsonlFilesFound: fileCount)
    }

    /// One cascade (conversation), grouping the `.db` and `.pb` files
    /// that share a `<UUID>` filename across the AntiGravity roots.
    private struct AntigravityCascade {
        let id: String
        var dbFiles: [URL]
        var pbFiles: [URL]
    }

    private static func collectAntigravityCascades(under roots: [URL]) -> [AntigravityCascade] {
        var byID: [String: AntigravityCascade] = [:]
        var order: [String] = []
        for root in roots {
            for file in collectAntigravityConversationFiles(under: root) {
                let id = file.deletingPathExtension().lastPathComponent
                if byID[id] == nil {
                    byID[id] = AntigravityCascade(id: id, dbFiles: [], pbFiles: [])
                    order.append(id)
                }
                if file.pathExtension == "db" {
                    byID[id]?.dbFiles.append(file)
                } else {
                    byID[id]?.pbFiles.append(file)
                }
            }
        }
        return order.compactMap { byID[$0] }
    }

    private static func collectAntigravityConversationFiles(under root: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { url in
            guard url.pathExtension == "db" || url.pathExtension == "pb" else { return false }
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if values?.isSymbolicLink == true { return false }
            if values?.isRegularFile == false { return false }
            return true
        }
    }

    /// Convert decoded `.db` turns into cache events, resolving the
    /// cumulative cache-read pool into per-turn cache-read /
    /// cache-creation splits.
    private static func antigravityEvents(
        fromDB turns: [AntigravitySessionReader.Turn],
        sessionId: String,
        cutoff: Date?
    ) -> [CostUsageScanCache.ParsedEvent] {
        var parsed: [CostUsageScanCache.ParsedEvent] = []
        parsed.reserveCapacity(turns.count)
        var previousCacheCumulative = 0
        for turn in turns {
            // `cumulativeCacheReadTokens` is a running total across the
            // conversation, so this turn's cache read is its increment.
            // Storing the running total (or the prior cumulative) per turn
            // re-counts every earlier turn's reads, ballooning a long
            // conversation's tokens and cost quadratically. The `.db`
            // exposes cache *reads* only — there's no cache-creation field —
            // so creation stays nil. Deltas telescope back to the final
            // cumulative, i.e. the conversation's true cache-read total.
            let cacheReadThisTurn = max(0, turn.cumulativeCacheReadTokens - previousCacheCumulative)
            previousCacheCumulative = turn.cumulativeCacheReadTokens
            let input = turn.inputTokens
            // Reasoning + tool tokens are billed at output rates by
            // Claude / Gemini, so fold them into output here.
            let output = turn.outputTokens + turn.thoughtsTokens + turn.toolTokens
            guard input > 0 || output > 0 || cacheReadThisTurn > 0 else { continue }
            let model = normalizedNonEmpty(turn.model) ?? "antigravity-default"
            let fallback = normalizedNonEmpty(turn.routedModel)
                .flatMap { $0 == model ? nil : $0 }
            let event = CostUsageScanCache.ParsedEvent(
                date: turn.date,
                model: model,
                modelFallback: fallback,
                input: input,
                output: output,
                cache: cacheReadThisTurn,
                cacheCreation: nil,
                sessionId: sessionId,
                messageId: turn.requestId,
                harness: .antigravity
            )
            guard isRetained(event.date, cutoff: cutoff) else { continue }
            parsed.append(event)
        }
        return parsed
    }

    /// Convert RPC-fetched turns into cache events. The RPC exposes no
    /// cache tokens (`cache = 0`) and already folds thinking into
    /// `output`. A turn with no timestamp falls back to the `.pb` file's
    /// mtime so it still lands on a real day.
    private static func antigravityEvents(
        fromRPC turns: [AntigravityCascadeUsageFetcher.Turn],
        sessionId: String,
        fallbackDate: Date,
        cutoff: Date?
    ) -> [CostUsageScanCache.ParsedEvent] {
        var parsed: [CostUsageScanCache.ParsedEvent] = []
        parsed.reserveCapacity(turns.count)
        for turn in turns {
            guard turn.input > 0 || turn.output > 0 else { continue }
            let model = normalizedNonEmpty(turn.model) ?? "antigravity-default"
            let event = CostUsageScanCache.ParsedEvent(
                date: turn.date ?? fallbackDate,
                model: model,
                input: turn.input,
                output: turn.output,
                cache: 0,
                cacheCreation: nil,
                sessionId: sessionId,
                messageId: turn.responseId,
                harness: .antigravity
            )
            guard isRetained(event.date, cutoff: cutoff) else { continue }
            parsed.append(event)
        }
        return parsed
    }

    /// Resolve each event's model label, price it, and fold it into the
    /// aggregator. Returns the resolved + priced events when `collecting`
    /// is set so the scan can hand the same rows — same model name, same
    /// cost — to an event sink without re-deriving either.
    @discardableResult
    private static func aggregateAntigravity(
        _ events: [CostUsageScanCache.ParsedEvent],
        labels: AntigravityModelLabelStore,
        into aggregator: inout CostAggregator,
        collecting: Bool = false
    ) -> [PricedUsageEvent] {
        var priced: [PricedUsageEvent] = []
        priced.reserveCapacity(collecting ? events.count : 0)
        for event in events {
            // Resolve the raw model id to its real label (when known),
            // then price + group under that name. A placeholder id
            // normalizes to `antigravity-default` (Sonnet rate); the
            // resolved label (e.g. "Gemini 3.5 Flash") normalizes to the
            // correct — usually much cheaper — rate.
            let learnedName = labels.resolve(event.model)
            let name = learnedName == event.model
                ? (normalizedNonEmpty(event.modelFallback) ?? learnedName)
                : learnedName
            let resolved = name == event.model ? event : CostUsageScanCache.ParsedEvent(
                date: event.date,
                model: name,
                modelFallback: event.modelFallback,
                input: event.input,
                output: event.output,
                cache: event.cache,
                cacheCreation: event.cacheCreation,
                sessionId: event.sessionId,
                messageId: event.messageId,
                harness: event.harness ?? .antigravity
            )
            let optionalCost = costUSDIfPriceable(tool: .antigravity, event: resolved)
            if collecting {
                priced.append(PricedUsageEvent(event: resolved, costUSD: optionalCost))
            }
            aggregator.add(at: resolved.date, model: resolved.model, input: resolved.input,
                           output: resolved.output, cache: resolved.cache, costUSD: optionalCost ?? 0)
        }
        return priced
    }

    private static func retentionCutoff(now: Date, retentionDays: Int?) -> Date? {
        guard let retentionDays else { return nil }
        let normalized = CostDataSettings.normalizedRetentionDays(retentionDays)
        guard normalized > 0 else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(normalized - 1), to: today)
    }

    private static func isRetained(_ date: Date, cutoff: Date?) -> Bool {
        guard let cutoff else { return true }
        return date >= cutoff
    }

    private static func retainedEvents(
        _ events: [CostUsageScanCache.ParsedEvent],
        cutoff: Date?
    ) -> [CostUsageScanCache.ParsedEvent] {
        guard let cutoff else { return events }
        return events.filter { $0.date >= cutoff }
    }

    /// Whether this Codex install is configured for the "fast" /
    /// "priority" service tier. Codex doesn't stamp the tier on each
    /// token event, so — like ccusage — we read it once from
    /// `~/.codex/config.toml` and apply it to every codex event in the
    /// scan. The flat scan for any `service_tier = "fast" | "priority"`
    /// line mirrors Codex's own precedence-free reading of the key.
    static func codexFastServiceTier(homeDirectory: String) -> Bool {
        let url = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".codex/config.toml")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return false }
        for rawLine in content.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            // Drop trailing `# comment`, then split on the first `=`.
            let setting = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            guard let eq = setting.firstIndex(of: "=") else { continue }
            let key = setting[..<eq].trimmingCharacters(in: .whitespaces)
            guard key == "service_tier" else { continue }
            let value = setting[setting.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if value == "fast" || value == "priority" { return true }
        }
        return false
    }

    /// A per-event `"fast"`/`"priority"` tier (Claude `usage.speed` /
    /// `service_tier`) selects the model's fast-tier multiplier.
    static func eventIsFast(_ event: CostUsageScanCache.ParsedEvent) -> Bool {
        guard let tier = event.serviceTier else { return false }
        return tier == "fast" || tier == "priority"
    }

    private static func costUSD(tool: ToolType, event: CostUsageScanCache.ParsedEvent, codexFastTier: Bool = false) -> Double {
        costUSDIfPriceable(tool: tool, event: event, codexFastTier: codexFastTier) ?? 0
    }

    /// Same pricing math as `costUSD`, but keeps the pricing table's `nil`
    /// instead of collapsing it to `0`. A `nil` means "this model / provider
    /// has no rate we can apply", which the usage ledger records as an
    /// unpriced request rather than as a free one.
    private static func costUSDIfPriceable(
        tool: ToolType,
        event: CostUsageScanCache.ParsedEvent,
        codexFastTier: Bool = false
    ) -> Double? {
        switch tool {
        case .codex:
            return CostUsagePricing.codexCostUSD(
                model: event.model,
                inputTokens: event.input + event.cache,
                cachedInputTokens: event.cache,
                outputTokens: event.output,
                isFast: codexFastTier
            )
        case .claude:
            let cacheCreation = max(0, event.cacheCreation ?? 0)
            let cacheRead = max(0, event.cache - cacheCreation)
            return CostUsagePricing.claudeCostUSD(
                model: event.model,
                inputTokens: event.input,
                cacheReadInputTokens: cacheRead,
                cacheCreationInputTokens: cacheCreation,
                outputTokens: event.output,
                isFast: eventIsFast(event)
            )
        case .gemini:
            return CostUsagePricing.geminiCostUSD(
                model: event.model,
                inputTokens: event.input + event.cache,
                cacheReadInputTokens: event.cache,
                outputTokens: event.output
            )
        case .grok:
            return CostUsagePricing.grokCostUSD(
                model: event.model,
                inputTokens: event.input + event.cache,
                cachedInputTokens: event.cache,
                outputTokens: event.output
            )
        case .antigravity:
            let cacheCreation = max(0, event.cacheCreation ?? 0)
            let cacheRead = max(0, event.cache - cacheCreation)
            return CostUsagePricing.antigravityCostUSD(
                model: event.model,
                inputTokens: event.input,
                cacheReadInputTokens: cacheRead,
                cacheCreationInputTokens: cacheCreation,
                outputTokens: event.output
            )
        case .alibaba, .alibabaTokenPlan, .copilot, .zai, .minimax, .kimi, .cursor, .mimo, .iflytek, .tencentHunyuan, .tencentTokenPlan, .volcengine, .volcengineAgentPlan, .baiduQianfan, .openCodeGo, .kilo, .kiro, .ollama, .openRouter, .warp:
            return nil
        }
    }

    // MARK: - Event sink

    /// Hand one file's finished, priced events to the sink. A `nil` sink
    /// short-circuits before any allocation, so a scan without a ledger
    /// behaves exactly as it did before the sink existed.
    private static func emit(
        _ sink: (any CostUsageEventSink)?,
        tool: ToolType,
        file: URL,
        mtime: Date,
        size: Int64,
        events: [PricedUsageEvent]
    ) async {
        guard let sink else { return }
        await sink.consume(
            UsageEventFileBatch(
                tool: tool, filePath: file.path, mtime: mtime, size: size, events: events
            )
        )
    }

    /// Claude events are priced per message, independently of the
    /// cross-file dedup the aggregator runs afterwards, so a per-file batch
    /// can be emitted as soon as the file is parsed. The ledger applies the
    /// same preference rules on its `dedupe_key` conflict.
    private static func emitClaude(
        _ sink: (any CostUsageEventSink)?,
        file: URL,
        mtime: Date,
        size: Int64,
        events: [CostUsageScanCache.ParsedEvent]
    ) async {
        guard let sink else { return }
        let priced = events.map {
            PricedUsageEvent(event: $0, costUSD: costUSDIfPriceable(tool: .claude, event: $0))
        }
        await emit(sink, tool: .claude, file: file, mtime: mtime, size: size, events: priced)
    }

    private static func claudePathRole(file: URL) -> CostUsageScanCache.PathRole {
        file.path.contains("/subagents/") ? .subagent : .parent
    }

    // MARK: - Claude Cowork
    //
    // Cowork keeps one throwaway workspace per local agent run under
    // `~/Library/Application Support/Claude/local-agent-mode-sessions/
    //  <space>/<x>/local_<uuid>/.claude/projects/<encoded-cwd>/<uuid>.jsonl`.
    // The transcripts are byte-for-byte the same assistant/usage JSONL that
    // Claude Code writes, so the parser is shared; only the harness stamp
    // differs. Cowork is **read-only everywhere**: `ClaudeCoworkSessionAdapter`
    // lists and reads the same files for the Sessions manager, and refuses to
    // plan a delete, because nothing may remove files from inside Claude.app's
    // own container (AGENTS.md § 5).

    /// Claude.app's own directory name for a Cowork workspace tree. Used both
    /// to find the root and to recognise a file that came from it.
    static let claudeCoworkDirectoryName = "local-agent-mode-sessions"

    static func claudeCoworkRoot(homeDirectory: String) -> URL {
        URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Library/Application Support/Claude")
            .appendingPathComponent(claudeCoworkDirectoryName)
    }

    /// Recognised by path *component* rather than by a prefix match against
    /// the root: `FileManager.enumerator` hands back symlink-resolved paths
    /// (`/private/var/...` for a `/var/...` root), so a prefix test silently
    /// mislabels every Cowork transcript. Claude Code's own project
    /// directories are percent-ish encoded with dashes, so a project whose cwd
    /// merely mentions this name cannot collide with a real path component.
    static func claudeHarness(file: URL) -> Harness {
        file.pathComponents.contains(claudeCoworkDirectoryName) ? .claudeCowork : .claudeCode
    }

    /// Transcript files under the Cowork root.
    ///
    /// Unlike the Claude Code roots, the enumeration starts *above* a hidden
    /// `.claude` directory, so `.skipsHiddenFiles` would find nothing. Hidden
    /// entries are therefore walked, and the `/.claude/projects/` requirement
    /// is what keeps the walk to transcripts rather than to whatever else the
    /// app stores in that workspace. Symlinks are refused for the same reason
    /// `collectJSONL` refuses them: they could resolve anywhere.
    static func collectClaudeCoworkJSONL(under root: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard url.path.contains("/.claude/projects/") else { continue }
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isRegularFile == false { continue }
            out.append(url)
        }
        return out
    }

    private static func deduplicateClaudeEvents(
        _ events: [CostUsageScanCache.ParsedEvent]
    ) -> [CostUsageScanCache.ParsedEvent] {
        var keyed: [String: CostUsageScanCache.ParsedEvent] = [:]
        var unkeyed: [CostUsageScanCache.ParsedEvent] = []

        for event in events {
            guard let sessionId = event.sessionId,
                  let messageId = event.messageId,
                  let requestId = event.requestId
            else {
                unkeyed.append(event)
                continue
            }
            let key = "\(sessionId)\u{0}\(messageId)\u{0}\(requestId)"
            if let existing = keyed[key] {
                if claudeEventWins(candidate: event, existing: existing) {
                    keyed[key] = event
                }
            } else {
                keyed[key] = event
            }
        }

        return keyed.keys.sorted().compactMap { keyed[$0] } + unkeyed
    }

    private static func claudeEventWins(
        candidate: CostUsageScanCache.ParsedEvent,
        existing: CostUsageScanCache.ParsedEvent
    ) -> Bool {
        let candidateSidechain = candidate.isSidechain ?? false
        let existingSidechain = existing.isSidechain ?? false
        if candidateSidechain != existingSidechain {
            return !candidateSidechain
        }

        let candidateRole = candidate.pathRole ?? .parent
        let existingRole = existing.pathRole ?? .parent
        if candidateRole != existingRole {
            return candidateRole == .parent
        }

        return (candidate.sourceKey ?? "") < (existing.sourceKey ?? "")
    }

    // MARK: - Aggregator

    /// Shared accumulator for local scans and authoritative remote usage rows.
    /// Cursor's dashboard is the latter: its local transcripts contain content
    /// but no stable token/cost counters, so the same snapshot math is fed from
    /// cursor.com's account usage events instead.
    struct CostAggregator {
        let tool: ToolType
        let now: Date
        let calendar: Calendar
        let startOfToday: Date
        let startOfYesterday: Date
        /// Midnight of the oldest day that still gets per-hour buckets.
        let hourlyCutoff: Date
        let weekCutoff: Date
        let monthCutoff: Date

        var totalCost: Double = 0, totalTokens: Int = 0, totalRequests: Int = 0
        var todayCost: Double = 0, todayTokens: Int = 0, todayRequests: Int = 0
        var weekCost: Double = 0, weekTokens: Int = 0, weekRequests: Int = 0
        var monthCost: Double = 0, monthTokens: Int = 0, monthRequests: Int = 0
        var byDay: [Date: (cost: Double, tokens: Int)] = [:]
        /// Per-hour buckets across the whole retained hourly window, not just
        /// yesterday and today — the chart's Hour mode needs evidence wherever
        /// the user can navigate to inside the window.
        var byHour: [Date: (cost: Double, tokens: Int)] = [:]
        /// Midnights inside the hourly window that saw at least one event. Days
        /// with nothing at all are left out of the emitted series entirely;
        /// `hourlyCoverageStart` is what tells the chart they were scanned.
        var hourlyDays: Set<Date> = []
        var heatmap: [[Int]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        /// Model ranking across every scanned session.
        var byModelAllTime: [String: (cost: Double, tokens: Int)] = [:]
        /// Model leaderboard for the headline "Top Model" tile.
        var byModel7d: [String: (cost: Double, tokens: Int)] = [:]
        /// Per-day per-model breakdown. Keyed by `startOfDay` of the event so
        /// chart tooltips can show "On Mar 5: gpt-5 $1.20 · sonnet $0.40".
        var byDayModel: [Date: [String: (cost: Double, tokens: Int)]] = [:]
        var byHourModel: [Date: [String: (cost: Double, tokens: Int)]] = [:]

        init(tool: ToolType, now: Date) {
            self.tool = tool
            self.now = now
            var cal = Calendar(identifier: .gregorian)
            cal.locale = Locale(identifier: "en_US_POSIX")
            self.calendar = cal
            self.startOfToday = cal.startOfDay(for: now)
            self.startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
            self.hourlyCutoff = CostChartWindowPolicy.hourlyRetentionStart(now: now, calendar: cal)
            self.weekCutoff = cal.date(byAdding: .day, value: -6, to: startOfToday) ?? now
            self.monthCutoff = cal.date(byAdding: .day, value: -29, to: startOfToday) ?? now
        }

        mutating func add(at date: Date, model: String, input: Int, output: Int, cache: Int, costUSD: Double) {
            let tokens = input + output + cache
            totalCost += costUSD
            totalTokens += tokens
            totalRequests += 1
            if date >= startOfToday {
                todayCost += costUSD
                todayTokens += tokens
                todayRequests += 1
            }
            if date >= weekCutoff {
                weekCost += costUSD
                weekTokens += tokens
                weekRequests += 1
            }
            if date >= monthCutoff {
                monthCost += costUSD
                monthTokens += tokens
                monthRequests += 1
            }
            let dayKey = calendar.startOfDay(for: date)
            var bucket = byDay[dayKey] ?? (0, 0)
            bucket.cost += costUSD
            bucket.tokens += tokens
            byDay[dayKey] = bucket

            // One hourly lane for the whole retained window. Events dated after
            // today are clock skew rather than history, and a future bucket
            // would push the lane past the chart's domain, so they stay out.
            if date >= hourlyCutoff, dayKey <= startOfToday,
               let hourKey = calendar.dateInterval(of: .hour, for: date)?.start {
                var hourBucket = byHour[hourKey] ?? (0, 0)
                hourBucket.cost += costUSD
                hourBucket.tokens += tokens
                byHour[hourKey] = hourBucket
                hourlyDays.insert(dayKey)
            }

            let weekday = calendar.component(.weekday, from: date) - 1     // 0..6, Sunday=0
            let hour = calendar.component(.hour, from: date)
            if weekday >= 0 && weekday < 7 && hour >= 0 && hour < 24 {
                heatmap[weekday][hour] += tokens
            }
            var allTimeModelEntry = byModelAllTime[model] ?? (0, 0)
            allTimeModelEntry.cost += costUSD
            allTimeModelEntry.tokens += tokens
            byModelAllTime[model] = allTimeModelEntry

            if date >= weekCutoff {
                var modelEntry = byModel7d[model] ?? (0, 0)
                modelEntry.cost += costUSD
                modelEntry.tokens += tokens
                byModel7d[model] = modelEntry
            }

            // Per-day per-model — fueled by the chart tooltip.
            var dayModels = byDayModel[dayKey] ?? [:]
            var dayModelEntry = dayModels[model] ?? (0, 0)
            dayModelEntry.cost += costUSD
            dayModelEntry.tokens += tokens
            dayModels[model] = dayModelEntry
            byDayModel[dayKey] = dayModels

            if date >= hourlyCutoff, dayKey <= startOfToday,
               let hourKey = calendar.dateInterval(of: .hour, for: date)?.start {
                var hourModels = byHourModel[hourKey] ?? [:]
                var hourModelEntry = hourModels[model] ?? (0, 0)
                hourModelEntry.cost += costUSD
                hourModelEntry.tokens += tokens
                hourModels[model] = hourModelEntry
                byHourModel[hourKey] = hourModels
            }
        }

        /// Zero-filled hourly buckets for one local day, oldest first.
        ///
        /// Walked with the calendar rather than by adding 24 fixed offsets to
        /// midnight: a spring-forward day is 23 hours long and a fall-back day
        /// 25, and offset arithmetic would spill the last bucket into the next
        /// day — where it would collide with that day's own midnight bucket in
        /// the combined series. `notAfter` stops today's lane at the hour in
        /// progress instead of drawing the rest of the day as zeros.
        func hourlyPoints(forDayStarting day: Date, notAfter limit: Date?) -> [HourlyCostPoint] {
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) else { return [] }
            var points: [HourlyCostPoint] = []
            var hour = day
            while hour < dayEnd {
                if let limit, hour > limit { break }
                let value = byHour[hour] ?? (0, 0)
                points.append(
                    HourlyCostPoint(date: hour, costUSD: value.cost, totalTokens: value.tokens)
                )
                guard let next = calendar.date(byAdding: .hour, value: 1, to: hour), next > hour else {
                    break
                }
                hour = next
            }
            return points
        }

        func snapshot(jsonlFilesFound: Int) -> CostSnapshot {
            let sortedDays = byDay
                .sorted { $0.key < $1.key }
                .map { DailyCostPoint(date: $0.key, costUSD: $0.value.cost, totalTokens: $0.value.tokens) }
            let currentHourStart = calendar.dateInterval(of: .hour, for: now)?.start ?? startOfToday
            let hourlyToday = hourlyPoints(forDayStarting: startOfToday, notAfter: currentHourStart)
            let hourlyYesterday = hourlyPoints(forDayStarting: startOfYesterday, notAfter: nil)
            // Today and yesterday are always emitted, even at zero, so a chart
            // opened on a quiet morning still reads as "covered, nothing spent"
            // rather than falling back to daily bars.
            let recentDays = hourlyDays
                .union([startOfToday, startOfYesterday])
                .filter { $0 >= hourlyCutoff && $0 <= startOfToday }
                .sorted()
            let hourlyRecent = recentDays.flatMap { day in
                hourlyPoints(
                    forDayStarting: day,
                    notAfter: day == startOfToday ? currentHourStart : nil
                )
            }
            let sevenDayBreakdowns = byModel7d
                .sorted { $0.value.cost > $1.value.cost }
                .prefix(20)
                .map { CostSnapshot.ModelBreakdown(modelName: $0.key, costUSD: $0.value.cost, totalTokens: $0.value.tokens) }
            // Full ranking: all scanned model usage, not just the 7-day window.
            let allTimeBreakdowns = byModelAllTime
                .sorted { $0.value.cost > $1.value.cost }
                .prefix(20)
                .map { CostSnapshot.ModelBreakdown(modelName: $0.key, costUSD: $0.value.cost, totalTokens: $0.value.tokens) }
            // Keep every per-period model. Hover remains intentionally compact,
            // while the inline inspector can show the complete model mix.
            var perDayModels: [Date: [CostSnapshot.ModelBreakdown]] = [:]
            for (day, models) in byDayModel {
                perDayModels[day] = models
                    .sorted { $0.value.cost > $1.value.cost }
                    .map { CostSnapshot.ModelBreakdown(modelName: $0.key, costUSD: $0.value.cost, totalTokens: $0.value.tokens) }
            }
            var perHourModels: [Date: [CostSnapshot.ModelBreakdown]] = [:]
            for (hour, models) in byHourModel {
                perHourModels[hour] = models
                    .sorted { $0.value.cost > $1.value.cost }
                    .map { CostSnapshot.ModelBreakdown(modelName: $0.key, costUSD: $0.value.cost, totalTokens: $0.value.tokens) }
            }
            return CostSnapshot(
                tool: tool,
                todayCostUSD: todayCost,
                last7DaysCostUSD: weekCost,
                last30DaysCostUSD: monthCost,
                allTimeCostUSD: totalCost,
                todayTokens: todayTokens,
                last7DaysTokens: weekTokens,
                last30DaysTokens: monthTokens,
                allTimeTokens: totalTokens,
                todayRequests: todayRequests,
                last7DaysRequests: weekRequests,
                last30DaysRequests: monthRequests,
                allTimeRequests: totalRequests,
                dailyHistory: sortedDays,
                todayHourlyHistory: hourlyToday,
                yesterdayHourlyHistory: hourlyYesterday,
                recentHourlyHistory: hourlyRecent,
                hourlyCoverageStart: hourlyCutoff,
                heatmap: UsageHeatmap(tool: tool, cells: heatmap, totalTokens: totalTokens),
                modelBreakdowns: Array(allTimeBreakdowns),
                last7DaysModelBreakdowns: Array(sevenDayBreakdowns),
                dailyModelBreakdown: perDayModels,
                hourlyModelBreakdown: perHourModels,
                jsonlFilesFound: jsonlFilesFound,
                updatedAt: now
            )
        }
    }

    // MARK: - Helpers

    private static func collectJSONL(under root: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            // Skip symlinks. They could resolve outside `~/.claude` /
            // `~/.codex` (e.g. an attacker with the user's UID seeding a link
            // to a different cache directory) and we don't want the scanner
            // to follow them silently.
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isRegularFile == false { continue }
            out.append(url)
        }
        return out
    }

    private static func fileMTime(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// (mtime, size) pair used as the per-file cache fingerprint. Falls back
    /// to `(distantPast, 0)` so a missing-attribute case never hits the
    /// cache, forcing a fresh parse rather than masking corruption.
    private static func fileFingerprint(_ url: URL) -> (Date, Int64) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return (.distantPast, 0)
        }
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return (mtime, size)
    }

    private static let lineChunkSize = 64 * 1024
    private static let newlineData = Data([0x0A])

    /// Internal rather than private so the session adapters can reuse the
    /// same O(n) line walk instead of copying it.
    static func forEachJSONLLine(in file: URL, _ body: (Data) -> Void) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }

        // Linear-time JSONL scan via [UInt8]: walks a single moving cursor
        // and only compacts when the consumed prefix exceeds one chunk. We
        // intentionally avoid Data as the scratch buffer — Data.removeFirst
        // can leave heap-backed storage with a non-zero startIndex, after
        // which 0-based subscripting like `buffer[i]` trips a bounds
        // precondition under release optimization. Array<UInt8>.removeFirst
        // physically shifts bytes and keeps indices 0-based, so this loop
        // is safe and still O(n).
        var buffer: [UInt8] = []
        var lineStart = 0
        do {
            while let chunk = try handle.read(upToCount: lineChunkSize), !chunk.isEmpty {
                buffer.append(contentsOf: chunk)
                let end = buffer.count
                var i = lineStart
                while i < end {
                    if buffer[i] == 0x0A {
                        if i > lineStart {
                            body(Data(buffer[lineStart..<i]))
                        }
                        lineStart = i + 1
                    }
                    i += 1
                }
                if lineStart > lineChunkSize {
                    buffer.removeFirst(lineStart)
                    lineStart = 0
                }
            }
            if lineStart < buffer.count {
                let tail = Data(buffer[lineStart..<buffer.count])
                if !tail.isEmpty {
                    body(tail)
                }
            }
            return true
        } catch {
            return false
        }
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoStandard: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseISO(_ raw: String) -> Date? {
        isoWithFraction.date(from: raw) ?? isoStandard.date(from: raw)
    }

    private static func normalizedNonEmpty(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func firstNonEmptyString(_ values: Any?...) -> String? {
        for value in values {
            if let string = value as? String,
               let normalized = normalizedNonEmpty(string) {
                return normalized
            }
            if let number = value as? NSNumber {
                let string = number.stringValue
                if let normalized = normalizedNonEmpty(string) {
                    return normalized
                }
            }
        }
        return nil
    }

    private static func firstDate(from values: Any?...) -> Date? {
        for value in values {
            if let string = value as? String, let date = parseISO(string) {
                return date
            }
            if let number = value as? NSNumber {
                return Date(timeIntervalSince1970: number.doubleValue)
            }
        }
        return nil
    }

    private static func anyInt(_ value: Any?) -> Int {
        if let n = value as? NSNumber { return n.intValue }
        if let i = value as? Int { return i }
        return 0
    }

    private static func anyBool(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return false
    }
}

private extension Data {
    func contains(asciiSequence sequence: String) -> Bool {
        guard let needle = sequence.data(using: .ascii) else { return false }
        return self.range(of: needle) != nil
    }
}
