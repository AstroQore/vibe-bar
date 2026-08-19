import XCTest
@testable import VibeBarCore

final class SessionResumeCommandBuilderTests: XCTestCase {
    private let uuid = "019c2215-0f3c-7f72-89e3-92598c209589"

    // MARK: - Commands

    func testExactCommandPerProvider() throws {
        XCTAssertEqual(try SessionResumeCommandBuilder.command(provider: .claude, sessionID: uuid),
                       "claude --resume \(uuid)")
        XCTAssertEqual(try SessionResumeCommandBuilder.command(provider: .codex, sessionID: uuid),
                       "codex resume \(uuid)")
        XCTAssertEqual(try SessionResumeCommandBuilder.command(provider: .grok, sessionID: uuid),
                       "grok --resume \(uuid)")
        XCTAssertEqual(try SessionResumeCommandBuilder.command(provider: .gemini, sessionID: "session-2026-01-01T00-00-abc"),
                       "gemini --resume session-2026-01-01T00-00-abc")
    }

    func testAntigravityNeedsTheCLIVariant() throws {
        XCTAssertEqual(
            try SessionResumeCommandBuilder.command(provider: .antigravity, sessionID: uuid, variant: "cli"),
            "agy --conversation \(uuid)"
        )
        assertThrows(.resumeUnavailable) {
            try SessionResumeCommandBuilder.command(provider: .antigravity, sessionID: uuid)
        }
        assertThrows(.resumeUnavailable) {
            try SessionResumeCommandBuilder.command(provider: .antigravity, sessionID: uuid, variant: "ide")
        }
        assertThrows(.resumeUnavailable) {
            try SessionResumeCommandBuilder.command(provider: .antigravity, sessionID: uuid, variant: "ide2")
        }
    }

    /// Neither Cowork nor Cursor publishes a "reopen this conversation"
    /// command; inventing one would hand the user a line that quietly starts
    /// a *new* session in the wrong app. Grok Bot has no CLI at all — the
    /// conversation only exists on xAI's servers.
    func testCoworkCursorAndGrokBotHaveNoResumeCommandOnAnyVariant() {
        for provider in [SessionProvider.claudeCowork, .cursor, .grokBot] {
            for variant in [nil, "cli", "default"] {
                assertThrows(.resumeUnavailable) {
                    try SessionResumeCommandBuilder.command(
                        provider: provider, sessionID: uuid, variant: variant
                    )
                }
            }
        }
    }

    /// Every provider either builds a command or refuses for a stated
    /// reason — a new case must not fall through to a wrong CLI.
    func testEveryProviderIsAccountedFor() {
        let resumable: Set<SessionProvider> = [.claude, .codex, .grok, .gemini, .antigravity]
        for provider in SessionProvider.allCases {
            let command = try? SessionResumeCommandBuilder.command(
                provider: provider, sessionID: uuid, variant: "cli"
            )
            XCTAssertEqual(command != nil, resumable.contains(provider), "\(provider)")
        }
    }

    /// The adapter's variant strings and the builder's one resumable
    /// variant have to stay the same three values.
    func testAntigravityVariantsMatchTheAdapter() {
        XCTAssertEqual(AntigravitySessionAdapter.cliVariant, SessionResumeCommandBuilder.antigravityCLIVariant)
        XCTAssertEqual(
            AntigravitySessionAdapter.surfaces.map(\.variant),
            ["ide", "cli", "ide2"]
        )
    }

    func testSurroundingWhitespaceIsTrimmedNotRejected() throws {
        XCTAssertEqual(try SessionResumeCommandBuilder.command(provider: .claude, sessionID: "  \(uuid)\n"),
                       "claude --resume \(uuid)")
    }

    // MARK: - Injection

    func testShellMetacharactersInIdsAreRejected() {
        let hostile = [
            "abc; rm -rf /",
            "$(whoami)",
            "`id`",
            "abc && curl example.com",
            "abc | tee /tmp/x",
            "abc\nrm -rf /",
            "../../etc/passwd",
            "abc'\"",
            ""
        ]
        for id in hostile {
            for provider in SessionProvider.allCases {
                assertThrows(.invalidSessionID) {
                    try SessionResumeCommandBuilder.command(provider: provider, sessionID: id, variant: "cli")
                }
            }
        }
    }

    func testUUIDProvidersRejectNonHexIdentifiers() {
        for provider in [SessionProvider.claude, .codex, .antigravity] {
            assertThrows(.invalidSessionID) {
                try SessionResumeCommandBuilder.command(provider: provider, sessionID: "session-xyz", variant: "cli")
            }
        }
        // Grok and Gemini use a wider charset, so the same id is fine.
        XCTAssertNoThrow(try SessionResumeCommandBuilder.command(provider: .gemini, sessionID: "session-xyz"))
        XCTAssertNoThrow(try SessionResumeCommandBuilder.command(provider: .grok, sessionID: "session_x.y-z"))
    }

    func testOverlongIdentifiersAreRejected() {
        let long = String(repeating: "a", count: 500)
        assertThrows(.invalidSessionID) {
            try SessionResumeCommandBuilder.command(provider: .gemini, sessionID: long)
        }
    }

    // MARK: - Shell quoting

    func testPosixSingleQuotingRoundTrip() throws {
        let cases = [
            "/Users/example/proj",
            "/Users/example/it's here",
            "/Users/example/$(whoami)",
            "/Users/example/a b;c",
            "/Users/example/'",
            "/Users/example/back\\slash"
        ]
        for value in cases {
            let quoted = SessionResumeCommandBuilder.posixSingleQuoted(value)
            let echoed = try runInShell("printf %s \(quoted)")
            XCTAssertEqual(echoed, value, "quoting failed to round-trip for \(value)")
        }
    }

    func testShellLinePrefixesCdWhenACwdIsKnown() {
        let command = "claude --resume \(uuid)"
        XCTAssertEqual(
            SessionResumeCommandBuilder.shellLine(cwd: "/Users/example/it's here", command: command),
            "cd '/Users/example/it'\\''s here' && \(command)"
        )
        XCTAssertEqual(SessionResumeCommandBuilder.shellLine(cwd: nil, command: command), command)
        XCTAssertEqual(SessionResumeCommandBuilder.shellLine(cwd: "   ", command: command), command)
    }

    // MARK: - Helpers

    private func assertThrows(
        _ expected: SessionResumeError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> String
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? SessionResumeError, expected, file: file, line: line)
        }
    }

    /// Runs the quoted fragment through a real shell so the escaping is
    /// verified against `/bin/sh`, not against our own assumptions.
    private func runInShell(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
