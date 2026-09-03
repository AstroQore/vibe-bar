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
    ///
    /// `isCancelled` is checked at every point where this function is still
    /// in control: before the head copy, between the copy's chunks, before
    /// handing bytes to the adapter, and after the adapter returns. The
    /// adapter's own parse is a single opaque call into the package and
    /// cannot be interrupted from here — so the guarantee is "a cancelled
    /// read starts no new parse and keeps no finished one", not "a parse
    /// already inside the kit stops mid-file". Bounding the bytes first is
    /// what keeps that uninterruptible window small.
    public static func readTranscript(
        adapter: any SessionProviderAdapter,
        fileURL: URL,
        headByteLimit: Int64?,
        scratchDirectory: URL = VibeBarLocalStore.sessionIndexScratchDirectoryURL,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> BoundedTranscript {
        let size = SessionParsing.fileSize(fileURL)
        // The autoreleasepool is what actually returns the parse's transient
        // strings: without it a run of selections holds every intermediate
        // NSString until the enclosing task hits a suspension point.
        return try autoreleasepool {
            if isCancelled() { throw CancellationError() }
            guard let headByteLimit,
                  headByteLimit > 0,
                  headTruncatableProviders.contains(adapter.provider),
                  size > headByteLimit
            else {
                let document = try adapter.parseTranscript(fileURL: fileURL, range: nil)
                // Drop a finished-but-abandoned parse here rather than
                // letting the caller carry gigabytes to its own check.
                if isCancelled() { throw CancellationError() }
                return BoundedTranscript(
                    document: document,
                    isHeadTruncated: false,
                    fileByteSize: size
                )
            }
            let head = try copyHead(
                of: fileURL,
                limit: headByteLimit,
                scratchDirectory: scratchDirectory,
                isCancelled: isCancelled
            )
            defer { try? FileManager.default.removeItem(at: head) }
            if isCancelled() { throw CancellationError() }
            let parsed = try adapter.parseTranscript(fileURL: head, range: nil)
            if isCancelled() { throw CancellationError() }
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

    // MARK: - Reading a transcript for an agent

    /// Byte ceiling for one `sessions.transcript` read.
    ///
    /// The same number as the viewer's, for the same reason and with the same
    /// consequence: past this, the answer says so instead of growing. It is
    /// generous relative to what an agent normally needs, because of a
    /// property worth stating outright — **`sessions.search` can only return a
    /// `matchedSeq` that lies inside the indexed head.** The indexer parses at
    /// most `SessionIndexExcerptPolicy.headParseByteLimit` (8 MiB) of any
    /// session, so every hit an agent can discover is reachable well inside
    /// this ceiling. "Read the match in context" therefore always works; only
    /// "page to the end of a 1 GB log" runs out of room.
    public static let agentTranscriptByteCeiling: Int64 = 32 * 1024 * 1024

    /// First read size. Most sessions are smaller than this, so the common
    /// case is one parse of the whole file.
    static let agentTranscriptInitialByteLimit: Int64 = 1024 * 1024

    /// Read the slice of `fileURL` that `request` asks for.
    ///
    /// There is no seek. A message index cannot be turned into a byte offset
    /// without parsing, because not every line of a rollout produces a
    /// message — the Codex adapter alone drops most of them. So reaching
    /// message *N* means parsing from the start until *N* exists, and the
    /// only bound available is the one this already has: bytes.
    ///
    /// What that buys is an *escalating head read* rather than a whole-file
    /// one. Start at `agentTranscriptInitialByteLimit`; if the parse did not
    /// reach the requested window and the file has more to give, estimate the
    /// bytes-per-message from what was just parsed, grow, and retry — up to
    /// `byteCeiling`. Small sessions cost one parse. A match near the head of
    /// a huge rollout costs one or two. Only a request that genuinely points
    /// past the ceiling gets a truncated answer, and it is told why.
    ///
    /// This deliberately calls `readTranscript` rather than reimplementing the
    /// bound: one read path, one cancellation story, one scratch sweep.
    public static func readTranscriptWindow(
        adapter: any SessionProviderAdapter,
        fileURL: URL,
        request: TranscriptWindowRequest,
        byteCeiling: Int64 = SessionIndexingBounds.agentTranscriptByteCeiling,
        scratchDirectory: URL = VibeBarLocalStore.sessionIndexScratchDirectoryURL,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> TranscriptWindow {
        let needed = request.upperBound
        var limit = min(agentTranscriptInitialByteLimit, byteCeiling)
        var read = try readTranscript(
            adapter: adapter,
            fileURL: fileURL,
            headByteLimit: limit,
            scratchDirectory: scratchDirectory,
            isCancelled: isCancelled
        )
        while read.isHeadTruncated, read.document.messages.count <= needed, limit < byteCeiling {
            limit = min(byteCeiling, Self.nextByteLimit(after: limit, read: read, needed: needed))
            read = try readTranscript(
                adapter: adapter,
                fileURL: fileURL,
                headByteLimit: limit,
                scratchDirectory: scratchDirectory,
                isCancelled: isCancelled
            )
        }
        return window(
            for: request,
            in: read.document.messages,
            reachedEndOfFile: !read.isHeadTruncated,
            bytesRead: read.isHeadTruncated ? limit : read.fileByteSize,
            fileBytes: read.fileByteSize
        )
    }

    /// How far to grow the next attempt.
    ///
    /// Doubling alone walks up to a deep message in log₂ steps, each one
    /// re-parsing everything before it. The bytes-per-message the last parse
    /// just measured is a much better guess, so take whichever is larger and
    /// give it 50% headroom — messages get longer further into a session.
    static func nextByteLimit(
        after limit: Int64,
        read: BoundedTranscript,
        needed: Int
    ) -> Int64 {
        let doubled = limit * 2
        let parsed = read.document.messages.count
        guard parsed > 0 else { return doubled }
        let perMessage = max(1, limit / Int64(parsed))
        let estimated = perMessage * Int64(needed + 1) * 3 / 2
        return max(doubled, estimated)
    }

    /// Slice, role-filter and budget one window out of the parsed messages.
    ///
    /// Split out from the read so the whole windowing contract — bounds,
    /// caps, cursor, reasons — is testable against a plain array with no
    /// file, adapter or scratch directory in sight.
    ///
    /// The two request shapes are collected in different orders, and that is
    /// the whole point. `from` reads forward and stops when a cap bites.
    /// `around` collects **outward from the target**, so a cap shrinks the
    /// window towards the message the caller asked to see instead of
    /// truncating the far side of it away.
    static func window(
        for request: TranscriptWindowRequest,
        in messages: [SessionMessage],
        reachedEndOfFile: Bool,
        bytesRead: Int64,
        fileBytes: Int64
    ) -> TranscriptWindow {
        var reasons: [TranscriptTruncationReason] = []
        // The window asked for more than the read could see. Say so rather
        // than returning an empty slice that reads like "no such messages".
        if !reachedEndOfFile, messages.count <= request.upperBound {
            reasons.append(.readCeiling)
        }

        // `min` matters: a `from` past the end of what was read would other-
        // wise build a reversed range, which traps rather than returning the
        // empty window that situation actually calls for.
        let order = request.around == nil
            ? Array(min(request.lowerBound, messages.count)..<messages.count)
            : Self.centredOrder(request: request, messageCount: messages.count)

        var chosen: [Int] = []
        var spent = 0
        var hitCap = false

        for index in order {
            guard index <= request.upperBound, index < messages.count else { continue }
            let message = messages[index]
            // A role filter thins the window; it does not extend it — and it
            // outranks "always include the target", because a caller asking
            // for user turns only did not ask for an assistant one.
            if let roles = request.roles, !roles.contains(message.role) { continue }
            if chosen.count >= request.limit {
                reasons.append(.messageLimit)
                hitCap = true
                break
            }
            // Always let the first message through: a response of zero
            // messages plus "the budget was full" is not an answer.
            let cost = Self.clipped(message).utf8.count
            if !chosen.isEmpty, spent + cost > TranscriptWindowRequest.maximumTextBytes {
                reasons.append(.byteBudget)
                hitCap = true
                break
            }
            chosen.append(index)
            spent += cost
        }

        // Centred collection visits neighbours alternately, so sort back into
        // reading order before anyone sees it.
        chosen.sort()
        var kept: [SessionMessage] = []
        var truncatedFlags: [Bool] = []
        var originalBytes: [Int] = []
        for index in chosen {
            let message = messages[index]
            let clipped = Self.clipped(message)
            if clipped != message.text {
                if !reasons.contains(.messageText) { reasons.append(.messageText) }
                truncatedFlags.append(true)
            } else {
                truncatedFlags.append(false)
            }
            originalBytes.append(message.text.utf8.count)
            kept.append(SessionMessage(
                seq: message.seq,
                role: message.role,
                text: clipped,
                timestamp: message.timestamp
            ))
        }

        // Where "keep reading" resumes: after the last message returned.
        //
        // The exception is a window that returned nothing because the read
        // never got that far. Handing back a cursor there would invite an
        // agent to retry the identical request forever, so it gets `nil` and
        // the `readCeiling` notice, which is the only useful answer.
        let nextFrom: Int?
        if kept.isEmpty, reasons.contains(.readCeiling) {
            nextFrom = nil
        } else {
            let resume = (chosen.last.map { $0 + 1 }) ?? request.lowerBound
            nextFrom = hitCap || resume < messages.count || !reachedEndOfFile ? resume : nil
        }

        return TranscriptWindow(
            messages: kept,
            textTruncated: truncatedFlags,
            textBytes: originalBytes,
            // Only a read that saw the whole file knows the whole count.
            totalMessageCount: reachedEndOfFile ? messages.count : nil,
            nextFrom: nextFrom,
            reasons: reasons,
            bytesRead: bytesRead,
            fileBytes: fileBytes
        )
    }

    /// Indices to try for an `around` request, nearest the target first.
    ///
    /// Target, then one before, one after, two before, two after… Collecting
    /// in this order is what guarantees the requested message survives every
    /// cap: it is considered before anything else, so the only thing that can
    /// exclude it is a `roles` filter it does not match.
    ///
    /// Walking outward from a centre also keeps the result contiguous, which
    /// is why `nextFrom` can stay a single "resume after the last message"
    /// index rather than a set of holes.
    ///
    /// The previous version simply started at `around - radius` and read
    /// forward, so `around: 500, radius: 100` with the default limit of 40
    /// returned 400–439 and omitted 500 — the one message the caller named.
    static func centredOrder(request: TranscriptWindowRequest, messageCount: Int) -> [Int] {
        guard let around = request.around, messageCount > 0 else { return [] }
        let lower = request.lowerBound
        let upper = min(request.upperBound, messageCount - 1)
        // The target itself has to be inside the readable span. When it is
        // not, there is no centred window to build: the caller gets the empty
        // result, and `readCeiling` explains it when the read was the reason.
        guard lower <= upper, around >= lower, around <= upper else { return [] }
        var order: [Int] = [around]
        order.reserveCapacity(upper - lower + 1)
        var step = 1
        while true {
            let before = around - step
            let after = around + step
            if before < lower, after > upper { break }
            if before >= lower { order.append(before) }
            if after <= upper { order.append(after) }
            step += 1
        }
        return order
    }

    private static func clipped(_ message: SessionMessage) -> String {
        SessionParsing.truncate(
            message.text,
            limit: TranscriptWindowRequest.maximumMessageTextCharacters
        )
    }

    /// Streams the first `limit` bytes of `fileURL` into a scratch file.
    /// Constant memory; the caller deletes the copy after parsing. Scratch
    /// lives under `~/.vibebar` because that directory is the only place
    /// the app writes; `SessionIndexCompactor` sweeps anything a crash
    /// leaves behind.
    ///
    /// The cancellation check is per chunk, which is the only granularity
    /// this loop has — and the reason the copy is chunked at all.
    static func copyHead(
        of fileURL: URL,
        limit: Int64,
        scratchDirectory: URL,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: scratchDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = scratchDirectory
            .appendingPathComponent("head-\(UUID().uuidString).\(fileURL.pathExtension)")
        var completed = false
        // A cancelled copy must not leave its partial file behind: nothing
        // else knows this path, so `SessionIndexCompactor`'s scratch sweep
        // would be the only thing that ever removed it.
        defer { if !completed { try? FileManager.default.removeItem(at: destination) } }
        let source = try FileHandle(forReadingFrom: fileURL)
        defer { try? source.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let sink = try FileHandle(forWritingTo: destination)
        defer { try? sink.close() }

        var remaining = limit
        let chunk = 4 * 1024 * 1024
        while remaining > 0 {
            if isCancelled() { throw CancellationError() }
            let want = Int(min(Int64(chunk), remaining))
            guard let data = try source.read(upToCount: want), !data.isEmpty else { break }
            try sink.write(contentsOf: data)
            remaining -= Int64(data.count)
        }
        completed = true
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
            scratchDirectory: scratchDirectory,
            // Explicitly opted out. The indexing sweep's cancellation story
            // belongs to the kit's `refreshIndex`, and making a throw here
            // mean "cancelled" would silently turn a cancelled pass into a
            // pass that skipped files — indistinguishable, in the index,
            // from files that failed to parse. The viewer is the caller that
            // needs the abort, and it passes its own check.
            isCancelled: { false }
        )
        return SessionIndexingBounds.trimmed(
            read.document,
            policy: policy,
            headTruncated: read.isHeadTruncated,
            provider: inner.provider
        )
    }
}
