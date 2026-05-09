import Foundation

public actor ServiceStatusClient {
    private let session: URLSession
    private let calendar: Calendar

    public init(session: URLSession = .shared) {
        self.session = session
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        self.calendar = cal
    }

    public func fetch(
        tool: ToolType,
        dayCount: Int = 90,
        now: Date = Date()
    ) async throws -> ServiceStatusSnapshot {
        switch tool {
        case .codex:  return try await fetchOpenAI(dayCount: dayCount, now: now)
        case .claude: return try await fetchClaude(dayCount: dayCount, now: now)
        case .alibaba, .gemini, .antigravity, .copilot, .zai, .minimax, .kimi, .cursor, .mimo, .iflytek:
            // Misc providers don't expose Atlassian-style status APIs.
            // `tool.supportsStatusPage` is `false` for all of them, and
            // upstream callers should already be filtering to primary
            // tools via `tool.supportsStatusPage` before reaching here.
            // We return an empty `none`-indicator snapshot rather than
            // throwing so any straggler call site fails closed instead
            // of crashing.
            return ServiceStatusSnapshot(
                tool: tool,
                indicator: .none,
                description: "Status page polling is not supported for this provider.",
                updatedAt: now,
                groups: [],
                components: [],
                recentIncidents: []
            )
        }
    }

    // MARK: - Claude (classic Statuspage with embedded uptimeData)

    private func fetchClaude(dayCount: Int, now: Date) async throws -> ServiceStatusSnapshot {
        let html = try await fetchHTML(url: ToolType.claude.statusPageURL)
        let summary = try await fetchJSON(SummaryDTO.self, from: ToolType.claude.statusSummaryAPI)
        let incidentsDTO = try await fetchJSON(IncidentsDTO.self, from: ToolType.claude.statusIncidentsAPI)

        let uptimeMap = parseClaudeUptimeData(html: html)
        let groups: [ServiceComponentGroup] = []  // claude.com is flat, no groups

        var components: [ServiceComponentSummary] = []
        for raw in summary.components where raw.group_id == nil && raw.group != true {
            let rawDays = uptimeMap[raw.id]?.days ?? []
            let perDay = buildClaudeDays(from: rawDays, dayCount: dayCount, now: now)
            let uptime = computeClaudeUptime(rawDays, dayCount: dayCount)
            components.append(
                ServiceComponentSummary(
                    id: raw.id,
                    name: raw.name,
                    status: raw.status,
                    groupId: nil,
                    uptimePercent: uptime,
                    recentDays: perDay
                )
            )
        }

        let recent = incidentsDTO.incidents
            .sorted { $0.created_at > $1.created_at }
            .prefix(4)
            .map {
                IncidentSummary(
                    id: $0.id,
                    name: $0.name,
                    impact: $0.impact,
                    createdAt: $0.created_at,
                    resolvedAt: $0.resolved_at,
                    url: $0.shortlink
                )
            }

        return ServiceStatusSnapshot(
            tool: .claude,
            indicator: summary.status.indicator,
            description: summary.status.description,
            updatedAt: summary.page.updated_at,
            groups: groups,
            components: components,
            recentIncidents: Array(recent)
        )
    }

    // MARK: - OpenAI (incident.io with embedded streaming chunks)

    private func fetchOpenAI(dayCount: Int, now: Date) async throws -> ServiceStatusSnapshot {
        let html = try await fetchHTML(url: ToolType.codex.statusPageURL)
        let summary = try await fetchJSON(SummaryDTO.self, from: ToolType.codex.statusSummaryAPI)
        let componentsDTO = try await fetchJSON(ComponentsDTO.self, from: ToolType.codex.statusComponentsAPI)
        let incidentsDTO = try await fetchJSON(IncidentsDTO.self, from: ToolType.codex.statusIncidentsAPI)

        let combined = ServiceStatusClient.combinedNextChunks(html: html)
        let groups = ServiceStatusClient.parseOpenAIGroups(combined: combined)
        let groupAssignments = ServiceStatusClient.parseOpenAIComponentGroupMap(combined: combined, groups: groups)
        let uptimeMap = ServiceStatusClient.parseOpenAIComponentUptime(combined: combined)
        let perComponentIncidents = ServiceStatusClient.parseOpenAIPerComponentIncidents(combined: combined)

        var components: [ServiceComponentSummary] = []
        for raw in componentsDTO.components {
            let groupId = groupAssignments[raw.id]
            let perDay = buildDayBuckets(
                from: perComponentIncidents[raw.id] ?? [],
                dayCount: dayCount,
                now: now
            )
            let uptime: Double? = uptimeMap[raw.id] ?? (perDay.isEmpty ? nil : computeUptime(perDay))
            components.append(
                ServiceComponentSummary(
                    id: raw.id,
                    name: raw.name,
                    status: raw.status,
                    groupId: groupId,
                    uptimePercent: uptime,
                    recentDays: perDay
                )
            )
        }

        let recent = incidentsDTO.incidents
            .sorted { $0.created_at > $1.created_at }
            .prefix(4)
            .map {
                IncidentSummary(
                    id: $0.id,
                    name: $0.name,
                    impact: $0.impact,
                    createdAt: $0.created_at,
                    resolvedAt: $0.resolved_at,
                    url: $0.shortlink
                )
            }

        return ServiceStatusSnapshot(
            tool: .codex,
            indicator: summary.status.indicator,
            description: summary.status.description,
            updatedAt: summary.page.updated_at,
            groups: groups,
            components: components,
            recentIncidents: Array(recent)
        )
    }

    // MARK: - HTML / JSON fetch primitives

    private func fetchHTML(url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await HTTPResponseLimit.boundedData(from: session, for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else {
            throw ServiceStatusError.badResponse
        }
        return text
    }

    private func fetchJSON<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Vibe Bar/1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await HTTPResponseLimit.boundedData(from: session, for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceStatusError.badResponse
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = ServiceStatusClient.flexibleDate(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date string \(raw)"
            )
        }
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Day bucket helpers

    private func buildDayBuckets(
        from impacts: [(start: Date, end: Date, impact: IncidentImpact)],
        dayCount: Int,
        now: Date
    ) -> [DayUptime] {
        let today = calendar.startOfDay(for: now)
        var bucket: [Date: IncidentImpact] = [:]
        for entry in impacts {
            let start = calendar.startOfDay(for: entry.start)
            let end = calendar.startOfDay(for: entry.end)
            var d = start
            while d <= end {
                if let existing = bucket[d] {
                    if entry.impact.severity > existing.severity {
                        bucket[d] = entry.impact
                    }
                } else {
                    bucket[d] = entry.impact
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
                d = next
                if d > today { break }
            }
        }
        var result: [DayUptime] = []
        for offset in stride(from: dayCount - 1, through: 0, by: -1) {
            guard let d = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            result.append(DayUptime(date: d, worstImpact: bucket[d]))
        }
        return result
    }

    private func buildClaudeDays(
        from days: [ClaudeDay],
        dayCount: Int,
        now: Date
    ) -> [DayUptime] {
        let today = calendar.startOfDay(for: now)
        var byDate: [Date: IncidentImpact?] = [:]
        for day in days {
            guard let parsed = ServiceStatusClient.parseDate(day.date) else { continue }
            let key = calendar.startOfDay(for: parsed)
            byDate[key] = ServiceStatusClient.claudeOutageImpact(day.outages)
        }
        var result: [DayUptime] = []
        for offset in stride(from: dayCount - 1, through: 0, by: -1) {
            guard let d = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let value = byDate[d] ?? nil
            result.append(DayUptime(date: d, worstImpact: value))
        }
        return result
    }

    private nonisolated static func claudeOutageImpact(_ outages: [String: Int]) -> IncidentImpact? {
        if outages.isEmpty { return nil }
        // Statuspage codes: m = minor (degraded), p = partial outage, M/c = major/critical, n = none
        if outages["c"] != nil || outages["M"] != nil { return .critical }
        if outages["p"] != nil { return .major }
        if outages["m"] != nil { return .minor }
        if outages["n"] != nil { return nil }
        return .minor  // unknown code, conservative
    }

    private nonisolated static func parseDate(_ raw: String) -> Date? {
        if let d = flexibleDate(from: raw) { return d }
        // YYYY-MM-DD format
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: raw)
    }

    private func computeUptime(_ days: [DayUptime]) -> Double {
        guard !days.isEmpty else { return 0 }
        let clean = days.filter { $0.worstImpact == nil }.count
        return Double(clean) / Double(days.count) * 100
    }

    private func computeClaudeUptime(_ days: [ClaudeDay], dayCount: Int) -> Double {
        // Statuspage uptime: 100 - (total_outage_seconds / total_window_seconds) * 100
        // Outage values in `days[].outages` dict are in seconds.
        let windowSeconds = Double(dayCount) * 86400.0
        guard windowSeconds > 0 else { return 0 }
        var totalOutage: Double = 0
        for day in days {
            for (_, secs) in day.outages {
                totalOutage += Double(secs)
            }
        }
        let pct = max(0, min(100, (1.0 - totalOutage / windowSeconds) * 100))
        return pct
    }

    // MARK: - Date helpers

    nonisolated static func flexibleDate(from raw: String) -> Date? {
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFractional.date(from: raw) { return date }

        let isoStandard = ISO8601DateFormatter()
        isoStandard.formatOptions = [.withInternetDateTime]
        if let date = isoStandard.date(from: raw) { return date }
        return nil
    }

    // MARK: - Claude HTML scraping

    private nonisolated func parseClaudeUptimeData(html: String) -> [String: ClaudeUptimeEntry] {
        guard let range = html.range(of: "var uptimeData = ") else { return [:] }
        let after = html[range.upperBound...]
        guard let json = ServiceStatusClient.extractJSONObject(in: after) else { return [:] }
        guard let data = json.data(using: .utf8) else { return [:] }
        do {
            return try JSONDecoder().decode([String: ClaudeUptimeEntry].self, from: data)
        } catch {
            return [:]
        }
    }

    private nonisolated static func extractJSONObject(in input: Substring) -> String? {
        var depth = 0
        var inString = false
        var escape = false
        var seenStart = false
        var startIdx: String.Index?
        var endIdx: String.Index?
        for idx in input.indices {
            let ch = input[idx]
            if escape { escape = false; continue }
            if ch == "\\" { escape = true; continue }
            if ch == "\"" { inString.toggle(); continue }
            if inString { continue }
            if ch == "{" {
                if !seenStart { startIdx = idx; seenStart = true }
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    endIdx = input.index(after: idx)
                    break
                }
            }
        }
        guard let s = startIdx, let e = endIdx else { return nil }
        return String(input[s..<e])
    }

    // MARK: - OpenAI HTML scraping

    private nonisolated static func combinedNextChunks(html: String) -> String {
        let pattern = #"self\.__next_f\.push\(\[1,\s*"((?:[^"\\]|\\.)*)"\]\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return ""
        }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        var combined = ""
        regex.enumerateMatches(in: html, options: [], range: nsRange) { match, _, _ in
            guard let m = match, m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: html) else { return }
            let raw = String(html[r])
            // unescape JS string: \" -> ", \\ -> \, \n -> newline
            let unescaped = raw
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\u003c", with: "<")
                .replacingOccurrences(of: "\\u003e", with: ">")
                .replacingOccurrences(of: "\\u0026", with: "&")
            combined.append(unescaped)
        }
        return combined
    }

    private nonisolated static func parseOpenAIGroups(combined: String) -> [ServiceComponentGroup] {
        // Group definitions look like:
        //   "display_aggregated_uptime":true,"hidden":false,"id":"<id>","name":"<name>"
        // The marker "display_aggregated_uptime":true is the reliable anchor.
        var seen = Set<String>()
        var groups: [ServiceComponentGroup] = []
        let anchor = "\"display_aggregated_uptime\":true"
        var search = combined.startIndex..<combined.endIndex
        while let range = combined.range(of: anchor, range: search) {
            let windowEnd = combined.index(range.upperBound, offsetBy: 400, limitedBy: combined.endIndex) ?? combined.endIndex
            let window = combined[range.upperBound..<windowEnd]
            if let id = extractStringField(in: window, key: "id"),
               let name = extractStringField(in: window, key: "name"),
               id != "$undefined" {
                if seen.insert(id).inserted {
                    groups.append(ServiceComponentGroup(id: id, name: name))
                }
            }
            search = range.upperBound..<combined.endIndex
        }
        return groups
    }

    private nonisolated static func parseOpenAIComponentGroupMap(
        combined: String,
        groups: [ServiceComponentGroup]
    ) -> [String: String] {
        // Each group block is laid out as
        //   {component_records... components_array_for_THIS_group} {anchor_for_THIS_group}
        // so a group's components array is the LAST "components":[ ... ] BEFORE its anchor.
        var map: [String: String] = [:]
        let anchor = "\"display_aggregated_uptime\":true"
        var anchorPositions: [(position: String.Index, end: String.Index)] = []
        var search = combined.startIndex..<combined.endIndex
        while let r = combined.range(of: anchor, range: search) {
            anchorPositions.append((r.lowerBound, r.upperBound))
            search = r.upperBound..<combined.endIndex
        }
        for (i, pos) in anchorPositions.enumerated() {
            // Read group id from a window after the anchor
            let idWindowEnd = combined.index(pos.end, offsetBy: 400, limitedBy: combined.endIndex) ?? combined.endIndex
            guard let gid = extractStringField(in: combined[pos.end..<idWindowEnd], key: "id"), gid != "$undefined" else { continue }
            // Slice from previous anchor (or start) up to current anchor
            let sliceStart = i == 0 ? combined.startIndex : anchorPositions[i - 1].end
            let sliceEnd = pos.position
            let slice = combined[sliceStart..<sliceEnd]
            // Find the LAST "components":[ in the slice
            guard let arrayHeader = slice.range(of: "\"components\":[", options: .backwards) else { continue }
            let arrayStart = arrayHeader.upperBound
            var depth = 1
            var inString = false
            var escape = false
            var endIndex = arrayStart
            for idx in slice[arrayStart...].indices {
                let ch = slice[idx]
                if escape { escape = false; continue }
                if ch == "\\" { escape = true; continue }
                if ch == "\"" { inString.toggle(); continue }
                if inString { continue }
                if ch == "[" { depth += 1 }
                else if ch == "]" {
                    depth -= 1
                    if depth == 0 { endIndex = idx; break }
                }
            }
            let arraySlice = slice[arrayStart..<endIndex]
            for cid in matches(in: String(arraySlice), pattern: "\"component_id\":\"([0-9A-Z]{20,})\"") {
                map[cid] = gid
            }
        }
        return map
    }

    private nonisolated static func extractStringField(in window: Substring, key: String) -> String? {
        let needle = "\"" + key + "\":\""
        guard let r = window.range(of: needle) else { return nil }
        let start = r.upperBound
        guard let endQuote = window[start...].firstIndex(of: "\"") else { return nil }
        return String(window[start..<endQuote])
    }

    private nonisolated static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let ns = NSRange(text.startIndex..<text.endIndex, in: text)
        var out: [String] = []
        regex.enumerateMatches(in: text, options: [], range: ns) { match, _, _ in
            guard let m = match, m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return }
            out.append(String(text[r]))
        }
        return out
    }

    private nonisolated static func parseOpenAIComponentUptime(combined: String) -> [String: Double] {
        // Pattern: "component_id":"<cid>", ...,"uptime":"99.99"
        var map: [String: Double] = [:]
        let p1 = #""component_id":"([0-9A-Z]{20,})"[^{}]{0,400}"uptime":"(\d{1,3}(?:\.\d+)?)""#
        if let r1 = try? NSRegularExpression(pattern: p1, options: []) {
            let ns = NSRange(combined.startIndex..<combined.endIndex, in: combined)
            r1.enumerateMatches(in: combined, options: [], range: ns) { m, _, _ in
                guard let m = m,
                      let cR = Range(m.range(at: 1), in: combined),
                      let uR = Range(m.range(at: 2), in: combined) else { return }
                let cid = String(combined[cR])
                if let v = Double(String(combined[uR])) {
                    map[cid] = v
                }
            }
        }
        return map
    }

    private nonisolated static func parseOpenAIPerComponentIncidents(combined: String) -> [String: [(start: Date, end: Date, impact: IncidentImpact)]] {
        // Pattern: incident records with component_id, start_at, end_at, status
        var map: [String: [(start: Date, end: Date, impact: IncidentImpact)]] = [:]
        let pattern = #""component_id":"([0-9A-Z]{20,})"[^{}]{0,400}"start_at":"([^"]+)"[^{}]{0,400}"status":"([a-z_]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [:] }
        let ns = NSRange(combined.startIndex..<combined.endIndex, in: combined)
        regex.enumerateMatches(in: combined, options: [], range: ns) { match, _, _ in
            guard let m = match,
                  let cR = Range(m.range(at: 1), in: combined),
                  let sR = Range(m.range(at: 2), in: combined),
                  let stR = Range(m.range(at: 3), in: combined) else { return }
            let cid = String(combined[cR])
            let startStr = String(combined[sR])
            let status = String(combined[stR])
            guard let start = flexibleDate(from: startStr) else { return }
            // Try to find end_at near this same record
            var end = Date()
            if let endRange = combined.range(of: "\"end_at\":\"", range: m.range(at: 0).location < combined.utf16.count ? Range(m.range, in: combined) : nil) {
                let after = combined[endRange.upperBound...]
                if let quote = after.firstIndex(of: "\"") {
                    let endStr = String(after[..<quote])
                    if let parsed = flexibleDate(from: endStr) { end = parsed }
                }
            }
            let impact = ServiceStatusClient.openAIStatusImpact(status)
            map[cid, default: []].append((start: start, end: end, impact: impact))
        }
        return map
    }

    private nonisolated static func openAIStatusImpact(_ status: String) -> IncidentImpact {
        switch status {
        case "operational":         return .none
        case "under_maintenance":   return .maintenance
        case "degraded_performance": return .minor
        case "partial_outage":      return .major
        case "major_outage", "full_outage": return .critical
        default:                    return .minor
        }
    }
}

public enum ServiceStatusError: Error, Sendable {
    case badResponse
}

// MARK: - Statuspage v2 DTOs (still used for current status + recent incidents)

private struct SummaryDTO: Decodable {
    struct Page: Decodable { let id: String; let name: String; let updated_at: Date }
    struct Status: Decodable { let indicator: StatusIndicator; let description: String }
    struct Component: Decodable {
        let id: String
        let name: String
        let status: ComponentStatusLevel
        let group_id: String?
        let group: Bool?
    }
    let page: Page
    let status: Status
    let components: [Component]
}

private struct ComponentsDTO: Decodable {
    struct Component: Decodable {
        let id: String
        let name: String
        let status: ComponentStatusLevel
        let group_id: String?
        let group: Bool?
    }
    let components: [Component]
}

private struct IncidentsDTO: Decodable {
    struct Incident: Decodable {
        let id: String
        let name: String
        let impact: IncidentImpact
        let created_at: Date
        let resolved_at: Date?
        let shortlink: URL?
    }
    let incidents: [Incident]
}

// MARK: - Claude scraped uptime DTOs

private struct ClaudeUptimeEntry: Decodable {
    let component: ClaudeComponentMeta
    let days: [ClaudeDay]
}

private struct ClaudeComponentMeta: Decodable {
    let code: String
    let name: String
}

private struct ClaudeDay: Decodable {
    let date: String
    let outages: [String: Int]
}
