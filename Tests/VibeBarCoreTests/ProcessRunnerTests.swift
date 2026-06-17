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
        _ = try await ProcessRunner.run(
            binary: perl,
            arguments: ["-e", "$SIG{TERM}='IGNORE'; sleep 10;"],
            timeout: 1,
            label: "ignores-sigterm"
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(
            elapsed, 4,
            "run() did not enforce its timeout against a SIGTERM-ignoring child (took \(elapsed)s)"
        )
    }
}
