import Foundation
import SQLite3

/// Cursor agent sessions: one SQLite store per conversation at
/// `~/.cursor/chats/<workspace-hash>/<agent-id>/store.db`.
///
/// The store has two tables and no schema anyone published:
///
/// - `meta(key, value)` — row `'0'` holds the conversation card as
///   **hex-encoded** JSON: `agentId`, `latestRootBlobId`, `name`, `mode`,
///   and `createdAt` in milliseconds. That row alone is enough to render a
///   list entry, which is why it is read first and separately.
/// - `blobs(id, data)` — a content-addressed graph keyed by the SHA-256 of
///   each value. A blob is either a raw JSON message (`{"role":…,
///   "content":…}`) or an undocumented protobuf node whose length-32
///   length-delimited fields are references to other blobs. The nodes carry
///   the facts a session row wants: field 9 is the workspace `file://` URI,
///   field 22 the surface (`cli`), field 26 a millisecond stamp, and field 4
///   an inline message JSON.
///
/// The walk from `latestRootBlobId` is bounded twice over (blobs visited and
/// bytes decoded) because the graph's shape is not ours to trust, and every
/// read goes through `LiveSQLiteReader`: Cursor keeps this file open with a
/// live WAL, so a locked or unreadable store is skipped rather than fatal.
///
/// **Read-only, permanently.** Cursor owns the store's lifecycle and holds it
/// open; `deletionPlan` fails closed (AGENTS.md § 5). Token counts stay
/// remote too — the nested field-5 accounting is context-window bookkeeping,
/// not billable usage, so nothing here feeds the cost ledger.
public struct CursorSessionAdapter: SessionProviderAdapter {
    public let provider: SessionProvider = .cursor

    public init() {}

    public func roots(homeDirectory: String) -> [URL] {
        [URL(fileURLWithPath: homeDirectory).appendingPathComponent(".cursor/chats")]
    }

    public func discoverSessionFiles(homeDirectory: String) -> [URL] {
        roots(homeDirectory: homeDirectory).flatMap { root in
            SessionParsing.collectFiles(under: root) { $0.lastPathComponent == Self.storeFileName }
        }
    }

    static let storeFileName = "store.db"

    // MARK: - Limits

    /// Blobs resolved in one walk. A conversation past this is truncated
    /// rather than followed: the graph is another app's, and a list row must
    /// not be able to cost an unbounded number of point lookups.
    static let maxBlobsVisited = 2_000
    /// Bytes decoded in one walk, across every blob.
    static let maxBytesVisited = 16 * 1024 * 1024
    /// `meta` rows examined while looking for the conversation card.
    static let maxMetaRows = 16

    // MARK: - Metadata

    public func extractMetadata(fileURL: URL) throws -> SessionSummary {
        guard let (card, walk) = Self.inspect(at: fileURL, collectingTranscript: false) else {
            throw SessionParseError.unreadable(fileURL.lastPathComponent)
        }
        guard !card.agentID.isEmpty else {
            throw SessionParseError.invalidFormat("\(fileURL.lastPathComponent): no agent id")
        }

        return SessionSummary(
            provider: .cursor,
            sessionID: card.agentID,
            providerVariant: card.mode,
            harness: .cursor,
            model: walk?.model,
            title: SessionParsing.display(card.name, limit: SessionParsing.titleLimit)
                ?? Self.fallbackTitle(agentID: card.agentID),
            summary: nil,
            projectDir: walk?.projectDir,
            createdAt: card.createdAt,
            // The store is rewritten on every turn, so its own modification
            // time is the honest "last active". The nodes' field-26 stamp is
            // not a per-turn clock — every node in a conversation carries the
            // same value — so it is only a fallback.
            lastActiveAt: SessionParsing.modificationDate(fileURL)
                ?? walk?.lastStamp
                ?? card.createdAt,
            sourcePath: fileURL.path,
            sizeBytes: SessionParsing.fileSize(fileURL),
            messageCount: walk?.messageCount ?? SessionSummary.unknownMessageCount
        )
    }

    /// `Agent ef677032…` — enough of the id to tell two unnamed rows apart.
    static func fallbackTitle(agentID: String) -> String {
        let head = agentID.split(separator: "-").first.map(String.init) ?? agentID
        return "Agent \(String(head.prefix(8)))…"
    }

    // MARK: - Transcript

    public func parseTranscript(fileURL: URL, range: Range<Int>?) throws -> TranscriptDocument {
        guard let (_, walk) = Self.inspect(at: fileURL, collectingTranscript: true), let walk else {
            throw SessionParseError.unreadable(fileURL.lastPathComponent)
        }
        let messages = walk.messages.enumerated().map { index, message in
            SessionMessage(seq: index, role: message.role, text: message.text, timestamp: nil)
        }
        return SessionTranscriptSlicing.document(messages: messages, range: range)
    }

    // MARK: - Deletion

    public func deletionPlan(for summary: SessionSummary, homeDirectory: String) throws -> SessionDeletionPlan {
        throw SessionDeleteError.providerIsReadOnly(.cursor)
    }

    // MARK: - The conversation card

    struct Card {
        let agentID: String
        let rootBlobID: String?
        let name: String?
        let mode: String?
        let createdAt: Date?
    }

    /// The card and the blob walk from one handle.
    ///
    /// Both reads share a connection deliberately: `LiveSQLiteReader` may
    /// have to snapshot a locked store into a temp directory, and doing that
    /// twice per file per scan would copy the database twice for nothing.
    /// `nil` means the store could not be read at all — the caller treats
    /// that as "skip this file", never as an empty conversation.
    static func inspect(at url: URL, collectingTranscript: Bool) -> (card: Card, walk: Walk?)? {
        LiveSQLiteReader.read(at: url) { database -> (card: Card, walk: Walk?)? in
            guard let card = try self.card(database) else { return nil }
            let walk = try self.walk(
                database,
                from: card.rootBlobID,
                collectingTranscript: collectingTranscript
            )
            return (card, walk)
        } ?? nil
    }

    /// The `meta` row that decodes to a conversation card.
    ///
    /// Cursor writes it under key `'0'`, but the key is read rather than
    /// assumed: the rows are tiny, and a store whose card moved to another
    /// key should list rather than vanish.
    static func card(_ database: OpaquePointer) throws -> Card? {
        let statement = try LiveSQLiteReader.prepare(database, "SELECT value FROM meta ORDER BY key")
        defer { sqlite3_finalize(statement) }
        var rows = 0
        while sqlite3_step(statement) == SQLITE_ROW, rows < maxMetaRows {
            rows += 1
            guard let hex = LiveSQLiteReader.text(statement, 0),
                  let data = hexDecoded(hex),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let agentID = SessionParsing.string(object["agentId"])
            else { continue }
            return Card(
                agentID: agentID,
                rootBlobID: SessionParsing.string(object["latestRootBlobId"]),
                name: SessionParsing.string(object["name"]),
                mode: SessionParsing.string(object["mode"]),
                createdAt: SessionParsing.date(object["createdAt"])
            )
        }
        return nil
    }

    /// Lowercase-or-uppercase hex to bytes. Anything that is not an even
    /// number of hex digits is not the card and yields `nil`.
    static func hexDecoded(_ hex: String) -> Data? {
        let scalars = Array(hex.utf8)
        guard !scalars.isEmpty, scalars.count.isMultiple(of: 2) else { return nil }
        var out = Data(capacity: scalars.count / 2)
        var index = 0
        while index < scalars.count {
            guard let high = nibble(scalars[index]), let low = nibble(scalars[index + 1]) else {
                return nil
            }
            out.append(high << 4 | low)
            index += 2
        }
        return out
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30           // 0-9
        case 0x61...0x66: return byte - 0x61 + 10      // a-f
        case 0x41...0x46: return byte - 0x41 + 10      // A-F
        default: return nil
        }
    }

    // MARK: - The blob walk

    struct Message {
        let role: SessionRole
        let text: String
    }

    struct Walk {
        let projectDir: String?
        let model: String?
        let lastStamp: Date?
        let messageCount: Int
        let messages: [Message]
    }

    /// Breadth-first from `root` over every length-32 reference, resolving
    /// each id against the same database.
    ///
    /// Discovery order is conversation order: a node lists its message
    /// references in turn order, so appending as they resolve reproduces the
    /// transcript without needing to understand the schema. A reference the
    /// store does not hold is skipped, and a node that points back at an
    /// ancestor is visited once — the graph is a merkle chain, so back-edges
    /// are normal rather than corruption.
    static func walk(
        _ database: OpaquePointer,
        from root: String?,
        collectingTranscript: Bool
    ) throws -> Walk? {
        guard let root, !root.isEmpty else { return nil }
        let statement = try LiveSQLiteReader.prepare(database, "SELECT data FROM blobs WHERE id = ?")
        defer { sqlite3_finalize(statement) }

        var queue = [root]
        var seen: Set<String> = [root]
        var budgetBytes = maxBytesVisited
        var visited = 0

        var projectDir: String?
        var model: String?
        var lastStamp: Int64 = 0
        var messageCount = 0
        var messages: [Message] = []

        var cursor = 0
        while cursor < queue.count, visited < maxBlobsVisited, budgetBytes > 0 {
            let id = queue[cursor]
            cursor += 1
            guard let data = try blob(statement, id: id) else { continue }
            visited += 1
            budgetBytes -= data.count

            if let object = messageObject(data) {
                absorb(
                    message: object,
                    model: &model,
                    messageCount: &messageCount,
                    messages: &messages,
                    collectingTranscript: collectingTranscript
                )
                continue
            }

            for field in ProtobufWireReader.fields(in: [UInt8](data)) {
                switch field.number {
                case workspaceURIField where projectDir == nil:
                    projectDir = field.text.flatMap(path(fromFileURI:))
                case timestampField:
                    if let stamp = field.unsigned, stamp <= UInt64(Int64.max) {
                        lastStamp = max(lastStamp, Int64(stamp))
                    }
                case inlineMessageField:
                    guard let bytes = field.bytes,
                          let object = messageObject(Data(bytes))
                    else { break }
                    absorb(
                        message: object,
                        model: &model,
                        messageCount: &messageCount,
                        messages: &messages,
                        collectingTranscript: collectingTranscript
                    )
                default:
                    break
                }
                guard let bytes = field.bytes, bytes.count == referenceByteCount else { continue }
                let reference = hexEncoded(bytes)
                if seen.insert(reference).inserted { queue.append(reference) }
            }
        }

        return Walk(
            projectDir: projectDir,
            model: model,
            lastStamp: lastStamp > 0 ? SessionParsing.date(NSNumber(value: lastStamp)) : nil,
            messageCount: messageCount,
            messages: messages
        )
    }

    /// Field numbers observed on Cursor 2026 stores. There is no public
    /// schema, so an unrecognised field is ignored rather than guessed at.
    static let workspaceURIField = 9
    static let inlineMessageField = 4
    static let timestampField = 26
    /// Blob ids are SHA-256, so a reference is exactly 32 bytes.
    static let referenceByteCount = 32

    /// `nil` only for a genuinely missing row. A step error (`SQLITE_BUSY`,
    /// `SQLITE_LOCKED`, …) on Cursor's live handle throws so
    /// `LiveSQLiteReader.read` abandons this pass and retries on a snapshot
    /// instead of indexing a silently partial walk.
    private static func blob(_ statement: OpaquePointer, id: String) throws -> Data? {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return LiveSQLiteReader.blob(statement, 0)
        case SQLITE_DONE: return nil
        default: throw LiveSQLiteReader.ReadError.statement
        }
    }

    /// A blob that is a message rather than a node. Cheap rejection first:
    /// protobuf nodes start with a wire key, never with `{`.
    static func messageObject(_ data: Data) -> [String: Any]? {
        guard data.first == UInt8(ascii: "{") else { return nil }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["role"] != nil
        else { return nil }
        return object
    }

    private static func absorb(
        message: [String: Any],
        model: inout String?,
        messageCount: inout Int,
        messages: inout [Message],
        collectingTranscript: Bool
    ) {
        messageCount += 1
        let role = role(message["role"] as? String)
        if model == nil { model = self.model(in: message) }
        guard collectingTranscript, role == .user || role == .assistant else { return }
        let text = self.text(in: message["content"])
        guard !text.isEmpty else { return }
        messages.append(Message(role: role, text: text))
    }

    static func role(_ raw: String?) -> SessionRole {
        switch raw {
        case "user": return .user
        case "assistant": return .assistant
        case "tool": return .tool
        case "system": return .system
        default: return .other
        }
    }

    /// `content[].providerOptions.cursor.modelName` — Cursor stamps the model
    /// on the assistant *part*, not on the message, and short or aborted
    /// conversations carry no model at all.
    static func model(in message: [String: Any]) -> String? {
        guard let parts = message["content"] as? [[String: Any]] else { return nil }
        for part in parts {
            guard let options = part["providerOptions"] as? [String: Any],
                  let cursor = options["cursor"] as? [String: Any],
                  let model = SessionParsing.string(cursor["modelName"])
            else { continue }
            return model
        }
        return nil
    }

    /// A user turn's content is a plain string; an assistant turn's is an
    /// array of parts of which only `text` is the reply. Reasoning traces and
    /// tool calls are deliberately dropped — the same choice every other
    /// adapter makes about a model's private scratch work.
    static func text(in content: Any?) -> String {
        if let text = content as? String { return text }
        guard let parts = content as? [[String: Any]] else { return "" }
        var out: [String] = []
        for part in parts where part["type"] as? String == "text" {
            guard let text = part["text"] as? String, !text.isEmpty else { continue }
            out.append(text)
        }
        return out.joined(separator: "\n")
    }

    /// `file:///Users/example/a%20project` → `/Users/example/a project`.
    static func path(fromFileURI raw: String) -> String? {
        guard raw.hasPrefix("file://"), let url = URL(string: raw), url.isFileURL else { return nil }
        let path = url.path
        return path.isEmpty ? nil : path
    }

    static func hexEncoded(_ bytes: ArraySlice<UInt8>) -> String {
        var out = ""
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0F)])
        }
        return out
    }

    private static let hexDigits = Array("0123456789abcdef")
}
