import Foundation

/// Volcengine / Doubao Coding Plan usage adapter.
///
/// Auth: a CAM sub-user (`<sub-user>` under main account `<mainUID>`)
/// password-logs in via `VolcengineSessionManager`. Sessions expire
/// within hours; on `needsLogin` the adapter wipes the cookie jar and
/// re-runs the login once before surfacing.
///
/// Endpoint:
/// `POST https://console.volcengine.com/api/top/ark/cn-beijing/2024-01-01/GetCodingPlanUsage`
/// returns three quota buckets — session (≈5h), weekly, monthly —
/// each carrying a 0–100 percent and an absolute reset epoch. There
/// are no used/total counts; the server does the arithmetic.
///
/// Optional companion call: `ListSubscribeTrade` to surface the plan
/// name ("Coding Plan Pro" / "Coding Plan Lite") in the card subtitle.
/// We invoke it best-effort and fall back to nil on any error so the
/// quota refresh still succeeds.
public struct VolcengineQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .volcengine

    private let sessionManager: VolcengineSessionManager
    private let now: @Sendable () -> Date

    public init(
        sessionManager: VolcengineSessionManager = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sessionManager = sessionManager
        self.now = now
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        let snapshot = try await fetchSnapshot()
        return AccountQuota(
            accountId: account.id,
            tool: .volcengine,
            buckets: snapshot.buckets,
            plan: snapshot.planName,
            email: account.email,
            queriedAt: now(),
            error: nil
        )
    }

    private func fetchSnapshot() async throws -> VolcengineQuotaSnapshot {
        do {
            return try await fetchOnce()
        } catch QuotaError.needsLogin {
            await sessionManager.wipeSession()
            return try await fetchOnce()
        }
    }

    private func fetchOnce() async throws -> VolcengineQuotaSnapshot {
        let session = try await sessionManager.authedSession()
        guard let csrfToken = await sessionManager.currentCsrfToken() else {
            throw QuotaError.needsLogin
        }

        let usageData = try await callBFF(
            session: session,
            csrfToken: csrfToken,
            url: Self.getCodingPlanUsageURL,
            body: [:]
        )
        let parsed = try VolcengineResponseParser.parseUsage(data: usageData)

        // Best-effort plan name. Failures here must not poison the
        // quota refresh — a missing plan badge is far less bad than a
        // visible error on a card whose buckets were fetched fine.
        var planName: String? = nil
        if let tradeData = try? await callBFF(
            session: session,
            csrfToken: csrfToken,
            url: Self.listSubscribeTradeURL,
            body: [
                "ResourceTypes": ["CodingPlan"],
                "ResourceNames": [""],
                "BizInfos": ["lite", "pro"]
            ]
        ) {
            planName = (try? VolcengineResponseParser.parsePlanName(data: tradeData)) ?? nil
        }

        return VolcengineQuotaSnapshot(buckets: parsed.buckets, planName: planName)
    }

    private func callBFF(
        session: URLSession,
        csrfToken: String,
        url: URL,
        body: [String: Any]
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(csrfToken, forHTTPHeaderField: "X-Csrf-Token")
        request.setValue("zh", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://console.volcengine.com", forHTTPHeaderField: "Origin")
        request.setValue("https://console.volcengine.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuotaError.network("Volcengine network error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Volcengine: invalid response object")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw QuotaError.needsLogin
            }
            if http.statusCode == 429 {
                throw QuotaError.rateLimited
            }
            throw QuotaError.network("Volcengine returned HTTP \(http.statusCode).")
        }
        return data
    }

    private static let getCodingPlanUsageURL = URL(string:
        "https://console.volcengine.com/api/top/ark/cn-beijing/2024-01-01/GetCodingPlanUsage"
    )!
    private static let listSubscribeTradeURL = URL(string:
        "https://console.volcengine.com/api/top/ark/cn-beijing/2024-01-01/ListSubscribeTrade"
    )!
}

struct VolcengineQuotaSnapshot {
    var buckets: [QuotaBucket]
    var planName: String?
}

// MARK: - Response parsing

enum VolcengineResponseParser {
    struct UsageSnapshot {
        var buckets: [QuotaBucket]
    }

    static func parseUsage(data: Data) throws -> UsageSnapshot {
        guard !data.isEmpty else {
            throw QuotaError.parseFailure("Volcengine returned an empty body.")
        }
        let envelope: VolcengineUsageEnvelope
        do {
            envelope = try JSONDecoder().decode(VolcengineUsageEnvelope.self, from: data)
        } catch {
            throw QuotaError.parseFailure("Volcengine usage response not parseable: \(error.localizedDescription)")
        }

        if let err = envelope.responseMetadata?.error {
            let code = err.code?.lowercased() ?? ""
            let message = err.message?.trimmed ?? "code \(err.code ?? "?")"
            if isAuthCode(code) || message.lowercased().contains("login") {
                throw QuotaError.needsLogin
            }
            if code.contains("requestlimit") || code.contains("ratelimit") {
                throw QuotaError.rateLimited
            }
            throw QuotaError.network("Volcengine: \(message)")
        }

        guard let result = envelope.result else {
            throw QuotaError.parseFailure("Volcengine usage response had no Result block.")
        }
        guard let usage = result.quotaUsage, !usage.isEmpty else {
            throw QuotaError.parseFailure("Volcengine usage response had no QuotaUsage entries.")
        }

        var buckets: [QuotaBucket] = []
        for entry in usage {
            guard let bucket = bucket(from: entry) else { continue }
            buckets.append(bucket)
        }
        guard !buckets.isEmpty else {
            throw QuotaError.parseFailure("Volcengine usage response had no recognizable Levels.")
        }
        return UsageSnapshot(buckets: buckets)
    }

    static func parsePlanName(data: Data) throws -> String? {
        guard !data.isEmpty else { return nil }
        let envelope: VolcengineSubscribeEnvelope
        do {
            envelope = try JSONDecoder().decode(VolcengineSubscribeEnvelope.self, from: data)
        } catch {
            return nil
        }
        guard let info = envelope.result?.infoList?.first(where: { ($0.bizInfo ?? "").isEmpty == false }) else {
            return nil
        }
        guard let raw = info.bizInfo?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return "Coding Plan " + raw.prefix(1).uppercased() + raw.dropFirst()
    }

    private static func bucket(from entry: VolcengineQuotaEntry) -> QuotaBucket? {
        guard let level = entry.level?.lowercased(), let percent = entry.percent else {
            return nil
        }
        let resetAt = entry.resetTimestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        switch level {
        case "session":
            return QuotaBucket(
                id: "volcengine.session",
                title: "5 Hours",
                shortLabel: "5h",
                usedPercent: clampPercent(percent),
                resetAt: resetAt,
                rawWindowSeconds: 5 * 3600
            )
        case "weekly":
            return QuotaBucket(
                id: "volcengine.weekly",
                title: "Weekly",
                shortLabel: "Wk",
                usedPercent: clampPercent(percent),
                resetAt: resetAt,
                rawWindowSeconds: 7 * 86_400
            )
        case "monthly":
            return QuotaBucket(
                id: "volcengine.monthly",
                title: "Monthly",
                shortLabel: "Mo",
                usedPercent: clampPercent(percent),
                resetAt: resetAt,
                rawWindowSeconds: 30 * 86_400
            )
        default:
            return nil
        }
    }

    private static func clampPercent(_ raw: Double) -> Double {
        max(0, min(100, raw))
    }

    private static func isAuthCode(_ code: String) -> Bool {
        code.contains("login") ||
            code.contains("auth") ||
            code.contains("invalidstate") ||
            code.contains("unauthenticated")
    }
}

// MARK: - Wire types

private struct VolcengineUsageEnvelope: Decodable {
    let responseMetadata: VolcengineResponseMetadata?
    let result: VolcengineUsageResult?

    enum CodingKeys: String, CodingKey {
        case responseMetadata = "ResponseMetadata"
        case result = "Result"
    }
}

private struct VolcengineUsageResult: Decodable {
    let status: String?
    let updateTimestamp: Int?
    let quotaUsage: [VolcengineQuotaEntry]?

    enum CodingKeys: String, CodingKey {
        case status = "Status"
        case updateTimestamp = "UpdateTimestamp"
        case quotaUsage = "QuotaUsage"
    }
}

struct VolcengineQuotaEntry: Decodable {
    let level: String?
    let percent: Double?
    let resetTimestamp: Int?

    enum CodingKeys: String, CodingKey {
        case level = "Level"
        case percent = "Percent"
        case resetTimestamp = "ResetTimestamp"
    }
}

private struct VolcengineSubscribeEnvelope: Decodable {
    let result: VolcengineSubscribeResult?

    enum CodingKeys: String, CodingKey { case result = "Result" }
}

private struct VolcengineSubscribeResult: Decodable {
    let infoList: [VolcengineSubscribeInfo]?

    enum CodingKeys: String, CodingKey { case infoList = "InfoList" }
}

private struct VolcengineSubscribeInfo: Decodable {
    let bizInfo: String?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case bizInfo = "BizInfo"
        case status = "Status"
    }
}

private extension String {
    var trimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
