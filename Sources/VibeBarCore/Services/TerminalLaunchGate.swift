import Foundation

/// What one attempt to drive a terminal emulator came to.
///
/// Produced by the App's AppleScript runner, which is the only part of a
/// launch that touches AppKit; everything that decides what happens next is
/// here, where it can be tested without a terminal.
public enum TerminalScriptOutcome: Sendable, Equatable {
    /// The terminal accepted the line.
    case succeeded
    /// The launch script would not compile.
    case uncompilable
    /// The script ran and failed. `code` is AppleScript's error number —
    /// `TerminalLaunchGate.notAuthorizedErrorNumber` once the user has
    /// declined the Automation prompt.
    case failed(code: Int?, message: String?)
}

/// Sends a resume line to a terminal without holding the main actor, and
/// without sending it twice.
///
/// Driving Terminal or iTerm is an Apple event, and the first one to each
/// target waits on the Automation prompt for as long as the user leaves it
/// up. That wait used to happen inside `NSAppleScript.executeAndReturnError`
/// on the main thread, so the whole app froze behind a system dialog, and a
/// second click queued a second script that opened a second window the
/// moment the first was approved. Now the script runs wherever `runScript`
/// puts it — the App hands it a serial queue — and a launch that is already
/// under way for the same line and terminal makes a repeat click a no-op.
///
/// A refusal is not a failure: the line goes to the pasteboard and the
/// result says why, so the user can paste it into whatever they already have
/// open instead of being sent to System Settings for a one-off action.
@MainActor
public final class TerminalLaunchGate {
    public enum Result: Equatable, Sendable {
        /// The terminal accepted the line and is running it.
        case launched(PreferredTerminal)
        /// The line is on the pasteboard. `reason` is `nil` when that was
        /// what the user asked for, and carries the automation failure
        /// otherwise.
        case copiedToClipboard(reason: String?)
        /// Neither the terminal nor the pasteboard took it.
        case failed(String)
    }

    /// Runs the launch for `target` with `shellLine`. Called off the main
    /// actor; whatever it blocks on, it blocks there.
    public typealias ScriptRunner = @Sendable (_ target: PreferredTerminal, _ shellLine: String) async -> TerminalScriptOutcome
    /// Puts text on the pasteboard; false when the pasteboard refused it.
    public typealias Pasteboard = @MainActor (_ text: String) -> Bool

    /// AppleScript's "not authorized to send Apple events" — the code macOS
    /// returns once the user has denied the Automation prompt, and the one
    /// outcome that is a settings problem rather than a scripting one.
    public static let notAuthorizedErrorNumber = -1743

    private struct Launch: Hashable {
        let target: PreferredTerminal
        let shellLine: String
    }

    private let runScript: ScriptRunner
    private let copyToPasteboard: Pasteboard
    private var inFlight: Set<Launch> = []

    public init(runScript: @escaping ScriptRunner, copyToPasteboard: @escaping Pasteboard) {
        self.runScript = runScript
        self.copyToPasteboard = copyToPasteboard
    }

    /// True while a launch of this line in this terminal has not finished.
    public func isLaunching(shellLine: String, preferred: PreferredTerminal) -> Bool {
        inFlight.contains(Launch(target: preferred, shellLine: shellLine))
    }

    /// Launch `shellLine` in `preferred`, or copy it.
    ///
    /// Returns `nil` when the same launch is already running: the click that
    /// started it will report how it went, and a second report — or a second
    /// window — is not what a double click meant. The in-flight mark is set
    /// before the first suspension, so two clicks delivered back to back on
    /// the main actor cannot both get past it.
    public func launch(shellLine: String, preferred: PreferredTerminal) async -> Result? {
        guard preferred != .copyOnly else { return copy(shellLine, reason: nil) }
        let launch = Launch(target: preferred, shellLine: shellLine)
        guard inFlight.insert(launch).inserted else { return nil }
        defer { inFlight.remove(launch) }
        switch await runScript(preferred, shellLine) {
        case .succeeded:
            return .launched(preferred)
        case .uncompilable:
            return copy(shellLine, reason: "The \(preferred.displayName) launch script could not be compiled.")
        case let .failed(code, message):
            return copy(shellLine, reason: Self.reason(code: code, message: message, target: preferred))
        }
    }

    static func reason(code: Int?, message: String?, target: PreferredTerminal) -> String {
        if code == notAuthorizedErrorNumber {
            return "Vibe Bar is not allowed to control \(target.displayName) yet — "
                + "approve it under System Settings › Privacy & Security › Automation."
        }
        if let message, !message.isEmpty {
            return "\(target.displayName) could not run the command: \(message)"
        }
        return "\(target.displayName) did not respond to the launch request."
    }

    private func copy(_ line: String, reason: String?) -> Result {
        guard copyToPasteboard(line) else {
            return .failed(reason ?? "The command could not be copied to the clipboard.")
        }
        return .copiedToClipboard(reason: reason)
    }
}
