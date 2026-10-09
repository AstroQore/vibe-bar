import XCTest
@testable import VibeBarCore

/// The Usage page's index sweep: due on first activation, throttled to the
/// Sessions page's ten minutes, one at a time, and always behind the
/// maintenance gate.
final class SessionIndexRefreshThrottleTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    func testRefreshesOnFirstActivationThenEveryTenMinutes() async {
        let clock = Clock()
        let throttle = SessionIndexRefreshThrottle(now: { clock.now })
        let gate = SessionIndexMaintenanceGate()
        let counter = Counter()

        let first = await throttle.refreshIfDue(gate: gate) { await counter.increment() }
        XCTAssertTrue(first, "an index with old rows is still re-scanned on activation")
        clock.advance(9 * 60)
        let tooSoon = await throttle.refreshIfDue(gate: gate) { await counter.increment() }
        XCTAssertFalse(tooSoon)
        clock.advance(61)
        let due = await throttle.refreshIfDue(gate: gate) { await counter.increment() }
        XCTAssertTrue(due)
        let count = await counter.value
        XCTAssertEqual(count, 2)
        XCTAssertEqual(SessionIndexRefreshThrottle.defaultMinimumInterval, 600)
    }

    func testWaitsForTheMaintenanceGate() async throws {
        let throttle = SessionIndexRefreshThrottle()
        let gate = SessionIndexMaintenanceGate()
        let counter = Counter()
        try await gate.acquire()
        let sweep = Task { await throttle.refreshIfDue(gate: gate) { await counter.increment() } }
        try await Task.sleep(for: .milliseconds(100))
        let whileHeld = await counter.value
        XCTAssertEqual(whileHeld, 0, "no sweep while a compaction holds the index")
        let secondWhileRunning = await throttle.refreshIfDue(gate: gate) { await counter.increment() }
        XCTAssertFalse(secondWhileRunning, "one sweep at a time")
        await gate.release()
        let ran = await sweep.value
        XCTAssertTrue(ran)
        let afterRelease = await counter.value
        XCTAssertEqual(afterRelease, 1)
        // The sweep handed the gate back.
        let free = await gate.tryAcquire()
        XCTAssertTrue(free)
    }

    func testCancelledWaitClaimsNothingAndStaysDue() async throws {
        let throttle = SessionIndexRefreshThrottle()
        let gate = SessionIndexMaintenanceGate()
        let counter = Counter()
        try await gate.acquire()
        let sweep = Task { await throttle.refreshIfDue(gate: gate) { await counter.increment() } }
        try await Task.sleep(for: .milliseconds(50))
        sweep.cancel()
        let ran = await sweep.value
        XCTAssertFalse(ran)
        let count = await counter.value
        XCTAssertEqual(count, 0)
        await gate.release()
        let due = await throttle.isDue
        XCTAssertTrue(due, "a cancelled wait does not count as a sweep")
    }
}
