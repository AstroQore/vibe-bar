import Foundation

/// Grok sessions: a directory per conversation at
/// `~/.grok/sessions/<percent-encoded cwd>/<session-id>/`, holding
/// `summary.json`, `chat_history.jsonl`, and assorted state files.
/// `~/.grok/archived_sessions` mirrors the layout.
///
/// The session's unit on disk is the directory, so that is also the
/// deletion unit — but only after both the summary's own id and the
/// directory's name agree on which session it is.
public struct GrokSessionAdapter: SessionProviderAdapter {
    public let provider: SessionProvider = .grok

    public init() {}

    public func roots(homeDirectory: String) -> [URL] {
        let home = URL(fileURLWithPath: homeDirectory)
        return [
            home.appendingPathComponent(".grok/sessions"),
            home.appendingPathComponent(".grok/archived_sessions")
        ]
    }

    public func discoverSessionFiles(homeDirectory: String) -> [URL] {
        roots(homeDirectory: homeDirectory).flatMap { root in
            SessionParsing.collectFiles(under: root) { $0.lastPathComponent == Self.summaryFileName }
        }
    }

    static let summaryFileName = "summary.json"
    static let chatHistoryFileName = "chat_history.jsonl"

    // MARK: - Metadata

    public func extractMetadata(fileURL: URL) throws -> SessionSummary {
        guard let root = SessionParsing.jsonObject(at: fileURL) else {
            throw SessionParseError.unreadable(fileURL.path)
        }
        let info = root["info"] as? [String: Any]
        guard let sessionID = SessionParsing.firstString(
            info?["id"], root["id"], root["session_id"], info?["session_id"]
        ) else {
            throw SessionParseError.invalidFormat("\(fileURL.path): no session id")
        }

        let sessionDir = fileURL.deletingLastPathComponent()
        guard sessionDir.lastPathComponent == sessionID else {
            throw SessionParseError.invalidFormat(
                "\(fileURL.path): parent directory is not named after the session id"
            )
        }

        // The cwd is encoded into the grandparent directory name; the
        // `info` object only sometimes repeats it.
        let encodedCwd = sessionDir.deletingLastPathComponent().lastPathComponent
        let projectDir = SessionParsing.firstString(
            encodedCwd.removingPercentEncoding,
            info?["cwd"],
            root["cwd"]
        )

        let title = SessionParsing.firstString(
            root["generated_title"], root["title"], info?["title"], info?["name"]
        )
        let summaryText = SessionParsing.firstString(
            root["session_summary"], root["summary"], info?["summary"]
        )

        return SessionSummary(
            provider: .grok,
            sessionID: sessionID,
            harness: .grokBuild,
            model: SessionParsing.firstString(
                root["current_model_id"], info?["current_model_id"], root["model"]
            ),
            title: SessionParsing.display(title ?? summaryText, limit: SessionParsing.titleLimit),
            summary: SessionParsing.display(summaryText, limit: SessionParsing.summaryLimit),
            projectDir: projectDir,
            createdAt: SessionParsing.firstDate(root["created_at"], info?["created_at"]),
            lastActiveAt: SessionParsing.firstDate(
                root["last_active_at"], root["updated_at"], info?["updated_at"]
            ) ?? SessionParsing.modificationDate(fileURL),
            sourcePath: fileURL.path,
            // Deleting a Grok session removes the directory, so the
            // size a user is shown should be the directory's.
            sizeBytes: SessionParsing.directorySize(sessionDir),
            messageCount: SessionParsing.int(root["num_chat_messages"])
                ?? SessionParsing.int(root["num_messages"])
                ?? SessionSummary.unknownMessageCount
        )
    }

    // MARK: - Transcript

    public func parseTranscript(fileURL: URL, range: Range<Int>?) throws -> TranscriptDocument {
        let history = fileURL.deletingLastPathComponent()
            .appendingPathComponent(Self.chatHistoryFileName)
        guard FileManager.default.fileExists(atPath: history.path) else {
            return .empty
        }

        var messages: [SessionMessage] = []
        var seq = 0
        let didRead = CostUsageScanner.forEachJSONLLine(in: history) { lineData in
            guard let obj = SessionParsing.json(lineData),
                  let role = Self.role(obj["type"] as? String)
            else { return }
            let text = SessionParsing.firstNonEmptyText(
                obj["content"], obj["text"], obj["message"]
            )
            guard !text.isEmpty else { return }
            messages.append(SessionMessage(
                seq: seq,
                role: role,
                text: text,
                timestamp: SessionParsing.firstDate(obj["timestamp"], obj["created_at"])
            ))
            seq += 1
        }
        guard didRead else { throw SessionParseError.unreadable(history.path) }
        return SessionTranscriptSlicing.document(messages: messages, range: range)
    }

    /// Reasoning traces, rewind markers, and backend bookkeeping lines
    /// share the file with the conversation; only the four transcript
    /// roles survive. `tool_result` is the shape the current CLI
    /// writes, `tool` the one older builds did.
    static func role(_ raw: String?) -> SessionRole? {
        switch raw {
        case "system": return .system
        case "user": return .user
        case "assistant": return .assistant
        case "tool", "tool_result": return .tool
        default: return nil
        }
    }

    // MARK: - Deletion

    public func deletionPlan(for summary: SessionSummary, homeDirectory: String) throws -> SessionDeletionPlan {
        let fileURL = URL(fileURLWithPath: summary.sourcePath)
        guard fileURL.lastPathComponent == Self.summaryFileName else {
            throw SessionParseError.invalidFormat("\(summary.sourcePath): not a Grok session summary")
        }
        let sessionDir = fileURL.deletingLastPathComponent()
        guard sessionDir.lastPathComponent == summary.sessionID else {
            throw SessionParseError.invalidFormat(
                "\(summary.sourcePath): parent directory is not named after the session id"
            )
        }
        return SessionDeletionPlan(
            provider: .grok,
            pathsToRemove: [sessionDir.path],
            validationSourcePath: fileURL.path,
            expectedSessionID: summary.sessionID
        )
    }
}
