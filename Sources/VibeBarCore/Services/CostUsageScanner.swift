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
        case .alibaba, .gemini, .antigravity, .copilot, .zai, .minimax, .kimi, .cursor, .mimo, .iflytek, .tencentHunyuan, .volcengine, .openCodeGo, .kilo, .kiro, .ollama, .openRouter:
            // Misc providers don't expose token-level cost data; the
            // cost-history pipeline is gated by `tool.supportsTokenCost`
            // upstream. Returning `nil` here is a defensive belt:
            // anything that does call us by accident gets an empty
            // snapshot, not a crash.
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
        case .alibaba, .gemini, .antigravity, .copilot, .zai, .minimax, .kimi, .cursor, .mimo, .iflytek, .tencentHunyuan, .volcengine, .openCodeGo, .kilo, .kiro, .ollama, .openRouter:
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
