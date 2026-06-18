import XCTest
@testable import VibeBarCore

/// `AsyncTimeout.run` bounds how long a caller waits for an async
/// operation. It is the last-resort backstop that keeps
/// `CostUsageService.refreshAll` from wedging forever if a single
/// provider's scan stalls — on timeout it abandons the operation and
/// returns, rather than awaiting a non-cancellable hang.
final class AsyncTimeoutTests: XCTestCase {

    func testReturnsCompletedWhenOperationFinishesInTime() async {
        let outcome = await AsyncTimeout.run(seconds: 5) { 42 }
        guard case .completed(let value) = outcome else {
            return XCTFail("expected .completed, got \(outcome)")
        }
        XCTAssertEqual(value, 42)
    }

    func testReturnsTimedOutWithoutWaitingForASlowOperation() async {
        let start = Date()
        let outcome = await AsyncTimeout.run(seconds: 0.2) { () -> Int in
            // Far longer than the timeout: the helper must not wait for it.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return 42
        }
        let elapsed = Date().timeIntervalSince(start)
        guard case .timedOut = outcome else {
            return XCTFail("expected .timedOut, got \(outcome)")
        }
        XCTAssertLessThan(
            elapsed, 2,
            "AsyncTimeout waited for the slow operation instead of abandoning it (took \(elapsed)s)"
        )
    }
}
