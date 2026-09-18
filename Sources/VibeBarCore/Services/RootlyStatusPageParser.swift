import Foundation

/// Mistral AI's status page, which moved from Checkly to Rootly in 2026-09.
///
/// Rootly publishes the page state as JSON (`/api/v1/status.json`, the same
/// `{indicator, description}` shape Statuspage uses) but not its services: the
/// per-service rows, their 90-day bars and their uptime percentages only exist
/// in the page's own HTML, one `<details>` card per service holding a
/// `turbo-frame` whose SVG draws a rect per day.
///
/// Everything here is a pure function over that markup, so the shapes are
/// pinned by fixtures rather than by a live page.
enum RootlyStatusPageParser {
    /// `/api/v1/status.json`. The `page.updated_at` is when Rootly last
    /// rebuilt the page, not when a service changed.
    struct StatusDTO: Decodable {
        struct Page: Decodable {
            let name: String?
            let updated_at: Date?
        }

        struct Status: Decodable {
            let indicator: StatusIndicator?
            let description: String?
        }

        struct Incident: Decodable {
            let id: String?
            let name: String?
            let impact: IncidentImpact?
            let status: String?
            let created_at: Date?
            let resolved_at: Date?
            let shortlink: String?
            let url: String?
        }

        let page: Page?
        let status: Status?
        let incidents: [Incident]?
    }

    /// One service card: its name, the words beside it, and the bars.
    struct Service {
        let id: String
        let name: String
        let statusText: String
        let uptimePercent: Double?
        /// Oldest first, one per drawn day.
        let dayImpacts: [IncidentImpact?]
    }

    static func snapshot(
        tool: ToolType,
        html: String,
        status: StatusDTO?,
        dayCount: Int,
        now: Date
    ) throws -> ServiceStatusSnapshot {
        let services = parseServices(html: html)
        guard !services.isEmpty || status != nil else { throw ServiceStatusError.badResponse }

        let components = services.map { service in
            ServiceComponentSummary(
                id: service.id,
                name: service.name,
                status: componentStatus(fromText: service.statusText),
                groupId: nil,
                uptimePercent: service.uptimePercent,
                recentDays: days(from: service.dayImpacts, dayCount: dayCount, now: now)
            )
        }

        let worst = components.map(\.status).max { $0.severity < $1.severity } ?? .operational
        // The page's own indicator wins when it has one: it is what the page
        // itself says at the top, and it accounts for incidents that no single
        // service row reflects.
        let indicator = status?.status?.indicator ?? xAIIndicator(for: worst)

        let incidents: [IncidentSummary] = (status?.incidents ?? []).compactMap { incident in
            guard let id = incident.id, let name = incident.name, let createdAt = incident.created_at else {
                return nil
            }
            let resolved = (incident.status ?? "").lowercased().contains("resolved")
            return IncidentSummary(
                id: id,
                name: name,
                impact: incident.impact ?? .minor,
                createdAt: createdAt,
                resolvedAt: incident.resolved_at ?? (resolved ? createdAt : nil),
                url: (incident.shortlink ?? incident.url).flatMap(URL.init(string:)) ?? tool.statusPageURL
            )
        }

        return ServiceStatusSnapshot(
            tool: tool,
            indicator: indicator,
            description: status?.status?.description ?? "",
            updatedAt: status?.page?.updated_at ?? now,
            groups: [],
            components: components,
            recentIncidents: Array(incidents.sorted { $0.createdAt > $1.createdAt }.prefix(4))
        )
    }

    // MARK: - Services

    /// Each service is a `turbo-frame id="uptime-chart-<id>"`. The name and
    /// the status words sit in the `<summary>` just above it, and the bars and
    /// the percentage inside it.
    static func parseServices(html: String) -> [Service] {
        var services: [Service] = []
        var searchStart = html.startIndex
        let frameMarker = "<turbo-frame id=\"uptime-chart-"

        while let frameRange = html.range(of: frameMarker, range: searchStart..<html.endIndex) {
            let afterID = frameRange.upperBound
            guard let idEnd = html.range(of: "\"", range: afterID..<html.endIndex) else { break }
            let id = String(html[afterID..<idEnd.lowerBound])
            let frameEnd = html.range(of: "</turbo-frame>", range: idEnd.upperBound..<html.endIndex)?.lowerBound
                ?? html.endIndex
            let frame = html[idEnd.upperBound..<frameEnd]
            let header = html[searchStart..<frameRange.lowerBound]
            searchStart = frameEnd

            guard let name = lastTagText("h2", in: header), !name.isEmpty else { continue }
            services.append(
                Service(
                    id: id.isEmpty ? name : id,
                    name: name,
                    statusText: lastTagText("span", in: header) ?? "",
                    uptimePercent: percent(in: frame),
                    dayImpacts: dayImpacts(in: frame)
                )
            )
        }
        return services
    }

    /// The text of the last `<tag …>text</tag>` in a fragment, tags stripped.
    private static func lastTagText(_ tag: String, in fragment: Substring) -> String? {
        var result: String?
        var search = fragment.startIndex
        while let open = fragment.range(of: "<\(tag)", range: search..<fragment.endIndex) {
            guard let openEnd = fragment.range(of: ">", range: open.upperBound..<fragment.endIndex),
                  let close = fragment.range(of: "</\(tag)>", range: openEnd.upperBound..<fragment.endIndex)
            else { break }
            let text = ServiceStatusClient.strippingTags(String(fragment[openEnd.upperBound..<close.lowerBound]))
            if !text.isEmpty { result = text }
            search = close.upperBound
        }
        return result
    }

    /// The `99.93%` between "90 days ago" and "Today".
    private static func percent(in frame: Substring) -> Double? {
        var search = frame.startIndex
        while let open = frame.range(of: "<span", range: search..<frame.endIndex) {
            guard let openEnd = frame.range(of: ">", range: open.upperBound..<frame.endIndex),
                  let close = frame.range(of: "</span>", range: openEnd.upperBound..<frame.endIndex)
            else { return nil }
            let text = frame[openEnd.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            search = close.upperBound
            guard text.hasSuffix("%"), let value = Double(text.dropLast()) else { continue }
            return value
        }
        return nil
    }

    /// One impact per drawn day, oldest first.
    ///
    /// Each day is drawn as a coloured rect; the hover target stacked on top
    /// of it carries the day's index but no fill of its own, so the coloured
    /// rects in document order are exactly the days.
    private static func dayImpacts(in frame: Substring) -> [IncidentImpact?] {
        var impacts: [IncidentImpact?] = []
        var search = frame.startIndex
        while let open = frame.range(of: "<rect", range: search..<frame.endIndex) {
            let close = frame.range(of: ">", range: open.upperBound..<frame.endIndex)?.upperBound
                ?? frame.endIndex
            let rect = frame[open.lowerBound..<close]
            search = close
            guard let color = firstHexColor(in: rect) else { continue }
            impacts.append(impact(ofColor: color))
        }
        return impacts
    }

    /// Rootly draws a green day for uptime and a red one for an outage; an
    /// amber day is a partial one. Anything else — including the gray it uses
    /// before a service existed — is "nothing recorded".
    private static func impact(ofColor value: Int) -> IncidentImpact? {
        let red = Double((value >> 16) & 0xFF)
        let green = Double((value >> 8) & 0xFF)
        let blue = Double(value & 0xFF)
        // A gray (or near-white/black) day has no hue to read: it is a date the
        // service did not exist yet, not a degraded one.
        if max(red, green, blue) - min(red, green, blue) < 40 { return nil }
        if green > red, green > blue { return nil }
        if red > green * 1.6 { return .major }
        if red >= green * 0.9 { return .minor }
        return nil
    }

    private static func firstHexColor(in fragment: Substring) -> Int? {
        var search = fragment.startIndex
        while let hash = fragment.range(of: "#", range: search..<fragment.endIndex) {
            search = hash.upperBound
            let hex = fragment[hash.upperBound...].prefix(6).lowercased()
            guard hex.count == 6, hex.allSatisfy(\.isHexDigit), let value = Int(hex, radix: 16) else { continue }
            return value
        }
        return nil
    }

    private static func days(
        from impacts: [IncidentImpact?],
        dayCount: Int,
        now: Date
    ) -> [DayUptime] {
        guard !impacts.isEmpty else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let today = calendar.startOfDay(for: now)
        // The page draws its own window; keep the newest `dayCount` of it so a
        // 30-day card and a 90-day card both end today.
        let kept = impacts.suffix(dayCount)
        return kept.enumerated().compactMap { offset, impact in
            let daysBack = kept.count - 1 - offset
            guard let date = calendar.date(byAdding: .day, value: -daysBack, to: today) else { return nil }
            return DayUptime(date: date, worstImpact: impact)
        }
    }

    static func componentStatus(fromText raw: String) -> ComponentStatusLevel {
        let text = raw.lowercased()
        if text.contains("maintenance") { return .underMaintenance }
        if text.contains("major") { return .majorOutage }
        if text.contains("partial") { return .partialOutage }
        if text.contains("degraded") || text.contains("degradation") { return .degradedPerformance }
        if text.contains("outage") || text.contains("down") { return .majorOutage }
        return .operational
    }

    private static func xAIIndicator(for status: ComponentStatusLevel) -> StatusIndicator {
        switch status {
        case .operational: .none
        case .degradedPerformance: .minor
        case .partialOutage: .major
        case .majorOutage: .critical
        case .underMaintenance: .maintenance
        }
    }
}
