import Foundation

/// Shared client for talking to a locally-running AntiGravity language
/// server.
///
/// Discovers the server process (`/bin/ps`), parses its CSRF token and
/// extension flags out of the command line, finds its listening TCP
/// ports (`/usr/sbin/lsof`), builds candidate endpoints, and POSTs
/// ConnectRPC-style JSON to a localhost path guarded by
/// `X-Codeium-Csrf-Token`.
///
/// Extracted from `AntigravityQuotaAdapter` so two callers can share one
/// probe + transport:
///   1. live quota — `GetUserStatus` (`AntigravityQuotaAdapter`)
///   2. historical cost — `GetCascadeTrajectoryGeneratorMetadata`
///      (`AntigravityCascadeUsageFetcher`, used by `CostUsageScanner`
///      for the encrypted `.pb` conversations we can't decode offline)
///
/// The self-signed language-server cert is trusted only for
/// `127.0.0.1` / `localhost` (`AntigravityLocalhostTrustPolicy`).
struct AntigravityLanguageServerClient {
    let timeout: TimeInterval

    init(timeout: TimeInterval = 8) {
        self.timeout = timeout
    }

    struct ProcessInfo {
        let pid: Int
        let csrfToken: String
        let extensionPort: Int?
        let extensionCSRFToken: String?
    }

    struct Endpoint: Equatable {
        let scheme: String
        let port: Int
        let csrfToken: String
    }

    /// Substring that every AntiGravity language-server process name
    /// must contain. AntiGravity IDE 1.x shipped the binary as
    /// `language_server_macos`; v2.0.x renamed it to plain
    /// `language_server`. The loose substring works for both — the
    /// `isAntigravityCommand` filter below narrows it to the right
    /// process when other vendors ship a `language_server` of their own.
    private static let processNameSubstring = "language_server"

    // MARK: - High-level

    /// Detect the running server and return its candidate endpoints.
    /// Throws `QuotaError.noCredential` when Antigravity isn't running.
    func connectedEndpoints() async throws -> [Endpoint] {
        let process = try await detectProcessInfo()
        let ports = try await listeningPorts(pid: process.pid)
        return endpointCandidates(for: process, ports: ports)
    }

    // MARK: - Process detection

    func detectProcessInfo() async throws -> ProcessInfo {
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
    /// picked up.
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

    func listeningPorts(pid: Int) async throws -> [Int] {
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

    func parseListeningPorts(_ output: String) -> [Int] {
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

    func endpointCandidates(for info: ProcessInfo, ports: [Int]) -> [Endpoint] {
        var endpoints: [Endpoint] = ports.map {
            Endpoint(scheme: "https", port: $0, csrfToken: info.csrfToken)
        }
        // Extension server is plain HTTP and may be on a separate port
        // with its own CSRF token. Append both shapes if we have them.
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

    func postLocal(
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

        let delegate = AntigravityLocalhostSessionDelegate()
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
            // The language server returns HTTP 500 with `code: unknown`
            // + `error getting token source` when the user is signed out
            // of AntiGravity itself. Surface that as needsLogin so the
            // card shows a sign-in hint instead of a generic error.
            if let body = String(data: data, encoding: .utf8),
               body.contains("token source") || body.contains("not authenticated") {
                throw QuotaError.needsLogin
            }
            throw QuotaError.network("Antigravity HTTP \(http.statusCode)")
        }
        return data
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

private final class AntigravityLocalhostSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
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
