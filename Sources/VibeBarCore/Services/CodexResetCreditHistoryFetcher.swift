import Foundation

/// The used / received record behind Codex reset credits.
///
/// `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/history`
/// (optionally `?cursor=<next_cursor>`) is what ChatGPT's own usage page
/// reads. It covers the past 30 days:
///
/// ```
/// { "events": [ { "id": "…", "kind": "used" | "granted", "occurred_at": "…" }, … ],
///   "window_start": "…", "as_of": "…", "next_cursor": null }
/// ```
///
/// The credits endpoint (`CodexResetCreditsFetcher`) lists only credits that
/// are still available, so a spent credit is visible nowhere else — this is
/// the receipt that lets reset history call a cycle a credit reset. Event ids
/// are hashed before they leave the parser; nothing redeemable is kept.
///
/// Silent on every failure: `nil` means "no answer", never "no events".
public enum CodexResetCreditHistoryFetcher {
    public enum Auth: Sendable {
        case bearer(accessToken: String, accountId: String?)
        case cookie(header: String, accountId: String?)
    }

    public struct Page: Sendable, Equatable {
        public var used: [ResetCreditEvent]
        public var granted: [ResetCreditEvent]
        public var nextCursor: String?
    }

    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/history")!
    /// Thirty days of a handful of events fits one page; the bound only stops
    /// a cursor that never ends from turning a refresh into a crawl.
    static let maxPages = 5

    public static func fetch(auth: Auth, session: URLSession = .shared, now: Date = Date()) async -> Page? {
        var merged: Page?
        var cursor: String?
        var seenCursors: Set<String> = []
        for _ in 0..<maxPages {
            guard let page = await fetchPage(auth: auth, cursor: cursor, session: session, now: now) else { break }
            if merged == nil { merged = Page(used: [], granted: [], nextCursor: nil) }
            merged?.used += page.used
            merged?.granted += page.granted
            guard let next = page.nextCursor, seenCursors.insert(next).inserted else { break }
            cursor = next
        }
        return merged
    }

    static func request(auth: Auth, cursor: String?) -> URLRequest {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        if let cursor { components.queryItems = [URLQueryItem(name: "cursor", value: cursor)] }
        var request = URLRequest(url: components.url ?? endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12
        switch auth {
        case .bearer(let accessToken, let accountId):
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
            if let accountId, !accountId.isEmpty {
                request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
        case .cookie(let header, let accountId):
            request.setValue(header, forHTTPHeaderField: "Cookie")
            request.setValue("https://chatgpt.com/codex/settings/usage", forHTTPHeaderField: "Referer")
            if let accountId, !accountId.isEmpty {
                request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
        }
        return request
    }

    private static func fetchPage(auth: Auth, cursor: String?, session: URLSession, now: Date) async -> Page? {
        do {
            let (data, response) = try await session.data(for: request(auth: auth, cursor: cursor))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return parsePage(data: data, now: now)
        } catch {
            return nil
        }
    }

    /// One page of the payload. `nil` unless `events` is an array, so an
    /// error body is never read as "nothing happened".
    public static func parsePage(data: Data, now: Date = Date()) -> Page? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else { return nil }
        var used: [ResetCreditEvent] = []
        var granted: [ResetCreditEvent] = []
        // A clock a minute ahead of ours is the server's, not a future event.
        let latest = now.addingTimeInterval(300)
        for row in events {
            guard let id = row["id"] as? String, !id.isEmpty,
                  let kind = (row["kind"] as? String)?.lowercased(),
                  let date = parseDate(row["occurred_at"]), date <= latest else { continue }
            let event = ResetCreditEvent(
                id: PrivacyPreservingHash.fileComponent(prefix: "reset-credit", rawValue: id), occurredAt: date)
            switch kind {
            case "used": used.append(event)
            case "granted": granted.append(event)
            default: continue
            }
        }
        let cursor = (root["next_cursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Page(used: used.sorted { $0.occurredAt < $1.occurredAt },
                    granted: granted.sorted { $0.occurredAt < $1.occurredAt },
                    nextCursor: cursor)
    }

    /// Folds a history page into the credits snapshot. A receipt the
    /// credits endpoint already carried (same instant) is not doubled.
    public static func merge(_ page: Page, into credits: ResetCredits) -> ResetCredits {
        var merged = credits
        var redemptions = credits.redemptions ?? []
        for event in page.used where !redemptions.contains(where: {
            abs($0.occurredAt.timeIntervalSince(event.occurredAt)) < 2
        }) {
            redemptions.append(event)
        }
        merged.redemptions = redemptions.sorted { $0.occurredAt < $1.occurredAt }
        merged.grants = page.granted
        return merged
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ raw: Any?) -> Date? {
        guard let s = raw as? String else { return nil }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }
}

/// Decides when a Codex refresh also reads the reset-credit history, so the
/// record costs a request only when something could have changed.
///
/// A read happens on the first refresh of each account in a process, when the
/// available count moves, when any window refills (the moment a spent credit
/// shows), and otherwise at most every `maxAge`. A receipt the server
/// publishes after the refill is picked up by the next read and reconciled
/// onto the cycle it belongs to by `SubscriptionHistoryStore`.
public actor CodexResetCreditHistoryGate {
    public static let shared = CodexResetCreditHistoryGate()

    struct State: Equatable {
        var lastAttemptAt: Date?
        var availableCount: Int?
        var usedPercents: [String: Double]
    }

    static let maxAge: TimeInterval = 6 * 3_600
    /// After a failed read, try again sooner than `maxAge`, but not every tick.
    static let retryAfterFailure: TimeInterval = 30 * 60
    /// A drop this large in any window reads as a refill.
    static let refillDrop = 10.0

    private var states: [String: State] = [:]

    public init() {}

    /// Records this refresh's observation and answers whether to read.
    public func shouldFetch(accountKey: String, availableCount: Int?, buckets: [QuotaBucket],
                            now: Date = Date()) -> Bool {
        let used = Dictionary(buckets.map { ($0.id, $0.usedPercent) }, uniquingKeysWith: { max($0, $1) })
        let previous = states[accountKey]
        let fetch = Self.needsFetch(previous: previous, availableCount: availableCount, usedPercents: used, now: now)
        states[accountKey] = State(lastAttemptAt: fetch ? now : previous?.lastAttemptAt,
                                   availableCount: availableCount ?? previous?.availableCount,
                                   usedPercents: used)
        return fetch
    }

    /// A failed read is retried after `retryAfterFailure` instead of `maxAge`.
    public func recordFailure(accountKey: String, now: Date = Date()) {
        states[accountKey]?.lastAttemptAt = now.addingTimeInterval(Self.retryAfterFailure - Self.maxAge)
    }

    static func needsFetch(previous: State?, availableCount: Int?, usedPercents: [String: Double],
                           now: Date) -> Bool {
        guard let previous, let last = previous.lastAttemptAt else { return true }
        if let availableCount, let before = previous.availableCount, availableCount != before { return true }
        for (id, value) in usedPercents {
            if let before = previous.usedPercents[id], before - value >= refillDrop { return true }
        }
        return now.timeIntervalSince(last) >= maxAge
    }
}
