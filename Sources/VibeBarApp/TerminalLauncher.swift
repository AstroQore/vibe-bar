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
/// those behind a per-target Automation approval. A refusal is not a
/// failure here: the line goes to the pasteboard and the caller says so, so
/// the user can paste it into whatever they already have open instead of
/// being sent to System Settings for a one-off action.
@MainActor
enum TerminalLauncher {
    enum Result: Equatable {
        /// The terminal accepted the line and is running it.
        case launched(PreferredTerminal)
        /// The line is on the pasteboard. `reason` is `nil` when that was
        /// what the user asked for, and carries the automation failure
        /// otherwise.
        case copiedToClipboard(reason: String?)
        /// Neither the terminal nor the pasteboard took it.
        case failed(String)
    }

    static func launch(shellLine: String, preferred: PreferredTerminal) async -> Result {
        switch preferred {
        case .copyOnly:
            return copy(shellLine, reason: nil)
        case .terminal:
            return run(terminalScript(for: shellLine), line: shellLine, target: preferred)
        case .iterm2:
            return run(itermScript(for: shellLine), line: shellLine, target: preferred)
        }
    }

    // MARK: - Scripts

    private static func terminalScript(for line: String) -> String {
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
    private static func itermScript(for line: String) -> String {
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
    static func appleScriptLiteral(_ raw: String) -> String {
        let escaped = raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Execution

    /// AppleScript's "not authorized to send Apple events" — the code macOS
    /// returns once the user has denied the Automation prompt, and the one
    /// outcome that is a settings problem rather than a scripting one.
    static let notAuthorizedErrorNumber = -1743

    private static func run(_ source: String, line: String, target: PreferredTerminal) -> Result {
        guard let script = NSAppleScript(source: source) else {
            return copy(line, reason: "The \(target.displayName) launch script could not be compiled.")
        }
        var errorInfo: NSDictionary?
        // The error dictionary is the only reliable signal: the returned
        // descriptor is typed non-optional here and carries nothing useful
        // for a `tell` that returns no value.
        _ = script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return .launched(target) }
        return copy(line, reason: reason(for: errorInfo, target: target))
    }

    private static func reason(for errorInfo: NSDictionary, target: PreferredTerminal) -> String {
        let code = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue
        if code == notAuthorizedErrorNumber {
            return "Vibe Bar is not allowed to control \(target.displayName) yet — "
                + "approve it under System Settings › Privacy & Security › Automation."
        }
        if let message = errorInfo[NSAppleScript.errorMessage] as? String, !message.isEmpty {
            return "\(target.displayName) could not run the command: \(message)"
        }
        return "\(target.displayName) did not respond to the launch request."
    }

    private static func copy(_ line: String, reason: String?) -> Result {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(line, forType: .string) else {
            return .failed(reason ?? "The command could not be copied to the clipboard.")
        }
        return .copiedToClipboard(reason: reason)
    }
}
