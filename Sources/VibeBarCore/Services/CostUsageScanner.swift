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
        homeDirectory: String = NSHomeDirectory(),
        now: Date = Date()
    ) async -> CostSnapshot? {
        switch tool {
        case .codex:
            return await scanCodex(homeDirectory: homeDirectory, now: now)
        case .claude:
            return await scanClaude(homeDirectory: homeDirectory, now: now)
        }
    }

    // MARK: - Codex

    private static func scanCodex(homeDirectory: String, now: Date) async -> CostSnapshot {
        let roots = [
            URL(fileURLWithPath: homeDirectory).appendingPathComponent(".codex/sessions"),
            URL(fileURLWithPath: homeDirectory).appendingPathComponent(".codex/archived_sessions")
        ]
        let files = roots.flatMap { collectJSONL(under: $0) }
        var aggregator = CostAggregator(tool: .codex, now: now)

        for file in files {
            let events = parseCodexFile(file: file)
            // Delta from one snapshot to the next is what was used in that interval.
            var previous: CodexEvent.Totals? = nil
            for event in events {
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
                aggregator.add(
                    at: event.date,
                    model: event.model,
                    input: max(0, delta.input - delta.cached),
                    output: delta.output,
                    cache: delta.cached,
                    costUSD: cost
                )
            }
        }
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
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd() else { return [] }

        var events: [CodexEvent] = []
        var currentModel = "gpt-5"
        for lineData in data.split(separator: 0x0A) {
            guard !lineData.isEmpty else { continue }
            guard lineData.contains(asciiSequence: "token_count") ||
                    lineData.contains(asciiSequence: "model") else { continue }
            guard let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else { continue }

            if let payload = obj["payload"] as? [String: Any] {
                if let m = payload["model"] as? String { currentModel = m }
            }
            if let m = obj["model"] as? String { currentModel = m }

            guard obj["type"] as? String == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any]
            else { continue }
            guard let total = info["total_token_usage"] as? [String: Any] else { continue }
            let totals = CodexEvent.Totals(
                input: anyInt(total["input_tokens"]),
                cached: anyInt(total["cached_input_tokens"] ?? total["cache_read_input_tokens"]),
                output: anyInt(total["output_tokens"])
            )
            let timestamp = (obj["timestamp"] as? String).flatMap(parseISO) ?? fileMTime(file) ?? Date()
            events.append(CodexEvent(date: timestamp, model: currentModel, totals: totals))
        }
        return events
    }

    // MARK: - Claude

    private static func scanClaude(homeDirectory: String, now: Date) async -> CostSnapshot {
        let projectsRoot = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".claude/projects")
        let altRoot = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".config/claude/projects")
        let files = collectJSONL(under: projectsRoot) + collectJSONL(under: altRoot)
        var aggregator = CostAggregator(tool: .claude, now: now)

        for file in files {
            guard let handle = try? FileHandle(forReadingFrom: file),
                  let data = try? handle.readToEnd()
            else { continue }
            try? handle.close()

            for lineData in data.split(separator: 0x0A) {
                guard !lineData.isEmpty,
                      lineData.contains(asciiSequence: "assistant"),
                      lineData.contains(asciiSequence: "usage")
                else { continue }
                guard let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
                      obj["type"] as? String == "assistant",
                      let message = obj["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any]
                else { continue }

                let model = (message["model"] as? String) ?? "claude-sonnet-4-5"
                let input = anyInt(usage["input_tokens"])
                let cacheRead = anyInt(usage["cache_read_input_tokens"])
                let cacheCreation = anyInt(usage["cache_creation_input_tokens"])
                let output = anyInt(usage["output_tokens"])
                let cost = CostUsagePricing.claudeCostUSD(
                    model: model,
                    inputTokens: input,
                    cacheReadInputTokens: cacheRead,
                    cacheCreationInputTokens: cacheCreation,
                    outputTokens: output
                ) ?? 0
                let date = (obj["timestamp"] as? String).flatMap(parseISO) ?? fileMTime(file) ?? Date()
                aggregator.add(
                    at: date,
                    model: model,
                    input: input,
                    output: output,
                    cache: cacheRead + cacheCreation,
                    costUSD: cost
                )
            }
        }
        return aggregator.snapshot(jsonlFilesFound: files.count)
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
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            out.append(url)
        }
        return out
    }

    private static func fileMTime(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
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
}

private extension Data {
    func contains(asciiSequence sequence: String) -> Bool {
        guard let needle = sequence.data(using: .ascii) else { return false }
        return self.range(of: needle) != nil
    }
}
