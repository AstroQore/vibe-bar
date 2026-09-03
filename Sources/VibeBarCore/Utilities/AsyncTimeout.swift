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
        let sleeper = SleeperBox()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome<T>, Never>) in
            let work = Task.detached(priority: .utility) {
                let value = await operation()
                if gate.claim() {
                    // The operation won the race: stop the sleeper instead of
                    // leaving a task parked for the rest of the budget. With a
                    // 300s per-provider budget and a refresh every few minutes
                    // those sleepers were otherwise permanently resident.
                    sleeper.cancel()
                    continuation.resume(returning: .completed(value))
                }
            }
            let timer = Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if gate.claim() {
                    work.cancel()
                    continuation.resume(returning: .timedOut)
                }
            }
            sleeper.adopt(timer)
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

/// Holds the sleeper task so the winning operation can cancel it. The
/// operation can finish before `adopt` runs (a synchronous-ish operation
/// resolves inside `withCheckedContinuation`), so a cancel that arrives
/// first is remembered and applied to whatever is adopted afterwards.
private final class SleeperBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func adopt(_ task: Task<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        if cancelled {
            task.cancel()
        } else {
            self.task = task
        }
    }

    func cancel() {
        lock.lock()
        let pending = task
        task = nil
        cancelled = true
        lock.unlock()
        pending?.cancel()
    }
}
