import Foundation

/// Per-file event cache for `CostUsageScanner`.
///
/// Stores the fully-cooked events parsed out of each Codex / Claude `.jsonl`
/// session log, keyed by a SHA-256 digest of the file path. Each entry carries a fingerprint
/// (`mtime` + `size`) so a follow-up scan can skip re-parsing files that
/// haven't changed — which, in practice, is most of them. Files that have
/// been appended since last scan still get re-parsed in full (cheap compared
/// to walking the entire history every refresh) but the long tail of
/// historical session files is read-once.
///
/// The cache is stored at `<homeDirectory>/.vibebar/scan_cache/<tool>.json`,
/// so tests pointing the scanner at a temp directory get an isolated cache.
public struct CostUsageScanCache: Codable, Sendable {
    public enum PathRole: String, Codable, Sendable {
        case parent
        case subagent
    }

    /// One scanned event, ready to feed straight into the aggregator.
    /// For Codex this is a delta-resolved record; for Claude it's a per
    /// assistant-message usage line.
    public struct ParsedEvent: Codable, Sendable {
        public let date: Date
        public let model: String
        /// Optional provider-native alias used only when `model` is an
        /// unresolved opaque identifier. AntiGravity keeps its field-19
        /// router alias here until the field-20 enum gains a learned label.
        public let modelFallback: String?
        public let input: Int
        public let output: Int
        public let cache: Int
        public let cacheCreation: Int?
        public let sessionId: String?
        public let messageId: String?
        public let requestId: String?
        public let isSidechain: Bool?
        public let pathRole: PathRole?
        public let sourceKey: String?
        /// Billing tier the message ran on when the source log records
        /// it per-event — Claude writes `message.usage.speed`
        /// (`"standard"` / `"fast"`). A `"fast"`/`"priority"` value
        /// triggers the model's fast-tier cost multiplier. Codex resolves
        /// its tier globally from `~/.codex/config.toml` at scan time, so
        /// codex events leave this `nil`.
        public let serviceTier: String?
        /// Local harness that produced this event — the CLI / app, not the
        /// company and not the quota SubProvider. `nil` only for entries
        /// cached before the harness dimension existed; consumers fall back
        /// to `Harness.defaultHarness(for:)`.
        public let harness: Harness?
        /// Canonical local project directory for this request when the
        /// harness records one. Kept as a path (rather than a display label)
        /// so worktree aliases can be folded into the owning repository and
        /// same-named projects in different directories remain distinct.
        public let projectPath: String?

        public init(
            date: Date,
            model: String,
            modelFallback: String? = nil,
            input: Int,
            output: Int,
            cache: Int,
            cacheCreation: Int? = nil,
            sessionId: String? = nil,
            messageId: String? = nil,
            requestId: String? = nil,
            isSidechain: Bool? = nil,
            pathRole: PathRole? = nil,
            sourceKey: String? = nil,
            serviceTier: String? = nil,
            harness: Harness? = nil,
            projectPath: String? = nil
        ) {
            self.date = date
            self.model = model
            self.modelFallback = modelFallback
            self.input = input
            self.output = output
            self.cache = cache
            self.cacheCreation = cacheCreation
            self.sessionId = sessionId
            self.messageId = messageId
            self.requestId = requestId
            self.isSidechain = isSidechain
            self.pathRole = pathRole
            self.sourceKey = sourceKey
            self.serviceTier = serviceTier
            self.harness = harness
            self.projectPath = projectPath
        }
    }

    public struct FileEntry: Codable, Sendable {
        public let mtime: Date
        public let size: Int64
        public let events: [ParsedEvent]
    }

    public var schemaVersion: Int
    public var retentionDays: Int?
    /// Version of the AntiGravity `.db` protobuf projection used to cook
    /// cached events. This is deliberately separate from `schemaVersion`:
    /// advancing it reparses only AntiGravity databases while preserving
    /// opaque `.pb` RPC results and every other provider's warm cache.
    public var antigravityDBParserVersion: Int? {
        didSet {
            if oldValue != antigravityDBParserVersion { dirty = true }
        }
    }
    public var entries: [String: FileEntry]

    /// Whether this copy has diverged from what is on disk.
    ///
    /// A steady-state scan touches no entry at all — every file is
    /// unchanged and served from the warm cache — and re-encoding plus
    /// rewriting a multi-tens-of-MB JSON in that case is pure waste.
    /// Set by `store` / `prune` / the legacy-key migration, cleared by
    /// `saveIfDirty`. Not persisted: a freshly decoded cache is by
    /// definition identical to its file.
    public private(set) var dirty: Bool = false

    public init(
        entries: [String: FileEntry] = [:],
        retentionDays: Int? = nil,
        schemaVersion: Int = Self.currentSchemaVersion,
        antigravityDBParserVersion: Int? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.retentionDays = retentionDays.map(CostDataSettings.normalizedRetentionDays)
        self.antigravityDBParserVersion = antigravityDBParserVersion
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, retentionDays, antigravityDBParserVersion, entries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays)
        self.antigravityDBParserVersion = try c.decodeIfPresent(
            Int.self,
            forKey: .antigravityDBParserVersion
        )
        self.entries = try c.decode([String: FileEntry].self, forKey: .entries)
    }

    /// Returns cached events if the on-disk fingerprint still matches; nil
    /// otherwise. The 1-second mtime tolerance absorbs filesystem timestamp
    /// rounding (some filesystems only have second-resolution mtime).
    public mutating func reusable(for path: String, mtime: Date, size: Int64) -> [ParsedEvent]? {
        let key = entryKey(for: path)
        let legacyEntry = entries.removeValue(forKey: path)
        if let legacyEntry {
            if entries[key] == nil { entries[key] = legacyEntry }
            dirty = true
        }
        guard let entry = entries[key] else { return nil }
        if entry.size != size { return nil }
        if abs(entry.mtime.timeIntervalSince(mtime)) > 1.0 { return nil }
        return entry.events
    }

    /// Last cached events for `path`, ignoring the file fingerprint.
    /// Used as a stale-data fallback when a fresh parse / RPC is
    /// impossible — e.g. an AntiGravity `.pb` cascade whose tokens can
    /// only be re-fetched from the language server, which isn't running
    /// right now. Returns whatever was cached on a previous successful
    /// fetch so usage doesn't blink out while Antigravity is closed.
    public func lastKnownEvents(for path: String) -> [ParsedEvent]? {
        entries[Self.entryKey(for: path)]?.events
    }

    public mutating func store(_ events: [ParsedEvent], for path: String, mtime: Date, size: Int64) {
        entries[entryKey(for: path)] = FileEntry(mtime: mtime, size: size, events: events)
        dirty = true
    }

    public mutating func prune(known: Set<String>) {
        let knownKeys = Set(known.map { entryKey(for: $0) })
        let before = entries.count
        entries = entries.filter { knownKeys.contains($0.key) }
        if entries.count != before { dirty = true }
    }

    public static func entryKey(for path: String) -> String {
        PrivacyPreservingHash.fileComponent(prefix: "path-v1", rawValue: path)
    }

    private func entryKey(for path: String) -> String {
        Self.entryKey(for: path)
    }

    // MARK: - Disk I/O

    /// Size past which a cache file is *reported* as unusually large. It is
    /// deliberately NOT a rejection threshold any more.
    ///
    /// It used to be: `load` returned an empty cache above 64 MB. On an
    /// install with ~3k Claude transcripts the file crosses that on its own
    /// and the result was a permanent thrash loop — every pass re-parsed
    /// every transcript (GBs of reads, gigabytes of transient JSON
    /// allocations) and rewrote the same oversized file, which `load` then
    /// refused again. A cache is not corrupt just because the user has a lot
    /// of history, and `save` must never write a file `load` would refuse.
    static let largeFileWarningBytes: Int = 64 * 1024 * 1024
    /// Corruption guard, far above any realistic cache. 3k Claude
    /// transcripts produce ~70 MB; 1 GiB is only reachable by a runaway
    /// writer or a truncated/garbage file, and decoding one of those would
    /// cost more than skipping it.
    static let maxFileBytes: Int = 1024 * 1024 * 1024
    /// v3 adds `ParsedEvent.serviceTier` (Claude fast-tier billing) and
    /// fast-multiplier cost semantics; bumping forces a one-time
    /// re-parse so historical events pick up the new field.
    /// v4 fixes the AntiGravity `.db` decoder re-summing the cumulative
    /// cache-read counter per turn; bumping forces a re-parse so cached
    /// events drop the inflated cache tokens.
    /// v5 adds `ParsedEvent.harness`. Codex is the reason it has to be a
    /// global bump rather than a defaulted field: a rollout's harness is
    /// decided by its `session_meta.originator`, which only a fresh parse
    /// can read, so ChatGPT Desktop sessions stay mislabelled "Codex" until
    /// their cache entry is thrown away. AntiGravity `.pb` cascades lose
    /// their cached RPC result on this one bump and re-fetch the next time
    /// the language server is reachable; ledger rows already ingested from
    /// them are untouched.
    /// v6 re-parses again after the Codex originator rule was corrected
    /// (`Codex Desktop` is Codex; only `codex_work_desktop` is ChatGPT
    /// Work). Cached v5 events carry the wrong stamp, and the reusable-cache
    /// path replays them without re-reading `originator`, so the ledger's
    /// `harness_v2` fixup would be undone on the next scan unless the cache
    /// is invalidated with it.
    /// v7 adds `ParsedEvent.projectPath`. Codex and Claude both stamp their
    /// cwd in the transcript, but a warm v6 cache never re-opens that header;
    /// invalidate once so the project dashboard is populated immediately.
    public static let currentSchemaVersion = 7

    public static func fileURL(homeDirectory: String, tool: ToolType) -> URL {
        URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(VibeBarLocalStore.directoryName, isDirectory: true)
            .appendingPathComponent("scan_cache", isDirectory: true)
            .appendingPathComponent("\(tool.rawValue).json")
    }

    public static func load(
        homeDirectory: String,
        tool: ToolType,
        retentionDays: Int? = nil
    ) -> CostUsageScanCache {
        let normalizedRetentionDays = retentionDays.map(CostDataSettings.normalizedRetentionDays)
        let url = fileURL(homeDirectory: homeDirectory, tool: tool)
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            if size > maxFileBytes {
                SafeLog.warn(
                    "CostUsageScanCache discarding implausible cache tool=\(tool.rawValue) bytes=\(size)"
                )
                try? FileManager.default.removeItem(at: url)
                return CostUsageScanCache(retentionDays: normalizedRetentionDays)
            }
            if size > largeFileWarningBytes {
                SafeLog.info(
                    "CostUsageScanCache large cache tool=\(tool.rawValue) bytes=\(size) — still reused"
                )
            }
        }
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(CostUsageScanCache.self, from: data)
        else {
            return CostUsageScanCache(retentionDays: normalizedRetentionDays)
        }
        guard cache.schemaVersion == currentSchemaVersion else {
            try? FileManager.default.removeItem(at: url)
            return CostUsageScanCache(retentionDays: normalizedRetentionDays)
        }
        guard cache.retentionDays == normalizedRetentionDays else {
            try? FileManager.default.removeItem(at: url)
            return CostUsageScanCache(retentionDays: normalizedRetentionDays)
        }
        return cache
    }

    public func save(homeDirectory: String, tool: ToolType) {
        let url = Self.fileURL(homeDirectory: homeDirectory, tool: tool)
        let parent = url.deletingLastPathComponent()
        let fm = FileManager.default
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
        try? fm.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    /// Write only when this copy diverged from disk, then mark it clean.
    /// Callers that hold the cache across passes use this; the unconditional
    /// `save` stays for tests and one-shot writers.
    public mutating func saveIfDirty(homeDirectory: String, tool: ToolType) {
        guard dirty else { return }
        save(homeDirectory: homeDirectory, tool: tool)
        dirty = false
    }

    public static func eraseAll(homeDirectory: String) {
        let root = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(VibeBarLocalStore.directoryName, isDirectory: true)
            .appendingPathComponent("scan_cache", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        CostUsageScanCacheStore.shared.forget()
    }
}

/// Process-wide warm copy of the decoded per-tool scan caches.
///
/// Decoding `~/.vibebar/scan_cache/<tool>.json` is not cheap once a user has
/// real history behind them (tens of MB of JSON, hundreds of thousands of
/// `ParsedEvent`s), and the previous design paid that decode *and* a full
/// re-encode on every refresh even when not a single session file had
/// changed. Holding the decoded value here makes the disk read a
/// once-per-launch cost.
///
/// Correctness comes from the file's own identity: the entry records the
/// (mtime, size) of the cache file as it was after the last read or write,
/// and a checkout whose stat no longer matches falls back to disk. That
/// covers a test writing a cache file by hand, another process editing it,
/// and `eraseAll` deleting it.
final class CostUsageScanCacheStore: @unchecked Sendable {
    static let shared = CostUsageScanCacheStore()

    private struct Entry {
        var cache: CostUsageScanCache
        var homeDirectory: String
        var retentionDays: Int?
        var fileMTime: Date?
        var fileSize: Int64
    }

    private let lock = NSLock()
    /// One slot per tool. Production has exactly one home directory; a test
    /// pointing the scanner at a temp home simply evicts the previous slot
    /// instead of accumulating one entry per temp directory.
    private var entries: [ToolType: Entry] = [:]

    /// The warm cache for `tool`, or a fresh read from disk when there is no
    /// usable warm copy.
    func checkout(
        homeDirectory: String,
        tool: ToolType,
        retentionDays: Int?
    ) -> CostUsageScanCache {
        let normalized = retentionDays.map(CostDataSettings.normalizedRetentionDays)
        lock.lock()
        defer { lock.unlock() }
        let stat = Self.stat(homeDirectory: homeDirectory, tool: tool)
        if let entry = entries[tool],
           entry.homeDirectory == homeDirectory,
           entry.retentionDays == normalized,
           entry.fileSize == stat.size,
           entry.fileMTime == stat.mtime {
            return entry.cache
        }
        let loaded = CostUsageScanCache.load(
            homeDirectory: homeDirectory,
            tool: tool,
            retentionDays: retentionDays
        )
        // Re-stat: `load` deletes the file on a schema / retention mismatch.
        let after = Self.stat(homeDirectory: homeDirectory, tool: tool)
        entries[tool] = Entry(
            cache: loaded,
            homeDirectory: homeDirectory,
            retentionDays: normalized,
            fileMTime: after.mtime,
            fileSize: after.size
        )
        return loaded
    }

    /// Hand the cache back after a pass. `persist: false` keeps the dirty
    /// flag so an abandoned (cancelled) pass doesn't pay for a full rewrite
    /// while still keeping the events it did parse.
    func checkin(
        _ cache: CostUsageScanCache,
        homeDirectory: String,
        tool: ToolType,
        retentionDays: Int?,
        persist: Bool = true
    ) {
        var cache = cache
        if persist {
            cache.saveIfDirty(homeDirectory: homeDirectory, tool: tool)
        }
        lock.lock()
        defer { lock.unlock() }
        let stat = Self.stat(homeDirectory: homeDirectory, tool: tool)
        entries[tool] = Entry(
            cache: cache,
            homeDirectory: homeDirectory,
            retentionDays: retentionDays.map(CostDataSettings.normalizedRetentionDays),
            fileMTime: stat.mtime,
            fileSize: stat.size
        )
    }

    /// Drop every warm copy. Called by the privacy / "clear cost data" erase.
    func forget() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }

    private static func stat(homeDirectory: String, tool: ToolType) -> (mtime: Date?, size: Int64) {
        let url = CostUsageScanCache.fileURL(homeDirectory: homeDirectory, tool: tool)
        guard let values = try? url.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else {
            // Sentinel: distinguishable from a real zero-byte file.
            return (nil, -1)
        }
        return (values.contentModificationDate, Int64(values.fileSize ?? 0))
    }
}
