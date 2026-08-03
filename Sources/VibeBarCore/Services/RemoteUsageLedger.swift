import Foundation
import SQLite3

public actor RemoteUsageLedger {
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL = VibeBarLocalStore.remoteUsageLedgerURL) throws {
        if url == VibeBarLocalStore.remoteUsageLedgerURL {
            try VibeBarLocalStore.ensureBaseDirectory()
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle
        else {
            if handle != nil { sqlite3_close_v2(handle) }
            throw RemoteSyncError.invalidConfiguration
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

    private static func initialize(_ database: OpaquePointer) throws {
        let sql = """
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=FULL;
            PRAGMA foreign_keys=ON;
            CREATE TABLE IF NOT EXISTS remote_machines (
                workspace_id TEXT NOT NULL,
                producer_id TEXT NOT NULL,
                alias TEXT NOT NULL,
                platform TEXT NOT NULL,
                timezone TEXT NOT NULL,
                probe_version TEXT NOT NULL,
                last_seen_at INTEGER NOT NULL,
                last_scan_at INTEGER NOT NULL,
                last_sequence INTEGER NOT NULL,
                source_status_json TEXT NOT NULL,
                PRIMARY KEY(workspace_id, producer_id)
            );
            CREATE TABLE IF NOT EXISTS remote_source_generations (
                workspace_id TEXT NOT NULL,
                producer_id TEXT NOT NULL,
                source_key TEXT NOT NULL,
                generation INTEGER NOT NULL,
                tool TEXT NOT NULL,
                observed_at INTEGER NOT NULL,
                PRIMARY KEY(workspace_id, producer_id, source_key)
            );
            CREATE TABLE IF NOT EXISTS remote_usage_facts (
                workspace_id TEXT NOT NULL,
                producer_id TEXT NOT NULL,
                event_key TEXT NOT NULL,
                source_key TEXT NOT NULL,
                source_generation INTEGER NOT NULL,
                tool TEXT NOT NULL,
                occurred_at INTEGER NOT NULL,
                observed_at INTEGER NOT NULL,
                model TEXT,
                input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                cache_read_tokens INTEGER NOT NULL,
                cache_creation_tokens INTEGER NOT NULL,
                reasoning_tokens INTEGER NOT NULL,
                tool_tokens INTEGER NOT NULL,
                total_only_tokens INTEGER,
                request_count INTEGER NOT NULL,
                service_tier TEXT,
                accounting TEXT NOT NULL,
                parser_version INTEGER NOT NULL,
                PRIMARY KEY(workspace_id, producer_id, event_key)
            );
            CREATE INDEX IF NOT EXISTS remote_usage_time_idx
                ON remote_usage_facts(workspace_id, producer_id, occurred_at);
            CREATE TABLE IF NOT EXISTS remote_imported_batches (
                workspace_id TEXT NOT NULL,
                producer_id TEXT NOT NULL,
                sequence INTEGER NOT NULL,
                imported_at INTEGER NOT NULL,
                PRIMARY KEY(workspace_id, producer_id, sequence)
            );
            CREATE TABLE IF NOT EXISTS remote_sync_state (
                workspace_id TEXT PRIMARY KEY,
                relay_cursor TEXT,
                last_sync_at INTEGER,
                last_error_code TEXT
            );
            """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw RemoteSyncError.invalidConfiguration
        }
    }

    @discardableResult
    func importBatch(
        _ payload: RemoteIngestPayload,
        sequence: Int64,
        receivedAt: Date
    ) throws -> Bool {
        guard payload.schema == 1 else { throw RemoteSyncError.invalidPayload }
        let workspace = payload.workspaceID.uuidString.lowercased()
        let producer = payload.producerID.uuidString.lowercased()
        try execute("BEGIN IMMEDIATE")
        do {
            if try scalarInt64(
                """
                SELECT 1 FROM remote_imported_batches
                WHERE workspace_id = ? AND producer_id = ? AND sequence = ?
                """,
                [.text(workspace), .text(producer), .integer(sequence)]
            ) != nil {
                try execute("COMMIT")
                return false
            }
            let previous = try scalarInt64(
                """
                SELECT last_sequence FROM remote_machines
                WHERE workspace_id = ? AND producer_id = ?
                """,
                [.text(workspace), .text(producer)]
            )
            let expected = (previous ?? 0) + 1
            guard sequence == expected else {
                if sequence < expected { throw RemoteSyncError.rollback }
                throw RemoteSyncError.sequenceGap(expected: expected, received: sequence)
            }
            guard payload.previousSequence == (sequence == 1 ? nil : sequence - 1) else {
                throw RemoteSyncError.sequenceGap(expected: expected, received: sequence)
            }

            for operation in payload.operations {
                guard case let .sourceReset(reset) = operation else { continue }
                let current = try sourceGeneration(
                    workspace: workspace,
                    producer: producer,
                    sourceKey: reset.sourceKey
                )
                guard reset.sourceGeneration > (current ?? 0) else {
                    throw RemoteSyncError.rollback
                }
                try upsertSourceGeneration(
                    workspace: workspace,
                    producer: producer,
                    sourceKey: reset.sourceKey,
                    generation: reset.sourceGeneration,
                    tool: reset.tool,
                    observedAt: try epoch(reset.observedAt)
                )
            }

            for operation in payload.operations {
                guard case let .usage(usage) = operation else { continue }
                let current = try sourceGeneration(
                    workspace: workspace,
                    producer: producer,
                    sourceKey: usage.sourceKey
                ) ?? 1
                guard usage.sourceGeneration == current else {
                    throw usage.sourceGeneration < current
                        ? RemoteSyncError.rollback
                        : RemoteSyncError.invalidPayload
                }
                if try sourceGeneration(
                    workspace: workspace,
                    producer: producer,
                    sourceKey: usage.sourceKey
                ) == nil {
                    try upsertSourceGeneration(
                        workspace: workspace,
                        producer: producer,
                        sourceKey: usage.sourceKey,
                        generation: usage.sourceGeneration,
                        tool: usage.tool,
                        observedAt: try epoch(usage.observedAt)
                    )
                }
                try upsertUsage(workspace: workspace, producer: producer, usage: usage)
            }

            let sourceData = try JSONEncoder.sorted.encode(payload.status.sources)
            guard let sourceJSON = String(data: sourceData, encoding: .utf8) else {
                throw RemoteSyncError.invalidPayload
            }
            try run(
                """
                INSERT INTO remote_machines(
                       workspace_id, producer_id, alias, platform, timezone, probe_version,
                       last_seen_at, last_scan_at, last_sequence, source_status_json
                   ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(workspace_id, producer_id) DO UPDATE SET
                       alias = excluded.alias,
                       platform = excluded.platform,
                       timezone = excluded.timezone,
                       probe_version = excluded.probe_version,
                       last_seen_at = excluded.last_seen_at,
                       last_scan_at = excluded.last_scan_at,
                       last_sequence = excluded.last_sequence,
                       source_status_json = excluded.source_status_json
                """,
                [
                    .text(workspace), .text(producer), .text(payload.probe.alias),
                    .text(payload.probe.platform), .text(payload.probe.timezone),
                    .text(payload.probe.version), .integer(Int64(receivedAt.timeIntervalSince1970)),
                    .integer(try epoch(payload.status.lastScanAt)), .integer(sequence),
                    .text(sourceJSON)
                ]
            )
            try run(
                """
                INSERT INTO remote_imported_batches(
                       workspace_id, producer_id, sequence, imported_at
                   ) VALUES(?, ?, ?, ?)
                """,
                [
                    .text(workspace), .text(producer), .integer(sequence),
                    .integer(Int64(receivedAt.timeIntervalSince1970))
                ]
            )
            try execute("COMMIT")
            return true
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func relayCursor(workspaceID: UUID) throws -> String? {
        try scalarText(
            "SELECT relay_cursor FROM remote_sync_state WHERE workspace_id = ?",
            [.text(workspaceID.uuidString.lowercased())]
        )
    }

    public func recordSync(
        workspaceID: UUID,
        cursor: String?,
        errorCode: String?,
        at date: Date = Date()
    ) throws {
        try run(
            """
            INSERT INTO remote_sync_state(
                   workspace_id, relay_cursor, last_sync_at, last_error_code
               ) VALUES(?, ?, ?, ?)
               ON CONFLICT(workspace_id) DO UPDATE SET
                   relay_cursor = COALESCE(excluded.relay_cursor, remote_sync_state.relay_cursor),
                   last_sync_at = excluded.last_sync_at,
                   last_error_code = excluded.last_error_code
            """,
            [
                .text(workspaceID.uuidString.lowercased()),
                cursor.map(Binding.text) ?? .null,
                .integer(Int64(date.timeIntervalSince1970)),
                errorCode.map(Binding.text) ?? .null
            ]
        )
    }

    public func machineSummaries(
        workspaceID: UUID,
        now: Date = Date()
    ) throws -> [RemoteMachineSummary] {
        let workspace = workspaceID.uuidString.lowercased()
        let statement = try prepare(
            """
            SELECT producer_id, alias, platform, probe_version, last_seen_at,
                      last_scan_at, last_sequence, source_status_json
               FROM remote_machines WHERE workspace_id = ? ORDER BY alias, producer_id
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(.text(workspace), at: 1, to: statement)
        var summaries: [RemoteMachineSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let producerRaw = columnText(statement, 0),
                  let producerID = UUID(uuidString: producerRaw),
                  let alias = columnText(statement, 1),
                  let platform = columnText(statement, 2),
                  let version = columnText(statement, 3),
                  let sourceJSON = columnText(statement, 7),
                  let sourceData = sourceJSON.data(using: .utf8),
                  let sourceStatuses = try? JSONDecoder().decode([String: String].self, from: sourceData)
            else { throw RemoteSyncError.invalidPayload }
            let usage = try aggregateUsage(
                workspace: workspace,
                producer: producerRaw,
                now: now
            )
            summaries.append(
                RemoteMachineSummary(
                    workspaceID: workspaceID,
                    producerID: producerID,
                    alias: alias,
                    platform: platform,
                    probeVersion: version,
                    lastSeenAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 4))),
                    lastScanAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 5))),
                    lastSequence: sqlite3_column_int64(statement, 6),
                    sourceStatuses: sourceStatuses,
                    todayTokens: usage.today,
                    last7DaysTokens: usage.week,
                    last30DaysTokens: usage.month,
                    allTimeTokens: usage.all,
                    last30DaysCostUSD: usage.cost,
                    byTool: usage.byTool
                )
            )
        }
        return summaries
    }

    private func aggregateUsage(
        workspace: String,
        producer: String,
        now: Date
    ) throws -> (today: Int, week: Int, month: Int, all: Int, cost: Double, byTool: [RemoteToolUsageSummary]) {
        let calendar = Calendar.current
        let startToday = calendar.startOfDay(for: now)
        let startWeek = calendar.date(byAdding: .day, value: -6, to: startToday) ?? startToday
        let startMonth = calendar.date(byAdding: .day, value: -29, to: startToday) ?? startToday
        let statement = try prepare(
            """
            SELECT tool, occurred_at, model, input_tokens, output_tokens,
                      cache_read_tokens, cache_creation_tokens, reasoning_tokens,
                      tool_tokens, total_only_tokens, service_tier
               FROM remote_usage_facts WHERE workspace_id = ? AND producer_id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(.text(workspace), at: 1, to: statement)
        bind(.text(producer), at: 2, to: statement)
        var today = 0, week = 0, month = 0, all = 0
        var byTool: [String: (tokens: Int, cost: Double)] = [:]
        var monthCost = 0.0
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let tool = columnText(statement, 0) else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1)))
            // A signed Probe may still have a clock that is ahead of Core.
            // Keep the fact in the ledger, but do not surface it in any usage
            // aggregate until its occurrence time has actually arrived.
            guard date <= now else { continue }
            let row = UsageRow(
                tool: tool,
                model: columnText(statement, 2),
                input: Int(sqlite3_column_int64(statement, 3)),
                output: Int(sqlite3_column_int64(statement, 4)),
                cacheRead: Int(sqlite3_column_int64(statement, 5)),
                cacheCreation: Int(sqlite3_column_int64(statement, 6)),
                reasoning: Int(sqlite3_column_int64(statement, 7)),
                toolTokens: Int(sqlite3_column_int64(statement, 8)),
                totalOnly: sqlite3_column_type(statement, 9) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int64(statement, 9)),
                serviceTier: columnText(statement, 10)
            )
            let tokens = row.tokenTotal
            all = clampedAdd(all, tokens)
            if date >= startToday { today = clampedAdd(today, tokens) }
            if date >= startWeek { week = clampedAdd(week, tokens) }
            if date >= startMonth {
                month = clampedAdd(month, tokens)
                let cost = costUSD(row)
                monthCost += cost
                byTool[tool, default: (0, 0)].tokens += tokens
                byTool[tool, default: (0, 0)].cost += cost
            }
        }
        return (
            today, week, month, all, monthCost,
            byTool.map { RemoteToolUsageSummary(tool: $0.key, tokens: $0.value.tokens, costUSD: $0.value.cost) }
                .sorted { $0.tokens > $1.tokens }
        )
    }

    private func clampedAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    private struct UsageRow {
        let tool: String
        let model: String?
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheCreation: Int
        let reasoning: Int
        let toolTokens: Int
        let totalOnly: Int?
        let serviceTier: String?
        var tokenTotal: Int {
            totalOnly ?? input + output + cacheRead + cacheCreation + reasoning + toolTokens
        }
    }

    private func costUSD(_ row: UsageRow) -> Double {
        guard row.totalOnly == nil, let model = row.model else { return 0 }
        switch row.tool {
        case "codex":
            return CostUsagePricing.codexCostUSD(
                model: model,
                inputTokens: row.input + row.cacheRead,
                cachedInputTokens: row.cacheRead,
                outputTokens: row.output,
                isFast: row.serviceTier == "fast"
            ) ?? 0
        case "claude":
            return CostUsagePricing.claudeCostUSD(
                model: model,
                inputTokens: row.input,
                cacheReadInputTokens: row.cacheRead,
                cacheCreationInputTokens: row.cacheCreation,
                outputTokens: row.output,
                isFast: row.serviceTier == "fast" || row.serviceTier == "priority"
            ) ?? 0
        case "antigravity":
            return CostUsagePricing.antigravityCostUSD(
                model: model,
                inputTokens: row.input,
                cacheReadInputTokens: row.cacheRead,
                cacheCreationInputTokens: row.cacheCreation,
                outputTokens: row.output + row.reasoning + row.toolTokens
            ) ?? 0
        case "grok":
            return CostUsagePricing.grokCostUSD(
                model: model,
                inputTokens: row.input + row.cacheRead,
                cachedInputTokens: row.cacheRead,
                outputTokens: row.output
            ) ?? 0
        default:
            return 0
        }
    }

    private func upsertUsage(
        workspace: String,
        producer: String,
        usage: RemoteIngestPayload.Usage
    ) throws {
        try run(
            """
            INSERT INTO remote_usage_facts(
                   workspace_id, producer_id, event_key, source_key, source_generation,
                   tool, occurred_at, observed_at, model, input_tokens, output_tokens,
                   cache_read_tokens, cache_creation_tokens, reasoning_tokens, tool_tokens,
                   total_only_tokens, request_count, service_tier, accounting, parser_version
               ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(workspace_id, producer_id, event_key) DO UPDATE SET
                   source_key = excluded.source_key,
                   source_generation = excluded.source_generation,
                   tool = excluded.tool,
                   occurred_at = excluded.occurred_at,
                   observed_at = excluded.observed_at,
                   model = excluded.model,
                   input_tokens = excluded.input_tokens,
                   output_tokens = excluded.output_tokens,
                   cache_read_tokens = excluded.cache_read_tokens,
                   cache_creation_tokens = excluded.cache_creation_tokens,
                   reasoning_tokens = excluded.reasoning_tokens,
                   tool_tokens = excluded.tool_tokens,
                   total_only_tokens = excluded.total_only_tokens,
                   request_count = excluded.request_count,
                   service_tier = excluded.service_tier,
                   accounting = excluded.accounting,
                   parser_version = excluded.parser_version
            """,
            [
                .text(workspace), .text(producer), .text(usage.eventKey), .text(usage.sourceKey),
                .integer(Int64(usage.sourceGeneration)), .text(usage.tool),
                .integer(try epoch(usage.occurredAt)), .integer(try epoch(usage.observedAt)),
                usage.model.map(Binding.text) ?? .null, .integer(Int64(usage.tokens.input)),
                .integer(Int64(usage.tokens.output)), .integer(Int64(usage.tokens.cacheRead)),
                .integer(Int64(usage.tokens.cacheCreation)), .integer(Int64(usage.tokens.reasoning)),
                .integer(Int64(usage.tokens.tool)),
                usage.tokens.totalOnly.map { .integer(Int64($0)) } ?? .null,
                .integer(Int64(usage.requestCount)), usage.serviceTier.map(Binding.text) ?? .null,
                .text(usage.accounting), .integer(Int64(usage.parserVersion))
            ]
        )
    }

    private func sourceGeneration(
        workspace: String,
        producer: String,
        sourceKey: String
    ) throws -> Int? {
        try scalarInt64(
            """
            SELECT generation FROM remote_source_generations
            WHERE workspace_id = ? AND producer_id = ? AND source_key = ?
            """,
            [.text(workspace), .text(producer), .text(sourceKey)]
        ).map(Int.init)
    }

    private func upsertSourceGeneration(
        workspace: String,
        producer: String,
        sourceKey: String,
        generation: Int,
        tool: String,
        observedAt: Int64
    ) throws {
        try run(
            """
            INSERT INTO remote_source_generations(
                   workspace_id, producer_id, source_key, generation, tool, observed_at
               ) VALUES(?, ?, ?, ?, ?, ?)
               ON CONFLICT(workspace_id, producer_id, source_key) DO UPDATE SET
                   generation = excluded.generation,
                   tool = excluded.tool,
                   observed_at = excluded.observed_at
            """,
            [
                .text(workspace), .text(producer), .text(sourceKey),
                .integer(Int64(generation)), .text(tool), .integer(observedAt)
            ]
        )
    }

    private enum Binding {
        case text(String)
        case integer(Int64)
        case null
    }

    private func epoch(_ value: String) throws -> Int64 {
        guard let date = RemoteProtocolCrypto.parseTimestamp(value) else {
            throw RemoteSyncError.invalidPayload
        }
        return Int64(date.timeIntervalSince1970)
    }

    private func execute(_ sql: String) throws {
        guard let database, sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw RemoteSyncError.invalidPayload
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard let database,
              sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw RemoteSyncError.invalidPayload }
        return statement
    }

    private func run(_ sql: String, _ bindings: [Binding]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            bind(value, at: Int32(index + 1), to: statement)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncError.invalidPayload
        }
    }

    private func scalarInt64(_ sql: String, _ bindings: [Binding]) throws -> Int64? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            bind(value, at: Int32(index + 1), to: statement)
        }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw RemoteSyncError.invalidPayload }
        return sqlite3_column_type(statement, 0) == SQLITE_NULL
            ? nil : sqlite3_column_int64(statement, 0)
    }

    private func scalarText(_ sql: String, _ bindings: [Binding]) throws -> String? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            bind(value, at: Int32(index + 1), to: statement)
        }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw RemoteSyncError.invalidPayload }
        return columnText(statement, 0)
    }

    private func bind(_ value: Binding, at index: Int32, to statement: OpaquePointer) {
        switch value {
        case let .text(text): sqlite3_bind_text(statement, index, text, -1, transient)
        case let .integer(integer): sqlite3_bind_int64(statement, index, integer)
        case .null: sqlite3_bind_null(statement, index)
        }
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: raw)
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
