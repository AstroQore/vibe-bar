import Foundation

/// Lightweight async wrapper around `Process`.
///
/// Used by adapters/helpers that need to shell out: the AntiGravity
/// local probe (`/bin/ps`, `/usr/sbin/lsof`) and the Gemini keepalive
/// helper. The implementation is intentionally minimal compared to
/// codexbar's SubprocessRunner: no process-group escalation and only
/// caller-supplied environment overrides.
public enum ProcessRunner {
    public struct Result: Sendable {
        public let stdout: String
        public let stderr: String
        public let terminationStatus: Int32
    }

    public enum Error: Swift.Error, LocalizedError {
        case binaryNotFound(String)
        case launchFailed(String)
        case timedOut(String)

        public var errorDescription: String? {
            switch self {
            case let .binaryNotFound(path): return "Binary not found: \(path)"
            case let .launchFailed(msg):    return "Process launch failed: \(msg)"
            case let .timedOut(label):      return "Process timed out: \(label)"
            }
        }
    }

    /// Run `binary` with `arguments`, capture stdout/stderr, kill
    /// the child if it exceeds `timeout`. Returns even when the
    /// process exits non-zero — adapters decide what to do with the
    /// status code.
    public static func run(
        binary: String,
        arguments: [String],
        timeout: TimeInterval = 5,
        label: String = "process",
        environment: [String: String]? = nil
    ) async throws -> Result {
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw Error.binaryNotFound(binary)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = nil

        do {
            try process.run()
        } catch {
            throw Error.launchFailed("\(error)")
        }

        let killTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning { process.terminate() }
        }

        let outData = await readPipe(stdout)
        let errData = await readPipe(stderr)
        process.waitUntilExit()
        killTask.cancel()

        return Result(
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            terminationStatus: process.terminationStatus
        )
    }

    private static func readPipe(_ pipe: Pipe) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var data = Data()
                while true {
                    do {
                        guard let chunk = try pipe.fileHandleForReading.read(upToCount: 64 * 1024),
                              !chunk.isEmpty else { break }
                        data.append(chunk)
                    } catch {
                        break
                    }
                }
                continuation.resume(returning: data)
            }
        }
    }
}
