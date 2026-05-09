import Foundation

/// MiniMax Token Plan usage adapter.
///
/// Auth: the Token Plan API key issued by MiniMax. This is separate
/// from regular pay-as-you-go API keys and is stored in
/// `MiscCredentialStore` under the API-key kind.
///
/// Endpoint:
/// `GET https://www.minimax.io/v1/token_plan/remains`
/// or the mainland China equivalent
/// `GET https://www.minimaxi.com/v1/token_plan/remains`.
///
/// Output: a single QuotaBucket carrying the prompts-used / total
/// from the preferred `model_remains` entry.
public struct MiniMaxQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .minimax

    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.now = now
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        let settings = MiscProviderSettings.current(for: .minimax)
        var lastError: QuotaError?
        let regions = MiniMaxRegion.resolve(settings: settings)

        guard let apiKey = MiscCredentialStore.readString(tool: .minimax, kind: .apiKey),
              !apiKey.isEmpty else {
            throw QuotaError.noCredential
        }

        for region in regions {
            do {
                let snapshot = try await fetchSnapshot(apiKey: apiKey, region: region)
                return AccountQuota(
                    accountId: account.id,
                    tool: .minimax,
                    buckets: snapshot.buckets,
                    plan: snapshot.planName,
                    email: account.email,
                    queriedAt: now(),
                    error: nil
                )
            } catch let error as QuotaError {
                if case .rateLimited = error { throw error }
                lastError = error
                continue
            } catch {
                lastError = .network("MiniMax network error: \(error.localizedDescription)")
                continue
            }
        }

        throw lastError ?? QuotaError.noCredential
    }

    private func fetchSnapshot(apiKey: String, region: MiniMaxRegion) async throws -> MiniMaxResponseParser.Snapshot {
        var lastError: QuotaError?
        for url in region.remainsURLs {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
                forHTTPHeaderField: "User-Agent"
            )
            do {
                return try await execute(request)
            } catch let error as QuotaError {
                if case .rateLimited = error { throw error }
                lastError = error
            } catch {
                lastError = .network("MiniMax network error: \(error.localizedDescription)")
            }
        }
        throw lastError ?? QuotaError.noCredential
    }

    private func execute(_ request: URLRequest) async throws -> MiniMaxResponseParser.Snapshot {
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
                throw QuotaError.needsLogin
            }
            if http.statusCode == 429 {
                throw QuotaError.rateLimited
            }
            throw QuotaError.network("MiniMax returned HTTP \(http.statusCode).")
        }

        return try MiniMaxResponseParser.parse(data: data, now: now())
    }
}

enum MiniMaxRegion: String, CaseIterable {
    case global
    case chinaMainland = "cn"

    static func resolve(settings: MiscProviderSettings) -> [MiniMaxRegion] {
        switch settings.region?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "global", "minimax", "platform.minimax.io", "www.minimax.io":
            return [.global, .chinaMainland]
        case "cn", "china", "china-mainland", "cn-beijing", "minimaxi", "platform.minimaxi.com", "www.minimaxi.com":
            return [.chinaMainland, .global]
        default:
            return [.global, .chinaMainland]
        }
    }

    var apiHost: URL {
        switch self {
        case .global:
            return URL(string: "https://www.minimax.io")!
        case .chinaMainland:
            return URL(string: "https://www.minimaxi.com")!
        }
    }

    var remainsURLs: [URL] {
        [
            apiHost.appendingPathComponent("v1/token_plan/remains"),
            apiHost.appendingPathComponent("v1/api/openplatform/coding_plan/remains")
        ]
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

        guard let dataField = response.payload,
              let first = preferredModelRemains(from: dataField.modelRemains) else {
            throw QuotaError.parseFailure("MiniMax response had no model_remains rows.")
        }

        // `current_interval_usage_count` is the number of prompts the
        // user has consumed in the current interval — NOT the number
        // remaining. The earlier port read it inverted, which made a
        // freshly-paid user (0 used) look 100 % consumed.
        let total = first.currentIntervalTotalCount ?? 0
        let used = max(0, first.currentIntervalUsageCount ?? 0)
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

    private static func preferredModelRemains(from rows: [MiniMaxModelRemains]?) -> MiniMaxModelRemains? {
        guard let rows, !rows.isEmpty else { return nil }
        if let chat = rows.first(where: { row in
            let name = row.modelName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return name.hasPrefix("minimax-m") && (row.currentIntervalTotalCount ?? 0) > 0
        }) {
            return chat
        }
        return rows.first { ($0.currentIntervalTotalCount ?? 0) > 0 } ?? rows.first
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
    let currentSubscribeTitle: String?
    let planName: String?
    let comboTitle: String?
    let currentPlanTitle: String?
    let currentComboCard: MiniMaxComboCard?
    let modelRemains: [MiniMaxModelRemains]?

    enum CodingKeys: String, CodingKey {
        case baseResp = "base_resp"
        case data
        case currentSubscribeTitle = "current_subscribe_title"
        case planName = "plan_name"
        case comboTitle = "combo_title"
        case currentPlanTitle = "current_plan_title"
        case currentComboCard = "current_combo_card"
        case modelRemains = "model_remains"
    }

    var payload: MiniMaxDataField? {
        if let data { return data }
        guard modelRemains != nil ||
              currentSubscribeTitle != nil ||
              planName != nil ||
              comboTitle != nil ||
              currentPlanTitle != nil ||
              currentComboCard != nil else {
            return nil
        }
        return MiniMaxDataField(
            baseResp: baseResp,
            currentSubscribeTitle: currentSubscribeTitle,
            planName: planName,
            comboTitle: comboTitle,
            currentPlanTitle: currentPlanTitle,
            currentComboCard: currentComboCard,
            modelRemains: modelRemains
        )
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

    init(
        baseResp: MiniMaxBaseResp?,
        currentSubscribeTitle: String?,
        planName: String?,
        comboTitle: String?,
        currentPlanTitle: String?,
        currentComboCard: MiniMaxComboCard?,
        modelRemains: [MiniMaxModelRemains]?
    ) {
        self.baseResp = baseResp
        self.currentSubscribeTitle = currentSubscribeTitle
        self.planName = planName
        self.comboTitle = comboTitle
        self.currentPlanTitle = currentPlanTitle
        self.currentComboCard = currentComboCard
        self.modelRemains = modelRemains
    }

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
    let modelName: String?
    let currentIntervalTotalCount: Int?
    let currentIntervalUsageCount: Int?
    let startTime: Int?
    let endTime: Int?
    let remainsTime: Int?

    enum CodingKeys: String, CodingKey {
        case modelName = "model_name"
        case currentIntervalTotalCount = "current_interval_total_count"
        case currentIntervalUsageCount = "current_interval_usage_count"
        case startTime = "start_time"
        case endTime = "end_time"
        case remainsTime = "remains_time"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelName = try? c.decodeIfPresent(String.self, forKey: .modelName)
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
