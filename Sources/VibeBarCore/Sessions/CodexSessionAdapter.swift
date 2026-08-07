import Foundation

/// Codex sessions: one JSONL rollout per thread under
/// `~/.codex/sessions/<yyyy>/<MM>/<dd>/rollout-<stamp>-<uuid>.jsonl`,
/// plus `~/.codex/archived_sessions`.
///
/// The rollout header (`session_meta`) carries the thread id and cwd,
/// but not the thread's display title — Codex keeps that in its own
/// state store, so titles are hydrated separately (see
/// `CodexTitleHydrator`) and the first user message is only the
/// fallback.
public struct CodexSessionAdapter: SessionProviderAdapter {
    public let provider: SessionProvider = .codex

    private let hydrator: CodexTitleHydrator

    public init(homeDirectory: String = RealHomeDirectory.path) {
        self.hydrator = CodexTitleHydrator(homeDirectory: homeDirectory)
    }

    public init(hydrator: CodexTitleHydrator) {
        self.hydrator = hydrator
    }

    public func roots(homeDirectory: String) -> [URL] {
        let home = URL(fileURLWithPath: homeDirectory)
        return [
            home.appendingPathComponent(".codex/sessions"),
            home.appendingPathComponent(".codex/archived_sessions")
        ]
    }

    public func discoverSessionFiles(homeDirectory: String) -> [URL] {
        roots(homeDirectory: homeDirectory).flatMap { root in
            SessionParsing.collectFiles(under: root) { $0.pathExtension == "jsonl" }
        }
    }

    // MARK: - Metadata

    public func extractMetadata(fileURL: URL) throws -> SessionSummary {
        let head = JSONLHeadTail.headLines(url: fileURL, count: 10).compactMap(SessionParsing.json)
        guard !head.isEmpty else {
            throw SessionParseError.unreadable(fileURL.lastPathComponent)
        }

        let meta = head.first { $0["type"] as? String == "session_meta" }?["payload"] as? [String: Any]
        let metaID = SessionParsing.firstString(meta?["id"], meta?["thread_id"])
        let filenameID = Self.trailingUUID(in: fileURL.deletingPathExtension().lastPathComponent)

        // A rollout whose filename disagrees with its own header is not
        // a rollout we understand — refuse rather than offer a delete
        // keyed on the wrong id.
        if let metaID, let filenameID, metaID.caseInsensitiveCompare(filenameID) != .orderedSame {
            throw SessionParseError.invalidFormat(
                "\(fileURL.lastPathComponent): session_meta id does not match filename"
            )
        }

        guard let sessionID = metaID ?? filenameID else {
            throw SessionParseError.invalidFormat("\(fileURL.lastPathComponent): no session id")
        }

        let tail = JSONLHeadTail.tailLines(url: fileURL, count: 30).compactMap(SessionParsing.json)
        let createdAt = SessionParsing.firstDate(
            head.first?["timestamp"],
            meta?["timestamp"]
        ) ?? SessionParsing.creationDate(fileURL)
        let lastActiveAt = tail.compactMap { SessionParsing.date($0["timestamp"]) }.last
            ?? SessionParsing.modificationDate(fileURL)

        let prompt = firstUserText(head)
        let hydrated = hydrator.thread(for: sessionID)

        return SessionSummary(
            provider: .codex,
            sessionID: sessionID,
            title: SessionParsing.display(hydrated?.title ?? prompt, limit: SessionParsing.titleLimit),
            summary: SessionParsing.display(prompt, limit: SessionParsing.summaryLimit),
            projectDir: SessionParsing.firstString(meta?["cwd"], hydrated?.cwd),
            createdAt: createdAt,
            lastActiveAt: lastActiveAt,
            sourcePath: fileURL.path,
            sizeBytes: SessionParsing.fileSize(fileURL),
            messageCount: JSONLHeadTail.lineCountIfSmall(url: fileURL) ?? SessionSummary.unknownMessageCount
        )
    }

    private func firstUserText(_ lines: [[String: Any]]) -> String? {
        for line in lines {
            guard line["type"] as? String == "response_item",
                  let payload = line["payload"] as? [String: Any],
                  payload["type"] as? String == "message",
                  payload["role"] as? String == "user"
            else { continue }
            let text = Self.strippingIDEEnvelope(SessionParsing.extractText(payload["content"]))
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// `rollout-2026-02-03T13-58-51-019c2215-0f3c-7f72-89e3-92598c209589`
    /// → the trailing UUID. Returns `nil` when the stem has no
    /// UUID-shaped suffix.
    static func trailingUUID(in stem: String) -> String? {
        guard stem.count >= 36 else { return nil }
        let candidate = String(stem.suffix(36))
        return isUUIDShaped(candidate) ? candidate : nil
    }

    static func isUUIDShaped(_ value: String) -> Bool {
        let groups = value.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 5,
              groups.map(\.count) == [8, 4, 4, 4, 12]
        else { return false }
        return value.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    /// The VS Code extension prefixes the first prompt with a block of
    /// editor context. The user's actual sentence follows the request
    /// marker, and that is what a title — or a transcript outline entry —
    /// should show.
    public static func strippingIDEEnvelope(_ text: String) -> String {
        guard text.contains(ideContextMarker),
              let marker = text.range(of: ideRequestMarker)
        else { return text }
        return String(text[marker.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let ideContextMarker = "# Context from my IDE setup:"
    static let ideRequestMarker = "## My request for Codex:"

    // MARK: - Transcript

    public func parseTranscript(fileURL: URL, range: Range<Int>?) throws -> TranscriptDocument {
        var messages: [SessionMessage] = []
        var seq = 0
        let didRead = CostUsageScanner.forEachJSONLLine(in: fileURL) { lineData in
            guard let obj = SessionParsing.json(lineData),
                  obj["type"] as? String == "response_item",
                  let payload = obj["payload"] as? [String: Any]
            else { return }

            let timestamp = SessionParsing.date(obj["timestamp"])
            let role: SessionRole
            let text: String
            switch payload["type"] as? String {
            case "message":
                role = ClaudeSessionAdapter.role(payload["role"] as? String)
                text = SessionParsing.extractText(payload["content"])
            case "function_call":
                role = .assistant
                let name = (payload["name"] as? String) ?? "tool"
                text = "[Tool: \(name)]"
            case "function_call_output":
                role = .tool
                text = SessionParsing.extractText(payload["output"])
            default:
                return
            }
            guard !text.isEmpty else { return }
            messages.append(SessionMessage(seq: seq, role: role, text: text, timestamp: timestamp))
            seq += 1
        }
        guard didRead else { throw SessionParseError.unreadable(fileURL.lastPathComponent) }
        return SessionTranscriptSlicing.document(messages: messages, range: range)
    }

    // MARK: - Deletion

    public func deletionPlan(for summary: SessionSummary, homeDirectory: String) throws -> SessionDeletionPlan {
        SessionDeletionPlan(
            provider: .codex,
            pathsToRemove: [summary.sourcePath],
            validationSourcePath: summary.sourcePath,
            expectedSessionID: summary.sessionID
        )
    }
}
