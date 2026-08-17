import Darwin
import Foundation

/// Reads AntiGravity's live quota from the installed `agy` CLI when the
/// desktop language server is absent or exposes only a partial quota summary.
///
/// `agy` hosts the same tokenless loopback HTTPS service while its TUI is
/// alive. Vibe Bar never sends a prompt or scrapes the TUI: it keeps a PTY
/// drained, probes the local ports, reads the quota RPCs, then terminates only
/// the process it launched. An already-running user-owned `agy` is reused and
/// never stopped.
enum AntigravityCLIQuotaFetcher {
    private static let readinessTimeout: TimeInterval = 15
    private static let pollIntervalNanoseconds: UInt64 = 350_000_000

    static func fetch() async throws -> AntigravityResponseParser.Snapshot {
        var lastError: Error?

        for pid in await runningAgyPIDs() {
            do {
                return try await fetch(pid: pid, deadline: Date().addingTimeInterval(2.5))
            } catch {
                lastError = error
            }
        }

        guard let binary = resolveBinary() else {
            throw lastError ?? QuotaError.noCredential
        }
        let process = try AntigravityCLIQuotaProcess.launch(binary: binary)
        defer { process.stop() }

        // Start the readiness window only once the launched process exists, so
        // probing stale user-owned `agy` processes above never eats into it.
        return try await fetch(
            pid: process.pid,
            deadline: Date().addingTimeInterval(readinessTimeout),
            isRunning: { process.isRunning },
            drainOutput: { process.drainOutput() }
        )
    }

    static func parseAgyPIDs(_ output: String) -> [Int] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2,
                  let pid = Int(parts[0]),
                  ["agy", "antigravity-cli", "antigravity_cli"].contains(
                      URL(fileURLWithPath: String(parts[1])).lastPathComponent.lowercased()
                  )
            else { return nil }
            return pid
        }
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

    private static func runningAgyPIDs() async -> [Int] {
        guard let result = try? await ProcessRunner.run(
            binary: "/bin/ps",
            arguments: ["-ax", "-o", "pid=,comm="],
            timeout: 2,
            label: "antigravity-agy-ps"
        ) else { return [] }
        return parseAgyPIDs(result.stdout)
    }

    private static func fetch(
        pid: Int,
        deadline: Date,
        isRunning: () -> Bool = { true },
        drainOutput: () -> Void = {}
    ) async throws -> AntigravityResponseParser.Snapshot {
        let client = AntigravityLanguageServerClient(timeout: 2)
        var lastError: Error?

        while Date() < deadline, isRunning() {
            drainOutput()
            let ports = (try? await client.listeningPorts(pid: pid)) ?? []
            for port in ports {
                for scheme in ["https", "http"] {
                    let endpoint = AntigravityLanguageServerClient.Endpoint(
                        scheme: scheme,
                        port: port,
                        csrfToken: ""
                    )
                    do {
                        return try await AntigravityQuotaAdapter.fetchLocalSnapshot { path, body in
                            try await client.postLocal(endpoint: endpoint, path: path, body: body)
                        }
                    } catch {
                        lastError = error
                    }
                }
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        throw lastError ?? QuotaError.noCredential
    }
}

private final class AntigravityCLIQuotaProcess: @unchecked Sendable {
    let pid: Int
    private let process: Process
    private let primaryFD: Int32
    private let primaryHandle: FileHandle
    private let secondaryHandle: FileHandle
    private let lock = NSLock()
    private var stopped = false

    private init(
        process: Process,
        primaryFD: Int32,
        primaryHandle: FileHandle,
        secondaryHandle: FileHandle
    ) {
        self.process = process
        self.pid = Int(process.processIdentifier)
        self.primaryFD = primaryFD
        self.primaryHandle = primaryHandle
        self.secondaryHandle = secondaryHandle
    }

    static func launch(binary: String) throws -> AntigravityCLIQuotaProcess {
        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        var window = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primaryFD, &secondaryFD, nil, nil, &window) == 0 else {
            throw QuotaError.unknown("Could not open a PTY for agy.")
        }
        _ = fcntl(primaryFD, F_SETFL, O_NONBLOCK)

        let primaryHandle = FileHandle(fileDescriptor: primaryFD, closeOnDealloc: true)
        let secondaryHandle = FileHandle(fileDescriptor: secondaryFD, closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.currentDirectoryURL = URL(
            fileURLWithPath: RealHomeDirectory.path,
            isDirectory: true
        )
        var environment = ProcessInfo.processInfo.environment
        environment["PWD"] = RealHomeDirectory.path
        environment["TERM"] = "xterm-256color"
        process.environment = environment
        process.standardInput = secondaryHandle
        process.standardOutput = secondaryHandle
        process.standardError = secondaryHandle
        do {
            try process.run()
        } catch {
            try? primaryHandle.close()
            try? secondaryHandle.close()
            throw QuotaError.unknown("Could not launch agy: \(error.localizedDescription)")
        }
        return AntigravityCLIQuotaProcess(
            process: process,
            primaryFD: primaryFD,
            primaryHandle: primaryHandle,
            secondaryHandle: secondaryHandle
        )
    }

    var isRunning: Bool { process.isRunning }

    func drainOutput() {
        var buffer = [UInt8](repeating: 0, count: 8_192)
        for _ in 0..<32 {
            let count = read(primaryFD, &buffer, buffer.count)
            if count <= 0 { break }
        }
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()

        if process.isRunning {
            process.terminate()
        }
        try? primaryHandle.close()
        try? secondaryHandle.close()
    }

    deinit { stop() }
}
