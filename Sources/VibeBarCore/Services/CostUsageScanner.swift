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
    public static func scan(
        tool: ToolType,
        homeDirectory: String = RealHomeDirectory.path,
        now: Date = Date(),
        retentionDays: Int? = nil
    ) async -> CostSnapshot? {
        switch tool {
        case .codex:
            return await scanCodex(homeDirectory: homeDirectory, now: now, retentionDays: retentionDays)
        case .claude:
            return await scanClaude(homeDirectory: homeDirectory, now: now, retentionDays: retentionDays)
        case .gemini:
            return await scanGemini(homeDirectory: homeDirectory, now: now, retentionDays: retentionDays)
        case .grok:
            return await scanGrok(homeDirectory: homeDirectory, now: now, retentionDays: retentionDays)
        case .antigravity:
            return await scanAntigravity(homeDirectory: homeDirectory, now: now, retentionDays: retentionDays)
        case .alibaba, .alibabaTokenPlan, .copilot, .zai, .minimax, .kimi, .cursor, .mimo, .iflytek, .tencentHunyuan, .tencentTokenPlan, .volcengine, .baiduQianfan, .openCodeGo, .kilo, .kiro, .ollama, .openRouter, .warp:
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
        retentionDays: Int?
    ) async -> CostSnapshot {
        let roots = [
            URL(fileURLWithPath: homeDirectory).appendingPathComponent(".codex/sessions"),
            URL(fileURLWithPath: homeDirectory).appendingPathComponent(".codex/archived_sessions")
        ]
        let files = roots.flatMap { collectJSONL(under: $0) }
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
                for event in retained {
                    let cost = costUSD(tool: .codex, event: event)
                    aggregator.add(at: event.date, model: event.model, input: event.input,
                                   output: event.output, cache: event.cache, costUSD: cost)
                }
                continue
            }

            let raw = parseCodexFile(file: file)
            // Delta from one snapshot to the next is what was used in that interval.
            var previous: CodexEvent.Totals? = nil
            var parsed: [CostUsageScanCache.ParsedEvent] = []
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
                let cost = CostUsagePricing.codexCostUSD(
                    model: event.model,
                    inputTokens: delta.input,
                    cachedInputTokens: delta.cached,
                    outputTokens: delta.output
                ) ?? 0
                let parsedEvent = CostUsageScanCache.ParsedEvent(
                    date: event.date,
                    model: event.model,
                    input: max(0, delta.input - delta.cached),
                    output: delta.output,
                    cache: delta.cached
                )
                guard isRetained(parsedEvent.date, cutoff: cutoff) else { continue }
                parsed.append(parsedEvent)
                aggregator.add(at: parsedEvent.date, model: parsedEvent.model,
                               input: parsedEvent.input, output: parsedEvent.output,
                               cache: parsedEvent.cache, costUSD: cost)
            }
            cache.store(parsed, for: file.path, mtime: mtime, size: size)
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

    private static func parseCodexFile(file: URL) -> [CodexEvent] {
        var events: [CodexEvent] = []
        var currentModel = "gpt-5"
        var runningTotals = CodexEvent.Totals(input: 0, cached: 0, output: 0)
        let didRead = forEachJSONLLine(in: file) { lineData in
            guard !lineData.isEmpty else { return }
            guard lineData.contains(asciiSequence: "token_count") ||
                    lineData.contains(asciiSequence: "model") else { return }
            guard let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else { return }

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
        return didRead ? events : []
    }

    // MARK: - Claude

    private static func scanClaude(
        homeDirectory: String,
        now: Date,
        retentionDays: Int?
    ) async -> CostSnapshot {
        let projectsRoot = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".claude/projects")
        let altRoot = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".config/claude/projects")
        let files = collectJSONL(under: projectsRoot) + collectJSONL(under: altRoot)
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
                continue
            }

            let sourceKey = CostUsageScanCache.entryKey(for: file.path)
            let pathRole = claudePathRole(file: file)
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
                    sourceKey: sourceKey
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
                continue
            }
            let parsed = keyedRows.keys.sorted().compactMap { keyedRows[$0] } + unkeyedRows
            cache.store(parsed, for: file.path, mtime: mtime, size: size)
            allEvents.append(contentsOf: parsed)
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
        retentionDays: Int?
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
                for event in retained {
                    let cost = costUSD(tool: .gemini, event: event)
                    aggregator.add(at: event.date, model: event.model, input: event.input,
                                   output: event.output, cache: event.cache, costUSD: cost)
                }
                continue
            }

            let isChatFile = file.path.contains("/chats/")
            let parsed: [CostUsageScanCache.ParsedEvent]
            let didRead: Bool
            if isChatFile {
                (parsed, didRead) = parseGeminiChatFile(file: file, cutoff: cutoff, aggregator: &aggregator)
            } else {
                (parsed, didRead) = parseGeminiTelemetryFile(file: file, now: now, cutoff: cutoff, aggregator: &aggregator)
            }
            if didRead {
                cache.store(parsed, for: file.path, mtime: mtime, size: size)
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
    ) -> ([CostUsageScanCache.ParsedEvent], Bool) {
        var parsed: [CostUsageScanCache.ParsedEvent] = []
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
                messageId: promptId
            )
            guard isRetained(parsedEvent.date, cutoff: cutoff) else { return }
            parsed.append(parsedEvent)
            let cost = CostUsagePricing.geminiCostUSD(
                model: model,
                inputTokens: input,
                cacheReadInputTokens: cached,
                outputTokens: output
            ) ?? 0
            aggregator.add(at: parsedEvent.date, model: parsedEvent.model,
                           input: parsedEvent.input, output: parsedEvent.output,
                           cache: parsedEvent.cache, costUSD: cost)
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
    ) -> ([CostUsageScanCache.ParsedEvent], Bool) {
        var parsed: [CostUsageScanCache.ParsedEvent] = []
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
                messageId: raw["id"] as? String
            )
            guard isRetained(parsedEvent.date, cutoff: cutoff) else { return }
            parsed.append(parsedEvent)
            let cost = CostUsagePricing.geminiCostUSD(
                model: model,
                inputTokens: inputTotal,
                cacheReadInputTokens: cached,
                outputTokens: outputBilled
            ) ?? 0
            aggregator.add(at: parsedEvent.date, model: parsedEvent.model,
                           input: parsedEvent.input, output: parsedEvent.output,
                           cache: parsedEvent.cache, costUSD: cost)
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
        retentionDays: Int?
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
                for event in retained {
                    let cost = costUSD(tool: .grok, event: event)
                    aggregator.add(at: event.date, model: event.model, input: event.input,
                                   output: event.output, cache: event.cache, costUSD: cost)
                }
                continue
            }

            let raw = parseGrokUpdatesFile(file: file)
            var parsed: [CostUsageScanCache.ParsedEvent] = []
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
                    sessionId: snapshot.sessionId
                )
                guard isRetained(parsedEvent.date, cutoff: cutoff) else { continue }
                parsed.append(parsedEvent)
                let cost = costUSD(tool: .grok, event: parsedEvent)
                aggregator.add(at: parsedEvent.date, model: parsedEvent.model,
                               input: parsedEvent.input, output: parsedEvent.output,
                               cache: parsedEvent.cache, costUSD: cost)
            }
            cache.store(parsed, for: file.path, mtime: mtime, size: size)
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

    // MARK: - AntiGravity (per-trajectory SQLite + protobuf blobs)
    //
    // The AntiGravity IDE writes one SQLite database per conversation
    // under `~/.gemini/antigravity/conversations/<UUID>.db`. The
    // `gen_metadata` table holds one row per model call; its `data`
    // BLOB is a protobuf message we read with a raw varint scanner
    // (no SwiftProtobuf dependency). Per-row token fields under path
    // `1.4`:
    //   - field 1: constant system-prompt size (cached after turn 1)
    //   - field 2: non-cached input tokens this turn
    //   - field 3: output tokens this turn
    //   - field 5: cumulative cache-read pool size
    //   - field 9: reasoning / thinking tokens (counted as output)
    //   - field 10: tool tokens (counted as output)
    // Model id lives at path `1.19`.
    // Timestamp lives at path `1.9.4` (seconds + nanos).
    //
    // The CLI-only `~/.gemini/antigravity-cli/conversations/*.pb`
    // container is an unidentified binary format, and the companion
    // transcript/history JSONL files do not carry token counts. CLI-only
    // AntiGravity usage stays dark until that format is reverse-engineered.

    private static func scanAntigravity(
        homeDirectory: String,
        now: Date,
        retentionDays: Int?
    ) async -> CostSnapshot {
        let root = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".gemini/antigravity/conversations")
        let dbFiles = collectAntigravityConversationFiles(under: root)
        var aggregator = CostAggregator(tool: .antigravity, now: now)
        var cache = CostUsageScanCache.load(homeDirectory: homeDirectory, tool: .antigravity, retentionDays: retentionDays)
        let cutoff = retentionCutoff(now: now, retentionDays: retentionDays)

        for file in dbFiles {
            let (mtime, size) = fileFingerprint(file)
            if let cached = cache.reusable(for: file.path, mtime: mtime, size: size) {
                let retained = retainedEvents(cached, cutoff: cutoff)
                if retained.count != cached.count {
                    cache.store(retained, for: file.path, mtime: mtime, size: size)
                }
                for event in retained {
                    let cost = costUSD(tool: .antigravity, event: event)
                    aggregator.add(at: event.date, model: event.model, input: event.input,
                                   output: event.output, cache: event.cache, costUSD: cost)
                }
                continue
            }

            let turns = AntigravitySessionReader.readGenMetadata(at: file)
            var parsed: [CostUsageScanCache.ParsedEvent] = []
            parsed.reserveCapacity(turns.count)
            var previousCacheCumulative = 0
            let sessionId = file.deletingPathExtension().lastPathComponent
            for turn in turns {
                let cacheCreation = max(0, turn.cumulativeCacheReadTokens - previousCacheCumulative)
                let cacheRead = max(0, previousCacheCumulative)
                previousCacheCumulative = turn.cumulativeCacheReadTokens
                let input = turn.inputTokens
                // Reasoning + tool tokens are billed at output rates by
                // Claude / Gemini, so fold them into output here.
                let output = turn.outputTokens + turn.thoughtsTokens + turn.toolTokens
                guard input > 0 || output > 0 || cacheRead > 0 || cacheCreation > 0 else { continue }
                let model = normalizedNonEmpty(turn.model) ?? "antigravity-default"
                let parsedEvent = CostUsageScanCache.ParsedEvent(
                    date: turn.date,
                    model: model,
                    input: input,
                    output: output,
                    cache: cacheRead + cacheCreation,
                    cacheCreation: cacheCreation,
                    sessionId: sessionId,
                    messageId: turn.requestId
                )
                guard isRetained(parsedEvent.date, cutoff: cutoff) else { continue }
                parsed.append(parsedEvent)
                let cost = costUSD(tool: .antigravity, event: parsedEvent)
                aggregator.add(at: parsedEvent.date, model: parsedEvent.model,
                               input: parsedEvent.input, output: parsedEvent.output,
                               cache: parsedEvent.cache, costUSD: cost)
            }
            cache.store(parsed, for: file.path, mtime: mtime, size: size)
        }
        cache.prune(known: Set(dbFiles.map(\.path)))
        cache.save(homeDirectory: homeDirectory, tool: .antigravity)
        return aggregator.snapshot(jsonlFilesFound: dbFiles.count)
    }

    private static func collectAntigravityConversationFiles(under root: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { url in
            guard url.pathExtension == "db" else { return false }
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if values?.isSymbolicLink == true { return false }
            if values?.isRegularFile == false { return false }
            return true
        }
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

    private static func costUSD(tool: ToolType, event: CostUsageScanCache.ParsedEvent) -> Double {
        switch tool {
        case .codex:
            return CostUsagePricing.codexCostUSD(
                model: event.model,
                inputTokens: event.input + event.cache,
                cachedInputTokens: event.cache,
                outputTokens: event.output
            ) ?? 0
        case .claude:
            let cacheCreation = max(0, event.cacheCreation ?? 0)
            let cacheRead = max(0, event.cache - cacheCreation)
            return CostUsagePricing.claudeCostUSD(
                model: event.model,
                inputTokens: event.input,
                cacheReadInputTokens: cacheRead,
                cacheCreationInputTokens: cacheCreation,
                outputTokens: event.output
            ) ?? 0
        case .gemini:
            return CostUsagePricing.geminiCostUSD(
                model: event.model,
                inputTokens: event.input + event.cache,
                cacheReadInputTokens: event.cache,
                outputTokens: event.output
            ) ?? 0
        case .grok:
            return CostUsagePricing.grokCostUSD(
                model: event.model,
                inputTokens: event.input + event.cache,
                cachedInputTokens: event.cache,
                outputTokens: event.output
            ) ?? 0
        case .antigravity:
            let cacheCreation = max(0, event.cacheCreation ?? 0)
            let cacheRead = max(0, event.cache - cacheCreation)
            return CostUsagePricing.antigravityCostUSD(
                model: event.model,
                inputTokens: event.input,
                cacheReadInputTokens: cacheRead,
                cacheCreationInputTokens: cacheCreation,
                outputTokens: event.output
            ) ?? 0
        case .alibaba, .alibabaTokenPlan, .copilot, .zai, .minimax, .kimi, .cursor, .mimo, .iflytek, .tencentHunyuan, .tencentTokenPlan, .volcengine, .baiduQianfan, .openCodeGo, .kilo, .kiro, .ollama, .openRouter, .warp:
            return 0
        }
    }

    private static func claudePathRole(file: URL) -> CostUsageScanCache.PathRole {
        file.path.contains("/subagents/") ? .subagent : .parent
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

    private struct CostAggregator {
        let tool: ToolType
        let now: Date
        let calendar: Calendar
        let startOfToday: Date
        let weekCutoff: Date
        let monthCutoff: Date

        var totalCost: Double = 0, totalTokens: Int = 0
        var todayCost: Double = 0, todayTokens: Int = 0
        var weekCost: Double = 0, weekTokens: Int = 0
        var monthCost: Double = 0, monthTokens: Int = 0
        var byDay: [Date: (cost: Double, tokens: Int)] = [:]
        var byHourToday: [Date: (cost: Double, tokens: Int)] = [:]
        var heatmap: [[Int]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        /// Model ranking across every scanned session.
        var byModelAllTime: [String: (cost: Double, tokens: Int)] = [:]
        /// Model leaderboard for the headline "Top Model" tile.
        var byModel7d: [String: (cost: Double, tokens: Int)] = [:]
        /// Per-day per-model breakdown. Keyed by `startOfDay` of the event so
        /// chart tooltips can show "On Mar 5: gpt-5 $1.20 · sonnet $0.40".
        var byDayModel: [Date: [String: (cost: Double, tokens: Int)]] = [:]

        init(tool: ToolType, now: Date) {
            self.tool = tool
            self.now = now
            var cal = Calendar(identifier: .gregorian)
            cal.locale = Locale(identifier: "en_US_POSIX")
            self.calendar = cal
            self.startOfToday = cal.startOfDay(for: now)
            self.weekCutoff = cal.date(byAdding: .day, value: -6, to: startOfToday) ?? now
            self.monthCutoff = cal.date(byAdding: .day, value: -29, to: startOfToday) ?? now
        }

        mutating func add(at date: Date, model: String, input: Int, output: Int, cache: Int, costUSD: Double) {
            let tokens = input + output + cache
            totalCost += costUSD
            totalTokens += tokens
            if date >= startOfToday {
                todayCost += costUSD
                todayTokens += tokens
                if let hourKey = calendar.dateInterval(of: .hour, for: date)?.start {
                    var hourBucket = byHourToday[hourKey] ?? (0, 0)
                    hourBucket.cost += costUSD
                    hourBucket.tokens += tokens
                    byHourToday[hourKey] = hourBucket
                }
            }
            if date >= weekCutoff {
                weekCost += costUSD
                weekTokens += tokens
            }
            if date >= monthCutoff {
                monthCost += costUSD
                monthTokens += tokens
            }
            let dayKey = calendar.startOfDay(for: date)
            var bucket = byDay[dayKey] ?? (0, 0)
            bucket.cost += costUSD
            bucket.tokens += tokens
            byDay[dayKey] = bucket

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
        }

        func snapshot(jsonlFilesFound: Int) -> CostSnapshot {
            let sortedDays = byDay
                .sorted { $0.key < $1.key }
                .map { DailyCostPoint(date: $0.key, costUSD: $0.value.cost, totalTokens: $0.value.tokens) }
            let currentHour = calendar.component(.hour, from: now)
            let hourlyToday = (0...max(0, currentHour)).compactMap { offset -> HourlyCostPoint? in
                guard let hour = calendar.date(byAdding: .hour, value: offset, to: startOfToday) else { return nil }
                let value = byHourToday[hour] ?? (0, 0)
                return HourlyCostPoint(date: hour, costUSD: value.cost, totalTokens: value.tokens)
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
            // Reduce per-day model maps to sorted top-N arrays. Tooltip caps
            // at 3 entries; we keep up to 5 here in case the UI wants more.
            var perDayModels: [Date: [CostSnapshot.ModelBreakdown]] = [:]
            for (day, models) in byDayModel {
                perDayModels[day] = models
                    .sorted { $0.value.cost > $1.value.cost }
                    .prefix(5)
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
                dailyHistory: sortedDays,
                todayHourlyHistory: hourlyToday,
                heatmap: UsageHeatmap(tool: tool, cells: heatmap, totalTokens: totalTokens),
                modelBreakdowns: Array(allTimeBreakdowns),
                last7DaysModelBreakdowns: Array(sevenDayBreakdowns),
                dailyModelBreakdown: perDayModels,
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

    private static func forEachJSONLLine(in file: URL, _ body: (Data) -> Void) -> Bool {
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
