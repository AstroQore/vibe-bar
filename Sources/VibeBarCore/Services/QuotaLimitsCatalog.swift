import Foundation
import os

/// Published per-plan quota limits that no provider reports itself, kept in
/// a public repository so a changed allowance reaches every install without
/// an app release: `AstroQore/vibebar-quota-limits`, `limits.json` (its
/// `schema.json` sits beside it).
///
/// Today it carries the ChatGPT Chat Pro-model allowances. The table in
/// `ChatGPTChatProAllowances.bundled(plan:)` stays in the binary as the
/// floor: it answers until a valid remote table has been fetched, and for
/// any plan the remote table has no usable rows for.
///
/// Refresh is best-effort and off the quota path. The pricing loop calls
/// `refresh()` on its own cadence; a validated document is written to
/// `~/.vibebar/quota_limits.json` as the last good copy and swapped into an
/// in-memory snapshot. Quota reads only ever consult that snapshot, which is
/// loaded from the cache file once, on first use. A failed or invalid fetch
/// leaves both the cache and the snapshot as they were.
public enum QuotaLimitsCatalog {
    public static let remoteURL = URL(
        string: "https://raw.githubusercontent.com/AstroQore/vibebar-quota-limits/main/limits.json"
    )!
    /// The document is a few kilobytes; anything near this is not it.
    public static let maxFetchBytes = 256 * 1024
    public static let defaultRequestTimeout: TimeInterval = 15
    public static let supportedSchemaVersion = 1
    /// More rows than any provider's plans could need is a broken document.
    static let maxRows = 256

    /// The validated table: ChatGPT Chat allowances by normalized plan.
    public struct Table: Sendable, Equatable {
        public let updatedAt: String?
        public let chatGPTChat: [String: [ChatGPTChatProAllowance]]
        public var rowCount: Int { chatGPTChat.values.reduce(0) { $0 + $1.count } }

        public init(updatedAt: String?, chatGPTChat: [String: [ChatGPTChatProAllowance]]) {
            self.updatedAt = updatedAt
            self.chatGPTChat = chatGPTChat
        }
    }

    public enum Outcome: String, Codable, Sendable, Equatable {
        case fetched
        case unchanged
        case networkFailure
        case invalidDocument
        case oversized
    }

    public struct Status: Codable, Sendable, Equatable {
        public var lastAttemptAt: Date?
        public var lastSuccessAt: Date?
        public var outcome: Outcome?
        public var rowCount: Int?
        public var updatedAt: String?
    }

    // MARK: - Parsing

    /// A document this build can use, or nil. A wrong schema version or a
    /// missing allowance list rejects the whole document; a row for an
    /// unknown provider, or one with any malformed field, is skipped alone.
    public static func parse(_ data: Data) -> Table? {
        guard !data.isEmpty, data.count <= maxFetchBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              ChatGPTChatParser.integer(root["schemaVersion"]) == supportedSchemaVersion,
              let rows = root["allowances"] as? [Any], rows.count <= maxRows else { return nil }
        var plans: [String: [ChatGPTChatProAllowance]] = [:]
        for case let row as [String: Any] in rows {
            guard row["provider"] as? String == "chatgptChat",
                  let plan = normalizedPlan(row["plan"] as? String),
                  let allowance = chatGPTChatAllowance(row),
                  !(plans[plan]?.contains { $0.id == allowance.id } ?? false) else { continue }
            plans[plan, default: []].append(allowance)
        }
        return Table(updatedAt: root["updatedAt"] as? String, chatGPTChat: plans)
    }

    private static func chatGPTChatAllowance(_ row: [String: Any]) -> ChatGPTChatProAllowance? {
        guard let id = row["id"] as? String,
              id.range(of: "^[a-z0-9_]{1,64}$", options: .regularExpression) != nil,
              let group = label(row["group"]), let title = label(row["title"]),
              let slugs = row["models"] as? [Any], !slugs.isEmpty, slugs.count <= 32,
              let limit = ChatGPTChatParser.integer(row["limit"]), limit > 0,
              let window = ChatGPTChatParser.integer(row["windowSeconds"]), window >= 3_600,
              window <= 366 * 86_400,
              (row["unit"] as? String ?? "messages") == "messages" else { return nil }
        var models: Set<String> = []
        for slug in slugs {
            guard let slug = slug as? String, ChatGPTChatParser.validModel(slug) else { return nil }
            models.insert(slug)
        }
        return ChatGPTChatProAllowance(id: id, group: group, title: title, models: models,
                                       limit: limit, windowSeconds: window)
    }

    private static func label(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= 64 else { return nil }
        return text
    }

    static func normalizedPlan(_ plan: String?) -> String? {
        guard let plan = plan?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !plan.isEmpty else { return nil }
        return plan
    }

    // MARK: - Snapshot

    private struct State {
        var loaded = false
        var table: Table?
    }
    private static let state = OSAllocatedUnfairLock<State>(initialState: State())

    /// The table quota reads resolve against: the last good document,
    /// read from the cache file the first time it is asked for and kept in
    /// memory after that.
    public static func snapshot(homeDirectory: String = RealHomeDirectory.path) -> Table? {
        if let loaded = state.withLock({ $0.loaded ? Optional($0.table) : nil }) { return loaded }
        let table = loadCache(homeDirectory: homeDirectory)
        return state.withLock { state in
            if !state.loaded { state.loaded = true; state.table = table }
            return state.table
        }
    }

    /// Tests only: forget the in-memory snapshot so the next read reloads.
    static func resetSnapshot(to table: Table? = nil, loaded: Bool = false) {
        state.withLock { $0 = State(loaded: loaded, table: table) }
    }

    public static func loadCache(homeDirectory: String = RealHomeDirectory.path) -> Table? {
        let url = cacheURL(homeDirectory: homeDirectory)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue, size > 0, size <= maxFetchBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    public static func cacheURL(homeDirectory: String = RealHomeDirectory.path) -> URL {
        VibeBarLocalStore.baseDirectory(homeDirectory: homeDirectory).appendingPathComponent("quota_limits.json")
    }

    static func statusURL(homeDirectory: String) -> URL {
        VibeBarLocalStore.baseDirectory(homeDirectory: homeDirectory).appendingPathComponent("quota_limits_status.json")
    }

    public static func loadStatus(homeDirectory: String = RealHomeDirectory.path) -> Status {
        (try? VibeBarLocalStore.readJSON(Status.self, from: statusURL(homeDirectory: homeDirectory))) ?? Status()
    }

    // MARK: - Refresh

    /// Fetch, validate and adopt the published table. Never throws; a
    /// failure keeps the last good table.
    @discardableResult
    public static func refresh(
        homeDirectory: String = RealHomeDirectory.path,
        session: URLSession = .shared,
        endpoint: URL = Self.remoteURL,
        requestTimeout: TimeInterval = Self.defaultRequestTimeout,
        now: Date = Date()
    ) async -> Outcome {
        let result = await fetchAndStore(homeDirectory: homeDirectory, session: session,
                                         endpoint: endpoint, timeout: requestTimeout)
        var status = loadStatus(homeDirectory: homeDirectory)
        status.lastAttemptAt = now
        status.outcome = result.outcome
        if let table = result.table {
            state.withLock { $0 = State(loaded: true, table: table) }
            status.lastSuccessAt = now
            status.rowCount = table.rowCount
            status.updatedAt = table.updatedAt
        }
        try? VibeBarLocalStore.writeJSON(status, to: statusURL(homeDirectory: homeDirectory),
                                         base: VibeBarLocalStore.baseDirectory(homeDirectory: homeDirectory))
        return result.outcome
    }

    private static func fetchAndStore(homeDirectory: String, session: URLSession, endpoint: URL,
                                      timeout: TimeInterval) async -> (outcome: Outcome, table: Table?) {
        guard endpoint.scheme?.lowercased() == "https" else { return (.networkFailure, nil) }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("VibeBar/quota-limits", forHTTPHeaderField: "User-Agent")
        let data: Data
        do {
            let (body, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return (.networkFailure, nil) }
            data = body
        } catch {
            SafeLog.warn("QuotaLimitsCatalog network: \(SafeLog.sanitize(error.localizedDescription))")
            return (.networkFailure, nil)
        }
        guard !data.isEmpty, data.count <= maxFetchBytes else { return (.oversized, nil) }
        guard let table = parse(data) else {
            SafeLog.warn("QuotaLimitsCatalog: the published document is not usable")
            return (.invalidDocument, nil)
        }
        let url = cacheURL(homeDirectory: homeDirectory)
        if let cached = try? Data(contentsOf: url), cached == data { return (.unchanged, table) }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
        } catch {
            // Still adopt it for this session; the cache keeps the last copy it could write.
            SafeLog.warn("QuotaLimitsCatalog cache write: \(SafeLog.sanitize(error.localizedDescription))")
        }
        return (.fetched, table)
    }
}
