import Foundation
import SQLite3

public enum UsageLedgerError: Error, Sendable {
    /// The SQLite file could not be opened or migrated.
    case open
    /// A statement failed to prepare, bind, or step.
    case statement
}

/// Durable per-request ledger for locally scanned CLI usage.
///
/// `CostUsageScanner` already parses every Codex / Claude / Gemini / Grok /
/// AntiGravity session log into per-request events and prices each one, but
/// it only keeps the *aggregate* (`CostSnapshot`). This actor persists the
/// events themselves so a usage UI can answer per-request questions —
/// "which model ran at 14:05?", "what did the last 200 requests cost?" —
/// without re-walking gigabytes of JSONL.
///
/// Shape mirrors `RemoteUsageLedger`: raw `sqlite3` C API, WAL, a 5 s busy
/// timeout, `CREATE TABLE IF NOT EXISTS` with a version stamp in a meta
/// table. Unlike the remote ledger, a schema-version mismatch here simply
/// drops and recreates every table: the authoritative copy of this data is
/// the scan cache on disk, so the next refresh re-ingests it for free.
///
/// # Token column semantics
///
/// `CostUsageScanCache.ParsedEvent` carries `input` / `cache` /
/// `cacheCreation`, and those mean slightly different things per provider.
/// Ingest normalizes all of them into three non-overlapping columns:
///
/// | column           | source                                    |
/// |------------------|-------------------------------------------|
/// | `fresh_input`    | `event.input`                             |
/// | `cache_creation` | `max(0, event.cacheCreation ?? 0)`         |
/// | `cache_read`     | `max(0, event.cache - cache_creation)`    |
///
/// Per provider, verified against the scanner's construction sites:
///
/// - **Codex** — `input` is already `delta.input - delta.cached`, i.e.
///   non-cached prompt tokens; `cache` is `delta.cached` (cache *reads*);
///   `cacheCreation` is never set. → `cache_creation = 0`.
/// - **Claude** — `input` is `usage.input_tokens`, which Anthropic already
///   reports net of cache; `cache` is the **sum** of
///   `cache_read_input_tokens + cache_creation_input_tokens`, and
///   `cacheCreation` repeats the creation half. Subtracting recovers the
///   read half — exactly what the scanner's own costing does.
/// - **Gemini** — both the OTLP and chat-history parsers store
///   `max(0, rawInput - cached)` in `input` and `cached` in `cache`;
///   `cacheCreation` is never set.
/// - **Grok** — the session total is split 70/30 into `input`/`output`
///   with `cache = 0`; no cache columns exist in the source at all.
/// - **AntiGravity** — the `.db` decoder stores this turn's cache-read
///   increment in `cache` and leaves `cacheCreation` nil (the protobuf has
///   no cache-creation field); the `.pb` RPC fallback has no cache data at
///   all and stores `0`.
///
/// So `cache_creation` is non-zero for Claude only, and the three columns
/// sum to the real token count without double counting anywhere.
public actor UsageEventLedger: CostUsageEventSink {
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let calendar: Calendar
    private let dayFormatter: DateFormatter

    /// Bumping this drops and rebuilds every table on the next open.
    static let schemaVersion = 3
    private static let schemaVersionKey = "schema_version"
    private static let floorKeyPrefix = "detail_floor_day:"
    /// Guard rail on zero-filled trend enumeration: ~135 years of daily
    /// buckets. A filter wider than this is a caller bug, not a chart.
    private static let maximumTrendBuckets = 50_000

    public init(url: URL = VibeBarLocalStore.usageEventsLedgerURL) throws {
        if url == VibeBarLocalStore.usageEventsLedgerURL {
            try VibeBarLocalStore.ensureBaseDirectory()
        }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.locale = Locale(identifier: "en_US_POSIX")
        self.calendar = gregorian
        let formatter = DateFormatter()
        formatter.calendar = gregorian
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = gregorian.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        self.dayFormatter = formatter

        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle
        else {
            if handle != nil { sqlite3_close_v2(handle) }
            throw UsageLedgerError.open
        }
        sqlite3_busy_timeout(handle, 5_000)
        do {
            try Self.initialize(handle)
            database = handle
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close_v2(database) }
    }

    // MARK: - Schema

    private static func initialize(_ database: OpaquePointer) throws {
        let preamble = """
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS ledger_meta (
                key TEXT PRIMARY KEY,
                value TEXT
            );
            """
        guard sqlite3_exec(database, preamble, nil, nil, nil) == SQLITE_OK else {
            throw UsageLedgerError.open
        }
        if let stored = storedSchemaVersion(database), stored != schemaVersion {
            // Every row here is reconstructible from the on-disk scan cache,
            // so a migration is never worth writing: drop, recreate, and let
            // the next refresh re-ingest.
            let reset = """
                DROP TABLE IF EXISTS usage_events;
                DROP TABLE IF EXISTS usage_daily_rollups;
                DROP TABLE IF EXISTS ingested_files;
                DELETE FROM ledger_meta;
                """
            guard sqlite3_exec(database, reset, nil, nil, nil) == SQLITE_OK else {
                throw UsageLedgerError.open
            }
        }
        let schema = """
            CREATE TABLE IF NOT EXISTS usage_events (
                id INTEGER PRIMARY KEY,
                tool TEXT NOT NULL,
                ts INTEGER NOT NULL,
                day TEXT NOT NULL,
                model TEXT NOT NULL,
                fresh_input INTEGER NOT NULL DEFAULT 0,
                output INTEGER NOT NULL DEFAULT 0,
                cache_read INTEGER NOT NULL DEFAULT 0,
                cache_creation INTEGER NOT NULL DEFAULT 0,
                cost_micros INTEGER,
                session_id TEXT,
                message_id TEXT,
                request_id TEXT,
                service_tier TEXT,
                is_sidechain INTEGER,
                path_role TEXT,
                source_key TEXT,
                dedupe_key TEXT NOT NULL UNIQUE
            );
            CREATE INDEX IF NOT EXISTS usage_events_tool_ts_idx ON usage_events(tool, ts);
            CREATE INDEX IF NOT EXISTS usage_events_day_idx ON usage_events(day);
            CREATE INDEX IF NOT EXISTS usage_events_model_idx ON usage_events(model);
            CREATE TABLE IF NOT EXISTS usage_daily_rollups (
                day TEXT NOT NULL,
                tool TEXT NOT NULL,
                model TEXT NOT NULL,
                requests INTEGER NOT NULL DEFAULT 0,
                fresh_input INTEGER NOT NULL DEFAULT 0,
                output INTEGER NOT NULL DEFAULT 0,
                cache_read INTEGER NOT NULL DEFAULT 0,
                cache_creation INTEGER NOT NULL DEFAULT 0,
                cost_micros INTEGER NOT NULL DEFAULT 0,
                unpriced INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(day, tool, model)
            );
            CREATE TABLE IF NOT EXISTS ingested_files (
                tool TEXT NOT NULL,
                file_key TEXT NOT NULL,
                mtime REAL NOT NULL,
                size INTEGER NOT NULL,
                PRIMARY KEY(tool, file_key)
            );
            """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            throw UsageLedgerError.open
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            """
            INSERT INTO ledger_meta(key, value) VALUES(?, ?)
               ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            -1, &statement, nil
        ) == SQLITE_OK, let statement else { throw UsageLedgerError.open }
        defer { sqlite3_finalize(statement) }
        let destructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, schemaVersionKey, -1, destructor)
        sqlite3_bind_text(statement, 2, String(schemaVersion), -1, destructor)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw UsageLedgerError.open }
    }

    private static func storedSchemaVersion(_ database: OpaquePointer) -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT value FROM ledger_meta WHERE key = '\(schemaVersionKey)'",
            -1, &statement, nil
        ) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0)
        else { return nil }
        return Int(String(cString: raw))
    }

    // MARK: - Ingest

    /// `CostUsageEventSink` conformance. Failures are swallowed on purpose:
    /// the ledger is a side channel of the cost scan, and a locked or
    /// corrupt database must never take the scan (or the popover) down with
    /// it. The next refresh retries the same batch.
    public func consume(_ batch: UsageEventFileBatch) async {
        try? ingest(batch)
    }

    /// Throwing form of `consume`, for tests and for callers that want to
    /// see ingest failures.
    public func ingest(_ batch: UsageEventFileBatch) throws {
        let fileKey = CostUsageScanCache.entryKey(for: batch.filePath)
        if let stored = try storedFingerprint(tool: batch.tool, fileKey: fileKey),
           stored.size == batch.size,
           abs(stored.mtime - batch.mtime.timeIntervalSince1970) <= 1.0 {
            return
        }
        let floor = try detailFloorDay(for: batch.tool)
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare(Self.insertEventSQL)
            defer { sqlite3_finalize(statement) }
            for (index, priced) in batch.events.enumerated() {
                let event = priced.event
                let day = dayString(for: event.date)
                // Below the floor the detail rows have already been folded
                // into `usage_daily_rollups`; re-inserting them would double
                // count every historical day on the next full re-scan.
                if let floor, day <= floor { continue }
                let cacheCreation = Int64(max(0, event.cacheCreation ?? 0))
                let cacheRead = max(0, Int64(event.cache) - cacheCreation)
                let freshInput = Int64(max(0, event.input))
                let output = Int64(max(0, event.output))
                let timestamp = Int64(event.date.timeIntervalSince1970.rounded(.down))
                let key = dedupeKey(
                    event: event,
                    tool: batch.tool,
                    fileKey: fileKey,
                    index: index,
                    timestamp: timestamp,
                    freshInput: freshInput,
                    output: output,
                    cacheRead: cacheRead,
                    cacheCreation: cacheCreation
                )
                let bindings: [Binding] = [
                    .text(batch.tool.rawValue),
                    .integer(timestamp),
                    .text(day),
                    .text(event.model),
                    .integer(freshInput),
                    .integer(output),
                    .integer(cacheRead),
                    .integer(cacheCreation),
                    priced.costMicros.map(Binding.integer) ?? .null,
                    event.sessionId.map(Binding.text) ?? .null,
                    event.messageId.map(Binding.text) ?? .null,
                    event.requestId.map(Binding.text) ?? .null,
                    event.serviceTier.map(Binding.text) ?? .null,
                    event.isSidechain.map { Binding.integer($0 ? 1 : 0) } ?? .null,
                    event.pathRole.map { Binding.text($0.rawValue) } ?? .null,
                    event.sourceKey.map(Binding.text) ?? .null,
                    .text(key)
                ]
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                for (offset, value) in bindings.enumerated() {
                    bind(value, at: Int32(offset + 1), to: statement)
                }
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw UsageLedgerError.statement
                }
            }
            try run(
                """
                INSERT INTO ingested_files(tool, file_key, mtime, size) VALUES(?, ?, ?, ?)
                   ON CONFLICT(tool, file_key) DO UPDATE SET
                       mtime = excluded.mtime,
                       size = excluded.size
                """,
                [
                    .text(batch.tool.rawValue), .text(fileKey),
                    .real(batch.mtime.timeIntervalSince1970), .integer(batch.size)
                ]
            )
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Conflict resolution mirrors `CostUsageScanner.claudeEventWins`: the
    /// same assistant message can appear in a parent transcript and in a
    /// sidechain / subagent copy, and only one of them is a real billable
    /// request. Preference order, best first:
    ///
    /// 1. not a sidechain,
    /// 2. `pathRole == .parent` (i.e. not under `/subagents/`),
    /// 3. lexicographically smallest `source_key`.
    ///
    /// The third rule is the scanner's actual tiebreak — it keeps the
    /// winner stable no matter which file the scan walks first — so the
    /// ledger and the aggregator agree on which copy survives. Expressed as
    /// a `DO UPDATE ... WHERE`: when the incoming row loses, SQLite leaves
    /// the stored row untouched and the insert is silently dropped.
    private static let insertEventSQL = """
        INSERT INTO usage_events(
               tool, ts, day, model, fresh_input, output, cache_read, cache_creation,
               cost_micros, session_id, message_id, request_id, service_tier,
               is_sidechain, path_role, source_key, dedupe_key
           ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT(dedupe_key) DO UPDATE SET
               tool = excluded.tool,
               ts = excluded.ts,
               day = excluded.day,
               model = excluded.model,
               fresh_input = excluded.fresh_input,
               output = excluded.output,
               cache_read = excluded.cache_read,
               cache_creation = excluded.cache_creation,
               cost_micros = excluded.cost_micros,
               session_id = excluded.session_id,
               message_id = excluded.message_id,
               request_id = excluded.request_id,
               service_tier = excluded.service_tier,
               is_sidechain = excluded.is_sidechain,
               path_role = excluded.path_role,
               source_key = excluded.source_key
           WHERE
               (CASE WHEN COALESCE(excluded.is_sidechain, 0) = 0 THEN 0 ELSE 1 END)
             < (CASE WHEN COALESCE(usage_events.is_sidechain, 0) = 0 THEN 0 ELSE 1 END)
            OR (
               (CASE WHEN COALESCE(excluded.is_sidechain, 0) = 0 THEN 0 ELSE 1 END)
             = (CASE WHEN COALESCE(usage_events.is_sidechain, 0) = 0 THEN 0 ELSE 1 END)
             AND (
                  (CASE WHEN COALESCE(excluded.path_role, 'parent') = 'parent' THEN 0 ELSE 1 END)
                < (CASE WHEN COALESCE(usage_events.path_role, 'parent') = 'parent' THEN 0 ELSE 1 END)
               OR (
                  (CASE WHEN COALESCE(excluded.path_role, 'parent') = 'parent' THEN 0 ELSE 1 END)
                = (CASE WHEN COALESCE(usage_events.path_role, 'parent') = 'parent' THEN 0 ELSE 1 END)
                AND COALESCE(excluded.source_key, '') < COALESCE(usage_events.source_key, '')
               )
             )
            )
        """

    /// A Claude request is uniquely identified by
    /// `(sessionId, messageId, requestId)` across every transcript file that
    /// copied it. Message/request ids can be reused by different sessions, so
    /// omitting the session id silently merged unrelated billable requests and
    /// made Workbench totals disagree with the CostSnapshot built by the same
    /// scan. Every other provider leaves at least one of them nil;
    /// those fall back to a digest that is stable across re-scans of the
    /// same file (hashed path + position + timestamp + model + tokens) so a
    /// re-ingest updates instead of duplicating.
    private func dedupeKey(
        event: CostUsageScanCache.ParsedEvent,
        tool: ToolType,
        fileKey: String,
        index: Int,
        timestamp: Int64,
        freshInput: Int64,
        output: Int64,
        cacheRead: Int64,
        cacheCreation: Int64
    ) -> String {
        if tool == .claude,
           let sessionId = event.sessionId,
           let messageId = event.messageId,
           let requestId = event.requestId {
            // `Binding.text` uses SQLite's NUL-terminated form. Keeping the
            // scanner's in-memory `\0` separator here would therefore persist
            // only `m:<sessionId>` and collapse an entire Claude session into
            // one request. Hash the length-delimited tuple into a printable,
            // fixed-width key instead.
            let tuple = [sessionId, messageId, requestId]
                .map { "\($0.utf8.count):\($0)" }
                .joined(separator: "|")
            return PrivacyPreservingHash.fileComponent(prefix: "cm-v3", rawValue: tuple)
        }
        let seed = [
            tool.rawValue, fileKey, String(index), String(timestamp), event.model,
            String(freshInput), String(output), String(cacheRead), String(cacheCreation)
        ].joined(separator: "|")
        return "f:" + PrivacyPreservingHash.fileComponent(prefix: "ue-v1", rawValue: seed)
    }

    private func storedFingerprint(
        tool: ToolType,
        fileKey: String
    ) throws -> (mtime: TimeInterval, size: Int64)? {
        let statement = try prepare(
            "SELECT mtime, size FROM ingested_files WHERE tool = ? AND file_key = ?"
        )
        defer { sqlite3_finalize(statement) }
        bind(.text(tool.rawValue), at: 1, to: statement)
        bind(.text(fileKey), at: 2, to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw UsageLedgerError.statement }
        return (sqlite3_column_double(statement, 0), sqlite3_column_int64(statement, 1))
    }

    // MARK: - Rollup / retention

    /// Fold detail rows older than `detailDays` into `usage_daily_rollups`,
    /// delete them, and advance the per-tool detail floor so a later
    /// re-scan of the same history cannot re-insert them.
    ///
    /// When `retentionDays > 0`, rollup rows (and any straggling detail
    /// rows) older than the retention window are deleted outright, and the
    /// floor advances past the pruned window for the same reason.
    public func rollupAndPrune(
        now: Date = Date(),
        detailDays: Int = 30,
        retentionDays: Int
    ) throws {
        let today = calendar.startOfDay(for: now)
        let detailFrom = calendar.date(byAdding: .day, value: -max(0, detailDays), to: today) ?? today
        let rollupCutoffDay = dayString(for: detailFrom)
        var floorTarget = dayString(
            for: calendar.date(byAdding: .day, value: -1, to: detailFrom) ?? detailFrom
        )

        let normalizedRetention = CostDataSettings.normalizedRetentionDays(retentionDays)
        var retentionDay: String?
        if normalizedRetention > 0 {
            let start = calendar.date(
                byAdding: .day, value: -(normalizedRetention - 1), to: today
            ) ?? today
            retentionDay = dayString(for: start)
            let dayBefore = dayString(
                for: calendar.date(byAdding: .day, value: -1, to: start) ?? start
            )
            if dayBefore > floorTarget { floorTarget = dayBefore }
        }

        try execute("BEGIN IMMEDIATE")
        do {
            try run(Self.rollupSQL, [.text(rollupCutoffDay)])
            try run("DELETE FROM usage_events WHERE day < ?", [.text(rollupCutoffDay)])
            if let retentionDay {
                try run("DELETE FROM usage_daily_rollups WHERE day < ?", [.text(retentionDay)])
                try run("DELETE FROM usage_events WHERE day < ?", [.text(retentionDay)])
            }
            // Only tools that have actually been ingested get a floor. A
            // provider whose first scan lands after this call must still be
            // allowed to backfill its own history.
            for tool in try ingestedTools() {
                let current = try detailFloorDay(for: tool)
                guard current == nil || current! < floorTarget else { continue }
                try run(
                    """
                    INSERT INTO ledger_meta(key, value) VALUES(?, ?)
                       ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                    [.text(Self.floorKeyPrefix + tool.rawValue), .text(floorTarget)]
                )
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private static let rollupSQL = """
        INSERT INTO usage_daily_rollups(
               day, tool, model, requests, fresh_input, output,
               cache_read, cache_creation, cost_micros, unpriced
           )
           SELECT day, tool, model, COUNT(*),
                  COALESCE(SUM(fresh_input), 0), COALESCE(SUM(output), 0),
                  COALESCE(SUM(cache_read), 0), COALESCE(SUM(cache_creation), 0),
                  COALESCE(SUM(cost_micros), 0),
                  SUM(CASE WHEN cost_micros IS NULL THEN 1 ELSE 0 END)
             FROM usage_events WHERE day < ?
            GROUP BY day, tool, model
           ON CONFLICT(day, tool, model) DO UPDATE SET
               requests = usage_daily_rollups.requests + excluded.requests,
               fresh_input = usage_daily_rollups.fresh_input + excluded.fresh_input,
               output = usage_daily_rollups.output + excluded.output,
               cache_read = usage_daily_rollups.cache_read + excluded.cache_read,
               cache_creation = usage_daily_rollups.cache_creation + excluded.cache_creation,
               cost_micros = usage_daily_rollups.cost_micros + excluded.cost_micros,
               unpriced = usage_daily_rollups.unpriced + excluded.unpriced
        """

    /// Wipe every ingested row. The schema (and its version stamp) stays so
    /// the next scan can start writing immediately.
    public func eraseAll() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM usage_events")
            try execute("DELETE FROM usage_daily_rollups")
            try execute("DELETE FROM ingested_files")
            try run("DELETE FROM ledger_meta WHERE key <> ?", [.text(Self.schemaVersionKey)])
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Oldest day that still has request-level rows for `tool`, or nil when
    /// nothing has been rolled up yet.
    public func detailFloorDay(for tool: ToolType) throws -> String? {
        try scalarText(
            "SELECT value FROM ledger_meta WHERE key = ?",
            [.text(Self.floorKeyPrefix + tool.rawValue)]
        )
    }

    private func ingestedTools() throws -> [ToolType] {
        let statement = try prepare("SELECT DISTINCT tool FROM ingested_files")
        defer { sqlite3_finalize(statement) }
        var tools: [ToolType] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = columnText(statement, 0), let tool = ToolType(rawValue: raw) {
                tools.append(tool)
            }
        }
        return tools
    }

    // MARK: - Queries

    /// Headline totals over `filter`, stitched across the detail/rollup
    /// boundary: request-level rows contribute for the days above each
    /// tool's floor, daily rollups contribute for the whole days below it.
    public func summary(_ filter: UsageQueryFilter) throws -> UsageSummaryMetrics {
        var requests = 0
        var unpriced = 0
        var priced = 0
        var freshInput: Int64 = 0
        var output: Int64 = 0
        var cacheRead: Int64 = 0
        var cacheCreation: Int64 = 0
        var cost: Int64 = 0

        let detail = detailPredicate(filter)
        let detailStatement = try prepare(
            """
            SELECT COUNT(*), COALESCE(SUM(fresh_input), 0), COALESCE(SUM(output), 0),
                   COALESCE(SUM(cache_read), 0), COALESCE(SUM(cache_creation), 0),
                   COALESCE(SUM(cost_micros), 0),
                   COALESCE(SUM(CASE WHEN cost_micros IS NULL THEN 1 ELSE 0 END), 0)
              FROM usage_events WHERE \(detail.sql)
            """
        )
        defer { sqlite3_finalize(detailStatement) }
        bindAll(detail.bindings, to: detailStatement)
        if sqlite3_step(detailStatement) == SQLITE_ROW {
            requests += Int(sqlite3_column_int64(detailStatement, 0))
            freshInput += sqlite3_column_int64(detailStatement, 1)
            output += sqlite3_column_int64(detailStatement, 2)
            cacheRead += sqlite3_column_int64(detailStatement, 3)
            cacheCreation += sqlite3_column_int64(detailStatement, 4)
            cost += sqlite3_column_int64(detailStatement, 5)
            let detailUnpriced = Int(sqlite3_column_int64(detailStatement, 6))
            unpriced += detailUnpriced
            priced += Int(sqlite3_column_int64(detailStatement, 0)) - detailUnpriced
        }

        if let rollup = rollupPredicate(filter) {
            let statement = try prepare(
                """
                SELECT COALESCE(SUM(requests), 0), COALESCE(SUM(fresh_input), 0),
                       COALESCE(SUM(output), 0), COALESCE(SUM(cache_read), 0),
                       COALESCE(SUM(cache_creation), 0), COALESCE(SUM(cost_micros), 0),
                       COALESCE(SUM(unpriced), 0)
                  FROM usage_daily_rollups WHERE \(rollup.sql)
                """
            )
            defer { sqlite3_finalize(statement) }
            bindAll(rollup.bindings, to: statement)
            if sqlite3_step(statement) == SQLITE_ROW {
                let rollupRequests = Int(sqlite3_column_int64(statement, 0))
                let rollupUnpriced = Int(sqlite3_column_int64(statement, 6))
                requests += rollupRequests
                freshInput += sqlite3_column_int64(statement, 1)
                output += sqlite3_column_int64(statement, 2)
                cacheRead += sqlite3_column_int64(statement, 3)
                cacheCreation += sqlite3_column_int64(statement, 4)
                cost += sqlite3_column_int64(statement, 5)
                unpriced += rollupUnpriced
                priced += rollupRequests - rollupUnpriced
            }
        }

        return UsageSummaryMetrics(
            requests: requests,
            unpricedRequests: unpriced,
            costMicros: priced > 0 ? cost : nil,
            freshInput: freshInput,
            output: output,
            cacheRead: cacheRead,
            cacheCreation: cacheCreation
        )
    }

    /// Zero-filled series across the filter's range.
    ///
    /// Hourly buckets read request-level rows only — daily rollups have no
    /// sub-day resolution to give back. An explicitly requested hourly range
    /// can nevertheless cross a tool's detail floor after retention has run,
    /// so resolve it against the floors actually recorded in this ledger. A
    /// day series is preferable to an apparently valid all-zero hourly chart
    /// that disagrees with the summary beside it.
    public func trend(
        _ filter: UsageQueryFilter,
        bucket: UsageTrendBucket? = nil
    ) throws -> UsageTrendSeries {
        let requested = bucket ?? UsageTrendBucket.recommended(for: filter.range)
        let resolved = try resolvedTrendBucket(for: filter, requested: requested)
        let starts = bucketStarts(for: filter.range, bucket: resolved)
        var totals: [Date: Accumulator] = [:]
        var providerTotals: [ToolType: [Date: Accumulator]] = [:]

        func add(_ statement: OpaquePointer, tool: ToolType, key: Date, offset: Int32) {
            totals[key, default: .zero].add(statement, offset: offset)
            providerTotals[tool, default: [:]][key, default: .zero].add(statement, offset: offset)
        }

        switch resolved {
        case .hour:
            let detail = detailPredicate(filter)
            let statement = try prepare(
                """
                SELECT ts, tool, fresh_input, output, cache_read, cache_creation,
                       COALESCE(cost_micros, 0)
                  FROM usage_events WHERE \(detail.sql)
                """
            )
            defer { sqlite3_finalize(statement) }
            bindAll(detail.bindings, to: statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                let date = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0)))
                guard let key = calendar.dateInterval(of: .hour, for: date)?.start,
                      let rawTool = columnText(statement, 1),
                      let tool = ToolType(rawValue: rawTool)
                else { continue }
                add(statement, tool: tool, key: key, offset: 2)
            }
        case .day, .week:
            let detail = detailPredicate(filter)
            let detailStatement = try prepare(
                """
                SELECT day, tool, COALESCE(SUM(fresh_input), 0), COALESCE(SUM(output), 0),
                       COALESCE(SUM(cache_read), 0), COALESCE(SUM(cache_creation), 0),
                       COALESCE(SUM(cost_micros), 0)
                  FROM usage_events WHERE \(detail.sql) GROUP BY day, tool
                """
            )
            defer { sqlite3_finalize(detailStatement) }
            bindAll(detail.bindings, to: detailStatement)
            while sqlite3_step(detailStatement) == SQLITE_ROW {
                guard let raw = columnText(detailStatement, 0),
                      let day = dayFormatter.date(from: raw),
                      let key = bucketStart(for: day, bucket: resolved),
                      let rawTool = columnText(detailStatement, 1),
                      let tool = ToolType(rawValue: rawTool)
                else { continue }
                add(detailStatement, tool: tool, key: key, offset: 2)
            }
            if let rollup = rollupPredicate(filter) {
                let statement = try prepare(
                    """
                    SELECT day, tool, COALESCE(SUM(fresh_input), 0), COALESCE(SUM(output), 0),
                           COALESCE(SUM(cache_read), 0), COALESCE(SUM(cache_creation), 0),
                           COALESCE(SUM(cost_micros), 0)
                      FROM usage_daily_rollups WHERE \(rollup.sql) GROUP BY day, tool
                    """
                )
                defer { sqlite3_finalize(statement) }
                bindAll(rollup.bindings, to: statement)
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let raw = columnText(statement, 0),
                          let day = dayFormatter.date(from: raw),
                          let key = bucketStart(for: day, bucket: resolved),
                          let rawTool = columnText(statement, 1),
                          let tool = ToolType(rawValue: rawTool)
                    else { continue }
                    add(statement, tool: tool, key: key, offset: 2)
                }
            }
        }

        let points = starts.map { start -> UsageTrendPoint in
            let value = totals[start] ?? .zero
            return UsageTrendPoint(
                bucketStart: start,
                freshInput: value.freshInput,
                output: value.output,
                cacheRead: value.cacheRead,
                cacheCreation: value.cacheCreation,
                costMicros: value.cost
            )
        }
        let providers = providerTotals
            .map { tool, values in
                UsageProviderTrendSeries(
                    tool: tool,
                    points: starts.map { start in
                        let value = values[start] ?? .zero
                        return UsageTrendPoint(
                            bucketStart: start,
                            freshInput: value.freshInput,
                            output: value.output,
                            cacheRead: value.cacheRead,
                            cacheCreation: value.cacheCreation,
                            costMicros: value.cost
                        )
                    }
                )
            }
            .sorted { $0.tool.rawValue < $1.tool.rawValue }
        return UsageTrendSeries(bucket: resolved, points: points, providerSeries: providers)
    }

    /// The finest trend bucket this ledger can draw honestly for `filter`.
    ///
    /// A floor is the last local day folded into `usage_daily_rollups`; detail
    /// starts on the following midnight. A range touching that folded day has
    /// no hour-level evidence, even if it has only 24 buckets and even if a
    /// different selected tool has newer detail. Falling back for the whole
    /// series keeps the stacked provider chart and its summary on the same
    /// data contract.
    private func resolvedTrendBucket(
        for filter: UsageQueryFilter,
        requested: UsageTrendBucket
    ) throws -> UsageTrendBucket {
        guard requested == .hour else { return requested }

        let tools: [ToolType]
        if let filteredTools = filter.tools {
            tools = filteredTools
        } else {
            tools = try ingestedTools()
        }
        for tool in tools {
            guard let floor = try detailFloorDay(for: tool),
                  let floorDay = dayFormatter.date(from: floor),
                  let firstDetailDay = calendar.date(byAdding: .day, value: 1, to: floorDay)
            else { continue }
            if filter.range.start < firstDetailDay {
                return .day
            }
        }
        return .hour
    }

    /// Whether every selected provider still has request-level evidence for
    /// every hour in `filter`. The Workbench uses this to keep the Hourly
    /// picker synchronized with the defensive fallback in `trend`.
    public func supportsHourlyTrend(_ filter: UsageQueryFilter) throws -> Bool {
        try resolvedTrendBucket(for: filter, requested: .hour) == .hour
    }

    /// One page of request-level rows, newest first.
    ///
    /// Request-level rows exist only **above** each tool's detail floor —
    /// older history has been folded into `usage_daily_rollups` and can no
    /// longer be enumerated per request. `totalCount` therefore counts the
    /// detail rows in range, not the summary's request count.
    /// `page` is zero-based; a page past the end returns no rows.
    public func requestPage(
        _ filter: UsageQueryFilter,
        page: Int,
        pageSize: Int
    ) throws -> UsageRequestPage {
        let size = min(max(1, pageSize), 1_000)
        let index = max(0, page)
        let detail = detailPredicate(filter)

        let countStatement = try prepare(
            "SELECT COUNT(*) FROM usage_events WHERE \(detail.sql)"
        )
        defer { sqlite3_finalize(countStatement) }
        bindAll(detail.bindings, to: countStatement)
        var total = 0
        if sqlite3_step(countStatement) == SQLITE_ROW {
            total = Int(sqlite3_column_int64(countStatement, 0))
        }

        let statement = try prepare(
            """
            SELECT id, tool, ts, model, fresh_input, output, cache_read, cache_creation,
                   cost_micros, service_tier, session_id, source_key
              FROM usage_events WHERE \(detail.sql)
             ORDER BY ts DESC, id DESC LIMIT ? OFFSET ?
            """
        )
        defer { sqlite3_finalize(statement) }
        bindAll(detail.bindings, to: statement)
        let offset = Int32(detail.bindings.count)
        bind(.integer(Int64(size)), at: offset + 1, to: statement)
        bind(.integer(Int64(index) * Int64(size)), at: offset + 2, to: statement)

        var rows: [UsageRequestRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawTool = columnText(statement, 1),
                  let tool = ToolType(rawValue: rawTool),
                  let model = columnText(statement, 3)
            else { continue }
            rows.append(
                UsageRequestRow(
                    id: sqlite3_column_int64(statement, 0),
                    date: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 2))),
                    tool: tool,
                    model: model,
                    freshInput: sqlite3_column_int64(statement, 4),
                    output: sqlite3_column_int64(statement, 5),
                    cacheRead: sqlite3_column_int64(statement, 6),
                    cacheCreation: sqlite3_column_int64(statement, 7),
                    costMicros: sqlite3_column_type(statement, 8) == SQLITE_NULL
                        ? nil : sqlite3_column_int64(statement, 8),
                    serviceTier: columnText(statement, 9),
                    sessionId: columnText(statement, 10),
                    sourceKey: columnText(statement, 11)
                )
            )
        }
        return UsageRequestPage(rows: rows, totalCount: total, page: index, pageSize: size)
    }

    /// Per-provider totals, detail ∪ rollups, heaviest first.
    public func providerStats(_ filter: UsageQueryFilter) throws -> [UsageProviderStat] {
        var totals: [ToolType: (requests: Int, tokens: Int64, cost: Int64)] = [:]
        try forEachGroup(filter, column: "tool") { key, requests, tokens, cost in
            guard let tool = ToolType(rawValue: key) else { return }
            totals[tool, default: (0, 0, 0)].requests += requests
            totals[tool, default: (0, 0, 0)].tokens += tokens
            totals[tool, default: (0, 0, 0)].cost += cost
        }
        return totals
            .map {
                UsageProviderStat(
                    tool: $0.key, requests: $0.value.requests,
                    totalTokens: $0.value.tokens, costMicros: $0.value.cost
                )
            }
            .sorted {
                $0.totalTokens == $1.totalTokens
                    ? $0.tool.rawValue < $1.tool.rawValue
                    : $0.totalTokens > $1.totalTokens
            }
    }

    /// Per-model totals, detail ∪ rollups, heaviest first.
    public func modelStats(_ filter: UsageQueryFilter) throws -> [UsageModelStat] {
        var totals: [String: (requests: Int, tokens: Int64, cost: Int64)] = [:]
        try forEachGroup(filter, column: "model") { key, requests, tokens, cost in
            totals[key, default: (0, 0, 0)].requests += requests
            totals[key, default: (0, 0, 0)].tokens += tokens
            totals[key, default: (0, 0, 0)].cost += cost
        }
        return totals
            .map { entry in
                UsageModelStat(
                    model: entry.key,
                    requests: entry.value.requests,
                    totalTokens: entry.value.tokens,
                    costMicros: entry.value.cost,
                    avgCostMicrosPerRequest: UsageModelStat.averageMicros(
                        total: entry.value.cost, requests: entry.value.requests
                    )
                )
            }
            .sorted {
                $0.totalTokens == $1.totalTokens
                    ? $0.model < $1.model
                    : $0.totalTokens > $1.totalTokens
            }
    }

    /// Every model name the ledger knows about, detail ∪ rollups, sorted.
    /// Intended to populate a filter picker, so it deliberately ignores the
    /// date range.
    public func availableModels(tools: [ToolType]? = nil) throws -> [String] {
        if let tools, tools.isEmpty { return [] }
        var clause = ""
        var bindings: [Binding] = []
        if let tools {
            clause = " WHERE tool IN (\(placeholders(tools.count)))"
            bindings = tools.map { .text($0.rawValue) }
        }
        let statement = try prepare(
            """
            SELECT model FROM usage_events\(clause)
            UNION
            SELECT model FROM usage_daily_rollups\(clause)
            ORDER BY 1
            """
        )
        defer { sqlite3_finalize(statement) }
        bindAll(bindings + bindings, to: statement)
        var models: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let model = columnText(statement, 0) { models.append(model) }
        }
        return models
    }

    private func forEachGroup(
        _ filter: UsageQueryFilter,
        column: String,
        _ body: (String, Int, Int64, Int64) -> Void
    ) throws {
        let detail = detailPredicate(filter)
        let detailStatement = try prepare(
            """
            SELECT \(column), COUNT(*),
                   COALESCE(SUM(fresh_input + output + cache_read + cache_creation), 0),
                   COALESCE(SUM(cost_micros), 0)
              FROM usage_events WHERE \(detail.sql) GROUP BY \(column)
            """
        )
        defer { sqlite3_finalize(detailStatement) }
        bindAll(detail.bindings, to: detailStatement)
        while sqlite3_step(detailStatement) == SQLITE_ROW {
            guard let key = columnText(detailStatement, 0) else { continue }
            body(
                key,
                Int(sqlite3_column_int64(detailStatement, 1)),
                sqlite3_column_int64(detailStatement, 2),
                sqlite3_column_int64(detailStatement, 3)
            )
        }
        guard let rollup = rollupPredicate(filter) else { return }
        let statement = try prepare(
            """
            SELECT \(column), COALESCE(SUM(requests), 0),
                   COALESCE(SUM(fresh_input + output + cache_read + cache_creation), 0),
                   COALESCE(SUM(cost_micros), 0)
              FROM usage_daily_rollups WHERE \(rollup.sql) GROUP BY \(column)
            """
        )
        defer { sqlite3_finalize(statement) }
        bindAll(rollup.bindings, to: statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = columnText(statement, 0) else { continue }
            body(
                key,
                Int(sqlite3_column_int64(statement, 1)),
                sqlite3_column_int64(statement, 2),
                sqlite3_column_int64(statement, 3)
            )
        }
    }

    // MARK: - Predicates

    private struct Predicate {
        let sql: String
        let bindings: [Binding]
    }

    private struct Accumulator {
        var freshInput: Int64 = 0
        var output: Int64 = 0
        var cacheRead: Int64 = 0
        var cacheCreation: Int64 = 0
        var cost: Int64 = 0

        static let zero = Accumulator()

        mutating func add(_ statement: OpaquePointer, offset: Int32) {
            freshInput += sqlite3_column_int64(statement, offset)
            output += sqlite3_column_int64(statement, offset + 1)
            cacheRead += sqlite3_column_int64(statement, offset + 2)
            cacheCreation += sqlite3_column_int64(statement, offset + 3)
            cost += sqlite3_column_int64(statement, offset + 4)
        }
    }

    private func detailPredicate(_ filter: UsageQueryFilter) -> Predicate {
        if filter.tools?.isEmpty == true || filter.models?.isEmpty == true {
            return Predicate(sql: "0", bindings: [])
        }
        var clauses = ["ts >= ?", "ts < ?"]
        var bindings: [Binding] = [
            .integer(Int64(filter.range.start.timeIntervalSince1970.rounded(.down))),
            .integer(Int64(filter.range.end.timeIntervalSince1970.rounded(.up)))
        ]
        if let tools = filter.tools {
            clauses.append("tool IN (\(placeholders(tools.count)))")
            bindings.append(contentsOf: tools.map { .text($0.rawValue) })
        }
        if let models = filter.models {
            clauses.append("model IN (\(placeholders(models.count)))")
            bindings.append(contentsOf: models.map { .text($0) })
        }
        return Predicate(sql: clauses.joined(separator: " AND "), bindings: bindings)
    }

    /// Rollup rows are whole days, so they may only answer for days the
    /// filter covers end to end. A range that starts mid-afternoon simply
    /// does not see that day's rollup — which is correct, because a partial
    /// day cannot be reconstructed from a daily total.
    private func rollupPredicate(_ filter: UsageQueryFilter) -> Predicate? {
        if filter.tools?.isEmpty == true || filter.models?.isEmpty == true { return nil }
        let startOfStart = calendar.startOfDay(for: filter.range.start)
        let firstFull = startOfStart == filter.range.start
            ? startOfStart
            : (calendar.date(byAdding: .day, value: 1, to: startOfStart) ?? startOfStart)
        let endBoundary = calendar.startOfDay(for: filter.range.end)
        guard let lastFull = calendar.date(byAdding: .day, value: -1, to: endBoundary),
              lastFull >= firstFull
        else { return nil }

        var clauses = ["day >= ?", "day <= ?"]
        var bindings: [Binding] = [.text(dayString(for: firstFull)), .text(dayString(for: lastFull))]
        if let tools = filter.tools {
            clauses.append("tool IN (\(placeholders(tools.count)))")
            bindings.append(contentsOf: tools.map { .text($0.rawValue) })
        }
        if let models = filter.models {
            clauses.append("model IN (\(placeholders(models.count)))")
            bindings.append(contentsOf: models.map { .text($0) })
        }
        return Predicate(sql: clauses.joined(separator: " AND "), bindings: bindings)
    }

    private func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: max(1, count)).joined(separator: ", ")
    }

    private func bucketStarts(for range: DateInterval, bucket: UsageTrendBucket) -> [Date] {
        let component: Calendar.Component
        var cursor: Date
        switch bucket {
        case .hour:
            component = .hour
            cursor = calendar.dateInterval(of: .hour, for: range.start)?.start ?? range.start
        case .day:
            component = .day
            cursor = calendar.startOfDay(for: range.start)
        case .week:
            component = .weekOfYear
            cursor = calendar.dateInterval(of: .weekOfYear, for: range.start)?.start
                ?? calendar.startOfDay(for: range.start)
        }
        var out: [Date] = []
        while cursor < range.end, out.count < Self.maximumTrendBuckets {
            out.append(cursor)
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor),
                  next > cursor
            else { break }
            cursor = next
        }
        return out
    }

    private func bucketStart(for date: Date, bucket: UsageTrendBucket) -> Date? {
        switch bucket {
        case .hour:
            calendar.dateInterval(of: .hour, for: date)?.start
        case .day:
            calendar.startOfDay(for: date)
        case .week:
            calendar.dateInterval(of: .weekOfYear, for: date)?.start
        }
    }

    /// Local-calendar day key. Matches `CostAggregator`'s bucketing —
    /// gregorian calendar, `en_US_POSIX` locale, the machine's time zone —
    /// so a ledger day and a snapshot day are always the same day.
    func dayString(for date: Date) -> String {
        dayFormatter.string(from: calendar.startOfDay(for: date))
    }

    // MARK: - SQLite plumbing

    private enum Binding {
        case text(String)
        case integer(Int64)
        case real(Double)
        case null
    }

    private func execute(_ sql: String) throws {
        guard let database, sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw UsageLedgerError.statement
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard let database,
              sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw UsageLedgerError.statement }
        return statement
    }

    private func run(_ sql: String, _ bindings: [Binding]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bindAll(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw UsageLedgerError.statement
        }
    }

    private func scalarText(_ sql: String, _ bindings: [Binding]) throws -> String? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bindAll(bindings, to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw UsageLedgerError.statement }
        return columnText(statement, 0)
    }

    private func bindAll(_ bindings: [Binding], to statement: OpaquePointer) {
        for (index, value) in bindings.enumerated() {
            bind(value, at: Int32(index + 1), to: statement)
        }
    }

    private func bind(_ value: Binding, at index: Int32, to statement: OpaquePointer) {
        switch value {
        case let .text(text): sqlite3_bind_text(statement, index, text, -1, transient)
        case let .integer(integer): sqlite3_bind_int64(statement, index, integer)
        case let .real(double): sqlite3_bind_double(statement, index, double)
        case .null: sqlite3_bind_null(statement, index)
        }
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: raw)
    }
}
