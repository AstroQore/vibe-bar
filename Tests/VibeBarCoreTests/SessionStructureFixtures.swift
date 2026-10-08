import Foundation
@testable import VibeBarCore

/// Synthetic session logs for the structure-parser tests. Every id, path
/// and text here is made up; nothing is copied from a real session.
enum SessionStructureFixtures {
    static let codexThreadID = "0190aaaa-0000-7000-8000-000000000001"
    static let codexParentID = "0190aaaa-0000-7000-8000-0000000000ff"
    static let codexRootID = "0190aaaa-0000-7000-8000-0000000000aa"
    static let claudeSessionID = "11111111-2222-4333-8444-555555555555"
    static let claudeParentSessionID = "99999999-8888-4777-8666-555555555555"

    static func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarStructure-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func jsonLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    /// One JSON value (object, array, string, number) as text.
    static func jsonValue(_ value: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys, .fragmentsAllowed])
        let array = String(data: data, encoding: .utf8)!
        return String(array.dropFirst().dropLast())
    }

    @discardableResult
    static func write(_ lines: [String], to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func stamp(_ second: Int) -> String {
        let minute = second / 60
        return String(format: "2026-05-01T10:%02d:%02d.000Z", minute % 60, second % 60)
    }
}

// MARK: - Codex rollout builder

/// Builds a rollout line by line, numbering `ordinal`s the way current
/// Codex does. Field names and nesting follow the shapes observed in local
/// rollouts; values are synthetic.
final class CodexRolloutBuilder {
    private(set) var lines: [String] = []
    private var ordinal = 0
    private var clock = 0
    private var cumulative = (input: 0, cached: 0, output: 0)
    var includeOrdinals = true

    /// Emits keys in Codex's own order — `timestamp`, `ordinal`, `type`,
    /// `payload` (whose `type` comes first) — because the parser's head
    /// sniffing for oversized lines relies on it.
    private func emit(_ type: String, _ payload: [String: Any], extra: [String: Any] = [:]) {
        var parts = ["\"timestamp\":\"\(SessionStructureFixtures.stamp(clock))\""]
        if includeOrdinals { parts.append("\"ordinal\":\(ordinal)") }
        parts.append("\"type\":\"\(type)\"")
        var payloadParts: [String] = []
        if let payloadType = payload["type"] as? String { payloadParts.append("\"type\":\"\(payloadType)\"") }
        for key in payload.keys.sorted() where key != "type" {
            payloadParts.append("\"\(key)\":" + SessionStructureFixtures.jsonValue(payload[key]!))
        }
        parts.append("\"payload\":{" + payloadParts.joined(separator: ",") + "}")
        for key in extra.keys.sorted() {
            parts.append("\"\(key)\":" + SessionStructureFixtures.jsonValue(extra[key]!))
        }
        lines.append("{" + parts.joined(separator: ",") + "}")
        ordinal += 1
        clock += 1
    }

    @discardableResult
    func meta(
        id: String = SessionStructureFixtures.codexThreadID,
        sessionID: String? = nil,
        parentThreadID: String? = nil,
        forkedFrom: String? = nil,
        source: Any = "cli",
        threadSource: String? = "user",
        historyStart: Int? = nil,
        gitBranch: String? = nil
    ) -> Self {
        var payload: [String: Any] = [
            "id": id,
            "session_id": sessionID ?? id,
            "timestamp": SessionStructureFixtures.stamp(0),
            "cwd": "/Users/example/project",
            "originator": "codex_cli_rs",
            "cli_version": "0.150.0",
            "source": source
        ]
        if let threadSource { payload["thread_source"] = threadSource }
        if let parentThreadID { payload["parent_thread_id"] = parentThreadID }
        if let forkedFrom { payload["forked_from_id"] = forkedFrom }
        if let historyStart { payload["subagent_history_start_ordinal"] = historyStart }
        if let gitBranch { payload["git"] = ["branch": gitBranch, "commit_hash": "abc123"] }
        emit("session_meta", payload)
        return self
    }

    @discardableResult
    func taskStarted(_ turnID: String) -> Self {
        emit("event_msg", ["type": "task_started", "turn_id": turnID, "started_at": 1_777_000_000 + clock])
        return self
    }

    @discardableResult
    func taskComplete(_ turnID: String, durationMs: Int = 4_000, lastMessage: String? = nil) -> Self {
        var payload: [String: Any] = ["type": "task_complete", "turn_id": turnID, "duration_ms": durationMs,
                                      "completed_at": 1_777_000_000 + clock]
        if let lastMessage { payload["last_agent_message"] = lastMessage }
        emit("event_msg", payload)
        return self
    }

    @discardableResult
    func turnContext(model: String, turnID: String = "t") -> Self {
        emit("turn_context", ["model": model, "turn_id": turnID, "effort": "medium", "approval_policy": "on-request"])
        return self
    }

    @discardableResult
    func developer(_ text: String = "<permissions>sandboxed</permissions>") -> Self {
        emit("response_item", ["type": "message", "role": "developer", "content": [["type": "input_text", "text": text]]])
        return self
    }

    @discardableResult
    func userResponseItem(_ text: String, metadata: [String: Any]? = nil) -> Self {
        var extra: [String: Any] = [:]
        if let metadata { extra["metadata"] = metadata }
        emit("response_item", ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]], extra: extra)
        return self
    }

    @discardableResult
    func userMessageItem(_ text: String, turnID: String = "t") -> Self {
        emit("event_msg", [
            "type": "item_completed", "turn_id": turnID, "thread_id": SessionStructureFixtures.codexThreadID,
            "item": ["type": "UserMessage", "id": "um", "content": [["type": "text", "text": text, "text_elements": []]]]
        ])
        return self
    }

    /// The pair current Codex writes for one typed prompt.
    @discardableResult
    func prompt(_ text: String, turnID: String = "t") -> Self {
        userResponseItem(text)
        return userMessageItem(text, turnID: turnID)
    }

    @discardableResult
    func assistant(_ text: String) -> Self {
        emit("response_item", ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]])
        return self
    }

    @discardableResult
    func reasoning(id: String, summary: String) -> Self {
        emit("response_item", ["type": "reasoning", "id": id, "summary": [["type": "summary_text", "text": summary]],
                               "encrypted_content": "gAAAAsynthetic"])
        return self
    }

    @discardableResult
    func reasoningCompleted(id: String, durationMs: Int) -> Self {
        emit("event_msg", ["type": "item_completed", "started_at_ms": 1_000, "completed_at_ms": 1_000 + durationMs,
                           "item": ["type": "Reasoning", "id": id, "summary_text": [], "raw_content": []]])
        return self
    }

    @discardableResult
    func functionCall(_ name: String, callID: String, arguments: [String: Any]) -> Self {
        let args = String(data: try! JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]), encoding: .utf8)!
        emit("response_item", ["type": "function_call", "name": name, "arguments": args, "call_id": callID])
        return self
    }

    @discardableResult
    func customToolCall(_ name: String, callID: String, input: String) -> Self {
        emit("response_item", ["type": "custom_tool_call", "name": name, "input": input, "call_id": callID, "status": "completed"])
        return self
    }

    @discardableResult
    func output(callID: String, text: String, custom: Bool = false) -> Self {
        emit("response_item", ["type": custom ? "custom_tool_call_output" : "function_call_output",
                               "call_id": callID, "output": [["type": "input_text", "text": text]]])
        return self
    }

    @discardableResult
    func stringOutput(callID: String, text: String, custom: Bool = false) -> Self {
        emit("response_item", ["type": custom ? "custom_tool_call_output" : "function_call_output",
                               "call_id": callID, "output": text])
        return self
    }

    @discardableResult
    func commandExecution(id: String, command: [String], exitCode: Int, seconds: Int = 0, nanos: Int = 250_000_000) -> Self {
        emit("event_msg", ["type": "item_completed", "item": [
            "type": "CommandExecution", "id": id, "command": command, "exit_code": exitCode,
            "status": exitCode == 0 ? "completed" : "failed", "duration": ["secs": seconds, "nanos": nanos],
            "aggregated_output": "synthetic output", "source": "unified_exec_startup", "cwd": "/Users/example/project"
        ]])
        return self
    }

    @discardableResult
    func mcpToolCall(id: String, server: String, tool: String, failed: Bool) -> Self {
        emit("event_msg", ["type": "item_completed", "item": [
            "type": "McpToolCall", "id": id, "server": server, "tool": tool,
            "status": failed ? "failed" : "completed", "arguments": ["title": "Open page"],
            "duration": ["secs": 1, "nanos": 0], "result": ["isError": failed, "content": []]
        ]])
        return self
    }

    /// Cumulative counter; pass the per-request increment.
    @discardableResult
    func tokenCount(input: Int, cached: Int, output: Int) -> Self {
        cumulative = (cumulative.input + input, cumulative.cached + cached, cumulative.output + output)
        let total: [String: Any] = [
            "input_tokens": cumulative.input, "cached_input_tokens": cumulative.cached,
            "cache_write_input_tokens": 0, "output_tokens": cumulative.output, "reasoning_output_tokens": 0,
            "total_tokens": cumulative.input + cumulative.output
        ]
        let last: [String: Any] = [
            "input_tokens": input, "cached_input_tokens": cached, "cache_write_input_tokens": 0,
            "output_tokens": output, "reasoning_output_tokens": 0, "total_tokens": input + output
        ]
        emit("event_msg", ["type": "token_count", "info": ["total_token_usage": total, "last_token_usage": last,
                                                            "model_context_window": 272_000]])
        return self
    }

    /// The newer per-response record, which repeats the cumulative counter.
    @discardableResult
    func tokenUsageRecord() -> Self {
        let total: [String: Any] = [
            "input_tokens": cumulative.input, "cached_input_tokens": cumulative.cached,
            "cache_write_input_tokens": 0, "output_tokens": cumulative.output, "reasoning_output_tokens": 0,
            "total_tokens": cumulative.input + cumulative.output
        ]
        emit("token_usage_record", ["thread_token_usage": total, "turn_token_usage": total, "usage": total])
        return self
    }

    @discardableResult
    func raw(_ line: String) -> Self {
        lines.append(line)
        return self
    }

    var ordinalNow: Int { ordinal }
}

// MARK: - Claude log builder

final class ClaudeLogBuilder {
    private(set) var lines: [String] = []
    private var clock = 0
    private var counter = 0
    var sessionID = SessionStructureFixtures.claudeSessionID
    private(set) var lastUUID: String?

    func nextUUID() -> String {
        counter += 1
        return String(format: "00000000-0000-4000-8000-%012d", counter)
    }

    @discardableResult
    func line(_ object: [String: Any], parent: String?? = .none, chain: Bool = true) -> String {
        var object = object
        let uuid = nextUUID()
        object["uuid"] = uuid
        object["sessionId"] = object["sessionId"] ?? sessionID
        object["timestamp"] = SessionStructureFixtures.stamp(clock)
        object["cwd"] = "/Users/example/project"
        object["gitBranch"] = "feature/structure"
        object["version"] = "2.1.0"
        object["isSidechain"] = object["isSidechain"] ?? false
        switch parent {
        case .none: object["parentUuid"] = lastUUID as Any? ?? NSNull()
        case .some(let explicit): object["parentUuid"] = explicit as Any? ?? NSNull()
        }
        lines.append(SessionStructureFixtures.jsonLine(object))
        clock += 2
        if chain { lastUUID = uuid }
        return uuid
    }

    @discardableResult
    func prompt(_ text: String, parent: String?? = .none, extra: [String: Any] = [:]) -> String {
        var object: [String: Any] = ["type": "user", "message": ["role": "user", "content": text], "origin": ["kind": "human"]]
        for (key, value) in extra { object[key] = value }
        return line(object, parent: parent)
    }

    @discardableResult
    func assistant(
        messageID: String,
        requestID: String = "req_synthetic",
        model: String = "claude-sonnet-4-5",
        blocks: [[String: Any]],
        usage: [String: Int]? = ["input_tokens": 10, "cache_creation_input_tokens": 100,
                                 "cache_read_input_tokens": 1_000, "output_tokens": 50],
        stopReason: String? = nil,
        extra: [String: Any] = [:]
    ) -> String {
        var message: [String: Any] = ["id": messageID, "role": "assistant", "type": "message", "model": model, "content": blocks]
        if let usage { message["usage"] = usage }
        if let stopReason { message["stop_reason"] = stopReason }
        var object: [String: Any] = ["type": "assistant", "message": message, "requestId": requestID]
        for (key, value) in extra { object[key] = value }
        return line(object)
    }

    @discardableResult
    func toolResult(id: String, content: String, isError: Bool = false, toolUseResult: [String: Any]? = nil, extra: [String: Any] = [:]) -> String {
        var object: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": content, "is_error": isError]]]
        ]
        if let toolUseResult { object["toolUseResult"] = toolUseResult }
        for (key, value) in extra { object[key] = value }
        return line(object)
    }

    @discardableResult
    func raw(_ text: String) -> Self {
        lines.append(text)
        return self
    }
}
