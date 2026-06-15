import Foundation

/// Fetches per-turn token usage for an AntiGravity *cascade*
/// (conversation) from the locally-running language server.
///
/// Used by `CostUsageScanner` for the conversations whose only on-disk
/// form is the encrypted `.pb` container we can't decode offline —
/// unlike the `.db` SQLite blobs, which `AntigravitySessionReader`
/// reads directly. Mirrors codeburn's approach: the `.pb`/`.db` files
/// only yield the cascade id (their `<UUID>` filename); the
/// authoritative token numbers come from a ConnectRPC call to
/// `GetCascadeTrajectoryGeneratorMetadata` on the running server.
///
/// Results are cached by the scanner (keyed on the `.pb` file
/// fingerprint), so a cascade fetched once while Antigravity is running
/// keeps showing up after it quits.
enum AntigravityCascadeUsageFetcher {
    static let methodPath =
        "/exa.language_server_pb.LanguageServerService/GetCascadeTrajectoryGeneratorMetadata"

    /// One model turn pulled from the RPC response. `output` already
    /// folds the thinking tokens in (Gemini / Claude bill reasoning at
    /// the output rate), matching the `.db` decode path. The RPC does
    /// not expose cache tokens, so the scanner records `cache = 0`.
    struct Turn: Equatable {
        let date: Date?
        let model: String?
        let input: Int
        let output: Int
        let responseId: String?
    }

    /// POST the cascade id to the running server (trying each candidate
    /// endpoint) and parse the turns out of the response. Throws on
    /// transport / parse failure so the scanner can fall back to its
    /// cache.
    static func fetchTurns(
        cascadeId: String,
        client: AntigravityLanguageServerClient,
        endpoints: [AntigravityLanguageServerClient.Endpoint]
    ) async throws -> [Turn] {
        let body = try JSONSerialization.data(withJSONObject: ["cascadeId": cascadeId])
        var lastError: Error?
        for endpoint in endpoints {
            do {
                let data = try await client.postLocal(endpoint: endpoint, path: methodPath, body: body)
                return parse(data: data)
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? QuotaError.network("Antigravity cascade RPC unreachable.")
    }

    // MARK: - Parsing
    //
    // The response is ConnectRPC JSON. The exact envelope key for the
    // metadata array isn't documented, so the parser is deliberately
    // lenient: it unwraps common wrappers, then takes the first
    // array-of-objects whose elements look like generator metadata
    // (carry `chatModel` / `usage`). Every field read is optional —
    // a short or renamed payload yields fewer turns, never a throw.
    // int64 fields arrive as JSON strings, so token values are parsed
    // from strings as well as numbers.

    static func parse(data: Data) -> [Turn] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let entries = extractMetadataEntries(root)
        var turns: [Turn] = []
        var seenResponseIds: Set<String> = []
        for entry in entries {
            let chatModel = (entry["chatModel"] as? [String: Any])
                ?? (entry["chat_model"] as? [String: Any])
            let usage = (chatModel?["usage"] as? [String: Any])
                ?? (entry["usage"] as? [String: Any])
            guard let usage else { continue }

            let input = asInt(usage["inputTokens"] ?? usage["input_tokens"]) ?? 0
            let thinking = asInt(usage["thinkingOutputTokens"] ?? usage["thinking_output_tokens"]) ?? 0
            let output: Int
            if let response = asInt(usage["responseOutputTokens"] ?? usage["response_output_tokens"]) {
                // Response + thinking are both billed at the output rate.
                output = response + thinking
            } else {
                // No response/thinking split — `outputTokens` already is
                // the full output for the turn.
                output = asInt(usage["outputTokens"] ?? usage["output_tokens"]) ?? 0
            }
            guard input > 0 || output > 0 else { continue }

            let responseId = (usage["responseId"] as? String) ?? (usage["response_id"] as? String)
            if let responseId, !responseId.isEmpty {
                if seenResponseIds.contains(responseId) { continue }
                seenResponseIds.insert(responseId)
            }

            let model = normalized(usage["model"] as? String) ?? normalized(chatModel?["model"] as? String)
            let date = startDate(from: chatModel)

            turns.append(Turn(date: date, model: model, input: input, output: output, responseId: responseId))
        }
        return turns
    }

    /// Locate the array of generator-metadata objects inside an
    /// arbitrary decoded JSON value.
    static func extractMetadataEntries(_ node: Any) -> [[String: Any]] {
        if let arr = node as? [[String: Any]] {
            return arr
        }
        guard let dict = node as? [String: Any] else { return [] }

        for key in ["generatorMetadata", "generator_metadata", "trajectoryGeneratorMetadata", "metadata"] {
            if let arr = dict[key] as? [[String: Any]] { return arr }
        }
        for key in ["response", "result", "data"] {
            if let inner = dict[key] {
                let nested = extractMetadataEntries(inner)
                if !nested.isEmpty { return nested }
            }
        }
        // Last resort: first array-of-objects that looks like metadata.
        for value in dict.values {
            if let arr = value as? [[String: Any]],
               arr.contains(where: { $0["chatModel"] != nil || $0["chat_model"] != nil || $0["usage"] != nil }) {
                return arr
            }
        }
        return []
    }

    private static func startDate(from chatModel: [String: Any]?) -> Date? {
        let meta = (chatModel?["chatStartMetadata"] as? [String: Any])
            ?? (chatModel?["chat_start_metadata"] as? [String: Any])
        guard let raw = (meta?["createdAt"] as? String) ?? (meta?["created_at"] as? String) else {
            return nil
        }
        return parseDate(raw)
    }

    private static func asInt(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if let i = Int(trimmed) { return i }
            if let d = Double(trimmed) { return Int(d) }
        }
        return nil
    }

    private static func normalized(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func parseDate(_ raw: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: raw) { return d }
        if let seconds = Double(raw) { return Date(timeIntervalSince1970: seconds) }
        return nil
    }
}
