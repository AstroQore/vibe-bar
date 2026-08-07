import Foundation

/// Claude Code sessions: one JSONL rollout per conversation under
/// `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl`, with
/// `~/.config/claude/projects` as the alternate root some installs use.
///
/// A rollout may have a sibling directory named after its stem holding
/// `subagents/agent-*.jsonl`. Those sidecar files are not sessions in
/// their own right — they are excluded from discovery and removed
/// together with their parent.
public struct ClaudeSessionAdapter: SessionProviderAdapter {
    public let provider: SessionProvider = .claude

    public init() {}

    public func roots(homeDirectory: String) -> [URL] {
        let home = URL(fileURLWithPath: homeDirectory)
        return [
            home.appendingPathComponent(".claude/projects"),
            home.appendingPathComponent(".config/claude/projects")
        ]
    }

    public func discoverSessionFiles(homeDirectory: String) -> [URL] {
        roots(homeDirectory: homeDirectory).flatMap { root in
            SessionParsing.collectFiles(under: root) { url in
                url.pathExtension == "jsonl"
                    && !url.lastPathComponent.hasPrefix(Self.subagentFilePrefix)
            }
        }
    }

    static let subagentFilePrefix = "agent-"

    // MARK: - Metadata

    public func extractMetadata(fileURL: URL) throws -> SessionSummary {
        let head = JSONLHeadTail.headLines(url: fileURL, count: 10).compactMap(SessionParsing.json)
        let tail = JSONLHeadTail.tailLines(url: fileURL, count: 30).compactMap(SessionParsing.json)
        guard !head.isEmpty || !tail.isEmpty else {
            throw SessionParseError.unreadable(fileURL.lastPathComponent)
        }

        let stem = fileURL.deletingPathExtension().lastPathComponent
        let sessionID = SessionParsing.firstString(
            head.compactMap { $0["sessionId"] }.first,
            tail.compactMap { $0["sessionId"] }.first
        ) ?? stem

        let projectDir = SessionParsing.firstString(
            head.compactMap { $0["cwd"] }.first,
            tail.compactMap { $0["cwd"] }.first
        )

        let createdAt = head.compactMap { SessionParsing.date($0["timestamp"]) }.first
        let lastActiveAt = tail.compactMap { SessionParsing.date($0["timestamp"]) }.last
            ?? SessionParsing.modificationDate(fileURL)

        return SessionSummary(
            provider: .claude,
            sessionID: sessionID,
            title: title(head: head, tail: tail, projectDir: projectDir),
            summary: SessionParsing.display(lastMessageText(tail), limit: SessionParsing.summaryLimit),
            projectDir: projectDir,
            createdAt: createdAt,
            lastActiveAt: lastActiveAt,
            sourcePath: fileURL.path,
            sizeBytes: SessionParsing.fileSize(fileURL),
            // Counting means reading the file. Worth it while it is
            // cheap; a sentinel otherwise, because a session list must
            // not walk gigabytes of transcripts to render.
            messageCount: JSONLHeadTail.lineCountIfSmall(url: fileURL) ?? SessionSummary.unknownMessageCount
        )
    }

    /// Pinned title first (`/title` writes a `custom-title` line at the
    /// end of the file), then the first genuine user prompt, then the
    /// project folder name.
    private func title(head: [[String: Any]], tail: [[String: Any]], projectDir: String?) -> String? {
        if let custom = tail.last(where: { $0["type"] as? String == "custom-title" }),
           let value = SessionParsing.display(SessionParsing.string(custom["customTitle"]),
                                              limit: SessionParsing.titleLimit) {
            return value
        }
        if let prompt = firstRealUserText(head),
           let value = SessionParsing.display(prompt, limit: SessionParsing.titleLimit) {
            return value
        }
        guard let projectDir else { return nil }
        let name = URL(fileURLWithPath: projectDir).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// Slash commands, hook output, and the "local commands" caveat
    /// preamble all land in the file as `user` entries. None of them is
    /// something the user typed as a prompt.
    private func firstRealUserText(_ lines: [[String: Any]]) -> String? {
        for line in lines {
            guard line["type"] as? String == "user",
                  !SessionParsing.bool(line["isMeta"]),
                  let message = line["message"] as? [String: Any]
            else { continue }
            let text = SessionParsing.extractText(message["content"])
            guard !text.isEmpty, !Self.isEnvelopeText(text) else { continue }
            return text
        }
        return nil
    }

    static func isEnvelopeText(_ text: String) -> Bool {
        for marker in envelopeMarkers where text.contains(marker) {
            return true
        }
        return false
    }

    private static let envelopeMarkers = [
        "<command-name>",
        "<local-command-stdout>",
        "<local-command-stderr>",
        "Caveat: The messages below were generated by the user while running local commands"
    ]

    private func lastMessageText(_ tail: [[String: Any]]) -> String? {
        for line in tail.reversed() {
            guard !SessionParsing.bool(line["isMeta"]),
                  let message = line["message"] as? [String: Any]
            else { continue }
            let text = SessionParsing.extractText(message["content"])
            if !text.isEmpty { return text }
        }
        return nil
    }

    // MARK: - Transcript

    public func parseTranscript(fileURL: URL, range: Range<Int>?) throws -> TranscriptDocument {
        var messages: [SessionMessage] = []
        var seq = 0
        let didRead = CostUsageScanner.forEachJSONLLine(in: fileURL) { lineData in
            guard let obj = SessionParsing.json(lineData),
                  !SessionParsing.bool(obj["isMeta"]),
                  let message = obj["message"] as? [String: Any]
            else { return }

            let content = message["content"]
            let text = SessionParsing.extractText(content)
            guard !text.isEmpty else { return }

            var role = Self.role(message["role"] as? String ?? obj["type"] as? String)
            if role == .user, SessionParsing.isAllToolResults(content) {
                role = .tool
            }
            messages.append(SessionMessage(
                seq: seq,
                role: role,
                text: text,
                timestamp: SessionParsing.date(obj["timestamp"])
            ))
            seq += 1
        }
        guard didRead else { throw SessionParseError.unreadable(fileURL.lastPathComponent) }
        return SessionTranscriptSlicing.document(messages: messages, range: range)
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

    // MARK: - Deletion

    public func deletionPlan(for summary: SessionSummary, homeDirectory: String) throws -> SessionDeletionPlan {
        let fileURL = URL(fileURLWithPath: summary.sourcePath)
        var paths = [fileURL.path]
        let sidecar = fileURL.deletingPathExtension()
        if SessionParsing.isDirectory(sidecar) {
            paths.append(sidecar.path)
        }
        return SessionDeletionPlan(
            provider: .claude,
            pathsToRemove: paths,
            validationSourcePath: fileURL.path,
            expectedSessionID: summary.sessionID
        )
    }
}

/// Shared `range` handling so every adapter reports `truncated` and
/// `totalMessageCount` the same way.
enum SessionTranscriptSlicing {
    static func document(messages: [SessionMessage], range: Range<Int>?) -> TranscriptDocument {
        let total = messages.count
        guard let range else {
            return TranscriptDocument(messages: messages, totalMessageCount: total, truncated: false)
        }
        let lower = max(0, range.lowerBound)
        let upper = min(total, max(lower, range.upperBound))
        let slice = Array(messages[lower..<upper])
        return TranscriptDocument(
            messages: slice,
            totalMessageCount: total,
            truncated: slice.count != total
        )
    }
}
