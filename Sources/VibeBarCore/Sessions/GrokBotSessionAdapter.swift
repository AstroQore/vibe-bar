import Foundation

/// Grok Bot conversations: the local cache the standalone `Grok Bot.app`
/// keeps at
/// `~/Library/Application Support/Grok Bot/sand-client-persistence/`.
///
/// This is xAI's cloud-bot client, **not** Grok Build — the two share a
/// company and nothing else. Every file in the directory is named
/// `<base32>.blob`, where the stem is the lowercase, unpadded RFC 4648
/// base32 of the key it holds, so `Base32` is how discovery decides whether
/// a file is one of ours. Two keys matter:
///
/// - `sand.client.slice.account.<account>.roster.last-roster` — one row per
///   bot: `id`, `name`, `description`, `createdAt`, `lastActivityAt`. The
///   row is the only place a conversation's *name* exists; the transcript
///   does not carry one. (Its `title` field is present but always empty, and
///   its `path` is a path inside the remote sandbox — never local.)
/// - `sand.client.slice.account.<account>.transcript.replicas.<bot uuid>` —
///   the conversation itself, one file per bot. That file is the session.
///
/// Everything else under the prefix (`ui-layout`, `composer-drafts`,
/// `send-journal`, …) is client state and is ignored. There can be more than
/// one account; the roster is resolved per account.
///
/// **A cloud cache, so read-only and partial by nature.** The conversations
/// live on xAI's servers; this directory is what the client happened to
/// replicate, which means history may be incomplete and the app rewrites it
/// underneath us. `deletionPlan` fails closed (AGENTS.md § 5), there is no
/// resume command, and nothing here feeds the cost ledger — the entries
/// carry no model, no token counts and no cost at all.
public struct GrokBotSessionAdapter: SessionProviderAdapter {
    public let provider: SessionProvider = .grokBot

    /// One parsed roster per adapter instance, invalidated by the roster
    /// file's own mtime + size. A scan calls `extractMetadata` once per bot
    /// and every one of those calls wants the same ~50 KB file; the registry
    /// builds one adapter and reuses it, so the cache is scan-scoped without
    /// any global state.
    private let rosters = RosterCache()

    public init() {}

    /// Deliberately not `FileManager.applicationSupportDirectory`: real-home
    /// reads route through the caller's `homeDirectory` (AGENTS.md § 6), and
    /// production passes `RealHomeDirectory.path`.
    static let storeRelativePath = "Library/Application Support/Grok Bot/sand-client-persistence"

    public func roots(homeDirectory: String) -> [URL] {
        [URL(fileURLWithPath: homeDirectory).appendingPathComponent(Self.storeRelativePath)]
    }

    public func discoverSessionFiles(homeDirectory: String) -> [URL] {
        roots(homeDirectory: homeDirectory).flatMap { root in
            SessionParsing.collectFiles(under: root) { Self.transcriptKey(at: $0) != nil }
        }
    }

    // MARK: - Keys

    /// The account and bot a transcript blob belongs to.
    struct TranscriptKey: Equatable {
        let accountID: String
        let botID: String
    }

    static let blobExtension = "blob"
    static let accountKeyPrefix = "sand.client.slice.account."
    static let transcriptInfix = ".transcript.replicas."
    static let rosterSuffix = ".roster.last-roster"
    static let variant = "bot"

    /// Longest filename stem we will even try to decode, and the largest
    /// blob we will read. Both are far above what the client writes (keys
    /// are ~100 characters, the biggest transcript here is ~110 KB) and exist
    /// so a junk file in the directory costs nothing.
    static let maxStemLength = 512
    static let maxBlobBytes: Int64 = 32 * 1024 * 1024

    /// The key a `.blob` filename encodes, or `nil` for anything that is not
    /// one of this store's account slices.
    static func decodedKey(at url: URL) -> String? {
        guard url.pathExtension == blobExtension else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty, stem.count <= maxStemLength else { return nil }
        guard let key = Base32.decodeToString(stem), key.hasPrefix(accountKeyPrefix) else { return nil }
        return key
    }

    static func transcriptKey(at url: URL) -> TranscriptKey? {
        guard let key = decodedKey(at: url) else { return nil }
        return transcriptKey(decoded: key)
    }

    static func transcriptKey(decoded key: String) -> TranscriptKey? {
        guard key.hasPrefix(accountKeyPrefix) else { return nil }
        let tail = key.dropFirst(accountKeyPrefix.count)
        guard let infix = tail.range(of: transcriptInfix) else { return nil }
        let accountID = String(tail[..<infix.lowerBound])
        let botID = String(tail[infix.upperBound...])
        // The account id is only ever compared against other decoded keys, so
        // it needs no charset beyond "plausible" — this store's ids contain
        // `%`. The bot id becomes the session id and travels much further, so
        // it is held to the conservative identifier charset.
        guard !accountID.isEmpty, accountID.count <= maxStemLength,
              !accountID.contains("/"), !accountID.contains("."),
              isIdentifier(botID)
        else { return nil }
        return TranscriptKey(accountID: accountID, botID: botID)
    }

    static func rosterKey(accountID: String) -> String {
        accountKeyPrefix + accountID + rosterSuffix
    }

    static func isIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 200 else { return false }
        return value.unicodeScalars.allSatisfy(identifierScalars.contains)
    }

    private static let identifierScalars = CharacterSet(charactersIn:
        "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-"
    )

    // MARK: - Metadata

    public func extractMetadata(fileURL: URL) throws -> SessionSummary {
        guard let key = Self.transcriptKey(at: fileURL) else {
            throw SessionParseError.invalidFormat(
                "\(fileURL.lastPathComponent): not a Grok Bot transcript blob"
            )
        }
        guard let entries = Self.entries(at: fileURL) else {
            throw SessionParseError.unreadable(fileURL.lastPathComponent)
        }
        let transcript = Self.transcript(from: entries)
        let row = rosterRow(for: key, in: fileURL.deletingLastPathComponent())

        let firstPrompt = transcript.messages.first { $0.role == .user }?.text
        let lastText = transcript.messages.last?.text

        return SessionSummary(
            provider: .grokBot,
            sessionID: key.botID,
            providerVariant: Self.variant,
            harness: .grokBot,
            // Cloud-side inference: the client never records which model
            // answered, and guessing one would be wrong at pricing time too.
            model: nil,
            title: SessionParsing.display(row?.name ?? firstPrompt, limit: SessionParsing.titleLimit),
            summary: SessionParsing.display(lastText ?? row?.description, limit: SessionParsing.summaryLimit),
            // The roster's `path` is a directory inside the remote sandbox
            // (`/home/box/…`), not anything on this Mac.
            projectDir: nil,
            createdAt: row?.createdAt ?? transcript.firstStamp,
            // The roster row and the transcript disagree in both directions —
            // the roster can lag a live conversation, and it also records
            // activity (a rename, an automation) that leaves no entry.
            lastActiveAt: Self.latest(transcript.lastStamp, row?.lastActivityAt),
            sourcePath: fileURL.path,
            sizeBytes: SessionParsing.fileSize(fileURL),
            messageCount: transcript.entryCount
        )
    }

    static func latest(_ dates: Date?...) -> Date? {
        dates.compactMap { $0 }.max()
    }

    // MARK: - Transcript

    public func parseTranscript(fileURL: URL, range: Range<Int>?) throws -> TranscriptDocument {
        guard let entries = Self.entries(at: fileURL) else {
            throw SessionParseError.unreadable(fileURL.lastPathComponent)
        }
        return SessionTranscriptSlicing.document(
            messages: Self.transcript(from: entries).messages,
            range: range
        )
    }

    /// The replica's `value.entries`, in the order the client wrote them.
    ///
    /// File order rather than timestamp order on purpose: a couple of
    /// conversations here have entries whose `timestampMs` runs backwards
    /// (a reply persisted before the message it answers), and the array is
    /// the client's own idea of the conversation.
    static func entries(at url: URL) -> [[String: Any]]? {
        guard SessionParsing.fileSize(url) <= maxBlobBytes else { return nil }
        guard let object = SessionParsing.jsonObject(at: url),
              let value = object["value"] as? [String: Any],
              let entries = value["entries"] as? [[String: Any]]
        else { return nil }
        return entries
    }

    struct Transcript {
        let messages: [SessionMessage]
        /// Conversation entries — `message` and `send-message` — whether or
        /// not they carried displayable text. This is what the list row
        /// counts, so a widget or a secret prompt still registers as a turn.
        let entryCount: Int
        let firstStamp: Date?
        let lastStamp: Date?
    }

    static func transcript(from entries: [[String: Any]]) -> Transcript {
        var messages: [SessionMessage] = []
        var entryCount = 0
        var first: Date?
        var last: Date?

        for entry in entries {
            let kind = SessionParsing.string(entry["kind"])
            guard kind == messageKind || kind == sendMessageKind else { continue }
            entryCount += 1
            let stamp = SessionParsing.date(entry["timestampMs"])
            if let stamp {
                first = min(first ?? stamp, stamp)
                last = max(last ?? stamp, stamp)
            }
            guard let message = self.message(from: entry, kind: kind, seq: messages.count, stamp: stamp) else {
                continue
            }
            messages.append(message)
        }
        return Transcript(messages: messages, entryCount: entryCount, firstStamp: first, lastStamp: last)
    }

    static let messageKind = "message"
    static let sendMessageKind = "send-message"

    /// One entry as a transcript bubble, read from the transcript owner's —
    /// the bot's — point of view.
    ///
    /// - `send-message` is the bot's own outbound turn to the human, so it is
    ///   the assistant.
    /// - `message` with `role: "user"` and no `fromAgent` is the human.
    /// - `message` with `role: "user"` and a `fromAgent` is *another bot*
    ///   talking to this one. Still an inbound turn, so still `.user` — the
    ///   sender's name is prefixed because `SessionRole` has no case for
    ///   "someone else's agent", and because `.user` is what the search index
    ///   and the transcript's prompt list actually keep.
    /// - `message` with `role: "assistant"` and a `toAgent` is this bot
    ///   answering *that* other bot. It is the bot's own text — the same
    ///   string appears in the other bot's replica as an inbound `fromAgent`
    ///   message — so it is the assistant, marked with the addressee.
    ///
    /// `event` (renames, automation changes) and `user-attachment` are not
    /// conversation and are dropped.
    static func message(
        from entry: [String: Any],
        kind: String?,
        seq: Int,
        stamp: Date?
    ) -> SessionMessage? {
        if kind == sendMessageKind {
            guard let payload = entry["message"] as? [String: Any] else { return nil }
            // Non-text payloads (a rendered widget, a secret request, a bare
            // attachment) have no content field; they still counted as turns.
            let text = SessionParsing.firstNonEmptyText(payload["content"])
            guard !text.isEmpty else { return nil }
            return SessionMessage(seq: seq, role: .assistant, text: text, timestamp: stamp)
        }

        let text = SessionParsing.firstNonEmptyText(entry["content"])
        guard !text.isEmpty else { return nil }
        switch SessionParsing.string(entry["role"]) {
        case "user":
            return SessionMessage(
                seq: seq,
                role: .user,
                text: prefixed(text, with: agentName(entry["fromAgent"]), arrow: false),
                timestamp: stamp
            )
        case "assistant":
            return SessionMessage(
                seq: seq,
                role: .assistant,
                text: prefixed(text, with: agentName(entry["toAgent"]), arrow: true),
                timestamp: stamp
            )
        default:
            return nil
        }
    }

    /// `Name: …` for an inbound agent turn, `→ Name: …` for an outbound one.
    /// Without an agent the text is its own.
    static func prefixed(_ text: String, with name: String?, arrow: Bool) -> String {
        guard let name else { return text }
        return (arrow ? "→ " : "") + name + ": " + text
    }

    static func agentName(_ value: Any?) -> String? {
        guard let agent = value as? [String: Any] else { return nil }
        return SessionParsing.display(SessionParsing.string(agent["name"]), limit: agentNameLimit)
    }

    static let agentNameLimit = 60

    // MARK: - Roster

    struct RosterRow: Equatable {
        let id: String
        let name: String?
        let description: String?
        let createdAt: Date?
        let lastActivityAt: Date?
    }

    func rosterRow(for key: TranscriptKey, in directory: URL) -> RosterRow? {
        rosters.rows(forAccount: key.accountID, in: directory)[key.botID]
    }

    /// Every bot the roster for `accountID` knows about, keyed by id.
    ///
    /// A missing or unparseable roster is an empty map, not a failure: the
    /// transcripts are still readable, they just list without their names.
    static func rosterRows(forAccount accountID: String, in directory: URL) -> (URL, [String: RosterRow])? {
        guard let url = rosterURL(forAccount: accountID, in: directory) else { return nil }
        return (url, rosterRows(at: url))
    }

    /// The store is flat and small (a couple of dozen files), so finding the
    /// roster means decoding the stems until one is the roster key for this
    /// account. The result is cached against the file's own stamp, so this
    /// runs once per scan rather than once per bot.
    static func rosterURL(forAccount accountID: String, in directory: URL) -> URL? {
        let wanted = rosterKey(accountID: accountID)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsSubdirectoryDescendants]
        )) ?? []
        return contents.first { decodedKey(at: $0) == wanted }
    }

    static func rosterRows(at url: URL) -> [String: RosterRow] {
        guard SessionParsing.fileSize(url) <= maxBlobBytes,
              let object = SessionParsing.jsonObject(at: url),
              let value = object["value"] as? [String: Any],
              let rows = value["rows"] as? [[String: Any]]
        else { return [:] }

        var out: [String: RosterRow] = [:]
        for row in rows {
            guard let id = SessionParsing.string(row["id"]) else { continue }
            out[id] = RosterRow(
                id: id,
                // `title` exists on every row and is always empty; `name` is
                // the one the client shows in its sidebar.
                name: SessionParsing.firstString(row["name"], row["title"]),
                description: SessionParsing.string(row["description"]),
                createdAt: SessionParsing.date(row["createdAt"]),
                lastActivityAt: SessionParsing.firstDate(row["lastActivityAt"], row["updatedAt"])
            )
        }
        return out
    }

    // MARK: - Deletion

    public func deletionPlan(for summary: SessionSummary, homeDirectory: String) throws -> SessionDeletionPlan {
        throw SessionDeleteError.providerIsReadOnly(.grokBot)
    }
}

/// One roster per account, invalidated by the roster file's own stamp.
///
/// Reference type so a `Sendable` value-type adapter can still keep a
/// scan-scoped cache; the lock is what makes that honest, since the index
/// fans its per-file work out across tasks.
private final class RosterCache: @unchecked Sendable {
    private struct Entry {
        let url: URL
        let stamp: Stamp
        let rows: [String: GrokBotSessionAdapter.RosterRow]
    }

    struct Stamp: Equatable {
        let modified: Date?
        let size: Int64

        static func of(_ url: URL) -> Stamp? {
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            ) else { return nil }
            return Stamp(modified: values.contentModificationDate, size: Int64(values.fileSize ?? 0))
        }
    }

    /// One account is the norm and a handful is the realistic maximum; past
    /// that the map is cleared rather than evicted one by one, because this
    /// is a scan-lifetime cache and not a long-lived one.
    private static let maxAccounts = 8

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func rows(
        forAccount accountID: String,
        in directory: URL
    ) -> [String: GrokBotSessionAdapter.RosterRow] {
        let cacheKey = directory.path + "\u{0}" + accountID
        lock.lock()
        let cached = entries[cacheKey]
        lock.unlock()

        // A single stat re-validates the hit; only a miss pays for the
        // directory listing that locates the roster again.
        if let cached, Stamp.of(cached.url) == cached.stamp {
            return cached.rows
        }

        guard let (url, rows) = GrokBotSessionAdapter.rosterRows(
            forAccount: accountID, in: directory
        ) else { return [:] }

        lock.lock()
        if entries.count >= Self.maxAccounts { entries.removeAll() }
        entries[cacheKey] = Entry(url: url, stamp: Stamp.of(url) ?? Stamp(modified: nil, size: 0), rows: rows)
        lock.unlock()
        return rows
    }
}
