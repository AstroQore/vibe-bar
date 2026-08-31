import XCTest
@testable import VibeBarCore

/// The lock exists to close one window: two writers that both re-read a file,
/// both merge onto what they read, and both rename — the second one's merge
/// having been based on a file that no longer exists.
final class SharedFileLockTests: XCTestCase {
    private var directory: URL!
    private var counter: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        counter = directory.appendingPathComponent("counter")
        try "0".write(to: counter, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    /// A read-modify-write with a gap in the middle, which is what a merge is.
    private func incrementUnderLock() {
        SharedFileLock.withLock(named: "counter", in: directory) {
            let value = Int(
                (try? String(contentsOf: counter, encoding: .utf8)) ?? "0"
            ) ?? 0
            // Wide enough that an unlocked version loses updates reliably.
            Thread.sleep(forTimeInterval: 0.002)
            try? "\(value + 1)".write(to: counter, atomically: true, encoding: .utf8)
        }
    }

    func testSerialisesConcurrentReadModifyWrites() throws {
        let rounds = 40
        DispatchQueue.concurrentPerform(iterations: rounds) { _ in incrementUnderLock() }

        let final = Int(try String(contentsOf: counter, encoding: .utf8))
        XCTAssertEqual(final, rounds, "an update was lost, so the lock is not excluding anything")
    }

    /// The control: the same work without the lock does lose updates, so the
    /// test above is measuring the lock and not the timing.
    func testTheSameWorkWithoutTheLockLosesUpdates() throws {
        let rounds = 40
        DispatchQueue.concurrentPerform(iterations: rounds) { _ in
            let value = Int((try? String(contentsOf: counter, encoding: .utf8)) ?? "0") ?? 0
            Thread.sleep(forTimeInterval: 0.002)
            try? "\(value + 1)".write(to: counter, atomically: true, encoding: .utf8)
        }
        let final = Int(try String(contentsOf: counter, encoding: .utf8))
        XCTAssertLessThan(final ?? .max, rounds)
    }

    /// A lock that cannot be taken must not stop the write: settings that
    /// cannot be saved is a worse outcome than a race that is already the
    /// behaviour everything shipped with until now.
    func testRunsTheBodyEvenWhenTheLockCannotBeTaken() {
        let unwritable = URL(fileURLWithPath: "/dev/null/nowhere", isDirectory: true)
        var ran = false
        SharedFileLock.withLock(named: "settings", in: unwritable) { ran = true }
        XCTAssertTrue(ran)
    }

    func testGivesBackWhatTheBodyReturns() {
        XCTAssertEqual(SharedFileLock.withLock(named: "value", in: directory) { 7 }, 7)
    }

    /// The claim that matters is cross-process and cross-language: the other
    /// writer is Vibe Bar Desktop, a separate Rust process. `flock(2)` is the
    /// same primitive from any language, and this checks that rather than
    /// assuming it — a foreign process must fail to take the lock while this
    /// one holds it, and succeed once it does not.
    func testAForeignProcessIsExcludedWhileWeHoldTheLock() throws {
        let lockPath = directory.appendingPathComponent("run/settings.lock").path
        func foreignAttempt() throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "python3", "-c",
                """
                import fcntl, os, sys
                fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    print("took")
                except OSError:
                    print("blocked")
                """,
                lockPath
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var whileHeld = ""
        SharedFileLock.withLock(named: "settings", in: directory) {
            whileHeld = (try? foreignAttempt()) ?? "error"
        }
        XCTAssertEqual(whileHeld, "blocked", "another process took the lock while we held it")
        XCTAssertEqual(try foreignAttempt(), "took", "the lock was not released")
    }

    /// The lock lives under `run/`, not next to the data.
    func testKeepsItsLockFileOutOfTheWay() {
        SharedFileLock.withLock(named: "settings", in: directory) {}
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("run/settings.lock").path
            )
        )
    }
}
