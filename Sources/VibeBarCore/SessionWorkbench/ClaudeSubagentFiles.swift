import Foundation

/// Claude Code's subagent transcripts, which the session index never lists.
///
/// Claude writes a Task subagent's conversation beside the parent log, at
/// `<project>/<parent session id>/subagents/agent-<agent id>.jsonl`, with a
/// small `agent-<agent id>.meta.json` naming its type and the task it was
/// given. agent-session-kit indexes only the top-level logs, so the
/// Sessions page reaches these from the parent: from the subagent steps of
/// its structure (`Step.childSessionID` is the agent id) or by listing the
/// folder when a parent row is expanded.
///
/// Read-only, and only ever inside the parent log's own sibling folder.
public enum ClaudeSubagentFiles {
    /// `providerVariant` the synthetic summaries carry, so the host can tell
    /// a subagent transcript from an indexed session: it has no resume
    /// command and cannot be deleted on its own.
    public static let variant = "claude-subagent"

    public struct Entry: Sendable, Hashable {
        public var agentID: String
        public var path: String
        public var sizeBytes: Int64
        public var modifiedAt: Date?
        public var agentType: String?
        public var description: String?
    }

    /// `<dir>/<id>.jsonl` → `<dir>/<id>/subagents`. Nil when the parent is
    /// itself a subagent transcript or not a `.jsonl` log.
    public static func directory(forParentLog path: String) -> URL? {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension == "jsonl",
              url.deletingLastPathComponent().lastPathComponent != "subagents"
        else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty else { return nil }
        return url.deletingLastPathComponent()
            .appendingPathComponent(stem, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
    }

    /// The transcript of one agent, when the agent id is a plain file-name
    /// segment and the file exists.
    public static func path(agentID: String, parentLog path: String) -> String? {
        guard isSafeSegment(agentID), let directory = directory(forParentLog: path) else { return nil }
        let candidate = directory.appendingPathComponent("agent-\(agentID).jsonl").path
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    /// Every agent transcript beside `path`, newest first. Blocking: call it
    /// off the main actor.
    public static func list(parentLog path: String, limit: Int = 200) -> [Entry] {
        guard let directory = directory(forParentLog: path),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        var entries: [Entry] = []
        for name in names where name.hasPrefix("agent-") && name.hasSuffix(".jsonl") {
            let agentID = String(name.dropFirst("agent-".count).dropLast(".jsonl".count))
            guard isSafeSegment(agentID) else { continue }
            let file = directory.appendingPathComponent(name)
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            guard (attributes?[.type] as? FileAttributeType) == .typeRegular else { continue }
            let meta = readMeta(directory.appendingPathComponent("agent-\(agentID).meta.json"))
            entries.append(Entry(
                agentID: agentID,
                path: file.path,
                sizeBytes: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
                modifiedAt: attributes?[.modificationDate] as? Date,
                agentType: meta.agentType,
                description: meta.description
            ))
        }
        entries.sort { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        return Array(entries.prefix(max(0, limit)))
    }

    /// A summary the Workbench can open like any other session.
    public static func summary(for entry: Entry, parent: SessionSummary) -> SessionSummary {
        SessionSummary(
            provider: .claude,
            sessionID: entry.agentID,
            providerVariant: variant,
            harness: parent.effectiveHarness,
            model: nil,
            title: entry.description.flatMap { $0.isEmpty ? nil : $0 },
            summary: entry.agentType,
            projectDir: parent.projectDir,
            createdAt: nil,
            lastActiveAt: entry.modifiedAt,
            sourcePath: entry.path,
            sizeBytes: entry.sizeBytes
        )
    }

    /// The summary for one agent id, read from disk. Blocking.
    public static func summary(agentID: String, parent: SessionSummary) -> SessionSummary? {
        guard let path = path(agentID: agentID, parentLog: parent.sourcePath) else { return nil }
        let url = URL(fileURLWithPath: path)
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let meta = readMeta(url.deletingPathExtension().appendingPathExtension("meta.json"))
        return summary(
            for: Entry(
                agentID: agentID,
                path: path,
                sizeBytes: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
                modifiedAt: attributes?[.modificationDate] as? Date,
                agentType: meta.agentType,
                description: meta.description
            ),
            parent: parent
        )
    }

    public static func isSubagentSummary(_ summary: SessionSummary) -> Bool {
        summary.provider == .claude && summary.providerVariant == variant
    }

    static func isSafeSegment(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// `{"agentType": …, "description": …}` — the only fields read, and only
    /// from a small file.
    static func readMeta(_ url: URL) -> (agentType: String?, description: String?) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              ((attributes[.size] as? NSNumber)?.intValue ?? .max) <= 64 * 1024,
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, nil) }
        let type = (object["agentType"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let description = (object["description"] as? String).map {
            SessionStructureText.preview($0, limit: SessionStructure.Prompt.previewLimit)
        }
        return (type, description)
    }
}
