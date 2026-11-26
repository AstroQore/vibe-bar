import Foundation

/// Reads quota from the installed `agy` CLI by running its official `/usage`
/// command in print mode. The command answers locally with structured JSON
/// and spends no model turn, so nothing has to be scraped from a terminal.
enum AntigravityCLIQuotaFetcher {
    private static let timeout: TimeInterval = 30

    static func fetch() async throws -> AntigravityResponseParser.Snapshot {
        guard let binary = resolveBinary() else { throw QuotaError.noCredential }
        // agy resolves its sign-in and log directory from HOME, which a
        // launchd-started app does not always carry.
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = RealHomeDirectory.path
        let result: ProcessRunner.Result
        do {
            result = try await ProcessRunner.run(
                binary: binary,
                arguments: ["--print", "/usage", "--output-format", "json"],
                timeout: timeout,
                label: "antigravity-agy-usage",
                environment: environment,
                currentDirectory: RealHomeDirectory.path
            )
        } catch let error as ProcessRunner.Error {
            throw QuotaError.network("agy /usage failed: \(error.localizedDescription)")
        }
        guard result.terminationStatus == 0 || !result.stdout.isEmpty else {
            let detail = result.stderr.split(separator: "\n").last.map(String.init) ?? "exit \(result.terminationStatus)"
            throw QuotaError.network("agy /usage failed: \(SafeLog.sanitize(detail))")
        }
        return try AntigravityResponseParser.parseCLIUsage(data: Data(result.stdout.utf8))
    }

    static func resolveBinary(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = RealHomeDirectory.path
    ) -> String? {
        var candidates: [String] = []
        if let override = environment["ANTIGRAVITY_CLI_PATH"]?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !override.isEmpty {
            candidates.append(override)
        }
        candidates.append(
            URL(fileURLWithPath: homeDirectory, isDirectory: true)
                .appendingPathComponent(".local/bin/agy").path
        )
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            candidates.append(URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent("agy").path)
        }
        candidates.append(contentsOf: ["/opt/homebrew/bin/agy", "/usr/local/bin/agy"])

        var seen: Set<String> = []
        return candidates.first { candidate in
            guard seen.insert(candidate).inserted else { return false }
            return FileManager.default.isExecutableFile(atPath: candidate)
        }
    }
}
