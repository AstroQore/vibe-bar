import Foundation

/// Google AntiGravity (local language-server) usage adapter.
///
/// Auth flow has no remote credential — we discover the locally
/// running AntiGravity language-server process, parse its CSRF
/// tokens out of the command line, find its listening TCP ports
/// via lsof, then POST to a localhost HTTPS endpoint protected by
/// `X-Codeium-Csrf-Token`.
///
/// Step-by-step:
/// 1. `/bin/ps -ax -o pid=,command=` → look for any `language_server`
///    process with `--app_data_dir` containing `antigravity` (or
///    path contains `antigravity`). AntiGravity IDE 1.x shipped the
///    binary as `language_server_macos`; v2.0.x renamed it to plain
///    `language_server`. The substring match here covers both.
/// 2. From that command line, extract `--csrf_token`,
///    `--extension_server_port`, `--extension_server_csrf_token`.
/// 3. `/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -a -p <pid>` → set
///    of listening ports.
/// 4. Try the language-server endpoints first
///    (`https://127.0.0.1:<port>` with the language-server CSRF),
///    fall back to the extension-server endpoint
///    (`http://127.0.0.1:<extension_port>` with the extension CSRF
///    when present).
/// 5. POST `/exa.language_server_pb.LanguageServerService/GetUserStatus`
///    with `{}` body, `Content-Type: application/json`,
///    `Connect-Protocol-Version: 1`, `X-Codeium-Csrf-Token: <token>`.
/// 6. Parse the response into per-model `QuotaBucket`s and the
///    plan name from `userTier.name` or `planStatus.planInfo`.
///
/// `URLSessionDelegate` accepts the language server's self-signed
/// cert, but only when the protection-space host is exactly
/// `127.0.0.1` or `localhost` — codexbar's
/// `LocalhostTrustPolicy.shouldAcceptServerTrust` is the same.
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

    /// Substring that every AntiGravity language-server process name
    /// must contain. AntiGravity IDE 1.x shipped the binary as
    /// `language_server_macos`; v2.0.x renamed it to plain
    /// `language_server`. The loose substring works for both — the
    /// `isAntigravityCommand` filter below narrows it to the right
    /// process when other vendors ship a `language_server` of their
    /// own.
    private static let processNameSubstring = "language_server"
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
        let process = try await detectProcessInfo()
        let ports = try await listeningPorts(pid: process.pid)
        let endpoints = endpointCandidates(for: process, ports: ports)
        let body = Data("{}".utf8)

        var lastError: Error?
        for endpoint in endpoints {
            do {
                let data = try await postLocal(
                    endpoint: endpoint,
                    path: AntigravityQuotaAdapter.userStatusPath,
                    body: body
                )
                let snapshot = try AntigravityResponseParser.parseUserStatus(data: data)
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

    // MARK: - Process detection

    struct ProcessInfo {
        let pid: Int
        let csrfToken: String
        let extensionPort: Int?
        let extensionCSRFToken: String?
    }

    private func detectProcessInfo() async throws -> ProcessInfo {
        let result: ProcessRunner.Result
        do {
            result = try await ProcessRunner.run(
                binary: "/bin/ps",
                arguments: ["-ax", "-o", "pid=,command="],
                timeout: timeout,
                label: "antigravity-ps"
            )
        } catch {
            throw QuotaError.unknown("Could not list processes: \(error.localizedDescription)")
        }

        var foundAntigravity = false
        for line in result.stdout.split(separator: "\n") {
            guard let match = AntigravityProcessLine.parse(String(line)) else { continue }
            let lower = match.command.lowercased()
            guard Self.matchesAntigravityProcess(lowercasedCommand: lower) else { continue }
            foundAntigravity = true
            guard let csrf = extractFlag("--csrf_token", from: match.command) else { continue }
            return ProcessInfo(
                pid: match.pid,
                csrfToken: csrf,
                extensionPort: extractFlag("--extension_server_port", from: match.command).flatMap { Int($0) },
                extensionCSRFToken: extractFlag("--extension_server_csrf_token", from: match.command)
            )
        }
        if foundAntigravity {
            throw QuotaError.parseFailure("Antigravity is running but its CSRF token is missing — restart Antigravity and retry.")
        }
        throw QuotaError.noCredential
    }

    /// Whether a process-list line looks like an AntiGravity language
    /// server. Combines the loose `language_server` binary-name match
    /// with the AntiGravity-specific path or flag check so unrelated
    /// vendors that also ship a `language_server` binary don't get
    /// picked up. Exposed at the package level so the parser tests can
    /// lock in v1.x → v2.0.x process-name compatibility without going
    /// through `ProcessRunner`.
    static func matchesAntigravityProcess(lowercasedCommand command: String) -> Bool {
        guard command.contains(processNameSubstring) else { return false }
        return isAntigravityCommand(command)
    }

    static func isAntigravityCommand(_ command: String) -> Bool {
        if command.contains("--app_data_dir") && command.contains("antigravity") { return true }
        if command.contains("/antigravity/") || command.contains("\\antigravity\\") { return true }
        return false
    }

    private func extractFlag(_ flag: String, from command: String) -> String? {
        let pattern = "\(NSRegularExpression.escapedPattern(for: flag))[=\\s]+([^\\s]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        guard let match = regex.firstMatch(in: command, options: [], range: range),
              let captured = Range(match.range(at: 1), in: command) else {
            return nil
        }
        return String(command[captured])
    }

    // MARK: - Port detection

    private func listeningPorts(pid: Int) async throws -> [Int] {
        let lsof = ["/usr/sbin/lsof", "/usr/bin/lsof"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        guard let lsof else {
            throw QuotaError.unknown("`lsof` not available; cannot probe Antigravity ports.")
        }
        let result: ProcessRunner.Result
        do {
            result = try await ProcessRunner.run(
                binary: lsof,
                arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)],
                timeout: timeout,
                label: "antigravity-lsof"
            )
        } catch {
            throw QuotaError.unknown("lsof failed: \(error.localizedDescription)")
        }
        let ports = parseListeningPorts(result.stdout)
        guard !ports.isEmpty else {
            throw QuotaError.parseFailure("Antigravity is running but no listening ports found yet — wait a few seconds and retry.")
        }
        return ports
    }

    private func parseListeningPorts(_ output: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #":(\d+)\s+\(LISTEN\)"#) else { return [] }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        var ports: Set<Int> = []
        regex.enumerateMatches(in: output, options: [], range: range) { match, _, _ in
            guard let match,
                  let captured = Range(match.range(at: 1), in: output),
                  let port = Int(output[captured]) else { return }
            ports.insert(port)
        }
        return ports.sorted()
    }

    // MARK: - Endpoint candidates

    struct Endpoint: Equatable {
        let scheme: String
        let port: Int
        let csrfToken: String
    }

    private func endpointCandidates(for info: ProcessInfo, ports: [Int]) -> [Endpoint] {
        var endpoints: [Endpoint] = ports.map {
            Endpoint(scheme: "https", port: $0, csrfToken: info.csrfToken)
        }
        // Extension server is plain HTTP and may be on a separate
        // port with its own CSRF token. Append both shapes if we
        // have them.
        if let extPort = info.extensionPort {
            if let extCSRF = info.extensionCSRFToken,
               !endpoints.contains(where: { $0.port == extPort && $0.csrfToken == extCSRF }) {
                endpoints.append(Endpoint(scheme: "http", port: extPort, csrfToken: extCSRF))
            }
            if !endpoints.contains(where: { $0.port == extPort && $0.csrfToken == info.csrfToken }) {
                endpoints.append(Endpoint(scheme: "http", port: extPort, csrfToken: info.csrfToken))
            }
        }
        return endpoints
    }

    // MARK: - HTTP

    private func postLocal(
        endpoint: Endpoint,
        path: String,
        body: Data
    ) async throws -> Data {
        guard let url = URL(string: "\(endpoint.scheme)://127.0.0.1:\(endpoint.port)\(path)") else {
            throw QuotaError.unknown("Antigravity: invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(endpoint.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false

        let delegate = LocalhostSessionDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await delegate.data(for: request, session: session)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Antigravity: invalid response object")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw QuotaError.needsLogin
            }
            // The language server returns HTTP 500 with
            // `code: unknown` + `error getting token source` when
            // the user is signed out of AntiGravity itself. Surface
            // that as needsLogin so the misc card shows a sign-in
            // hint instead of a generic network error.
            if let body = String(data: data, encoding: .utf8),
               body.contains("token source") || body.contains("not authenticated") {
                throw QuotaError.needsLogin
            }
            throw QuotaError.network("Antigravity HTTP \(http.statusCode)")
        }
        return data
    }

    private func mapError(_ error: Error?) -> QuotaError {
        if let qe = error as? QuotaError { return qe }
        return QuotaError.network(error?.localizedDescription ?? "Antigravity unreachable.")
    }
}

// MARK: - Process line parser

struct AntigravityProcessLine {
    let pid: Int
    let command: String

    static func parse(_ line: String) -> AntigravityProcessLine? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let pid = Int(parts[0]) else { return nil }
        return AntigravityProcessLine(pid: pid, command: String(parts[1]))
    }
}

// MARK: - Localhost trust policy

enum AntigravityLocalhostTrustPolicy {
    /// Returns `true` only for localhost / 127.0.0.1 + ServerTrust.
    /// Codexbar's policy verbatim.
    static func shouldAcceptServerTrust(
        host: String,
        authenticationMethod: String,
        hasServerTrust: Bool
    ) -> Bool {
        guard authenticationMethod == NSURLAuthenticationMethodServerTrust else { return false }
        let normalised = host.lowercased()
        guard normalised == "127.0.0.1" || normalised == "localhost" else { return false }
        return hasServerTrust
    }
}

private final class LocalhostSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    func data(
        for request: URLRequest,
        session: URLSession
    ) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, let response else {
                    continuation.resume(throwing: QuotaError.network("Antigravity: empty response"))
                    return
                }
                continuation.resume(returning: (data, response))
            }
            task.resume()
        }
    }

    private func challengeResult(
        _ challenge: URLAuthenticationChallenge
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard AntigravityLocalhostTrustPolicy.shouldAcceptServerTrust(
            host: space.host,
            authenticationMethod: space.authenticationMethod,
            hasServerTrust: space.serverTrust != nil
        ), let trust = space.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        challengeResult(challenge)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        challengeResult(challenge)
    }
}

// MARK: - Response parsing

enum AntigravityResponseParser {
    struct Snapshot {
        var buckets: [QuotaBucket]
        var planName: String?
        var email: String?
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
        for config in modelConfigs {
            guard let quota = config.quotaInfo,
                  let fraction = quota.remainingFraction else { continue }
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
        return Snapshot(buckets: buckets, planName: plan, email: userStatus.email)
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
