import Darwin
import Foundation

/// Keeps `SessionIndexStore` in step with what is actually on disk.
///
/// One pass walks every adapter's session files, fingerprints each one
/// (modification time in nanoseconds + size), and re-reads only the
/// files whose fingerprint moved. Metadata is always indexed; message
/// bodies are indexed only while `bodyIndexing()` says so, and turning
/// that off drops the bodies on the next pass.
///
/// Nothing here hops to the main actor and nothing here throws: a file
/// that fails to parse is logged and skipped, because one unreadable
/// rollout must not cost the user every other session in the list.
public actor SessionIndexService {
    private let homeDirectory: String
    private let store: SessionIndexStore
    private let registry: SessionProviderRegistry
    private let bodyIndexing: @Sendable () -> Bool

    public init(
        homeDirectory: String = RealHomeDirectory.path,
        store: SessionIndexStore,
        registry: SessionProviderRegistry,
        bodyIndexing: @escaping @Sendable () -> Bool
    ) {
        self.homeDirectory = homeDirectory
        self.store = store
        self.registry = registry
        self.bodyIndexing = bodyIndexing
    }

    /// Bring the index up to date. `progress` is called after each file
    /// with `(filesDone, filesTotal)`.
    public func refreshIndex(progress: (@Sendable (Int, Int) -> Void)? = nil) async {
        let indexBodies = bodyIndexing()
        do {
            let previous = try await store.bodyIndexingMode()
            if !indexBodies {
                try await store.dropBodyIndex()
            } else if previous != true {
                // Bodies were off (or this is the first pass): the files
                // indexed back then still have a matching fingerprint, so
                // without dropping their cursors they would never be
                // re-read and would stay body-less forever.
                try await store.resetFileCursors()
            }
            try await store.setBodyIndexingMode(indexBodies)
        } catch {
            SafeLog.warn("Session index: applying the body-indexing mode failed.")
        }

        var files: [(adapter: any SessionProviderAdapter, url: URL)] = []
        for adapter in registry.adapters {
            for url in adapter.discoverSessionFiles(homeDirectory: homeDirectory) {
                files.append((adapter, url))
            }
        }

        var seen: Set<String> = []
        let total = files.count
        var done = 0
        for file in files {
            let hash = Self.pathHash(file.url.path)
            seen.insert(hash)
            await index(file: file.url, adapter: file.adapter, pathHash: hash, bodies: indexBodies)
            done += 1
            progress?(done, total)
        }

        do {
            try await store.pruneMissing(existingPathHashes: seen)
        } catch {
            SafeLog.warn("Session index: pruning vanished sessions failed.")
        }
    }

    public func allSummaries() async throws -> [SessionSummary] {
        try await store.allSummaries()
    }

    public func summaryPage(
        providers: [SessionProvider]? = nil,
        harnesses: [Harness]? = nil,
        since: Date? = nil,
        order: SessionSummaryOrder = .recentFirst,
        offset: Int = 0,
        limit: Int = 250
    ) async throws -> SessionSummaryPage {
        try await store.summaryPage(
            providers: providers,
            harnesses: harnesses,
            since: since,
            order: order,
            offset: offset,
            limit: limit
        )
    }

    public func providerCounts() async throws -> [SessionProvider: Int] {
        try await store.providerCounts()
    }

    public func harnessCounts() async throws -> [Harness: Int] {
        try await store.harnessCounts()
    }

    public func search(
        _ text: String,
        providers: [SessionProvider]? = nil,
        harnesses: [Harness]? = nil,
        limit: Int = 50
    ) async throws -> [SessionSearchHit] {
        try await store.search(
            text: text,
            providers: providers,
            harnesses: harnesses,
            limit: limit
        )
    }

    // MARK: - One file

    private func index(
        file url: URL,
        adapter: any SessionProviderAdapter,
        pathHash: String,
        bodies: Bool
    ) async {
        guard let fingerprint = Self.fingerprint(url) else { return }
        do {
            if let cursor = try await store.fileCursor(pathHash: pathHash),
               cursor.mtimeNanos == fingerprint.mtimeNanos,
               cursor.size == fingerprint.size {
                return
            }
            let summary = try adapter.extractMetadata(fileURL: url)
            let row = try await store.upsertSession(summary)
            if bodies {
                let document = try adapter.parseTranscript(fileURL: url, range: nil)
                try await store.replaceMessages(
                    sessionRow: row,
                    excerpts: Self.excerpts(from: document, provider: summary.provider)
                )
            }
            try await store.saveFileCursor(
                pathHash: pathHash,
                path: url.path,
                provider: adapter.provider,
                mtimeNanos: fingerprint.mtimeNanos,
                size: fingerprint.size,
                sessionRow: row
            )
        } catch {
            // The path is the user's own filesystem; log the file name
            // only, and let the next refresh retry.
            SafeLog.warn(
                "Session index: skipped \(adapter.provider.rawValue) file "
                    + "\(SafeLog.sanitize(url.lastPathComponent))."
            )
        }
    }

    static func pathHash(_ path: String) -> String {
        PrivacyPreservingHash.fileComponent(prefix: "session-path-v1", rawValue: path)
    }

    /// Nanosecond mtime + size. Second-resolution timestamps are too
    /// coarse: a session file appended to twice inside the same second is
    /// exactly the case an incremental index has to notice.
    ///
    /// A live SQLite store in WAL mode commits into `<file>-wal` and leaves
    /// the main file untouched until a checkpoint, so the journal sibling is
    /// folded in (latest mtime, summed size) or an active Cursor / AntiGravity
    /// conversation would look unchanged for as long as it is being written.
    static func fingerprint(_ url: URL) -> (mtimeNanos: Int64, size: Int64)? {
        guard var result = statFingerprint(url.path) else { return nil }
        if let wal = statFingerprint(url.path + "-wal") {
            result = (max(result.mtimeNanos, wal.mtimeNanos), result.size + wal.size)
        }
        return result
    }

    private static func statFingerprint(_ path: String) -> (mtimeNanos: Int64, size: Int64)? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let seconds = Int64(info.st_mtimespec.tv_sec)
        let nanos = Int64(info.st_mtimespec.tv_nsec)
        return (seconds * 1_000_000_000 + nanos, Int64(info.st_size))
    }

    // MARK: - Excerpt policy

    /// Per-message cap. Long enough to keep a paragraph of context around
    /// a match, short enough that a pasted file does not become the
    /// index.
    static let maxExcerptCharacters = 2_000
    /// Per-session cap on indexed text. A transcript past this is
    /// indexed from the top and truncated.
    static let maxSessionExcerptBytes = 512 * 1024

    /// What of a transcript is worth searching: the human's prompts and
    /// the model's replies. Tool output, system preambles, and the
    /// editor / slash-command envelopes are noise a user would never
    /// search for and would flood every result list if indexed.
    static func excerpts(
        from document: TranscriptDocument,
        provider: SessionProvider
    ) -> [SessionIndexStore.MessageExcerpt] {
        var out: [SessionIndexStore.MessageExcerpt] = []
        var budget = maxSessionExcerptBytes
        for message in document.messages {
            guard message.role == .user || message.role == .assistant else { continue }
            guard let text = normalize(message.text, provider: provider) else { continue }
            let cost = text.utf8.count
            guard cost <= budget else { break }
            budget -= cost
            out.append(SessionIndexStore.MessageExcerpt(
                seq: message.seq, role: message.role, excerpt: text
            ))
        }
        return out
    }

    static func normalize(_ raw: String, provider: SessionProvider) -> String? {
        var text = raw
        if provider == .codex {
            text = CodexSessionAdapter.strippingIDEEnvelope(text)
        }
        guard !ClaudeSessionAdapter.isEnvelopeText(text) else { return nil }

        // `[Tool: name]` markers are how every adapter renders a tool
        // call inside an assistant turn; they carry no searchable content.
        let kept = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !isToolMarker($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kept.isEmpty else { return nil }
        return SessionParsing.truncate(kept, limit: maxExcerptCharacters)
    }

    private static func isToolMarker(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("[Tool: ") && trimmed.hasSuffix("]")
    }
}
