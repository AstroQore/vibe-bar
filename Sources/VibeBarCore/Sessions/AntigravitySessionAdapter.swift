import Foundation

/// AntiGravity sessions: one SQLite database per conversation under
/// `~/.gemini/antigravity{,-cli,-ide}/conversations/<uuid>.db`, with the
/// filename's UUID as the conversation id.
///
/// Three surfaces write the same schema, so one adapter covers all of
/// them and records which produced a row in `providerVariant`. A handful
/// of conversations exist only as a bare `<uuid>.pb` protobuf snapshot;
/// those are listed from their filename and file dates alone.
///
/// Everything about this provider is best-effort. The databases have no
/// message table — the transcript is reconstructed by pulling readable
/// text runs out of each step's protobuf payload — and both title
/// sources are side stores that are routinely stale (see
/// `AntigravityConversationIndex`). The one thing the adapter refuses to
/// do is delete: AntiGravity holds live WAL handles on these files, so
/// `deletionPlan` fails closed with `.providerIsReadOnly` (AGENTS.md § 5).
public struct AntigravitySessionAdapter: SessionProviderAdapter {
    public let provider: SessionProvider = .antigravity

    private let index: AntigravityConversationIndex

    public init() {
        self.init(index: AntigravityConversationIndex())
    }

    public init(index: AntigravityConversationIndex) {
        self.index = index
    }

    // MARK: - Surfaces

    /// IDE conversations (`~/.gemini/antigravity`).
    public static let ideVariant = "ide"
    /// CLI conversations (`~/.gemini/antigravity-cli`), the only surface
    /// with a documented resume command.
    public static let cliVariant = SessionResumeCommandBuilder.antigravityCLIVariant
    /// The newer IDE data directory (`~/.gemini/antigravity-ide`), which
    /// ships alongside the original one rather than replacing it.
    public static let ide2Variant = "ide2"

    static let surfaces: [(directory: String, variant: String)] = [
        ("antigravity", ideVariant),
        ("antigravity-cli", cliVariant),
        ("antigravity-ide", ide2Variant)
    ]

    static let conversationsDirectoryName = "conversations"

    public func roots(homeDirectory: String) -> [URL] {
        let gemini = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".gemini")
        return Self.surfaces.map { surface in
            gemini
                .appendingPathComponent(surface.directory, isDirectory: true)
                .appendingPathComponent(Self.conversationsDirectoryName, isDirectory: true)
        }
    }

    public func discoverSessionFiles(homeDirectory: String) -> [URL] {
        roots(homeDirectory: homeDirectory).flatMap { root in
            // `<uuid>.db-wal` / `<uuid>.db-shm` carry the `db-wal` /
            // `db-shm` extension, so an exact match already excludes the
            // journal siblings of a live conversation.
            SessionParsing.collectFiles(under: root) {
                $0.pathExtension == "db" || $0.pathExtension == "pb"
            }
        }
    }

    /// `.../antigravity-cli/conversations/<uuid>.db` → `cli`. Returns nil
    /// for anything that is not directly inside a known surface's
    /// `conversations` directory.
    static func variant(forFile url: URL) -> String? {
        let conversations = url.deletingLastPathComponent()
        guard conversations.lastPathComponent == conversationsDirectoryName else { return nil }
        let surface = conversations.deletingLastPathComponent().lastPathComponent
        return surfaces.first { $0.directory == surface }?.variant
    }

    static func surfaceDirectory(forFile url: URL) -> URL {
        url.deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: - Metadata

    public func extractMetadata(fileURL: URL) throws -> SessionSummary {
        guard let variant = Self.variant(forFile: fileURL) else {
            throw SessionParseError.invalidFormat("\(fileURL.lastPathComponent): not an AntiGravity conversation")
        }
        let sessionID = fileURL.deletingPathExtension().lastPathComponent
        guard !sessionID.isEmpty else {
            throw SessionParseError.invalidFormat("\(fileURL.lastPathComponent): no conversation id")
        }
        let hydrated = index.record(
            for: sessionID,
            surface: Self.surfaceDirectory(forFile: fileURL)
        )

        // A `.pb` snapshot is opaque: it is listed so the conversation is
        // not silently missing, and nothing is claimed about its contents.
        guard fileURL.pathExtension == "db" else {
            return summary(
                sessionID: sessionID,
                variant: variant,
                model: nil,
                title: hydrated?.title,
                summaryText: nil,
                projectDir: hydrated?.projectDir,
                createdAt: SessionParsing.creationDate(fileURL),
                lastActiveAt: hydrated?.lastModified ?? SessionParsing.modificationDate(fileURL),
                fileURL: fileURL,
                messageCount: SessionSummary.unknownMessageCount
            )
        }

        let turns = AntigravityLiveSQLite.turns(at: fileURL)
        let dates = (turns ?? []).map(\.turn.date)
        let firstText = hydrated?.title == nil ? firstUserishText(fileURL: fileURL) : nil

        return summary(
            sessionID: sessionID,
            variant: variant,
            model: Self.model(turns: turns),
            title: hydrated?.title ?? firstText,
            summaryText: firstText,
            projectDir: hydrated?.projectDir,
            createdAt: dates.first ?? SessionParsing.creationDate(fileURL),
            lastActiveAt: dates.last ?? hydrated?.lastModified ?? SessionParsing.modificationDate(fileURL),
            fileURL: fileURL,
            messageCount: turns.map(\.count) ?? SessionSummary.unknownMessageCount
        )
    }

    /// The most recent turn's model. `gen_metadata` is already decoded for
    /// the dates and the message count, so no extra read happens here; the
    /// router alias is the documented fallback when the model enum itself
    /// has no learned label (see `AntigravitySessionReader.Turn`).
    static func model(turns: [(idx: Int, turn: AntigravitySessionReader.Turn)]?) -> String? {
        guard let turns else { return nil }
        for entry in turns.reversed() {
            if let model = entry.turn.model ?? entry.turn.routedModel { return model }
        }
        return nil
    }

    private func summary(
        sessionID: String,
        variant: String,
        model: String?,
        title: String?,
        summaryText: String?,
        projectDir: String?,
        createdAt: Date?,
        lastActiveAt: Date?,
        fileURL: URL,
        messageCount: Int
    ) -> SessionSummary {
        SessionSummary(
            provider: .antigravity,
            sessionID: sessionID,
            providerVariant: variant,
            harness: .antigravity,
            model: model,
            title: SessionParsing.display(title, limit: SessionParsing.titleLimit)
                ?? Self.fallbackTitle(sessionID: sessionID),
            summary: SessionParsing.display(summaryText, limit: SessionParsing.summaryLimit),
            projectDir: projectDir,
            createdAt: createdAt,
            lastActiveAt: lastActiveAt,
            sourcePath: fileURL.path,
            sizeBytes: SessionParsing.fileSize(fileURL),
            messageCount: messageCount
        )
    }

    /// `Conversation 6529ee47…` — enough of the id to tell two rows apart
    /// without showing a full UUID in a list.
    static func fallbackTitle(sessionID: String) -> String {
        let head = sessionID.split(separator: "-").first.map(String.init) ?? sessionID
        return "Conversation \(String(head.prefix(8)))…"
    }

    /// First readable prose in the opening steps, used only when no side
    /// store had a title. Tool-argument JSON is skipped: it is real text,
    /// but it is not what the conversation was about.
    private func firstUserishText(fileURL: URL) -> String? {
        guard let steps = AntigravityLiveSQLite.steps(at: fileURL) else { return nil }
        for step in steps.prefix(Self.titleStepScanLimit) {
            guard let payload = step.payload else { continue }
            for run in AntigravityStepText.runs(in: payload) where !run.hasPrefix("{") {
                return run
            }
        }
        return nil
    }

    static let titleStepScanLimit = 12

    // MARK: - Transcript

    public func parseTranscript(fileURL: URL, range: Range<Int>?) throws -> TranscriptDocument {
        guard fileURL.pathExtension == "db" else { return .empty }
        guard let steps = AntigravityLiveSQLite.steps(at: fileURL) else {
            throw SessionParseError.unreadable(fileURL.lastPathComponent)
        }
        let turns = AntigravityLiveSQLite.turns(at: fileURL) ?? []

        var stepMessages: [(idx: Int, role: SessionRole, text: String)] = []
        for step in steps {
            guard let payload = step.payload else { continue }
            let runs = AntigravityStepText.runs(in: payload)
            guard !runs.isEmpty else { continue }
            let text = SessionParsing.truncate(
                runs.joined(separator: "\n"),
                limit: AntigravityStepText.maxStepTextLength
            )
            if let role = Self.stepTypeRoleMap[step.type] {
                stepMessages.append((step.idx, role, text))
            } else {
                stepMessages.append((step.idx, .other, "Step \(step.type): \(text)"))
            }
        }

        var messages: [SessionMessage] = []
        var stepCursor = 0
        for (idx, turn) in turns {
            var emittedInRegion = false
            while stepCursor < stepMessages.count, stepMessages[stepCursor].idx <= idx {
                let step = stepMessages[stepCursor]
                messages.append(SessionMessage(
                    seq: messages.count, role: step.role, text: step.text, timestamp: nil
                ))
                emittedInRegion = true
                stepCursor += 1
            }

            // The turn card is the fallback view of a region whose steps
            // gave up no text at all — otherwise the step text *is* the
            // transcript and a token line adds nothing.
            if !emittedInRegion {
                messages.append(SessionMessage(
                    seq: messages.count,
                    role: .other,
                    text: Self.turnCard(turn),
                    timestamp: turn.date
                ))
            }
        }
        while stepCursor < stepMessages.count {
            let step = stepMessages[stepCursor]
            messages.append(SessionMessage(
                seq: messages.count, role: step.role, text: step.text, timestamp: nil
            ))
            stepCursor += 1
        }

        return SessionTranscriptSlicing.document(messages: messages, range: range)
    }

    static func turnCard(_ turn: AntigravitySessionReader.Turn) -> String {
        let tokens = "in \(turn.inputTokens) · out \(turn.outputTokens)"
        guard let model = turn.model ?? turn.routedModel else { return "Turn — \(tokens)" }
        return "Turn — \(model) · \(tokens)"
    }

    /// Step types observed on AntiGravity 2026 builds. The numbers are an
    /// internal enum with no public schema, so an unrecognized type is
    /// still shown — labelled with its raw value — rather than dropped.
    static let stepTypeRoleMap: [Int: SessionRole] = [
        8: .assistant,
        9: .tool,
        14: .system,
        15: .assistant,
        23: .system,
        33: .tool,
        98: .system,
        132: .assistant
    ]

    // MARK: - Deletion

    /// AntiGravity keeps live SQLite handles (and a `-wal` / `-shm` pair)
    /// on the conversation databases, and removing one out from under a
    /// running IDE is how a store gets corrupted rather than emptied.
    public func deletionPlan(for summary: SessionSummary, homeDirectory: String) throws -> SessionDeletionPlan {
        throw SessionDeleteError.providerIsReadOnly(.antigravity)
    }
}

/// Pulls human-readable text out of an AntiGravity `steps.step_payload`
/// blob.
///
/// The payload is an undocumented protobuf message, so the extractor
/// walks the wire format the way `protoc --decode_raw` does: every
/// length-delimited field is either a string (keep it, if it reads like
/// prose) or a nested message (recurse). What is left over — ids, field
/// names, hashes, paths — is filtered out by shape, since the schema
/// gives no way to filter it by name.
enum AntigravityStepText {
    /// A step's text is a transcript entry, not a document; the cap keeps
    /// one pasted file from dominating the index.
    static let maxStepTextLength = 4_000
    /// Shorter runs are almost always field names (`sessionID`,
    /// `toolAction`) rather than content.
    static let minRunLength = 8
    /// CJK carries far more per character and never appears in this
    /// schema's field names, so those runs get a lower floor — otherwise
    /// a complete sentence like `已经完成了` would be filtered as noise.
    static let minCJKRunLength = 4
    static let maxDepth = 6
    /// Length-delimited fields visited per payload. Bounds the walk on a
    /// deeply nested or hostile blob.
    static let maxNodes = 4_000

    static func runs(in blob: Data) -> [String] {
        let bytes = [UInt8](blob)
        var out: [String] = []
        var seen: Set<String> = []
        var budget = maxNodes
        walk(bytes, range: bytes.startIndex..<bytes.endIndex, depth: 0,
             budget: &budget, out: &out, seen: &seen)
        return out
    }

    private static func walk(
        _ bytes: [UInt8],
        range: Range<Int>,
        depth: Int,
        budget: inout Int,
        out: inout [String],
        seen: inout Set<String>
    ) {
        var index = range.lowerBound
        while index < range.upperBound, budget > 0 {
            guard let key = readVarint(bytes, &index, range.upperBound), key != 0 else { return }
            switch key & 0x07 {
            case 0:
                guard readVarint(bytes, &index, range.upperBound) != nil else { return }
            case 1:
                guard index + 8 <= range.upperBound else { return }
                index += 8
            case 2:
                guard let length = readVarint(bytes, &index, range.upperBound),
                      length <= UInt64(range.upperBound - index)
                else { return }
                let end = index + Int(length)
                let payload = index..<end
                index = end
                budget -= 1
                if let text = String(bytes: bytes[payload], encoding: .utf8), isProse(text) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if seen.insert(trimmed).inserted { out.append(trimmed) }
                } else if depth < maxDepth, payload.count > 2 {
                    walk(bytes, range: payload, depth: depth + 1,
                         budget: &budget, out: &out, seen: &seen)
                }
            case 5:
                guard index + 4 <= range.upperBound else { return }
                index += 4
            default:
                return
            }
        }
    }

    private static func readVarint(_ bytes: [UInt8], _ index: inout Int, _ end: Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < end, shift < 64 {
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    /// True for a run that reads as something a person wrote or a model
    /// said. The tests pin the exact behavior; the rules, in order:
    ///
    /// - long enough to be content rather than a field name, and under
    ///   5% control bytes (a decoded-but-binary field usually trips this);
    /// - not a bare UUID, not a bare path, not a base64 / hash-shaped
    ///   token;
    /// - any CJK content passes — those scripts have no word spacing, so
    ///   the word-count rule below would reject real sentences;
    /// - otherwise at least two whitespace-separated words and at least
    ///   half the characters being letters, which is what separates
    ///   `Reading input JSON file` from `-3750763034362895579P`.
    static func isProse(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= minCJKRunLength else { return false }

        var controls = 0
        var letters = 0
        var hasCJK = false
        for character in text {
            if let scalar = character.unicodeScalars.first,
               scalar.value < 0x20, scalar != "\n", scalar != "\t", scalar != "\r" {
                controls += 1
            }
            if character.isLetter { letters += 1 }
            if !hasCJK, isCJK(character) { hasCJK = true }
        }
        guard text.count >= (hasCJK ? minCJKRunLength : minRunLength) else { return false }
        guard controls * 20 <= text.count else { return false }
        guard !isUUIDish(text), !isBarePath(text), !isTokenish(text) else { return false }
        if hasCJK { return true }

        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= 2 else { return false }
        return letters * 2 >= text.count
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF, // kana
             0x3400...0x4DBF, // CJK extension A
             0x4E00...0x9FFF, // CJK unified ideographs
             0xAC00...0xD7AF, // hangul
             0xF900...0xFAFF: // compatibility ideographs
            return true
        default:
            return false
        }
    }

    private static func isUUIDish(_ text: String) -> Bool {
        // Payload strings often arrive with a one-byte length prefix
        // still attached (`$e702954a-…`), so tolerate a short prefix.
        let candidate = text.count > 36 ? String(text.suffix(36)) : text
        return CodexSessionAdapter.isUUIDShaped(candidate)
    }

    private static func isBarePath(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace) else { return false }
        return text.hasPrefix("/") || text.hasPrefix("~/") || text.hasPrefix("file://")
    }

    private static func isTokenish(_ text: String) -> Bool {
        guard text.count >= 16, !text.contains(where: \.isWhitespace) else { return false }
        return text.unicodeScalars.allSatisfy { tokenCharacters.contains($0) }
    }

    private static let tokenCharacters = CharacterSet(charactersIn:
        "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ+/=_-."
    )
}
