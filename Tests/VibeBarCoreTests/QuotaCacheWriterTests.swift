import XCTest
@testable import VibeBarCore

/// The writer exists so `QuotaService` stops encoding and writing an account's
/// quota cache on the main actor once per successful refresh. What has to hold:
/// the first write for an account lands immediately, further writes inside the
/// throttle window are coalesced to the newest one, and a delete cannot be
/// undone by a write still sitting in the queue.
final class QuotaCacheWriterTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(accountId: String, plan: String?)] = []
        private var deletions: [String] = []

        func record(_ quota: AccountQuota) {
            lock.lock()
            storage.append((quota.accountId, quota.plan))
            lock.unlock()
        }

        func recordDeletion(_ accountId: String) {
            lock.lock()
            deletions.append(accountId)
            lock.unlock()
        }

        var writes: [(accountId: String, plan: String?)] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        var deletes: [String] {
            lock.lock()
            defer { lock.unlock() }
            return deletions
        }
    }

    private func quota(accountId: String = "acct-1", plan: String?) -> AccountQuota {
        AccountQuota(
            accountId: accountId,
            tool: .claude,
            buckets: [],
            plan: plan,
            email: nil,
            queriedAt: Date()
        )
    }

    private func makeWriter(_ recorder: Recorder, throttle: TimeInterval) -> QuotaCacheWriter {
        QuotaCacheWriter(
            throttleInterval: throttle,
            write: { recorder.record($0) },
            remove: { recorder.recordDeletion($0) }
        )
    }

    func testFirstWritePerAccountLandsImmediately() async {
        let recorder = Recorder()
        let writer = makeWriter(recorder, throttle: 60)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await writer.save(quota(plan: "first"), now: start)
        await writer.save(quota(accountId: "acct-2", plan: "other"), now: start)

        XCTAssertEqual(recorder.writes.map(\.plan), ["first", "other"])
    }

    func testWritesInsideTheWindowCoalesceToTheNewest() async {
        let recorder = Recorder()
        let writer = makeWriter(recorder, throttle: 60)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await writer.save(quota(plan: "first"), now: start)
        await writer.save(quota(plan: "second"), now: start.addingTimeInterval(1))
        await writer.save(quota(plan: "third"), now: start.addingTimeInterval(2))
        XCTAssertEqual(recorder.writes.map(\.plan), ["first"])

        await writer.flushPendingWrites()
        XCTAssertEqual(recorder.writes.map(\.plan), ["first", "third"])

        // Nothing is queued any more, so a second flush must be a no-op rather
        // than rewriting the same quota.
        await writer.flushPendingWrites()
        XCTAssertEqual(recorder.writes.count, 2)
    }

    func testWriteAfterTheWindowLandsImmediatelyAgain() async {
        let recorder = Recorder()
        let writer = makeWriter(recorder, throttle: 10)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await writer.save(quota(plan: "first"), now: start)
        await writer.save(quota(plan: "second"), now: start.addingTimeInterval(11))
        XCTAssertEqual(recorder.writes.map(\.plan), ["first", "second"])
    }

    func testDeleteDropsAPendingWriteSoASignedOutAccountStaysGone() async {
        let recorder = Recorder()
        let writer = makeWriter(recorder, throttle: 60)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await writer.save(quota(plan: "first"), now: start)
        await writer.save(quota(plan: "queued"), now: start.addingTimeInterval(1))
        await writer.delete(accountId: "acct-1")
        await writer.flushPendingWrites()

        XCTAssertEqual(recorder.deletes, ["acct-1"])
        XCTAssertEqual(recorder.writes.map(\.plan), ["first"])
    }

    func testCoalescedWriteIsFlushedOnItsOwnWithoutAnExplicitFlush() async throws {
        let recorder = Recorder()
        let writer = makeWriter(recorder, throttle: 0.2)
        let now = Date()

        await writer.save(quota(plan: "first"), now: now)
        await writer.save(quota(plan: "queued"), now: now)
        XCTAssertEqual(recorder.writes.map(\.plan), ["first"])

        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(recorder.writes.map(\.plan), ["first", "queued"])
    }
}
