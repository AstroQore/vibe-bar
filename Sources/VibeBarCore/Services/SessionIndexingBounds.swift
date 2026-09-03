import Foundation

/// Bounds what `SessionIndexService` reads and keeps, per provider.
///
/// The kit's indexer asks an adapter for the *whole* transcript and only
/// then applies its excerpt budget. Two costs follow at real-world sizes:
///
/// - **Memory.** `parseTranscript` materializes every message of the file
///   before a single excerpt is taken. Codex rollouts on a busy machine
///   exceed a gigabyte, and parsing one put the app's lifetime peak at
///   1.5–1.9 GB. The excerpt budget is filled by the head of the
///   transcript, so for oversized JSONL files the wrapper parses a copy of
///   the head instead of the original.
/// - **Index size.** Full-length tool output dominated a 2.5 GB index.
///   The wrapper pre-trims every message to `SessionIndexExcerptPolicy`
///   before the kit's own (looser) budget runs.
///
/// Only the *indexing* services get wrapped adapters. The transcript
/// viewer and the deleter keep the raw registry: reading a session on
/// screen should show all of it, and deletion plans must come from the
/// adapter that owns the files.
public enum SessionIndexingBounds {
    /// Providers whose discovered session file is a JSONL log that can be
    /// parsed from a byte-truncated copy (a partial trailing line is
    /// skipped by the kit's line scanner). Grok's transcript lives in a
    /// sibling file of the discovered one and the SQLite/protobuf-backed
    /// providers cannot be truncated at a byte offset, so they are listed
    /// out.
    static let headTruncatableProviders: Set<SessionProvider> = [
        .codex, .claude, .claudeCowork
    ]

    /// `registry`, with every adapter wrapped in the indexing bounds.
    public static func boundedRegistry(
        _ registry: SessionProviderRegistry,
        policy: SessionIndexExcerptPolicy = .standard,
        scratchDirectory: URL = VibeBarLocalStore.sessionIndexScratchDirectoryURL
    ) -> SessionProviderRegistry {
        SessionProviderRegistry(adapters: registry.adapters.map {
            BoundedSessionAdapter(inner: $0, policy: policy, scratchDirectory: scratchDirectory)
        })
    }

    // MARK: - Reading a transcript for the screen

    /// How much of an oversized log the transcript viewer parses before it
    /// stops and offers the rest as an explicit action.
    ///
    /// Larger than the index's own limit because this is what the user asked
    /// to read — but still a limit: the kit's adapters materialize every
    /// message before applying `range:`, so a `range` is not a memory bound
    /// and a 1.7 GB rollout put the app's lifetime peak at 1.5–1.9 GB. At
    /// 32 MiB the viewer opens tens of thousands of messages, which is more
    /// than its 80-per-page reader can walk in a sitting.
    public static let viewerHeadParseByteLimit: Int64 = 32 * 1024 * 1024

    /// One transcript, read whole or read from the head.
    public struct BoundedTranscript: Sendable {
        public let document: TranscriptDocument
        /// True when `document` stops short of the file because the head
        /// limit was hit — not because the adapter itself truncated.
        public let isHeadTruncated: Bool
        /// Size of the file on disk, so a caller can say how much was left.
        public let fileByteSize: Int64
    }

    /// Parse `fileURL` with a byte bound instead of a message bound.
    ///
    /// `headByteLimit` of `nil` is the unbounded read — what "Load entire
    /// transcript" performs once the user has asked for it in as many words.
    /// Providers whose session is not a byte-truncatable JSONL log (Grok,
    /// Cursor, AntiGravity, Grok Bot) are always read whole; a SQLite or
    /// protobuf store cut at an offset is not a shorter session, it is a
    /// corrupt one.
    public static func readTranscript(
        adapter: any SessionProviderAdapter,
        fileURL: URL,
        headByteLimit: Int64?,
        scratchDirectory: URL = VibeBarLocalStore.sessionIndexScratchDirectoryURL
    ) throws -> BoundedTranscript {
        let size = SessionParsing.fileSize(fileURL)
        // The autoreleasepool is what actually returns the parse's transient
        // strings: without it a run of selections holds every intermediate
        // NSString until the enclosing task hits a suspension point.
        return try autoreleasepool {
            guard let headByteLimit,
                  headByteLimit > 0,
                  headTruncatableProviders.contains(adapter.provider),
                  size > headByteLimit
            else {
                return BoundedTranscript(
                    document: try adapter.parseTranscript(fileURL: fileURL, range: nil),
                    isHeadTruncated: false,
                    fileByteSize: size
                )
            }
            let head = try copyHead(of: fileURL, limit: headByteLimit, scratchDirectory: scratchDirectory)
            defer { try? FileManager.default.removeItem(at: head) }
            let parsed = try adapter.parseTranscript(fileURL: head, range: nil)
            return BoundedTranscript(
                document: TranscriptDocument(
                    messages: parsed.messages,
                    totalMessageCount: parsed.totalMessageCount,
                    truncated: true
                ),
                isHeadTruncated: true,
                fileByteSize: size
            )
        }
    }

    /// Streams the first `limit` bytes of `fileURL` into a scratch file.
    /// Constant memory; the caller deletes the copy after parsing. Scratch
    /// lives under `~/.vibebar` because that directory is the only place
    /// the app writes; `SessionIndexCompactor` sweeps anything a crash
    /// leaves behind.
    static func copyHead(of fileURL: URL, limit: Int64, scratchDirectory: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: scratchDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = scratchDirectory
            .appendingPathComponent("head-\(UUID().uuidString).\(fileURL.pathExtension)")
        let source = try FileHandle(forReadingFrom: fileURL)
        defer { try? source.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let sink = try FileHandle(forWritingTo: destination)
        defer { try? sink.close() }

        var remaining = limit
        let chunk = 4 * 1024 * 1024
        while remaining > 0 {
            let want = Int(min(Int64(chunk), remaining))
            guard let data = try source.read(upToCount: want), !data.isEmpty else { break }
            try sink.write(contentsOf: data)
            remaining -= Int64(data.count)
        }
        return destination
    }

    // MARK: - Transcript trimming

    /// `document` with the excerpt policy applied: per-message character
    /// caps by role, then the per-session byte budget, stopping at the
    /// first message that does not fit — the same stop-at-overflow shape
    /// as the kit's own budget so search results stay a prefix of the
    /// transcript.
    static func trimmed(
        _ document: TranscriptDocument,
        policy: SessionIndexExcerptPolicy,
        headTruncated: Bool,
        provider: SessionProvider
    ) -> TranscriptDocument {
        var kept: [SessionMessage] = []
        kept.reserveCapacity(document.messages.count)
        var budget = policy.sessionExcerptBytes
        var changed = false
        for message in document.messages {
            let cap = policy.excerptCharacters(for: message.role)
            // Provider envelopes come off before any cap. A Codex IDE
            // prompt puts kilobytes of editor context ahead of the
            // "## My request for Codex:" marker; truncating the raw text
            // first would cut the marker and the actual request away, and
            // the kit's own later normalization could then only index the
            // context prefix. Same call the kit makes at index time.
            var source = message.text
            if provider == .codex {
                source = CodexSessionAdapter.strippingIDEEnvelope(source)
            }
            let text = SessionParsing.truncate(source, limit: cap)
            if text != message.text { changed = true }
            // `changed` compares against the raw message on purpose: an
            // envelope strip with no truncation still needs a rebuilt
            // document so the indexed text matches what was budgeted.
            let cost = text.utf8.count
            guard cost <= budget else {
                changed = true
                break
            }
            budget -= cost
            kept.append(text == message.text
                ? message
                : SessionMessage(seq: message.seq, role: message.role, text: text, timestamp: message.timestamp))
        }
        guard changed || headTruncated else { return document }
        return TranscriptDocument(
            messages: kept,
            totalMessageCount: document.totalMessageCount,
            truncated: document.truncated || headTruncated || kept.count < document.messages.count
        )
    }
}

/// One adapter, bounded. Everything except `parseTranscript` forwards.
struct BoundedSessionAdapter: SessionProviderAdapter {
    let inner: any SessionProviderAdapter
    let policy: SessionIndexExcerptPolicy
    let scratchDirectory: URL

    var provider: SessionProvider { inner.provider }

    func roots(homeDirectory: String) -> [URL] {
        inner.roots(homeDirectory: homeDirectory)
    }

    func discoverSessionFiles(homeDirectory: String) -> [URL] {
        inner.discoverSessionFiles(homeDirectory: homeDirectory)
    }

    func extractMetadata(fileURL: URL) throws -> SessionSummary {
        try inner.extractMetadata(fileURL: fileURL)
    }

    func deletionPlan(for summary: SessionSummary, homeDirectory: String) throws -> SessionDeletionPlan {
        try inner.deletionPlan(for: summary, homeDirectory: homeDirectory)
    }

    func parseTranscript(fileURL: URL, range: Range<Int>?) throws -> TranscriptDocument {
        // An explicit range is a viewer-shaped read; only the indexer's
        // whole-document read is bounded.
        guard range == nil else {
            return try inner.parseTranscript(fileURL: fileURL, range: range)
        }
        let read = try SessionIndexingBounds.readTranscript(
            adapter: inner,
            fileURL: fileURL,
            headByteLimit: policy.headParseByteLimit,
            scratchDirectory: scratchDirectory
        )
        return SessionIndexingBounds.trimmed(
            read.document,
            policy: policy,
            headTruncated: read.isHeadTruncated,
            provider: inner.provider
        )
    }
}
