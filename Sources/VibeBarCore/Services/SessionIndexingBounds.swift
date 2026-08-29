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

    // MARK: - Transcript trimming

    /// `document` with the excerpt policy applied: per-message character
    /// caps by role, then the per-session byte budget, stopping at the
    /// first message that does not fit — the same stop-at-overflow shape
    /// as the kit's own budget so search results stay a prefix of the
    /// transcript.
    static func trimmed(
        _ document: TranscriptDocument,
        policy: SessionIndexExcerptPolicy,
        headTruncated: Bool
    ) -> TranscriptDocument {
        var kept: [SessionMessage] = []
        kept.reserveCapacity(document.messages.count)
        var budget = policy.sessionExcerptBytes
        var changed = false
        for message in document.messages {
            let cap = policy.excerptCharacters(for: message.role)
            let text = SessionParsing.truncate(message.text, limit: cap)
            if text != message.text { changed = true }
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
        var headTruncated = false
        var document: TranscriptDocument
        if SessionIndexingBounds.headTruncatableProviders.contains(inner.provider),
           SessionParsing.fileSize(fileURL) > policy.headParseByteLimit {
            let head = try copyHead(of: fileURL)
            defer { try? FileManager.default.removeItem(at: head) }
            document = try inner.parseTranscript(fileURL: head, range: nil)
            headTruncated = true
        } else {
            document = try inner.parseTranscript(fileURL: fileURL, range: nil)
        }
        return SessionIndexingBounds.trimmed(document, policy: policy, headTruncated: headTruncated)
    }

    /// Streams the first `headParseByteLimit` bytes into a scratch file.
    /// Constant memory; the caller deletes the copy after parsing. Scratch
    /// lives under `~/.vibebar` because that directory is the only place
    /// the app writes; `SessionIndexCompactor` sweeps anything a crash
    /// leaves behind.
    private func copyHead(of fileURL: URL) throws -> URL {
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

        var remaining = policy.headParseByteLimit
        let chunk = 4 * 1024 * 1024
        while remaining > 0 {
            let want = Int(min(Int64(chunk), remaining))
            guard let data = try source.read(upToCount: want), !data.isEmpty else { break }
            try sink.write(contentsOf: data)
            remaining -= Int64(data.count)
        }
        return destination
    }
}
