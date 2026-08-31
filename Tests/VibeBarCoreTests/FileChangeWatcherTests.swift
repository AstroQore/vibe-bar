import XCTest
@testable import VibeBarCore

/// Everything here writes atomically, so the case that matters is the one a
/// naive descriptor watch gets wrong: after a rename the path holds a new
/// inode, and a watcher still holding the old one goes quiet forever.
final class FileChangeWatcherTests: XCTestCase {
    private var directory: URL!
    private var file: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("settings.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    /// `Data.write(options: .atomic)` — the way every store here writes.
    private func writeAtomically(_ text: String) throws {
        try Data(text.utf8).write(to: file, options: [.atomic])
    }

    private func watcher(_ onChange: @escaping @Sendable () -> Void) -> FileChangeWatcher {
        FileChangeWatcher(url: file, debounceMilliseconds: 20, onChange: onChange)
    }

    func testReportsAnAtomicReplace() throws {
        try writeAtomically("{}")
        let changed = expectation(description: "change reported")
        let watcher = watcher { changed.fulfill() }
        watcher.start()
        defer { watcher.stop() }

        // Let the source arm before the write it is meant to see.
        Thread.sleep(forTimeInterval: 0.1)
        try writeAtomically(#"{"a":1}"#)

        wait(for: [changed], timeout: 3)
    }

    /// The one a descriptor watch fails: a second atomic write, after the
    /// first has already replaced the inode the watcher opened.
    func testKeepsReportingAfterTheInodeIsReplaced() throws {
        try writeAtomically("{}")
        let second = expectation(description: "second change reported")
        second.assertForOverFulfill = false
        let seen = OSAllocatedUnfairLockCounter()
        let watcher = watcher {
            if seen.increment() >= 2 { second.fulfill() }
        }
        watcher.start()
        defer { watcher.stop() }

        Thread.sleep(forTimeInterval: 0.1)
        try writeAtomically(#"{"a":1}"#)
        Thread.sleep(forTimeInterval: 0.2)
        try writeAtomically(#"{"a":2}"#)

        wait(for: [second], timeout: 3)
    }

    /// settings.json does not exist until something writes it, and a watcher
    /// started first still has to report that first write.
    func testReportsAFileThatDoesNotExistYet() throws {
        let created = expectation(description: "creation reported")
        created.assertForOverFulfill = false
        let watcher = watcher { created.fulfill() }
        watcher.start()
        defer { watcher.stop() }

        Thread.sleep(forTimeInterval: 0.1)
        try writeAtomically(#"{"a":1}"#)

        wait(for: [created], timeout: 3)
    }

    func testSaysNothingAfterBeingStopped() throws {
        try writeAtomically("{}")
        let quiet = expectation(description: "no change reported")
        quiet.isInverted = true
        let watcher = watcher { quiet.fulfill() }
        watcher.start()
        Thread.sleep(forTimeInterval: 0.1)
        watcher.stop()

        try writeAtomically(#"{"a":1}"#)
        wait(for: [quiet], timeout: 0.5)
    }

    /// A burst of writes is far fewer reloads than writes.
    ///
    /// Written in place rather than atomically, which is the only way this
    /// measures the debounce: an atomic write replaces the inode, the source
    /// cancels and re-arms, and that gap swallows a burst all by itself. The
    /// first version of this test used atomic writes and passed with the
    /// debounce removed entirely.
    ///
    /// And not *one* reload: the debounce promises at most one report per
    /// window, not that a burst finishes inside one. An exact count asserts
    /// how fast the machine is, which is how the first version passed here
    /// and failed on a slower CI runner.
    func testCoalescesABurstOfWrites() throws {
        try writeAtomically("{}")
        let counter = OSAllocatedUnfairLockCounter()
        let watcher = FileChangeWatcher(url: file, debounceMilliseconds: 300) {
            _ = counter.increment()
        }
        watcher.start()
        defer { watcher.stop() }

        Thread.sleep(forTimeInterval: 0.1)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let writes = 8
        for index in 0..<writes {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Data("{\"a\":\(index)}".utf8))
            try handle.synchronize()
            Thread.sleep(forTimeInterval: 0.01)
        }
        Thread.sleep(forTimeInterval: 1.0)

        let reports = counter.value
        XCTAssertGreaterThan(reports, 0, "a burst of writes was not reported at all")
        XCTAssertLessThan(
            reports, writes,
            "every write produced its own report, so nothing is being coalesced"
        )
    }
}

/// A counter the watcher's queue and the test can both touch.
final class OSAllocatedUnfairLockCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
