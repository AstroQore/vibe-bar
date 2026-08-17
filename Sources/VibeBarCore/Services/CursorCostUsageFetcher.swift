import Foundation

enum CursorCostFetchOutcome: Sendable {
    case unavailable
    case success(CostSnapshot)
    case failed
}

/// Fetches Cursor Agent token/cost events from Cursor's account dashboard.
///
/// Cursor's local agent transcripts do not carry token counters. The dashboard
/// event rows do, including authoritative `tokenUsage.totalCents`; Grok Bot's
/// cloud-only weekly allowance is a separate endpoint and is intentionally not
/// synthesized into these events.
struct CursorCostUsageFetcher: Sendable {
    private let session: URLSession
    private let baseURL: URL
    private let pageSize: Int
    private let maxPages: Int

    init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://cursor.com")!,
        pageSize: Int = 1_000,
        maxPages: Int = 200
    ) {
        self.session = session
        self.baseURL = baseURL
        self.pageSize = pageSize
        self.maxPages = maxPages
    }

    static func fetch(
        homeDirectory: String = RealHomeDirectory.path,
        now: Date = Date(),
        retentionDays: Int,
        session: URLSession = .shared,
        resolutions override: [MiscCookieResolver.Resolution]? = nil
    ) async -> CursorCostFetchOutcome {
        let resolutions = override ?? CursorSessionResolver.resolutions(
            homeDirectory: homeDirectory,
            now: now
        )
        guard !resolutions.isEmpty else { return .unavailable }

        let normalizedRetention = CostDataSettings.normalizedRetentionDays(retentionDays)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let since = normalizedRetention > 0
            ? calendar.date(byAdding: .day, value: -(normalizedRetention - 1), to: today)
            : nil
        let fetcher = CursorCostUsageFetcher(session: session)
        var snapshots: [CostSnapshot] = []
        for resolution in resolutions {
            do {
                let snapshot = try await fetcher.fetchSnapshot(
                    cookieHeader: resolution.header,
                    since: since,
                    until: now,
                    now: now
                )
                snapshots.append(snapshot)
            } catch {
                SafeLog.net("Cursor cost refresh failed: \(SafeLog.sanitize(error.localizedDescription))")
            }
        }
        guard !snapshots.isEmpty else { return .failed }
        return .success(CostSnapshotAggregator.combinedSnapshot(
            tool: .cursor,
            snapshots: snapshots,
            now: now
        ))
    }

    func fetchSnapshot(
        cookieHeader: String,
        since: Date?,
        until: Date?,
        now: Date
    ) async throws -> CostSnapshot {
        let events = try await fetchAllEvents(
            cookieHeader: cookieHeader,
            since: since,
            until: until
        )
        var accumulator = CostUsageScanner.CostAggregator(tool: .cursor, now: now)
        var includedEvents = 0
        for event in events {
            guard let date = event.date,
                  event.clientType?.lowercased() != "grok-bot",
                  let usage = event.tokenUsage,
                  usage.totalTokens > 0
            else { continue }
            let model = event.model.flatMap { $0.isEmpty ? nil : $0 } ?? "cursor-unknown"
            accumulator.add(
                at: date,
                model: model,
                input: usage.inputTokens + usage.cacheWriteTokens,
                output: usage.outputTokens,
                cache: usage.cacheReadTokens,
                costUSD: max(0, (usage.totalCents ?? 0) / 100)
            )
            includedEvents += 1
        }
        return accumulator.snapshot(jsonlFilesFound: includedEvents)
    }

    private func fetchAllEvents(
        cookieHeader: String,
        since: Date?,
        until: Date?
    ) async throws -> [CursorUsageEvent] {
        var pages: [[CursorUsageEvent]] = []
        var expectedTotal: Int?
        var completed = false

        for page in 1...maxPages {
            let response = try await fetchPage(
                cookieHeader: cookieHeader,
                page: page,
                since: since,
                until: until
            )
            if let total = response.totalUsageEventsCount {
                guard total >= 0 else { throw QuotaError.parseFailure("Cursor event count is negative") }
                if let expectedTotal, expectedTotal != total {
                    throw QuotaError.parseFailure("Cursor event count changed during pagination")
                }
                expectedTotal = total
            }
            let pageEvents = response.usageEventsDisplay
            if pageEvents.isEmpty {
                completed = true
                break
            }
            pages.append(pageEvents)
            if pageEvents.count < pageSize {
                completed = true
                break
            }
        }

        let rawEvents = pages.flatMap(\.self)
        guard completed else {
            throw QuotaError.parseFailure("Cursor usage pagination reached its safety cap")
        }
        guard let expectedTotal else { return rawEvents }
        guard rawEvents.count >= expectedTotal else {
            throw QuotaError.parseFailure("Cursor usage pagination returned a partial result")
        }
        guard rawEvents.count > expectedTotal else { return rawEvents }

        // The endpoint has no stable event id and can repeat exact rows at page
        // boundaries. Remove only the overlap proven by its authoritative count.
        var removalsRemaining = rawEvents.count - expectedTotal
        var reconciled = pages.first ?? []
        for index in pages.indices.dropFirst() {
            let page = pages[index]
            let overlap = Self.boundaryOverlap(
                previousPage: pages[index - 1],
                currentPage: page
            )
            let removalCount = min(overlap, removalsRemaining)
            reconciled.append(contentsOf: page.dropFirst(removalCount))
            removalsRemaining -= removalCount
        }
        guard removalsRemaining == 0, reconciled.count == expectedTotal else {
            throw QuotaError.parseFailure("Cursor usage pagination could not reconcile duplicate rows")
        }
        return reconciled
    }

    private func fetchPage(
        cookieHeader: String,
        page: Int,
        since: Date?,
        until: Date?
    ) async throws -> CursorUsageEventsPage {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("/api/dashboard/get-filtered-usage-events")
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("\(baseURL.scheme ?? "https")://\(baseURL.host ?? "cursor.com")", forHTTPHeaderField: "Origin")
        request.httpBody = try JSONEncoder().encode(CursorFilteredUsageRequest(
            page: page,
            pageSize: pageSize,
            startDate: Self.millisString(since),
            endDate: Self.millisString(until)
        ))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Cursor usage returned an invalid response")
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw QuotaError.needsLogin }
        guard http.statusCode == 200 else {
            throw QuotaError.network("Cursor usage returned HTTP \(http.statusCode)")
        }
        do {
            return try JSONDecoder().decode(CursorUsageEventsPage.self, from: data)
        } catch {
            throw QuotaError.parseFailure("Cursor usage events are not parseable: \(error.localizedDescription)")
        }
    }

    private static func millisString(_ date: Date?) -> String? {
        date.map { String(Int64(($0.timeIntervalSince1970 * 1_000).rounded())) }
    }

    private static func boundaryOverlap(
        previousPage: [CursorUsageEvent],
        currentPage: [CursorUsageEvent]
    ) -> Int {
        let limit = min(previousPage.count, currentPage.count)
        guard limit > 0 else { return 0 }
        for count in stride(from: limit, through: 1, by: -1)
            where previousPage.suffix(count).elementsEqual(currentPage.prefix(count)) {
            return count
        }
        return 0
    }
}

private struct CursorFilteredUsageRequest: Encodable {
    let page: Int
    let pageSize: Int
    let startDate: String?
    let endDate: String?
}

private struct CursorUsageEventsPage: Decodable {
    let totalUsageEventsCount: Int?
    let usageEventsDisplay: [CursorUsageEvent]

    private enum CodingKeys: String, CodingKey {
        case totalUsageEventsCount
        case usageEventsDisplay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawCount = try? container.decode(CursorFlexibleNumber.self, forKey: .totalUsageEventsCount)
        self.totalUsageEventsCount = rawCount?.nonnegativeInt
        self.usageEventsDisplay = try container.decode(
            [CursorUsageEvent].self,
            forKey: .usageEventsDisplay
        )
    }
}

private struct CursorUsageEvent: Decodable, Hashable {
    let timestamp: CursorFlexibleNumber?
    let model: String?
    let tokenUsage: CursorEventTokenUsage?
    let kind: String?
    let isHeadless: Bool?
    let clientType: String?

    var date: Date? {
        guard let milliseconds = timestamp?.doubleValue,
              milliseconds.isFinite,
              milliseconds > 0
        else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }
}

private struct CursorEventTokenUsage: Decodable, Hashable {
    let inputTokensRaw: CursorFlexibleNumber?
    let outputTokensRaw: CursorFlexibleNumber?
    let cacheWriteTokensRaw: CursorFlexibleNumber?
    let cacheReadTokensRaw: CursorFlexibleNumber?
    let totalCentsRaw: CursorFlexibleNumber?

    private enum CodingKeys: String, CodingKey {
        case inputTokensRaw = "inputTokens"
        case outputTokensRaw = "outputTokens"
        case cacheWriteTokensRaw = "cacheWriteTokens"
        case cacheReadTokensRaw = "cacheReadTokens"
        case totalCentsRaw = "totalCents"
    }

    var inputTokens: Int { inputTokensRaw?.nonnegativeInt ?? 0 }
    var outputTokens: Int { outputTokensRaw?.nonnegativeInt ?? 0 }
    var cacheWriteTokens: Int { cacheWriteTokensRaw?.nonnegativeInt ?? 0 }
    var cacheReadTokens: Int { cacheReadTokensRaw?.nonnegativeInt ?? 0 }
    var totalCents: Double? { totalCentsRaw?.doubleValue }

    var totalTokens: Int {
        var total = 0
        for value in [inputTokens, outputTokens, cacheWriteTokens, cacheReadTokens] {
            let (sum, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return 0 }
            total = sum
        }
        return total
    }
}

private enum CursorFlexibleNumber: Decodable, Hashable {
    case integer(Int64)
    case decimal(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
            return
        }
        if let value = try? container.decode(Double.self), value.isFinite {
            self = .decimal(value)
            return
        }
        if let raw = try? container.decode(String.self),
           let value = Double(raw), value.isFinite {
            self = .decimal(value)
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Cursor number")
    }

    var doubleValue: Double {
        switch self {
        case .integer(let value): return Double(value)
        case .decimal(let value): return value
        }
    }

    var nonnegativeInt: Int {
        switch self {
        case .integer(let value):
            guard value >= 0 else { return 0 }
            return Int(exactly: value) ?? 0
        case .decimal(let value):
            guard value >= 0 else { return 0 }
            return Int(exactly: value) ?? 0
        }
    }
}
