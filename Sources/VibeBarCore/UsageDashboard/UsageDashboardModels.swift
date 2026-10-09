import Foundation

// MARK: - Calendar

/// The calendar every Usage page day is cut with: the usage ledger's own —
/// Gregorian, `en_US_POSIX`, the machine's time zone — which is also
/// `CostAggregator`'s, so "today", "7 days" and "30 days" start at the same
/// local midnight here, in the popover's cost cards and in the ledger's
/// `day` column. `Calendar.current` is not used: a Mac set to another
/// calendar would cut a different day and spell a different year.
public enum UsageDashboardCalendar {
    public static var local: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = .current
        return calendar
    }
}

// MARK: - Query

/// The five ranges the Usage page offers. Every multi-day preset is aligned
/// to local calendar days, matching `CostSnapshot.last7Days*` everywhere else
/// in Vibe Bar; `all` starts at the first retained fact.
public enum UsageDashboardRange: String, CaseIterable, Sendable, Hashable, Codable {
    case today
    case week
    case month
    case quarter
    case all

    public var calendarDays: Int? {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .all: nil
        }
    }

    /// The window this preset covers at `now`. `earliest` is only read by
    /// `all`; without one the window collapses to today.
    public func interval(now: Date, earliest: Date?, calendar: Calendar = UsageDashboardCalendar.local) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let start: Date
        if let days = calendarDays {
            start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        } else {
            start = min(earliest.map { calendar.startOfDay(for: $0) } ?? today, today)
        }
        return DateInterval(start: start, end: max(now, start.addingTimeInterval(60)))
    }
}

/// Everything that narrows the page. `harnesses == nil` is every harness and
/// `[]` is none, the same convention as `HarnessSelection`.
public struct UsageDashboardQuery: Hashable, Sendable {
    public var range: UsageDashboardRange
    public var interval: DateInterval
    public var harnesses: [Harness]?
    public var model: String?
    public var project: String?

    public init(
        range: UsageDashboardRange,
        interval: DateInterval,
        harnesses: [Harness]? = nil,
        model: String? = nil,
        project: String? = nil
    ) {
        self.range = range
        self.interval = interval
        self.harnesses = harnesses.map { $0.sorted { $0.rawValue < $1.rawValue } }
        self.model = model
        self.project = project
    }

    public func includes(_ harness: Harness) -> Bool {
        harnesses?.contains(harness) ?? true
    }

    /// The ledger filter this query reads with. The project dimension is
    /// applied separately because `UsageQueryFilter` predates it.
    public var ledgerFilter: UsageQueryFilter {
        UsageQueryFilter(range: interval, harnesses: harnesses, models: model.map { [$0] })
    }

    /// The same filter with every harness: every ledger row is keyed by its
    /// harness, so the chips narrow the reading in memory and toggling one
    /// costs no query.
    public var ledgerFilterAllHarnesses: UsageQueryFilter {
        UsageQueryFilter(range: interval, models: model.map { [$0] })
    }
}

// MARK: - Shared values

/// Four disjoint token buckets, the ledger's own split. `prompt` is
/// everything sent to the model (fresh + cache read + cache write).
public struct UsageTokenSplit: Hashable, Sendable, Codable {
    public var input: Int64
    public var output: Int64
    public var cacheRead: Int64
    public var cacheWrite: Int64

    public init(input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public static let zero = UsageTokenSplit()

    public var total: Int64 { input + output + cacheRead + cacheWrite }
    public var prompt: Int64 { input + cacheRead + cacheWrite }
    public var isZero: Bool { total == 0 }

    /// Share of the prompt side served from cache; `nil` with no prompt.
    public var cacheHitRate: Double? {
        prompt > 0 ? Double(cacheRead) / Double(prompt) : nil
    }

    public static func + (lhs: UsageTokenSplit, rhs: UsageTokenSplit) -> UsageTokenSplit {
        UsageTokenSplit(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite
        )
    }

    public static func += (lhs: inout UsageTokenSplit, rhs: UsageTokenSplit) { lhs = lhs + rhs }

    public init(_ usage: SessionStructure.TokenUsage) {
        self.init(
            input: Int64(max(0, usage.input)),
            output: Int64(max(0, usage.output)),
            cacheRead: Int64(max(0, usage.cacheRead)),
            cacheWrite: Int64(max(0, usage.cacheWrite))
        )
    }
}

// MARK: - Snapshot

/// Every number the Usage page draws, computed once per query off the main
/// thread and handed to the view model as one immutable value.
public struct UsageDashboardSnapshot: Sendable, Equatable {
    public var query: UsageDashboardQuery
    public var generatedAt: Date
    public var hero: Hero
    public var trend: Trend
    public var projects: Ranking
    public var models: Ranking
    public var heatmap: Heatmap
    /// Sessions active in the range, most recent first, capped at
    /// `UsageDashboardBuilder.recentSessionLimit`.
    public var recentSessions: [SessionRow]
    public var topSessions: TopSessions
    public var shape: SessionShape
    public var skills: [SkillRow]
    public var tools: ToolUsage
    public var health: [HarnessHealth]
    public var mix: Mix
    public var options: FilterOptions
    public var coverage: Coverage

    public init(
        query: UsageDashboardQuery,
        generatedAt: Date,
        hero: Hero,
        trend: Trend,
        projects: Ranking,
        models: Ranking,
        heatmap: Heatmap,
        recentSessions: [SessionRow],
        topSessions: TopSessions,
        shape: SessionShape,
        skills: [SkillRow],
        tools: ToolUsage,
        health: [HarnessHealth],
        mix: Mix = Mix(),
        options: FilterOptions,
        coverage: Coverage
    ) {
        self.query = query
        self.generatedAt = generatedAt
        self.hero = hero
        self.trend = trend
        self.projects = projects
        self.models = models
        self.heatmap = heatmap
        self.recentSessions = recentSessions
        self.topSessions = topSessions
        self.shape = shape
        self.skills = skills
        self.tools = tools
        self.health = health
        self.mix = mix
        self.options = options
        self.coverage = coverage
    }

    public static func empty(query: UsageDashboardQuery, now: Date = Date()) -> UsageDashboardSnapshot {
        UsageDashboardSnapshot(
            query: query,
            generatedAt: now,
            hero: Hero(),
            trend: Trend(bucket: .day, points: []),
            projects: Ranking(),
            models: Ranking(),
            heatmap: Heatmap(),
            recentSessions: [],
            topSessions: TopSessions(),
            shape: SessionShape(),
            skills: [],
            tools: ToolUsage(),
            health: [],
            options: FilterOptions(),
            coverage: Coverage()
        )
    }

    // MARK: Hero

    public struct Hero: Sendable, Equatable {
        public var sessions: Int = 0
        public var medianSessionTokens: Int64?
        public var p90SessionTokens: Int64?
        public var tokens: UsageTokenSplit = .zero
        public var requests: Int = 0
        /// Priced spend; `nil` when no request in range had a price.
        public var costMicros: Int64?
        /// Some usage could not be priced, so `costMicros` is a floor.
        public var hasUnpricedUsage: Bool = false
        /// Distinct local clock hours with at least one request.
        public var activeHours: Int = 0
        public var activeDays: Int = 0
        public var projectCount: Int = 0
        public var topProjectName: String?
        public var topProjectShare: Double?

        public init() {}
    }

    // MARK: Trend

    public struct Trend: Sendable, Equatable {
        /// `hour` for Today, `week` past `UsageDashboardBuilder.dailyTrendLimit`
        /// days, `day` otherwise — the same buckets `UsageEventLedger.trend`
        /// draws.
        public enum Bucket: String, Sendable, Equatable { case hour, day, week }
        public var bucket: Bucket
        public var points: [TrendPoint]

        public init(bucket: Bucket, points: [TrendPoint]) {
            self.bucket = bucket
            self.points = points
        }
    }

    public struct TrendPoint: Sendable, Equatable, Identifiable {
        public var start: Date
        /// Everything sent in: fresh input + cache read + cache write.
        public var promptTokens: Int64
        public var outputTokens: Int64
        public var requests: Int
        public var sessions: Int
        public var costMicros: Int64
        public var activeHours: Int
        /// Tokens and cost per harness, heaviest first, for the split view.
        public var byHarness: [HarnessValue]

        public var id: Date { start }
        public var totalTokens: Int64 { promptTokens + outputTokens }

        public init(
            start: Date,
            promptTokens: Int64 = 0,
            outputTokens: Int64 = 0,
            requests: Int = 0,
            sessions: Int = 0,
            costMicros: Int64 = 0,
            activeHours: Int = 0,
            byHarness: [HarnessValue] = []
        ) {
            self.start = start
            self.promptTokens = promptTokens
            self.outputTokens = outputTokens
            self.requests = requests
            self.sessions = sessions
            self.costMicros = costMicros
            self.activeHours = activeHours
            self.byHarness = byHarness
        }
    }

    public struct HarnessValue: Sendable, Equatable, Identifiable {
        public var harness: Harness
        public var tokens: Int64
        public var costMicros: Int64
        public var id: Harness { harness }

        public init(harness: Harness, tokens: Int64, costMicros: Int64) {
            self.harness = harness
            self.tokens = tokens
            self.costMicros = costMicros
        }
    }

    // MARK: Mix

    /// One slice of a share donut.
    public struct MixSlice: Sendable, Equatable, Identifiable {
        /// `Harness.rawValue` or the company's `ToolType.rawValue`.
        public var id: String
        public var harness: Harness?
        public var company: ToolType?
        public var tokens: Int64
        public var costMicros: Int64
        public var requests: Int

        public init(id: String, harness: Harness? = nil, company: ToolType? = nil, tokens: Int64, costMicros: Int64, requests: Int) {
            self.id = id
            self.harness = harness
            self.company = company
            self.tokens = tokens
            self.costMicros = costMicros
            self.requests = requests
        }
    }

    /// Token share by harness and by company — the same groupings
    /// `UsageEventLedger.harnessStats` and `UsageProviderStat.mergedByCompany`
    /// give the MCP `usage.summary` tool.
    public struct Mix: Sendable, Equatable {
        public var harnesses: [MixSlice] = []
        public var companies: [MixSlice] = []

        public init(harnesses: [MixSlice] = [], companies: [MixSlice] = []) {
            self.harnesses = harnesses
            self.companies = companies
        }
    }

    // MARK: Rankings

    public struct Ranking: Sendable, Equatable {
        public var rows: [RankingRow] = []
        /// Entries past the shown rows.
        public var remainderCount: Int = 0
        public var remainderTokens: Int64 = 0
        public var totalTokens: Int64 = 0

        public init(rows: [RankingRow] = [], remainderCount: Int = 0, remainderTokens: Int64 = 0, totalTokens: Int64 = 0) {
            self.rows = rows
            self.remainderCount = remainderCount
            self.remainderTokens = remainderTokens
            self.totalTokens = totalTokens
        }
    }

    public struct RankingRow: Sendable, Equatable, Identifiable {
        /// The project path or the raw model id.
        public var id: String
        /// Directory basename, or the canonical model name.
        public var title: String
        public var tokens: Int64
        public var costMicros: Int64?
        public var requests: Int
        public var sessions: Int
        /// `tokens / ranking total`.
        public var share: Double

        public init(id: String, title: String, tokens: Int64, costMicros: Int64?, requests: Int, sessions: Int, share: Double) {
            self.id = id
            self.title = title
            self.tokens = tokens
            self.costMicros = costMicros
            self.requests = requests
            self.sessions = sessions
            self.share = share
        }
    }

    // MARK: Heatmap

    /// Requests by local weekday × hour. Weekday 0 is Monday.
    public struct Heatmap: Sendable, Equatable {
        public var cells: [Int] = Array(repeating: 0, count: 7 * 24)
        public var maximum: Int = 0
        public var totalRequests: Int = 0
        public var busiestWeekday: Int?
        public var busiestHour: Int?
        /// The first instant hourly detail exists for; older days are daily
        /// rollups and cannot be placed on the clock.
        public var coversFrom: Date?

        public init() {}

        public func value(weekday: Int, hour: Int) -> Int {
            guard (0..<7).contains(weekday), (0..<24).contains(hour) else { return 0 }
            return cells[weekday * 24 + hour]
        }
    }

    // MARK: Sessions

    public struct SessionRow: Sendable, Equatable, Identifiable {
        /// Where a session's tokens and cost come from. One source per
        /// harness, never a mix: a session's figure must not change because a
        /// second source caught up.
        public enum TokenSource: String, Sendable, Equatable {
            /// The usage ledger's own rows for this session id — the rows
            /// every total on the page sums.
            case ledger
            /// The parsed session log (`session_structure.sqlite3`): Codex
            /// and ChatGPT Work rows carry no session id in the ledger.
            case sessionLog
            /// Nothing on this Mac records the session's tokens.
            case none
        }

        public var summary: SessionSummary
        public var harness: Harness
        public var title: String?
        public var projectPath: String?
        public var projectName: String?
        public var model: String?
        public var startedAt: Date?
        public var lastActiveAt: Date?
        /// `nil` when nothing on this Mac recorded the session's tokens.
        public var tokens: UsageTokenSplit?
        public var costMicros: Int64?
        public var costIsPartial: Bool
        public var tokenSource: TokenSource
        public var messages: Int?
        public var durationSeconds: Int?
        public var activeSeconds: Int?
        public var toolCalls: Int?
        public var failedToolCalls: Int?

        public var id: String { summary.id }

        public init(
            summary: SessionSummary,
            harness: Harness,
            title: String? = nil,
            projectPath: String? = nil,
            projectName: String? = nil,
            model: String? = nil,
            startedAt: Date? = nil,
            lastActiveAt: Date? = nil,
            tokens: UsageTokenSplit? = nil,
            costMicros: Int64? = nil,
            costIsPartial: Bool = false,
            tokenSource: TokenSource = .none,
            messages: Int? = nil,
            durationSeconds: Int? = nil,
            activeSeconds: Int? = nil,
            toolCalls: Int? = nil,
            failedToolCalls: Int? = nil
        ) {
            self.summary = summary
            self.harness = harness
            self.title = title
            self.projectPath = projectPath
            self.projectName = projectName
            self.model = model
            self.startedAt = startedAt
            self.lastActiveAt = lastActiveAt
            self.tokens = tokens
            self.costMicros = costMicros
            self.costIsPartial = costIsPartial
            self.tokenSource = tokenSource
            self.messages = messages
            self.durationSeconds = durationSeconds
            self.activeSeconds = activeSeconds
            self.toolCalls = toolCalls
            self.failedToolCalls = failedToolCalls
        }
    }

    public struct TopSessions: Sendable, Equatable {
        public var byTokens: [SessionRow] = []
        public var byCost: [SessionRow] = []
        public var byActive: [SessionRow] = []

        public init(byTokens: [SessionRow] = [], byCost: [SessionRow] = [], byActive: [SessionRow] = []) {
            self.byTokens = byTokens
            self.byCost = byCost
            self.byActive = byActive
        }
    }

    public struct Histogram: Sendable, Equatable {
        public struct Bin: Sendable, Equatable, Identifiable {
            public var lower: Int
            /// Inclusive; `nil` for the open last bin.
            public var upper: Int?
            public var count: Int
            public var id: Int { lower }

            public init(lower: Int, upper: Int?, count: Int) {
                self.lower = lower
                self.upper = upper
                self.count = count
            }
        }

        public var bins: [Bin] = []
        public var median: Double?
        /// Sessions the metric was known for.
        public var sampleCount: Int = 0

        public init(bins: [Bin] = [], median: Double? = nil, sampleCount: Int = 0) {
            self.bins = bins
            self.median = median
            self.sampleCount = sampleCount
        }

        public var maximum: Int { bins.map(\.count).max() ?? 0 }
    }

    public struct SessionShape: Sendable, Equatable {
        public var messages = Histogram()
        /// Seconds.
        public var duration = Histogram()
        public var toolCalls = Histogram()

        public init(messages: Histogram = Histogram(), duration: Histogram = Histogram(), toolCalls: Histogram = Histogram()) {
            self.messages = messages
            self.duration = duration
            self.toolCalls = toolCalls
        }
    }

    // MARK: Skills and tools

    public struct HarnessCount: Sendable, Equatable, Identifiable {
        public var harness: Harness
        public var count: Int
        public var id: Harness { harness }

        public init(harness: Harness, count: Int) {
            self.harness = harness
            self.count = count
        }
    }

    public struct SkillRow: Sendable, Equatable, Identifiable {
        public var name: String
        public var invocations: Int
        public var sessions: Int
        public var lastUsedAt: Date?
        public var harnesses: [HarnessCount]
        /// Directory basenames, most used first, at most three.
        public var projects: [String]
        public var projectCount: Int

        public var id: String { name }

        public init(
            name: String,
            invocations: Int,
            sessions: Int,
            lastUsedAt: Date?,
            harnesses: [HarnessCount],
            projects: [String],
            projectCount: Int
        ) {
            self.name = name
            self.invocations = invocations
            self.sessions = sessions
            self.lastUsedAt = lastUsedAt
            self.harnesses = harnesses
            self.projects = projects
            self.projectCount = projectCount
        }
    }

    public struct ToolRow: Sendable, Equatable, Identifiable {
        public var name: String
        public var category: UsageToolCategory
        public var calls: Int
        public var sessions: Int
        public var share: Double

        public var id: String { name }

        public init(name: String, category: UsageToolCategory, calls: Int, sessions: Int, share: Double) {
            self.name = name
            self.category = category
            self.calls = calls
            self.sessions = sessions
            self.share = share
        }
    }

    public struct ToolWeek: Sendable, Equatable, Identifiable {
        public var start: Date
        /// Calls per category, in `UsageToolCategory.allCases` order.
        public var counts: [Int]
        public var id: Date { start }
        public var total: Int { counts.reduce(0, +) }

        public init(start: Date, counts: [Int]) {
            self.start = start
            self.counts = counts
        }

        public func count(_ category: UsageToolCategory) -> Int {
            guard let index = UsageToolCategory.allCases.firstIndex(of: category), index < counts.count else { return 0 }
            return counts[index]
        }
    }

    public struct ToolUsage: Sendable, Equatable {
        public var rows: [ToolRow] = []
        public var remainderCount: Int = 0
        public var totalCalls: Int = 0
        public var weeks: [ToolWeek] = []

        public init(rows: [ToolRow] = [], remainderCount: Int = 0, totalCalls: Int = 0, weeks: [ToolWeek] = []) {
            self.rows = rows
            self.remainderCount = remainderCount
            self.totalCalls = totalCalls
            self.weeks = weeks
        }
    }

    // MARK: Health

    public enum HealthRating: String, Sendable, Equatable {
        case excellent
        case good
        case fair
        case poor
        case unknown

        public init(score: Int?) {
            guard let score else { self = .unknown; return }
            switch score {
            case 90...: self = .excellent
            case 75..<90: self = .good
            case 55..<75: self = .fair
            default: self = .poor
            }
        }
    }

    public struct HarnessHealth: Sendable, Equatable, Identifiable {
        public var harness: Harness
        public var requests: Int
        public var sessions: Int
        public var score: Int?
        public var rating: HealthRating
        public var cacheScore: Int?
        public var leanStartScore: Int?
        public var paceScore: Int?
        public var reliabilityScore: Int?
        /// Median prompt (fresh + cache) per request.
        public var typicalPrompt: Int64?
        public var maxPrompt: Int64?
        /// Median prompt of a session's first request.
        public var startSize: Int64?
        /// Median per-session prompt growth per request.
        public var growthPerRequest: Int64?
        public var cacheHitRate: Double?
        public var contextWindow: Int?
        /// Failed / all tool calls in sessions with a parsed structure.
        public var toolFailureRate: Double?
        public var models: [String]

        public var id: Harness { harness }

        public init(
            harness: Harness,
            requests: Int,
            sessions: Int,
            score: Int?,
            cacheScore: Int?,
            leanStartScore: Int?,
            paceScore: Int?,
            reliabilityScore: Int?,
            typicalPrompt: Int64?,
            maxPrompt: Int64?,
            startSize: Int64?,
            growthPerRequest: Int64?,
            cacheHitRate: Double?,
            contextWindow: Int?,
            toolFailureRate: Double?,
            models: [String]
        ) {
            self.harness = harness
            self.requests = requests
            self.sessions = sessions
            self.score = score
            self.rating = HealthRating(score: score)
            self.cacheScore = cacheScore
            self.leanStartScore = leanStartScore
            self.paceScore = paceScore
            self.reliabilityScore = reliabilityScore
            self.typicalPrompt = typicalPrompt
            self.maxPrompt = maxPrompt
            self.startSize = startSize
            self.growthPerRequest = growthPerRequest
            self.cacheHitRate = cacheHitRate
            self.contextWindow = contextWindow
            self.toolFailureRate = toolFailureRate
            self.models = models
        }
    }

    // MARK: Options and coverage

    public struct HarnessOption: Sendable, Equatable, Identifiable {
        public var harness: Harness
        public var tokens: Int64
        public var sessions: Int
        public var id: Harness { harness }

        public init(harness: Harness, tokens: Int64, sessions: Int) {
            self.harness = harness
            self.tokens = tokens
            self.sessions = sessions
        }
    }

    public struct ProjectOption: Sendable, Equatable, Identifiable {
        public var path: String
        public var name: String
        public var tokens: Int64
        public var id: String { path }

        public init(path: String, name: String, tokens: Int64) {
            self.path = path
            self.name = name
            self.tokens = tokens
        }
    }

    public struct FilterOptions: Sendable, Equatable {
        /// Harnesses with tokens or sessions in the range *before* the
        /// harness filter, so narrowing never retires a chip.
        public var harnesses: [HarnessOption] = []
        public var models: [String] = []
        public var projects: [ProjectOption] = []

        public init(harnesses: [HarnessOption] = [], models: [String] = [], projects: [ProjectOption] = []) {
            self.harnesses = harnesses
            self.models = models
            self.projects = projects
        }
    }

    public struct Coverage: Sendable, Equatable {
        public var sessionsInRange: Int = 0
        /// Codex / Claude sessions whose structure the sidecar can hold…
        public var structureEligible: Int = 0
        /// …and how many of them it holds at their current fingerprint.
        public var structureReady: Int = 0
        public var activityEligible: Int = 0
        public var activityReady: Int = 0
        /// Sessions left out of the background fill (above its size or count cap).
        public var skipped: Int = 0
        /// Earliest instant with request-level detail; days before it are rollups.
        public var hourlyFrom: Date?
        /// A project filter drops daily rollups, which carry no project.
        public var excludesRollups: Bool = false

        public init() {}

        public var isComplete: Bool {
            structureReady + skipped >= structureEligible && activityReady + skipped >= activityEligible
        }
    }
}
