import Foundation

/// How much of a transcript the session index is allowed to keep.
///
/// The index's schema and its 512 KiB / 2 000-character ceilings live in
/// `agent-session-kit`; this policy is Vibe Bar's tighter, host-side budget
/// on top of them. It exists because the FTS5 `trigram` tokenizer — the one
/// tokenizer that makes CJK and identifier substring search work — costs
/// roughly 3 bytes of index per character of text. At the kit's ceilings a
/// year of heavy agent use produced a 2.5 GB `session_index.sqlite3` whose
/// bulk was tool output: command dumps, file listings, build logs.
///
/// Two components enforce the same numbers:
/// - `SessionIndexingBounds` trims transcripts on their way *into* the
///   index (and caps how much of a multi-hundred-MB rollout is parsed at
///   all, which is what bounds the indexer's memory);
/// - `SessionIndexCompactor` re-asserts the caps over rows already *in*
///   the index, so tightening a number here shrinks the existing database
///   on the next maintenance pass instead of only affecting new sessions.
public struct SessionIndexExcerptPolicy: Sendable, Equatable {
    /// Characters kept of a tool or system excerpt. Tool output is three
    /// quarters of all indexed text but almost never what a search is *for*;
    /// 600 characters keeps the command line and the head of its output —
    /// the part that identifies it — without indexing the whole dump.
    public var toolExcerptCharacters: Int

    /// Characters kept of a user or assistant excerpt. Matches the kit's
    /// own per-message cap: prose is what searches target, so it is not
    /// tightened here.
    public var proseExcerptCharacters: Int

    /// UTF-8 bytes of excerpt text kept per session, counted in message
    /// order and stopping at the first message that does not fit — the same
    /// stop-at-overflow shape as the kit's 512 KiB budget, just lower.
    public var sessionExcerptBytes: Int

    /// Transcripts larger than this are body-indexed from a copy of their
    /// first `headParseByteLimit` bytes instead of the whole file. The
    /// kit's parser materializes every message of a rollout before the
    /// excerpt budget is applied, so parsing a 1.6 GB rollout means
    /// gigabytes of transient strings; the session budget above is filled
    /// by the first few hundred KiB anyway.
    ///
    /// 8 MiB, not the 64 MiB this started at: `sessionExcerptBytes` is
    /// 128 KiB, so the budget saturates two orders of magnitude before the
    /// old limit and the extra 56 MiB were copied, parsed into strings, and
    /// thrown away on every re-index of a file that had merely grown. The
    /// only thing a larger head buys is a deeper *fallback* when the head is
    /// mostly matter the trim drops (long tool output), and 8 MiB of JSONL
    /// is already thousands of messages.
    public var headParseByteLimit: Int64

    public init(
        toolExcerptCharacters: Int = 600,
        proseExcerptCharacters: Int = 2_000,
        sessionExcerptBytes: Int = 128 * 1024,
        headParseByteLimit: Int64 = 8 * 1024 * 1024
    ) {
        self.toolExcerptCharacters = toolExcerptCharacters
        self.proseExcerptCharacters = proseExcerptCharacters
        self.sessionExcerptBytes = sessionExcerptBytes
        self.headParseByteLimit = headParseByteLimit
    }

    public static let standard = SessionIndexExcerptPolicy()

    /// Bump when the standard *excerpt* caps tighten (or loosen) so
    /// `SessionIndexCompactor` re-runs its trim pass over existing rows
    /// regardless of the daily throttle.
    ///
    /// `headParseByteLimit` is deliberately not one of those caps:
    /// it bounds what is *read*, and the rows already in the database were
    /// written under the same 128 KiB excerpt budget either way. Lowering it
    /// must not cost the user an unscheduled pass over a gigabyte-scale
    /// index that would find nothing to trim.
    public static let version = 1

    /// The excerpt cap for one message, by the role the index stores.
    /// `.other` gets the tool cap because the kit files it as `system`
    /// when it writes the row.
    public func excerptCharacters(for role: SessionRole) -> Int {
        switch role {
        case .tool, .system, .other: return toolExcerptCharacters
        case .user, .assistant: return proseExcerptCharacters
        }
    }
}
