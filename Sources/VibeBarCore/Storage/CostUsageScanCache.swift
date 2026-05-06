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
    /// One scanned event, ready to feed straight into the aggregator.
    /// For Codex this is a delta-resolved record; for Claude it's a per
    /// assistant-message usage line.
    public struct ParsedEvent: Codable, Sendable {
        public let date: Date
        public let model: String
        public let input: Int
        public let output: Int
        public let cache: Int
        public let costUSD: Double
    }

    public struct FileEntry: Codable, Sendable {
        public let mtime: Date
        public let size: Int64
        public let events: [ParsedEvent]
    }

    public var retentionDays: Int?
    public var entries: [String: FileEntry]

    public init(entries: [String: FileEntry] = [:], retentionDays: Int? = nil) {
        self.retentionDays = retentionDays.map(CostDataSettings.normalizedRetentionDays)
        self.entries = entries
    }

    /// Returns cached events if the on-disk fingerprint still matches; nil
    /// otherwise. The 1-second mtime tolerance absorbs filesystem timestamp
    /// rounding (some filesystems only have second-resolution mtime).
    public mutating func reusable(for path: String, mtime: Date, size: Int64) -> [ParsedEvent]? {
        let key = entryKey(for: path)
        let legacyEntry = entries.removeValue(forKey: path)
        if let legacyEntry, entries[key] == nil {
            entries[key] = legacyEntry
        }
        guard let entry = entries[key] else { return nil }
        if entry.size != size { return nil }
        if abs(entry.mtime.timeIntervalSince(mtime)) > 1.0 { return nil }
        return entry.events
    }

    public mutating func store(_ events: [ParsedEvent], for path: String, mtime: Date, size: Int64) {
        entries[entryKey(for: path)] = FileEntry(mtime: mtime, size: size, events: events)
    }

    public mutating func prune(known: Set<String>) {
        let knownKeys = Set(known.map { entryKey(for: $0) })
        entries = entries.filter { knownKeys.contains($0.key) }
    }

    public static func entryKey(for path: String) -> String {
        PrivacyPreservingHash.fileComponent(prefix: "path-v1", rawValue: path)
    }

    private func entryKey(for path: String) -> String {
        Self.entryKey(for: path)
    }

    // MARK: - Disk I/O

    /// 64 MB safety cap. The cache for a heavy user with several years of
    /// Codex / Claude history is usually under 10 MB.
    private static let maxFileBytes: Int = 64 * 1024 * 1024

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
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = (attrs[.size] as? NSNumber)?.intValue,
           size > maxFileBytes {
            return CostUsageScanCache(retentionDays: normalizedRetentionDays)
        }
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(CostUsageScanCache.self, from: data)
        else {
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

    public static func eraseAll(homeDirectory: String) {
        let root = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(VibeBarLocalStore.directoryName, isDirectory: true)
            .appendingPathComponent("scan_cache", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
    }
}
