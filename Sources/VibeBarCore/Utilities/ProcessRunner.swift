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

    /// Grace given to a child to honor SIGTERM before `run` escalates to
    /// SIGKILL once the `timeout` has elapsed.
    private static let killGraceNanoseconds: UInt64 = 500_000_000

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

        let execution = ProcessExecution(process: process, stdout: stdout, stderr: stderr)
        let collection = ProcessCollectionState()
        process.terminationHandler = { finished in
            collection.record(terminationStatus: finished.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            throw Error.launchFailed("\(error)")
        }

        Task.detached(priority: .userInitiated) {
            collection.record(stdout: Self.readPipe(execution.stdout))
        }
        Task.detached(priority: .userInitiated) {
            collection.record(stderr: Self.readPipe(execution.stderr))
        }
        let timeoutTask = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            } catch {
                return
            }
            guard collection.beginTermination(.timedOut) else { return }
            await execution.stop(graceNanoseconds: Self.killGraceNanoseconds)
            collection.finishTermination(.timedOut)
        }

        let outcome = await withTaskCancellationHandler {
            await collection.wait()
        } onCancel: {
            guard collection.beginTermination(.cancelled) else { return }
            Task.detached(priority: .utility) {
                await execution.stop(graceNanoseconds: Self.killGraceNanoseconds)
                collection.finishTermination(.cancelled)
            }
        }
        timeoutTask.cancel()

        switch outcome {
        case let .completed(stdout, stderr, terminationStatus):
            return Result(
                stdout: String(data: stdout, encoding: .utf8) ?? "",
                stderr: String(data: stderr, encoding: .utf8) ?? "",
                terminationStatus: terminationStatus
            )
        case .timedOut:
            throw Error.timedOut(label)
        case .cancelled:
            throw CancellationError()
        }
    }

    private static func readPipe(_ pipe: Pipe) -> Data {
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
        return data
    }
}

private final class ProcessExecution: @unchecked Sendable {
    let process: Process
    let stdout: Pipe
    let stderr: Pipe

    init(process: Process, stdout: Pipe, stderr: Pipe) {
        self.process = process
        self.stdout = stdout
        self.stderr = stderr
    }

    func stop(graceNanoseconds: UInt64) async {
        closePipes()
        if process.isRunning { process.terminate() }
        try? await Task.sleep(nanoseconds: graceNanoseconds)
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        for _ in 0..<10 where process.isRunning {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        closePipes()
    }

    private func closePipes() {
        for handle in [
            stdout.fileHandleForReading,
            stdout.fileHandleForWriting,
            stderr.fileHandleForReading,
            stderr.fileHandleForWriting,
        ] {
            try? handle.close()
        }
    }
}

private enum ProcessTerminationIntent: Sendable, Equatable {
    case timedOut
    case cancelled
}

private enum ProcessCollectionOutcome: Sendable {
    case completed(stdout: Data, stderr: Data, terminationStatus: Int32)
    case timedOut
    case cancelled
}

private final class ProcessCollectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout: Data?
    private var stderr: Data?
    private var terminationStatus: Int32?
    private var terminationIntent: ProcessTerminationIntent?
    private var outcome: ProcessCollectionOutcome?
    private var continuation: CheckedContinuation<ProcessCollectionOutcome, Never>?

    func record(stdout: Data) {
        record { self.stdout = stdout }
    }

    func record(stderr: Data) {
        record { self.stderr = stderr }
    }

    func record(terminationStatus: Int32) {
        record { self.terminationStatus = terminationStatus }
    }

    private func record(_ update: () -> Void) {
        let resolved = lock.withLock { () -> (CheckedContinuation<ProcessCollectionOutcome, Never>?, ProcessCollectionOutcome)? in
            guard outcome == nil, terminationIntent == nil else { return nil }
            update()
            guard let stdout, let stderr, let terminationStatus else { return nil }
            let completed = ProcessCollectionOutcome.completed(
                stdout: stdout,
                stderr: stderr,
                terminationStatus: terminationStatus
            )
            outcome = completed
            let waiter = continuation
            continuation = nil
            return (waiter, completed)
        }
        if let resolved { resolved.0?.resume(returning: resolved.1) }
    }

    func beginTermination(_ intent: ProcessTerminationIntent) -> Bool {
        lock.withLock {
            guard outcome == nil, terminationIntent == nil else { return false }
            terminationIntent = intent
            return true
        }
    }

    func finishTermination(_ intent: ProcessTerminationIntent) {
        let resolved = lock.withLock { () -> (CheckedContinuation<ProcessCollectionOutcome, Never>?, ProcessCollectionOutcome)? in
            guard outcome == nil, terminationIntent == intent else { return nil }
            let terminal: ProcessCollectionOutcome = intent == .timedOut ? .timedOut : .cancelled
            outcome = terminal
            let waiter = continuation
            continuation = nil
            return (waiter, terminal)
        }
        if let resolved { resolved.0?.resume(returning: resolved.1) }
    }

    func wait() async -> ProcessCollectionOutcome {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> ProcessCollectionOutcome? in
                if let outcome { return outcome }
                self.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}
