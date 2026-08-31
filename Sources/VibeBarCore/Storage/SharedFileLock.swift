import Foundation

/// An advisory lock over one shared file, held across a read-modify-write.
///
/// `settings.json` has two writers in separate processes. Each one re-reads
/// the file before writing so the other's keys survive, but re-read and
/// rename are two steps: two writers can interleave between them and the
/// second one's merge is then based on a file that no longer exists. The
/// window is small and the loss is silent, which is the combination worth
/// spending a lock on.
///
/// `flock(2)` rather than a lock file with a pid in it: the kernel releases it
/// when the descriptor closes, including when the process dies, so there is no
/// stale lock to break and no liveness check to get wrong. It is advisory —
/// it binds the clients that ask for it, which is both of them.
public enum SharedFileLock {
    /// Run `body` while holding the lock named by `name` under `directory`.
    ///
    /// Failing to take the lock is not failing to write: a read-only or
    /// unusual filesystem should degrade to the unlocked behaviour that came
    /// before, not to losing the user's settings. The narrow race is worth
    /// closing; it is not worth a new way to fail.
    @discardableResult
    public static func withLock<T>(
        named name: String, in directory: URL, _ body: () throws -> T
    ) rethrows -> T {
        guard let descriptor = acquire(named: name, in: directory) else { return try body() }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        return try body()
    }

    private static func acquire(named name: String, in directory: URL) -> Int32? {
        let runDirectory = directory.appendingPathComponent("run", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: runDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let path = runDirectory.appendingPathComponent("\(name).lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return nil }
        // Blocking: the other holder has a file read, a merge and a rename to
        // do, and waiting for that is the entire point.
        guard flock(descriptor, LOCK_EX) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }
}
