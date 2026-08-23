import XCTest
@testable import VibeBarCore

/// `ProcessRunner` must enforce its `timeout` even when the child refuses
/// to die on SIGTERM. The AntiGravity cost-scan probe (`/bin/ps`,
/// `/usr/sbin/lsof`) runs through here; a child that ignores SIGTERM used
/// to leave `run` blocked on pipe EOF forever, which wedged the entire
/// cost-refresh loop (`CostUsageService.refreshAll`).
final class ProcessRunnerTests: XCTestCase {

    /// Guard test: a normal, fast process still returns its stdout and a
    /// zero status. The timeout fix must not regress the happy path.
    func testCapturesStdoutOfNormalProcess() async throws {
        let result = try await ProcessRunner.run(
            binary: "/bin/echo",
            arguments: ["hello-vibebar"],
            timeout: 5,
            label: "echo"
        )
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertTrue(
            result.stdout.contains("hello-vibebar"),
            "stdout was: \(result.stdout)"
        )
    }

    /// A child that ignores SIGTERM and holds the stdout pipe open must be
    /// force-killed when the timeout elapses, so `run` returns promptly
    /// instead of waiting for the child to exit on its own.
    func testKillsChildThatIgnoresSIGTERMWithinTimeout() async throws {
        let perl = "/usr/bin/perl"
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: perl),
            "perl not available to simulate a SIGTERM-ignoring child"
        )
        // perl ignores SIGTERM and would otherwise stay alive ~10s, holding
        // the stdout pipe open so `run` never sees EOF. With a 1s timeout,
        // `run` must SIGKILL it and return in ~1-2s, not ~10s.
        let start = Date()
        do {
            _ = try await ProcessRunner.run(
                binary: perl,
                arguments: ["-e", "$SIG{TERM}='IGNORE'; sleep 10;"],
                timeout: 1,
                label: "ignores-sigterm"
            )
            XCTFail("Expected ProcessRunner.Error.timedOut")
        } catch let error as ProcessRunner.Error {
            guard case .timedOut("ignores-sigterm") = error else {
                return XCTFail("Expected timedOut, got \(error)")
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(
            elapsed, 4,
            "run() did not enforce its timeout against a SIGTERM-ignoring child (took \(elapsed)s)"
        )
    }

    /// Both streams must be drained at once. Reading stdout to EOF before
    /// touching stderr deadlocks once the child fills stderr's pipe.
    func testDrainsLargeStdoutAndStderrConcurrently() async throws {
        let perl = "/usr/bin/perl"
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: perl),
            "perl not available to generate large output"
        )

        let result = try await ProcessRunner.run(
            binary: perl,
            arguments: ["-e", "print STDOUT 'o' x 1048576; print STDERR 'e' x 1048576;"],
            timeout: 5,
            label: "large-dual-pipes"
        )

        XCTAssertEqual(result.stdout.utf8.count, 1_048_576)
        XCTAssertEqual(result.stderr.utf8.count, 1_048_576)
        XCTAssertEqual(result.terminationStatus, 0)
    }

    /// The parent can exit while a forked descendant still owns both pipe FDs.
    /// The timeout must cover collecting the pipes, not just the parent PID.
    func testTimesOutWhenDescendantKeepsPipesOpen() async throws {
        let perl = "/usr/bin/perl"
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: perl),
            "perl not available to fork a pipe-holding descendant"
        )

        let start = Date()
        do {
            _ = try await ProcessRunner.run(
                binary: perl,
                arguments: ["-e", "if (fork() == 0) { sleep 2; exit 0; } exit 0;"],
                timeout: 0.2,
                label: "descendant-holds-pipes"
            )
            XCTFail("Expected ProcessRunner.Error.timedOut")
        } catch let error as ProcessRunner.Error {
            guard case .timedOut("descendant-holds-pipes") = error else {
                return XCTFail("Expected timedOut, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testCallerCancellationStopsTheProcessPromptly() async throws {
        let perl = "/usr/bin/perl"
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: perl),
            "perl not available to simulate a long-running child"
        )

        let start = Date()
        let task = Task {
            try await ProcessRunner.run(
                binary: perl,
                arguments: ["-e", "sleep 10;"],
                timeout: 10,
                label: "cancelled-child"
            )
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }
}
