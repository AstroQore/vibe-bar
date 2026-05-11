import Foundation

/// Kiro usage adapter.
///
/// Kiro currently exposes plan usage through the local `kiro-cli`.
/// Users sign in with `kiro-cli login`; Vibe Bar validates `whoami`
/// and then runs `/usage` through non-interactive chat mode.
public struct KiroQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .kiro

    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        let settings = MiscProviderSettings.current(for: .kiro)
        guard settings.allowsLocalProbeAccess else {
            throw QuotaError.noCredential
        }

        do {
            let whoami = try await KiroCLIRunner.run(
                arguments: ["whoami"],
                timeout: 8,
                idleTimeout: 5
            )
            try KiroResponseParser.validateWhoAmI(
                stdout: whoami.stdout,
                stderr: whoami.stderr,
                terminationStatus: whoami.terminationStatus
            )
            let usage = try await KiroCLIRunner.run(
                arguments: ["chat", "--no-interactive", "/usage"],
                timeout: 20,
                idleTimeout: 10
            )
            let snapshot = try KiroResponseParser.parse(output: usage.stdout + "\n" + usage.stderr, now: now())
            return AccountQuota(
                accountId: account.id,
                tool: .kiro,
                buckets: snapshot.buckets,
                plan: snapshot.planName,
                email: account.email,
                queriedAt: now(),
                error: nil
            )
        } catch KiroResponseParser.KiroError.notLoggedIn {
            throw QuotaError.needsLogin
        } catch KiroResponseParser.KiroError.cliFailed {
            throw QuotaError.noCredential
        } catch KiroCLIRunner.Error.cliNotFound {
            throw QuotaError.noCredential
        } catch KiroCLIRunner.Error.timeout {
            throw QuotaError.network("Kiro CLI timed out.")
        } catch let error as KiroCLIRunner.Error {
            throw QuotaError.network("Kiro CLI launch failed: \(error.localizedDescription)")
        } catch let error as KiroResponseParser.KiroError {
            switch error {
            case .parseError:
                throw QuotaError.parseFailure("Kiro usage output was not recognized.")
            case .notLoggedIn:
                throw QuotaError.needsLogin
            case .cliFailed:
                throw QuotaError.noCredential
            }
        } catch let error as ProcessRunner.Error {
            switch error {
            case .binaryNotFound:
                throw QuotaError.noCredential
            case .timedOut:
                throw QuotaError.network("Kiro CLI timed out.")
            case .launchFailed(let message):
                throw QuotaError.network("Kiro CLI launch failed: \(message)")
            }
        } catch let error as QuotaError {
            throw error
        } catch {
            throw QuotaError.parseFailure("Kiro usage output was not recognized.")
        }
    }
}

enum KiroResponseParser {
    enum KiroError: Error {
        case notLoggedIn
        case cliFailed
        case parseError(String)
    }

    struct Snapshot {
        var buckets: [QuotaBucket]
        var planName: String?
    }

    static func validateWhoAmI(stdout: String, stderr: String, terminationStatus: Int32) throws {
        let combined = stripANSI(stdout + "\n" + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = combined.lowercased()
        if lower.contains("not logged in") ||
            lower.contains("login required") ||
            lower.contains("kiro-cli login") {
            throw KiroError.notLoggedIn
        }
        guard terminationStatus == 0, !combined.isEmpty else {
            throw KiroError.cliFailed
        }
    }

    static func parse(output: String, now: Date) throws -> Snapshot {
        let text = stripANSI(output).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw KiroError.parseError("Empty Kiro output.")
        }
        let lower = text.lowercased()
        if lower.contains("kiro-cli login") ||
            lower.contains("login --use-device-flow") ||
            lower.contains("not logged in") ||
            lower.contains("login required") ||
            lower.contains("failed to initialize auth portal") ||
            lower.contains("oauth error") {
            throw KiroError.notLoggedIn
        }
        if lower.contains("could not retrieve usage") ||
            lower.contains("dispatch failure") {
            throw KiroError.parseError("Kiro CLI warning output.")
        }

        let plan = parsePlan(text)
        let usage = parseUsage(text, now: now)
        let managedPlan = lower.contains("managed by admin") ||
            lower.contains("managed by organization")

        guard usage != nil || managedPlan else {
            throw KiroError.parseError("No recognizable usage patterns in Kiro output.")
        }

        let primaryUsed = usage?.used ?? 0
        let primaryTotal = usage?.total ?? 0
        let primaryPercent: Double = {
            if let percent = usage?.percent { return percent }
            guard primaryTotal > 0 else { return 0 }
            return primaryUsed / primaryTotal * 100
        }()

        var buckets: [QuotaBucket] = [
            QuotaBucket(
                id: "kiro.credits",
                title: "Credits",
                shortLabel: "Credits",
                usedPercent: primaryPercent,
                resetAt: usage?.resetAt,
                groupTitle: "\(money(primaryUsed)) / \(money(primaryTotal)) covered"
            )
        ]

        if let bonus = parseBonus(text, now: now) {
            buckets.append(QuotaBucket(
                id: "kiro.bonus",
                title: "Bonus Credits",
                shortLabel: "Bonus",
                usedPercent: bonus.total > 0 ? bonus.used / bonus.total * 100 : 0,
                resetAt: bonus.expiryDays.map { now.addingTimeInterval(TimeInterval($0 * 86_400)) },
                groupTitle: "\(money(bonus.used)) / \(money(bonus.total)) credits"
            ))
        }

        return Snapshot(buckets: buckets, planName: plan)
    }

    private static func parsePlan(_ text: String) -> String? {
        if let plan = firstMatch(#"(?m)^\s*Plan:\s*(.+?)\s*$"#, in: text) {
            return plan.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let plan = firstMatch(#"(?m)Estimated\s+Usage\s*\|\s*resets\s+on\s+[^|]+\|\s*([^\n|]+)"#, in: text) {
            return plan.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let plan = firstMatch(#"\|\s*([^|]*KIRO[^|]*?)\s*\|"#, in: text) {
            return plan.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func parseUsage(_ text: String, now: Date) -> (used: Double, total: Double, percent: Double?, resetAt: Date?)? {
        guard let usageMatch = firstMatch(
            #"\(([0-9]+(?:\.[0-9]+)?)\s+of\s+([0-9]+(?:\.[0-9]+)?)\s+covered in plan\)"#,
            in: text,
            captureCount: 2
        ) else {
            return nil
        }
        let used = Double(usageMatch[0]) ?? 0
        let total = Double(usageMatch[1]) ?? 0
        let percent = firstMatch(#"([0-9]+(?:\.[0-9]+)?)\s*%"#, in: text).flatMap(Double.init)
        let resetAt = parseResetDate(in: text, now: now)
        return (used, total, percent, resetAt)
    }

    private static func parseBonus(_ text: String, now: Date) -> (used: Double, total: Double, expiryDays: Int?)? {
        guard let match = firstMatch(
            #"Bonus credits:\s*([0-9]+(?:\.[0-9]+)?)/([0-9]+(?:\.[0-9]+)?)\s+credits used(?:,\s*expires in\s*([0-9]+)\s+days?)?"#,
            in: text,
            captureCount: 3
        ) else {
            return nil
        }
        return (
            Double(match[0]) ?? 0,
            Double(match[1]) ?? 0,
            match.count > 2 ? Int(match[2]) : nil
        )
    }

    private static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        firstMatch(pattern, in: text, captureCount: 1)?.first
    }

    private static func firstMatch(_ pattern: String, in text: String, captureCount: Int) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsrange) else { return nil }
        var captures: [String] = []
        for index in 1...captureCount {
            let range = match.range(at: index)
            guard range.location != NSNotFound,
                  let swiftRange = Range(range, in: text) else {
                captures.append("")
                continue
            }
            captures.append(String(text[swiftRange]))
        }
        return captures
    }

    private static func nextDate(month: Int, day: Int, now: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        var components = calendar.dateComponents([.year], from: now)
        components.month = month
        components.day = day
        components.hour = 0
        components.minute = 0
        components.second = 0
        guard var date = calendar.date(from: components) else { return nil }
        if date < now,
           let nextYear = calendar.date(byAdding: .year, value: 1, to: date) {
            date = nextYear
        }
        return date
    }

    private static func parseResetDate(in text: String, now: Date) -> Date? {
        if let isoDate = firstMatch(#"resets on\s+([0-9]{4}-[0-9]{2}-[0-9]{2})"#, in: text) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: isoDate) { return date }
        }
        return firstMatch(#"resets on\s+([0-9]{1,2})/([0-9]{1,2})"#, in: text, captureCount: 2)
            .flatMap { components -> Date? in
                guard let month = Int(components[0]), let day = Int(components[1]) else { return nil }
                return nextDate(month: month, day: day, now: now)
            }
    }

    static func isUsageOutputComplete(_ output: String) -> Bool {
        let stripped = stripANSI(output).lowercased()
        return stripped.contains("covered in plan") ||
            stripped.contains("resets on") ||
            stripped.contains("bonus credits") ||
            stripped.contains("plan:") ||
            stripped.contains("estimated usage") ||
            stripped.contains("managed by admin") ||
            stripped.contains("managed by organization") ||
            stripped.contains("could not retrieve usage") ||
            stripped.contains("dispatch failure") ||
            stripped.contains("kiro-cli login")
    }

    private static func money(_ value: Double) -> String {
        value.rounded(.towardZero) == value ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }
}

private enum KiroCLIRunner {
    struct Result: Sendable {
        let stdout: String
        let stderr: String
        let terminationStatus: Int32
    }

    enum Error: Swift.Error, LocalizedError {
        case cliNotFound
        case launchFailed(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                return "kiro-cli not found"
            case .launchFailed(let message):
                return message
            case .timeout:
                return "Kiro CLI timed out"
            }
        }
    }

    static func run(
        arguments: [String],
        timeout: TimeInterval,
        idleTimeout: TimeInterval
    ) async throws -> Result {
        guard let binary = executable(named: "kiro-cli") else {
            throw Error.cliNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        final class ActivityState: @unchecked Sendable {
            private let lock = NSLock()
            private var stdout = Data()
            private var stderr = Data()
            private var lastActivityAt = Date()
            private var receivedOutput = false

            func appendStdout(_ data: Data) {
                lock.lock()
                defer { lock.unlock() }
                stdout.append(data)
                lastActivityAt = Date()
                receivedOutput = true
            }

            func appendStderr(_ data: Data) {
                lock.lock()
                defer { lock.unlock() }
                stderr.append(data)
                lastActivityAt = Date()
                receivedOutput = true
            }

            func snapshot() -> (stdout: Data, stderr: Data, lastActivityAt: Date, receivedOutput: Bool) {
                lock.lock()
                defer { lock.unlock() }
                return (stdout, stderr, lastActivityAt, receivedOutput)
            }
        }

        let state = ActivityState()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { state.appendStdout(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { state.appendStderr(data) }
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try process.run()
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: Error.launchFailed(error.localizedDescription))
                    return
                }

                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning {
                    let snapshot = state.snapshot()
                    let combined = snapshot.stdout.utf8String + "\n" + snapshot.stderr.utf8String
                    if Date() >= deadline {
                        process.terminate()
                        process.waitUntilExit()
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        continuation.resume(throwing: Error.timeout)
                        return
                    }
                    if snapshot.receivedOutput,
                       Date().timeIntervalSince(snapshot.lastActivityAt) >= idleTimeout,
                       KiroResponseParser.isUsageOutputComplete(combined) {
                        process.terminate()
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }

                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                if process.isRunning { process.terminate() }
                process.waitUntilExit()

                var output = state.snapshot()
                output.stdout.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                output.stderr.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: Result(
                    stdout: output.stdout.utf8String,
                    stderr: output.stderr.utf8String,
                    terminationStatus: process.terminationStatus
                ))
            }
        }
    }

    private static func executable(named name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let searchDirs = path.split(separator: ":").map(String.init) + [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            URL(fileURLWithPath: RealHomeDirectory.path)
                .appendingPathComponent(".local/bin")
                .path
        ]
        for dir in searchDirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

private extension Data {
    var utf8String: String {
        String(data: self, encoding: .utf8) ?? ""
    }
}
