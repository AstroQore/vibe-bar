import Foundation

/// Orchestrates structure parsing for the Workbench: sidecar first, parse on
/// a miss, keep the last few full structures in memory.
///
/// Every entry point is `async` on this actor and every parse runs in a
/// detached utility-priority task, so nothing here can block the main
/// thread; the actor stays responsive while a large file parses, and two
/// requests for the same file share one parse.
///
/// Size policy: a file up to `fullParseLimitBytes` (32 MiB) is parsed in
/// full detail on demand. A larger one is only ever parsed in outline detail
/// as a whole; its turns are materialized one byte window at a time
/// (`turn(at:for:)`), which reads that turn's lines and nothing else.
public actor SessionStructureService {
    public struct Configuration: Sendable, Hashable {
        public var fullParseLimitBytes: Int64
        /// Full structures kept in memory (LRU).
        public var cacheCapacity: Int
        /// `refresh` parses at most this many files per call…
        public var batchMaxFiles: Int
        /// …and stops once this many bytes have been parsed.
        public var batchByteBudget: Int64
        /// `refresh` skips files larger than this; they are parsed on demand.
        public var batchMaxFileBytes: Int64

        public init(
            fullParseLimitBytes: Int64 = 32 * 1024 * 1024,
            cacheCapacity: Int = 8,
            batchMaxFiles: Int = 48,
            batchByteBudget: Int64 = 192 * 1024 * 1024,
            batchMaxFileBytes: Int64 = 512 * 1024 * 1024
        ) {
            self.fullParseLimitBytes = fullParseLimitBytes
            self.cacheCapacity = cacheCapacity
            self.batchMaxFiles = batchMaxFiles
            self.batchByteBudget = batchByteBudget
            self.batchMaxFileBytes = batchMaxFileBytes
        }
    }

    public struct RefreshReport: Hashable, Sendable {
        public var parsed = 0
        public var upToDate = 0
        public var skippedLarge = 0
        public var deferred = 0
        public var missing = 0
        public var failed = 0
        public var unsupported = 0
        public var bytesParsed: Int64 = 0

        public init() {}
    }

    public let configuration: Configuration
    private let store: SessionStructureStore?
    private let codexState: CodexThreadStateReader?
    private var cache: [String: (fingerprint: SessionFileFingerprint, structure: SessionStructure)] = [:]
    private var recency: [String] = []
    private var inFlight: [String: Task<SessionStructure?, Never>] = [:]

    public init(
        store: SessionStructureStore?,
        codexState: CodexThreadStateReader? = nil,
        configuration: Configuration = Configuration()
    ) {
        self.store = store
        self.codexState = codexState
        self.configuration = configuration
    }

    /// The app's instance: sidecar under `~/.vibebar`, Codex state database
    /// under `~/.codex`, both through `RealHomeDirectory`.
    public static func live(configuration: Configuration = Configuration()) -> SessionStructureService {
        SessionStructureService(
            store: SessionStructureStore(),
            codexState: CodexThreadStateReader(homeDirectory: RealHomeDirectory.path),
            configuration: configuration
        )
    }

    public static func supports(_ provider: SessionProvider) -> Bool {
        provider == .codex || provider == .claude
    }

    // MARK: - Reads

    /// Stats for one session — from the sidecar when its row is fresh.
    public func stats(for summary: SessionSummary) async -> SessionStats? {
        await outline(for: summary)?.stats
    }

    /// Outline-detail structure (turn boundaries, counts, usage, previews).
    public func outline(for summary: SessionSummary) async -> SessionStructure? {
        guard Self.supports(summary.provider),
              let fingerprint = SessionFileFingerprint.of(path: summary.sourcePath)
        else { return nil }
        if let cached = cache[summary.sourcePath], cached.fingerprint == fingerprint {
            touch(summary.sourcePath)
            return cached.structure.outlineOnly
        }
        if let store, let record = await store.record(forPath: summary.sourcePath, fingerprint: fingerprint) {
            return record.structure
        }
        let detail: SessionStructure.Detail = fingerprint.size <= configuration.fullParseLimitBytes ? .full : .outline
        guard let parsed = await parse(summary, fingerprint: fingerprint, detail: detail) else { return nil }
        return parsed.detail == .full ? parsed.outlineOnly : parsed
    }

    /// The structure in the requested detail. The default, `.outline`, is
    /// answered from the sidecar whenever its row is fresh (stats + turn
    /// outline, no file read). `.full` parses — or reuses one of the last
    /// few full parses — and, for a file above the full-parse limit, returns
    /// the outline instead; ask for its turns one at a time with
    /// `turn(at:for:)`.
    public func structure(
        for summary: SessionSummary,
        detail: SessionStructure.Detail = .outline
    ) async -> SessionStructure? {
        guard detail == .full else { return await outline(for: summary) }
        guard Self.supports(summary.provider),
              let fingerprint = SessionFileFingerprint.of(path: summary.sourcePath)
        else { return nil }
        if let cached = cache[summary.sourcePath], cached.fingerprint == fingerprint {
            touch(summary.sourcePath)
            return cached.structure
        }
        guard fingerprint.size <= configuration.fullParseLimitBytes else {
            return await outline(for: summary)
        }
        return await parse(summary, fingerprint: fingerprint, detail: .full)
    }

    /// One turn in full detail. Small files answer from the full structure;
    /// large ones re-read only that turn's byte window.
    public func turn(at index: Int, for summary: SessionSummary) async -> SessionStructure.Turn? {
        guard let fingerprint = SessionFileFingerprint.of(path: summary.sourcePath) else { return nil }
        if fingerprint.size <= configuration.fullParseLimitBytes {
            guard let structure = await structure(for: summary, detail: .full),
                  structure.turns.indices.contains(index)
            else { return nil }
            return structure.turns[index]
        }
        guard let outline = await outline(for: summary),
              outline.turns.indices.contains(index)
        else { return nil }
        let entry = outline.turns[index]
        let url = URL(fileURLWithPath: summary.sourcePath)
        let provider = summary.provider
        let window = SessionStructure.ByteRange(entry.byteOffset, max(entry.byteEnd, entry.byteOffset + 1))
        let parsed = await Task.detached(priority: .userInitiated) {
            Self.runParser(provider: provider, url: url, options: SessionStructureParseOptions(detail: .full, byteRange: window))
        }.value
        guard let parsed,
              var turn = parsed.turns.first(where: { $0.byteOffset == entry.byteOffset }) ?? parsed.turns.first
        else { return nil }
        // The window has no history before it; the outline's whole-file
        // reading of usage, model and status is the one to keep.
        turn.index = entry.index
        turn.usage = entry.usage
        turn.model = entry.model ?? turn.model
        turn.status = entry.status
        if turn.startedAt == nil { turn.startedAt = entry.startedAt }
        if turn.durationMs == nil { turn.durationMs = entry.durationMs }
        return turn
    }

    // MARK: - Background fill

    /// Bring sidecar rows up to date for `summaries`, most recently active
    /// first, within the configured file-count and byte budgets. Outline
    /// detail only — enough for every stat and the outline.
    public func refresh(summaries: [SessionSummary]) async -> RefreshReport {
        var report = RefreshReport()
        let ordered = summaries.sorted {
            ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast)
        }
        for summary in ordered {
            if Task.isCancelled { break }
            guard Self.supports(summary.provider) else {
                report.unsupported += 1
                continue
            }
            guard let fingerprint = SessionFileFingerprint.of(path: summary.sourcePath) else {
                report.missing += 1
                continue
            }
            if let store, await store.record(forPath: summary.sourcePath, fingerprint: fingerprint) != nil {
                report.upToDate += 1
                continue
            }
            if fingerprint.size > configuration.batchMaxFileBytes {
                report.skippedLarge += 1
                continue
            }
            if report.parsed >= configuration.batchMaxFiles || report.bytesParsed >= configuration.batchByteBudget {
                report.deferred += 1
                continue
            }
            if await parse(summary, fingerprint: fingerprint, detail: .outline) != nil {
                report.parsed += 1
                report.bytesParsed += fingerprint.size
            } else {
                report.failed += 1
            }
        }
        return report
    }

    // MARK: - Parsing

    private func parse(
        _ summary: SessionSummary,
        fingerprint: SessionFileFingerprint,
        detail: SessionStructure.Detail
    ) async -> SessionStructure? {
        let key = "\(detail.rawValue)|\(summary.sourcePath)"
        if let running = inFlight[key] { return await running.value }
        let url = URL(fileURLWithPath: summary.sourcePath)
        let provider = summary.provider
        let codexState = self.codexState
        let task = Task.detached(priority: .utility) { () -> SessionStructure? in
            guard var structure = Self.runParser(
                provider: provider, url: url, options: SessionStructureParseOptions(detail: detail)
            ) else { return nil }
            if provider == .codex, let codexState {
                Self.applyCodexState(codexState, to: &structure, sessionID: structure.sessionID ?? summary.sessionID)
            }
            return structure
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        guard let result else { return nil }
        // The file may have moved on while it was read; key the cache by
        // what was current when the read began, so a newer write is a miss.
        if let store, !result.diagnostics.incomplete {
            await store.upsert(SessionStructureRecord(structure: result, fingerprint: fingerprint))
        }
        if result.detail == .full {
            remember(summary.sourcePath, fingerprint: fingerprint, structure: result)
        }
        return result
    }

    nonisolated static func runParser(
        provider: SessionProvider,
        url: URL,
        options: SessionStructureParseOptions
    ) -> SessionStructure? {
        switch provider {
        case .codex:
            return CodexSessionStructureParser.parse(fileURL: url, options: options, isCancelled: { Task.isCancelled })
        case .claude:
            return ClaudeSessionStructureParser.parse(fileURL: url, options: options, isCancelled: { Task.isCancelled })
        default:
            return nil
        }
    }

    /// Fill what a rollout could not say from Codex's thread table: the
    /// token total when no counter was written, and branch / model when the
    /// rollout predates those fields.
    nonisolated static func applyCodexState(
        _ reader: CodexThreadStateReader,
        to structure: inout SessionStructure,
        sessionID: String?
    ) {
        let needsTokens = structure.stats.usageSource == .none
        let needsBranch = structure.stats.gitBranch == nil
        let needsModel = structure.stats.models.isEmpty
        guard needsTokens || needsBranch || needsModel, let sessionID,
              let state = reader.thread(id: sessionID)
        else { return }
        if needsTokens, state.tokensUsed > 0 {
            if structure.stats.forkStartOrdinal != nil {
                // `tokens_used` has the rollout counter's basis, which for a
                // session cut at its inherited-history ordinal includes the
                // copied parent history. Keep it as that, not as the total.
                structure.stats.cumulativeTokensIncludingInherited = state.tokensUsed
                structure.stats.totalTokens = 0
                structure.stats.usageSource = .unavailable
            } else {
                structure.stats.totalTokens = state.tokensUsed
                structure.stats.usageSource = .codexStateDatabase
            }
        }
        if needsBranch { structure.stats.gitBranch = state.gitBranch }
        if needsModel, let model = state.model { structure.stats.models = [model] }
    }

    // MARK: - LRU

    private func remember(_ path: String, fingerprint: SessionFileFingerprint, structure: SessionStructure) {
        cache[path] = (fingerprint, structure)
        touch(path)
        while recency.count > max(0, configuration.cacheCapacity), let evicted = recency.first {
            recency.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }

    private func touch(_ path: String) {
        if let index = recency.firstIndex(of: path) { recency.remove(at: index) }
        recency.append(path)
    }

    /// Paths currently held in full detail, least recent first (tests).
    public var cachedPaths: [String] { recency }
}
