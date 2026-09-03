import Foundation

/// The vocabulary an *agent* uses to find and read someone else's session.
///
/// The Workbench's Sessions page has its own filter state, shaped by the
/// controls on screen. This is the MCP side of the same idea, and it is
/// deliberately a plain value: `MCPServer` parses arguments into one,
/// `MCPController` applies it, and `VibeBarCoreTests` can exercise the
/// semantics without a running app or an index.
///
/// The argument names match `usage.*` (`from` / `to` / `models` /
/// `harnesses`) on purpose. Two vocabularies for one concept is how an agent
/// ends up passing `since` to a tool that wanted `from` and silently getting
/// an unfiltered answer.
public struct SessionQueryFilter: Sendable, Equatable {
    /// On-disk stores to read. `nil` is every store; an empty list is none.
    public var providers: [SessionProvider]?
    /// Usage-axis harnesses to keep. `nil` is every harness; empty is none.
    public var harnesses: [Harness]?
    /// **Substring** match against the session's project directory.
    ///
    /// Substring rather than prefix because that is what
    /// `SessionIndexStore.summaryPage` implements in SQL
    /// (`project_dir LIKE '%needle%'`), which keeps `totalCount` and paging
    /// exact — a host-side prefix re-filter would make the store's count
    /// describe a different set than the rows returned. A full absolute path
    /// therefore behaves as an exact match, and `vibe-bar` matches every
    /// checkout of it.
    public var projectDir: String?
    /// Inclusive lower bound on the session's last activity
    /// (`lastActiveAt ?? createdAt`).
    public var from: Date?
    /// Exclusive upper bound on the same stamp.
    public var to: Date?
    /// Raw vendor model ids, compared case-insensitively and exactly — the
    /// same rule as `usage.*`. A session whose log never recorded a model
    /// matches no model filter; it is never inferred.
    public var models: [String]?

    public init(
        providers: [SessionProvider]? = nil,
        harnesses: [Harness]? = nil,
        projectDir: String? = nil,
        from: Date? = nil,
        to: Date? = nil,
        models: [String]? = nil
    ) {
        self.providers = providers
        self.harnesses = harnesses
        self.projectDir = projectDir
        self.from = from
        self.to = to
        self.models = models
    }

    /// Project terms in the shape `SessionIndexStore` takes them.
    public var projectIncludes: [String] {
        guard let projectDir, !projectDir.trimmingCharacters(in: .whitespaces).isEmpty else {
            return []
        }
        return [projectDir]
    }

    /// True when this filter can never match anything.
    ///
    /// The house rule, stated once: **an omitted list means "everything", an
    /// explicitly empty list means "nothing"**. `quota.get`'s `tools: []`
    /// already works that way, the skill documents it, and `SessionIndexStore`
    /// returns an empty page for `providers: []` / `harnesses: []` — but the
    /// store has no model column filter at all, so `models: []` could only be
    /// honoured here. It used to be skipped instead, which quietly turned
    /// "match nothing" into "match everything".
    public var matchesNothing: Bool {
        providers?.isEmpty == true || harnesses?.isEmpty == true || models?.isEmpty == true
    }

    /// True when every part of this filter is something the index can answer
    /// in SQL, so a page's `totalCount` and `offset` describe exactly the rows
    /// that come back.
    ///
    /// `to` and `models` are the two that are not: `summaryPage` has a `since`
    /// but no upper bound, and no model column filter. They are applied here
    /// instead, which means the count has to be withheld rather than reported
    /// as something it no longer describes. Any `models` list counts —
    /// including an empty one, which the store cannot express.
    public var isAnsweredEntirelyByTheIndex: Bool {
        to == nil && models == nil
    }

    /// Does this summary survive the parts of the filter the index did not
    /// apply? Safe to call for the store-native parts too — it re-asserts all
    /// of them, so a caller never has to track which half ran where.
    public func matches(_ summary: SessionSummary) -> Bool {
        // Every list below is `if let`, never `if let … , !isEmpty`: an empty
        // list has to fall into the membership test and fail it, which is
        // what makes "nothing" mean nothing.
        if let providers, !providers.contains(summary.provider) { return false }
        if let harnesses, !harnesses.contains(summary.effectiveHarness) { return false }
        if let needle = projectIncludes.first {
            guard let directory = summary.projectDir,
                  directory.range(of: needle, options: .caseInsensitive) != nil
            else { return false }
        }
        if let models {
            guard let model = summary.model, !model.isEmpty else { return false }
            guard models.contains(where: { $0.compare(model, options: .caseInsensitive) == .orderedSame })
            else { return false }
        }
        guard from != nil || to != nil else { return true }
        // A row with no timestamp at all cannot satisfy a time window. Saying
        // "unknown" is not the same as saying "in range".
        guard let stamp = summary.lastActiveAt ?? summary.createdAt else { return false }
        if let from, stamp < from { return false }
        if let to, stamp >= to { return false }
        return true
    }
}

/// How to name one session across the MCP surface.
///
/// Either the composite `id` every `sessions.*` row already carries, or the
/// `sessionId` + `provider` pair. There is deliberately **no** path argument:
/// every read resolves through the session index, so an agent can only reach
/// files Vibe Bar already discovered under a provider's own roots. The path
/// component of a composite id is informational — the index row is what
/// decides which file is opened.
public struct SessionLocator: Sendable, Equatable {
    public var provider: SessionProvider
    public var sessionID: String

    public init(provider: SessionProvider, sessionID: String) {
        self.provider = provider
        self.sessionID = sessionID
    }

    /// Parse `provider:sessionID:sourcePath`, the shape of `SessionSummary.id`.
    ///
    /// Only the first two components are read. A macOS path may contain `:`,
    /// so the split is bounded rather than greedy, and the trailing path is
    /// dropped rather than validated — see the type's note on why.
    public static func parse(compositeID: String) -> SessionLocator? {
        let parts = compositeID.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let provider = SessionProvider(rawValue: String(parts[0])),
              !parts[1].isEmpty
        else { return nil }
        return SessionLocator(provider: provider, sessionID: String(parts[1]))
    }
}

// MARK: - Transcript windows

/// Which slice of a transcript an agent asked for.
///
/// Two shapes, and they are not interchangeable. `around` is "show me this
/// match in context" — the answer to a `sessions.search` hit's `matchedSeq`.
/// `from` is "keep reading" — the answer to a previous window's cursor.
public struct TranscriptWindowRequest: Sendable, Equatable {
    /// Centre the window on this message index. Wins over `from`.
    public var around: Int?
    /// Messages either side of `around`.
    public var radius: Int
    /// First message index to return, when `around` is absent.
    public var from: Int
    /// Maximum messages to return, before the byte budget has its say.
    public var limit: Int
    /// Roles to keep. `nil` is every role, an empty set is none — the same
    /// house rule as every other list filter. Applied *after* the window is
    /// taken, so a `roles` filter thins a window rather than scanning for
    /// more matches beyond it — otherwise "the 20 messages around seq 400"
    /// would silently become "the next 20 user messages, wherever they are".
    ///
    /// It also outranks `around`'s guarantee to include its target: a caller
    /// asking for user turns only did not ask for an assistant one.
    public var roles: Set<SessionRole>?

    public static let defaultRadius = 20
    public static let defaultLimit = 40
    /// Hard ceiling on messages per response, whatever was asked for.
    public static let maximumMessages = 200
    /// UTF-8 budget for all message text in one response. An agent asking for
    /// 200 tool-call outputs gets a truncated answer and a cursor, not a
    /// multi-megabyte payload it then has to page through in its context.
    public static let maximumTextBytes = 256 * 1024
    /// Cap on a single message's text, in **characters** — the unit
    /// `SessionParsing.truncate` works in, and four times the kit's own prose
    /// excerpt cap. One pasted build log must not be able to spend the whole
    /// response on itself. The response-wide budget above is in bytes and is
    /// what actually bounds the payload; this only stops one message from
    /// being the whole of it.
    public static let maximumMessageTextCharacters = 8_000

    public init(
        around: Int? = nil,
        radius: Int = TranscriptWindowRequest.defaultRadius,
        from: Int = 0,
        limit: Int = TranscriptWindowRequest.defaultLimit,
        roles: Set<SessionRole>? = nil
    ) {
        self.around = around
        self.radius = max(0, radius)
        self.from = max(0, from)
        self.limit = min(max(1, limit), TranscriptWindowRequest.maximumMessages)
        self.roles = roles
    }

    /// First message index this request needs, before any role filtering.
    public var lowerBound: Int {
        guard let around else { return from }
        return max(0, around - radius)
    }

    /// Highest message index this request needs. The reader uses it to decide
    /// how many bytes of the log it has to parse.
    public var upperBound: Int {
        guard let around else { return from + limit - 1 }
        return around + radius
    }
}

/// Why a window stops where it does. Reported verbatim so an agent can act on
/// the reason rather than guess from a short list.
public enum TranscriptTruncationReason: String, Sendable, Codable, CaseIterable {
    /// The requested message count was reached.
    case messageLimit
    /// The response's UTF-8 budget was reached.
    case byteBudget
    /// At least one message's own text was clipped.
    case messageText
    /// The read stopped at its byte ceiling before reaching the requested
    /// window. The rest of the log exists; it is past what a bounded read
    /// will parse.
    case readCeiling
}

/// One slice of a transcript, plus everything needed to ask for the next.
public struct TranscriptWindow: Sendable, Equatable {
    public var messages: [SessionMessage]
    /// Per-message flag, parallel to `messages`: true where `text` is a
    /// prefix of what the log holds.
    public var textTruncated: [Bool]
    /// Original UTF-8 length of each message's text, before any clipping.
    public var textBytes: [Int]
    /// Total messages in the log, when the read actually reached the end of
    /// the file — which a bounded read often does not, because it stops as
    /// soon as it has the window it was asked for. `nil` otherwise: the count
    /// of a prefix is not the count of the log, and reporting it as one would
    /// make an agent believe it had seen everything.
    public var totalMessageCount: Int?
    /// Index to pass back as `from` to continue. `nil` when the window
    /// reached the end of what was read *and* the read reached the end of the
    /// file.
    public var nextFrom: Int?
    public var reasons: [TranscriptTruncationReason]
    /// Bytes of the log actually parsed, and its size on disk.
    public var bytesRead: Int64
    public var fileBytes: Int64

    public var hasMore: Bool { nextFrom != nil }
    public var isTruncated: Bool { !reasons.isEmpty }

    public init(
        messages: [SessionMessage],
        textTruncated: [Bool],
        textBytes: [Int],
        totalMessageCount: Int?,
        nextFrom: Int?,
        reasons: [TranscriptTruncationReason],
        bytesRead: Int64,
        fileBytes: Int64
    ) {
        self.messages = messages
        self.textTruncated = textTruncated
        self.textBytes = textBytes
        self.totalMessageCount = totalMessageCount
        self.nextFrom = nextFrom
        self.reasons = reasons
        self.bytesRead = bytesRead
        self.fileBytes = fileBytes
    }

    /// One sentence an agent can relay, or `nil` when nothing was cut.
    public func notice(fileByteFormatter: (Int64) -> String) -> String? {
        guard isTruncated else { return nil }
        var parts: [String] = []
        if reasons.contains(.readCeiling) {
            parts.append(
                "the requested messages lie past the first "
                    + fileByteFormatter(bytesRead)
                    + " of a " + fileByteFormatter(fileBytes) + " log, which is as far as a bounded read goes"
            )
        }
        if reasons.contains(.messageLimit) { parts.append("the message limit was reached") }
        if reasons.contains(.byteBudget) { parts.append("the response byte budget was reached") }
        if reasons.contains(.messageText) { parts.append("some message text was clipped to fit") }
        let joined = parts.joined(separator: "; ")
        guard nextFrom != nil else { return "Truncated: " + joined + "." }
        return "Truncated: " + joined + ". Call again with the reported nextFrom to continue."
    }
}

/// A bounded read that cannot be performed as asked.
///
/// Four providers keep their sessions in stores that are not byte-truncatable
/// JSONL — Cursor's and AntiGravity's SQLite databases, Grok's sibling-file
/// transcript, Grok Bot's blob cache. For those, "read the first N bytes" has
/// no meaning: the only read available is the whole store.
///
/// The transcript tool advertises a byte ceiling, and an agent may call it in
/// a loop. Documenting the exception was not enough — an unbounded parse of a
/// large store stalls the request and can exhaust the app. So the tool refuses
/// above the ceiling and says why, which is something the caller can act on.
public enum TranscriptReadRefusal: Error, LocalizedError, Equatable {
    case wholeFileOnly(provider: SessionProvider, fileBytes: Int64, ceilingBytes: Int64)

    public var errorDescription: String? {
        switch self {
        case let .wholeFileOnly(provider, fileBytes, ceilingBytes):
            return "\(provider.displayName) stores its sessions in a format that can only be read "
                + "whole, and this one is \(Self.megabytes(fileBytes)) — past the "
                + "\(Self.megabytes(ceilingBytes)) a bounded read allows. Reading it would hold the "
                + "entire store in memory. Use sessions.search to find the moment you need, or open "
                + "the session in \(provider.displayName) itself."
        }
    }

    static func megabytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        return mb >= 10 ? "\(Int(mb.rounded())) MB" : String(format: "%.1f MB", mb)
    }
}

/// One session, read for an agent.
public struct SessionTranscriptResult: Sendable {
    public let summary: SessionSummary
    public let window: TranscriptWindow

    public init(summary: SessionSummary, window: TranscriptWindow) {
        self.summary = summary
        self.window = window
    }
}
