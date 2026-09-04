import Foundation

public actor ServiceStatusClient {
    private let session: URLSession

    /// Every provider publishes its day buckets in UTC, so all of the day
    /// math here shares one calendar rather than each parser building its own.
    private nonisolated static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(
        tool: ToolType,
        dayCount: Int = 90,
        now: Date = Date()
    ) async throws -> ServiceStatusSnapshot {
        switch tool {
        case .codex:  return try await fetchOpenAI(dayCount: dayCount, now: now)
        case .claude:
            return try await fetchClassicStatuspage(tool: .claude, dayCount: dayCount, now: now)
        case .gemini, .antigravity:
            // Both Gemini and Antigravity live under the same Google
            // Apps Status product (id `npdyhgECDJ6tB66MxXyo` =
            // "Gemini"), so they share one feed.
            return try await fetchGoogleAppsStatus(tool: tool, dayCount: dayCount, now: now)
        case .grok:
            return try await fetchXAIStatus(dayCount: dayCount, now: now)
        case .cursor:
            return try await fetchClassicStatuspage(tool: .cursor, dayCount: dayCount, now: now)
        case .alibaba, .alibabaTokenPlan, .copilot, .zai, .minimax, .kimi, .mimo, .iflytek, .tencentHunyuan, .tencentTokenPlan, .volcengine, .volcengineAgentPlan, .baiduQianfan, .openCodeGo, .kilo, .kiro, .ollama, .openRouter, .warp:
            // Misc providers don't expose known machine-readable status APIs.
            // `tool.supportsStatusPage` is `false` for all of them, and
            // upstream callers should already be filtering to primary
            // tools via `tool.supportsStatusPage` before reaching here.
            // We return an empty `none`-indicator snapshot rather than
            // throwing so any straggler call site fails closed instead
            // of crashing.
            return ServiceStatusSnapshot(
                tool: tool,
                indicator: .none,
                // A diagnostic marker, not rendered copy: `supportsStatusPage`
                // is false for every tool in this list, so no surface reaches
                // this snapshot. Left in English deliberately — translating a
                // string only a developer can ever see buys nothing.
                description: "Status page polling is not supported for this provider.",
                updatedAt: now,
                groups: [],
                components: [],
                recentIncidents: []
            )
        }
    }

    // MARK: - xAI Status (HTML status.x.ai)

    private static let xAIComponentPageSpecs: [(id: String, name: String, path: String)] = [
        ("grok-com", "Grok (Web)", "grok-com"),
        ("ios-app", "Grok (iOS)", "ios-app"),
        ("android-app", "Grok (Android)", "android-app"),
        ("grok-in-x", "Grok in X", "grok-in-x"),
        ("api-us-east-1", "API (us-east-1.api.x.ai)", "api-us-east-1"),
        ("api-eu-west-1", "API (eu-west-1.api.x.ai)", "api-eu-west-1"),
        ("api-console", "API Console", "api-console")
    ]

    private func fetchXAIStatus(dayCount: Int, now: Date) async throws -> ServiceStatusSnapshot {
        let overviewHTML = try await fetchHTML(url: ToolType.grok.statusPageURL)
        var componentPages: [(id: String, name: String, url: URL, html: String)] = []
        for spec in Self.xAIComponentPageSpecs {
            guard let url = URL(string: spec.path, relativeTo: ToolType.grok.statusPageURL)?.absoluteURL else {
                continue
            }
            if let html = try? await fetchHTML(url: url) {
                componentPages.append((id: spec.id, name: spec.name, url: url, html: html))
            }
        }
        return Self.parseXAIStatusPages(
            tool: .grok,
            overviewHTML: overviewHTML,
            componentPages: componentPages,
            dayCount: dayCount,
            now: now
        )
    }

    nonisolated static func parseXAIStatusPages(
        tool: ToolType,
        overviewHTML: String,
        componentPages: [(id: String, name: String, url: URL, html: String)],
        dayCount: Int,
        now: Date
    ) -> ServiceStatusSnapshot {
        let parsedComponents = componentPages.map { page in
            parseXAIComponentPage(
                id: page.id,
                name: page.name,
                url: page.url,
                html: page.html,
                dayCount: dayCount,
                now: now
            )
        }
        let detailedComponents = parsedComponents.map(\.component)
        let detailedNames = Set(detailedComponents.map { xAISlug($0.name) })
        // Every component page is an independent request. Keep the richer
        // history for pages that succeeded, then backfill any failed request
        // from the all-components overview so its outage status is not lost.
        let overviewFallbacks = parseXAIOverviewComponents(
            overviewHTML,
            dayCount: dayCount,
            now: now
        ).filter { !detailedNames.contains(xAISlug($0.name)) }
        let components = detailedComponents + overviewFallbacks

        let recentIncidents = parsedComponents
            .flatMap(\.incidents)
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(4)
            .map { $0 }

        let worstStatus = components.map(\.status).max { $0.severity < $1.severity } ?? .operational
        let indicator = xAIIndicator(for: worstStatus)

        // Every incident this parser emits comes from a "Resolved · Duration:"
        // row, so `resolvedAt` is never nil and an empty result means there
        // were no incidents at all.
        let updatedAt = recentIncidents.compactMap(\.resolvedAt).max() ?? now

        return ServiceStatusSnapshot(
            tool: tool,
            indicator: indicator,
            // status.x.ai publishes component tiles and nothing that reads
            // like a sentence, so there is no provider wording to carry.
            // Empty, not our own summary: `description` is persisted, and a
            // translated string cached here would outlive a language change.
            // `effectiveDescription` derives our words on read.
            description: "",
            updatedAt: updatedAt,
            groups: [],
            components: components,
            recentIncidents: Array(recentIncidents)
        )
    }

    private nonisolated static func parseXAIComponentPage(
        id: String,
        name: String,
        url: URL,
        html: String,
        dayCount: Int,
        now: Date
    ) -> (component: ServiceComponentSummary, incidents: [IncidentSummary]) {
        let lines = visibleTextLines(fromHTML: html)
        let status = xAIComponentStatus(from: lines)
        let incidents = parseXAIIncidents(
            text: lines.joined(separator: " "),
            componentId: id,
            url: url
        )
        let dayBuckets = buildDayBuckets(
            from: incidents.map { incident in
                (start: incident.createdAt, end: incident.resolvedAt ?? now, impact: incident.impact)
            },
            dayCount: dayCount,
            now: now
        )
        let component = ServiceComponentSummary(
            id: id,
            name: name,
            status: status,
            groupId: nil,
            uptimePercent: computeUptime(dayBuckets),
            recentDays: dayBuckets
        )
        return (component, incidents)
    }

    private nonisolated static func parseXAIOverviewComponents(
        _ html: String,
        dayCount: Int,
        now: Date
    ) -> [ServiceComponentSummary] {
        let lines = visibleTextLines(fromHTML: html)
        // The overview lists one row per service as "<name> <word>", so the
        // trailing vocabulary word is the status and everything before it is
        // the name.
        let services = lines.compactMap { line -> (name: String, status: ComponentStatusLevel)? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = trimmed.lowercased()
            guard let token = xAIStatusVocabulary.first(where: {
                $0.endsAnOverviewRow && lowered.hasSuffix(" \($0.token)")
            }) else { return nil }
            let name = String(trimmed.dropLast(token.token.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return (name, token.level)
        }
        return services.map { service in
            ServiceComponentSummary(
                id: xAISlug(service.name),
                name: service.name,
                status: service.status,
                groupId: nil,
                uptimePercent: service.status == .operational ? 100 : nil,
                recentDays: buildDayBuckets(from: [], dayCount: dayCount, now: now)
            )
        }
    }

    private nonisolated static func parseXAIIncidents(
        text: String,
        componentId: String,
        url: URL
    ) -> [IncidentSummary] {
        let normalized = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let pattern = #"([A-Z][a-z]{2} \d{1,2}, \d{4}, \d{2}:\d{2} [AP]M UTC)\s+(.+?)\s+Resolved\s+·\s+Duration:\s+(.+?)\s+·\s+(info|disruption|outage)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        var incidents: [IncidentSummary] = []
        regex.enumerateMatches(in: normalized, options: [], range: range) { match, _, _ in
            guard let match,
                  let dateRange = Range(match.range(at: 1), in: normalized),
                  let nameRange = Range(match.range(at: 2), in: normalized),
                  let durationRange = Range(match.range(at: 3), in: normalized),
                  let impactRange = Range(match.range(at: 4), in: normalized),
                  let createdAt = parseXAIStatusDate(String(normalized[dateRange]))
            else { return }
            let name = String(normalized[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let impact = xAIIncidentImpact(String(normalized[impactRange]))
            let duration = parseXAIDuration(String(normalized[durationRange]))
            incidents.append(
                IncidentSummary(
                    id: "\(componentId)-\(Int(createdAt.timeIntervalSince1970))-\(xAISlug(name))",
                    name: name,
                    impact: impact,
                    createdAt: createdAt,
                    resolvedAt: createdAt.addingTimeInterval(duration),
                    url: url
                )
            )
        }
        return incidents
    }

    nonisolated static func parseXAIStatusDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM d, yyyy, hh:mm a 'UTC'"
        return formatter.date(from: raw)
    }

    /// Sum of every "<number> <unit>" the duration text spells out. An
    /// unparseable duration is 0 — the caller only ever adds it to the
    /// incident's start, so an unresolvable text and a zero-length incident
    /// are the same answer.
    nonisolated static func parseXAIDuration(_ raw: String) -> TimeInterval {
        let pattern = #"(\d+(?:\.\d+)?)\s*(days?|hours?|minutes?|seconds?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return 0
        }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        var total: TimeInterval = 0
        regex.enumerateMatches(in: raw, options: [], range: range) { match, _, _ in
            guard let match,
                  let valueRange = Range(match.range(at: 1), in: raw),
                  let unitRange = Range(match.range(at: 2), in: raw),
                  let value = Double(raw[valueRange]),
                  value.isFinite,
                  value >= 0
            else { return }
            let unit = raw[unitRange].lowercased()
            let multiplier: TimeInterval
            if unit.hasPrefix("day") {
                multiplier = 86_400
            } else if unit.hasPrefix("hour") {
                multiplier = 3_600
            } else if unit.hasPrefix("minute") {
                multiplier = 60
            } else {
                multiplier = 1
            }
            total += value * multiplier
        }
        return total
    }

    private struct XAIStatusToken {
        let token: String
        let level: ComponentStatusLevel
        /// Most tokens are phrases matched anywhere in a component page's
        /// prose. The two halves of the available/unavailable pair are not:
        /// "available" is a suffix of "unavailable", so they only count as a
        /// line's final word.
        let matchesAnywhere: Bool
        /// Also part of the vocabulary that terminates an all-components
        /// overview row.
        let endsAnOverviewRow: Bool

        init(
            _ token: String,
            _ level: ComponentStatusLevel,
            matchesAnywhere: Bool = true,
            endsAnOverviewRow: Bool = false
        ) {
            self.token = token
            self.level = level
            self.matchesAnywhere = matchesAnywhere
            self.endsAnOverviewRow = endsAnOverviewRow
        }

        func matches(_ line: String) -> Bool {
            matchesAnywhere
                ? line.contains(token)
                : (line == token || line.hasSuffix(" \(token)"))
        }
    }

    /// status.x.ai writes health as prose rather than a machine-readable
    /// status, and the same vocabulary appears on the per-component pages and
    /// on the all-components overview. **Order is load-bearing** — the first
    /// hit wins, so the specific phrasings must precede the bare words they
    /// contain ("service unavailable" before "unavailable") and "maintenance"
    /// / "degraded" must precede "available", or "Under maintenance —
    /// service available shortly" would read as fully operational.
    private nonisolated static let xAIStatusVocabulary: [XAIStatusToken] = [
        XAIStatusToken("service fully operational", .operational),
        XAIStatusToken("not aware of any issues", .operational),
        XAIStatusToken("major outage", .majorOutage),
        XAIStatusToken("service unavailable", .majorOutage),
        XAIStatusToken("unavailable", .majorOutage, matchesAnywhere: false, endsAnOverviewRow: true),
        XAIStatusToken("partial outage", .partialOutage),
        XAIStatusToken("maintenance", .underMaintenance, endsAnOverviewRow: true),
        XAIStatusToken("degraded", .degradedPerformance, endsAnOverviewRow: true),
        XAIStatusToken("disruption", .degradedPerformance),
        XAIStatusToken("available", .operational, matchesAnywhere: false, endsAnOverviewRow: true)
    ]

    private nonisolated static func xAIComponentStatus(from lines: [String]) -> ComponentStatusLevel {
        // Status appears before Past Issues. Parse each visible line in order
        // so a historical incident cannot override the current status.
        for rawLine in lines.prefix(12) {
            let line = rawLine.lowercased()
            if let hit = xAIStatusVocabulary.first(where: { $0.matches(line) }) {
                return hit.level
            }
        }
        return .operational
    }

    private nonisolated static func xAIIncidentImpact(_ raw: String) -> IncidentImpact {
        switch raw.lowercased() {
        case "outage": return .critical
        case "disruption": return .minor
        case "info": return .minor
        default: return .minor
        }
    }

    private nonisolated static func xAIIndicator(for status: ComponentStatusLevel) -> StatusIndicator {
        switch status {
        case .operational: return .none
        case .underMaintenance: return .maintenance
        case .degradedPerformance: return .minor
        case .partialOutage: return .major
        case .majorOutage: return .critical
        }
    }

    private nonisolated static func visibleTextLines(fromHTML html: String) -> [String] {
        var text = html
            .replacingOccurrences(of: "(?is)<script.*?</script>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "(?is)<style.*?</style>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&middot;", with: "·")
            .replacingOccurrences(of: "&#183;", with: "·")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "\\s*\\n\\s*", with: "\n", options: .regularExpression)
        return text
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private nonisolated static func xAISlug(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return raw.lowercased().unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        .reduce(into: "") { result, ch in
            if ch == "-", result.last == "-" { return }
            result.append(ch)
        }
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - Google Apps Status (incidents.json + products.json)

    /// Product id for Gemini on Google's Workspace Status dashboard.
    /// Confirmed against `https://www.google.com/appsstatus/dashboard/products.json`
    /// on 2026-05-22. Gemini Web and AntiGravity currently share this
    /// Google status product entry — Google hasn't split them out.
    private static let googleGeminiProductId = "npdyhgECDJ6tB66MxXyo"
    private static let googleIncidentsURL = URL(string: "https://www.google.com/appsstatus/dashboard/incidents.json")!

    private func fetchGoogleAppsStatus(
        tool: ToolType,
        dayCount: Int,
        now: Date
    ) async throws -> ServiceStatusSnapshot {
        let raw = try await fetchJSON([GoogleAppsIncident].self, from: Self.googleIncidentsURL)
        let geminiIncidents = raw.filter { incident in
            if incident.service_key == Self.googleGeminiProductId { return true }
            return incident.affected_products?.contains(where: { $0.id == Self.googleGeminiProductId }) ?? false
        }

        let impacts: [(start: Date, end: Date, impact: IncidentImpact)] = geminiIncidents.compactMap { incident in
            guard let start = ServiceStatusClient.flexibleDate(from: incident.begin) else { return nil }
            let end = incident.end.flatMap(ServiceStatusClient.flexibleDate(from:)) ?? now
            return (start: start, end: end, impact: ServiceStatusClient.googleStatusImpact(incident))
        }

        let perDay = Self.buildDayBuckets(from: impacts, dayCount: dayCount, now: now)
        let uptime = Self.computeUptime(perDay)

        // The component summary for the dedicated card. Google's feed
        // doesn't expose per-subsystem health, so the single "Gemini"
        // component reflects the worst recent impact.
        let currentImpact = perDay.last?.worstImpact ?? .none
        let component = ServiceComponentSummary(
            id: Self.googleGeminiProductId,
            name: tool == .antigravity ? "Antigravity (shared Gemini status)" : "Gemini",
            status: currentImpact.componentStatus,
            groupId: nil,
            uptimePercent: uptime,
            recentDays: perDay
        )

        let recent: [IncidentSummary] = geminiIncidents
            .compactMap { incident -> (Date, IncidentSummary)? in
                guard let createdAt = ServiceStatusClient.flexibleDate(from: incident.created ?? incident.begin) else {
                    return nil
                }
                let resolvedAt = incident.end.flatMap(ServiceStatusClient.flexibleDate(from:))
                let summary = IncidentSummary(
                    id: incident.id,
                    name: incident.external_desc ?? incident.service_name ?? "Gemini incident",
                    impact: ServiceStatusClient.googleStatusImpact(incident),
                    createdAt: createdAt,
                    resolvedAt: resolvedAt,
                    url: incident.uri.flatMap { URL(string: "https://www.google.com/appsstatus/dashboard/\($0)") }
                )
                return (createdAt, summary)
            }
            .sorted { $0.0 > $1.0 }
            .prefix(4)
            .map { $0.1 }

        let topIndicator = currentImpact.indicator

        let mostRecentUpdate = geminiIncidents
            .compactMap { incident -> Date? in
                if let when = incident.most_recent_update?.when {
                    return ServiceStatusClient.flexibleDate(from: when)
                }
                return ServiceStatusClient.flexibleDate(from: incident.modified ?? incident.created ?? incident.begin)
            }
            .max() ?? now

        return ServiceStatusSnapshot(
            tool: tool,
            indicator: topIndicator,
            // The Google Apps Status feed carries incidents, not a
            // page-level blurb. Same reasoning as the xAI branch above:
            // leave it empty and let `effectiveDescription` say it.
            description: "",
            updatedAt: mostRecentUpdate,
            groups: [],
            components: [component],
            recentIncidents: Array(recent)
        )
    }

    private nonisolated static func googleStatusImpact(_ incident: GoogleAppsIncident) -> IncidentImpact {
        // Google publishes a free-text `status_impact` plus a
        // `severity` enum (low / medium / high / critical). Use
        // severity primarily; fall back to status_impact heuristics.
        switch incident.severity?.lowercased() {
        case "critical": return .critical
        case "high":     return .major
        case "medium":   return .minor
        case "low":      return .minor
        default: break
        }
        let impact = incident.status_impact?.uppercased() ?? ""
        if impact.contains("DISRUPT") || impact.contains("OUTAGE") { return .critical }
        if impact.contains("DEGRADED") || impact.contains("DELAY")  { return .minor }
        if impact.contains("MAINTENANCE") { return .maintenance }
        return .minor
    }

    // MARK: - Classic Statuspage (summary/incidents + embedded uptimeData)

    /// Classic Statuspage-hosted providers (status.claude.com,
    /// status.cursor.com) all publish the same three shapes: `summary.json`
    /// for current component health and page indicator, `incidents.json` for
    /// the incident feed, and a `window.uptimeData` blob inlined in the
    /// status page HTML. Only that HTML blob carries the 90-day per-component
    /// outage history — the v2 JSON APIs never expose it — so a provider that
    /// skips the scrape renders empty gray strips with no uptime percentage.
    /// Fetch all three and key the history off the same component ids the
    /// summary uses.
    private func fetchClassicStatuspage(
        tool: ToolType,
        dayCount: Int,
        now: Date
    ) async throws -> ServiceStatusSnapshot {
        let summary = try await fetchJSON(SummaryDTO.self, from: tool.statusSummaryAPI)
        let incidentsDTO = try await fetchJSON(IncidentsDTO.self, from: tool.statusIncidentsAPI)
        // The history blob is a scrape of a page we don't control, so treat it
        // as best-effort: a redesign or a blocked HTML request must still
        // leave the current status and the incident feed usable.
        let html = try? await fetchHTML(url: tool.statusPageURL)
        // `try?` must not swallow a cancelled refresh into a history-less
        // "success"; only ordinary scrape failures are best-effort.
        try Task.checkCancellation()
        let uptimeMap = html.map { Self.parseStatuspageUptimeData(html: $0) } ?? [:]

        // Grouped pages (a `group: true` row owns the `group_id` children);
        // claude.com and cursor.com are both flat today, so this yields [].
        let groups = summary.components.compactMap { raw -> ServiceComponentGroup? in
            guard raw.group == true else { return nil }
            return ServiceComponentGroup(id: raw.id, name: raw.name)
        }

        var components: [ServiceComponentSummary] = []
        for raw in summary.components where raw.group != true {
            // A missing history entry means the scrape didn't cover this
            // component. Leave uptime nil instead of synthesizing a 90-day
            // all-green wall that the official page would contradict.
            let rawDays = uptimeMap[raw.id]?.days
            components.append(
                ServiceComponentSummary(
                    id: raw.id,
                    name: raw.name,
                    status: raw.status,
                    groupId: raw.group_id,
                    uptimePercent: rawDays.map { Self.computeStatuspageUptime($0, dayCount: dayCount) },
                    recentDays: rawDays.map {
                        Self.buildStatuspageDays(from: $0, dayCount: dayCount, now: now)
                    } ?? []
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
            tool: tool,
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
            let perDay = Self.buildDayBuckets(
                from: perComponentIncidents[raw.id] ?? [],
                dayCount: dayCount,
                now: now
            )
            let uptime: Double? = uptimeMap[raw.id] ?? (perDay.isEmpty ? nil : Self.computeUptime(perDay))
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

    private nonisolated static func buildDayBuckets(
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

    private nonisolated static func buildStatuspageDays(
        from days: [StatuspageDay],
        dayCount: Int,
        now: Date
    ) -> [DayUptime] {
        let today = calendar.startOfDay(for: now)
        var byDate: [Date: IncidentImpact?] = [:]
        for day in days {
            guard let parsed = parseDate(day.date) else { continue }
            let key = calendar.startOfDay(for: parsed)
            byDate[key] = statuspageOutageImpact(day.outages)
        }
        var result: [DayUptime] = []
        for offset in stride(from: dayCount - 1, through: 0, by: -1) {
            guard let d = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let value = byDate[d] ?? nil
            result.append(DayUptime(date: d, worstImpact: value))
        }
        return result
    }

    private nonisolated static func statuspageOutageImpact(_ outages: [String: Int]) -> IncidentImpact? {
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

    private nonisolated static func computeUptime(_ days: [DayUptime]) -> Double {
        guard !days.isEmpty else { return 0 }
        let clean = days.filter { $0.worstImpact == nil }.count
        return Double(clean) / Double(days.count) * 100
    }

    private nonisolated static func computeStatuspageUptime(_ days: [StatuspageDay], dayCount: Int) -> Double {
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

    // MARK: - Classic Statuspage HTML scraping

    /// status.claude.com used to inline `var uptimeData = {…}`; it now ships
    /// `window.uptimeData = {…}` with `var uptimeData = window.uptimeData;`
    /// as an alias, which made the old single-anchor scrape silently return
    /// empty — every component rendered 100% all-green while the official
    /// page showed a month of degraded days. Try both anchors and accept the
    /// first occurrence that decodes to a non-empty map.
    ///
    /// status.cursor.com ships the byte-identical shape, keyed by the same
    /// component ids its `summary.json` uses, so both providers share this
    /// parser.
    nonisolated static func parseStatuspageUptimeData(html: String) -> [String: StatuspageUptimeEntry] {
        for anchor in ["window.uptimeData = ", "var uptimeData = "] {
            var search = html.startIndex..<html.endIndex
            while let range = html.range(of: anchor, range: search) {
                let after = html[range.upperBound...]
                if let json = ServiceStatusClient.extractJSONObject(in: after),
                   let data = json.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode([String: StatuspageUptimeEntry].self, from: data),
                   !decoded.isEmpty {
                    return decoded
                }
                search = range.upperBound..<html.endIndex
            }
        }
        return [:]
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

// MARK: - Classic Statuspage scraped uptime DTOs

struct StatuspageUptimeEntry: Decodable {
    let component: StatuspageComponentMeta
    let days: [StatuspageDay]
}

struct StatuspageComponentMeta: Decodable {
    let code: String
    let name: String
}

struct StatuspageDay: Decodable {
    let date: String
    let outages: [String: Int]
}

// MARK: - Google Apps Status DTOs

/// One element of `https://www.google.com/appsstatus/dashboard/incidents.json`.
/// All fields are optional because Google adds new keys over time —
/// dropping a key shouldn't break the whole decode.
private struct GoogleAppsIncident: Decodable {
    let id: String
    let number: String?
    let begin: String
    let end: String?
    let created: String?
    let modified: String?
    let external_desc: String?
    let service_key: String?
    let service_name: String?
    let severity: String?
    let status_impact: String?
    let uri: String?
    let affected_products: [GoogleAppsProduct]?
    let most_recent_update: GoogleAppsUpdate?
}

private struct GoogleAppsProduct: Decodable {
    let title: String?
    let id: String
}

private struct GoogleAppsUpdate: Decodable {
    let status: String?
    let when: String?
}
