import Foundation

/// MiniMax Coding Plan usage adapter.
///
/// Auth: the `HERTZ-SESSION` cookie issued by MiniMax's web console.
/// Source resolution flows through `MiscCookieResolver` so users can
/// pick auto-import, manual paste, or off.
///
/// Endpoint:
/// `GET https://openplatform.minimax.io/v1/api/openplatform/coding_plan/remains`
/// returns the JSON shape codexbar's parser handles. Codexbar also
/// supports an HTML scraping fallback against the
/// `platform.minimax.io/user-center/payment/coding-plan` Next.js
/// page; this v1 port skips it because the JSON endpoint covers
/// the common case.
///
/// Output: a single QuotaBucket carrying the prompts-used / total
/// from the first `model_remains` entry.
public struct MiniMaxQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .minimax

    private let session: URLSession
    private let now: @Sendable () -> Date

    public static let cookieSpec = MiscCookieResolver.Spec(
        tool: .minimax,
        domains: [
            "platform.minimax.io",
            "openplatform.minimax.io",
            "minimax.io",
            "platform.minimaxi.com",
            "openplatform.minimaxi.com",
            "minimaxi.com"
        ],
        requiredNames: ["HERTZ-SESSION"]
    )

    private static let endpoint = URL(string:
        "https://openplatform.minimax.io/v1/api/openplatform/coding_plan/remains"
    )!

    public init(
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.now = now
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        guard let resolution = MiscCookieResolver.resolve(for: MiniMaxQuotaAdapter.cookieSpec) else {
            throw QuotaError.noCredential
        }

        var request = URLRequest(url: MiniMaxQuotaAdapter.endpoint)
        request.httpMethod = "GET"
        request.setValue(resolution.header, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://platform.minimax.io", forHTTPHeaderField: "Origin")
        request.setValue("https://platform.minimax.io/user-center/payment/coding-plan",
                         forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await self.session.data(for: request)
        } catch {
            throw QuotaError.network("MiniMax network error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("MiniMax: invalid response object")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                CookieHeaderCache.clear(for: .minimax)
                throw QuotaError.needsLogin
            }
            if http.statusCode == 429 {
                throw QuotaError.rateLimited
            }
            throw QuotaError.network("MiniMax returned HTTP \(http.statusCode).")
        }

        let snapshot = try MiniMaxResponseParser.parse(data: data, now: now())
        return AccountQuota(
            accountId: account.id,
            tool: .minimax,
            buckets: snapshot.buckets,
            plan: snapshot.planName,
            email: account.email,
            queriedAt: now(),
            error: nil
        )
    }
}

// MARK: - Response parsing

enum MiniMaxResponseParser {
    struct Snapshot {
        var buckets: [QuotaBucket]
        var planName: String?
    }

    static func parse(data: Data, now: Date) throws -> Snapshot {
        guard !data.isEmpty else {
            throw QuotaError.parseFailure("MiniMax returned an empty body.")
        }
        let response: MiniMaxAPIResponse
        do {
            response = try JSONDecoder().decode(MiniMaxAPIResponse.self, from: data)
        } catch {
            throw QuotaError.parseFailure("MiniMax response not parseable: \(error.localizedDescription)")
        }

        // Inspect both possible base_resp locations (root and inside data).
        let baseResp = response.baseResp ?? response.data?.baseResp
        if let status = baseResp?.statusCode, status != 0 {
            let message = baseResp?.statusMessage ?? "status_code \(status)"
            let lower = message.lowercased()
            if status == 1004 || lower.contains("cookie") || lower.contains("login") || lower.contains("log in") {
                throw QuotaError.needsLogin
            }
            throw QuotaError.network("MiniMax: \(message)")
        }

        guard let dataField = response.data,
              let first = dataField.modelRemains?.first else {
            throw QuotaError.parseFailure("MiniMax response had no model_remains rows.")
        }

        let total = first.currentIntervalTotalCount ?? 0
        let remaining = first.currentIntervalUsageCount ?? 0
        let used = max(0, total - remaining)
        let percent: Double
        if total > 0 {
            percent = max(0, min(100, Double(used) / Double(total) * 100))
        } else {
            percent = 0
        }

        let resetAt: Date? = {
            if let end = epochSeconds(first.endTime) {
                let endDate = Date(timeIntervalSince1970: end)
                if endDate > now { return endDate }
            }
            if let remains = first.remainsTime, remains > 0 {
                let seconds: TimeInterval = remains > 1_000_000 ? TimeInterval(remains) / 1000
                                                                : TimeInterval(remains)
                return now.addingTimeInterval(seconds)
            }
            return nil
        }()

        let windowSeconds: Int? = {
            if let start = epochSeconds(first.startTime),
               let end = epochSeconds(first.endTime),
               end > start {
                return Int(end - start)
            }
            return nil
        }()

        let bucket = QuotaBucket(
            id: "minimax.coding",
            title: "Prompts",
            shortLabel: "Prompts",
            usedPercent: percent,
            resetAt: resetAt,
            rawWindowSeconds: windowSeconds
        )

        let plan = dataField.currentSubscribeTitle?.trimmed
            ?? dataField.planName?.trimmed
            ?? dataField.currentPlanTitle?.trimmed
            ?? dataField.currentComboCard?.title?.trimmed
            ?? dataField.comboTitle?.trimmed

        return Snapshot(buckets: [bucket], planName: plan)
    }

    private static func epochSeconds(_ raw: Int?) -> TimeInterval? {
        guard let raw, raw > 0 else { return nil }
        if raw > 1_000_000_000_000 {
            return TimeInterval(raw) / 1000
        }
        if raw > 1_000_000_000 {
            return TimeInterval(raw)
        }
        return nil
    }
}

// MARK: - Wire types

private struct MiniMaxAPIResponse: Decodable {
    let baseResp: MiniMaxBaseResp?
    let data: MiniMaxDataField?

    enum CodingKeys: String, CodingKey {
        case baseResp = "base_resp"
        case data
    }
}

private struct MiniMaxBaseResp: Decodable {
    let statusCode: Int?
    let statusMessage: String?

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case statusMessage = "status_msg"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        statusCode = (try? c.decodeIfPresent(Int.self, forKey: .statusCode))
            ?? Int((try? c.decodeIfPresent(Double.self, forKey: .statusCode)) ?? 0)
        statusMessage = try c.decodeIfPresent(String.self, forKey: .statusMessage)
    }
}

private struct MiniMaxDataField: Decodable {
    let baseResp: MiniMaxBaseResp?
    let currentSubscribeTitle: String?
    let planName: String?
    let comboTitle: String?
    let currentPlanTitle: String?
    let currentComboCard: MiniMaxComboCard?
    let modelRemains: [MiniMaxModelRemains]?

    enum CodingKeys: String, CodingKey {
        case baseResp = "base_resp"
        case currentSubscribeTitle = "current_subscribe_title"
        case planName = "plan_name"
        case comboTitle = "combo_title"
        case currentPlanTitle = "current_plan_title"
        case currentComboCard = "current_combo_card"
        case modelRemains = "model_remains"
    }
}

private struct MiniMaxComboCard: Decodable {
    let title: String?
}

private struct MiniMaxModelRemains: Decodable {
    let currentIntervalTotalCount: Int?
    let currentIntervalUsageCount: Int?
    let startTime: Int?
    let endTime: Int?
    let remainsTime: Int?

    enum CodingKeys: String, CodingKey {
        case currentIntervalTotalCount = "current_interval_total_count"
        case currentIntervalUsageCount = "current_interval_usage_count"
        case startTime = "start_time"
        case endTime = "end_time"
        case remainsTime = "remains_time"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentIntervalTotalCount = MiniMaxQuotaDecoding.int(c, forKey: .currentIntervalTotalCount)
        currentIntervalUsageCount = MiniMaxQuotaDecoding.int(c, forKey: .currentIntervalUsageCount)
        startTime = MiniMaxQuotaDecoding.int(c, forKey: .startTime)
        endTime = MiniMaxQuotaDecoding.int(c, forKey: .endTime)
        remainsTime = MiniMaxQuotaDecoding.int(c, forKey: .remainsTime)
    }
}

private enum MiniMaxQuotaDecoding {
    static func int<K: CodingKey>(_ c: KeyedDecodingContainer<K>, forKey key: K) -> Int? {
        if let v = try? c.decodeIfPresent(Int.self, forKey: key) { return v }
        if let v = try? c.decodeIfPresent(Int64.self, forKey: key) { return Int(v) }
        if let v = try? c.decodeIfPresent(Double.self, forKey: key) { return Int(v) }
        if let v = try? c.decodeIfPresent(String.self, forKey: key),
           let n = Int(v.trimmingCharacters(in: .whitespacesAndNewlines)) { return n }
        return nil
    }
}

private extension String {
    var trimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
