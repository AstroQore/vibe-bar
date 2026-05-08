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
/// 1. `/bin/ps -ax -o pid=,command=` → look for `language_server_macos`
///    with `--app_data_dir` containing `antigravity` (or path
///    contains `antigravity`).
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

    public init(
        timeout: TimeInterval = 8,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.timeout = timeout
        self.now = now
    }

    private static let processName = "language_server_macos"
    private static let userStatusPath =
        "/exa.language_server_pb.LanguageServerService/GetUserStatus"

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        guard MiscProviderSettings.current(for: .antigravity).allowsLocalProbeAccess else {
            throw QuotaError.noCredential
        }

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
            guard lower.contains(AntigravityQuotaAdapter.processName) else { continue }
            guard isAntigravityCommand(lower) else { continue }
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

    private func isAntigravityCommand(_ command: String) -> Bool {
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
            let modelId = config.modelOrAlias?.model ?? config.label
            var bucket = QuotaBucket(
                id: "antigravity.\(modelId)",
                title: config.label,
                shortLabel: AntigravityResponseParser.shortLabel(for: modelId),
                usedPercent: max(0, min(100, (1 - fraction) * 100)),
                resetAt: resetAt,
                rawWindowSeconds: nil
            )
            bucket.groupTitle = AntigravityResponseParser.groupTitle(for: modelId)
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

    private static func shortLabel(for modelId: String) -> String {
        let lower = modelId.lowercased()
        if lower.contains("claude") { return "Claude" }
        if lower.contains("flash-lite") { return "Lite" }
        if lower.contains("flash") { return "Flash" }
        if lower.contains("pro") { return "Pro" }
        return modelId
    }

    private static func groupTitle(for modelId: String) -> String? {
        let lower = modelId.lowercased()
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
