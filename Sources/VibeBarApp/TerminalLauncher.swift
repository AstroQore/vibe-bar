import AppKit
import Foundation
import VibeBarCore

/// Hands one already-built shell line to a terminal emulator.
///
/// This type never composes a command. Callers pass the line produced by
/// `SessionResumeCommandBuilder`, which is the only place that validates a
/// session id and quotes a working directory — building command text in two
/// places is how one of them ends up without the validation.
///
/// Driving Terminal or iTerm means sending Apple events, and macOS gates
/// those behind a per-target Automation approval. The decisions — what a
/// refusal means, what goes to the pasteboard, which repeat clicks to ignore
/// — live in `TerminalLaunchGate` (Core); this file is the AppKit half: the
/// scripts, the queue they run on, and the pasteboard.
@MainActor
enum TerminalLauncher {
    typealias Result = TerminalLaunchGate.Result

    /// One gate for the app, so a double click on the row's menu and on the
    /// transcript header's button is still one launch.
    private static let gate = TerminalLaunchGate(
        runScript: { target, line in await execute(script(for: target, line: line)) },
        copyToPasteboard: { line in
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(line, forType: .string)
        }
    )

    /// `nil` when the same launch is already in progress — nothing new to
    /// report, and nothing was started.
    static func launch(shellLine: String, preferred: PreferredTerminal) async -> Result? {
        await gate.launch(shellLine: shellLine, preferred: preferred)
    }

    // MARK: - Scripts

    private nonisolated static func script(for target: PreferredTerminal, line: String) -> String {
        switch target {
        case .iterm2: itermScript(for: line)
        case .terminal, .copyOnly: terminalScript(for: line)
        }
    }

    private nonisolated static func terminalScript(for line: String) -> String {
        """
        tell application "Terminal"
            activate
            do script \(appleScriptLiteral(line))
        end tell
        """
    }

    /// `create window with default profile` rather than reusing the front
    /// window: a resume writes into whatever session it lands in, and the
    /// window a user left a long-running command in is not a scratch pad.
    private nonisolated static func itermScript(for line: String) -> String {
        """
        tell application "iTerm"
            activate
            set targetWindow to (create window with default profile)
            tell current session of targetWindow
                write text \(appleScriptLiteral(line))
            end tell
        end tell
        """
    }

    /// AppleScript's string literal understands exactly two escapes, and the
    /// backslash has to be doubled first or it would escape the quote that
    /// the next replacement inserts.
    nonisolated static func appleScriptLiteral(_ raw: String) -> String {
        let escaped = raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Execution

    /// Every AppleScript this app runs goes through this one serial queue.
    ///
    /// Off the main thread because `executeAndReturnError` does not return
    /// until the target answers — and the first launch to each target waits
    /// on the Automation prompt for as long as the user leaves it up, which
    /// used to freeze the app behind a system dialog. Serial because
    /// `NSAppleScript` is not safe to run on two threads at once.
    private nonisolated static let scriptQueue = DispatchQueue(
        label: "com.astroqore.VibeBar.terminal-launch",
        qos: .userInitiated
    )

    private nonisolated static func execute(_ source: String) async -> TerminalScriptOutcome {
        await withCheckedContinuation { continuation in
            scriptQueue.async {
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(returning: .uncompilable)
                    return
                }
                var errorInfo: NSDictionary?
                // The error dictionary is the only reliable signal: the
                // returned descriptor is typed non-optional here and carries
                // nothing useful for a `tell` that returns no value.
                _ = script.executeAndReturnError(&errorInfo)
                guard let errorInfo else {
                    continuation.resume(returning: .succeeded)
                    return
                }
                continuation.resume(returning: .failed(
                    code: (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue,
                    message: errorInfo[NSAppleScript.errorMessage] as? String
                ))
            }
        }
    }
}
