import Darwin
import XCTest
@testable import VibeBarCore

/// "Reveal in Finder": what it selects, that the probe never runs on the
/// main thread, and that clicking again while a slow probe runs starts no
/// second one.
@MainActor
final class SessionSourceRevealTests: XCTestCase {
    func testRevealSelectsTheLogOrTheNearestThingThatExists() {
        let existing: Set<String> = [
            "/Users/example/.codex/sessions/2026/01/02/rollout.jsonl",
            "/Users/example/.local/share/devin/cli/sessions.db",
            "/Users/example/.claude/projects/demo"
        ]
        let exists: (String) -> Bool = { existing.contains($0) }
        XCTAssertEqual(
            SessionSourceReveal.target(
                forSourcePath: "/Users/example/.codex/sessions/2026/01/02/rollout.jsonl", fileExists: exists
            )?.path,
            "/Users/example/.codex/sessions/2026/01/02/rollout.jsonl"
        )
        // A Devin locator names a row inside the database.
        XCTAssertEqual(
            SessionSourceReveal.target(
                forSourcePath: "/Users/example/.local/share/devin/cli/sessions.db/sess-1", fileExists: exists
            )?.path,
            "/Users/example/.local/share/devin/cli/sessions.db"
        )
        // A log removed since the last sweep: its folder.
        XCTAssertEqual(
            SessionSourceReveal.target(
                forSourcePath: "/Users/example/.claude/projects/demo/gone.jsonl", fileExists: exists
            )?.path,
            "/Users/example/.claude/projects/demo"
        )
        XCTAssertNil(SessionSourceReveal.target(forSourcePath: "/nowhere/at/all", fileExists: exists))
        XCTAssertNil(SessionSourceReveal.target(forSourcePath: "", fileExists: exists))
    }

    /// Holds probes open until released, and records what reached Finder.
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var held: [CheckedContinuation<Void, Never>] = []
        /// Sticky: a probe that arrives after `releaseAll()` must not wait
        /// for a release that already happened.
        private var released = false
        private var started: [String] = []
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        var target: URL? = URL(fileURLWithPath: "/Users/example/.codex/sessions/rollout.jsonl")
        @MainActor var presented: [URL] = []

        var starts: [String] { lock.withLock { started } }

        func resolve(_ path: String) async -> URL? {
            lock.withLock {
                started.append(path)
                let ready = startWaiters
                startWaiters = []
                ready.forEach { $0.resume() }
            }
            await withCheckedContinuation { continuation in
                let immediate: Bool = lock.withLock {
                    if released { return true }
                    held.append(continuation)
                    return false
                }
                if immediate { continuation.resume() }
            }
            return target
        }

        func waitForStarts(_ count: Int) async {
            while true {
                if lock.withLock({ started.count >= count }) { return }
                await withCheckedContinuation { continuation in
                    let ready: Bool = lock.withLock {
                        if started.count >= count { return true }
                        startWaiters.append(continuation)
                        return false
                    }
                    if ready { continuation.resume() }
                }
            }
        }

        func releaseAll() {
            let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
                released = true
                let waiting = held
                held = []
                return waiting
            }
            waiting.forEach { $0.resume() }
        }

        @MainActor func revealer() -> SessionSourceRevealer {
            SessionSourceRevealer(
                resolve: { [self] path in await self.resolve(path) },
                present: { [self] url in presented.append(url) }
            )
        }
    }

    private final class ThreadLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _probedOnMain = false
        private var _probes = 0
        var probedOnMain: Bool { lock.withLock { _probedOnMain } }
        var probes: Int { lock.withLock { _probes } }
        func record() {
            lock.withLock {
                _probes += 1
                if pthread_main_np() != 0 { _probedOnMain = true }
            }
        }
    }

    func testTheDefaultProbeRunsOffTheMainThread() async {
        let log = ThreadLog()
        let existing = "/Users/example/.claude/projects/demo"
        var presented: [URL] = []
        let revealer = SessionSourceRevealer(
            resolve: SessionSourceRevealer.offMainResolver(fileExists: { path in
                log.record()
                return path == existing
            }),
            present: { presented.append($0) }
        )
        let shown = await revealer.reveal(sourcePath: existing + "/gone.jsonl")
        XCTAssertTrue(shown)
        XCTAssertEqual(presented.map(\.path), [existing])
        XCTAssertEqual(log.probes, 2, "the missing log, then its folder")
        XCTAssertFalse(log.probedOnMain, "no filesystem probe may run on the main thread")
    }

    func testARevealWhoseProbeFindsNothingShowsNothing() async {
        let probe = Probe()
        probe.target = nil
        let revealer = probe.revealer()
        let task = Task { await revealer.reveal(sourcePath: "/nowhere/at/all") }
        await probe.waitForStarts(1)
        probe.releaseAll()
        let shown = await task.value
        XCTAssertFalse(shown)
        XCTAssertTrue(probe.presented.isEmpty)
    }

    func testClickingAgainWhileTheSameProbeRunsIsIgnored() async {
        let probe = Probe()
        let revealer = probe.revealer()
        let path = "/Volumes/slow-share/.codex/sessions/rollout.jsonl"

        let first = Task { await revealer.reveal(sourcePath: path) }
        await probe.waitForStarts(1)
        XCTAssertTrue(revealer.isRevealing(sourcePath: path))
        let second = await revealer.reveal(sourcePath: path)
        XCTAssertFalse(second, "a repeat of an in-flight reveal is dropped")
        XCTAssertEqual(probe.starts, [path], "one probe, however many clicks")

        probe.releaseAll()
        let firstShown = await first.value
        XCTAssertTrue(firstShown)
        XCTAssertEqual(probe.presented.count, 1, "Finder is asked once")
        XCTAssertFalse(revealer.isRevealing(sourcePath: path))

        // Done means a fresh click probes again.
        let again = Task { await revealer.reveal(sourcePath: path) }
        await probe.waitForStarts(2)
        probe.releaseAll()
        let againShown = await again.value
        XCTAssertTrue(againShown)
        XCTAssertEqual(probe.presented.count, 2)
    }

    func testTwoClicksDeliveredBackToBackStartOneProbe() async {
        let probe = Probe()
        let revealer = probe.revealer()
        let path = "/Users/example/.codex/sessions/rollout.jsonl"
        let first = Task { await revealer.reveal(sourcePath: path) }
        let second = Task { await revealer.reveal(sourcePath: path) }
        await probe.waitForStarts(1)
        for _ in 0..<20 { await Task.yield() }
        probe.releaseAll()
        let results = [await first.value, await second.value]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        XCTAssertEqual(probe.starts.count, 1)
        XCTAssertEqual(probe.presented.count, 1)
    }

    func testAnotherSessionIsNotHeldUpByASlowOne() async {
        let probe = Probe()
        let revealer = probe.revealer()
        let first = Task { await revealer.reveal(sourcePath: "/Volumes/slow-share/a.jsonl") }
        let second = Task { await revealer.reveal(sourcePath: "/Users/example/b.jsonl") }
        await probe.waitForStarts(2)
        probe.releaseAll()
        let results = [await first.value, await second.value]
        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(Set(probe.starts), ["/Volumes/slow-share/a.jsonl", "/Users/example/b.jsonl"])
    }
}
