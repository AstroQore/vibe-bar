import Foundation

/// Gemini CLI sessions: one whole-file JSON document per conversation at
/// `~/.gemini/tmp/<project-hash>/chats/session-<stamp>.json`.
///
/// The project hash is opaque; the CLI drops the real working directory
/// in a sibling `.project_root` file, which is the only way to show a
/// user which checkout a session belongs to.
public struct GeminiSessionAdapter: SessionProviderAdapter {
    public let provider: SessionProvider = .gemini

    public init() {}

    public func roots(homeDirectory: String) -> [URL] {
        [URL(fileURLWithPath: homeDirectory).appendingPathComponent(".gemini/tmp")]
    }

    public func discoverSessionFiles(homeDirectory: String) -> [URL] {
        guard let root = roots(homeDirectory: homeDirectory).first,
              let projects = try? FileManager.default.contentsOfDirectory(atPath: root.path)
        else { return [] }

        var out: [URL] = []
        for project in projects {
            let chats = root.appendingPathComponent(project, isDirectory: true)
                .appendingPathComponent("chats", isDirectory: true)
            out.append(contentsOf: SessionParsing.collectFiles(under: chats) { url in
                url.pathExtension == "json" && url.lastPathComponent.hasPrefix("session-")
            })
        }
        return out.sorted { $0.path < $1.path }
    }

    static let projectRootFileName = ".project_root"

    // MARK: - Metadata

    public func extractMetadata(fileURL: URL) throws -> SessionSummary {
        guard let root = SessionParsing.jsonObject(at: fileURL) else {
            throw SessionParseError.unreadable(fileURL.path)
        }
        let messages = (root["messages"] as? [[String: Any]]) ?? []
        let sessionID = SessionParsing.firstString(root["sessionId"], root["session_id"])
            ?? fileURL.deletingPathExtension().lastPathComponent

        let timestamps = messages.compactMap { SessionParsing.date($0["timestamp"]) }
        let createdAt = SessionParsing.firstDate(root["startTime"], root["start_time"])
            ?? timestamps.first
            ?? SessionParsing.creationDate(fileURL)
        let lastActiveAt = SessionParsing.firstDate(root["lastUpdated"], root["last_updated"])
            ?? timestamps.last
            ?? SessionParsing.modificationDate(fileURL)

        let firstUser = messages.first { Self.role($0) == .user }
        // Trailing turns can be empty (a tool-only round, an aborted
        // response); the summary should show the last turn that says
        // something.
        let last = messages.last { !Self.text($0).isEmpty }

        return SessionSummary(
            provider: .gemini,
            sessionID: sessionID,
            harness: .geminiCLI,
            model: Self.model(in: messages) ?? SessionParsing.firstString(root["model"]),
            title: SessionParsing.display(Self.text(firstUser), limit: SessionParsing.titleLimit),
            summary: SessionParsing.display(Self.text(last), limit: SessionParsing.summaryLimit),
            projectDir: projectRoot(for: fileURL),
            createdAt: createdAt,
            lastActiveAt: lastActiveAt,
            sourcePath: fileURL.path,
            sizeBytes: SessionParsing.fileSize(fileURL),
            messageCount: messages.count
        )
    }

    /// `~/.gemini/tmp/<hash>/.project_root` holds the checkout path the
    /// hash was derived from.
    private func projectRoot(for fileURL: URL) -> String? {
        let projectDir = fileURL.deletingLastPathComponent().deletingLastPathComponent()
        let marker = projectDir.appendingPathComponent(Self.projectRootFileName)
        guard let raw = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        return SessionParsing.string(raw)
    }

    // MARK: - Transcript

    public func parseTranscript(fileURL: URL, range: Range<Int>?) throws -> TranscriptDocument {
        guard let root = SessionParsing.jsonObject(at: fileURL) else {
            throw SessionParseError.unreadable(fileURL.path)
        }
        let raw = (root["messages"] as? [[String: Any]]) ?? []
        var messages: [SessionMessage] = []
        for entry in raw {
            let text = Self.text(entry)
            guard !text.isEmpty else { continue }
            messages.append(SessionMessage(
                seq: messages.count,
                role: Self.role(entry),
                text: text,
                timestamp: SessionParsing.date(entry["timestamp"])
            ))
        }
        return SessionTranscriptSlicing.document(messages: messages, range: range)
    }

    /// Gemini labels its own turns `gemini` and keeps `role` only on
    /// some vintages, so both fields are consulted.
    static func role(_ entry: [String: Any]?) -> SessionRole {
        guard let entry else { return .other }
        let raw = SessionParsing.firstString(entry["type"], entry["role"])
        switch raw {
        case "user": return .user
        case "gemini", "assistant", "model": return .assistant
        case "tool", "tool_result", "function": return .tool
        case "system": return .system
        default: return .other
        }
    }

    /// Newer Gemini CLI vintages stamp the model on each turn; older ones
    /// write no model at all, and the session then simply has none. The whole
    /// document is already in memory here, so this costs nothing extra.
    static func model(in messages: [[String: Any]]) -> String? {
        for entry in messages {
            if let model = SessionParsing.firstString(
                entry["model"], entry["modelName"], entry["model_name"]
            ) {
                return model
            }
        }
        return nil
    }

    static func text(_ entry: [String: Any]?) -> String {
        guard let entry else { return "" }
        return SessionParsing.firstNonEmptyText(entry["content"], entry["text"], entry["parts"])
    }

    // MARK: - Deletion

    public func deletionPlan(for summary: SessionSummary, homeDirectory: String) throws -> SessionDeletionPlan {
        SessionDeletionPlan(
            provider: .gemini,
            pathsToRemove: [summary.sourcePath],
            validationSourcePath: summary.sourcePath,
            expectedSessionID: summary.sessionID
        )
    }
}
