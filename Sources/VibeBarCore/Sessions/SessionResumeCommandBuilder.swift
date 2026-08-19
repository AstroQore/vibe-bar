import Foundation

public enum SessionResumeError: Error, Hashable, Sendable {
    /// The id contains something outside the provider's own id charset.
    /// Session ids come off disk, and the result of this builder is
    /// pasted into a shell, so anything unexpected is refused rather
    /// than escaped.
    case invalidSessionID
    /// The provider (or this variant of it) has no resume command.
    case resumeUnavailable
}

extension SessionResumeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidSessionID: return "This session's identifier cannot be used in a command."
        case .resumeUnavailable: return "This session cannot be resumed from the command line."
        }
    }
}

/// Builds the shell command that reopens a session in its own CLI.
///
/// Pure string construction — nothing here spawns a process. The App
/// layer decides whether to copy the line to the clipboard or hand it
/// to a terminal.
public enum SessionResumeCommandBuilder {
    public static func command(
        provider: SessionProvider,
        sessionID: String,
        variant: String? = nil
    ) throws -> String {
        let id = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValid(id, for: provider) else { throw SessionResumeError.invalidSessionID }

        switch provider {
        case .claude:
            return "claude --resume \(id)"
        case .codex:
            return "codex resume \(id)"
        case .grok:
            return "grok --resume \(id)"
        case .gemini:
            return "gemini --resume \(id)"
        case .antigravity:
            // Only the CLI surface takes a conversation id; the IDE
            // sessions have no documented command-line entry point.
            guard variant == antigravityCLIVariant else { throw SessionResumeError.resumeUnavailable }
            return "agy --conversation \(id)"
        case .claudeCowork, .cursor, .grokBot:
            // Cowork runs inside Claude.app and Cursor's agents inside
            // Cursor; neither publishes a "reopen this conversation"
            // command, and inventing one would hand the user a line that
            // silently starts a *new* session. Grok Bot goes further: the
            // conversation runs on xAI's servers and there is no CLI at all.
            throw SessionResumeError.resumeUnavailable
        }
    }

    public static let antigravityCLIVariant = "cli"

    /// `cd '<dir>' && <command>` so the resumed session lands in the
    /// directory it was recorded in.
    public static func shellLine(cwd: String?, command: String) -> String {
        guard let cwd, !cwd.trimmingCharacters(in: .whitespaces).isEmpty else { return command }
        return "cd \(posixSingleQuoted(cwd)) && \(command)"
    }

    /// POSIX single-quoting: everything between the quotes is literal,
    /// and an embedded quote is spelled `'\''` — close, escape, reopen.
    public static func posixSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Validation

    private static let maxSessionIDLength = 200

    static func isValid(_ id: String, for provider: SessionProvider) -> Bool {
        guard !id.isEmpty, id.count <= maxSessionIDLength else { return false }
        switch provider {
        case .claude, .claudeCowork, .codex, .cursor, .antigravity, .grokBot:
            return id.unicodeScalars.allSatisfy { uuidCharacters.contains($0) }
        case .grok, .gemini:
            return id.unicodeScalars.allSatisfy { looseCharacters.contains($0) }
        }
    }

    private static let uuidCharacters = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
    private static let looseCharacters = CharacterSet(charactersIn:
        "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ._-"
    )
}
