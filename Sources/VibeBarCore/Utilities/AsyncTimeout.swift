import Foundation

/// Runs an async operation with a hard wall-clock bound.
///
/// Unlike a `withTaskGroup`-based timeout (which still awaits the losing
/// child at scope exit, so it can't actually abandon a non-cancellable
/// hang), this races the operation against a sleep on *unstructured*
/// tasks. Whichever finishes first resolves the result; on timeout the
/// operation is cancelled best-effort and otherwise left to finish off to
/// the side, so the caller is never blocked by a stuck operation.
public enum AsyncTimeout {
    public enum Outcome<T: Sendable>: Sendable {
        case completed(T)
        case timedOut
    }

    public static func run<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async -> T
    ) async -> Outcome<T> {
        let gate = ResumeGate()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome<T>, Never>) in
            let work = Task.detached(priority: .utility) {
                let value = await operation()
                if gate.claim() { continuation.resume(returning: .completed(value)) }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if gate.claim() {
                    work.cancel()
                    continuation.resume(returning: .timedOut)
                }
            }
        }
    }
}

/// One-shot gate so exactly one of {operation finished, timeout fired}
/// resumes the continuation. The loser is dropped; the abandoned operation
/// keeps running to completion off to the side.
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
