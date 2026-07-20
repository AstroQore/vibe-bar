import Foundation

/// Google AntiGravity (local language-server) live-quota adapter.
///
/// Auth flow has no remote credential — it discovers the locally
/// running AntiGravity language-server process, parses its CSRF tokens
/// and ports, then POSTs to a localhost HTTPS endpoint protected by
/// `X-Codeium-Csrf-Token`. The discovery + transport now live in the
/// shared `AntigravityLanguageServerClient`; this adapter reads the
/// grouped `RetrieveUserQuotaSummary` payload for the four real quota
/// lanes and uses `GetUserStatus` only to attach account identity and
/// keep the model-label cache fresh. The cost-scanner reuses the client
/// for the `GetCascadeTrajectoryGeneratorMetadata` call.
public struct AntigravityQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .antigravity

    private let timeout: TimeInterval
    private let now: @Sendable () -> Date
    private let usageModeProvider: @Sendable () -> AntigravityUsageMode

    public init(
        timeout: TimeInterval = 8,
        now: @escaping @Sendable () -> Date = { Date() },
        usageMode: (@Sendable () -> AntigravityUsageMode)? = nil
    ) {
        self.timeout = timeout
        self.now = now
        self.usageModeProvider = usageMode ?? { Self.resolveUsageMode() }
    }

    private static let userStatusPath =
        "/exa.language_server_pb.LanguageServerService/GetUserStatus"
    private static let quotaSummaryPath =
        "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        let order = AntigravitySourcePlanner.resolve(mode: usageModeProvider())
        var lastError: Error?
        for source in order {
            do {
                switch source {
                case .localProbe:
                    return try await fetchWithLocalProbe(for: account)
                case .webCookie:
                    // Spike-gated: returns `.noCredential` until the
                    // Antigravity Cloud endpoint is reverse-engineered
                    // and `antigravityWebSourceAvailable` flips. See
                    // plan §9. The planner already collapses
                    // `webOnly` / `webThenLocal` to `[.localProbe]`
                    // while the flag is off, so this arm is unreachable
                    // in practice until the spike lands.
                    throw QuotaError.noCredential
                default:
                    continue
                }
            } catch QuotaError.noCredential {
                lastError = QuotaError.noCredential
                continue
            } catch {
                lastError = error
                continue
            }
        }
        throw mapURLError(lastError ?? QuotaError.noCredential)
    }

    private func fetchWithLocalProbe(for account: AccountIdentity) async throws -> AccountQuota {
        let client = AntigravityLanguageServerClient(timeout: timeout)
        let endpoints = try await client.connectedEndpoints()
        var lastError: Error?
        for endpoint in endpoints {
            do {
                let snapshot = try await Self.fetchLocalSnapshot { path, body in
                    try await client.postLocal(endpoint: endpoint, path: path, body: body)
                }
                // Keep the id → label map fresh so the cost scanner can
                // resolve placeholder model ids to real names and rates.
                AntigravityModelLabelStore.merge(snapshot.modelLabels)
                return AccountQuota(
                    accountId: account.id,
                    tool: .antigravity,
                    buckets: snapshot.buckets,
                    plan: snapshot.planName,
                    email: snapshot.email,
                    queriedAt: now(),
                    error: nil
                )
            } catch {
                lastError = error
                continue
            }
        }
        throw mapError(lastError)
    }

    /// Fetch the grouped quota payload first, then attach identity on a
    /// best-effort basis. Keeping this seam independent from process discovery
    /// makes the endpoint contract and request order unit-testable.
    static func fetchLocalSnapshot(
        request: (_ path: String, _ body: Data) async throws -> Data
    ) async throws -> AntigravityResponseParser.Snapshot {
        let quotaData = try await request(
            Self.quotaSummaryPath,
            Data(#"{"forceRefresh":true}"#.utf8)
        )
        let quotaSnapshot = try AntigravityResponseParser.parseQuotaSummary(data: quotaData)

        let identitySnapshot: AntigravityResponseParser.Snapshot?
        do {
            let identityData = try await request(Self.userStatusPath, Data("{}".utf8))
            identitySnapshot = try AntigravityResponseParser.parseUserStatus(data: identityData)
        } catch {
            // Quotas remain useful when this older endpoint is unavailable.
            identitySnapshot = nil
        }
        return quotaSnapshot.mergingIdentity(identitySnapshot)
    }

    /// Reads the persisted `antigravityUsageMode` setting from disk.
    /// Internal (not `private`) so the public init's default argument
    /// can reference it.
    static func resolveUsageMode() -> AntigravityUsageMode {
        let appSettings = (try? VibeBarLocalStore.readJSON(
            AppSettings.self,
            from: VibeBarLocalStore.settingsURL
        )) ?? .default
        return appSettings.antigravityUsageMode
    }

    /// Whether a process-list line looks like an AntiGravity language
    /// server. Thin delegate to `AntigravityLanguageServerClient` so the
    /// parser tests keep their original `AntigravityQuotaAdapter` entry
    /// point now that the probe logic lives in the shared client.
    static func matchesAntigravityProcess(lowercasedCommand command: String) -> Bool {
        AntigravityLanguageServerClient.matchesAntigravityProcess(lowercasedCommand: command)
    }

    private func mapError(_ error: Error?) -> QuotaError {
        if let qe = error as? QuotaError { return qe }
        return QuotaError.network(error?.localizedDescription ?? "Antigravity unreachable.")
    }
}

// MARK: - Response parsing

enum AntigravityResponseParser {
    struct Snapshot {
        var buckets: [QuotaBucket]
        var planName: String?
        var email: String?
        /// `modelOrAlias.model → label` for every config (e.g.
        /// `MODEL_PLACEHOLDER_M132 → "Gemini 3.5 Flash (High)"`),
        /// regardless of whether the config carried quota. Fed into
        /// `AntigravityModelLabelStore` so the cost scanner can resolve
        /// real model names and rates.
        var modelLabels: [String: String] = [:]

        func mergingIdentity(_ identity: Snapshot?) -> Snapshot {
            guard let identity else { return self }
            return Snapshot(
                buckets: buckets,
                planName: identity.planName ?? planName,
                email: identity.email ?? email,
                modelLabels: identity.modelLabels.isEmpty ? modelLabels : identity.modelLabels
            )
        }
    }

    /// Parse Antigravity 2.x's grouped quota summary into the four stable
    /// Vibe Bar lanes. Unknown cadences/groups and buckets without a usable
    /// remaining fraction are deliberately omitted instead of being reported
    /// as exhausted.
    static func parseQuotaSummary(data: Data) throws -> Snapshot {
        let response: AntigravityQuotaSummaryResponse
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            response = try decoder.decode(AntigravityQuotaSummaryResponse.self, from: data)
        } catch {
            throw QuotaError.parseFailure("Antigravity quota summary not parseable: \(error.localizedDescription)")
        }
        if let code = response.code, code.isError {
            throw QuotaError.network("Antigravity: \(response.message ?? code.label)")
        }

        guard let groups = response.resolvedGroups, !groups.isEmpty else {
            throw QuotaError.parseFailure("Antigravity quota summary had no groups.")
        }

        var bucketsBySlot: [QuotaSummarySlot: QuotaBucket] = [:]
        for group in groups {
            for payload in group.buckets ?? [] {
                guard payload.disabled != true,
                      let groupKind = quotaGroupKind(groupName: group.displayName, bucketId: payload.bucketId),
                      let cadence = quotaCadence(for: payload),
                      let remainingFraction = payload.resolvedRemainingFraction,
                      remainingFraction.isFinite
                else { continue }

                let slot = QuotaSummarySlot(group: groupKind, cadence: cadence)
                let candidate = quotaBucket(
                    slot: slot,
                    remainingFraction: remainingFraction,
                    resetAt: payload.resetTime.flatMap(parseDate)
                )
                if let current = bucketsBySlot[slot], current.usedPercent >= candidate.usedPercent {
                    continue
                }
                bucketsBySlot[slot] = candidate
            }
        }

        let buckets = QuotaSummarySlot.displayOrder.compactMap { bucketsBySlot[$0] }
        guard !buckets.isEmpty else {
            throw QuotaError.parseFailure("Antigravity quota summary had no usable 5-hour or weekly buckets.")
        }
        return Snapshot(buckets: buckets, planName: nil, email: nil)
    }

    static func parseUserStatus(data: Data) throws -> Snapshot {
        let response: AntigravityAPIResponse
        do {
            response = try JSONDecoder().decode(AntigravityAPIResponse.self, from: data)
        } catch {
            throw QuotaError.parseFailure("Antigravity response not parseable: \(error.localizedDescription)")
        }
        if let code = response.code, code.isError {
            throw QuotaError.network("Antigravity: \(response.message ?? code.label)")
        }
        guard let userStatus = response.userStatus else {
            throw QuotaError.parseFailure("Antigravity response had no userStatus envelope.")
        }

        var modelLabels: [String: String] = [:]
        for config in userStatus.cascadeModelConfigData?.clientModelConfigs ?? [] {
            if let rawModel = config.modelOrAlias?.model {
                let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { modelLabels[trimmed] = config.label }
            }
        }

        let plan = userStatus.userTier?.preferredName ?? userStatus.planStatus?.planInfo?.preferredName
        return Snapshot(buckets: [], planName: plan, email: userStatus.email, modelLabels: modelLabels)
    }

    static func parseDate(_ raw: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: raw) { return d }
        if let seconds = Double(raw) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    private static func quotaGroupKind(groupName: String?, bucketId: String?) -> QuotaSummaryGroupKind? {
        let value = "\(groupName ?? "") \(bucketId ?? "")".lowercased()
        if value.contains("gemini") { return .gemini }
        if value.contains("claude") || value.contains("gpt") || value.contains("3p-") {
            return .claudeGPT
        }
        return nil
    }

    private static func quotaCadence(for bucket: AntigravityQuotaSummaryBucket) -> QuotaSummaryCadence? {
        var candidates: Set<String> = []
        for rawValue in [bucket.bucketId, bucket.displayName, bucket.window].compactMap({ $0 }) {
            let normalized = rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
            guard !normalized.isEmpty else { continue }
            candidates.insert(normalized)
            if normalized.hasSuffix(" limit") {
                candidates.insert(String(normalized.dropLast(" limit".count)))
            }
        }
        let expanded = candidates.reduce(into: candidates) { result, candidate in
            for alias in sessionCadenceAliases.union(["weekly"])
                where candidate.hasSuffix("-\(alias)")
            {
                result.insert(alias)
            }
        }
        if !expanded.isDisjoint(with: sessionCadenceAliases) { return .fiveHour }
        if expanded.contains("weekly") { return .weekly }
        return nil
    }

    private static let sessionCadenceAliases: Set<String> = [
        "session", "5h", "5-hour", "five hour", "five-hour"
    ]

    private static func quotaBucket(
        slot: QuotaSummarySlot,
        remainingFraction: Double,
        resetAt: Date?
    ) -> QuotaBucket {
        let remaining = max(0, min(1, remainingFraction))
        return QuotaBucket(
            id: slot.id,
            title: slot.cadence == .fiveHour ? "5 Hours" : "Weekly",
            shortLabel: slot.shortLabel,
            usedPercent: (1 - remaining) * 100,
            resetAt: resetAt,
            rawWindowSeconds: slot.cadence == .fiveHour ? 18_000 : 604_800,
            groupTitle: slot.group.title
        )
    }
}

private enum QuotaSummaryGroupKind: Int, Hashable {
    case gemini
    case claudeGPT

    var title: String {
        switch self {
        case .gemini: return "Gemini Models"
        case .claudeGPT: return "Claude and GPT Models"
        }
    }
}

private enum QuotaSummaryCadence: Int, Hashable {
    case fiveHour
    case weekly
}

private struct QuotaSummarySlot: Hashable {
    let group: QuotaSummaryGroupKind
    let cadence: QuotaSummaryCadence

    static let displayOrder: [QuotaSummarySlot] = [
        QuotaSummarySlot(group: .gemini, cadence: .fiveHour),
        QuotaSummarySlot(group: .gemini, cadence: .weekly),
        QuotaSummarySlot(group: .claudeGPT, cadence: .fiveHour),
        QuotaSummarySlot(group: .claudeGPT, cadence: .weekly)
    ]

    var id: String {
        switch (group, cadence) {
        case (.gemini, .fiveHour): return "gemini_five_hour"
        case (.gemini, .weekly): return "gemini_weekly"
        case (.claudeGPT, .fiveHour): return "claude_gpt_five_hour"
        case (.claudeGPT, .weekly): return "claude_gpt_weekly"
        }
    }

    var shortLabel: String {
        switch (group, cadence) {
        case (.gemini, .fiveHour): return "G 5h"
        case (.gemini, .weekly): return "G wk"
        case (.claudeGPT, .fiveHour): return "C+G 5h"
        case (.claudeGPT, .weekly): return "C+G wk"
        }
    }
}

// MARK: - Wire types

private struct AntigravityQuotaSummaryResponse: Decodable {
    let code: AntigravityCodeValue?
    let message: String?
    let response: AntigravityQuotaSummaryPayload?
    let summary: AntigravityQuotaSummaryPayload?
    let groups: [AntigravityQuotaSummaryGroup]?

    var resolvedGroups: [AntigravityQuotaSummaryGroup]? {
        response?.groups ?? summary?.groups ?? groups
    }
}

private struct AntigravityQuotaSummaryPayload: Decodable {
    let groups: [AntigravityQuotaSummaryGroup]?
}

private struct AntigravityQuotaSummaryGroup: Decodable {
    let displayName: String?
    let buckets: [AntigravityQuotaSummaryBucket]?
}

private struct AntigravityQuotaSummaryBucket: Decodable {
    let bucketId: String?
    let displayName: String?
    let window: String?
    let remainingFraction: Double?
    let remaining: AntigravityQuotaSummaryRemaining?
    let resetTime: String?
    let disabled: Bool?

    var resolvedRemainingFraction: Double? {
        remainingFraction ?? remaining?.remainingFraction
    }
}

private struct AntigravityQuotaSummaryRemaining: Decodable {
    let remainingFraction: Double?

    private enum CodingKeys: String, CodingKey {
        case remainingFraction
        case oneofCase = "case"
        case value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(Double.self, forKey: .remainingFraction) {
            remainingFraction = value
        } else if try container.decodeIfPresent(String.self, forKey: .oneofCase) == "remainingFraction" {
            remainingFraction = try container.decodeIfPresent(Double.self, forKey: .value)
        } else {
            remainingFraction = nil
        }
    }
}

private struct AntigravityAPIResponse: Decodable {
    let code: AntigravityCodeValue?
    let message: String?
    let userStatus: AntigravityUserStatus?
}

private struct AntigravityUserStatus: Decodable {
    let email: String?
    let planStatus: AntigravityPlanStatus?
    let cascadeModelConfigData: AntigravityModelConfigData?
    let userTier: AntigravityUserTier?
}

private struct AntigravityUserTier: Decodable {
    let id: String?
    let name: String?

    var preferredName: String? {
        guard let value = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

private struct AntigravityPlanStatus: Decodable {
    let planInfo: AntigravityPlanInfo?
}

private struct AntigravityPlanInfo: Decodable {
    let planName: String?
    let planDisplayName: String?
    let displayName: String?
    let productName: String?
    let planShortName: String?

    var preferredName: String? {
        let candidates = [planDisplayName, displayName, productName, planName, planShortName]
        for candidate in candidates {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty { return value }
        }
        return nil
    }
}

private struct AntigravityModelConfigData: Decodable {
    let clientModelConfigs: [AntigravityModelConfig]?
}

private struct AntigravityModelConfig: Decodable {
    let label: String
    let modelOrAlias: AntigravityModelAlias?
}

private struct AntigravityModelAlias: Decodable {
    let model: String
}

/// AntiGravity's `code` field can be either a number or a string —
/// both shapes encode the same value space.
struct AntigravityCodeValue: Decodable {
    let raw: String

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let int = try? c.decode(Int.self) {
            raw = String(int)
        } else if let str = try? c.decode(String.self) {
            raw = str
        } else {
            raw = "0"
        }
    }

    var label: String {
        raw.lowercased() == "ok" ? "OK" : raw
    }

    var isOK: Bool {
        raw == "0" || raw.lowercased() == "ok"
    }

    var isError: Bool { !isOK }
}
