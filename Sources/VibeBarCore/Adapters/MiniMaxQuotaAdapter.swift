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
/// Env overrides match Codex Bar's latest reader:
/// `MINIMAX_CODING_API_KEY`, `MINIMAX_API_KEY`, `MINIMAX_HOST`,
/// `MINIMAX_CODING_PLAN_URL`, and `MINIMAX_REMAINS_URL`.
///
/// Output: QuotaBuckets for every usable `model_remains` row, plus a
/// weekly bucket when the API includes weekly quota fields.
public struct MiniMaxQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .minimax

    private let session: URLSession
    private let environment: [String: String]
    private let now: @Sendable () -> Date

    public init(
        session: URLSession = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.environment = environment
        self.now = now
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        let settings = MiscProviderSettings.current(for: .minimax)
        var lastError: QuotaError?
        let regions = MiniMaxRegion.resolve(settings: settings)

        guard settings.allowsAPIOrOAuthAccess,
              let apiKey = MiniMaxSettings.resolveAPIKey(environment: environment),
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
        for url in region.remainsURLs(environment: environment) {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("VibeBar", forHTTPHeaderField: "MM-API-Source")
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
        case "global", "minimax", "platform.minimax.io", "www.minimax.io", "api.minimax.io":
            return [.global, .chinaMainland]
        case "cn", "china", "china-mainland", "cn-beijing", "minimaxi", "platform.minimaxi.com", "www.minimaxi.com", "api.minimaxi.com":
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

    var openPlatformAPIHost: URL {
        switch self {
        case .global:
            return URL(string: "https://api.minimax.io")!
        case .chinaMainland:
            return URL(string: "https://api.minimaxi.com")!
        }
    }

    var remainsURLs: [URL] {
        remainsURLs(environment: [:])
    }

    func remainsURLs(environment: [String: String]) -> [URL] {
        var urls: [URL] = []
        for key in ["MINIMAX_REMAINS_URL", "MINIMAX_CODING_PLAN_URL"] {
            if let url = Self.fullURL(from: environment[key]) {
                urls.append(url)
            }
        }
        if let hostURL = Self.hostOverrideURL(from: environment["MINIMAX_HOST"]) {
            urls.append(hostURL.appendingPathComponent("v1/api/openplatform/coding_plan/remains"))
        }
        urls.append(contentsOf: [
            apiHost.appendingPathComponent("v1/token_plan/remains"),
            openPlatformAPIHost.appendingPathComponent("v1/api/openplatform/coding_plan/remains"),
            apiHost.appendingPathComponent("v1/api/openplatform/coding_plan/remains")
        ])
        return Self.deduplicated(urls)
    }

    private static func fullURL(from raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              url.scheme != nil else {
            return nil
        }
        return url
    }

    private static func hostOverrideURL(from raw: String?) -> URL? {
        guard var raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        if !raw.contains("://") { raw = "https://\(raw)" }
        return URL(string: raw)
    }

    private static func deduplicated(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }
}

private enum MiniMaxSettings {
    static func resolveAPIKey(environment: [String: String]) -> String? {
        if let stored = MiscCredentialStore.readString(tool: .minimax, kind: .apiKey),
           !stored.isEmpty {
            return stored
        }
        for key in ["MINIMAX_CODING_API_KEY", "MINIMAX_API_KEY"] {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
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

        guard let dataField = response.payload else {
            throw QuotaError.parseFailure("MiniMax response had no data payload.")
        }

        let plan = dataField.currentSubscribeTitle?.trimmed
            ?? dataField.planName?.trimmed
            ?? dataField.currentPlanTitle?.trimmed
            ?? dataField.currentComboCard?.title?.trimmed
            ?? dataField.comboTitle?.trimmed

        let serviceBuckets = makeServiceBuckets(from: dataField.services, now: now)
        if !serviceBuckets.isEmpty {
            return Snapshot(buckets: serviceBuckets, planName: plan)
        }

        let modelBuckets = makeModelRemainBuckets(from: dataField.modelRemains, now: now)
        if !modelBuckets.isEmpty {
            return Snapshot(buckets: modelBuckets, planName: plan)
        }

        guard let first = preferredModelRemains(from: dataField.modelRemains) else {
            throw QuotaError.parseFailure("MiniMax response had no model_remains rows.")
        }

        var buckets: [QuotaBucket] = []
        buckets.append(modelBucket(from: first, now: now))
        if let weekly = weeklyBucket(from: first, now: now) {
            buckets.append(weekly)
        }

        return Snapshot(buckets: buckets, planName: plan)
    }

    private static func makeModelRemainBuckets(from rows: [MiniMaxModelRemains]?, now: Date) -> [QuotaBucket] {
        guard let rows else { return [] }
        var buckets: [QuotaBucket] = []
        var addedWeekly = false
        for (index, row) in rows.enumerated() {
            guard (row.currentIntervalTotalCount ?? 0) > 0 else { continue }
            buckets.append(modelBucket(from: row, index: index, now: now))
            if !addedWeekly, let weekly = weeklyBucket(from: row, now: now) {
                buckets.append(weekly)
                addedWeekly = true
            }
        }
        return buckets
    }

    private static func modelBucket(from row: MiniMaxModelRemains, index: Int = 0, now: Date) -> QuotaBucket {
        let total = row.currentIntervalTotalCount ?? 0
        let used = max(0, row.currentIntervalUsageCount ?? 0)
        let remaining = max(0, total - used)
        let windowLabel = windowLabel(startTime: row.startTime, endTime: row.endTime) ?? "5 hours"
        let title = serviceTitle(for: row.modelName) ?? "5 Hours"
        return quotaBucket(
            id: "minimax.coding.\(index).\(slug(row.modelName ?? title))",
            title: title,
            shortLabel: "5h",
            used: used,
            total: total,
            percent: nil,
            startTime: row.startTime,
            endTime: row.endTime,
            remainsTime: row.remainsTime,
            windowSeconds: 5 * 3600,
            now: now,
            groupTitle: "\(remaining)/\(total) · \(windowLabel)"
        )
    }

    private static func weeklyBucket(from row: MiniMaxModelRemains, now: Date) -> QuotaBucket? {
        guard (row.currentWeeklyTotalCount ?? 0) > 0 else { return nil }
        let total = row.currentWeeklyTotalCount ?? 0
        let used = max(0, row.currentWeeklyUsageCount ?? 0)
        let remaining = max(0, total - used)
        return quotaBucket(
            id: "minimax.weekly",
            title: "Weekly",
            shortLabel: "Wk",
            used: used,
            total: total,
            percent: nil,
            startTime: row.weeklyStartTime,
            endTime: row.weeklyEndTime,
            remainsTime: row.weeklyRemainsTime,
            windowSeconds: 7 * 86_400,
            now: now,
            groupTitle: "\(remaining)/\(total) · Weekly"
        )
    }

    private static func makeServiceBuckets(from services: [MiniMaxServiceUsage]?, now: Date) -> [QuotaBucket] {
        guard let services else { return [] }
        return services.compactMap { service in
            let identity = service.bucketIdentity
            let total = service.limit ?? service.total
            let used = service.usage ?? service.used
            guard total != nil || service.percent != nil else { return nil }
            return quotaBucket(
                id: identity.id,
                title: identity.title,
                shortLabel: identity.shortLabel,
                used: used ?? 0,
                total: total ?? 0,
                percent: service.percent,
                startTime: service.startTime,
                endTime: service.endTime,
                remainsTime: service.remainsTime,
                windowSeconds: identity.windowSeconds,
                now: now,
                groupTitle: total.map { total in "\(max(0, total - (used ?? 0)))/\(total) left" }
            )
        }
    }

    private static func quotaBucket(
        id: String,
        title: String,
        shortLabel: String,
        used: Int,
        total: Int,
        percent: Double?,
        startTime: Int?,
        endTime: Int?,
        remainsTime: Int?,
        windowSeconds: Int?,
        now: Date,
        groupTitle: String? = nil
    ) -> QuotaBucket {
        let usedPercent: Double
        if let percent {
            usedPercent = percent <= 1 ? percent * 100 : percent
        } else if total > 0 {
            usedPercent = Double(max(0, used)) / Double(total) * 100
        } else {
            usedPercent = 0
        }
        return QuotaBucket(
            id: id,
            title: title,
            shortLabel: shortLabel,
            usedPercent: max(0, min(100, usedPercent)),
            resetAt: resetDate(endTime: endTime, remainsTime: remainsTime, now: now),
            rawWindowSeconds: windowSeconds ?? inferredWindowSeconds(startTime: startTime, endTime: endTime),
            groupTitle: groupTitle
        )
    }

    private static func resetDate(endTime: Int?, remainsTime: Int?, now: Date) -> Date? {
        if let end = epochSeconds(endTime) {
            let endDate = Date(timeIntervalSince1970: end)
            if endDate > now { return endDate }
        }
        if let remains = remainsTime, remains > 0 {
            let seconds: TimeInterval = remains > 1_000_000 ? TimeInterval(remains) / 1000
                                                            : TimeInterval(remains)
            return now.addingTimeInterval(seconds)
        }
        return nil
    }

    private static func inferredWindowSeconds(startTime: Int?, endTime: Int?) -> Int? {
        guard let start = epochSeconds(startTime),
              let end = epochSeconds(endTime),
              end > start else {
            return nil
        }
        return Int(end - start)
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

    private static func windowLabel(startTime: Int?, endTime: Int?) -> String? {
        guard let start = epochSeconds(startTime),
              let end = epochSeconds(endTime),
              end > start else {
            return nil
        }
        let hours = Int(((end - start) / 3600).rounded())
        if (4...6).contains(hours) { return "5 hours" }
        if (23...25).contains(hours) { return "Today" }
        return hours > 0 ? "\(hours) hours" : nil
    }

    private static func serviceTitle(for modelName: String?) -> String? {
        guard let modelName = modelName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modelName.isEmpty else {
            return nil
        }
        let lower = modelName.lowercased()
        if lower.contains("minimax-m") { return "Text Generation" }
        if lower.contains("speech") { return "Text to Speech" }
        if lower.contains("hailuo"), lower.contains("fast") { return "Image to Video" }
        if lower.contains("hailuo") { return "Text to Video" }
        if lower.hasPrefix("image-") { return "Image Generation" }
        if lower.contains("music") { return "Music Generation" }
        return formattedModelName(modelName)
    }

    private static func formattedModelName(_ modelName: String) -> String {
        let words = modelName
            .replacingOccurrences(of: #"[_-]+"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .map { word -> String in
                let lower = word.lowercased()
                if ["api", "vlm", "ylm", "tts", "hd", "mimo"].contains(lower) {
                    return lower.uppercased()
                }
                return lower.prefix(1).uppercased() + String(lower.dropFirst())
            }
        return words.joined(separator: " ")
    }

    private static func slug(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let replaced = lowered.replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
        let trimmed = replaced.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "bucket" : trimmed
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
    let services: [MiniMaxServiceUsage]?

    enum CodingKeys: String, CodingKey {
        case baseResp = "base_resp"
        case data
        case currentSubscribeTitle = "current_subscribe_title"
        case planName = "plan_name"
        case comboTitle = "combo_title"
        case currentPlanTitle = "current_plan_title"
        case currentComboCard = "current_combo_card"
        case modelRemains = "model_remains"
        case services
    }

    var payload: MiniMaxDataField? {
        if let data { return data }
        guard modelRemains != nil ||
              services != nil ||
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
            modelRemains: modelRemains,
            services: services
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
    let services: [MiniMaxServiceUsage]?

    init(
        baseResp: MiniMaxBaseResp?,
        currentSubscribeTitle: String?,
        planName: String?,
        comboTitle: String?,
        currentPlanTitle: String?,
        currentComboCard: MiniMaxComboCard?,
        modelRemains: [MiniMaxModelRemains]?,
        services: [MiniMaxServiceUsage]?
    ) {
        self.baseResp = baseResp
        self.currentSubscribeTitle = currentSubscribeTitle
        self.planName = planName
        self.comboTitle = comboTitle
        self.currentPlanTitle = currentPlanTitle
        self.currentComboCard = currentComboCard
        self.modelRemains = modelRemains
        self.services = services
    }

    enum CodingKeys: String, CodingKey {
        case baseResp = "base_resp"
        case currentSubscribeTitle = "current_subscribe_title"
        case planName = "plan_name"
        case comboTitle = "combo_title"
        case currentPlanTitle = "current_plan_title"
        case currentComboCard = "current_combo_card"
        case modelRemains = "model_remains"
        case services
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
    let currentWeeklyTotalCount: Int?
    let currentWeeklyUsageCount: Int?
    let weeklyStartTime: Int?
    let weeklyEndTime: Int?
    let weeklyRemainsTime: Int?

    enum CodingKeys: String, CodingKey {
        case modelName = "model_name"
        case currentIntervalTotalCount = "current_interval_total_count"
        case currentIntervalUsageCount = "current_interval_usage_count"
        case startTime = "start_time"
        case endTime = "end_time"
        case remainsTime = "remains_time"
        case currentWeeklyTotalCount = "current_weekly_total_count"
        case currentWeeklyUsageCount = "current_weekly_usage_count"
        case weeklyStartTime = "weekly_start_time"
        case weeklyEndTime = "weekly_end_time"
        case weeklyRemainsTime = "weekly_remains_time"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelName = try? c.decodeIfPresent(String.self, forKey: .modelName)
        currentIntervalTotalCount = MiniMaxQuotaDecoding.int(c, forKey: .currentIntervalTotalCount)
        currentIntervalUsageCount = MiniMaxQuotaDecoding.int(c, forKey: .currentIntervalUsageCount)
        startTime = MiniMaxQuotaDecoding.int(c, forKey: .startTime)
        endTime = MiniMaxQuotaDecoding.int(c, forKey: .endTime)
        remainsTime = MiniMaxQuotaDecoding.int(c, forKey: .remainsTime)
        currentWeeklyTotalCount = MiniMaxQuotaDecoding.int(c, forKey: .currentWeeklyTotalCount)
        currentWeeklyUsageCount = MiniMaxQuotaDecoding.int(c, forKey: .currentWeeklyUsageCount)
        weeklyStartTime = MiniMaxQuotaDecoding.int(c, forKey: .weeklyStartTime)
        weeklyEndTime = MiniMaxQuotaDecoding.int(c, forKey: .weeklyEndTime)
        weeklyRemainsTime = MiniMaxQuotaDecoding.int(c, forKey: .weeklyRemainsTime)
    }
}

private struct MiniMaxServiceUsage: Decodable {
    let serviceType: String?
    let windowType: String?
    let timeRange: String?
    let usage: Int?
    let used: Int?
    let limit: Int?
    let total: Int?
    let percent: Double?
    let startTime: Int?
    let endTime: Int?
    let remainsTime: Int?

    enum CodingKeys: String, CodingKey {
        case serviceType = "service_type"
        case windowType = "window_type"
        case timeRange = "time_range"
        case usage, used, limit, total, percent
        case startTime = "start_time"
        case endTime = "end_time"
        case remainsTime = "remains_time"
        case resetAt = "reset_at"
        case resetTime = "reset_time"
        case resetInSeconds = "reset_in_seconds"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serviceType = try? c.decodeIfPresent(String.self, forKey: .serviceType)
        windowType = try? c.decodeIfPresent(String.self, forKey: .windowType)
        timeRange = try? c.decodeIfPresent(String.self, forKey: .timeRange)
        usage = MiniMaxQuotaDecoding.int(c, forKey: .usage)
        used = MiniMaxQuotaDecoding.int(c, forKey: .used)
        limit = MiniMaxQuotaDecoding.int(c, forKey: .limit)
        total = MiniMaxQuotaDecoding.int(c, forKey: .total)
        percent = MiniMaxQuotaDecoding.double(c, forKey: .percent)
        startTime = MiniMaxQuotaDecoding.int(c, forKey: .startTime)
        endTime = MiniMaxQuotaDecoding.int(c, forKey: .endTime)
            ?? MiniMaxQuotaDecoding.int(c, forKey: .resetAt)
            ?? MiniMaxQuotaDecoding.int(c, forKey: .resetTime)
        remainsTime = MiniMaxQuotaDecoding.int(c, forKey: .remainsTime)
            ?? MiniMaxQuotaDecoding.int(c, forKey: .resetInSeconds)
    }

    var bucketIdentity: (id: String, title: String, shortLabel: String, windowSeconds: Int?) {
        let raw = [windowType, timeRange, serviceType]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: " ")
        if raw.contains("week") {
            return ("minimax.weekly", "Weekly", "Wk", 7 * 86_400)
        }
        if raw.contains("month") {
            return ("minimax.monthly", "Monthly", "Month", 30 * 86_400)
        }
        if raw.contains("day") || raw.contains("24") {
            return ("minimax.daily", "Daily", "Day", 86_400)
        }
        if raw.contains("hour") || raw.contains("5h") || raw.contains("interval") || raw.contains("session") {
            return ("minimax.coding", "5 Hours", "5h", 5 * 3600)
        }
        return ("minimax.coding", "5 Hours", "5h", 5 * 3600)
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

    static func double<K: CodingKey>(_ c: KeyedDecodingContainer<K>, forKey key: K) -> Double? {
        if let v = try? c.decodeIfPresent(Double.self, forKey: key) { return v }
        if let v = try? c.decodeIfPresent(Int.self, forKey: key) { return Double(v) }
        if let v = try? c.decodeIfPresent(String.self, forKey: key),
           let n = Double(v.trimmingCharacters(in: .whitespacesAndNewlines)) { return n }
        return nil
    }
}

private extension String {
    var trimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
