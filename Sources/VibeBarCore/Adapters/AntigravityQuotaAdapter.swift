import Foundation

/// Google AntiGravity (local language-server) live-quota adapter.
///
/// Auth flow has no remote credential — it discovers the locally
/// running AntiGravity language-server process, parses its CSRF tokens
/// and ports, then POSTs to a localhost HTTPS endpoint protected by
/// `X-Codeium-Csrf-Token`. The discovery + transport now live in the
/// shared `AntigravityLanguageServerClient`; this adapter only adds the
/// `GetUserStatus` call and maps the response into `QuotaBucket`s and
/// the plan name (`userTier.name` / `planStatus.planInfo`). The
/// cost-scanner reuses the same client for the
/// `GetCascadeTrajectoryGeneratorMetadata` call.
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
        let body = Data("{}".utf8)

        var lastError: Error?
        for endpoint in endpoints {
            do {
                let data = try await client.postLocal(
                    endpoint: endpoint,
                    path: AntigravityQuotaAdapter.userStatusPath,
                    body: body
                )
                let snapshot = try AntigravityResponseParser.parseUserStatus(data: data)
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

        let modelConfigs = userStatus.cascadeModelConfigData?.clientModelConfigs ?? []
        var buckets: [QuotaBucket] = []
        var modelLabels: [String: String] = [:]
        for config in modelConfigs {
            // Capture the id → label mapping for every config (even ones
            // without quota), so placeholder model ids in the cost data
            // can later be resolved to real names / rates.
            if let rawModel = config.modelOrAlias?.model {
                let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { modelLabels[trimmed] = config.label }
            }
            guard let quota = config.quotaInfo else { continue }
            // Google's wire format omits `remainingFraction` when the
            // model's quota is fully spent (proto3 zero-default). The
            // older guard dropped depleted models entirely, hiding the
            // exhausted state from the user. Treat a missing fraction
            // as 0 so the bucket still shows up (at 100% used) with
            // the reset countdown that Google does send. See the live
            // AntigravityQuotaWatcher-v2 panel — depleted models stay
            // visible there for exactly the same reason.
            let fraction = quota.remainingFraction ?? 0.0
            let resetAt = quota.resetTime.flatMap(parseDate)
            let modelId = normalizedModelID(label: config.label, rawModelID: config.modelOrAlias?.model)
            var bucket = QuotaBucket(
                id: modelId,
                title: config.label,
                shortLabel: AntigravityResponseParser.shortLabel(for: config.label, modelId: modelId),
                usedPercent: max(0, min(100, (1 - fraction) * 100)),
                resetAt: resetAt,
                rawWindowSeconds: nil
            )
            bucket.groupTitle = AntigravityResponseParser.groupTitle(for: config.label, modelId: modelId)
            buckets.append(bucket)
        }

        let plan = userStatus.userTier?.preferredName ?? userStatus.planStatus?.planInfo?.preferredName
        return Snapshot(buckets: buckets, planName: plan, email: userStatus.email, modelLabels: modelLabels)
    }

    private static func parseDate(_ raw: String) -> Date? {
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

    private static func normalizedModelID(label: String, rawModelID: String?) -> String {
        let trimmedRaw = rawModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedRaw, !trimmedRaw.isEmpty, !isPlaceholderModelID(trimmedRaw) {
            return trimmedRaw
        }
        let slug = slugModelLabel(label)
        return slug.isEmpty ? (trimmedRaw ?? "model") : slug
    }

    private static func isPlaceholderModelID(_ value: String) -> Bool {
        value.lowercased().hasPrefix("model_")
    }

    private static func slugModelLabel(_ label: String) -> String {
        let lower = label.lowercased()
        var scalars = String.UnicodeScalarView()
        var lastWasSeparator = false
        for scalar in lower.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar.value == 46 {
                scalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                scalars.append("-")
                lastWasSeparator = true
            }
        }
        return String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func shortLabel(for label: String, modelId: String) -> String {
        let lower = "\(label) \(modelId)".lowercased()
        if lower.contains("gpt-oss") { return "GPT-OSS" }
        if lower.contains("sonnet") { return "Sonnet" }
        if lower.contains("opus") { return "Opus" }
        if lower.contains("claude") { return "Claude" }
        if lower.contains("high") { return "High" }
        if lower.contains("medium") { return "Med" }
        if lower.contains("low") { return "Low" }
        if lower.contains("flash-lite") { return "Lite" }
        if lower.contains("flash") { return "Flash" }
        if lower.contains("pro") { return "Pro" }
        return modelId
    }

    private static func groupTitle(for label: String, modelId: String) -> String? {
        let lower = "\(label) \(modelId)".lowercased()
        if lower.contains("gpt-oss") { return "GPT-OSS" }
        if lower.contains("claude") { return "Claude" }
        if lower.contains("gemini") {
            if lower.contains("flash-lite") { return "Gemini Flash Lite" }
            if lower.contains("flash") { return "Gemini Flash" }
            return "Gemini Pro"
        }
        return nil
    }
}

// MARK: - Wire types

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
    let quotaInfo: AntigravityQuotaInfo?
}

private struct AntigravityModelAlias: Decodable {
    let model: String
}

private struct AntigravityQuotaInfo: Decodable {
    let remainingFraction: Double?
    let resetTime: String?
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
