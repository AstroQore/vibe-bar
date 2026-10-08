import Darwin
import XCTest
@testable import VibeBarCore

/// The resume launcher's decisions, with the terminal replaced by a closure:
/// the pasteboard fallback for each way a script can fail, the off-main
/// script run, and the double click that must not open two windows.
@MainActor
final class TerminalLaunchGateTests: XCTestCase {
    private let line = "cd /Users/example/Code/demo && codex resume 0199aaaa-0000-7000-8000-000000000001"

    /// Records what reached the pasteboard and how often the script ran, and
    /// can hold a script open until the test lets it finish.
    private final class Harness: @unchecked Sendable {
        private let lock = NSLock()
        private var _runs: [(PreferredTerminal, String)] = []
        private var _ranOnMainThread = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var startedWaiters: [CheckedContinuation<Void, Never>] = []
        private var _started = 0
        var outcome: TerminalScriptOutcome = .succeeded
        var holdsScripts = false
        @MainActor var copied: [String] = []
        @MainActor var pasteboardAccepts = true

        var runs: [(PreferredTerminal, String)] { lock.withLock { _runs } }
        var ranOnMainThread: Bool { lock.withLock { _ranOnMainThread } }

        func run(_ target: PreferredTerminal, _ line: String) async -> TerminalScriptOutcome {
            let hold: Bool = lock.withLock {
                _runs.append((target, line))
                if pthread_main_np() != 0 { _ranOnMainThread = true }
                _started += 1
                let ready = startedWaiters
                startedWaiters = []
                ready.forEach { $0.resume() }
                return holdsScripts
            }
            if hold {
                await withCheckedContinuation { continuation in
                    lock.withLock { waiters.append(continuation) }
                }
            }
            return outcome
        }

        /// Returns once at least `count` scripts have started.
        func waitForStarts(_ count: Int) async {
            while true {
                let done: Bool = lock.withLock { _started >= count }
                if done { return }
                await withCheckedContinuation { continuation in
                    let ready: Bool = lock.withLock {
                        if _started >= count { return true }
                        startedWaiters.append(continuation)
                        return false
                    }
                    if ready { continuation.resume() }
                }
            }
        }

        func releaseScripts() {
            let held: [CheckedContinuation<Void, Never>] = lock.withLock {
                let held = waiters
                waiters = []
                holdsScripts = false
                return held
            }
            held.forEach { $0.resume() }
        }

        @MainActor func gate() -> TerminalLaunchGate {
            TerminalLaunchGate(
                runScript: { [self] target, line in await self.run(target, line) },
                copyToPasteboard: { [self] text in
                    guard pasteboardAccepts else { return false }
                    copied.append(text)
                    return true
                }
            )
        }
    }

    func testALaunchTheTerminalAcceptsCopiesNothing() async {
        let harness = Harness()
        let result = await harness.gate().launch(shellLine: line, preferred: .terminal)
        XCTAssertEqual(result, .launched(.terminal))
        XCTAssertEqual(harness.runs.map(\.0), [.terminal])
        XCTAssertEqual(harness.runs.map(\.1), [line])
        XCTAssertTrue(harness.copied.isEmpty)
        XCTAssertFalse(harness.ranOnMainThread, "the script must never run on the main thread")
    }

    func testARefusedAutomationPromptFallsBackToThePasteboard() async {
        let harness = Harness()
        harness.outcome = .failed(code: TerminalLaunchGate.notAuthorizedErrorNumber, message: "Not authorized")
        let result = await harness.gate().launch(shellLine: line, preferred: .iterm2)
        guard case let .copiedToClipboard(reason?) = result else {
            return XCTFail("expected the pasteboard fallback with a reason, got \(String(describing: result))")
        }
        XCTAssertTrue(reason.contains("Automation"), reason)
        XCTAssertTrue(reason.contains("iTerm2"), reason)
        XCTAssertEqual(harness.copied, [line])
    }

    func testEveryOtherScriptFailureAlsoFallsBackAndSaysWhy() async {
        let harness = Harness()
        let gate = harness.gate()

        harness.outcome = .failed(code: -2_700, message: "Terminal got an error")
        let failed = await gate.launch(shellLine: line, preferred: .terminal)
        XCTAssertEqual(failed, .copiedToClipboard(reason: "Terminal could not run the command: Terminal got an error"))

        harness.outcome = .failed(code: nil, message: nil)
        let silent = await gate.launch(shellLine: line, preferred: .terminal)
        XCTAssertEqual(silent, .copiedToClipboard(reason: "Terminal did not respond to the launch request."))

        harness.outcome = .uncompilable
        let uncompiled = await gate.launch(shellLine: line, preferred: .terminal)
        guard case .copiedToClipboard(reason: _?) = uncompiled else {
            return XCTFail("expected a reasoned fallback, got \(String(describing: uncompiled))")
        }
        XCTAssertEqual(harness.copied, [line, line, line])
    }

    func testAPasteboardThatRefusesTooIsAFailureCarryingTheFirstReason() async {
        let harness = Harness()
        harness.outcome = .failed(code: TerminalLaunchGate.notAuthorizedErrorNumber, message: nil)
        harness.pasteboardAccepts = false
        let result = await harness.gate().launch(shellLine: line, preferred: .terminal)
        guard case let .failed(message) = result else {
            return XCTFail("expected a failure, got \(String(describing: result))")
        }
        XCTAssertTrue(message.contains("Automation"), message)
    }

    func testCopyOnlyNeverRunsAScript() async {
        let harness = Harness()
        let gate = harness.gate()
        let first = await gate.launch(shellLine: line, preferred: .copyOnly)
        let second = await gate.launch(shellLine: line, preferred: .copyOnly)
        XCTAssertEqual(first, .copiedToClipboard(reason: nil))
        XCTAssertEqual(second, .copiedToClipboard(reason: nil), "copying is instant and never deduplicated")
        XCTAssertTrue(harness.runs.isEmpty)
        XCTAssertEqual(harness.copied, [line, line])
    }

    /// The double click: the second request arrives while the first script
    /// is still waiting on Terminal (or on the Automation prompt). It must
    /// neither start a second script nor report anything.
    func testASecondClickWhileTheSameLaunchRunsIsIgnored() async {
        let harness = Harness()
        harness.holdsScripts = true
        let gate = harness.gate()

        let first = Task { await gate.launch(shellLine: line, preferred: .terminal) }
        await harness.waitForStarts(1)
        XCTAssertTrue(gate.isLaunching(shellLine: line, preferred: .terminal))

        let second = await gate.launch(shellLine: line, preferred: .terminal)
        XCTAssertNil(second, "a repeat of an in-flight launch is dropped")
        XCTAssertEqual(harness.runs.count, 1, "one script, so one window")

        harness.releaseScripts()
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .launched(.terminal))
        XCTAssertFalse(gate.isLaunching(shellLine: line, preferred: .terminal))

        // Finished means a fresh click launches again.
        let third = await gate.launch(shellLine: line, preferred: .terminal)
        XCTAssertEqual(third, .launched(.terminal))
        XCTAssertEqual(harness.runs.count, 2)
    }

    /// Two clicks queued back to back on the main actor, before either has
    /// reached its first suspension: the in-flight mark is set before the
    /// script is awaited, so the second still sees it.
    func testTwoClicksDeliveredBackToBackStillStartOneScript() async {
        let harness = Harness()
        harness.holdsScripts = true
        let gate = harness.gate()

        let first = Task { await gate.launch(shellLine: line, preferred: .iterm2) }
        let second = Task { await gate.launch(shellLine: line, preferred: .iterm2) }
        await harness.waitForStarts(1)
        // Let both clicks reach the gate before the script is allowed to end;
        // whichever ran first holds the mark, the other must see it.
        for _ in 0..<20 { await Task.yield() }
        harness.releaseScripts()
        let results = [await first.value, await second.value]
        XCTAssertEqual(results.filter { $0 == nil }.count, 1, "one of the two clicks is dropped")
        XCTAssertEqual(results.compactMap { $0 }, [.launched(.iterm2)])
        XCTAssertEqual(harness.runs.count, 1)
    }

    func testDifferentSessionsAreNotMergedIntoOneLaunch() async {
        let harness = Harness()
        harness.holdsScripts = true
        let gate = harness.gate()
        let other = "cd /Users/example/Code/demo && codex resume 0199aaaa-0000-7000-8000-000000000002"

        let first = Task { await gate.launch(shellLine: line, preferred: .terminal) }
        let second = Task { await gate.launch(shellLine: other, preferred: .terminal) }
        await harness.waitForStarts(2)
        harness.releaseScripts()
        let results = [await first.value, await second.value]
        XCTAssertEqual(results, [.launched(.terminal), .launched(.terminal)])
        XCTAssertEqual(Set(harness.runs.map(\.1)), [line, other])
    }

    // MARK: - Reveal in Finder

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
}
