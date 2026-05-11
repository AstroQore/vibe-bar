import Foundation

/// Kilo usage adapter.
///
/// Auth: API key from Keychain / `KILO_API_KEY`, with a CLI fallback to
/// `~/.local/share/kilo/auth.json` (the file created by `kilo login`).
/// Usage is fetched through Kilo's tRPC batch endpoint, matching the
/// Codex Bar provider.
public struct KiloQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .kilo

    private let session: URLSession
    private let environment: [String: String]
    private let homeDirectory: String
    private let now: @Sendable () -> Date

    public init(
        session: URLSession = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = RealHomeDirectory.path,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.now = now
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        let settings = MiscProviderSettings.current(for: .kilo)
        guard settings.allowsAPIOrOAuthAccess,
              let token = Self.resolveAuthToken(
                environment: environment,
                homeDirectory: homeDirectory,
                allowCLI: settings.allowsLocalProbeAccess
              ) else {
            throw QuotaError.noCredential
        }

        let snapshot = try await fetchSnapshot(token: token)
        return AccountQuota(
            accountId: account.id,
            tool: .kilo,
            buckets: snapshot.buckets,
            plan: snapshot.planName,
            email: account.email,
            queriedAt: now(),
            error: nil
        )
    }

    private func fetchSnapshot(token: String) async throws -> KiloResponseParser.Snapshot {
        let url = try KiloResponseParser.batchURL(baseURL: Self.apiURL(environment: environment))
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuotaError.network("Kilo network error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Kilo: invalid response object")
        }
        guard http.statusCode == 200 else {
            switch http.statusCode {
            case 401, 403: throw QuotaError.needsLogin
            case 404:      throw QuotaError.network("Kilo tRPC endpoint not found.")
            case 429:      throw QuotaError.rateLimited
            case 500...599: throw QuotaError.network("Kilo service unavailable (HTTP \(http.statusCode)).")
            default:       throw QuotaError.network("Kilo returned HTTP \(http.statusCode).")
            }
        }
        return try KiloResponseParser.parse(data: data, now: now())
    }

    private static func apiURL(environment: [String: String]) -> URL {
        if let raw = cleaned(environment["KILO_API_URL"]),
           let url = URL(string: raw),
           url.scheme != nil {
            return url
        }
        return URL(string: "https://app.kilo.ai/api/trpc")!
    }

    private static func resolveAuthToken(
        environment: [String: String],
        homeDirectory: String,
        allowCLI: Bool
    ) -> String? {
        if let stored = MiscCredentialStore.readString(tool: .kilo, kind: .apiKey),
           !stored.isEmpty {
            return stored
        }
        if let env = cleaned(environment["KILO_API_KEY"]) {
            return env
        }
        guard allowCLI else { return nil }
        let authURL = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("kilo", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
        guard let data = try? Data(contentsOf: authURL),
              let auth = try? JSONDecoder().decode(KiloAuthFile.self, from: data) else {
            return nil
        }
        return cleaned(auth.kilo?.access)
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'")) {
            value.removeFirst()
            value.removeLast()
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private struct KiloAuthFile: Decodable {
    let kilo: KiloAuthSection?
}

private struct KiloAuthSection: Decodable {
    let access: String?
}

enum KiloResponseParser {
    struct Snapshot {
        var buckets: [QuotaBucket]
        var planName: String?
    }

    private static let procedures = [
        "user.getCreditBlocks",
        "kiloPass.getState",
        "user.getAutoTopUpPaymentMethod"
    ]

    static func batchURL(baseURL: URL) throws -> URL {
        let endpoint = baseURL.appendingPathComponent(procedures.joined(separator: ","))
        let inputMap = Dictionary(uniqueKeysWithValues: procedures.indices.map {
            (String($0), ["json": NSNull()])
        })
        let data = try JSONSerialization.data(withJSONObject: inputMap)
        guard let input = String(data: data, encoding: .utf8),
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw QuotaError.parseFailure("Kilo batch URL could not be built.")
        }
        components.queryItems = [
            URLQueryItem(name: "batch", value: "1"),
            URLQueryItem(name: "input", value: input)
        ]
        guard let url = components.url else {
            throw QuotaError.parseFailure("Kilo batch URL could not be built.")
        }
        return url
    }

    static func parse(data: Data, now: Date) throws -> Snapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw QuotaError.parseFailure("Kilo response was not JSON.")
        }
        let entries = try responseEntriesByIndex(from: root)
        var payloads: [String: Any] = [:]

        for (index, procedure) in procedures.enumerated() {
            guard let entry = entries[index] else { continue }
            if let error = trpcError(from: entry) {
                if procedure == "user.getAutoTopUpPaymentMethod" {
                    continue
                }
                throw error
            }
            if let payload = resultPayload(from: entry) {
                payloads[procedure] = payload
            }
        }

        let credits = creditFields(from: payloads[procedures[0]])
        let pass = passFields(from: payloads[procedures[1]])
        let plan = planName(from: payloads[procedures[1]])
        let autoTopUp = autoTopUpState(
            creditBlocksPayload: payloads[procedures[0]],
            autoTopUpPayload: payloads[procedures[2]]
        )
        let displayPlan = makePlanLabel(planName: plan, autoTopUp: autoTopUp)

        var buckets: [QuotaBucket] = []
        if let total = credits.total ?? credits.used.flatMap({ used in credits.remaining.map { used + $0 } }) {
            let used = credits.used ?? credits.remaining.map { max(0, total - $0) } ?? 0
            buckets.append(QuotaBucket(
                id: "kilo.credits",
                title: "Credits",
                shortLabel: "Credits",
                usedPercent: total > 0 ? used / total * 100 : 100,
                groupTitle: "\(compact(used))/\(compact(total)) credits"
            ))
        }
        if let total = pass.total ?? pass.used.flatMap({ used in pass.remaining.map { used + $0 } }) {
            let used = pass.used ?? pass.remaining.map { max(0, total - $0) } ?? 0
            let base = max(0, total - (pass.bonus ?? 0))
            var group = "\(money(used)) / \(money(base))"
            if let bonus = pass.bonus, bonus > 0 {
                group += " (+ \(money(bonus)) bonus)"
            }
            buckets.append(QuotaBucket(
                id: "kilo.pass",
                title: "Kilo Pass",
                shortLabel: "Pass",
                usedPercent: total > 0 ? used / total * 100 : 100,
                resetAt: pass.resetsAt,
                groupTitle: group
            ))
        }

        guard !buckets.isEmpty else {
            throw QuotaError.parseFailure("Kilo response had no usable credit windows.")
        }
        return Snapshot(buckets: buckets, planName: displayPlan)
    }

    private static func responseEntriesByIndex(from root: Any) throws -> [Int: [String: Any]] {
        if let entries = root as? [[String: Any]] {
            return Dictionary(uniqueKeysWithValues: entries.prefix(procedures.count).enumerated().map { ($0.offset, $0.element) })
        }
        if let dictionary = root as? [String: Any] {
            if dictionary["result"] != nil || dictionary["error"] != nil {
                return [0: dictionary]
            }
            let indexed = dictionary.compactMap { key, value -> (Int, [String: Any])? in
                guard let index = Int(key),
                      index >= 0,
                      index < procedures.count,
                      let entry = value as? [String: Any] else {
                    return nil
                }
                return (index, entry)
            }
            if !indexed.isEmpty {
                return Dictionary(uniqueKeysWithValues: indexed)
            }
        }
        throw QuotaError.parseFailure("Kilo response had an unexpected tRPC shape.")
    }

    private static func trpcError(from entry: [String: Any]) -> QuotaError? {
        guard let error = entry["error"] as? [String: Any] else { return nil }
        let combined = [
            stringValue(for: ["json", "data", "code"], in: error),
            stringValue(for: ["data", "code"], in: error),
            stringValue(for: ["code"], in: error),
            stringValue(for: ["json", "message"], in: error),
            stringValue(for: ["message"], in: error)
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if combined.contains("unauthorized") || combined.contains("forbidden") {
            return .needsLogin
        }
        if combined.contains("not_found") || combined.contains("not found") {
            return .network("Kilo tRPC endpoint not found.")
        }
        return .parseFailure("Kilo tRPC error payload.")
    }

    private static func resultPayload(from entry: [String: Any]) -> Any? {
        guard let result = entry["result"] as? [String: Any] else { return nil }
        if let data = result["data"] as? [String: Any] {
            if let json = data["json"] {
                return json is NSNull ? nil : json
            }
            return data
        }
        if let json = result["json"] {
            return json is NSNull ? nil : json
        }
        return nil
    }

    private static func creditFields(from payload: Any?) -> (used: Double?, total: Double?, remaining: Double?) {
        let contexts = dictionaryContexts(from: payload)
        if let blocks = firstArray(forKeys: ["creditBlocks"], in: contexts) {
            var total = 0.0
            var remaining = 0.0
            var sawTotal = false
            var sawRemaining = false
            for case let block as [String: Any] in blocks {
                if let amount = double(from: block["amount_mUsd"]) {
                    total += amount / 1_000_000
                    sawTotal = true
                }
                if let balance = double(from: block["balance_mUsd"]) {
                    remaining += balance / 1_000_000
                    sawRemaining = true
                }
            }
            if sawTotal || sawRemaining {
                return (
                    sawTotal && sawRemaining ? max(0, total - remaining) : nil,
                    sawTotal ? max(0, total) : nil,
                    sawRemaining ? max(0, remaining) : nil
                )
            }
        }

        let blockContexts = (firstArray(forKeys: ["blocks"], in: contexts) ?? []).compactMap { $0 as? [String: Any] }
        var used = firstDouble(forKeys: ["used", "usedCredits", "creditsUsed", "consumed", "spent"], in: blockContexts)
            ?? firstDouble(forKeys: ["used", "usedCredits", "creditsUsed", "consumed", "spent"], in: contexts)
        var total = firstDouble(forKeys: ["total", "totalCredits", "creditsTotal", "limit"], in: blockContexts)
            ?? firstDouble(forKeys: ["total", "totalCredits", "creditsTotal", "limit"], in: contexts)
        var remaining = firstDouble(forKeys: ["remaining", "remainingCredits", "creditsRemaining"], in: blockContexts)
            ?? firstDouble(forKeys: ["remaining", "remainingCredits", "creditsRemaining"], in: contexts)

        if total == nil, let used, let remaining { total = used + remaining }
        if used == nil, let total, let remaining { used = max(0, total - remaining) }
        if remaining == nil, let total, let used { remaining = max(0, total - used) }

        if used == nil, total == nil, remaining == nil,
           let balance = firstDouble(forKeys: ["totalBalance_mUsd"], in: contexts) {
            let dollars = max(0, balance / 1_000_000)
            return (0, dollars, dollars)
        }
        return (used, total, remaining)
    }

    private struct PassFields {
        let used: Double?
        let total: Double?
        let remaining: Double?
        let bonus: Double?
        let resetsAt: Date?
    }

    private static func passFields(from payload: Any?) -> PassFields {
        if let subscription = subscriptionData(from: payload) {
            let used = double(from: subscription["currentPeriodUsageUsd"]).map { max(0, $0) }
            let base = double(from: subscription["currentPeriodBaseCreditsUsd"]).map { max(0, $0) }
            let bonus = max(0, double(from: subscription["currentPeriodBonusCreditsUsd"]) ?? 0)
            let total = base.map { $0 + bonus }
            return PassFields(
                used: used,
                total: total,
                remaining: total.flatMap { total in used.map { max(0, total - $0) } },
                bonus: bonus > 0 ? bonus : nil,
                resetsAt: date(from: subscription["nextBillingAt"])
                    ?? date(from: subscription["nextRenewalAt"])
                    ?? date(from: subscription["renewsAt"])
                    ?? date(from: subscription["renewAt"])
            )
        }

        let contexts = dictionaryContexts(from: payload)
        let total = moneyAmount(centsKeys: ["amountCents", "totalCents", "limitCents"],
                                milliUSDKeys: ["amount_mUsd", "total_mUsd", "limit_mUsd"],
                                plainKeys: ["amount", "total", "limit", "creditsTotal"], in: contexts)
        let used = moneyAmount(centsKeys: ["usedCents", "spentCents"],
                               milliUSDKeys: ["used_mUsd", "spent_mUsd"],
                               plainKeys: ["used", "spent", "usage", "creditsUsed"], in: contexts)
        let remaining = moneyAmount(centsKeys: ["remainingCents", "balanceCents"],
                                    milliUSDKeys: ["remaining_mUsd", "balance_mUsd"],
                                    plainKeys: ["remaining", "balance", "creditsRemaining"], in: contexts)
        let bonus = moneyAmount(centsKeys: ["bonusCents"], milliUSDKeys: ["bonus_mUsd"], plainKeys: ["bonus", "bonusCredits"], in: contexts)
        return PassFields(
            used: used,
            total: total ?? combinedTotal(used: used, remaining: remaining),
            remaining: remaining,
            bonus: bonus,
            resetsAt: firstDate(forKeys: ["resetAt", "resetsAt", "nextResetAt", "nextRenewalAt", "expiresAt"], in: contexts)
        )
    }

    private static func combinedTotal(used: Double?, remaining: Double?) -> Double? {
        guard let used, let remaining else { return nil }
        return used + remaining
    }

    private static func planName(from payload: Any?) -> String? {
        if let subscription = subscriptionData(from: payload) {
            if let tier = (subscription["tier"] as? String)?.trimmed {
                switch tier {
                case "tier_19": return "Starter"
                case "tier_49": return "Pro"
                case "tier_199": return "Expert"
                default: return tier
                }
            }
            return "Kilo Pass"
        }
        let contexts = dictionaryContexts(from: payload)
        return firstString(forKeys: ["planName", "tier", "tierName", "passName", "subscriptionName"], in: contexts)
            ?? stringValue(for: ["plan", "name"], in: contexts)
            ?? stringValue(for: ["subscription", "name"], in: contexts)
    }

    private static func autoTopUpState(
        creditBlocksPayload: Any?,
        autoTopUpPayload: Any?
    ) -> (enabled: Bool?, method: String?) {
        let creditContexts = dictionaryContexts(from: creditBlocksPayload)
        let autoContexts = dictionaryContexts(from: autoTopUpPayload)
        let enabled = firstBool(forKeys: ["enabled", "isEnabled", "active"], in: autoContexts)
            ?? boolFromStatusString(firstString(forKeys: ["status"], in: autoContexts))
            ?? firstBool(forKeys: ["autoTopUpEnabled"], in: creditContexts)
        let method = firstString(forKeys: ["paymentMethod", "paymentMethodType", "method", "cardBrand"], in: autoContexts)?.trimmed
            ?? moneyAmount(centsKeys: ["amountCents"], milliUSDKeys: [], plainKeys: ["amount", "topUpAmount", "amountUsd"], in: autoContexts).map(money)
        return (enabled, method)
    }

    private static func makePlanLabel(planName: String?, autoTopUp: (enabled: Bool?, method: String?)) -> String? {
        var parts: [String] = []
        if let planName = planName?.trimmed { parts.append(planName) }
        if let enabled = autoTopUp.enabled {
            if enabled {
                parts.append("Auto top-up: \(autoTopUp.method?.trimmed ?? "enabled")")
            } else {
                parts.append("Auto top-up: off")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func subscriptionData(from payload: Any?) -> [String: Any]? {
        guard let dict = payload as? [String: Any] else { return nil }
        if let subscription = dict["subscription"] as? [String: Any] {
            return subscription
        }
        let hasShape = dict["currentPeriodUsageUsd"] != nil ||
            dict["currentPeriodBaseCreditsUsd"] != nil ||
            dict["currentPeriodBonusCreditsUsd"] != nil ||
            dict["tier"] != nil
        return hasShape ? dict : nil
    }

    private static func dictionaryContexts(from payload: Any?) -> [[String: Any]] {
        guard let dict = payload as? [String: Any] else { return [] }
        var contexts: [[String: Any]] = []
        var queue: [([String: Any], Int)] = [(dict, 0)]
        while !queue.isEmpty {
            let (current, depth) = queue.removeFirst()
            contexts.append(current)
            guard depth < 2 else { continue }
            for value in current.values {
                if let nested = value as? [String: Any] {
                    queue.append((nested, depth + 1))
                } else if let array = value as? [Any] {
                    for case let nested as [String: Any] in array {
                        queue.append((nested, depth + 1))
                    }
                }
            }
        }
        return contexts
    }

    private static func firstArray(forKeys keys: [String], in contexts: [[String: Any]]) -> [Any]? {
        for context in contexts {
            for key in keys where context[key] is [Any] {
                return context[key] as? [Any]
            }
        }
        return nil
    }

    private static func firstDouble(forKeys keys: [String], in contexts: [[String: Any]]) -> Double? {
        for context in contexts {
            for key in keys {
                if let value = double(from: context[key]) { return value }
            }
        }
        return nil
    }

    private static func firstString(forKeys keys: [String], in contexts: [[String: Any]]) -> String? {
        for context in contexts {
            for key in keys {
                if let value = (context[key] as? String)?.trimmed { return value }
            }
        }
        return nil
    }

    private static func firstBool(forKeys keys: [String], in contexts: [[String: Any]]) -> Bool? {
        for context in contexts {
            for key in keys {
                if let value = bool(from: context[key]) { return value }
            }
        }
        return nil
    }

    private static func firstDate(forKeys keys: [String], in contexts: [[String: Any]]) -> Date? {
        for context in contexts {
            for key in keys {
                if let value = date(from: context[key]) { return value }
            }
        }
        return nil
    }

    private static func moneyAmount(centsKeys: [String], milliUSDKeys: [String], plainKeys: [String], in contexts: [[String: Any]]) -> Double? {
        if let cents = firstDouble(forKeys: centsKeys, in: contexts) { return cents / 100 }
        if let micro = firstDouble(forKeys: milliUSDKeys, in: contexts) { return micro / 1_000_000 }
        return firstDouble(forKeys: plainKeys, in: contexts)
    }

    private static func stringValue(for path: [String], in dict: [String: Any]) -> String? {
        var cursor: Any = dict
        for key in path {
            guard let next = (cursor as? [String: Any])?[key] else { return nil }
            cursor = next
        }
        return (cursor as? String)?.trimmed
    }

    private static func stringValue(for path: [String], in contexts: [[String: Any]]) -> String? {
        for context in contexts {
            if let value = stringValue(for: path, in: context) { return value }
        }
        return nil
    }

    private static func double(from raw: Any?) -> Double? {
        switch raw {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as NSNumber: return value.doubleValue
        case let value as String: return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    private static func bool(from raw: Any?) -> Bool? {
        switch raw {
        case let value as Bool: return value
        case let value as NSNumber: return value.boolValue
        case let value as String:
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes", "enabled", "on"].contains(normalized) { return true }
            if ["false", "0", "no", "disabled", "off"].contains(normalized) { return false }
            return nil
        default: return nil
        }
    }

    private static func boolFromStatusString(_ raw: String?) -> Bool? {
        guard let normalized = raw?.trimmed?.lowercased() else { return nil }
        if ["enabled", "active", "on"].contains(normalized) { return true }
        if ["disabled", "inactive", "off", "none"].contains(normalized) { return false }
        return nil
    }

    private static func date(from raw: Any?) -> Date? {
        switch raw {
        case let value as Double:
            return dateFromEpoch(value)
        case let value as Int:
            return dateFromEpoch(Double(value))
        case let value as NSNumber:
            return dateFromEpoch(value.doubleValue)
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let numeric = Double(trimmed) { return dateFromEpoch(numeric) }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = fractional.date(from: trimmed) { return parsed }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: trimmed)
        default:
            return nil
        }
    }

    private static func dateFromEpoch(_ value: Double) -> Date {
        Date(timeIntervalSince1970: abs(value) > 10_000_000_000 ? value / 1000 : value)
    }

    private static func compact(_ value: Double) -> String {
        value.rounded(.towardZero) == value ? String(Int(value)) : String(format: "%.2f", value)
    }

    private static func money(_ value: Double) -> String {
        value.rounded(.towardZero) == value ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }
}

private extension String {
    var trimmed: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
