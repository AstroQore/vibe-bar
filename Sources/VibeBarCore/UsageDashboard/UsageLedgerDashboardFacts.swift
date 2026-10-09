import Foundation

/// The ledger's side of the Usage page: request-level groupings for one
/// filter, read in a handful of `GROUP BY`s rather than row by row.
///
/// Every row carries the harness its requests came from. Days below a
/// tool's detail floor only exist as daily rollups — they contribute to
/// `days` and `models` and to nothing that needs a clock, a project or a
/// session (`slots`, `projects`, `sessions`, `promptBuckets`).
public struct UsageLedgerDashboardFacts: Sendable, Equatable {
    /// Width of a `slots` row. 15 minutes places a request on the local
    /// clock for any whole-hour or half-hour time zone and keeps 30 days at
    /// ≤ 2 880 rows per harness.
    public static let slotSeconds: Int64 = 900
    /// Width of one prompt-size histogram bucket.
    public static let promptBucketTokens: Int64 = 1_024
    /// Width of the activity slot a session's active time is counted in.
    public static let sessionActivitySlotSeconds: Int64 = 300

    public struct DayRow: Sendable, Equatable {
        /// Local `yyyy-MM-dd`, as the ledger stores it.
        public var day: String
        public var harness: Harness
        public var requests: Int
        public var tokens: UsageTokenSplit
        public var costMicros: Int64
        public var unpriced: Int

        public init(day: String, harness: Harness, requests: Int, tokens: UsageTokenSplit, costMicros: Int64, unpriced: Int) {
            self.day = day
            self.harness = harness
            self.requests = requests
            self.tokens = tokens
            self.costMicros = costMicros
            self.unpriced = unpriced
        }
    }

    public struct SlotRow: Sendable, Equatable {
        /// Unix seconds, a multiple of `slotSeconds`.
        public var start: Int64
        public var harness: Harness
        public var requests: Int
        public var tokens: UsageTokenSplit
        public var costMicros: Int64
        public var unpriced: Int

        public init(start: Int64, harness: Harness, requests: Int, tokens: UsageTokenSplit, costMicros: Int64, unpriced: Int) {
            self.start = start
            self.harness = harness
            self.requests = requests
            self.tokens = tokens
            self.costMicros = costMicros
            self.unpriced = unpriced
        }
    }

    public struct GroupRow: Sendable, Equatable {
        /// The project path or the raw model id.
        public var key: String
        public var harness: Harness
        public var requests: Int
        public var tokens: Int64
        public var costMicros: Int64
        public var unpriced: Int

        public init(key: String, harness: Harness, requests: Int, tokens: Int64, costMicros: Int64, unpriced: Int) {
            self.key = key
            self.harness = harness
            self.requests = requests
            self.tokens = tokens
            self.costMicros = costMicros
            self.unpriced = unpriced
        }
    }

    /// Whole-session totals over every detail row a session has, for the
    /// sessions with at least one row inside the filter.
    public struct SessionRow: Sendable, Equatable {
        public var sessionID: String
        public var harness: Harness
        public var requests: Int
        public var firstAt: Date
        public var lastAt: Date
        public var tokens: UsageTokenSplit
        public var costMicros: Int64
        public var unpriced: Int
        /// Prompt size of the first main-thread request.
        public var firstPrompt: Int64?
        public var maxPrompt: Int64
        /// Distinct `sessionActivitySlotSeconds` slots with a request.
        public var activeSlots: Int
        /// The model with the most requests.
        public var model: String?
        public var project: String?

        public init(
            sessionID: String,
            harness: Harness,
            requests: Int,
            firstAt: Date,
            lastAt: Date,
            tokens: UsageTokenSplit,
            costMicros: Int64,
            unpriced: Int,
            firstPrompt: Int64?,
            maxPrompt: Int64,
            activeSlots: Int,
            model: String?,
            project: String?
        ) {
            self.sessionID = sessionID
            self.harness = harness
            self.requests = requests
            self.firstAt = firstAt
            self.lastAt = lastAt
            self.tokens = tokens
            self.costMicros = costMicros
            self.unpriced = unpriced
            self.firstPrompt = firstPrompt
            self.maxPrompt = maxPrompt
            self.activeSlots = activeSlots
            self.model = model
            self.project = project
        }
    }

    public struct PromptBucketRow: Sendable, Equatable {
        public var harness: Harness
        /// `prompt / promptBucketTokens`.
        public var bucket: Int64
        public var requests: Int
        public var maxPrompt: Int64

        public init(harness: Harness, bucket: Int64, requests: Int, maxPrompt: Int64) {
            self.harness = harness
            self.bucket = bucket
            self.requests = requests
            self.maxPrompt = maxPrompt
        }
    }

    /// Request-level days (by each row's own `day` key) and, when read,
    /// rollup days. Detail and rollup days never overlap: a day is folded into
    /// rollups only after its detail rows are pruned.
    public var days: [DayRow] = []
    public var slots: [SlotRow] = []
    public var projects: [GroupRow] = []
    /// Detail and rollups.
    public var models: [GroupRow] = []
    public var sessions: [SessionRow] = []
    public var promptBuckets: [PromptBucketRow] = []
    /// The last day already folded into rollups, newest across tools; every
    /// day after it still has request-level rows. `nil` before any rollup.
    public var detailFloorDay: String?
    /// Whether the rollups were read (they are not under a project filter).
    public var includesRollups: Bool = true

    public init() {}
}
