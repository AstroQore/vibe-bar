import XCTest
@testable import VibeBarCore

/// The queue that holds a debounced control's last change until a moment the
/// app can observe.
@MainActor
final class PendingEditQueueTests: XCTestCase {
    func testTwoControlsEditedInOneWindowBothSurvive() {
        // The regression that came back three review rounds running: a single
        // pending slot meant the second control to queue silently dropped the
        // first one's write. Keying the queue is what makes that impossible.
        let queue = PendingEditQueue()
        var written: [String] = []
        queue.schedule("color") { written.append("color") }
        queue.schedule("threshold") { written.append("threshold") }
        XCTAssertEqual(queue.pendingKeys, ["color", "threshold"])

        queue.flush()
        XCTAssertEqual(written, ["color", "threshold"])
        XCTAssertTrue(queue.pendingKeys.isEmpty)
    }

    func testEveryOneOfManyControlsSurvivesOneWindow() {
        // The general shape, so a fourth control added later cannot quietly
        // reintroduce the bug.
        let queue = PendingEditQueue()
        var written: Set<String> = []
        let keys = (0..<8).map { "control.\($0)" }
        for key in keys {
            queue.schedule(key) { written.insert(key) }
        }
        XCTAssertEqual(queue.pendingKeys, keys)
        queue.flush()
        XCTAssertEqual(written, Set(keys))
    }

    func testOneControlMovingKeepsOnlyItsNewestValue() {
        // Within a control, the newest value is the only one that matters —
        // a colour drag must not write every frame it passed through.
        let queue = PendingEditQueue()
        var written: [Int] = []
        for value in 1...5 {
            queue.schedule("color") { written.append(value) }
        }
        XCTAssertEqual(queue.pendingKeys, ["color"])
        queue.flush()
        XCTAssertEqual(written, [5])
    }

    func testAControlKeepsItsPlaceWhenItQueuesAgain() {
        let queue = PendingEditQueue()
        var written: [String] = []
        queue.schedule("a") { written.append("a-old") }
        queue.schedule("b") { written.append("b") }
        queue.schedule("a") { written.append("a-new") }
        queue.flush()
        XCTAssertEqual(written, ["a-new", "b"])
    }

    func testFlushingAnEmptyQueueDoesNothing() {
        let queue = PendingEditQueue()
        queue.flush()
        XCTAssertTrue(queue.pendingKeys.isEmpty)
    }

    func testAFlushFromInsideACommitDoesNotRecurse() {
        // Every other edit flushes first, and a queued write is itself an
        // edit — the queue empties before it runs so the re-entrant call
        // finds nothing rather than looping.
        let queue = PendingEditQueue()
        var runs = 0
        queue.schedule("self-flushing") {
            runs += 1
            queue.flush()
        }
        queue.flush()
        XCTAssertEqual(runs, 1)
    }

    func testAQueuedWriteLandsOnItsOwnAfterTheIdleWindow() async throws {
        let queue = PendingEditQueue(delay: .milliseconds(5))
        var written = false
        queue.schedule("color") { written = true }
        XCTAssertFalse(written, "not written while the user may still be moving")
        // Polled rather than slept through: a fixed sleep spends wall time on
        // a shared test timeline whether or not it is needed, and this suite
        // runs beside timing-sensitive ones.
        for _ in 0..<100 where !written {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(written, "written once the control went quiet")
        XCTAssertTrue(queue.pendingKeys.isEmpty)
    }
}
