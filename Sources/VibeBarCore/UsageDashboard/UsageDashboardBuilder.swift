import Foundation

/// Everything `UsageDashboardBuilder` reads. Plain values, so a test can
/// build one by hand and check every card's numbers without a database.
public struct UsageDashboardInputs: Sendable {
    public var query: UsageDashboardQuery
    public var now: Date
    public var calendar: Calendar
    /// The ledger read with the query's range, model and project, every
    /// harness included — the builder applies the harness filter itself.
    public var ledger: UsageLedgerDashboardFacts
    /// Whole-session ledger totals, for the session ids the ledger carries.
    public var ledgerSessions: [UsageLedgerDashboardFacts.SessionRow]
    /// Session ids with a detail row inside the query.
    public var ledgerSessionIDsInQuery: Set<String>
    /// Sessions active in the range, every harness (the builder filters).
    public var sessions: [SessionSummary]
    /// Fresh structure stats by source path.
    public var structures: [String: SessionStats]
    /// Fresh activity tallies by source path.
    public var activity: [String: SessionActivityTally]
    /// Source paths the background fill will not reach.
    public var unreachablePaths: Set<String>
    public var availableModels: [String]
    /// Project tokens for the range with no project filter, for the picker.
    public var projectOptions: [String: Int64]

    public init(
        query: UsageDashboardQuery,
        now: Date,
        calendar: Calendar = UsageDashboardCalendar.local,
        ledger: UsageLedgerDashboardFacts = UsageLedgerDashboardFacts(),
        ledgerSessions: [UsageLedgerDashboardFacts.SessionRow] = [],
        ledgerSessionIDsInQuery: Set<String> = [],
        sessions: [SessionSummary] = [],
        structures: [String: SessionStats] = [:],
        activity: [String: SessionActivityTally] = [:],
        unreachablePaths: Set<String> = [],
        availableModels: [String] = [],
        projectOptions: [String: Int64] = [:]
    ) {
        self.query = query
        self.now = now
        self.calendar = calendar
        self.ledger = ledger
        self.ledgerSessions = ledgerSessions
        self.ledgerSessionIDsInQuery = ledgerSessionIDsInQuery
        self.sessions = sessions
        self.structures = structures
        self.activity = activity
        self.unreachablePaths = unreachablePaths
        self.availableModels = availableModels
        self.projectOptions = projectOptions
    }
}

/// Turns `UsageDashboardInputs` into a `UsageDashboardSnapshot`. Pure: no
/// I/O, no clock beyond `inputs.now`, no locale — every label is the App's.
///
/// Sources, in order of precedence (see AGENTS.md § 7.1 for the harness axis):
///
/// - **Request-level numbers** (tokens, cost, requests, trend, heatmap,
///   projects, models, prompt sizes) come from the usage ledger. Days below
///   the ledger's detail floor are daily rollups: they count in totals, the
///   trend and the model ranking, never on the clock or per project.
/// - **Session tokens and cost** come from exactly one source per harness
///   (`SessionRow.TokenSource`): the ledger's own rows for that session id
///   wherever the harness writes one, so a session's figure is a slice of
///   the totals above it; the structure sidecar for Codex and ChatGPT Work,
///   whose ledger rows carry no session id; nothing for Cursor. Counts the
///   ledger does not hold (messages, tool calls, duration) come from the
///   sidecar, then the session index.
/// - **Tools, skills and Codex prompt sizes** come from
///   `SessionActivityTally`.
public enum UsageDashboardBuilder {
    public static let rankingLimit = 6
    public static let topSessionLimit = 8
    public static let recentSessionLimit = 200
    public static let skillLimit = 12
    public static let toolLimit = 10
    public static let toolWeekLimit = 26
    /// Above this many days the trend switches to weekly bars.
    public static let dailyTrendLimit = 120

    public static func build(_ inputs: UsageDashboardInputs) -> UsageDashboardSnapshot {
        var context = Context(inputs: inputs)
        let rows = context.sessionRows()
        let ledgerRows = context.dayTotals()

        var snapshot = UsageDashboardSnapshot.empty(query: inputs.query, now: inputs.now)
        snapshot.hero = context.hero(rows: rows, days: ledgerRows)
        snapshot.trend = context.trend(rows: rows, days: ledgerRows)
        snapshot.projects = context.projectRanking(rows: rows)
        snapshot.models = context.modelRanking(rows: rows)
        snapshot.heatmap = context.heatmap()
        snapshot.recentSessions = Array(rows.sorted(by: Self.recentFirst).prefix(recentSessionLimit))
        snapshot.topSessions = topSessions(rows)
        snapshot.shape = shape(rows)
        snapshot.skills = context.skills(rows: rows)
        snapshot.tools = context.tools(rows: rows)
        snapshot.health = context.health(rows: rows)
        snapshot.mix = context.mix(days: ledgerRows)
        snapshot.options = context.options()
        snapshot.coverage = context.coverage(rows: rows)
        return snapshot
    }

    // MARK: - Session lists

    static func recentFirst(_ lhs: UsageDashboardSnapshot.SessionRow, _ rhs: UsageDashboardSnapshot.SessionRow) -> Bool {
        let left = lhs.lastActiveAt ?? lhs.startedAt ?? .distantPast
        let right = rhs.lastActiveAt ?? rhs.startedAt ?? .distantPast
        return left == right ? lhs.id < rhs.id : left > right
    }

    static func topSessions(_ rows: [UsageDashboardSnapshot.SessionRow]) -> UsageDashboardSnapshot.TopSessions {
        typealias Row = UsageDashboardSnapshot.SessionRow
        func top(_ value: (Row) -> Int64?) -> [Row] {
            var ranked: [(row: Row, value: Int64)] = []
            for row in rows {
                if let measure = value(row), measure > 0 { ranked.append((row, measure)) }
            }
            ranked.sort { lhs, rhs in
                lhs.value == rhs.value ? recentFirst(lhs.row, rhs.row) : lhs.value > rhs.value
            }
            return ranked.prefix(topSessionLimit).map { $0.row }
        }
        return UsageDashboardSnapshot.TopSessions(
            byTokens: top { $0.tokens?.total },
            byCost: top { $0.costMicros },
            byActive: top { row in (row.activeSeconds ?? row.durationSeconds).map(Int64.init) }
        )
    }

    // MARK: - Session shape

    static let messageBins: [(Int, Int?)] = [(1, 5), (6, 15), (16, 30), (31, 60), (61, 120), (121, nil)]
    static let durationBins: [(Int, Int?)] = [(0, 299), (300, 899), (900, 1_799), (1_800, 3_599), (3_600, 10_799), (10_800, nil)]
    static let toolCallBins: [(Int, Int?)] = [(0, 0), (1, 10), (11, 50), (51, 100), (101, 250), (251, nil)]

    static func shape(_ rows: [UsageDashboardSnapshot.SessionRow]) -> UsageDashboardSnapshot.SessionShape {
        UsageDashboardSnapshot.SessionShape(
            messages: histogram(rows.compactMap(\.messages).filter { $0 > 0 }, bins: messageBins),
            duration: histogram(rows.compactMap(\.durationSeconds), bins: durationBins),
            toolCalls: histogram(rows.compactMap(\.toolCalls), bins: toolCallBins)
        )
    }

    static func histogram(_ values: [Int], bins: [(Int, Int?)]) -> UsageDashboardSnapshot.Histogram {
        var counts = Array(repeating: 0, count: bins.count)
        for value in values {
            if let index = bins.firstIndex(where: { value >= $0.0 && ($0.1.map { value <= $0 } ?? true) }) {
                counts[index] += 1
            }
        }
        return UsageDashboardSnapshot.Histogram(
            bins: zip(bins, counts).map { UsageDashboardSnapshot.Histogram.Bin(lower: $0.0.0, upper: $0.0.1, count: $0.1) },
            median: percentile(values.map(Double.init), 0.5),
            sampleCount: values.count
        )
    }

    // MARK: - Statistics

    /// Linear-interpolated percentile; `nil` for an empty sample.
    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = max(0, min(1, p)) * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        let fraction = rank - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    /// The median of a bucketed histogram, read at the middle of the bucket
    /// holding the middle request.
    static func histogramMedian(_ buckets: [(bucket: Int64, count: Int)], width: Int64) -> Int64? {
        let total = buckets.reduce(0) { $0 + $1.count }
        guard total > 0 else { return nil }
        let middle = (total + 1) / 2
        var running = 0
        for entry in buckets.sorted(by: { $0.bucket < $1.bucket }) {
            running += entry.count
            if running >= middle { return entry.bucket * width + width / 2 }
        }
        return nil
    }

    // MARK: - Health score

    /// The health score, 0–100, and its four parts. A part with no evidence
    /// is `nil` and drops out of the weighted mean.
    ///
    /// - **Cache** (weight 0.35): `hitRate / 0.85`, capped — a harness that
    ///   serves 85 % of its prompt from cache scores 100. A harness with no
    ///   cache token at all in the range has no cache part.
    /// - **Lean start** (0.20): the median first-request prompt as a share
    ///   of the context window, 100 at ≤ 5 % falling linearly to 0 at 40 %.
    ///   Without a known window: 100 at ≤ 10 k tokens, 0 at 80 k.
    /// - **Pace** (0.20): median prompt growth per request as a share of the
    ///   window, 100 at ≤ 0.2 % falling to 0 at 2 %. Without a window: 100 at
    ///   ≤ 500 tokens a request, 0 at 5 k.
    /// - **Reliability** (0.25): `1 − failed / tool calls`, 100 at 0 % and 0
    ///   at 25 % failed. Needs at least 20 parsed tool calls.
    public static func healthScores(
        cacheHitRate: Double?,
        startSize: Int64?,
        growthPerRequest: Int64?,
        contextWindow: Int?,
        toolFailureRate: Double?
    ) -> (score: Int?, cache: Int?, leanStart: Int?, pace: Int?, reliability: Int?) {
        func linear(_ value: Double, best: Double, worst: Double) -> Int {
            let fraction = (worst - value) / (worst - best)
            return Int((max(0, min(1, fraction)) * 100).rounded())
        }
        let cache = cacheHitRate.map { Int((max(0, min(1, $0 / 0.85)) * 100).rounded()) }
        let window = contextWindow.flatMap { $0 > 0 ? Double($0) : nil }
        let lean: Int? = startSize.map { size in
            if let window { return linear(Double(size) / window, best: 0.05, worst: 0.40) }
            return linear(Double(size), best: 10_000, worst: 80_000)
        }
        let pace: Int? = growthPerRequest.map { growth in
            if let window { return linear(Double(growth) / window, best: 0.002, worst: 0.02) }
            return linear(Double(growth), best: 500, worst: 5_000)
        }
        let reliability = toolFailureRate.map { linear($0, best: 0, worst: 0.25) }
        let parts: [(Int?, Double)] = [(cache, 0.35), (lean, 0.20), (pace, 0.20), (reliability, 0.25)]
        let present = parts.compactMap { part in part.0.map { (Double($0), part.1) } }
        let weight = present.reduce(0) { $0 + $1.1 }
        let score: Int? = weight > 0
            ? Int((present.reduce(0) { $0 + $1.0 * $1.1 } / weight).rounded())
            : nil
        return (score, cache, lean, pace, reliability)
    }
}

// MARK: - Context

private struct Context {
    let inputs: UsageDashboardInputs
    /// `inputs.ledger` narrowed to the query's harnesses.
    let facts: UsageLedgerDashboardFacts
    let calendar: Calendar
    let dayFormatter: DateFormatter
    let startDay: String
    let endDay: String
    private var dayDates: [String: Date] = [:]

    init(inputs: UsageDashboardInputs) {
        self.inputs = inputs
        var facts = inputs.ledger
        if inputs.query.harnesses != nil {
            let query = inputs.query
            facts.slots = facts.slots.filter { query.includes($0.harness) }
            facts.days = facts.days.filter { query.includes($0.harness) }
            facts.projects = facts.projects.filter { query.includes($0.harness) }
            facts.models = facts.models.filter { query.includes($0.harness) }
            facts.promptBuckets = facts.promptBuckets.filter { query.includes($0.harness) }
        }
        self.facts = facts
        self.calendar = inputs.calendar
        let formatter = DateFormatter()
        formatter.calendar = inputs.calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = inputs.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        self.dayFormatter = formatter
        self.startDay = formatter.string(from: inputs.query.interval.start)
        // The interval's end is exclusive; the last day is the one before it
        // unless the end falls inside a day.
        self.endDay = formatter.string(from: inputs.query.interval.end.addingTimeInterval(-1))
    }

    var query: UsageDashboardQuery { inputs.query }

    mutating func date(forDay key: String) -> Date? {
        if let cached = dayDates[key] { return cached }
        let value = dayFormatter.date(from: key).map { calendar.startOfDay(for: $0) }
        dayDates[key] = value
        return value
    }

    func inRange(day key: String) -> Bool { key >= startDay && key <= endDay }

    // MARK: Sessions

    func ledgerKey(_ harness: Harness, _ id: String) -> String { harness.rawValue + "|" + id }

    func sessionRows() -> [UsageDashboardSnapshot.SessionRow] {
        let ledgerByKey = Dictionary(
            inputs.ledgerSessions.map { (ledgerKey($0.harness, $0.sessionID), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let interval = query.interval
        var rows: [UsageDashboardSnapshot.SessionRow] = []
        var seen: Set<String> = []
        for summary in inputs.sessions {
            guard seen.insert(summary.id).inserted else { continue }
            let harness = summary.effectiveHarness
            guard query.includes(harness) else { continue }
            let lastActive = summary.lastActiveAt ?? summary.createdAt
            let started = summary.createdAt ?? summary.lastActiveAt
            if let lastActive, lastActive < interval.start { continue }
            if let started, started > interval.end { continue }
            let stats = inputs.structures[summary.sourcePath]
            let tally = inputs.activity[summary.sourcePath]
            let ledger = ledgerByKey[ledgerKey(harness, summary.sessionID)]
            let row = UsageDashboardBuilder.sessionRow(summary: summary, stats: stats, tally: tally, ledger: ledger)
            if let model = query.model {
                let matches = row.model == model
                    || summary.model == model
                    || stats?.models.contains(model) == true
                    || inputs.ledgerSessionIDsInQuery.contains(summary.sessionID)
                guard matches else { continue }
            }
            if let project = query.project, row.projectPath != project { continue }
            rows.append(row)
        }
        return rows
    }

    // MARK: Days

    struct DayTotal {
        var tokens = UsageTokenSplit.zero
        var requests = 0
        var costMicros: Int64 = 0
        var unpriced = 0
        var hours: Set<Int64> = []
        var byHarness: [Harness: (tokens: Int64, cost: Int64, requests: Int)] = [:]
    }

    /// One total per local day, from the ledger's own day keys: request rows
    /// by their `day` column and rollups by theirs — exactly what
    /// `UsageEventLedger.summary` and `trend` sum. Clock hours come from the
    /// slots, which carry the request's instant.
    mutating func dayTotals() -> [String: DayTotal] {
        var days: [String: DayTotal] = [:]
        for row in facts.days {
            var total = days[row.day] ?? DayTotal()
            total.tokens += row.tokens
            total.requests += row.requests
            total.costMicros += row.costMicros
            total.unpriced += row.unpriced
            var harness = total.byHarness[row.harness] ?? (0, 0, 0)
            harness.tokens += row.tokens.total
            harness.cost += row.costMicros
            harness.requests += row.requests
            total.byHarness[row.harness] = harness
            days[row.day] = total
        }
        for slot in facts.slots where slot.requests > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(slot.start))
            let key = dayFormatter.string(from: date)
            days[key, default: DayTotal()].hours.insert(hourKey(date))
        }
        return days
    }

    func hourKey(_ date: Date) -> Int64 {
        Int64((calendar.dateInterval(of: .hour, for: date)?.start ?? date).timeIntervalSince1970)
    }

    // MARK: Hero

    func hero(rows: [UsageDashboardSnapshot.SessionRow], days: [String: DayTotal]) -> UsageDashboardSnapshot.Hero {
        var hero = UsageDashboardSnapshot.Hero()
        hero.sessions = rows.count
        let sessionTokens = rows.compactMap { $0.tokens?.total }.filter { $0 > 0 }.map(Double.init)
        hero.medianSessionTokens = UsageDashboardBuilder.percentile(sessionTokens, 0.5).map { Int64($0.rounded()) }
        hero.p90SessionTokens = UsageDashboardBuilder.percentile(sessionTokens, 0.9).map { Int64($0.rounded()) }
        var priced = 0
        var cost: Int64 = 0
        var hours: Set<Int64> = []
        for total in days.values {
            hero.tokens += total.tokens
            hero.requests += total.requests
            cost += total.costMicros
            priced += total.requests - total.unpriced
            if total.unpriced > 0 { hero.hasUnpricedUsage = true }
            hours.formUnion(total.hours)
        }
        hero.costMicros = priced > 0 ? cost : nil
        hero.activeHours = hours.count
        hero.activeDays = days.values.filter { $0.requests > 0 }.count
        let projects = projectTotals(rows: rows)
        hero.projectCount = projects.count
        let projectTokens = projects.values.reduce(Int64(0)) { $0 + $1.tokens }
        if let top = projects.max(by: { $0.value.tokens == $1.value.tokens ? $0.key > $1.key : $0.value.tokens < $1.value.tokens }) {
            hero.topProjectName = Self.basename(top.key)
            hero.topProjectShare = projectTokens > 0 ? Double(top.value.tokens) / Double(projectTokens) : nil
        }
        return hero
    }

    // MARK: Trend

    mutating func trend(rows: [UsageDashboardSnapshot.SessionRow], days: [String: DayTotal]) -> UsageDashboardSnapshot.Trend {
        if query.range == .today { return hourlyTrend(rows: rows) }
        let interval = query.interval
        var starts: [Date] = []
        var cursor = calendar.startOfDay(for: interval.start)
        while cursor < interval.end, starts.count < 2_000 {
            starts.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        let weekly = starts.count > UsageDashboardBuilder.dailyTrendLimit
        func bucket(_ date: Date) -> Date {
            weekly
                ? (calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date))
                : calendar.startOfDay(for: date)
        }
        var order: [Date] = []
        var points: [Date: UsageDashboardSnapshot.TrendPoint] = [:]
        var split: [Date: [Harness: (tokens: Int64, cost: Int64)]] = [:]
        for start in starts {
            let key = bucket(start)
            if points[key] == nil {
                order.append(key)
                points[key] = UsageDashboardSnapshot.TrendPoint(start: key)
            }
        }
        var hoursByBucket: [Date: Set<Int64>] = [:]
        for (day, total) in days {
            guard let date = date(forDay: day) else { continue }
            let key = bucket(date)
            guard points[key] != nil else { continue }
            points[key]?.promptTokens += total.tokens.prompt
            points[key]?.outputTokens += total.tokens.output
            points[key]?.requests += total.requests
            points[key]?.costMicros += total.costMicros
            hoursByBucket[key, default: []].formUnion(total.hours)
            for (harness, value) in total.byHarness {
                var entry = split[key]?[harness] ?? (0, 0)
                entry.tokens += value.tokens
                entry.cost += value.cost
                split[key, default: [:]][harness] = entry
            }
        }
        for (key, hours) in hoursByBucket { points[key]?.activeHours = hours.count }
        for (key, values) in split { points[key]?.byHarness = Self.harnessValues(values) }
        for row in rows {
            var buckets: Set<Date> = []
            for day in activeDays(of: row) where inRange(day: day) {
                if let date = date(forDay: day) { buckets.insert(bucket(date)) }
            }
            for key in buckets { points[key]?.sessions += 1 }
        }
        return UsageDashboardSnapshot.Trend(
            bucket: weekly ? .week : .day,
            points: order.compactMap { points[$0] }
        )
    }

    /// Today, one bar per local hour, from the slots — the same instants
    /// `UsageEventLedger.trend(_, bucket: .hour)` buckets.
    func hourlyTrend(rows: [UsageDashboardSnapshot.SessionRow]) -> UsageDashboardSnapshot.Trend {
        let interval = query.interval
        var starts: [Date] = []
        var cursor = calendar.dateInterval(of: .hour, for: interval.start)?.start ?? interval.start
        while cursor < interval.end, starts.count < 48 {
            starts.append(cursor)
            guard let next = calendar.date(byAdding: .hour, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        var points = Dictionary(uniqueKeysWithValues: starts.map { ($0, UsageDashboardSnapshot.TrendPoint(start: $0)) })
        var split: [Date: [Harness: (tokens: Int64, cost: Int64)]] = [:]
        for slot in facts.slots {
            let date = Date(timeIntervalSince1970: TimeInterval(slot.start))
            guard let key = calendar.dateInterval(of: .hour, for: date)?.start, points[key] != nil else { continue }
            points[key]?.promptTokens += slot.tokens.prompt
            points[key]?.outputTokens += slot.tokens.output
            points[key]?.requests += slot.requests
            points[key]?.costMicros += slot.costMicros
            if slot.requests > 0 { points[key]?.activeHours = 1 }
            var entry = split[key]?[slot.harness] ?? (0, 0)
            entry.tokens += slot.tokens.total
            entry.cost += slot.costMicros
            split[key, default: [:]][slot.harness] = entry
        }
        for (key, values) in split { points[key]?.byHarness = Self.harnessValues(values) }
        for row in rows {
            guard let last = row.lastActiveAt ?? row.startedAt else { continue }
            let first = row.startedAt ?? last
            for start in starts {
                let end = start.addingTimeInterval(3_600)
                if first < end, last >= start { points[start]?.sessions += 1 }
            }
        }
        return UsageDashboardSnapshot.Trend(bucket: .hour, points: starts.compactMap { points[$0] })
    }

    static func harnessValues(_ values: [Harness: (tokens: Int64, cost: Int64)]) -> [UsageDashboardSnapshot.HarnessValue] {
        values
            .map { UsageDashboardSnapshot.HarnessValue(harness: $0.key, tokens: $0.value.tokens, costMicros: $0.value.cost) }
            .sorted { $0.tokens == $1.tokens ? $0.harness.rawValue < $1.harness.rawValue : $0.tokens > $1.tokens }
    }

    /// The local days a session was active on: its scan's days, else the
    /// first and last request the ledger saw, else its last activity.
    func activeDays(of row: UsageDashboardSnapshot.SessionRow) -> [String] {
        if let tally = inputs.activity[row.summary.sourcePath], !tally.activeDays.isEmpty {
            return tally.activeDays
        }
        let dates = [row.startedAt, row.lastActiveAt].compactMap { $0 }
        return Array(Set(dates.map { dayFormatter.string(from: $0) }))
    }

    // MARK: Rankings

    struct GroupTotal {
        var tokens: Int64 = 0
        var costMicros: Int64 = 0
        var requests = 0
        var unpriced = 0
        var sessions = 0
    }

    /// Ledger project totals — the rows `UsageEventLedger.projectStats` sums
    /// — with how many of the range's sessions ran there. A harness whose
    /// rows name no project (AntiGravity, Grok Build, Cursor) is simply not
    /// in this ranking, as in `projectStats`.
    func projectTotals(rows: [UsageDashboardSnapshot.SessionRow]) -> [String: GroupTotal] {
        var totals: [String: GroupTotal] = [:]
        for row in facts.projects {
            var total = totals[row.key] ?? GroupTotal()
            total.tokens += row.tokens
            total.costMicros += row.costMicros
            total.requests += row.requests
            total.unpriced += row.unpriced
            totals[row.key] = total
        }
        for row in rows {
            guard let path = row.projectPath, totals[path] != nil else { continue }
            totals[path]?.sessions += 1
        }
        return totals
    }

    func projectRanking(rows: [UsageDashboardSnapshot.SessionRow]) -> UsageDashboardSnapshot.Ranking {
        ranking(projectTotals(rows: rows), title: Self.basename)
    }

    func modelRanking(rows: [UsageDashboardSnapshot.SessionRow]) -> UsageDashboardSnapshot.Ranking {
        var totals: [String: GroupTotal] = [:]
        for row in facts.models {
            var total = totals[row.key] ?? GroupTotal()
            total.tokens += row.tokens
            total.costMicros += row.costMicros
            total.requests += row.requests
            total.unpriced += row.unpriced
            totals[row.key] = total
        }
        for row in rows {
            guard let model = row.model, totals[model] != nil else { continue }
            totals[model]?.sessions += 1
        }
        return ranking(totals, title: UsageModelNaming.canonicalDisplayName)
    }

    func ranking(_ totals: [String: GroupTotal], title: (String) -> String) -> UsageDashboardSnapshot.Ranking {
        let sorted = totals.sorted {
            $0.value.tokens == $1.value.tokens
                ? ($0.value.sessions == $1.value.sessions ? $0.key < $1.key : $0.value.sessions > $1.value.sessions)
                : $0.value.tokens > $1.value.tokens
        }
        let total = sorted.reduce(Int64(0)) { $0 + $1.value.tokens }
        let shown = sorted.prefix(UsageDashboardBuilder.rankingLimit)
        let rest = sorted.dropFirst(UsageDashboardBuilder.rankingLimit)
        return UsageDashboardSnapshot.Ranking(
            rows: shown.map { entry in
                UsageDashboardSnapshot.RankingRow(
                    id: entry.key,
                    title: title(entry.key),
                    tokens: entry.value.tokens,
                    costMicros: entry.value.requests > entry.value.unpriced || entry.value.costMicros > 0
                        ? entry.value.costMicros : nil,
                    requests: entry.value.requests,
                    sessions: entry.value.sessions,
                    share: total > 0 ? Double(entry.value.tokens) / Double(total) : 0
                )
            },
            remainderCount: rest.count,
            remainderTokens: rest.reduce(Int64(0)) { $0 + $1.value.tokens },
            totalTokens: total
        )
    }

    static func basename(_ path: String) -> String {
        UsageProjectIdentity.displayName(for: path)
    }

    // MARK: Heatmap

    func heatmap() -> UsageDashboardSnapshot.Heatmap {
        var map = UsageDashboardSnapshot.Heatmap()
        for slot in facts.slots where slot.requests > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(slot.start))
            let parts = calendar.dateComponents([.weekday, .hour], from: date)
            guard let weekday = parts.weekday, let hour = parts.hour else { continue }
            let monday = (weekday + 5) % 7
            map.cells[monday * 24 + hour] += slot.requests
            map.totalRequests += slot.requests
        }
        map.maximum = map.cells.max() ?? 0
        if map.maximum > 0, let index = map.cells.firstIndex(of: map.maximum) {
            map.busiestWeekday = index / 24
            map.busiestHour = index % 24
        }
        map.coversFrom = hourlyFrom()
        return map
    }

    func hourlyFrom() -> Date? {
        guard let floor = facts.detailFloorDay,
              let day = dayFormatter.date(from: floor),
              let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
        else { return nil }
        return next > query.interval.start ? next : nil
    }

    // MARK: Skills

    mutating func skills(rows: [UsageDashboardSnapshot.SessionRow]) -> [UsageDashboardSnapshot.SkillRow] {
        struct Accumulator {
            var invocations = 0
            var sessions = 0
            var lastUsed: Date?
            var harnesses: [Harness: Int] = [:]
            var projects: [String: Int] = [:]
        }
        var skills: [String: Accumulator] = [:]
        for row in rows {
            guard let tally = inputs.activity[row.summary.sourcePath] else { continue }
            var used: [String: Int] = [:]
            for (day, counts) in tally.days where inRange(day: day) {
                for (name, count) in counts.skills { used[name, default: 0] += count }
            }
            for (name, count) in used where count > 0 {
                var entry = skills[name] ?? Accumulator()
                entry.invocations += count
                entry.sessions += 1
                entry.harnesses[row.harness, default: 0] += count
                if let project = row.projectName { entry.projects[project, default: 0] += count }
                if let last = tally.skillLastUsed[name], last <= query.interval.end {
                    entry.lastUsed = max(entry.lastUsed ?? last, last)
                }
                skills[name] = entry
            }
        }
        return skills
            .sorted { $0.value.invocations == $1.value.invocations ? $0.key < $1.key : $0.value.invocations > $1.value.invocations }
            .prefix(UsageDashboardBuilder.skillLimit)
            .map { name, entry in
                UsageDashboardSnapshot.SkillRow(
                    name: name,
                    invocations: entry.invocations,
                    sessions: entry.sessions,
                    lastUsedAt: entry.lastUsed,
                    harnesses: entry.harnesses
                        .sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }
                        .map { UsageDashboardSnapshot.HarnessCount(harness: $0.key, count: $0.value) },
                    projects: entry.projects
                        .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                        .prefix(3).map(\.key),
                    projectCount: entry.projects.count
                )
            }
    }

    // MARK: Tools

    mutating func tools(rows: [UsageDashboardSnapshot.SessionRow]) -> UsageDashboardSnapshot.ToolUsage {
        var calls: [String: Int] = [:]
        var sessions: [String: Int] = [:]
        var weeks: [Date: [Int]] = [:]
        let categories = UsageToolCategory.allCases
        for row in rows {
            guard let tally = inputs.activity[row.summary.sourcePath] else { continue }
            var used: Set<String> = []
            for (day, counts) in tally.days where inRange(day: day) {
                guard let date = date(forDay: day) else { continue }
                let week = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
                var stack = weeks[week] ?? Array(repeating: 0, count: categories.count)
                for (name, count) in counts.tools where count > 0 {
                    calls[name, default: 0] += count
                    used.insert(name)
                    if let index = categories.firstIndex(of: UsageToolCategory(toolName: name)) {
                        stack[index] += count
                    }
                }
                weeks[week] = stack
            }
            for name in used { sessions[name, default: 0] += 1 }
        }
        let total = calls.values.reduce(0, +)
        let sorted = calls.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        return UsageDashboardSnapshot.ToolUsage(
            rows: sorted.prefix(UsageDashboardBuilder.toolLimit).map { name, count in
                UsageDashboardSnapshot.ToolRow(
                    name: name,
                    category: UsageToolCategory(toolName: name),
                    calls: count,
                    sessions: sessions[name] ?? 0,
                    share: total > 0 ? Double(count) / Double(total) : 0
                )
            },
            remainderCount: max(0, sorted.count - UsageDashboardBuilder.toolLimit),
            totalCalls: total,
            weeks: weeks.keys.sorted().suffix(UsageDashboardBuilder.toolWeekLimit).map {
                UsageDashboardSnapshot.ToolWeek(start: $0, counts: weeks[$0] ?? [])
            }
        )
    }

    // MARK: Health

    func health(rows: [UsageDashboardSnapshot.SessionRow]) -> [UsageDashboardSnapshot.HarnessHealth] {
        var requests: [Harness: Int] = [:]
        var tokens: [Harness: UsageTokenSplit] = [:]
        for row in facts.days {
            requests[row.harness, default: 0] += row.requests
            tokens[row.harness, default: .zero] += row.tokens
        }
        var buckets: [Harness: [(bucket: Int64, count: Int)]] = [:]
        var maxPrompt: [Harness: Int64] = [:]
        for row in facts.promptBuckets {
            buckets[row.harness, default: []].append((row.bucket, row.requests))
            maxPrompt[row.harness] = max(maxPrompt[row.harness] ?? 0, row.maxPrompt)
        }
        var models: [Harness: [String: Int]] = [:]
        for row in facts.models {
            models[row.harness, default: [:]][row.key, default: 0] += row.requests
        }
        let ledgerByKey = Dictionary(
            inputs.ledgerSessions.map { (ledgerKey($0.harness, $0.sessionID), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var sessionsByHarness: [Harness: [UsageDashboardSnapshot.SessionRow]] = [:]
        for row in rows { sessionsByHarness[row.harness, default: []].append(row) }

        let harnesses = Set(requests.filter { $0.value > 0 }.keys).union(sessionsByHarness.keys)
        var out: [UsageDashboardSnapshot.HarnessHealth] = []
        for harness in harnesses {
            let sessionRows = sessionsByHarness[harness] ?? []
            var starts: [Double] = []
            var growth: [Double] = []
            var windows: [Int: Int] = [:]
            var failed = 0
            var toolCalls = 0
            for row in sessionRows {
                let ledger = ledgerByKey[ledgerKey(harness, row.summary.sessionID)]
                let tally = inputs.activity[row.summary.sourcePath]
                let first = ledger?.firstPrompt ?? tally?.firstPromptTokens.map(Int64.init)
                let peak = ledger.map(\.maxPrompt) ?? tally?.maxPromptTokens.map(Int64.init)
                let count = ledger?.requests ?? tally?.requests ?? 0
                if let first, first > 0 { starts.append(Double(first)) }
                if let first, let peak, count >= 2, peak >= first {
                    growth.append(Double(peak - first) / Double(count - 1))
                }
                if let window = tally?.contextWindow { windows[window, default: 0] += 1 }
                if let stats = inputs.structures[row.summary.sourcePath] {
                    failed += stats.failedToolCount
                    toolCalls += stats.toolCallCount
                }
            }
            let rankedModels = (models[harness] ?? [:])
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .map(\.key)
            let window = windows.max { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }?.key
                ?? rankedModels.lazy.compactMap(UsageModelContextWindow.tokens(for:)).first
            let typical = UsageDashboardBuilder.histogramMedian(
                buckets[harness] ?? [], width: UsageLedgerDashboardFacts.promptBucketTokens
            )
            let start = UsageDashboardBuilder.percentile(starts, 0.5).map { Int64($0.rounded()) }
            let pace = UsageDashboardBuilder.percentile(growth, 0.5).map { Int64($0.rounded()) }
            // A harness that never recorded a cache token in the range has no
            // cache evidence (Grok Build's log carries no cache fields at
            // all): unknown, not a 0 % that would sink its score.
            let split = tokens[harness] ?? .zero
            let hitRate = split.cacheRead + split.cacheWrite > 0 ? split.cacheHitRate : nil
            let failureRate = toolCalls >= 20 ? Double(failed) / Double(toolCalls) : nil
            let scores = UsageDashboardBuilder.healthScores(
                cacheHitRate: hitRate,
                startSize: start,
                growthPerRequest: pace,
                contextWindow: window,
                toolFailureRate: failureRate
            )
            out.append(UsageDashboardSnapshot.HarnessHealth(
                harness: harness,
                requests: requests[harness] ?? 0,
                sessions: sessionRows.count,
                score: scores.score,
                cacheScore: scores.cache,
                leanStartScore: scores.leanStart,
                paceScore: scores.pace,
                reliabilityScore: scores.reliability,
                typicalPrompt: typical,
                maxPrompt: maxPrompt[harness],
                startSize: start,
                growthPerRequest: pace,
                cacheHitRate: hitRate,
                contextWindow: window,
                toolFailureRate: failureRate,
                models: Array(rankedModels.prefix(4))
            ))
        }
        return out.sorted {
            $0.requests == $1.requests
                ? ($0.sessions == $1.sessions ? $0.harness.rawValue < $1.harness.rawValue : $0.sessions > $1.sessions)
                : $0.requests > $1.requests
        }
    }

    // MARK: Mix

    func mix(days: [String: DayTotal]) -> UsageDashboardSnapshot.Mix {
        var harnesses: [Harness: (tokens: Int64, cost: Int64, requests: Int)] = [:]
        for total in days.values {
            for (harness, value) in total.byHarness {
                var entry = harnesses[harness] ?? (0, 0, 0)
                entry.tokens += value.tokens
                entry.cost += value.cost
                entry.requests += value.requests
                harnesses[harness] = entry
            }
        }
        var companies: [ToolType: (tokens: Int64, cost: Int64, requests: Int)] = [:]
        for (harness, value) in harnesses {
            var entry = companies[harness.company] ?? (0, 0, 0)
            entry.tokens += value.tokens
            entry.cost += value.cost
            entry.requests += value.requests
            companies[harness.company] = entry
        }
        return UsageDashboardSnapshot.Mix(
            harnesses: harnesses
                .filter { $0.value.tokens > 0 }
                .map { UsageDashboardSnapshot.MixSlice(id: $0.key.rawValue, harness: $0.key, tokens: $0.value.tokens, costMicros: $0.value.cost, requests: $0.value.requests) }
                .sorted { $0.tokens == $1.tokens ? $0.id < $1.id : $0.tokens > $1.tokens },
            companies: companies
                .filter { $0.value.tokens > 0 }
                .map { UsageDashboardSnapshot.MixSlice(id: $0.key.rawValue, company: $0.key, tokens: $0.value.tokens, costMicros: $0.value.cost, requests: $0.value.requests) }
                .sorted { $0.tokens == $1.tokens ? $0.id < $1.id : $0.tokens > $1.tokens }
        )
    }

    // MARK: Options and coverage

    func options() -> UsageDashboardSnapshot.FilterOptions {
        var sessionCounts: [Harness: Int] = [:]
        let interval = query.interval
        for summary in inputs.sessions {
            if let last = summary.lastActiveAt ?? summary.createdAt, last < interval.start { continue }
            sessionCounts[summary.effectiveHarness, default: 0] += 1
        }
        // From the unfiltered reading, so narrowing never retires a chip.
        var harnessTokens: [Harness: Int64] = [:]
        for row in inputs.ledger.days { harnessTokens[row.harness, default: 0] += row.tokens.total }
        let harnesses = Set(harnessTokens.filter { $0.value > 0 }.keys).union(sessionCounts.keys)
        var projects = inputs.projectOptions
        if let selected = query.project, projects[selected] == nil { projects[selected] = 0 }
        return UsageDashboardSnapshot.FilterOptions(
            harnesses: harnesses
                .map {
                    UsageDashboardSnapshot.HarnessOption(
                        harness: $0, tokens: harnessTokens[$0] ?? 0, sessions: sessionCounts[$0] ?? 0
                    )
                }
                .sorted {
                    $0.tokens == $1.tokens
                        ? ($0.sessions == $1.sessions ? $0.harness.rawValue < $1.harness.rawValue : $0.sessions > $1.sessions)
                        : $0.tokens > $1.tokens
                },
            models: inputs.availableModels,
            projects: projects
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(60)
                .map { UsageDashboardSnapshot.ProjectOption(path: $0.key, name: Self.basename($0.key), tokens: $0.value) }
        )
    }

    func coverage(rows: [UsageDashboardSnapshot.SessionRow]) -> UsageDashboardSnapshot.Coverage {
        var coverage = UsageDashboardSnapshot.Coverage()
        coverage.sessionsInRange = rows.count
        for row in rows {
            let provider = row.summary.provider
            let path = row.summary.sourcePath
            let unreachable = inputs.unreachablePaths.contains(path)
            if SessionStructureService.supports(provider) {
                coverage.structureEligible += 1
                if inputs.structures[path] != nil { coverage.structureReady += 1 }
            }
            if SessionActivityScanner.supports(provider) {
                coverage.activityEligible += 1
                if inputs.activity[path] != nil { coverage.activityReady += 1 }
                else if unreachable { coverage.skipped += 1 }
            }
        }
        coverage.hourlyFrom = hourlyFrom()
        coverage.excludesRollups = !facts.includesRollups
        return coverage
    }
}

// MARK: - One session

extension UsageDashboardBuilder {
    /// One session's row, from whichever sources know it. See the type's
    /// doc comment for the order.
    public static func sessionRow(
        summary: SessionSummary,
        stats: SessionStats?,
        tally: SessionActivityTally?,
        ledger: UsageLedgerDashboardFacts.SessionRow?
    ) -> UsageDashboardSnapshot.SessionRow {
        var tokens: UsageTokenSplit?
        var cost: Int64?
        var partial = false
        var source = UsageDashboardSnapshot.SessionRow.TokenSource.none
        if usesSessionLog(summary.effectiveHarness) {
            if let stats, stats.totalTokens > 0 || !stats.totalUsage.isZero {
                tokens = stats.totalUsage.isZero
                    ? UsageTokenSplit(input: Int64(stats.totalTokens))
                    : UsageTokenSplit(stats.totalUsage)
                cost = stats.estimatedCostUSD.map { Int64(($0 * 1_000_000).rounded()) }
                partial = stats.hasUnpricedUsage
                source = .sessionLog
            }
        } else if let ledger {
            tokens = ledger.tokens
            cost = ledger.requests > ledger.unpriced ? ledger.costMicros : nil
            partial = ledger.unpriced > 0
            source = .ledger
        }
        let topModel = stats?.modelUsage.max { $0.usage.total < $1.usage.total }?.model
        let model = topModel ?? ledger?.model ?? summary.model ?? stats?.models.first
        // The ledger stores a worktree under its repository's root
        // (`UsageProjectIdentity`); a session's own cwd is folded the same way
        // so the two sources name one project once.
        let project = UsageProjectIdentity.normalizedPath(summary.projectDir)
            ?? UsageProjectIdentity.normalizedPath(stats?.cwd)
            ?? UsageProjectIdentity.normalizedPath(ledger?.project)
        let started = summary.createdAt ?? stats?.startedAt ?? ledger?.firstAt
        let lastActive = summary.lastActiveAt ?? stats?.endedAt ?? ledger?.lastAt
        let messages: Int?
        if let stats, stats.turnCount > 0 || stats.promptCount > 0 {
            messages = stats.promptCount + stats.turnCount
        } else if summary.hasKnownMessageCount {
            messages = summary.messageCount
        } else {
            messages = ledger?.requests
        }
        let duration: Int? = stats?.durationMs.map { $0 / 1_000 }
            ?? (started.flatMap { start in lastActive.map { Int(max(0, $0.timeIntervalSince(start))) } })
        let slotSeconds = Int(UsageLedgerDashboardFacts.sessionActivitySlotSeconds)
        let active: Int? = ledger.map { $0.activeSlots * slotSeconds }
            ?? tally.flatMap { $0.activeSlots > 0 ? $0.activeSlots * slotSeconds : nil }
        let toolCalls = stats?.toolCallCount ?? tally?.totalToolCalls
        return UsageDashboardSnapshot.SessionRow(
            summary: summary,
            harness: summary.effectiveHarness,
            title: nonEmpty(summary.title) ?? nonEmpty(stats?.title),
            projectPath: project,
            projectName: project.map(Context.basename),
            model: model,
            startedAt: started,
            lastActiveAt: lastActive,
            tokens: tokens,
            costMicros: cost,
            costIsPartial: partial,
            tokenSource: source,
            messages: messages,
            durationSeconds: duration,
            activeSeconds: active,
            toolCalls: toolCalls,
            failedToolCalls: stats?.failedToolCount
        )
    }

    /// Codex and ChatGPT Work: their ledger rows carry no session id, so the
    /// parsed session log is the only per-session reading there is.
    public static func usesSessionLog(_ harness: Harness) -> Bool {
        harness == .codex || harness == .chatgptWork
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}
